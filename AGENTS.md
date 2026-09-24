# Release instructions for Don-Olsen/xdripswift

These instructions apply to every future TestFlight release from this repository.
First read `docs/PROJECT-STATUS.md` and `docs/MAC-BUILD.md` before any release work.

1. Finish and review the intended app code, tests, project files and release notes. Confirm the next build number in the existing App Store Connect app `6795645396`; do not infer it from Git. Set the checked-in `CURRENT_PROJECT_VERSION` to that number before testing.
2. Review the exact staged diff and ensure it contains all releasable source, tests and project files, and no secrets or build output. Run the relevant tests and iPhone/Watch simulator builds against that exact staged tree. Preserve known failures in the report; do not disable tests.
3. Before any TestFlight upload, commit the tested tree, push the release branch to `Don-Olsen/xdripswift`, create the annotated tag `testflight-<version>-<buildnumber>` on that commit, and push the tag. Verify the remote branch and tag resolve to the same commit. Do not move or reuse an existing TestFlight tag. The release working tree must be clean.
4. Build the signed Release archive and IPA from the tag's Git tree. Do not change app code between checkpoint/tag and build. Only local signing configuration and build output may be added outside Git. Verify that the iPhone and Watch products embed the tagged source commit, and check all five bundle IDs, signatures, provisioning profiles, entitlements, version and build number.
5. Upload only after the user explicitly says `GO UPLOAD` for that release. A normal test, build, archive or export must never upload. Recheck the App Store Connect build slot immediately before upload. After an uncertain upload outcome, inspect Apple's receipt before considering any retry; never upload twice just because processing is slow.
6. After Apple processes the build, record the actual TestFlight status, version/build, source commit, tag, test results and open issues in `docs/PROJECT-STATUS.md`. This can be a separate documentation commit pushed after upload. The TestFlight tag must remain on the exact build-source commit.

Use `scripts/release-testflight.py` for the gated sequence. It does not stage files automatically. The agent should stage and inspect the intended files, then run its checkpoint, publish, build, verify, upload and status commands as documented. This checkpoint/push/tag sequence is part of every authorized future release; the user need not request those steps separately. Specific later user instructions override this policy.

Never push IPA, xcarchive, xcresult, DerivedData, logs, certificates, provisioning profiles, private keys, tokens, secrets or private health data. Do not revoke existing signing assets, create a new App Store Connect app or change the established bundle IDs or team. Keep Codemagic as a fallback unless explicitly asked to change it.

The already-uploaded 7.0.0 (4263) predates this rule. Do not retroactively claim that it was built from a tag.
The post-upload `checkpoint/post-testflight-4263` branch preserves that integration source in a code commit and the new release process in a later commit. Its commits do not retroactively make 4263 a tag-built release.
