#!/usr/bin/env python3
"""Gated local TestFlight sequence for the existing xDrip4iOS app.

Only the automatically selected tracked build number is staged by this script.
All other changes must be reviewed and staged first. Normal builds never upload.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time

from apple_release import AppleClient, AppleError


ROOT = Path(__file__).resolve().parent.parent
APP_ID = "6795645396"
TEAM = "GFZ896KN66"
REMOTE = "origin"
DOC = Path("docs/PROJECT-STATUS.md")
INTERNAL_GROUP = "Ole Internal"


class SlotOccupied(RuntimeError):
    """A different upload took the slot before this release attempted upload."""


def fail(message):
    raise SystemExit("error: " + message)


def run(args, *, output=False, env=None, log=None):
    if log is None:
        result = subprocess.run(args, cwd=ROOT, env=env, text=True,
                                stdout=subprocess.PIPE if output else None,
                                check=True)
        return result.stdout.strip() if output else ""
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w", encoding="utf-8") as stream:
        return subprocess.run(args, cwd=ROOT, env=env, text=True,
                              stdout=stream, stderr=subprocess.STDOUT).returncode


def git(*args):
    return run(["git", *args], output=True)


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_tree(root):
    if not root.is_dir():
        fail("release archive is missing")
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        mode = path.lstat().st_mode
        digest.update(relative + b"\0" + str(mode & 0o7777).encode() + b"\0")
        if stat.S_ISLNK(mode):
            digest.update(b"L" + os.readlink(path).encode("utf-8") + b"\0")
        elif stat.S_ISREG(mode):
            digest.update(b"F" + bytes.fromhex(sha256_file(path)))
        elif stat.S_ISDIR(mode):
            digest.update(b"D")
        else:
            fail("unexpected file type in release archive: " + str(path))
    return digest.hexdigest()


def version_and_build():
    content = (ROOT / "xDrip/Version.xcconfig").read_text(encoding="utf-8")
    version = re.search(r"^XDRIP_MARKETING_VERSION\s*=\s*(\d+(?:\.\d+)+)\s*$", content, re.M)
    checked_build = re.search(r"^CURRENT_PROJECT_VERSION\s*=\s*([1-9]\d*)\s*$", content, re.M)
    if not version or not checked_build:
        fail("checked-in marketing version or build number is missing")
    supplied = os.environ.get("XDRIP_BUILD_NUMBER")
    if supplied is not None and supplied != checked_build.group(1):
        fail("XDRIP_BUILD_NUMBER conflicts with the tracked Apple-selected build")
    return version.group(1), checked_build.group(1)


def release_paths(version, build):
    default = ROOT / "build" / f"testflight-{version}-{build}"
    output = Path(os.environ.get("XDRIP_RELEASE_ROOT", str(default))).resolve()
    build_root = (ROOT / "build").resolve()
    if output == build_root or build_root not in output.parents:
        fail("XDRIP_RELEASE_ROOT must stay inside the git-ignored build/ directory")
    return output, output / "release-state.json"


def save_state(path, state):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temp.replace(path)


def load_state(path, version, build):
    if not path.is_file():
        fail("release state is missing; start with checkpoint")
    state = json.loads(path.read_text(encoding="utf-8"))
    if state.get("version") != version or state.get("build") != build:
        fail("release state does not match the checked-in version/build")
    return state


def require_step(state, *steps):
    if state.get("step") not in steps:
        fail("release step is %r; expected %s" % (state.get("step"), ", ".join(steps)))


def ensure_origin():
    allowed = {
        "https://github.com/Don-Olsen/xdripswift.git",
        "git@github.com:Don-Olsen/xdripswift.git",
        "ssh://git@github.com/Don-Olsen/xdripswift.git",
    }
    if git("remote", "get-url", REMOTE) not in allowed:
        fail("origin is not the expected Don-Olsen/xdripswift repository")


def forbidden_index_paths():
    names = subprocess.check_output(["git", "ls-files", "--cached", "-z"], cwd=ROOT)
    forbidden = []
    for raw in names.split(b"\0"):
        if not raw:
            continue
        name = os.fsdecode(raw)
        base = Path(name).name.lower()
        parts = [part.lower() for part in Path(name).parts]
        suffix = Path(name).suffix.lower()
        if ("build" in parts or "deriveddata" in parts or
                any(part.endswith((".xcarchive", ".xcresult")) for part in parts) or
                suffix in {".ipa", ".xcarchive", ".xcresult", ".mobileprovision",
                           ".provisionprofile", ".p12", ".p8", ".cer", ".crt",
                           ".pem", ".key", ".log", ".sqlite"} or
                base in {"xdripconfigoverride.xcconfig", "versionoverride.xcconfig",
                         ".env", ".netrc", "credentials.json", "app-store-connect.json"} or
                base.startswith(".env.") or base.startswith("authkey_")):
            forbidden.append(name)
    if forbidden:
        fail("release index contains forbidden files: " + ", ".join(forbidden))


def ensure_candidate_matches_index():
    forbidden_index_paths()
    if subprocess.run(["git", "diff", "--quiet"], cwd=ROOT).returncode != 0:
        fail("unstaged tracked changes exist; stage or resolve them before tests")
    if git("ls-files", "--others", "--exclude-standard"):
        fail("untracked release files exist; review and stage or exclude them")
    if git("ls-files", "-u"):
        fail("unmerged files exist")
    run(["git", "diff", "--cached", "--check"])
    if (ROOT / "xDrip/VersionOverride.xcconfig").exists():
        fail("local VersionOverride.xcconfig would change the tested build number")


def ensure_clean():
    if git("status", "--porcelain", "--untracked-files=all"):
        fail("release working tree must be clean")
    if (ROOT / "xDrip/VersionOverride.xcconfig").exists():
        fail("local VersionOverride.xcconfig would change the tagged build")


def ensure_checkpoint(state):
    ensure_clean()
    if git("rev-parse", "HEAD") != state["checkpoint"]:
        fail("HEAD differs from the tested release checkpoint")
    if git("rev-parse", "HEAD^{tree}") != state["tree"]:
        fail("checkpoint tree differs from the tested tree")
    if git("branch", "--show-current") != state["branch"]:
        fail("release branch has changed")


def remote_ref(ref):
    result = git("ls-remote", REMOTE, ref)
    return result.split("\t", 1)[0] if result else ""


def ensure_published(state):
    ensure_checkpoint(state)
    if git("rev-parse", f"refs/tags/{state['tag']}^{{}}") != state["checkpoint"]:
        fail("local release tag differs from checkpoint")
    if git("cat-file", "-t", f"refs/tags/{state['tag']}") != "tag":
        fail("release tag is not annotated")
    if remote_ref(f"refs/heads/{state['branch']}") != state["checkpoint"]:
        fail("remote release branch differs from checkpoint")
    if remote_ref(f"refs/tags/{state['tag']}^{{}}") != state["checkpoint"]:
        fail("remote release tag differs from checkpoint")


def apple_client():
    return AppleClient.from_environment()


def slot_records(snapshot, version, build):
    return [row for collection in ("builds", "uploads")
            for row in snapshot[collection]
            if row["version"] == version and row["build"] == build]


def number_in_use(snapshot, build):
    def numeric(value):
        parts = tuple(int(part) for part in value.split("."))
        return parts + (0,) * (3 - len(parts))
    return any(numeric(row["build"]) == numeric(build) for collection in ("builds", "uploads")
               for row in snapshot[collection])


def release_source_changed(state):
    # Include staged and unstaged tracked changes as well as later commits.
    return bool(set(git("diff", "--name-only", state["checkpoint"]).splitlines()) - {DOC.as_posix()})


def apple_snapshot(client, version, destination):
    snapshot = client.snapshot(version)
    if (snapshot.get("appID") != APP_ID or snapshot.get("version") != version or
            snapshot.get("bundleID") != "com.GFZ896KN66.xdripswift" or
            snapshot.get("platform") != "IOS"):
        fail("Apple snapshot does not identify the existing iOS app/version")
    save_state(destination, snapshot)
    return snapshot


def allocation_receipt(root, version, build):
    allocation = root / "allocation.json"
    if not allocation.is_file():
        fail("Apple allocation is missing; run prepare (no manual build number required)")
    receipt = json.loads(allocation.read_text(encoding="utf-8"))
    if (receipt.get("appID") != APP_ID or receipt.get("version") != version or
            receipt.get("selectedBuild") != build or not receipt.get("observedAt") or
            receipt.get("snapshot", {}).get("appID") != APP_ID or
            number_in_use(receipt["snapshot"], build)):
        fail("Apple allocation does not match this release")
    return allocation, receipt


def prepare(*, force_new=False):
    """Authenticate and allocate before changing source; stage only Version.xcconfig."""
    ensure_origin()
    if os.environ.get("XDRIP_RELEASE_ROOT"):
        fail("automatic allocation uses separate per-build directories; unset XDRIP_RELEASE_ROOT")
    ensure_candidate_matches_index()
    if os.environ.get("XDRIP_STAGED_DIFF_REVIEWED") != "YES":
        fail("review and stage the intended release changes first")
    version, previous_build = version_and_build()
    client = apple_client()  # Fail on missing authentication before tests or source mutations.
    active_path = ROOT / "build/release-automation/active.json"
    if active_path.exists():
        active = json.loads(active_path.read_text(encoding="utf-8"))
        active_root, active_state_path = release_paths(active["version"], active["build"])
        if (active_root / "upload-attempt.json").exists():
            active_state = load_state(active_state_path, active["version"], active["build"])
            if active_state.get("appleStatus") != "internal-testing":
                reconcile_attempt(client, active_root, active_state_path, active_state)
                fail("prior upload is still active; resume release/status before allocating another build")
            if active["version"] == version:
                if not release_source_changed(active_state):
                    fail("this release is already in internal testing; do not upload it again")
    tree = git("write-tree")
    preflight = ROOT / "build/release-automation/preflight" / tree
    env = os.environ.copy()
    env["XDRIP_OUTPUT_ROOT"] = str(preflight)
    run([str(ROOT / "scripts/local-build.sh"), "python"], env=env)
    ensure_candidate_matches_index()
    if git("write-tree") != tree:
        fail("source changed during preliminary checks")
    snapshot = apple_snapshot(client, version, preflight / "apple-builds.json")
    old_root, _ = release_paths(version, previous_build)
    if not force_new and (old_root / "allocation.json").exists() and not number_in_use(snapshot, previous_build):
        allocation_receipt(old_root, version, previous_build)
        # Keep the original allocation hash bound to an existing test receipt.
        # The fresh, read-only snapshot is saved separately above.
        return version, previous_build
    else:
        selected = str(snapshot["nextBuild"])
        if not re.fullmatch(r"[1-9]\d*", selected):
            fail("Apple build selection returned an unsupported build format")
        # A local abandoned tag/output remains reserved too; never move a release tag.
        while True:
            reserved_root, _ = release_paths(version, selected)
            tag = f"testflight-{version}-{selected}"
            local_tag = subprocess.run(["git", "rev-parse", "-q", "--verify", f"refs/tags/{tag}"],
                                       cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
            if not reserved_root.exists() and not local_tag and not remote_ref(f"refs/tags/{tag}"):
                break
            selected = str(int(selected) + 1)
    if number_in_use(snapshot, selected):
        fail("selected build already exists at Apple")
    root, _ = release_paths(version, selected)
    receipt = {"appID": APP_ID, "version": version, "selectedBuild": selected,
               "previousTrackedBuild": previous_build, "observedAt": snapshot["observedAt"],
               "preflightTree": tree, "snapshot": snapshot}
    save_state(root / "allocation.json", receipt)
    version_file = ROOT / "xDrip/Version.xcconfig"
    content, substitutions = re.subn(r"^CURRENT_PROJECT_VERSION[ \t]*=[ \t]*[1-9]\d*[ \t]*$",
                                     "CURRENT_PROJECT_VERSION = " + selected,
                                     version_file.read_text(encoding="utf-8"), flags=re.M)
    if substitutions != 1:
        fail("ambiguous tracked build-number setting")
    version_file.write_text(content, encoding="utf-8")
    run(["git", "add", "--", "xDrip/Version.xcconfig"])
    os.environ.pop("XDRIP_BUILD_NUMBER", None)
    save_state(active_path, {"version": version, "build": selected, "allocatedAt": utc_now()})
    print(f"Apple-selected release: {version} ({selected}); existing version builds: "
          f"{len(snapshot['versionBuilds'])}", flush=True)
    return version, selected


def checkpoint(root, path, version, build, tag):
    ensure_origin()
    allocation, receipt = allocation_receipt(root, version, build)
    snapshot = apple_snapshot(apple_client(), version, root / "apple-before-checkpoint.json")
    if number_in_use(snapshot, build):
        raise SlotOccupied("Apple received this build number before checkpoint")
    if os.environ.get("XDRIP_STAGED_DIFF_REVIEWED") != "YES":
        fail("review the exact staged diff and set XDRIP_STAGED_DIFF_REVIEWED=YES")
    ensure_candidate_matches_index()
    staged = git("diff", "--cached", "--name-only")
    if not staged:
        fail("stage the intended release source, tests and project files first")
    git("var", "GIT_AUTHOR_IDENT")
    git("var", "GIT_COMMITTER_IDENT")
    if path.exists():
        state = load_state(path, version, build)
        require_step(state, "tested")
        if (git("rev-parse", "HEAD") != state["baseCommit"] or
                git("write-tree") != state["tree"] or
                git("branch", "--show-current") != state["branch"] or
                state.get("tests", {}).get("verificationPassed") is not True or
                state.get("allocationSha256") != sha256_file(allocation)):
            fail("saved test receipt does not match the staged release tree")
        tree = state["tree"]
        print("Resuming the already-tested staged tree:", tree, flush=True)
    else:
        branch = git("branch", "--show-current")
        if not branch:
            fail("a named release branch is required")
        base = git("rev-parse", "HEAD")
        tree = git("write-tree")
        print("Testing the exact staged Git tree:", tree, flush=True)
        test_root = root / "test"
        env = os.environ.copy()
        env["XDRIP_OUTPUT_ROOT"] = str(test_root)
        run([str(ROOT / "scripts/local-build.sh"), "release-test"], env=env)
        ensure_candidate_matches_index()
        if git("write-tree") != tree or git("rev-parse", "HEAD") != base:
            fail("source changed during tests; repeat the tests before checkpoint")
        summary = json.loads((test_root / "results/stability-summary.json").read_text(encoding="utf-8"))
        counts = summary.get("counts", {})
        if (summary.get("verificationPassed") is not True or
                counts.get("totalTestCount", 0) < 1 or
                counts.get("passedTests") != counts.get("totalTestCount") or
                counts.get("failedTests") != 0 or counts.get("skippedTests") != 0):
            fail("XCTest result summary does not confirm all relevant tests passed")
        state = {
            "version": version, "build": build, "tag": tag, "branch": branch,
            "allocationPath": str(allocation), "allocationSha256": sha256_file(allocation),
            "baseCommit": base, "tree": tree, "testedAt": utc_now(),
            "tests": {
                "verificationPassed": True,
                "counts": counts,
                "resultBundle": str(test_root / "results/AllTests.xcresult"),
                "summary": str(test_root / "results/stability-summary.json"),
                "iphoneBuildLog": str(test_root / "logs/iphone-build.log"),
                "watchBuildLog": str(test_root / "logs/watch-build.log"),
            },
            "step": "tested",
        }
        save_state(path, state)
    run(["git", "commit", "-m", f"testflight: checkpoint {version} ({build}) [skip ci]"])
    ensure_clean()
    checkpoint_sha = git("rev-parse", "HEAD")
    if git("rev-parse", "HEAD^{tree}") != tree:
        fail("commit tree differs from the tested tree; stop the release")
    state.update(step="checkpointed", checkpoint=checkpoint_sha, checkpointedAt=utc_now())
    save_state(path, state)
    print("Tested checkpoint:", checkpoint_sha)


def publish(path, state):
    require_step(state, "checkpointed")
    ensure_origin()
    ensure_checkpoint(state)
    run(["git", "push", REMOTE, f"HEAD:refs/heads/{state['branch']}"])
    if remote_ref(f"refs/heads/{state['branch']}") != state["checkpoint"]:
        fail("remote branch did not resolve to the tested checkpoint")
    tag = state["tag"]
    local = subprocess.run(["git", "rev-parse", "-q", "--verify", f"refs/tags/{tag}^{{}}"],
                           cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if local.returncode == 0:
        if local.stdout.strip() != state["checkpoint"]:
            fail("an existing local TestFlight tag points elsewhere")
    else:
        if remote_ref(f"refs/tags/{tag}"):
            fail("TestFlight tag exists remotely but not locally; inspect before continuing")
        run(["git", "tag", "-a", tag, "-m", f"TestFlight {state['version']} ({state['build']})", state["checkpoint"]])
    if git("cat-file", "-t", f"refs/tags/{tag}") != "tag":
        fail("TestFlight tag must be annotated")
    existing_remote = remote_ref(f"refs/tags/{tag}^{{}}") or remote_ref(f"refs/tags/{tag}")
    if existing_remote and existing_remote != state["checkpoint"]:
        fail("existing remote TestFlight tag points elsewhere; never move it")
    if not existing_remote:
        run(["git", "push", REMOTE, f"refs/tags/{tag}"])
    ensure_published(state)
    state.update(step="tagged", publishedAt=utc_now())
    save_state(path, state)
    print("Pushed branch and immutable TestFlight tag:", tag)


def build(root, path, state):
    require_step(state, "tagged")
    ensure_published(state)
    output = root / "build"
    if output.exists():
        fail("build output already exists; inspect it instead of overwriting it")
    env = os.environ.copy()
    env.update(XDRIP_OUTPUT_ROOT=str(output), XDRIP_RELEASE_TAG=state["tag"],
               XDRIP_RELEASE_STATE_PATH=str(path), XDRIP_BUILD_NUMBER=state["build"],
               XDRIP_ASC_ALLOCATION_PATH=state["allocationPath"])
    if sha256_file(Path(state["allocationPath"])) != state["allocationSha256"]:
        fail("Apple allocation receipt changed since checkpoint")
    run([str(ROOT / "scripts/local-build.sh"), "archive"], env=env)
    ipa_files = list((output / "export").glob("*.ipa"))
    if len(ipa_files) != 1:
        fail("expected exactly one locally exported IPA")
    state.update(step="built", archive=str(output / "archive/xdrip.xcarchive"),
                 ipa=str(ipa_files[0]), builtAt=utc_now())
    save_state(path, state)


def verify(root, path, state):
    require_step(state, "built")
    ensure_published(state)
    for phase, name in (("archive-development", "archive-signed-bundles.json"),
                        ("export-distribution", "export-signed-bundles.json")):
        manifest = json.loads((root / "build/results" / name).read_text(encoding="utf-8"))
        if (manifest.get("sourceCommit") != state["checkpoint"] or
                manifest.get("version") != state["version"] or
                manifest.get("build") != state["build"] or
                manifest.get("signingPhase") != phase or
                len(manifest.get("bundles", [])) != 5 or
                not all(row.get("signatureVerified") is True for row in manifest["bundles"])):
            fail("signed bundle manifest does not match the tagged release")
    ipa = Path(state["ipa"])
    if not ipa.is_file():
        fail("exported IPA is missing")
    # Verify the actual IPA bytes again, not a stale previously extracted directory.
    (root / "verify").mkdir(parents=True, exist_ok=True)
    extracted = Path(tempfile.mkdtemp(prefix="ipa-", dir=root / "verify"))
    run(["ditto", "-x", "-k", str(ipa), str(extracted)])
    for phase, app in (
        ("archive-development", root / "build/archive/xdrip.xcarchive/Products/Applications/xdrip.app"),
        ("export-distribution", extracted / "Payload/xdrip.app"),
    ):
        env = os.environ.copy()
        env.update(XDRIP_OUTPUT_ROOT=str(root / "verify" / phase), XDRIP_APP_PATH=str(app),
                   XDRIP_SIGNING_PHASE=phase, XDRIP_BUILD_NUMBER=state["build"],
                   XDRIP_SOURCE_COMMIT=state["checkpoint"])
        run([str(ROOT / "scripts/local-build.sh"), "verify-signed"], env=env)
    sha = sha256_file(ipa)
    archive_sha = sha256_tree(Path(state["archive"]))
    state.update(step="verified", ipaSha256=sha, archiveSha256=archive_sha,
                 verifiedAt=utc_now())
    save_state(path, state)
    print("Verified tag, source stamp, five signed bundles and IPA SHA-256:", sha)


def upload(root, path, state):
    require_step(state, "verified")
    ensure_published(state)
    if (os.environ.get("XDRIP_GO_UPLOAD") != "YES" or
            os.environ.get("XDRIP_GO_UPLOAD_VERSION") != state.get("version")):
        fail("upload requires GO UPLOAD for this version and matching XDRIP_GO_UPLOAD_VERSION")
    ipa = Path(state["ipa"])
    if sha256_file(ipa) != state["ipaSha256"]:
        fail("verified IPA bytes changed")
    if sha256_tree(Path(state["archive"])) != state["archiveSha256"]:
        fail("verified release archive changed")
    attempt = root / "upload-attempt.json"
    client = apple_client()
    if attempt.exists():
        reconcile_attempt(client, root, path, state)
        return
    snapshot = apple_snapshot(client, state["version"], root / "apple-before-upload.json")
    if number_in_use(snapshot, state["build"]):
        raise SlotOccupied("a different Apple upload now occupies the selected build number")
    auth_args = client.upload_auth_args()
    # Exclusive creation prevents two local upload commands racing past the guard.
    attempt_data = {"startedAt": utc_now(), "checkpoint": state["checkpoint"],
                    "version": state["version"], "build": state["build"],
                    "tag": state["tag"], "ipaSha256": state["ipaSha256"], "outcome": "uncertain"}
    with attempt.open("x", encoding="utf-8") as stream:
        json.dump(attempt_data, stream, indent=2)
    log = root / "upload.log"
    # altool uploads this verified IPA directly. It does not re-export or re-sign it.
    code = run(["xcrun", "altool", "--upload-package", str(ipa),
                *auth_args, "--output-format", "json"], log=log)
    attempt_data.update(exitCode=code, finishedAt=utc_now())
    if code == 0:
        attempt_data["outcome"] = "received"
    save_state(attempt, attempt_data)
    if code != 0:
        reconcile_attempt(client, root, path, state)
        return
    state.update(step="uploaded", uploadedAt=utc_now(), uploadLog=str(log))
    save_state(path, state)
    print("Upload command succeeded; verify Apple's processing status for", APP_ID, state["version"], state["build"])


def reconcile_attempt(client, root, path, state):
    """Read Apple after uncertainty. A matching number alone cannot prove our bytes arrived."""
    attempt = json.loads((root / "upload-attempt.json").read_text(encoding="utf-8"))
    if any(attempt.get(key) != state.get(key) for key in ("checkpoint", "tag", "ipaSha256")):
        fail("previous upload attempt does not identify this exact tagged IPA")
    snapshot = apple_snapshot(client, state["version"], root / "apple-after-upload-attempt.json")
    records = slot_records(snapshot, state["version"], state["build"])
    if attempt.get("outcome") != "received":
        detail = "Apple has a matching build/upload, but its source is unconfirmed" if records else "Apple has not yet exposed this upload"
        fail(detail + "; the prior upload outcome remains uncertain, so no second upload or new number is chosen")
    state.update(step="uploaded", uploadedAt=attempt.get("finishedAt", attempt["startedAt"]),
                 uploadLog=str(root / "upload.log"))
    save_state(path, state)


def poll_apple(root, path, state, *, timeout=900):
    require_step(state, "uploaded", "status-recorded")
    client = apple_client()
    deadline = time.monotonic() + timeout
    last_status = None
    while True:
        observed = client.build_status(state["version"], state["build"])
        observation = {"observedAt": utc_now(), "appID": APP_ID,
                       "version": state["version"], "build": state["build"],
                       "status": "received", "buildRecord": observed, "group": None}
        if observed is not None:
            if (observed.get("version") != state["version"] or observed.get("build") != state["build"]):
                fail("Apple result identifies a different release")
            processing = observed.get("processingState")
            internal = observed.get("betaInternalState")
            if processing in {"FAILED", "INVALID"} or observed.get("uploadState") == "FAILED":
                observation["status"] = "failed"
            elif observed.get("expired") is True:
                observation["status"] = "action-required"
            elif processing == "VALID":
                if observed.get("buildAudienceType") != "INTERNAL_ONLY":
                    observation["status"] = "action-required"
                elif internal in {"READY_FOR_BETA_TESTING", "IN_BETA_TESTING"}:
                    group = client.ensure_internal_group(observed["id"], INTERNAL_GROUP)
                    observation["group"] = group
                    confirmed = client.build_status(state["version"], state["build"])
                    observation["buildRecord"] = confirmed
                    if (confirmed and confirmed.get("id") == observed["id"] and
                            confirmed.get("version") == state["version"] and confirmed.get("build") == state["build"] and
                            confirmed.get("processingState") == "VALID" and
                            confirmed.get("buildAudienceType") == "INTERNAL_ONLY" and
                            confirmed.get("betaInternalState") == "IN_BETA_TESTING" and
                            confirmed.get("expired") is False and group.get("buildLinked") is True and
                            group.get("isInternalGroup") is True and group.get("name") == INTERNAL_GROUP and
                            group.get("buildID") == observed["id"]):
                        observation["status"] = "internal-testing"
                    else:
                        observation["status"] = "processing"
                elif internal in {"PROCESSING", "IN_EXPORT_COMPLIANCE_REVIEW"}:
                    observation["status"] = "processing"
                else:
                    # Never invent export-compliance/legal declarations or change testing audiences.
                    observation["status"] = "action-required"
            else:
                observation["status"] = "processing"
        state["appleObservation"] = observation
        save_state(root / "apple-status.json", observation)
        save_state(path, state)
        if observation["status"] != last_status:
            print("Apple status:", observation["status"], flush=True)
            last_status = observation["status"]
        if observation["status"] in {"internal-testing", "failed", "action-required"} or time.monotonic() >= deadline:
            return observation
        time.sleep(min(30, max(0, deadline - time.monotonic())))


def status(root, path, state, observation=None):
    require_step(state, "uploaded", "status-recorded")
    ensure_origin()
    ensure_clean()
    if git("rev-parse", f"refs/tags/{state['tag']}^{{}}") != state["checkpoint"]:
        fail("TestFlight tag moved from the release checkpoint")
    later_paths = git("diff", "--name-only", state["checkpoint"], "HEAD").splitlines()
    if any(name != DOC.as_posix() for name in later_paths):
        fail("app/project code changed since tag; stop before status commit")
    observation = observation or poll_apple(root, path, state, timeout=0)
    if (observation.get("appID") != APP_ID or observation.get("version") != state["version"] or
            observation.get("build") != state["build"]):
        fail("Apple status observation identifies another release")
    value = observation["status"]
    record = observation.get("buildRecord") or {}
    url = f"https://appstoreconnect.apple.com/apps/{APP_ID}/testflight/ios"
    if record.get("id"):
        url += "/" + record["id"]
    group = observation.get("group") or {}
    if value == "internal-testing" and not (
            group.get("buildLinked") is True and group.get("isInternalGroup") is True and
            group.get("name") == INTERNAL_GROUP and group.get("buildID") == record.get("id") and
            record.get("expired") is False and record.get("processingState") == "VALID" and
            record.get("version") == state["version"] and record.get("build") == state["build"] and
            record.get("buildAudienceType") == "INTERNAL_ONLY" and record.get("betaInternalState") == "IN_BETA_TESTING"):
        fail("Internal / Testing requires verified Apple status and the existing internal group")
    labels = {"received": "Upload modtaget", "processing": "Apple behandler",
              "internal-testing": "Internal / Testing", "failed": "Apple afviste buildet",
              "action-required": "Apple kræver en konkret handling"}
    if value not in labels:
        fail("unknown Apple processing status")
    start = f"<!-- {state['tag']}:start -->"
    end = f"<!-- {state['tag']}:end -->"
    counts = state["tests"]["counts"]
    text = (f"{start}\n### TestFlight {state['version']} ({state['build']})\n\n"
            f"- Kildecommit og tag: `{state['checkpoint']}` / `{state['tag']}`.\n"
            f"- Tests: {counts['passedTests']}/{counts['totalTestCount']} bestået; "
            f"{counts['failedTests']} fejlet; {counts['skippedTests']} skipped. "
            "iPhone- og Watch-simulatorbuilds bestod.\n"
            f"- Apple-status ({utc_now()}): [{labels[value]}]({url}).\n"
            + ("- Eksisterende intern gruppe: Ole Internal er bekræftet tilknyttet.\n" if group.get("buildLinked") else
               "- Ole Internal: endnu ikke bekræftet tilknyttet.\n")
            + "- Åbne problemer og fysisk testbehov: se de øvrige afsnit i dette dokument; "
              "TestFlight-uploaden løser dem ikke.\n"
            f"{end}\n")
    doc_path = ROOT / DOC
    existing = doc_path.read_text(encoding="utf-8")
    if start in existing and end in existing:
        first = existing.index(start)
        last = existing.index(end, first) + len(end)
        existing = existing[:first] + text.rstrip("\n") + existing[last:]
    else:
        existing = text + "\nDe følgende afsnit bevarer integrations- og testhistorikken før denne udgivelse.\n\n" + existing
    doc_path.write_text(existing, encoding="utf-8")
    run(["git", "add", "--", DOC.as_posix()])
    if git("diff", "--cached", "--name-only") != DOC.as_posix():
        fail("status commit must contain only docs/PROJECT-STATUS.md")
    run(["git", "diff", "--cached", "--check"])
    run(["git", "commit", "-m", f"docs: record TestFlight {state['version']} ({state['build']}) status [skip ci]"])
    ensure_clean()
    run(["git", "push", REMOTE, f"HEAD:refs/heads/{state['branch']}"])
    if remote_ref(f"refs/tags/{state['tag']}^{{}}") != state["checkpoint"]:
        fail("remote TestFlight tag changed after status update")
    state.update(step="status-recorded", appleStatus=value, statusRecordedAt=utc_now(),
                 statusCommit=git("rev-parse", "HEAD"))
    save_state(path, state)
    print("Recorded Apple status without moving the TestFlight tag:", labels[value])


def release_all():
    if (os.environ.get("XDRIP_GO_UPLOAD") != "YES" or
            os.environ.get("XDRIP_GO_UPLOAD_VERSION") != version_and_build()[0]):
        fail("release requires the user's GO UPLOAD for this version; prepare/build never imply upload")
    for _ in range(3):
        version, number = version_and_build()
        root, path = release_paths(version, number)
        try:
            if path.exists():
                previous = load_state(path, version, number)
                if previous.get("appleStatus") == "internal-testing" and release_source_changed(previous):
                    version, number = prepare(force_new=True)
                    root, path = release_paths(version, number)
            if not path.exists():
                version, number = prepare()
                root, path = release_paths(version, number)
                checkpoint(root, path, version, number, f"testflight-{version}-{number}")
            state = load_state(path, version, number)
            if state["step"] == "tested":
                checkpoint(root, path, version, number, state["tag"])
                state = load_state(path, version, number)
            if state["step"] == "checkpointed":
                publish(path, state)
            if state["step"] == "tagged":
                build(root, path, state)
            if state["step"] == "built":
                verify(root, path, state)
            if state["step"] == "verified":
                upload(root, path, state)
            observation = poll_apple(root, path, state)
            status(root, path, state, observation)
            return
        except SlotOccupied as error:
            if (root / "upload-attempt.json").exists():
                fail("upload already attempted; never reallocate on an uncertain outcome")
            if path.exists():
                state = load_state(path, version, number)
                state.update(step="superseded", supersededAt=utc_now(), reason=str(error))
                save_state(path, state)
            print("Apple slot occupied; preserving previous tag and retesting a newly selected number.", flush=True)
            prepare(force_new=True)
    fail("repeated concurrent Apple build collisions; no further automatic upload attempts")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "apple-status", "prepare", "release", "checkpoint", "publish", "build", "verify", "upload", "status"))
    args = parser.parse_args()
    os.chdir(ROOT)
    ensure_origin()
    if args.command == "release":
        release_all()
        return
    if args.command == "prepare":
        prepare()
        return
    version, number = version_and_build()
    root, path = release_paths(version, number)
    tag = f"testflight-{version}-{number}"
    if args.command == "apple-status":
        snapshot = apple_snapshot(apple_client(), version, ROOT / "build/release-automation/apple-builds.json")
        print(json.dumps({key: snapshot[key] for key in ("appID", "version", "highestBuild", "nextBuild", "versionBuilds")}, indent=2))
        return
    if args.command == "check":
        print("Repository:", ROOT)
        print("Candidate:", version, number, tag)
        print("Git:", git("status", "--short", "--branch"))
        print("Release state:", path if path.exists() else "not started")
        forbidden_index_paths()
        return
    if args.command == "checkpoint":
        checkpoint(root, path, version, number, tag)
        return
    state = load_state(path, version, number)
    {
        "publish": lambda: publish(path, state),
        "build": lambda: build(root, path, state),
        "verify": lambda: verify(root, path, state),
        "upload": lambda: upload(root, path, state),
        "status": lambda: status(root, path, state),
    }[args.command]()


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        fail(f"command failed ({exc.returncode}): {' '.join(map(str, exc.cmd))}")
    except (AppleError, SlotOccupied) as exc:
        fail(str(exc))
