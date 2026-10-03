#!/usr/bin/env python3
"""Offline prospective forecast evaluation. Never downloads data or changes app data.

Inputs (UTF-8 CSV, RFC 4180 quoting):
  forecast: xDrip Home Screen > Export forecast log, schema_version=1.
  glucose: date_utc,glucose_mgdl,source_identity,sensor_identity
Timestamps must be ISO 8601 UTC (Z or +00:00); glucose must be mg/dL.
Source and sensor identities must match the forecast export exactly. Blank sensor
identity cannot establish a match and is reported, never combined across sensors.

For each +30/+60/+120 point, target = referenceDate + offset. Compare forecast
and unchanged-reference baseline with the SAME nearest valid actual reading
within +/-150 seconds of target. Equal-distance ties use the earlier reading.
No interpolation. Actuals outside 20..600 mg/dL or nonfinite are excluded and
reported. Conflicting actual values at one source/sensor/time are all excluded.
Target and matched actual must both be strictly after computedAt; otherwise the
point is reported as retrospective, never scored as a future forecast.

Positive bias means overprediction; a large error is >=3 mmol/L (using the
app's conversion 18.01801801801802 mg/dL per mmol/L). Separate results by engine,
configured horizon, and evaluated offset. Availability describes retained logged
records, not all Home refreshes or continuous day coverage. The logger preserves
one first valid result and throttles identical unavailable records; this export
cannot reconstruct every calculation attempt, later meals, or later insulin.
"""
from __future__ import annotations

import argparse
import bisect
import csv
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
import json
import math
from pathlib import Path
import statistics
from typing import TextIO

MGDL_PER_MMOLL = 18.01801801801802
MATCH_TOLERANCE_SECONDS = 150
LARGE_ERROR_MMOLL = 3.0
EVALUATION_OFFSETS = (30, 60, 120)
FORECAST_FIELDS = {
    "schema_version", "record_type", "engine_version", "source_identity", "sensor_identity",
    "reference_identity", "reference_date_utc", "computed_at_utc", "horizon_minutes",
    "reference_glucose_mgdl", "offset_minutes", "prediction_mgdl", "reason",
}
GLUCOSE_FIELDS = {"date_utc", "glucose_mgdl", "source_identity", "sensor_identity"}


class InputError(ValueError):
    pass


def utc(value: str, field_name: str) -> datetime:
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if result.tzinfo is None or result.utcoffset() != timedelta(0):
            raise ValueError("not UTC")
        return result.astimezone(timezone.utc)
    except (ValueError, TypeError) as exc:
        raise InputError(f"{field_name} must be an explicit ISO 8601 UTC timestamp") from exc


def number(value: str, field_name: str) -> float:
    try:
        result = float(value)
        if not math.isfinite(result):
            raise ValueError("not finite")
        return result
    except (ValueError, TypeError) as exc:
        raise InputError(f"{field_name} must contain a finite number") from exc


def integer(value: str, field_name: str) -> int:
    value_float = number(value, field_name)
    if not value_float.is_integer():
        raise InputError(f"{field_name} must be an integer")
    return int(value_float)


def rows(handle: TextIO, required: set[str]):
    reader = csv.DictReader(handle)
    if reader.fieldnames is None or not required.issubset(reader.fieldnames):
        raise InputError("Missing CSV columns: " + ", ".join(sorted(required - set(reader.fieldnames or []))))
    if len(reader.fieldnames) != len(set(reader.fieldnames)):
        raise InputError("Duplicate CSV column names")
    for row in reader:
        if None in row or any(value is None for value in row.values()):
            raise InputError(f"CSV line {reader.line_num} has an incorrect column count")
        yield row


@dataclass
class Forecast:
    engine: str
    horizon: int
    reference_identity: str
    source: str
    sensor: str
    reference: datetime
    computed: datetime
    glucose: float
    points: dict[int, float] = field(default_factory=dict)


def read_forecasts(handle: TextIO):
    forecasts: dict[tuple, Forecast] = {}
    unavailable: dict[tuple, dict] = {}
    duplicate_point_rows = 0
    for row in rows(handle, FORECAST_FIELDS):
        if row["schema_version"] != "1":
            raise InputError("Unsupported forecast schema_version")
        engine = row["engine_version"]
        if not engine:
            raise InputError("engine_version is missing")
        horizon = integer(row["horizon_minutes"], "horizon_minutes")
        computed = utc(row["computed_at_utc"], "computed_at_utc")
        source, sensor = row["source_identity"], row["sensor_identity"]
        identity = row["reference_identity"]
        reference = utc(row["reference_date_utc"], "reference_date_utc") if row["reference_date_utc"] else None
        if row["record_type"] == "unavailable":
            if not row["reason"] or row["prediction_mgdl"] or row["offset_minutes"]:
                raise InputError("Unavailable record needs a reason and no prediction point")
            key = (engine, horizon, identity, source, sensor, reference, computed, row["reason"])
            unavailable[key] = {"engine": engine, "horizon": horizon, "reason": row["reason"],
                                "computed": computed, "reference": reference}
            continue
        if row["record_type"] != "forecast":
            raise InputError("Unknown record_type")
        if horizon not in (60, 120):
            raise InputError("Valid forecast horizon_minutes must be 60 or 120")
        if reference is None or not identity or row["reason"]:
            raise InputError("Forecast needs reference identity/date and no unavailable reason")
        if reference > computed:
            raise InputError("Forecast reference date cannot be after computed_at_utc")
        glucose = number(row["reference_glucose_mgdl"], "reference_glucose_mgdl")
        prediction = number(row["prediction_mgdl"], "prediction_mgdl")
        if not 20 <= glucose <= 600 or not 20 <= prediction <= 600:
            raise InputError("Forecast glucose outside 20..600 mg/dL")
        offset = integer(row["offset_minutes"], "offset_minutes")
        if offset < 0 or offset > horizon or offset % 5:
            raise InputError("Prediction offset must be a five-minute point within its horizon")
        key = (engine, horizon, identity)
        candidate = Forecast(engine, horizon, identity, source, sensor, reference, computed, glucose)
        previous = forecasts.get(key)
        if previous is None:
            forecasts[key] = candidate
            previous = candidate
        elif (previous.source, previous.sensor, previous.reference, previous.computed, previous.glucose) != (
                source, sensor, reference, computed, glucose):
            raise InputError("Conflicting immutable forecast metadata for the same reference/horizon/engine")
        if offset in previous.points:
            if previous.points[offset] != prediction:
                raise InputError("Conflicting forecast points for one immutable record")
            duplicate_point_rows += 1
        previous.points[offset] = prediction
    for forecast in forecasts.values():
        if 0 not in forecast.points or forecast.points[0] != forecast.glucose:
            raise InputError("Forecast offset zero must match reference_glucose_mgdl")
    return list(forecasts.values()), list(unavailable.values()), duplicate_point_rows


def read_glucose(handle: TextIO):
    records: dict[tuple, float] = {}
    conflicts: set[tuple] = set()
    counts = {"input_rows": 0, "invalid_rows": 0, "duplicate_rows": 0, "conflicting_timestamps": 0}
    for row in rows(handle, GLUCOSE_FIELDS):
        counts["input_rows"] += 1
        try:
            date = utc(row["date_utc"], "date_utc")
            value = number(row["glucose_mgdl"], "glucose_mgdl")
            if not 20 <= value <= 600 or not row["source_identity"] or not row["sensor_identity"]:
                raise InputError("Invalid glucose or source/sensor identity")
        except InputError:
            counts["invalid_rows"] += 1
            continue
        key = (row["source_identity"], row["sensor_identity"], date)
        if key in conflicts:
            continue
        if key in records:
            if records[key] == value:
                counts["duplicate_rows"] += 1
            else:
                del records[key]
                conflicts.add(key)
            continue
        records[key] = value
    counts["conflicting_timestamps"] = len(conflicts)
    grouped: dict[tuple, list[tuple[datetime, float]]] = {}
    for (source, sensor, date), value in records.items():
        grouped.setdefault((source, sensor), []).append((date, value))
    for values in grouped.values():
        values.sort()
    counts["valid_unique_readings"] = len(records)
    return {key: ([item[0] for item in values], values) for key, values in grouped.items()}, counts


def nearest(actuals, source: str, sensor: str, target: datetime):
    dates, values = actuals.get((source, sensor), ([], []))
    index = bisect.bisect_left(dates, target)
    candidates = values[max(0, index - 1):index + 1]
    if not candidates:
        return None
    result = min(candidates, key=lambda value: (abs((value[0] - target).total_seconds()), value[0]))
    return result if abs((result[0] - target).total_seconds()) <= MATCH_TOLERANCE_SECONDS else None


def distribution(values: list[float]):
    return {"count": len(values), "minimum": min(values) if values else None,
            "mean": statistics.fmean(values) if values else None, "maximum": max(values) if values else None}


def error_metrics(errors: list[float]):
    threshold = LARGE_ERROR_MMOLL * MGDL_PER_MMOLL
    count = len(errors)
    mae = statistics.fmean(abs(value) for value in errors) if errors else None
    bias = statistics.fmean(errors) if errors else None
    large = sum(abs(value) >= threshold for value in errors)
    return {"count": count, "mae_mgdl": mae, "mae_mmoll": mae / MGDL_PER_MMOLL if mae is not None else None,
            "bias_mgdl": bias, "bias_mmoll": bias / MGDL_PER_MMOLL if bias is not None else None,
            "large_error_count": large, "large_error_percent": large / count * 100 if count else None}


def evaluate(forecast_handle: TextIO, glucose_handle: TextIO):
    forecasts, unavailable, duplicate_rows = read_forecasts(forecast_handle)
    actuals, actual_counts = read_glucose(glucose_handle)
    configurations = sorted({(x.engine, x.horizon) for x in forecasts} |
                            {(x["engine"], x["horizon"]) for x in unavailable})
    results, availability = [], []
    for engine, horizon in configurations:
        valid = [x for x in forecasts if x.engine == engine and x.horizon == horizon]
        invalid = [x for x in unavailable if x["engine"] == engine and x["horizon"] == horizon]
        reasons: dict[str, int] = {}
        for record in invalid:
            reasons[record["reason"]] = reasons.get(record["reason"], 0) + 1
        recorded = len(valid) + len(invalid)
        availability.append({"engine_version": engine, "horizon_minutes": horizon,
                             "valid_logged_records": len(valid), "unavailable_logged_records": len(invalid),
                             "unavailable_without_reference": sum(x["reference"] is None for x in invalid),
                             "unavailable_by_reason": reasons,
                             "valid_percent_of_retained_records": len(valid) / recorded * 100 if recorded else None})
        # An unavailable invalidHorizon record is evidence, not a supported
        # prediction configuration. Keep its count/reason above without inventing
        # scored offsets, and do not let it make the entire export unreadable.
        if horizon not in (60, 120):
            continue
        for offset in EVALUATION_OFFSETS:
            if offset > horizon:
                continue
            counts = {"forecast_records": len(valid), "missing_prediction_point": 0,
                      "target_not_after_computed_at": 0, "missing_source_or_sensor_identity": 0,
                      "missing_followup_measurement": 0, "matched_actual_not_after_computed_at": 0}
            errors, baseline_errors, leads, match_offsets = [], [], [], []
            for forecast in valid:
                if offset not in forecast.points:
                    counts["missing_prediction_point"] += 1
                    continue
                try:
                    target = forecast.reference + timedelta(minutes=offset)
                except OverflowError as exc:
                    raise InputError("Forecast target date is outside the supported date range") from exc
                if target <= forecast.computed:
                    counts["target_not_after_computed_at"] += 1
                    continue
                if not forecast.source or not forecast.sensor:
                    counts["missing_source_or_sensor_identity"] += 1
                    continue
                actual = nearest(actuals, forecast.source, forecast.sensor, target)
                if actual is None:
                    counts["missing_followup_measurement"] += 1
                    continue
                if actual[0] <= forecast.computed:
                    counts["matched_actual_not_after_computed_at"] += 1
                    continue
                errors.append(forecast.points[offset] - actual[1])
                baseline_errors.append(forecast.glucose - actual[1])
                leads.append((target - forecast.computed).total_seconds() / 60)
                match_offsets.append((actual[0] - target).total_seconds())
            results.append({"engine_version": engine, "horizon_minutes": horizon, "offset_minutes": offset,
                            **counts, "comparable_forecasts": len(errors),
                            "forecast": error_metrics(errors), "unchanged_reference": error_metrics(baseline_errors),
                            "actual_lead_minutes_from_computed_at": distribution(leads),
                            "matched_actual_offset_seconds_from_target": distribution(match_offsets)})
    times = [x.computed for x in forecasts] + [x["computed"] for x in unavailable]
    return {"report_schema_version": 1, "match_tolerance_seconds": MATCH_TOLERANCE_SECONDS,
            "match_tie_rule": "earlier valid reading", "mgdl_per_mmoll": MGDL_PER_MMOLL,
            "large_absolute_error_threshold_mmoll": LARGE_ERROR_MMOLL,
            "bias_definition": "forecast minus actual; positive means overprediction",
            "duplicate_forecast_point_rows_ignored": duplicate_rows,
            "glucose_input": actual_counts, "availability": availability, "results": results,
            "logged_time_span": {"first_computed_at_utc": min(times).isoformat() if times else None,
                                 "last_computed_at_utc": max(times).isoformat() if times else None,
                                 "utc_dates_with_records": len({x.date() for x in times})},
            "limitations": [
                "Availability counts retained first-valid and throttled unavailable records, not every calculation attempt.",
                "Home-driven forecasts do not establish continuous 24-hour calculation or logging coverage.",
                "No interpolation, sensor mixing, parameter optimization, or dose recommendation is performed.",
                "Later meals, insulin, exercise and treatment corrections are not identified by these two CSV inputs.",
                "Software fixtures and reported external replay results do not establish future real-world accuracy."]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--forecast-csv", type=Path, required=True)
    parser.add_argument("--glucose-csv", type=Path, required=True)
    parser.add_argument("--output-json", type=Path, help="Optional local report; otherwise print summary JSON")
    args = parser.parse_args(argv)
    try:
        if args.output_json:
            for input_path in (args.forecast_csv, args.glucose_csv):
                if args.output_json.resolve() == input_path.resolve() or (
                        args.output_json.exists() and input_path.exists() and args.output_json.samefile(input_path)):
                    raise InputError("Output report must not overwrite either input CSV")
        with args.forecast_csv.open(encoding="utf-8-sig", newline="") as forecast, \
                args.glucose_csv.open(encoding="utf-8-sig", newline="") as glucose:
            report = evaluate(forecast, glucose)
        rendered = json.dumps(report, indent=2, ensure_ascii=False, allow_nan=False) + "\n"
        if args.output_json:
            args.output_json.write_text(rendered, encoding="utf-8")
        else:
            print(rendered, end="")
    except (OSError, InputError, csv.Error) as exc:
        parser.exit(2, f"Forecast evaluation failed: {exc}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
