#!/usr/bin/env python3
"""Gated local TestFlight sequence for the existing xDrip4iOS app.

This script never stages files. `upload` is a separate command and requires
the user's explicit GO UPLOAD plus a fresh App Store Connect slot check.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parent.parent
APP_ID = "6795645396"
TEAM = "GFZ896KN66"
REMOTE = "origin"
DOC = Path("docs/PROJECT-STATUS.md")


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
    build = os.environ.get("XDRIP_BUILD_NUMBER", "")
    if not version or not checked_build:
        fail("checked-in marketing version or build number is missing")
    if not re.fullmatch(r"[1-9]\d*", build):
        fail("set XDRIP_BUILD_NUMBER to the ASC-confirmed positive number")
    if checked_build.group(1) != build:
        fail("set checked-in CURRENT_PROJECT_VERSION to the confirmed build before testing")
    return version.group(1), build


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
                         ".env", ".netrc", "credentials.json"} or
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


def checkpoint(root, path, version, build, tag):
    ensure_origin()
    if os.environ.get("XDRIP_ASC_BUILD_CONFIRMED") != "YES":
        fail("confirm the unused build number in App Store Connect first")
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
                state.get("tests", {}).get("verificationPassed") is not True):
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
        run([str(ROOT / "scripts/local-build.sh"), "all"], env=env)
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
            "baseCommit": base, "tree": tree, "testedAt": utc_now(),
            "tests": {
                "verificationPassed": True,
                "counts": counts,
                "resultBundle": str(test_root / "results/Verification.xcresult"),
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
               XDRIP_RELEASE_STATE_PATH=str(path), XDRIP_ASC_BUILD_CONFIRMED="YES")
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
    for phase, app in (
        ("archive-development", root / "build/archive/xdrip.xcarchive/Products/Applications/xdrip.app"),
        ("export-distribution", root / "build/export-verification/Payload/xdrip.app"),
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
    if os.environ.get("XDRIP_GO_UPLOAD") != "YES":
        fail("upload requires the user's explicit GO UPLOAD and XDRIP_GO_UPLOAD=YES")
    if os.environ.get("XDRIP_ASC_UPLOAD_SLOT_CONFIRMED") != "YES":
        fail("recheck this exact app/version/build in App Store Connect before upload")
    ipa = Path(state["ipa"])
    if sha256_file(ipa) != state["ipaSha256"]:
        fail("verified IPA bytes changed")
    if sha256_tree(Path(state["archive"])) != state["archiveSha256"]:
        fail("verified release archive changed")
    attempt = root / "upload-attempt.json"
    if attempt.exists():
        fail("upload was already attempted; inspect Apple before any manual retry")
    options = root / "UploadOptions.plist"
    options.write_bytes(plistlib.dumps({
        "destination": "upload", "manageAppVersionAndBuildNumber": False,
        "method": "app-store-connect", "signingStyle": "automatic", "teamID": TEAM,
        "testFlightInternalTestingOnly": True, "uploadSymbols": True,
    }))
    attempt.write_text(json.dumps({"startedAt": utc_now(), "checkpoint": state["checkpoint"],
                                   "tag": state["tag"], "ipaSha256": state["ipaSha256"]}, indent=2) + "\n",
                       encoding="utf-8")
    log = root / "upload.log"
    code = run(["xcodebuild", "-exportArchive", "-archivePath", state["archive"],
                "-exportPath", str(root / "upload-export"), "-exportOptionsPlist", str(options),
                "-allowProvisioningUpdates"], log=log)
    if code != 0 or "Upload succeeded" not in log.read_text(encoding="utf-8", errors="replace"):
        fail("upload outcome is uncertain; inspect App Store Connect before any retry")
    state.update(step="uploaded", uploadedAt=utc_now(), uploadLog=str(log))
    save_state(path, state)
    print("Upload command succeeded; verify Apple's processing status for", APP_ID, state["version"], state["build"])


def status(root, path, state):
    require_step(state, "uploaded", "status-recorded")
    ensure_origin()
    ensure_clean()
    if git("rev-parse", f"refs/tags/{state['tag']}^{{}}") != state["checkpoint"]:
        fail("TestFlight tag moved from the release checkpoint")
    later_paths = git("diff", "--name-only", state["checkpoint"], "HEAD").splitlines()
    if any(name != DOC.as_posix() for name in later_paths):
        fail("app/project code changed since tag; stop before status commit")
    value = os.environ.get("XDRIP_ASC_STATUS", "")
    if value not in {"received", "processing", "internal-testing"}:
        fail("set XDRIP_ASC_STATUS to received, processing or internal-testing after checking Apple")
    url = os.environ.get("XDRIP_ASC_BUILD_URL", "")
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.netloc != "appstoreconnect.apple.com" or \
            f"/apps/{APP_ID}/testflight/ios/" not in parsed.path:
        fail("XDRIP_ASC_BUILD_URL must be the existing app's exact TestFlight build URL")
    group = os.environ.get("XDRIP_ASC_INTERNAL_GROUP", "")
    if value == "internal-testing" and not group:
        fail("record the existing internal tester group in XDRIP_ASC_INTERNAL_GROUP")
    labels = {"received": "Upload modtaget", "processing": "Apple behandler",
              "internal-testing": "Tilgængelig for intern TestFlight-test"}
    start = f"<!-- {state['tag']}:start -->"
    end = f"<!-- {state['tag']}:end -->"
    counts = state["tests"]["counts"]
    text = (f"{start}\n### TestFlight {state['version']} ({state['build']})\n\n"
            f"- Kildecommit og tag: `{state['checkpoint']}` / `{state['tag']}`.\n"
            f"- Tests: {counts['passedTests']}/{counts['totalTestCount']} bestået; "
            f"{counts['failedTests']} fejlet; {counts['skippedTests']} skipped. "
            "iPhone- og Watch-simulatorbuilds bestod.\n"
            f"- Apple-status ({utc_now()}): [{labels[value]}]({url}).\n"
            + ("- Eksisterende intern gruppe: tilknyttet; navn udeladt af Git.\n" if group else "")
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
        existing = existing.rstrip("\n") + "\n\n" + text
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "checkpoint", "publish", "build", "verify", "upload", "status"))
    args = parser.parse_args()
    os.chdir(ROOT)
    version, build = version_and_build()
    root, path = release_paths(version, build)
    tag = f"testflight-{version}-{build}"
    ensure_origin()
    if args.command == "check":
        print("Repository:", ROOT)
        print("Candidate:", version, build, tag)
        print("Git:", git("status", "--short", "--branch"))
        print("Release state:", path if path.exists() else "not started")
        forbidden_index_paths()
        return
    if args.command == "checkpoint":
        checkpoint(root, path, version, build, tag)
        return
    state = load_state(path, version, build)
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
