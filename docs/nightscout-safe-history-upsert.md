# Safe Nightscout history updates

Baseline: `24530203abab59006957e336aee88f1d295e80cf` (7.0.0 / 4262).
Branch: `fix/nightscout-safe-history-upsert`.

Automatic smoothing used to DELETE a window around every historical reading and
then POST replacements. If the typed DELETE returned zero or an unrecognised
count, a second DELETE dropped the SGV type restriction. That could affect other
entry types. The supplied logs do not establish that a calibration was deleted.

This change adapts the Nightscout portion of official upstream commit
[`10e86580`](https://github.com/JohanDegraeve/xdripswift/commit/10e86580b5b7b377b34d874fcaaae8e1783411b9):

- Ordinary replacements POST the existing payload without its local `_id`.
  Nightscout's `sysTime + type` upsert retains the existing server ID. No DELETE
  precedes automatic smoothing or a normal historical value revision.
- Explicit cadence rebuilds delete only supplied suppressed SGV timestamps,
  deduplicated and chunked by 50. A retained timestamp cannot also be deleted.
  Single-reading deletion uses the same exact, typed path. No untyped fallback.
- Delete count decoding supports `n`, `deletedCount` and `result.n`. Unknown count
  remains `unknown`; an HTTP/decoding failure stops that job before upload and
  prevents its checkpoint advancing. No hidden broad retry.
- Existing replacement ordering, historical upload waiters, durable Watch
  history queue and live upload handoff remain. Every chunk rechecks enabled
  state and the original destination; queued data cannot follow a changed site.
- The existing URLSession is injectable, so XCTest exercises real manager,
  request construction and callback handling against an isolated URLProtocol.

This is a selective port, not a full 7.1.0 merge. Glucose calculation, smoothing
parameters, cadence calculation, calibration, HealthKit replacement semantics,
Watch BLE, ownership, alarms and signing remain unchanged. Upstream's additional
HealthKit deletion and cadence-setting changes are outside this Nightscout fix.
No last-upload content cache or new persistent replacement pipeline is added.
The pre-existing replacement task chain is in memory: interrupted revisions are
recomputed by a later normal smoothing pass, or explicit Apply must be repeated.
The separate durable Watch history queue remains persistent and is still covered
by the existing pipeline tests. This patch does not promise to replay an
interrupted manual Apply automatically after process termination.

## Verification

`NightscoutHistoryWriteTests` uses an in-memory Core Data store, synthetic values
and an injected ephemeral URLSession that intercepts every request. It checks
30-reading smoothing without DELETE, remote ID retention, calibration/manual
entry preservation, repeated and changed upserts, overlapping snapshots, a lost
reply, failed chunks, upload disable, destination change, exact typed deletion,
50-timestamp chunking, count formats, failed deletion, and the production
post-processing caller for automatic and explicit cadence paths.

Both Codemagic workflows explicitly select this suite. The xcresult evidence
script requires every declared test method to have run and passed; missing,
skipped or failed methods fail verification. Existing Watch/value/diagnostic
suites remain selected. Local Python checks are not XCTest or Xcode verification.
Actual CI results and the tested SHA are recorded in the release report after
execution, not assumed here.

The representative server fixture models the public Nightscout v1 storage
contract (POST upsert by timestamp/type; typed exact DELETE). The user's own
server version has not been queried or used for synthetic/destructive tests.
An incompatible server must fail the request; the app never falls back to a
broader DELETE to compensate.

## Physical checks

After installing the next verified build on both devices, keep the same sensor
and processing settings. Observe an ordinary 30-minute run with smoothing as
already configured: historical values should update at Nightscout, existing
calibration/manual entries should remain, and normal smoothing must log no
DELETE attempts. Record server/app version and start/end time. Do not create
fake measurements or alter treatment for this check.

Separately test phone/Watch handoff and a 60-minute uninterrupted watch-face
window without debugger or repeated app openings. Request the local Watch log
after the window and confirm receipt before exporting. Distinguish local frame
gaps from delayed phone or Nightscout delivery. The Nightscout traffic fix is not
evidence that BLE recovery or overnight alarm availability has improved.
