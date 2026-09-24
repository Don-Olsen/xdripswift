# Release instructions for Don-Olsen/xdripswift

First read `docs/PROJECT-STATUS.md` and `docs/MAC-BUILD.md`. Continue the existing
`integration/upstream-7.1.1` worktree for 7.1.1; preserve the 4263 checkpoint.

Every future TestFlight release follows this sequence automatically:

1. Review and stage the finished source, tests and release-process files. Preserve actual test evidence and known open issues. Run preliminary checks.
2. Use `scripts/release-testflight.py prepare` or `release` to query Apple's public App Store Connect API for app `6795645396`, bundle `com.GFZ896KN66.xdripswift`. Read every page of builds and build uploads, explicitly check the current marketing version and all processing states, and automatically select the next unused number. Never ask the user for a build number when authenticated API access can obtain it. Never infer Apple's inventory from Git or the old branch name.
3. The process records Apple's inventory and selected number locally, updates/stages only tracked `xDrip/Version.xcconfig`, then runs the complete XCTest suite, Python guards and both simulator builds against the exact staged tree. A build-number/source change requires a new test receipt; earlier 983/983 or 475/475 results cannot replace it.
4. Commit and push that tested, clean checkpoint to `Don-Olsen/xdripswift`. Create and push an annotated `testflight-<version>-<buildnumber>` tag on exactly that commit. Never move or reuse a tag. This is part of the release task, not an extra user approval.
5. Archive and export from the tag's Git tree using automatic signing for team `GFZ896KN66`. For unattended cloud signing, `release-testflight.py` passes the configured external App Store Connect **Admin team key** to Xcode's supported authentication flags; a working Xcode account is an alternative. Do not put the key in Git or logs. Verify embedded source commit, all five bundle IDs, signatures, provisioning profiles, entitlements, versions/builds and Watch embedding. Verify the actual exported IPA, not only a cached extraction.
6. Upload requires the user's explicit GO UPLOAD for this release. The agent sets `XDRIP_GO_UPLOAD=YES` and matching `XDRIP_GO_UPLOAD_VERSION` only when that authorization exists. Normal test/build/prepare/archive commands never upload. The `release` command rechecks Apple immediately before uploading the same verified IPA with Apple's altool. Xcode export may create a single `AWAITING_UPLOAD` record: accept it only when its exact ID was newly observed after this export and is still awaiting upload. Any other occupied number causes automatic reallocation, retest, new checkpoint/tag and rebuild; old tags remain unchanged. An uncertain prior upload is inspected at Apple and is never blindly repeated or replaced with another number.
7. Follow processing for up to 15 minutes. Attach only to the existing internal `Ole Internal` group. Confirm exact app/version/build, `VALID`, `INTERNAL_ONLY`, `IN_BETA_TESTING` and the group's actual build relationship before reporting Internal / Testing. No external testing, new groups/testers or App Store publication.
8. Record actual Apple status, source commit/tag, test results and open issues in `docs/PROJECT-STATUS.md`, commit/push that documentation separately, and leave the tag on the exact build-source commit. Processing timeout is not upload failure.

Use the existing account/API access. Public REST requires an Apple-issued API key;
Xcode login alone is not an API credential. Configure a private `.p8` and its
local configuration outside Git, with owner-only access, as documented in
MAC-BUILD.md. Never extract browser cookies or Xcode login tokens, use private
Apple APIs, or ask for passwords/private-key contents in chat. If API access is
missing, diagnose that authentication/permission requirement; do not replace it
with a manual build-number question. Stop only for personal login/2FA, missing
rights, a new legal agreement, an unresolved technical fault or a source/product
mismatch. User authorization for necessary automatic signing persists for the
specific authorized release; do not ask for another GO UPLOAD.

Never push build output, IPA, xcarchive, xcresult, DerivedData, logs, private
configuration, certificates/profiles/keys/tokens or health data. Do not revoke
signing assets, create a new app/bundle ID, change team/capabilities or run CI as
part of this process. Keep Codemagic as fallback. Use `[skip ci]` on release and
status commits and verify push/tag workflow triggers remain inactive.

7.0.0 (4263) predates this rule and was built from local integration changes.
Never retroactively describe it as tag-built. Its permanent checkpoint is
`checkpoint/post-testflight-4263`; leave it untouched.
