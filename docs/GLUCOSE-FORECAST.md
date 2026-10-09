# Local glucose forecast

The iPhone Home chart can show a separate, dotted estimate for the next 60 minutes, or 120 minutes when selected. Set **Settings → Home Screen → Glucose forecast** to Off to hide it. The values at +30 and +60 minutes (+120 when selected) are estimates, never sensor readings. The 120-minute horizon is more uncertain. The calculation assumes no new, unrecorded food or insulin after its starting reading. The chart itself does not calculate a dose; the separate, confirmation-gated pen calculator described below does.

Forecast points are never saved as BG readings or sent to Nightscout, Apple Health or Watch. From the post-4294 local-treatment change, the existing engine can also supply a separate bolus safety check and the new optional “Low soon” warning. Neither use writes forecast points as measurements, and ML never supplies the safety check or warning. Watch sensor ownership, Bluetooth recovery and workout runtime are unchanged. These checks use new glucose events, without polling or a keepalive timer.

## Home visual follow-up after 4309

The compact badge shows +30/+60 and, when selected, +120. Its ⓘ button opens
reference time, parameter source and the explanation of the ML band's coverage
at each horizon. The sheet freezes one presentation snapshot at opening;
subsequent readings do not mix newer values into that explanation. An updating
state hides numeric summaries in both the badge and the sheet, as before.
Large text wraps instead of shrinking, and the button has a minimum 44-point
height. Numbers follow the phone's locale; Danish Home labels and insulin
units use Danish text and E/E/t without changing shared therapy payloads.

Only Home's ML band is less prominent, with stronger treatment-label background
contrast. Forecast points, raw band values, validation, freshness, chart
publication and calculation behavior are unchanged. Synthetic simulator
fixtures cover normal text, accessibility3, mmol/L, mg/dL and the information
view. The new UI is not installed or physically verified on iPhone; no speed,
battery or accuracy improvement has been measured. Local validation is recorded
in PROJECT-STATUS.md; release remains a separate task.

## Home presentation during reloads

The live Home graph reserves the selected 60/120-minute future span independently
of whether a forecast is ready. A foreground refresh or a temporary unavailable
result therefore does not collapse and re-expand the time axis of glucose,
treatments and IOB/COB curves. Turning the forecast off, viewing history or using
the night layout removes this reservation. Compact/Watch/widget charts do not
opt into it. An empty reserved area is not a prediction: the existing freshness,
sensor, treatment and settings checks still decide whether forecast points can
be drawn. The historical 4289 behavior still allowed HealthKit synchronization
to make treatment inputs briefly incomplete on reentry. The post-4292 bounded
complete-snapshot rule is described below.

The original local follow-up to 4289 passed 1,184/1,184 XCTest tests, all
Python checks and both simulator builds on 2026-10-03. Its presentation
regression tests cover 60/120-minute loading/valid/unavailable transitions
and the off/history/non-main exclusions. Device logs establish transient
input unavailability; the visual result of the later 4293 fix still requires
direct observation on the user's iPhone.

## Historical follow-up to 4290: foreground reload presentation

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

## Post-4292 foreground treatment and forecast presentation

The older two-second exception above is historical. A routine reread of an
already complete and recent Apple Health import may now retain the last
validated Home display for no more than 30 seconds. The same selected sources
must remain enabled, with no error or ambiguous records. Home keeps the last
complete treatment input snapshot while the import writes pages; the IOB/COB
figures continue to age from that snapshot. Partially imported pages and
uncommitted writes are not treated as a new complete dataset. Once insulin
and carbohydrate imports have both finished and their writes are durable,
the new treatment values and curves can advance together. The forecast is
shown only when it has been recalculated for that complete input generation
and the current glucose chart tail; otherwise it has an explicit unavailable
state rather than overlaying an older estimate. A
reread with no actual treatment change does not clear or rebuild them merely
because HealthKit checked for updates.

A first import, source change, stale prior sync, error, ambiguity, failed
save or reread longer than 30 seconds ends retention and shows the normal
unavailable state. A pending local treatment save retains the prior display
only until its success or failure is known; failure ends the hold. A newer
glucose chart tail can never be overlaid with an older forecast. New sensor
readings and alarms are independent of this presentation rule.

## Inputs and setup

The calculation starts from the newest downstream-valid CGM reading and a continuous recent history from the same sensor/source. Old readings, gaps, invalid samples, incomplete treatment imports or a pending treatment save make the forecast unavailable; missing data is never treated as zero.

Bolus and carbohydrate inputs come through the existing TherapyMetricsManager treatment selection. This preserves the selected HealthKit import source, Watch treatments once saved on iPhone, exact external identities, corrections, deletions and existing source precedence. Basal insulin recorded as a basal injection, including Tresiba, is not processed as a rapid-acting bolus; Watch now distinguishes **Bolus (hurtigtvirkende)** from **Basal (langtidsvirkende)**. Basal entries accept whole positive units up to the existing 200 U limit, without rounding; bolus still allows fractions. A basal entry is stored as `BasalInjection` and is excluded from bolus, IOB, COB and forecast inputs. The existing local-only durable receipt and UUID deduplication rules still apply. Older apps that cannot decode a new treatment type reject it without a saved receipt; Watch preserves the pending entry and shows that both apps need updating. Unknown persisted types leave the queue file intact and block new writes until a compatible version can read it. If Nightscout AID or CareLink owns an IOB/COB metric, the forecast does not silently substitute local treatment history. When Nightscout treatment import and HealthKit insulin/carbohydrate import are simultaneously enabled, their unrelated IDs cannot reliably prove that one dose has not been imported twice. The forecast is unavailable in that configuration rather than risking a double-counted dose. A treatment recorded after the last CGM measurement temporarily makes the estimate unavailable until a newer CGM reading anchors it.

Enter your own insulin sensitivity (ISF) and carbohydrate ratio in Home Screen settings. ISF is shown in the selected glucose unit and stored internally in mg/dL per unit; carbohydrate ratio is grams per unit. The manual pair is assumed constant over the forecast window; it does not represent a time-of-day profile. No personal value is inferred or supplied by the app. An incomplete pair prevents a forecast. Existing saved Nightscout profile snapshots cannot prove that their declared default profile was the one actually imported, because the profile importer historically allowed a fallback to an arbitrary store entry. This release therefore does not automatically use those snapshots as forecast settings. The deterministic engine requests no new HealthKit access; optional personal ML training additionally requests read access to historical blood glucose. The existing insulin/carbohydrate import remains configured separately in Apple Health settings.

## Model and limits

The local calculation is a small Swift adaptation of the *principles* in [LoopKit's prediction code at commit 1b09bddd22bd91fb81e4b074f7638bc9e987246e](https://github.com/LoopKit/LoopKit/tree/1b09bddd22bd91fb81e4b074f7638bc9e987246e), especially date-aligned treatment effects and short glucose momentum. The previous retrospective discrepancy contribution is explicitly disabled in this candidate. It is not a verbatim port of the full LoopKit algorithm and does not include its pump basal, zero-temp or dynamic carbohydrate absorption model. The [LoopKit MIT license](https://github.com/LoopKit/LoopKit/blob/1b09bddd22bd91fb81e4b074f7638bc9e987246e/LICENSE) and the existing xDrip therapy-model source notices apply to reused model formulas.

For each five-minute point, bolus and carbohydrate effects are the difference between the existing selected treatment curves at that point and at the latest CGM reading. Thus current IOB/COB is not multiplied by a constant. The recent measured glucose trajectory is adjusted for already modeled treatment effects before its residual trend is estimated from actual sample times. The 15-minute regression window (at least four readings spanning ten minutes, with the existing 30-second cadence tolerance) is independent from the new ten-minute momentum decay. Five-minute midpoint integration uses weights 0.75 and 0.25; after +10 minutes the accumulated residual contribution stays constant while treatment effects continue. A residual slope of +2 mg/dL/min therefore contributes +10 mg/dL by +10 minutes; the equivalent fall contributes −10 mg/dL. `correctionRate` is still calculated, but the shared compile-time configuration explicitly sets `correctionContributionEnabled = false` and `correctionWeight = 0`. There is no active 60-minute residual correction and no division by a zero correction duration. The overall history still needs six samples over at least 25 minutes within its 30-minute window; the existing freshness and maximum-gap limits remain 330 seconds. Values outside 20–600 mg/dL cause rejection, not clipping. The 60/120-minute horizon is unchanged. `GlucoseForecastEngine.configuration` is the single source of the constants used by both the engine and evidence log; the post-4294 engine version is `local-residual-momentum10-mealduration-v3`. The selected Fiasp/other insulin peak and insulin-action duration remain unchanged. Each confirmed carbohydrate entry can now supply its selected absorption duration; legacy entries use the normal four-hour duration.

The model assumes stable unmodeled background glucose/long-acting basal action. Missed or changed Tresiba, exercise, illness, stress, sensor lag and new food or insulin can invalidate that assumption. The forecast is exploratory until prospective device data establishes its error and coverage. No claim of Trio-equivalent accuracy is made.

## Personal ML model and corrected historical inputs in 4293

This local candidate keeps the existing Swift forecast engine authoritative. When a
validated device-local model is compatible with the current treatment sources and
therapy settings, it adds a bounded correction to each existing five-minute engine
point; otherwise the complete engine forecast remains visible. The engine's stored
points and its prospective baseline log are unchanged. ML never creates a
forecast when the engine has rejected its inputs. It does not write measured
glucose, therapy, alarms, HealthKit, Nightscout or Watch data. There is no model
import, Mac training pipeline, background polling or dose advice.

After 4292, training can read up to 365 days of xDrip glucose history directly
from Apple Health, in memory and read-only. Sources are discovered by an
"xDrip" name match and their bundle identifiers are frozen for the run;
identical same-time readings are deduplicated and conflicting same-time
readings are excluded. A source switch or a gap above the forecast engine's
limit divides replay into deterministic segments. A segment identity is
training provenance, not a physical sensor ID. Sensor changes without a
recorded source/gap cannot always be detected. Treatment history comes from
the selected Health insulin and carbohydrate sources, with insulin restricted
to explicitly classified boluses. Basal and unclassified insulin never become
bolus features. The first training attempt requests Health blood-glucose
**read** access; no new Health write access is requested. HealthKit does not
reveal read authorization, so an empty response is treated as missing data,
not as proof of denial or of zero treatments. The loader then tries the app's
own history under the same coverage rules. An explicit HealthKit query error or
timeout now stops history preparation instead of silently treating that source
as empty. A successful but empty read remains unknown, so local fallback still
requires its own complete evidence. The ML status shows the requested window,
raw per-source read counts/date spans and treatment-coverage gaps to distinguish
these cases on a later device run; it does not expose glucose or dose values.
The newest preparation result takes precedence over any older training error
in Settings; a prior failure can no longer mask a new read outcome.

Every historical example requires continuous glucose and separately proven
insulin and carbohydrate coverage for its whole treatment window. A day
without records from a selected therapy source is unknown coverage, not a
verified zero. Local fallback requires its full insulin/carbohydrate windows
to be after the respective Health import historyStart. Missing or unknown
coverage excludes the example. Historical Health samples are never copied
into the app's treatment store, BG database, statistics, Nightscout or Watch.
The model data-generation version changes, so older model packages and
checkpoints are never used with this history path. Settings shows completed
history days, completed model fits, self-check progress and usable-day/example
counts in Danish; final success appears only after the model decision.

The fixed 16-column feature contract uses raw glucose slopes, the existing
treatment curves, IOB/COB from bolus/carbohydrates only, and the local time at
the reference reading. Retrospective examples use all original glucose samples
inside each selected engine window; only the training anchors are spaced ten
minutes apart. Targets are nearest same-sensor readings within ±2 minutes,
with earlier readings winning ties. Historical treatment ingestion times and
past therapy settings are not reliably retained. The replay marks their
availability provenance **unknown** and applies one snapshot of current
settings; its self-check cannot prove live accuracy or freedom from all
retrospective information bias.

Create ML trains separate boosted-tree correction and expected-error models at
+30, +60 and +120 minutes, sequentially on the iPhone, either during an explicit foreground run or a system-granted background processing opportunity.
The error targets come from chronological out-of-sample complete-line
predictions. The last 28 calendar days ending on the latest usable day
are held apart: 14 for interval calibration and 14 for final self-check;
targets crossing boundaries are excluded. Training requires at least 60
calendar days with usable examples across all three horizons. Within each
period and horizon, A requires at least 30 usable days and 300 examples,
while B and C each require at least 10 usable days and 100 examples. A
candidate activates only if the complete ML line's MAE beats the engine at
all three horizons and does not worsen against a fairly comparable current
model. An incompatible model, failed training, partial package, nonfinite
result or any central point outside 20–600 mg/dL leaves the engine in use.
No trained model is committed to Git.

Corrections are capped at ±27 mg/dL at +30/+60/+120 and linearly interpolated
between knots, with zero correction at the reference. The engine's own
five-minute shape remains intact. The displayed interval targets 80% coverage
at **the three calibrated horizons** using deterministic nearest-rank
calibration of positive expected error; intermediate interval widths are
interpolated. This is neither a probability for the whole curve nor a
hypoglycemia safety limit. Settings → Home Screen → Personal forecast model
shows the current status, historical self-check and **Train now**. An explicit
foreground run pauses when the app leaves the foreground; automatic runs use
only a real system-granted `BGProcessingTask` lease. Model packages are written
in Application Support and activated through an atomic pointer only after all
six compiled models reload and validate. Create ML checkpoint directories are
protected and excluded from backup before training writes to them. Interrupted
sessions can resume only with the exact same immutable training inputs,
context, app build and training recipe, within 48 hours. Stale or incompatible
sessions are removed; unknown directories are preserved. Model retention keeps
the active package and one verified previous package.

These checks are software safeguards, not an observed improvement for this
person. A physical run must compare newly collected predictions with later
measured glucose and document any intervening meals, boluses or setting changes.
The exact tagged 4293 source passed 1,246/1,246 XCTest tests, all existing
Python controls and both iPhone/Watch simulator builds. Its signed IPA was
verified before upload, and Apple confirmed **Internal / Testing** on
2026-10-04. No model has yet been trained or exercised on the user's actual
iPhone, so future personal accuracy and the 80% interval target remain
unverified in physical use.

## Build 4294: usable-day training periods and diagnostics

In 4293, a large annual example count could still end in the generic
`mlNotEnoughHistory` message: its fixed 14-calendar-day B and C periods each
needed ten usable days, and the reason for rejection was hidden. The 4294
follow-up does **not** relax the minimum number of days, rows, walk-forward
residuals or calibration predictions. It reports the failing phase, horizon,
fold where applicable, actual and required counts, and the period's dates in
Danish. The preparation summary separates usable Health and app-history days
and reports same-time Health glucose timestamps merged or discarded as
conflicts. Thus an overall count such as 330 days cannot be mistaken for
proof that every training, calibration and self-check gate passed.

A usable day contains at least one complete valid training anchor with +30,
+60 and +120 targets after row-validity and boundary filtering. The latest
14 such days form C (self-check), the preceding 14 form B (band calibration),
and older days form A (training). Empty calendar days between selected days
are skipped, but the order is never shuffled. Targets must remain in their
anchor's period: the horizon **plus the existing two-minute match allowance**
is reserved at A/B and B/C boundaries and within chronological walk-forward
folds. Historical input windows may extend backward into the previous period;
targets may not extend forward into the next. The last C anchor must be at
most 48 hours old, and B plus C may span at most 60 calendar days. If either
freshness check fails, training is deferred with its measured limit shown.
The existing minimums remain 60 usable days overall; A needs at least 30
days and 300 rows per horizon, and B and C each need at least ten days and
100 rows per horizon. The separate walk-forward and valid calibration-output
minimums still apply.

For frozen xDrip Health sources, every otherwise valid raw glucose value at
the *same exact timestamp* is considered before choosing a source. If the
global maximum minus minimum exceeds **3.6 mg/dL**, that timestamp is
discarded for all sources. Otherwise, copies within each source bundle are
collapsed to that bundle's median; the number of repeated copies cannot
give one source more weight. The existing deterministic source choice and
segment boundary at a source change remain. Point-sample, single-reading,
finite-value and 20–600 mg/dL checks still apply. The data-generation/
feature version is advanced so packages and training checkpoints based on
the earlier duplicate policy cannot be reused.

The cleaned Health readings are compared at exactly overlapping timestamps
with Core Data's stored `finalValue`. Diagnostics report the comparison count
and the median and 95th percentile of the **absolute** difference in mg/dL;
neither dataset is changed. Differences alone cannot establish whether later
smoothing, recalibration or another cause is responsible. No personal
comparison statistic or training result is claimed until collected from the
user's iPhone. The correction model remains trained on A, and the error
model on chronological out-of-sample A residuals. Precisely those fitted
models are calibrated on B and evaluated on C; activation never retrains
them on either held-out period after the self-check. At the next weekly
training, previously held-out days may enter the then-current A period.

Local validation on 4 October 2026 passed **1,255/1,255 XCTest tests**, all
project Python controls, both iPhone and Watch simulator builds, and a separate
unsigned iPhoneOS/arm64 build that compiled the Create ML training path. The
latter produced an arm64 Mach-O iPhone app. The first full run had one faulty
new test fixture; the fixture was corrected and the entire suite passed on
rerun. Passing software checks does not prove that the original iPhone failure
is resolved or that personal accuracy has improved; the specific on-device
gate and outcome must be read from the new status display. The release process
repeated **1,255/1,255 XCTest tests** and both simulator builds on the exact
4294 source checkpoint; Apple confirmed **Internal / Testing** in the existing
Ole Internal group.

## After 4294: fair local ML self-check (step A)

The historical self-check now scores the engine, the finished ML line (with
the same whole-line fallback as live inference), and an unchanged-glucose
baseline against **the same complete C-period reference/actual pairs** at
each horizon. It shows the count, reference period, MAE and signed error
(prediction minus actual) for all three, and ML's MAE difference from the
unchanged baseline. A negative improvement means ML was worse. The activation
gate remains the existing comparison against the engine and a fairly
comparable prior model; this addition does not silently change model selection.

An explicit share action on the personal-model settings screen exposes a
device-local UTF-8 CSV with one row per C-period reference. It includes UTC
reference and matched-target times, source identity, effective engine/feature
version and treatment/ISF/ratio settings, reference glucose, engine and ML
values at +30/+60/+120, actual values, IOB/COB and bolus/carbohydrate sums
from the treatment window passed to the engine. The file is written for a
completed self-check even when the candidate is rejected, protected in
Application Support, and shared only on user action. An older or failed review
write cannot expose a mismatched CSV. This is sensitive health data; it is
not sent to Git, HealthKit, Nightscout, Watch or the network by the app.

Live Home and replay use the same event-time treatment-window filter and
unchanged forecast engine. Synthetic tests also exercise selected-source
filtering and exact-origin duplicate precedence before handing canonical
insulin units and carbohydrate grams to both paths. This proves parity *after
the chosen records and glucose samples are supplied*; it does not prove that
historical HealthKit and live Core Data contain identical observations,
source selections or settings. In particular, the historical loader
deliberately chooses direct HealthKit bolus/carbohydrate samples when their
selected sources are enabled, while live metrics use eligible imported Core
Data entries with local/remote origin-ID precedence. This source-level
difference is not covered by the synthetic motor-input parity test and is
not proof of a bug or of matching real iPhone inputs. Historical import availability is often
unknown, so replay continues to mark it as retrospective. The user's external
20 September–3 October replay rows are unavailable locally; the reported MAE
difference remains unexplained until matching per-reference inputs and targets
can be compared. Neither aggregate MAE nor daily treatment totals identify a
cause.

After a source-cutover backup is restored without its active source setup,
`therapyRestoreRequiresSourceSetup` keeps local therapy metrics, the forecast
and ML training unavailable until the selected source history and cutoff are
re-established. This is a fail-safe for an unknown treatment window, not a
zero-insulin or zero-carbohydrate result. Historical replay also rejects an
anchor whose treatment window contains a local entry created at an unknown time,
edited after the anchor, or now deleted when an earlier revision may have
existed. The earlier value cannot be reconstructed from the current row; these
anchors are omitted rather than evaluated with a falsely empty treatment set.

## Historical therapy and local-source cutover after 4297 (candidate)

The 4297 iPhone showed a 365-day history pass but zero historical Health insulin
and carbohydrate rows. A read-only check of that installed app's preferences on
5 October 2026 found a **valid** local-treatment cutover with both selected
mySugr bundle identifiers present; ongoing import was off as intended. Thus a
missing cutover is a reproducible failure mode, but is not the observed state
on that iPhone. The actual empty-history cause remains unverified.

The user-initiated training path had requested read access for blood glucose
alone. It now includes read-only requests for insulin delivery and dietary
carbohydrates even when ongoing treatment import is disabled. That omission is
a concrete code defect; whether it accounts for the zero rows on this iPhone
still requires a new on-device read. The history loader reports the cutover
state/date/source identifiers, effective ongoing-import flags, per-kind
executed/skipped query counts and reasons, requested periods, exact selected
bundle identifiers, and row counts returned by HealthKit before the source
filter, after the exact source filter, excluded by cutover, and accepted after
validation. A source query lists available source names and bundle identifiers
without changing the selected source. The live adapter counts raw **therapy**
rows before application filtering; glucose selection remains unchanged. Query
failure, cancellation, timeout and a successful empty response remain distinct.
An invalid stored cutover stops training with an explicit status before any
historical query. The 60-day, chronology, calibration and self-check thresholds
are unchanged.

On the next on-device run, skipped queries identify a missing/invalid setup;
executed queries with raw rows but no source matches identify a source-ID
mismatch. An executed query with zero raw rows is still ambiguous: HealthKit
does not reveal whether read access is denied or the source has no records.
No diagnosis of the user's actual HealthKit response is claimed until that
run's new status is collected.

Before a valid cutover, replay accepts treatments only from the saved Health
source. At or after the cutover it accepts confirmed local treatments only;
Health copies and later imported rows cannot count twice. Evidence for a
treatment window that crosses the cutover must exist on both sides for insulin
and carbohydrates separately. An unknown side is never treated as zero.

A previously self-checked model may remain usable across a documented, clean
transition to local logging if the **actual six-model package** is readable,
its existing approval remains valid, all non-source signature components and
model/engine/features/settings match, and its old source identifiers match the
saved cutover. This is a compatibility decision, not rewritten model metadata
or a claim that the model was retrained. The same result governs Settings and
live inference. A prospective check compares the old model's and engine's
+60-minute errors on paired readings from the same input snapshots. It needs
seven usable days after cutover; absent pairs or immature targets do not count
as zero error. If the old model is worse, its model-ID/cutover pair is disabled
durably. This check is limited to the transition model and does not establish
clinical accuracy or improvement at +30/+120 minutes.

The separate pen calculator can optionally reduce its curve-based COB using a
model-based **CGM-estimeret COB**. It reads a bounded glucose/treatment window
for that calculation only, models each rapid bolus's interval effect, allocates
positive residual to active meals and applies a minimum-absorption floor. The
calculator uses `min(curve COB, estimated COB)`; missing, inconsistent or noisy
history, an unknown relevant profile, manual/explicit fallback glucose, or a
changed snapshot leave curve COB in force with an explanation. This feature
does not alter Home COB, the forecast engine, ML, alarms or stored treatments.
It has not been verified as a clinically reliable measure of absorption.

The combined local candidate passed 1,379/1,379 XCTest tests, all project
Python controls, both simulator builds and an unsigned iPhoneOS/arm64 build.
The exact Apple-numbered release checkpoint must be tested again. Synthetic
HealthKit answers cannot establish the actual iPhone's read permission or
sample/source counts.

## After 4294: local treatment data (step B)

Treatment logging can use local xDrip entries as the primary source after an
explicit, persisted cutoff. A final selected Health import completes before the
source switches. Earlier selected mySugr entries remain eligible by event time;
local entries are eligible from the cutoff, including after a restart or a
later backdated entry. A restored cutoff without its source setup fails closed.
Confirmed local bolus and carbohydrate entries are offered to HealthKit by the
existing local writer using a stable sync identifier and version. The local
entry remains authoritative if the Health write fails, and xDrip does not
reimport its own Health samples. See `HEALTHKIT-THERAPY-IMPORT.md` for the
source, retry and backup rules.

Carbohydrate entries carry a meal kind and a selected duration: quick 30,
normal 240, or slow 300 minutes. Older entries read as normal/240 minutes.
The selected duration flows through local COB, the existing engine treatment
curve and historical ML input. A planned meal is a separate, unconfirmed
entry; its time passing is not confirmation. It is excluded from actual COB,
the unconditional engine forecast, ML and safety decisions until the user
confirms it as eaten. Any separate dotted planned-food scenario is conditional
on that future meal, and must not be confused with the unconditional forecast.
New local entries retain event and creation/modification times so historical
replay can reject information unavailable at the anchor. Imported historical
Health entries still use event time where knowledge time is unprovable.
The changed treatment formation invalidates incompatible stored ML models and
checkpoints; the engine remains available while ML retrains.

## After 4294: pen calculator and “Low soon” (step C)

The separate pen calculator uses `(COB + new unrecorded carbohydrates) / CR +
(glucose − target) / correction factor + 20-minute glucose change / correction
factor − IOB`. It shares the carbohydrate, glucose-correction, trend and active
insulin terms described by [Trio's bolus calculator](https://triodocs.org/usage/features/bolus-calculator/),
but uses the user's specified 20-minute change and a pen-specific workflow.
It has no loop control, superbolus, automatic dosing, or dependence on the ML
estimate. The profile is prefilled with the user's stated time-of-day CR,
correction, target, 0.5-unit pen step and 25-unit maximum, but it cannot be
used before explicit confirmation. The forecast's ISF/CR are separate and
never substitute for dose settings. A coherent, fresh local treatment snapshot
and verified source cutoff are required; unknown therapy data never become
zero IOB/COB. A stale or manual glucose value is identified with its time and
has no trend term. Already-recorded or backdated carbohydrate is included in
COB and not added again as a new meal.

The proposed amount is bounded at zero and the confirmed maximum and rounded
down to the pen step. The engine's unplanned-food 120-minute path is a read-only
safety check: a current or predicted glucose below 3.0 mmol/L blocks an
insulin proposal, and current glucose below 3.9 mmol/L displays “eat first”.
When that engine check is unavailable, the arithmetic proposal can still be
shown with an explicit unverified warning, as requested; this is a material
limitation. A user may separately record the amount actually taken. The app
never administers insulin. For a slow meal, the optional default 70% now and
90-minute reminder starts a *new* calculation; it is not a guaranteed second
dose. These rules are software behavior, not demonstrated clinical accuracy.

“Low soon” is a new, separately switchable iPhone alert, initially enabled.
At each newly saved CGM reading, it requests a warning when the valid engine
projection at +30 minutes is below 4.4 mmol/L while current glucose is at
least 3.9 mmol/L; repeated requests are limited to one per 30 minutes. Its
calculation does not depend on Home visibility, chart horizon or ML and does
not include unconfirmed meals. It requires the completed local-treatment
source cutover and a complete current therapy snapshot; being enabled in
Settings alone does not prove it is ready to warn. Health-import completion
can trigger a coalesced retry for the same reading, without a new timer. The Apple Watch
receives only the ordinary forwarded iPhone notification; it does not compute
this alert. An accepted notification request proves scheduling, not that the
person saw or heard it. The descriptive 30-day statistics distinguish planned
warning requests, sustained recorded lows and periods that cannot be judged
because readings or evaluations are missing. Low episodes require at least
15 minutes below 3.9 mmol/L, with no inter-reading gap over 5.5 minutes;
a normal reading or a longer gap ends an episode. The ML display is capped
at the engine curve when glucose is below 5.0 mmol/L and falling, or the
new warning is active. This presentation cap does not change the engine or
the recorded ML model.

## Validation boundary

### Pen calculator and planned meals in 4296

The iPhone pen calculator recalculates its existing suggestion when its inputs change and
on the existing screen clock as treatment effects and the time-based profile age. A
suggestion in 4296 was copied into the insulin field only by an explicit tap; the
follow-up after 4313 below changes meal entry on iPhone. Logging records the
user-entered insulin and carbohydrate amounts independently of whether a current
suggestion exists; insulin under a warning or without a completed calculation needs an
explicit confirmation. The local write-ahead journal binds each attempt's UUIDs to its
amounts and timestamps, so an uncertain save cannot be retried as a different dose.
The calculator does not deliver insulin.

New, unrecorded carbohydrates contribute to the existing dose calculation even when
the meal is planned for later. They do not become consumed COB, ML input or a safety
forecast treatment until the user confirms eating. Insulin logged with a plan is an
actual bolus at registration time and continues to contribute to IOB if the plan is
cancelled. A planned 🍕 meal uses the already configured percentage only for the
suggestion; after meal confirmation a new calculation uses the meal through COB and
does not add the original grams again. Meal linkage, the selected 🍕 reminder interval
and stable one-time notification identities are kept in local Application Support
metadata; Core Data remains the treatment source. Notification scheduling failures
are reported separately from a verified treatment save. Scheduling is not proof of
delivery or of the person seeing a reminder.

An explicit selection can use a particular CGM reading without a reliable 20-minute
trend, or a manual glucose value, with trend contribution zero and without the
existing forecast check. This does not make unknown IOB/COB equal zero. The selected
reading keeps its original measurement time and sensor identity. The pinned-CGM
choice resets when a newer fresh reading has a usable trend; a manual entry remains
selected until the user chooses CGM or closes the calculator.
This fallback is local to the calculator and does not change stored CGM readings,
forecast history, ML or alarms. It does not establish that a dose is clinically safe.

The exact 4296 checkpoint passed 1,346 XCTest tests, 157 Python tests, 54
synthetic Watch checks, both simulator builds and an unsigned iPhoneOS/arm64
build. The exported five-bundle IPA was verified before the internal TestFlight
upload. A physical iPhone and Watch have not yet verified the calculator flow
or actual notification delivery.

Unit tests cover model curves, timing, units, stale and gapped data, treatment selection, source ownership and missing settings. Real-world accuracy must be assessed at +30, +60 and +120 minutes separately against measured glucose, an unchanged-value baseline and a simple short trend. Inputs must be frozen at prediction time; later meals, insulin, corrections and changed settings must be reported separately. Historical xDrip treatment rows do not consistently retain a “known to the app at this time” timestamp, so a retrospective replay cannot prove that it avoided future information. Prospective snapshots or an external dataset with that provenance are needed before reporting comparative accuracy.

Future extensions may evaluate proven profile provenance, activity, heart rate, sleep and medication effects. The Watch workout that keeps the sensor connection alive must not be interpreted as exercise.


### iPhone meal-dose autofill after 4313

Entering new carbohydrates on iPhone now fills the insulin field from the existing
current, valid pen suggestion, including the final planned-meal/🍕 split. It does
not calculate a second dose or record treatment. Empty opening and 🍕 reassessment
keep explicit-copy behavior; the shared Watch service retains its existing behavior.
A user edit, including explicit zero or clearing, owns the insulin field. An explicit
selection of the current suggestion resumes automatic filling for a new meal.

An invalidated automatic dose is cleared until the latest calculation completes;
Log waits during that automatic refresh. A missing calculation never supplies zero.
Blocked suggestions fill no insulin, while carbohydrate-only registration remains
possible after a completed block. Manual logging remains independent of calculation
availability, with the existing warning confirmation. Frozen confirmation/save drafts
retain their original amounts, timestamps and operation identities. Formula, profile,
CGM-COB, rounding, safety checks and journal/storage are unchanged. Physical iPhone
interaction has not yet been verified for this change. Software validation and the
authorised release outcome are recorded separately in PROJECT-STATUS.md.

## Prospective evidence log and export

A completed Home calculation supplies an immutable value snapshot to a separate serial IO worker. It never sends Core Data objects between queues or rereads settings while writing. Rendering does not wait for disk IO. The Home evidence log adds no timer or continuous background calculation; the separate “Low soon” event-driven calculation is described above. Off means no Home forecast attempt is logged; cache hits do not create records.

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


## Automatic background ML training after 4311

Ordinary unlocked foreground use prepares a complete immutable history snapshot
through the existing HealthKit/app loader and replay. This preparation can start
one day before a compatible model becomes seven days old. The snapshot contains
value types, frozen settings, feature order, reference/target dates and the exact
examples used by the existing trainer. No Core Data objects cross queues. The
protected snapshot is stored locally in Application Support, excluded from
backup, limited to 128 MiB and 200,000 rows, and rejected after 48 hours or when
the latest reference is over 48 hours old. Source context, engine/features,
app build and time zone must still match. Historical provenance limitations,
60-day requirements, chronological splits and all approval gates are unchanged.

One registered `BGProcessingTask` requests external power, requires no network,
and supplies an earliest start time. iOS chooses whether and when it runs;
this is an approximately weekly opportunity, not a guaranteed weekly execution.
The background entry waits for existing model-load readiness, reads only the
prepared protected snapshot, and never asks HealthKit for authorization or
reads locked HealthKit history. It uses the existing sequential Create ML
trainer, calibration, self-check and atomic model installation on its separate
low-priority worker. Foreground forecast work, sensor collection, alarm delivery
and Watch communication retain their existing paths. **Train now** remains an
explicit immediate foreground action.

An interrupted task cancels the training lease and retains fingerprint-bound
Create ML sessions for a later run. Public Create ML session restore/resume is
used; a completed-fit shortcut is accepted only if its final checkpoint reloads
as a valid regressor. System expiration or process termination requests a retry
no earlier than one hour; a failed attempt or unavailable prepared snapshot has
a 24-hour retry delay. Completed training or a completed self-check rejection
uses a seven-day cadence. The existing compatible model remains active after
failed/interrupted/rejected training. Disabled forecasting or an invalid source
configuration removes this task's pending request. Repeated app activations,
duplicated callbacks and process restarts do not create parallel jobs or reset
the durable cadence. A missing/stale snapshot needs fresh preparation during
ordinary unlocked app use; no background mechanism fabricates missing history.

Software validation and physical evidence are recorded in PROJECT-STATUS.md.
Synthetic tests cover snapshot validation/protection, durable cadence, actual
background-entry handoff, expiration/readiness and repeated callbacks. A local
macOS Create ML probe produced checkpoints at iterations 5/10/15/20 and resumed
with an identical prediction; final-checkpoint construction failed on that Mac,
so the session-resume fallback was exercised. This is not an iPhone background
runtime measurement. The paired phone was inspected read-only at build 4311;
no local installation or background training was performed. Overnight locked-
phone completion, iOS scheduling/expiration and battery/runtime effects remain
for physical follow-up after TestFlight installation. No new prediction
accuracy is claimed, and engine mathematics, ML features/approval criteria,
dosing rules, HealthKit import/export, alarms and Libre/Watch are unchanged.
