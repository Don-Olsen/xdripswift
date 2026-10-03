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
    return E.evaluate(csv_input(predictions, E.FORECAST_FIELDS), csv_input(actuals, E.GLUCOSE_FIELDS))


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
        for change in [{"computed_at_utc": "2026-10-03T12:00:00"}, {"schema_version": "2"},
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


if __name__ == "__main__":
    unittest.main()
