# Local xDrip4iOS workspace

For current work on `Don-Olsen/xdripswift`, continue
`xdripswift-upstream-7.1.1` on `integration/upstream-7.1.1`. First read that
repository's `AGENTS.md`, `docs/PROJECT-STATUS.md` and `docs/MAC-BUILD.md`.
The preserved 4263 checkpoint is `xdripswift-watch-reading-integration` on
`checkpoint/post-testflight-4263`; the older sibling `xdripswift` is not the
current release source. Do not restart or overwrite those worktrees.

Future releases automatically query authenticated Apple build/upload status,
choose an unused build number, update tracked release metadata, test the exact
release tree, commit/push, tag, build from the tag, verify, upload only with
explicit version-specific GO UPLOAD, check Internal / Testing and the existing
Ole Internal group, then commit/push status without moving the tag.
Use `scripts/release-testflight.py`; never ask for a manual build number when
Apple's public API can obtain it. Missing API authentication is a credential
setup issue, not a build-number issue. No browser-cookie or Xcode-token scraping.
Normal builds never upload. Preserve all signing assets and app identity.
The user has explicitly authorized this 7.1.1 release, including the automatic
number/checkpoint/tag/signing/upload steps; see current project status for
remaining technical blockers. Other releases need their own GO UPLOAD.

Build 4263 was uploaded before this process. Never create a retroactive tag or
claim it was tag-built. The repository copy of these workspace instructions is
`docs/workspace-AGENTS.md`; this parent workspace file is outside the repository.
