# Project status for Mac continuation

Date: 24 September 2026. This handoff branch starts at
`d09bac575d9622d1368cbba0dc3039862d997ed3` and adds documentation and
the preserved Watch reading durability draft only. No application source file
has been changed on this branch.

The Windows draft originated from `e11a6f4d3674b0ef58f1ac5159fcf0aac7ca8c21`.
It is available as the original checked ZIP and a readable patch in
[`handoff/watch-reading-durability/`](handoff/watch-reading-durability/README.md).
The original Windows worktree and its uncommitted changes remain untouched.
The draft is **not yet integrated** with the 25 later commits through `d09bac57`.

The draft aims to persist an accepted direct Watch reading in its bounded
delivery outbox before publishing it locally, retain persistence evidence, and
repair the queue/display cache after restart. Its eight new XCTest methods
remain unverified by Xcode. The preserved
[`code-review.md`](handoff/watch-reading-durability/code-review.md) documents a
restore problem: after an initial queue read fails, a later successful merge of
a newer queue reading can still leave the older cached reading selected for
display. This must be resolved and tested during integration.

The Mac already has a local Xcode, build, and signing setup according to the
user. Preserve and inspect that setup; do not start configuration from scratch.
Earlier successful Mac tests and builds apply to their tested SHAs, not to this
unapplied patch. In particular, the latest verified TestFlight release remains
7.0.0 (4262) from `24530203abab59006957e336aee88f1d295e80cf`;
the `d09bac57` Nightscout branch and this handoff have no new Xcode result or
upload recorded here.

Next Mac task: fetch the handoff from GitHub; read the package, extracted patch,
metadata, and review; integrate the existing changes onto the newer code in a
separate worktree while preserving newer fixes; address the restore edge case;
run relevant XCTest suites and iPhone/Watch builds; then continue local archive,
signing, and IPA export. Do not upload to TestFlight automatically.
