#!/usr/bin/env python3
"""Receipts for explicitly registered local build caches. Never deletes files."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import time

from build_lock import build_lock

COMMANDS = {"test-ci", "test-all", "build", "all", "release-test"}
RECEIPT = "local-run-receipt.json"


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1048576), b""):
            digest.update(block)
    return digest.hexdigest()


def checked_directory(path):
    path = Path(path)
    require(path.is_absolute() and path == path.resolve(), "Path must be canonical: " + str(path))
    require(path.is_dir(), "Directory missing: " + str(path))
    return path


def inventory(base, content=False):
    """No links/special files; directory mtimes are deliberately not included."""
    checked_directory(base)
    rows = {}
    def onerror(error):
        raise error
    for parent, dirs, names in os.walk(base, followlinks=False, onerror=onerror):
        for name in dirs:
            require(not (Path(parent) / name).is_symlink(), "Linked directory in local run")
        for name in sorted(names):
            if name == ".DS_Store":
                continue
            path = Path(parent) / name
            info = path.lstat()
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1,
                    "Linked or special file in local run: " + str(path))
            rows[path.relative_to(base).as_posix()] = (
                sha256(path) if content else
                [info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns])
    return rows


def atomic_json(path, data):
    require(not path.is_symlink(), "Linked receipt/registry")
    temp = path.with_name(path.name + ".tmp-" + str(os.getpid()))
    with temp.open("x", encoding="utf-8") as stream:
        json.dump(data, stream, sort_keys=True)
        stream.write("\n")
    os.replace(temp, path)


def registry_path(repo, output):
    folder = repo / "build/release-automation/local-runs"
    folder.mkdir(parents=True, exist_ok=True)
    checked_directory(folder)
    return folder / (hashlib.sha256(str(output).encode()).hexdigest() + ".json")


def register(repo, output):
    atomic_json(registry_path(repo, output), {"schemaVersion": 1, "outputRoot": str(output),
                                             "receipt": str(output / RECEIPT)})


def evidence(output, command, legacy=False):
    """Inspect raw logs/XCResult; a manually written summary alone is insufficient."""
    require(command in COMMANDS, "Unsupported local command")
    logs = []
    result = None
    if command in {"test-ci", "all"}:
        logs.append(("xctest-verification.log", "TEST"))
        result = output / "results/Verification.xcresult"
    elif command in {"test-all", "release-test"}:
        logs.append(("all-xctest.log", "TEST"))
        result = output / "results/AllTests.xcresult"
    if command in {"build", "all", "release-test"}:
        logs += [("iphone-build.log", "BUILD"), ("watch-build.log", "BUILD")]
    for name, kind in logs:
        path = output / "logs" / name
        require(path.is_file() and not path.is_symlink(), "Required log missing: " + name)
        markers = re.findall(r"\*\* (?:TEST|BUILD) (SUCCEEDED|FAILED|CANCELLED) \*\*",
                             path.read_text(errors="replace"))
        require(markers and markers[-1] == "SUCCEEDED" and
                "** " + kind + " SUCCEEDED **" in path.read_text(errors="replace"),
                "No successful terminal marker: " + name)
    counts = None
    if result is not None:
        checked_directory(result)
        raw = subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary",
                                       "--path", str(result)], text=True)
        summary = json.loads(raw)
        counts = {key: summary[key] for key in
                  ("totalTestCount", "passedTests", "failedTests", "skippedTests")}
        require(summary.get("result") == "Passed" and counts["totalTestCount"] > 0
                and counts["passedTests"] == counts["totalTestCount"]
                and counts["failedTests"] == counts["skippedTests"] == 0,
                "XCResult does not show all tests passed")
    source = None
    if legacy:
        require(result is not None, "Legacy registration requires an XCResult")
        saved = json.loads((output / "results/stability-summary.json").read_text())
        require(saved.get("verificationPassed") is True and saved.get("counts") == counts
                and Path(saved.get("resultBundle", "")).resolve() == result,
                "Legacy summary disagrees with raw XCResult")
        source = saved.get("sourceCommit")
        require(isinstance(source, str) and re.fullmatch(r"[0-9a-f]{40}", source),
                "Legacy evidence has no source commit")
    hashes = {}
    for name in ("logs", "results"):
        hashes[name] = inventory(output / name, content=True)
    require(hashes["logs"] and (result is None or hashes["results"]), "Empty local evidence")
    newest = max((output / name / relative).stat().st_mtime_ns
                 for name, files in hashes.items() for relative in files)
    return {"counts": counts, "sourceCommitFromEvidence": source,
            "hashes": hashes, "latestEvidenceMtimeNs": newest}


def start(repo, output, derived, command, cache_mode):
    repo, output, derived = map(checked_directory, (repo, output, derived))
    require(command in COMMANDS and cache_mode in {"shared", "dedicated"}, "Invalid local run")
    if cache_mode == "dedicated":
        require(derived == output / "DerivedData", "Dedicated cache must belong to output root")
    path = output / RECEIPT
    require(not path.exists() and not path.is_symlink(), "Output already has a local run receipt; use a new output")
    receipt = {"schemaVersion": 1, "repoRoot": str(repo), "outputRoot": str(output),
               "derivedData": str(derived), "command": command, "cacheMode": cache_mode,
               "status": "running", "startedAtNs": time.time_ns(), "provenance": "local-build"}
    atomic_json(path, receipt)
    register(repo, output)


def finish(output, exit_code):
    output = checked_directory(output)
    path = output / RECEIPT
    require(not path.is_symlink(), "Linked run receipt")
    receipt = json.loads(path.read_text())
    require(receipt.get("status") == "running" and receipt.get("outputRoot") == str(output),
            "Run receipt is not running")
    receipt.update(status="failed", exitCode=exit_code, finishedAtNs=time.time_ns())
    if exit_code == 0:
        try:
            if receipt["cacheMode"] == "dedicated":
                receipt["evidence"] = evidence(output, receipt["command"])
                receipt["cacheInventory"] = inventory(Path(receipt["derivedData"]))
            receipt["status"] = "completed"
        except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
            receipt.update(status="unverified", reason=str(error))
    atomic_json(path, receipt)


def inspect_legacy(repo, output, command):
    repo, output = map(checked_directory, (repo, output))
    derived = checked_directory(output / "DerivedData")
    proof = evidence(output, command, legacy=True)
    check = subprocess.run(["git", "cat-file", "-e", proof["sourceCommitFromEvidence"] + "^{commit}"],
                           cwd=repo, text=True, capture_output=True)
    require(check.returncode == 0, "Recorded legacy source commit is absent from this repository")
    return {"schemaVersion": 1, "repoRoot": str(repo), "outputRoot": str(output),
            "derivedData": str(derived), "command": command, "cacheMode": "dedicated",
            "status": "legacy-inspected", "provenance": "explicit-legacy-registration",
            "inspectedAt": datetime.now(timezone.utc).isoformat(),
            "evidence": proof, "cacheInventory": inventory(derived)}


def validate(receipt, repo, output, cutoff_ns):
    """Called under cleanup's lock. Missing/reused/shared caches are never eligible."""
    require(receipt.get("schemaVersion") == 1 and receipt.get("repoRoot") == str(repo)
            and receipt.get("outputRoot") == str(output), "Local receipt ownership mismatch")
    checked_directory(output)
    derived = checked_directory(Path(receipt["derivedData"]))
    require(receipt.get("cacheMode") == "dedicated" and derived == output / "DerivedData",
            "Shared or unrelated local cache is preserved")
    require(receipt.get("status") in {"completed", "legacy-inspected"}, "Local run did not complete")
    require(receipt.get("command") in COMMANDS, "Unknown local command")
    expected = "local-build" if receipt["status"] == "completed" else "explicit-legacy-registration"
    require(receipt.get("provenance") == expected, "Unknown local receipt provenance")
    if receipt["status"] == "completed":
        require(receipt.get("exitCode") == 0 and receipt["finishedAtNs"] < cutoff_ns,
                "Newer or failed local run is preserved")
    proof = receipt["evidence"]
    require(proof["latestEvidenceMtimeNs"] < cutoff_ns, "Local evidence is newer than current release")
    for name in ("logs", "results"):
        require(inventory(output / name, content=True) == proof["hashes"][name],
                "Local test/build evidence changed")
    original = receipt["cacheInventory"]
    now = inventory(derived)
    # Missing leaves are allowed after selective cleanup. New or changed leaves
    # indicate cache reuse; stop even if those leaves would not be deleted.
    require(all(original.get(name) == row for name, row in now.items()),
            "Local cache was reused or changed after completion/inspection")
    return derived


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("start", "finish", "inspect-legacy", "register-legacy"))
    parser.add_argument("--repo", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--derived", type=Path)
    parser.add_argument("--command", choices=sorted(COMMANDS))
    parser.add_argument("--cache-mode", choices=("shared", "dedicated"))
    parser.add_argument("--exit-code", type=int)
    args = parser.parse_args()
    with build_lock():
        output = args.output.resolve()
        if args.action == "finish":
            require(args.exit_code is not None, "Missing exit code")
            finish(output, args.exit_code)
        elif args.action == "start":
            start(args.repo.resolve(), output, args.derived.resolve(), args.command, args.cache_mode)
        else:
            receipt = inspect_legacy(args.repo.resolve(), output, args.command)
            if args.action == "register-legacy":
                path = output / RECEIPT
                require(not path.exists() and not path.is_symlink(), "Local receipt already exists")
                atomic_json(path, receipt)
                register(args.repo.resolve(), output)
            print(json.dumps({key: value for key, value in receipt.items() if key != "cacheInventory"}, indent=2))


if __name__ == "__main__":
    main()
