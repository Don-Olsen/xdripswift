# Workspace entry point for Codex

In the local Mac workspace, the integration checkout is named
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
