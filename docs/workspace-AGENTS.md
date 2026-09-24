# Workspace entry point for Codex

For the official 7.1.1 integration, continue the existing
`xdripswift-upstream-7.1.1` worktree on `integration/upstream-7.1.1`, based on
checkpoint `5a0ce985c86909e3827970f4487ca573bd46a7a5`. Read the current status
before treating it as release-ready; upstream test failures and the unconfirmed
Apple build number are documented there. This task has no upload authorization.

In the local Mac workspace, the preserved 4263 integration checkout is named
`xdripswift-watch-reading-integration`. An older sibling checkout named
`xdripswift` does not contain the code used for TestFlight 7.0.0 (4263).
Start release work in the integration checkout on
`checkpoint/post-testflight-4263` or its reviewed successor. First read the
repository root `AGENTS.md`, `docs/PROJECT-STATUS.md` and `docs/MAC-BUILD.md`.

Build 4263 was uploaded from local integration changes before the new Git
checkpoint rule. Never describe it as built from a release tag. Every later
TestFlight upload follows the tested checkpoint, pushed branch, pushed tag,
tagged build, verification, explicit `GO UPLOAD` and Apple-status sequence.

This file preserves the useful project guidance from a local parent-workspace
`AGENTS.md` inside Git. The parent file itself is outside this repository.
