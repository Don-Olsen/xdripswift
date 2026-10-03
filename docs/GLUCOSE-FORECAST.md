# Local glucose forecast

The iPhone Home chart can show a separate, dotted estimate for the next 60 minutes, or 120 minutes when selected. Set **Settings → Home Screen → Glucose forecast** to Off to hide it. The values at +30 and +60 minutes (+120 when selected) are estimates, never sensor readings. The 120-minute horizon is more uncertain. The calculation assumes no new, unrecorded food or insulin after its starting reading. It does not provide a dose recommendation.

The forecast is display-only. Its points are never saved as BG readings, used for statistics or alerts, sent to Nightscout or Apple Health, or sent to Watch. Watch sensor ownership, Bluetooth recovery, workout runtime and alarm rules are unchanged. It uses existing event-driven Home updates and adds no polling or keepalive timer.

## Home presentation during reloads

The live Home graph reserves the selected 60/120-minute future span independently
of whether a forecast is ready. A foreground refresh or a temporary unavailable
result therefore does not collapse and re-expand the time axis of glucose,
treatments and IOB/COB curves. Turning the forecast off, viewing history or using
the night layout removes this reservation. Compact/Watch/widget charts do not
opt into it. An empty reserved area is not a prediction: the existing freshness,
sensor, treatment and settings checks still decide whether forecast points can
be drawn. HealthKit synchronization can briefly make treatment inputs incomplete
on reentry; the estimate can remain hidden until that check succeeds. This change
does not change forecasting, import behavior or its availability log.

The local follow-up to 4289 passed 1,184/1,184 XCTest tests, all Python checks
and both simulator builds on 2026-10-03. The new presentation regression tests
cover 60/120-minute loading/valid/unavailable transitions and the off/history/
non-main exclusions. Device logs establish transient input unavailability, but
physical observation of the corrected UI still requires a separately authorized
release. This follow-up has not been uploaded or installed on the user's devices.

## Follow-up to 4290: foreground reload presentation

The iPhone was read over the paired network connection and confirmed on 4290.
Its retained log contained a `dataUnavailable` result followed by a valid result
for the same reading 504 ms later. The app-start entries place this evidence at
startup; the log alone is not a recording of every warm-foreground render.
The values in this sample did not require a larger glucose axis. Consequently,
axis retention alone does not explain every reported disappearing curve.

The local follow-up separates a refresh request from an actual input revision.
Only a specifically identified read of previously complete Health inputs may
retain the last dated forecast for at most two seconds, marked **Updating…** with numeric
forecast summaries hidden. This is a bounded presentation state, never a new
valid prediction or a valid evidence-log record. Generic unavailable results,
changed treatments/settings/sources, pending saves and mismatched glucose or
sensor identities do not qualify. The normal input and freshness guards remain.
A writer commit confirms only the input generation captured when that save
began; newer child/main mutations remain pending. No previous forecast is
loaded from disk to conceal a cold-start data check.

Separately, the live chart retains overlay extrema and the common therapy scale
while curves reload. It retains geometry, not uncertain treatment points.
Disabling overlays, changing the visible range, explicit reset, history mode
or viewport expiry clears the relevant geometry; a new valid result supplies
its own extrema. Compact and Watch charts retain their existing behavior.

The forecast engine, imported treatment selection, sensor transport, Watch
runtime, alarms and evidence-log schema are unchanged. A one-shot expiry for
the short presentation state is not polling or a background forecast. Actual
validation and physical-check limitations are recorded in PROJECT-STATUS.md.

## Inputs and setup

The calculation starts from the newest downstream-valid CGM reading and a continuous recent history from the same sensor/source. Old readings, gaps, invalid samples, incomplete treatment imports or a pending treatment save make the forecast unavailable; missing data is never treated as zero.

Bolus and carbohydrate inputs come through the existing TherapyMetricsManager treatment selection. This preserves the selected HealthKit import source, Watch treatments once saved on iPhone, exact external identities, corrections, deletions and existing source precedence. Basal insulin recorded as a basal injection, including Tresiba, is not processed as a rapid-acting bolus; Watch now distinguishes **Bolus (hurtigtvirkende)** from **Basal (langtidsvirkende)**. Basal entries accept whole positive units up to the existing 200 U limit, without rounding; bolus still allows fractions. A basal entry is stored as `BasalInjection` and is excluded from bolus, IOB, COB and forecast inputs. The existing local-only durable receipt and UUID deduplication rules still apply. Older apps that cannot decode a new treatment type reject it without a saved receipt; Watch preserves the pending entry and shows that both apps need updating. Unknown persisted types leave the queue file intact and block new writes until a compatible version can read it. If Nightscout AID or CareLink owns an IOB/COB metric, the forecast does not silently substitute local treatment history. When Nightscout treatment import and HealthKit insulin/carbohydrate import are simultaneously enabled, their unrelated IDs cannot reliably prove that one dose has not been imported twice. The forecast is unavailable in that configuration rather than risking a double-counted dose. A treatment recorded after the last CGM measurement temporarily makes the estimate unavailable until a newer CGM reading anchors it.

Enter your own insulin sensitivity (ISF) and carbohydrate ratio in Home Screen settings. ISF is shown in the selected glucose unit and stored internally in mg/dL per unit; carbohydrate ratio is grams per unit. The manual pair is assumed constant over the forecast window; it does not represent a time-of-day profile. No personal value is inferred or supplied by the app. An incomplete pair prevents a forecast. Existing saved Nightscout profile snapshots cannot prove that their declared default profile was the one actually imported, because the profile importer historically allowed a fallback to an arbitrary store entry. This release therefore does not automatically use those snapshots as forecast settings. It does not request new HealthKit types or permissions; the existing optional insulin/carbohydrate import remains configured separately in Apple Health settings.

## Model and limits

The local calculation is a small Swift adaptation of the *principles* in [LoopKit's prediction code at commit 1b09bddd22bd91fb81e4b074f7638bc9e987246e](https://github.com/LoopKit/LoopKit/tree/1b09bddd22bd91fb81e4b074f7638bc9e987246e), especially date-aligned treatment effects and short glucose momentum. The previous retrospective discrepancy contribution is explicitly disabled in this candidate. It is not a verbatim port of the full LoopKit algorithm and does not include its pump basal, zero-temp or dynamic carbohydrate absorption model. The [LoopKit MIT license](https://github.com/LoopKit/LoopKit/blob/1b09bddd22bd91fb81e4b074f7638bc9e987246e/LICENSE) and the existing xDrip therapy-model source notices apply to reused model formulas.

For each five-minute point, bolus and carbohydrate effects are the difference between the existing selected treatment curves at that point and at the latest CGM reading. Thus current IOB/COB is not multiplied by a constant. The recent measured glucose trajectory is adjusted for already modeled treatment effects before its residual trend is estimated from actual sample times. The 15-minute regression window (at least four readings spanning ten minutes, with the existing 30-second cadence tolerance) is independent from the new ten-minute momentum decay. Five-minute midpoint integration uses weights 0.75 and 0.25; after +10 minutes the accumulated residual contribution stays constant while treatment effects continue. A residual slope of +2 mg/dL/min therefore contributes +10 mg/dL by +10 minutes; the equivalent fall contributes −10 mg/dL. `correctionRate` is still calculated, but the shared compile-time configuration explicitly sets `correctionContributionEnabled = false` and `correctionWeight = 0`. There is no active 60-minute residual correction and no division by a zero correction duration. The overall history still needs six samples over at least 25 minutes within its 30-minute window; the existing freshness and maximum-gap limits remain 330 seconds. Values outside 20–600 mg/dL cause rejection, not clipping. The 60/120-minute horizon is unchanged. `GlucoseForecastEngine.configuration` is the single source of the constants used by both the engine and evidence log; the engine version is `local-residual-momentum10-v2`. The selected Fiasp/other insulin peak, ten-hour duration of insulin action and selected carbohydrate absorption duration remain unchanged.

The model assumes stable unmodeled background glucose/long-acting basal action. Missed or changed Tresiba, exercise, illness, stress, sensor lag and new food or insulin can invalidate that assumption. The forecast is exploratory until prospective device data establishes its error and coverage. No claim of Trio-equivalent accuracy is made.

## Validation boundary

Unit tests cover model curves, timing, units, stale and gapped data, treatment selection, source ownership and missing settings. Real-world accuracy must be assessed at +30, +60 and +120 minutes separately against measured glucose, an unchanged-value baseline and a simple short trend. Inputs must be frozen at prediction time; later meals, insulin, corrections and changed settings must be reported separately. Historical xDrip treatment rows do not consistently retain a “known to the app at this time” timestamp, so a retrospective replay cannot prove that it avoided future information. Prospective snapshots or an external dataset with that provenance are needed before reporting comparative accuracy.

Future extensions may evaluate proven profile provenance, activity, heart rate, sleep and medication effects. The Watch workout that keeps the sensor connection alive must not be interpreted as exercise.


## Prospective evidence log and export

A completed calculation supplies an immutable value snapshot to a separate serial IO worker. It never sends Core Data objects between queues or rereads settings while writing. Rendering does not wait for disk IO. No new forecast timer or background calculation is introduced. Off means no forecast attempt is logged; cache hits do not create records.

Daily JSON Lines files live in **Application Support/GlucoseForecastLog**. The first valid result for each source/reference identity, configured horizon and engine version is retained unchanged, including across restarts and later setting changes. The UI still recomputes normally when its inputs change. Unavailable results have a separate record type and reason; they cannot block a later valid result. Identical failures are throttled to one per reference/reason/horizon/engine in a ten-minute UTC bucket. Unknown reference dates stay null, and unknown parameters/treatment counts are not zero.

Snapshots include app/schema/engine versions; stable source, sensor and reference identities; reference and completion times; every five-minute prediction in mg/dL; ISF, carbohydrate ratio and selected model/durations; the engine's actual constants; treatment-window bounds and bolus/carbohydrate counts and sums; exact value-based calculation inputs; and their SHA-256 fingerprint. The fingerprint is diagnostic, not an anonymization guarantee. Source identity currently uses `sensor:<sensorID>` from the existing adapter; actual-glucose data must use this same identity and the exact sensor ID.

Retention keeps at most **400 UTC calendar days** (today and the preceding 399 days). Cleanup runs on the worker once per day when logging or exporting; it reads directory metadata, not the entire history. At most two daily deduplication indexes are retained in memory. A partial last line can be recovered without damaging previous complete lines. File failures report only a fixed diagnostic category, without health data, and do not fail the forecast or glucose UI. Unknown/corrupt complete records remain in the original file and are diagnosed when skipped during CSV export.

Files use iOS `completeUntilFirstUserAuthentication` protection and are explicitly included in normal device backup, subject to the user's device backup settings. They are not added to xDrip's separate application-specific backup format. No automatic transmission to HealthKit, Nightscout, Watch, network or Git occurs. Restoring via normal device backup needs physical verification; unit tests cannot prove an actual iCloud/device restore.

Use **Settings → Home Screen → Eksportér prognoselog / Export forecast log**. Export streams a separate UTF-8 CSV copy to the system share sheet. It does not rename JSONL. Source files stay local; a destination is selected by the user. Temporary CSV copies older than 24 hours are pruned on the next explicit export, not by a new timer.

### CSV schema 1

The stable header is:

```csv
schema_version,record_type,engine_version,app_version,app_build,source_identity,sensor_identity,reference_identity,reference_date_utc,computed_at_utc,horizon_minutes,reference_glucose_mgdl,offset_minutes,prediction_mgdl,reason,isf_mgdl_per_unit,carb_ratio_grams_per_unit,insulin_model,insulin_peak_minutes,insulin_duration_minutes,carb_duration_minutes,treatment_window_start_utc,treatment_window_end_utc,bolus_count,bolus_units,carb_count,carb_grams,input_fingerprint,engine_constants_json
```

A valid forecast has one row per point, including offset zero, with repeated snapshot metadata. `horizon_minutes` is the configured 60/120-minute horizon; `offset_minutes` is that row's displacement from `reference_date_utc`. Unavailable records have one row with a reason and blank point fields. Missing values are empty cells, never substituted zero. Dates are ISO 8601 UTC with millisecond precision and `Z`; numeric values use a decimal point independent of device locale. Commas, quotes and CR/LF are quoted/escaped, with CRLF row endings. Constants are a properly escaped JSON cell. JSONL additionally retains the detailed input samples/treatments; the CSV carries their fingerprint and summaries.

## Local evaluation

Run locally, without network access:

```sh
python3 -B scripts/evaluate-glucose-forecast.py \
  --forecast-csv forecast.csv --glucose-csv actual-glucose.csv \
  --output-json forecast-report.json
```

The UTF-8 actual-glucose CSV must contain:

```csv
date_utc,glucose_mgdl,source_identity,sensor_identity
```

All actuals are measured glucose in mg/dL, with explicit UTC times and the exact matching source/sensor identities. Do not assign a new sensor's readings to an older sensor. Invalid/nonfinite/out-of-range actuals and conflicting values at the same source/sensor/time are counted and excluded.

The evaluator assesses +30, +60 and +120 separately, grouped by engine version and configured horizon. Target time is **referenceDate + offset**, not computedAt + offset. It reports the actual remaining lead time from `computedAt`, and excludes points whose target or matched actual was already past at completion. Matching is nearest valid measured glucose within ±150 seconds; ties use the earlier measurement. There is no interpolation and no matching across sensor identities. Forecast and unchanged-reference baseline use exactly the same matched pair.

Reports include comparable counts, MAE, signed bias (positive means overprediction), errors at least 3 mmol/L, matching/lead-time distributions, missing reference/sensor information, missing subsequent measurements, missing forecast points and unavailable reasons. Conversion follows the app's existing 18.01801801801802 mg/dL per mmol/L. Units are explicit. The tool does not tune personal settings or suggest doses.

**Availability is limited to retained records:** first-valid deduplication and error throttling mean the CSV cannot count every Home calculation attempt. It reports valid versus unavailable retained records, not a percentage of all daily sensor minutes. Home-based logging does not establish continuous full-day coverage. It cannot identify later meals/insulin without separate event data, so prospective accuracy must be interpreted with that limitation.

## Evidence for this candidate

The user supplied an external replay of 4286 (217 days; 64,091 predictions) reporting +30/+60/+120 MAE 0.90/1.45/2.04 mmol/L for 4286, 0.82/1.28/1.79 for unchanged glucose, and 0.77/1.24/1.76 for disabled correction, ten-minute decay and user-selected personal settings. The replay code/data are **not in this repository and these numbers have not been reproduced here**. Their stated separate tuning/test periods and input-availability rules are externally reported provenance, not independently verified findings. The small reported +120-minute difference does not prove future or universal accuracy.

Software tests verify calculations, guards, Watch treatment semantics, logging and evaluator mechanics. They do not establish clinical or real-world predictive accuracy. No personal ISF, ratio, insulin preset or absorption time from the external analysis is hardcoded, automatically changed or made a default. Forward validation must use newly collected frozen snapshots and subsequent measured glucose. Physical follow-up includes basal confirmation/receipt on both devices (including an older paired version), export/share, persistence after restart/restore, and the existing Home forecast visibility behavior. The implementation itself did not authorize release/upload. The subsequent explicit user upload request on 2026-10-03 authorizes the internal TestFlight process, with a newly selected build number and fresh validation of its exact release tree. See PROJECT-STATUS.md for actual release status.


## Software validation for the unreleased candidate

On 2026-10-03, the final local `scripts/local-build.sh release-test` run passed
**1,182/1,182 XCTest tests** (zero failures/skips), **157 Python tests** and
**54 synthetic self-checks**. Both unsigned iPhone and Watch simulator builds
passed with Xcode 27.0 (27A266a). This includes 17 log tests, eight Watch basal
tests and 18 evaluator tests, as well as the existing suite. A real Swift CSV
was also read by the Python evaluator against synthetic known-answer glucose.
These are software results, not reproduced external replay or patient accuracy.

Evidence is in
`~/DeveloperBuildData/xDrip/local-runs/xdripswift/20261003T171157Z-47158/`.
The tested candidate consists of local changes above HEAD
`bbfc66803033dd2e063954d3dd277ba0d7a6b1c7`; the source manifest records their
hashes. `docs/PROJECT-STATUS.md` records the scope and remaining physical checks.
iOS hardware file-protection behavior and real device backup/restore cannot be
proven by CoreSimulator; the configured protection class and backup flags are
tested. No upload or installation on a physical device was performed.
