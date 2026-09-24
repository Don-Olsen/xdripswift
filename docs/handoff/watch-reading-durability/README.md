# Watch reading durability: preserved Windows draft for Mac integration

This directory transfers existing work. The app source on this branch remains at
`d09bac575d9622d1368cbba0dc3039862d997ed3`; the draft has **not** been
applied to it, built, tested with Xcode, signed, or released.

## Provenance and files

- Draft base: `e11a6f4d3674b0ef58f1ac5159fcf0aac7ca8c21`, local branch
  `fix/watch-reading-durability-4260` in the preserved Windows worktree.
- Later code base: `d09bac575d9622d1368cbba0dc3039862d997ed3`, 25 commits
  after the draft base in the observed linear history. The later commits remain
  the base for integration.
- Original package: `watch-reading-durability-transfer-e11a6f4d3674.zip`.
  SHA-256: `43f94cf96604b2f20bd13465be6d59f2fb9c8d6cf30f1c51ef69d3b936d88f63`.
  Its four payload hashes were checked against `SHA256SUMS.txt` before transfer.
- Readable source patch: `watch-reading-durability.patch`, extracted unchanged
  from that package. Its SHA-256 is
  `ced1bf72d67cc9839cfc9907d1a0060895d28b3a32ef4dedb8df49eb127918ed`.
- `README.txt`, `GIT-STATUS.txt`, `COMPARISON-D09BAC57.txt`, and
  `SHA256SUMS.txt` are the other unchanged package entries. They record the
  basis, dirty-worktree status, exclusions, and comparison with the later code.
- `code-review.md` is the relevant preserved review from
  `review/watch-report-742EE33E/`. It includes the restore edge case below.

The patch changes exactly four tracked Swift files: `LibreWatchValuePipelineTests.swift`,
`WatchStateModel.swift`, `LibreDirectView.swift`, and
`LibreWatchDirectSession.swift` (370 insertions, 27 deletions against its base).
The unrelated dirty `README.md`, untracked `AGENTS.md` and `docs/` in the old
Windows worktree are deliberately absent. No health logs, personal settings,
credentials, signing assets, build outputs, or raw sensor payloads are included.

## Existing draft and tests

The draft prepares and persists the Watch reading outbox before local
display/alarm publication, records whether persistence was confirmed, repairs
the display-cache/outbox relationship after restart, and exposes a local storage
warning. These eight XCTest methods are in the patch and have **not** been run
with Xcode:

1. `testSubmissionCommitsRealOutboxBeforePublishingAndAllowsDiagnosticReads`
2. `testSubmissionRestartBetweenQueueAndDisplayCacheRecoversNewestReading`
3. `testSubmissionRepairsLegacyAndFailedWriteCacheOnceWithoutChangingID`
4. `testSubmissionConfirmedAndAcknowledgedCacheIsNotRequeuedOnRestart`
5. `testSubmissionFailedWriteKeepsRAMAndClinicalPublicationThenRetries`
6. `testSubmissionRestartRepairsLatestCachedReadingAfterQueueWriteFailure`
7. `testSubmissionDuplicateOutOfOrderAndWrongSessionDoNotPersistOrPublish`
8. `testSubmissionRestorePreservesSessionCalibrationAndAgeBounds`

## Known review finding

`LibreWatchReadingSubmission.restore` selects the display candidate before
calling `persist(&pending)`. If an earlier file read failed, `persist` can later
read and merge a newer queue reading B while the function still returns older
cached reading A. `code-review.md` describes the exact path. Add a regression
with failed first read, older cache A, and a successful second read of B; select
the display candidate after the merge. This is a static code finding, not a
failure shown in a physical Watch log.

The review also identifies a separate receiver-side risk: a temporarily
unavailable sensor/transmitter or calibration context may be returned as a
terminal `invalidPayload`. Assess it without treating it as a proven cause of
the observed field gaps. The draft does not change that receiver path.

## Continue on the Mac

1. Fetch this handoff branch from GitHub into the Mac repository. Preserve the
   Mac's existing checkout, local Xcode setup, signing assets, and any changes.
   Use a separate integration branch/worktree from the verified newer code.
2. Read this directory, especially the patch and `code-review.md`. The patch
   does not apply directly to `d09bac57` because later `WatchStateModel` changes
   overlap it. Integrate the existing behavior and tests selectively without
   replacing newer files wholesale. Do not recreate older functionality.
3. Resolve and test the documented restore edge case. Run the eight new tests
   and relevant existing Watch suites, then separate iPhone and Watch builds.
4. Continue with local Release archive, embedded Watch-app/signature checks,
   and IPA export using the Mac's established configuration. No TestFlight
   upload follows automatically from this handoff.

Previous green Mac results for the newer base do not verify this unapplied
draft. See `docs/PROJECT-STATUS.md` for the project-level state.
