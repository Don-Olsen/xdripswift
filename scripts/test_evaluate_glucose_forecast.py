#!/usr/bin/env python3
"""Synthetic, local-only fixtures for evaluate-glucose-forecast.py."""
import csv
from datetime import datetime, timedelta, timezone
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("forecast_evaluator", Path(__file__).with_name("evaluate-glucose-forecast.py"))
E = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = E
SPEC.loader.exec_module(E)
START = datetime(2026, 10, 3, 12, tzinfo=timezone.utc)


def timestamp(minutes=0):
    return (START + timedelta(minutes=minutes)).isoformat(timespec="microseconds").replace("+00:00", "Z")


def csv_input(rows, headers):
    handle = io.StringIO(newline="")
    writer = csv.DictWriter(handle, fieldnames=sorted(headers))
    writer.writeheader()
    writer.writerows(rows)
    handle.seek(0)
    return handle


def forecast(identity="ref-a", horizon=120, computed=None, source="local", sensor="sensor-a", engine="v2",
             values=None, reference=0):
    values = values or {30: 130, 60: 140, 120: 150}
    computed = reference if computed is None else computed
    rows = []
    for offset in range(0, horizon + 1, 5):
        row = {key: "" for key in E.FORECAST_FIELDS}
        row.update(schema_version="1", record_type="forecast", engine_version=engine,
                   source_identity=source, sensor_identity=sensor, reference_identity=identity,
                   reference_date_utc=timestamp(reference), computed_at_utc=timestamp(computed),
                   horizon_minutes=str(horizon), reference_glucose_mgdl="120", offset_minutes=str(offset),
                   prediction_mgdl=str(values.get(offset, 120)))
        rows.append(row)
    return rows


def unavailable(reason="dataUnavailable", reference=None, computed=0):
    row = {key: "" for key in E.FORECAST_FIELDS}
    row.update(schema_version="1", record_type="unavailable", engine_version="v2", horizon_minutes="120",
               computed_at_utc=timestamp(computed), reason=reason)
    if reference is not None:
        row.update(reference_date_utc=timestamp(reference), reference_identity="ref-a")
    return row


def glucose(minute, value, source="local", sensor="sensor-a"):
    return dict(date_utc=timestamp(minute), glucose_mgdl=str(value), source_identity=source, sensor_identity=sensor)


def run(predictions, actuals):
    headers = E.FORECAST_FIELDS | set().union(*(row.keys() for row in predictions))
    return E.evaluate(csv_input(predictions, headers), csv_input(actuals, E.GLUCOSE_FIELDS))


def presentation(model="model-a", presented=None, ml_values=None, capped=(), **kwargs):
    predictions = forecast(**kwargs)
    values = {30: 140, 60: 150, 120: 160} if ml_values is None else ml_values
    for row in predictions:
        row.update({name: "" for name in E.PRESENTATION_FIELDS})
        offset = int(row["offset_minutes"])
        engine = float(row["prediction_mgdl"])
        row.update(schema_version="3", record_type="presentation", model_id=model or "",
                   presented_at_utc=timestamp(presented) if presented is not None else row["computed_at_utc"],
                   displayed_prediction_mgdl=str(engine))
        if model is not None:
            ml = values.get(offset, engine)
            row.update(ml_prediction_mgdl=str(ml), low_glucose_cap_applied="true" if offset in capped else "false",
                       displayed_prediction_mgdl=str(engine if offset in capped else ml))
    return predictions


class ForecastEvaluatorTests(unittest.TestCase):
    def test_known_mae_bias_and_same_baseline_pairs_at_all_offsets(self):
        report = run(forecast(), [glucose(30, 135), glucose(60, 130), glucose(120, 160)])
        expected = [(30, 5, -5, 15, -15), (60, 10, 10, 10, -10), (120, 10, -10, 40, -40)]
        for result, (offset, mae, bias, base_mae, base_bias) in zip(report["results"], expected):
            self.assertEqual(result["offset_minutes"], offset)
            self.assertEqual(result["comparable_forecasts"], 1)
            self.assertEqual(result["forecast"]["mae_mgdl"], mae)
            self.assertEqual(result["forecast"]["bias_mgdl"], bias)
            self.assertEqual(result["unchanged_reference"]["mae_mgdl"], base_mae)
            self.assertEqual(result["unchanged_reference"]["bias_mgdl"], base_bias)
            self.assertAlmostEqual(result["forecast"]["mae_mmoll"], mae / E.MGDL_PER_MMOLL)

    def test_horizon_and_engine_are_never_combined(self):
        predictions = forecast(horizon=60) + forecast(horizon=120) + forecast(horizon=60, engine="older")
        report = run(predictions, [glucose(30, 130), glucose(60, 140), glucose(120, 150)])
        self.assertEqual(len(report["availability"]), 3)
        self.assertEqual(len(report["results"]), 7)
        self.assertTrue(all(item["forecast_records"] == 1 for item in report["results"]))

    def test_target_uses_reference_not_computation_and_reports_real_lead(self):
        report = run(forecast(computed=4), [glucose(30, 130), glucose(34, 599)])
        result = report["results"][0]
        self.assertEqual(result["forecast"]["mae_mgdl"], 0)
        self.assertEqual(result["actual_lead_minutes_from_computed_at"]["mean"], 26)

    def test_target_already_reached_is_not_a_future_forecast(self):
        report = run(forecast(computed=60), [glucose(30, 130), glucose(60, 140), glucose(120, 150)])
        self.assertEqual(report["results"][0]["target_not_after_computed_at"], 1)
        self.assertEqual(report["results"][1]["target_not_after_computed_at"], 1)
        self.assertEqual(report["results"][2]["comparable_forecasts"], 1)
        self.assertEqual(report["results"][2]["actual_lead_minutes_from_computed_at"]["mean"], 60)

    def test_actual_already_known_at_computed_at_is_not_scored(self):
        report = run(forecast(computed=29), [glucose(29, 130)])
        result = report["results"][0]
        self.assertEqual(result["matched_actual_not_after_computed_at"], 1)
        self.assertEqual(result["comparable_forecasts"], 0)

    def test_nearest_match_inclusive_tolerance_and_earlier_tie(self):
        report = run(forecast(), [glucose(27.5, 130), glucose(32.5, 200), glucose(62.5, 140), glucose(122.501, 150)])
        first, second, third = report["results"]
        self.assertEqual(first["forecast"]["mae_mgdl"], 0)
        self.assertEqual(first["matched_actual_offset_seconds_from_target"]["mean"], -150)
        self.assertEqual(second["forecast"]["mae_mgdl"], 0)
        self.assertEqual(third["missing_followup_measurement"], 1)
        self.assertIsNone(third["forecast"]["mae_mgdl"])

    def test_no_sensor_or_source_mixing(self):
        report = run(forecast(), [glucose(30, 130, sensor="sensor-b"), glucose(30, 130, source="remote")])
        self.assertEqual(report["results"][0]["missing_followup_measurement"], 1)
        unknown = run(forecast(sensor=""), [glucose(30, 130)])
        self.assertEqual(unknown["results"][0]["missing_source_or_sensor_identity"], 1)

    def test_unavailable_is_separate_from_missing_followup(self):
        report = run([unavailable(), unavailable("historyGap", reference=0, computed=1)] + forecast(computed=2), [])
        availability = report["availability"][0]
        self.assertEqual(availability["valid_logged_records"], 1)
        self.assertEqual(availability["unavailable_logged_records"], 2)
        self.assertEqual(availability["unavailable_without_reference"], 1)
        self.assertAlmostEqual(availability["valid_percent_of_retained_records"], 100 / 3)
        self.assertEqual(availability["unavailable_by_reason"], {"dataUnavailable": 1, "historyGap": 1})
        self.assertTrue(all(x["missing_followup_measurement"] == 1 for x in report["results"]))
        self.assertIn("continuous 24-hour", " ".join(report["limitations"]))

    def test_unsupported_unavailable_horizon_is_retained_without_poisoning_valid_records(self):
        invalid_horizon = unavailable(reason="invalidHorizon")
        invalid_horizon["horizon_minutes"] = "35"
        report = run([invalid_horizon] + forecast(), [glucose(30, 130)])
        invalid = next(item for item in report["availability"] if item["horizon_minutes"] == 35)
        self.assertEqual(invalid["unavailable_logged_records"], 1)
        self.assertEqual(invalid["unavailable_by_reason"], {"invalidHorizon": 1})
        self.assertEqual(len(report["results"]), 3)
        self.assertTrue(all(item["horizon_minutes"] == 120 for item in report["results"]))
        self.assertEqual(report["results"][0]["comparable_forecasts"], 1)
        with self.assertRaises(E.InputError):
            run(forecast(horizon=35), [])

    def test_future_reference_and_date_overflow_fail_clearly(self):
        with self.assertRaisesRegex(E.InputError, "reference date"):
            run(forecast(reference=1, computed=0), [])
        predictions = forecast()
        for row in predictions:
            row["reference_date_utc"] = "9999-12-31T23:59:00Z"
            row["computed_at_utc"] = "9999-12-31T23:59:00Z"
        with self.assertRaisesRegex(E.InputError, "target date"):
            run(predictions, [])

    def test_missing_prediction_point_is_reported(self):
        predictions = [row for row in forecast() if row["offset_minutes"] != "60"]
        report = run(predictions, [glucose(60, 140)])
        self.assertEqual(report["results"][1]["missing_prediction_point"], 1)

    def test_large_errors_and_bias_use_signed_errors(self):
        predictions = forecast(identity="a", values={30: 190}) + forecast(identity="b", reference=1, values={30: 50})
        report = run(predictions, [glucose(30, 120), glucose(31, 120)])
        metric = report["results"][0]["forecast"]
        self.assertEqual(metric["mae_mgdl"], 70)
        self.assertEqual(metric["bias_mgdl"], 0)
        self.assertEqual(metric["large_error_count"], 2)
        self.assertEqual(metric["large_error_percent"], 100)

    def test_duplicate_export_rows_do_not_double_count(self):
        original = forecast()
        report = run(original + original, [glucose(30, 130)])
        self.assertEqual(report["results"][0]["comparable_forecasts"], 1)
        self.assertEqual(report["duplicate_forecast_point_rows_ignored"], len(original))

    def test_conflicting_immutable_forecasts_fail_closed(self):
        for altered in [forecast(computed=1), forecast(values={30: 131}), forecast(sensor="other")]:
            with self.assertRaises(E.InputError):
                run(forecast() + altered, [])

    def test_actual_invalid_conflict_and_duplicate_handling(self):
        actuals = [glucose(30, 130), glucose(30, 130), glucose(60, 140), glucose(60, 150),
                   glucose(120, "nan"), glucose(120, 601), glucose(120, 15), glucose(120, 150, sensor="")]
        report = run(forecast(), actuals)
        self.assertEqual(report["glucose_input"]["invalid_rows"], 4)
        self.assertEqual(report["glucose_input"]["duplicate_rows"], 1)
        self.assertEqual(report["glucose_input"]["conflicting_timestamps"], 1)
        self.assertEqual(report["glucose_input"]["valid_unique_readings"], 1)
        self.assertEqual(report["results"][1]["missing_followup_measurement"], 1)

    def test_utf8_escaping_fractional_time_and_nulls_survive_csv(self):
        reason = 'Ukendt, "kilde"\nprøv igen æøå'
        report = run([unavailable(reason=reason)], [])
        self.assertEqual(report["availability"][0]["unavailable_by_reason"], {reason: 1})
        self.assertEqual(report["availability"][0]["unavailable_without_reference"], 1)
        self.assertEqual(report["results"][0]["forecast"]["count"], 0)
        self.assertIsNone(report["results"][0]["forecast"]["mae_mmoll"])
        rendered = json.dumps(report, allow_nan=False)
        self.assertEqual(json.loads(rendered), report)
        self.assertEqual(E.utc("2026-10-03T12:00:00.123Z", "test").microsecond, 123000)

    def test_rejects_ambiguous_times_schema_types_and_range(self):
        for change in [{"computed_at_utc": "2026-10-03T12:00:00"}, {"schema_version": "99"},
                       {"record_type": "unknown"}, {"prediction_mgdl": "nan"},
                       {"offset_minutes": "2.5"}, {"prediction_mgdl": "601"}]:
            predictions = forecast()
            predictions[0].update(change)
            with self.assertRaises(E.InputError):
                run(predictions, [])
        with self.assertRaises(E.InputError):
            E.utc("2026-10-03T14:00:00+02:00", "test")

    def test_cli_creates_only_requested_local_report(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            forecast_path = directory / "forecast.csv"
            actual_path = directory / "actual.csv"
            output = directory / "report.json"
            forecast_path.write_text(csv_input(forecast(), E.FORECAST_FIELDS).getvalue(), encoding="utf-8")
            actual_path.write_text(csv_input([glucose(30, 130)], E.GLUCOSE_FIELDS).getvalue(), encoding="utf-8")
            result = subprocess.run([sys.executable, str(Path(E.__file__)), "--forecast-csv", str(forecast_path),
                                     "--glucose-csv", str(actual_path), "--output-json", str(output)],
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertEqual(json.loads(output.read_text())["results"][0]["forecast"]["mae_mgdl"], 0)
            self.assertEqual({x.name for x in directory.iterdir()}, {"forecast.csv", "actual.csv", "report.json"})
            before = actual_path.read_bytes()
            result = subprocess.run([sys.executable, str(Path(E.__file__)), "--forecast-csv", str(forecast_path),
                                     "--glucose-csv", str(actual_path), "--output-json", str(actual_path)],
                                    capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(actual_path.read_bytes(), before)


class PresentationEvaluatorTests(unittest.TestCase):
    def test_schema_two_current_exports_and_mixed_legacy_versions(self):
        v2 = forecast(identity="schema2")
        for row in v2:
            row["schema_version"] = "2"
        unavailable_v2 = unavailable()
        unavailable_v2["schema_version"] = "2"
        report = run(forecast() + v2 + [unavailable_v2] + presentation(), [glucose(30, 135)])
        self.assertEqual(report["availability"][0]["valid_logged_records"], 2)
        self.assertEqual(report["availability"][0]["unavailable_logged_records"], 1)
        self.assertEqual(report["results"][0]["forecast"]["count"], 2)
        self.assertEqual(report["presentation_results"][0]["comparable_presentations"], 1)
        self.assertEqual(report["report_schema_version"], 2)

    def test_known_answers_capped_and_uncapped_at_each_offset(self):
        report = run(presentation(computed=2, presented=4, capped=(30, 120)),
                     [glucose(30, 135), glucose(60, 145), glucose(120, 155)])
        for result, offset, displayed_bias, capped in zip(report["presentation_results"],
                                                        (30, 60, 120), (-5, 5, -5), (1, 0, 1)):
            self.assertEqual(result["offset_minutes"], offset)
            self.assertEqual(result["engine"]["bias_mgdl"], -5)
            self.assertEqual(result["ml"]["bias_mgdl"], 5)
            self.assertEqual(result["displayed"]["bias_mgdl"], displayed_bias)
            for name in ("engine", "ml", "displayed", "unchanged_reference"):
                self.assertEqual(result[name]["count"], 1)
            self.assertEqual(result["low_glucose_cap_applied_points"], capped)
            self.assertEqual(result["low_glucose_cap_applied_comparable_pairs"], capped)
            self.assertEqual(result["actual_lead_minutes_from_computed_at"]["mean"], offset - 2)
            self.assertEqual(result["actual_lead_minutes_from_presented_at"]["mean"], offset - 4)
            self.assertEqual(result["matched_actual_period"]["utc_dates"], 1)
        self.assertEqual(report["availability"], [])
        self.assertEqual(report["results"], [])
        self.assertEqual(report["presentation_results"][0]["unchanged_reference"]["bias_mgdl"], -15)
        self.assertEqual(report["presentation_results"][2]["unchanged_reference"]["bias_mgdl"], -35)

    def test_engine_fallback_is_separate_and_never_zero_ml_error(self):
        report = run(presentation(model=None) + presentation(), [glucose(30, 135)])
        fallback, available = report["presentation_availability"]
        self.assertIsNone(fallback["model_id"])
        self.assertEqual(fallback["ml_unavailable_records"], 1)
        self.assertEqual(fallback["ml_unavailable_reason"], "not_recorded")
        self.assertEqual(available["ml_available_records"], 1)
        result = report["presentation_results"][0]
        self.assertEqual(result["ml_unavailable_points"], 1)
        self.assertEqual(result["comparable_presentations"], 0)
        self.assertEqual(result["engine_fallback"]["comparable_presentations"], 1)
        self.assertEqual(result["engine_fallback"]["engine"]["mae_mgdl"], 5)
        self.assertEqual(result["engine_fallback"]["displayed"]["mae_mgdl"], 5)
        for name in ("engine", "ml", "displayed", "unchanged_reference"):
            self.assertEqual(result[name]["count"], 0)
            self.assertIsNone(result[name]["mae_mgdl"])
        self.assertEqual(report["presentation_results"][3]["comparable_presentations"], 1)

    def test_model_horizon_engine_and_reference_namespaces_are_separate(self):
        predictions = (presentation(model="a", horizon=60) + presentation(model="a") +
                       presentation(model="b", ml_values={30: 135}) + presentation(model="a", engine="older"))
        report = run(predictions, [glucose(30, 135), glucose(60, 145), glucose(120, 155)])
        self.assertEqual(len(report["presentation_availability"]), 4)
        self.assertEqual(len(report["presentation_results"]), 11)
        self.assertTrue(all(item["presentation_records"] == 1 for item in report["presentation_results"]))
        b = next(item for item in report["presentation_results"] if item["model_id"] == "b")
        self.assertEqual(b["ml"]["mae_mgdl"], 0)
        a = next(item for item in report["presentation_results"] if item["model_id"] == "a" and item["engine_version"] == "v2")
        self.assertEqual(a["ml"]["mae_mgdl"], 5)

    def test_all_variants_use_the_same_pairs_and_same_calculation_engine(self):
        good = presentation(identity="good", values={30: 130}, ml_values={30: 140})
        missing_actual = presentation(identity="missing", reference=10, values={30: 500}, ml_values={30: 510})
        missing_point = [row for row in presentation(identity="missing-point", reference=20)
                         if row["offset_minutes"] != "30"]
        report = run(forecast(values={30: 400}) + good + missing_actual + missing_point,
                     [glucose(30, 135), glucose(50, 599)])
        result = report["presentation_results"][0]
        self.assertEqual(result["presentation_records"], 3)
        self.assertEqual(result["missing_followup_measurement"], 1)
        self.assertEqual(result["missing_prediction_point"], 1)
        for name in ("engine", "ml", "displayed", "unchanged_reference"):
            self.assertEqual(result[name]["count"], 1)
        self.assertEqual(result["engine"]["mae_mgdl"], 5)
        self.assertEqual(result["ml"]["mae_mgdl"], 5)
        self.assertEqual(result["unchanged_reference"]["mae_mgdl"], 15)
        self.assertEqual(report["results"][0]["forecast"]["mae_mgdl"], 265)
        self.assertEqual(report["availability"][0]["valid_logged_records"], 1)

    def test_shown_late_is_retrospective_and_cap_counts_remain_visible(self):
        report = run(presentation(presented=30, capped=(30,)), [glucose(30, 135), glucose(60, 145)])
        result = report["presentation_results"][0]
        self.assertEqual(result["target_not_after_presented_at"], 1)
        self.assertEqual(result["comparable_presentations"], 0)
        self.assertIsNone(result["ml"]["mae_mgdl"])
        self.assertEqual(result["low_glucose_cap_applied_points"], 1)
        self.assertEqual(result["low_glucose_cap_applied_comparable_pairs"], 0)
        self.assertEqual(report["presentation_results"][1]["comparable_presentations"], 1)

    def test_matched_actual_must_be_strictly_future_at_computation_and_presentation(self):
        for computed, presented, failure in [(29, 29, "matched_actual_not_after_computed_at"),
                                             (0, 29, "matched_actual_not_after_presented_at")]:
            with self.subTest(failure=failure):
                result = run(presentation(computed=computed, presented=presented),
                             [glucose(29, 135)])["presentation_results"][0]
                self.assertEqual(result[failure], 1)
                self.assertEqual(result["comparable_presentations"], 0)
        result = run(presentation(computed=30, presented=31), [glucose(30, 135)])["presentation_results"][0]
        self.assertEqual(result["target_not_after_computed_at"], 1)

    def test_target_and_actual_leads_are_distinct_for_off_target_matches(self):
        result = run(presentation(computed=4, presented=7), [glucose(29, 135)])["presentation_results"][0]
        self.assertEqual(result["target_lead_minutes_from_computed_at"]["mean"], 26)
        self.assertEqual(result["target_lead_minutes_from_presented_at"]["mean"], 23)
        self.assertEqual(result["actual_lead_minutes_from_computed_at"]["mean"], 25)
        self.assertEqual(result["actual_lead_minutes_from_presented_at"]["mean"], 22)

    def test_presentation_matching_preserves_tolerance_and_earlier_tie(self):
        results = run(presentation(), [glucose(27.5, 135), glucose(32.5, 599), glucose(62.5, 145),
                                       glucose(122.501, 155)])["presentation_results"]
        self.assertEqual(results[0]["ml"]["mae_mgdl"], 5)
        self.assertEqual(results[0]["matched_actual_offset_seconds_from_target"]["mean"], -150)
        self.assertEqual(results[1]["comparable_presentations"], 1)
        self.assertEqual(results[2]["missing_followup_measurement"], 1)
        self.assertIsNone(results[2]["engine"]["mae_mgdl"])

    def test_presentation_source_sensor_matching_and_deduplication_scope(self):
        predictions = (presentation() + presentation(sensor="sensor-b") + presentation(source="remote"))
        report = run(predictions, [glucose(30, 135), glucose(30, 140, sensor="sensor-b")])
        result = report["presentation_results"][0]
        self.assertEqual(result["presentation_records"], 3)
        self.assertEqual(result["comparable_presentations"], 2)
        self.assertEqual(result["missing_followup_measurement"], 1)
        self.assertEqual(result["ml"]["mae_mgdl"], 2.5)
        blank = run(presentation(sensor=""), [glucose(30, 135)])["presentation_results"][0]
        self.assertEqual(blank["missing_source_or_sensor_identity"], 1)

    def test_duplicate_presentation_exports_do_not_double_count(self):
        original = presentation()
        report = run(original + original + forecast() + forecast(), [glucose(30, 135)])
        self.assertEqual(report["duplicate_presentation_point_rows_ignored"], len(original))
        self.assertEqual(report["duplicate_forecast_point_rows_ignored"], len(original))
        self.assertEqual(report["presentation_results"][0]["comparable_presentations"], 1)
        self.assertEqual(report["results"][0]["comparable_forecasts"], 1)

    def test_rejects_missing_ml_model_display_cap_and_inconsistent_caps(self):
        changes = [{"ml_prediction_mgdl": ""}, {"model_id": ""}, {"displayed_prediction_mgdl": ""},
                   {"low_glucose_cap_applied": ""}, {"low_glucose_cap_applied": "yes"},
                   {"low_glucose_cap_applied": "true"}, {"displayed_prediction_mgdl": "130"},
                   {"ml_prediction_mgdl": "nan"}, {"ml_prediction_mgdl": "601"},
                   {"displayed_prediction_mgdl": "19"}, {"presented_at_utc": ""},
                   {"presented_at_utc": timestamp(-1)}, {"schema_version": "2"}]
        for change in changes:
            with self.subTest(change=change):
                predictions = presentation()
                predictions[0].update(change)
                with self.assertRaises(E.InputError):
                    run(predictions, [])
        predictions = presentation(capped=(30,))
        predictions[6]["displayed_prediction_mgdl"] = "129"
        with self.assertRaises(E.InputError):
            run(predictions, [])

    def test_presentation_reference_point_must_be_unchanged_in_every_variant(self):
        for capped in ((), (0,)):
            with self.subTest(capped=capped):
                predictions = presentation(ml_values={0: 121}, capped=capped)
                with self.assertRaisesRegex(E.InputError, "offset zero"):
                    run(predictions, [])

    def test_global_time_span_includes_presentation_only_exports(self):
        report = run(presentation(computed=3, presented=4), [])
        self.assertEqual(report["logged_time_span"]["first_computed_at_utc"], E.utc(timestamp(3), "test").isoformat())
        self.assertEqual(report["logged_time_span"]["utc_dates_with_records"], 1)
        self.assertEqual(report["availability"], [])
        self.assertEqual(report["results"], [])

    def test_rejects_inconsistent_fallback_and_fields_on_legacy(self):
        for change in [{"ml_prediction_mgdl": "120"}, {"low_glucose_cap_applied": "false"},
                       {"displayed_prediction_mgdl": "121"}]:
            with self.subTest(change=change):
                predictions = presentation(model=None)
                predictions[0].update(change)
                with self.assertRaises(E.InputError):
                    run(predictions, [])
        predictions = forecast()
        predictions[0]["model_id"] = "unexpected-model"
        with self.assertRaises(E.InputError):
            run(predictions, [])

    def test_rejects_conflicting_immutable_presentation_metadata_and_points(self):
        for changed in [presentation(computed=1), presentation(presented=1),
                        presentation(values={30: 131}), presentation(ml_values={30: 141})]:
            with self.assertRaises(E.InputError):
                run(presentation() + changed, [])
        predictions = presentation()
        for row in predictions:
            row["app_build"] = "4340"
        predictions[3]["app_build"] = "4341"
        with self.assertRaisesRegex(E.InputError, "metadata"):
            run(predictions, [])

    def test_rejects_schema_three_presentation_with_old_header(self):
        predictions = forecast()
        for row in predictions:
            row.update(schema_version="3", record_type="presentation")
        with self.assertRaisesRegex(E.InputError, "columns"):
            run(predictions, [])

    def test_model_identity_unicode_quoting_and_nulls_survive_json(self):
        model = 'ML, "model"\næøå'
        report = run(presentation(model=model) + presentation(model=None), [])
        self.assertEqual(report["presentation_availability"][1]["model_id"], model)
        result = report["presentation_results"][3]
        self.assertEqual(result["missing_followup_measurement"], 1)
        self.assertIsNone(result["ml"]["mae_mgdl"])
        self.assertIsNone(result["matched_actual_period"]["first_utc"])
        self.assertEqual(json.loads(json.dumps(report, allow_nan=False, ensure_ascii=False)), report)

    def test_periods_report_only_retained_and_comparable_records(self):
        report = run(presentation(identity="first") + presentation(identity="next-day", reference=1440),
                     [glucose(30, 135)])
        availability = report["presentation_availability"][0]
        self.assertEqual(availability["computed_period"]["utc_dates"], 2)
        self.assertEqual(availability["presented_period"]["utc_dates"], 2)
        result = report["presentation_results"][0]
        self.assertEqual(result["comparable_presented_period"]["utc_dates"], 1)
        self.assertEqual(result["matched_actual_period"]["utc_dates"], 1)
        self.assertEqual(result["missing_followup_measurement"], 1)

    def test_cli_reads_schema_three_and_writes_null_metrics(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            forecast_path = directory / "forecast.csv"
            actual_path = directory / "actual.csv"
            forecast_path.write_text(csv_input(presentation(model=None), E.FORECAST_FIELDS | E.PRESENTATION_FIELDS).getvalue(),
                                     encoding="utf-8")
            actual_path.write_text(csv_input([glucose(30, 135)], E.GLUCOSE_FIELDS).getvalue(), encoding="utf-8")
            result = subprocess.run([sys.executable, "-B", str(Path(E.__file__)), "--forecast-csv", str(forecast_path),
                                     "--glucose-csv", str(actual_path)], capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            self.assertIsNone(report["presentation_results"][0]["ml"]["mae_mgdl"])
            self.assertEqual(report["presentation_results"][0]["engine_fallback"]["engine"]["mae_mgdl"], 5)


if __name__ == "__main__":
    unittest.main()
