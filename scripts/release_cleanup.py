"""Fail-closed retention for reproducible files of completed TestFlight builds.

Current, newer and incomplete releases are untouched. IPA, XCArchive, dSYM,
XCResult, logs and status remain. No Apple mutations. Use release-testflight.py.
"""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import zipfile

from build_lock import build_lock
import local_run_receipt

class CleanupBlocked(RuntimeError):
    pass

def require(ok, reason):
    if not ok:
        raise CleanupBlocked(reason)

def command(args, cwd=None):
    p = subprocess.run(args, cwd=cwd, text=True, capture_output=True,
                       env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"))
    require(p.returncode == 0, "Cannot verify: " + str(args[0]))
    return p.stdout

def read_json(p):
    require(not p.is_symlink(), "Symlinked metadata: " + str(p))
    return json.loads(p.read_text())

def fingerprint(p):
    s = p.lstat()
    # File Provider may hydrate an old cache file and change ctime while
    # identity, type, size and mtime stay stable. Keep those checks;
    # hard links are checked again immediately before deletion.
    return [s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns]

def hash_file(p):
    h = hashlib.sha256()
    with p.open("rb") as f:
        for b in iter(lambda: f.read(1048576), b""):
            h.update(b)
    return h.hexdigest()

def idle():
    # Read arguments in memory to recognize script wrappers, never log credentials.
    rows = command(["ps", "-axo", "pid=,ppid=,comm="]).splitlines()
    processes = {}
    for row in rows:
        parts = row.strip().split(None, 2)
        require(len(parts) == 3, "Incomplete process inventory")
        processes[int(parts[0])] = (int(parts[1]), parts[2])
    require(bool(processes), "Empty process inventory")
    ancestors, pid = set(), os.getpid()
    while pid in processes and pid not in ancestors:
        ancestors.add(pid)
        pid = processes[pid][0]
    names = {"Xcode", "xcodebuild", "XCBBuildService", "SWBBuildService", "SwiftBuild",
             "swift", "swiftc", "swift-frontend", "clang", "clang++", "ld", "xctest",
             "simctl", "altool", "iTMSTransporter", "Transporter", "codesign"}
    blocked = []
    for pid, (_, comm) in processes.items():
        name = Path(comm).name
        if name in names or name.endswith(".xctest") or "XCTRunner" in name:
            blocked.append((pid, name))
        elif pid not in ancestors and name.lower().startswith(("python", "bash", "zsh", "sh", "java")):
            p = subprocess.run(["ps", "-p", str(pid), "-o", "args="], text=True, capture_output=True)
            if p.returncode not in (0, 1):
                raise CleanupBlocked("Cannot inspect process")
            if any(x in p.stdout for x in ("release-testflight.py", "local-build.sh", "iTMSTransporter")):
                blocked.append((pid, name))
    require(not blocked, "Active Xcode/build/test/upload processes: " + str(blocked))

def git_snapshot(root):
    # Inspect relocated historical worktrees without repairing or pruning Git data.
    common = (root / command(["git", "rev-parse", "--git-common-dir"], root).strip()).resolve()
    entries = [(common.parent, common)]
    for admin in sorted((common / "worktrees").glob("*")):
        original = Path((admin / "gitdir").read_text().strip()).parent
        work = original if original.is_dir() else root.parent / original.name
        require(work.is_dir(), "Unknown worktree location: " + str(original))
        pointer = (work / ".git").read_text().strip()
        require(pointer.startswith("gitdir: ") and Path(pointer[8:]).name == admin.name,
                "Uncertain relocated worktree: " + str(work))
        entries.append((work, admin))
    result = {}
    for work, admin in entries:
        args = ["git", "--git-dir=" + str(admin), "--work-tree=" + str(work)]
        result[str(work)] = {
            "head": command(args + ["rev-parse", "HEAD"]).strip(),
            "status": command(args + ["status", "--porcelain=v1", "-uall"]),
            "index": hash_file(admin / "index") if (admin / "index").exists() else None,
        }
    result["refs"] = command(["git", "show-ref"], root)
    return result

def confirm_apple(client, state):
    version, number = state["version"], state["build"]
    snapshot = client.snapshot(version)
    require(snapshot.get("appID") == "6795645396" and snapshot.get("version") == version
            and snapshot.get("bundleID") == "com.GFZ896KN66.xdripswift" and snapshot.get("platform") == "IOS",
            "Apple snapshot identifies another app or version")
    rows = snapshot["builds"] + snapshot["uploads"]
    require(all(str(r["build"]).isdigit() and int(r["build"]) <= int(number) for r in rows),
            "Newer or unrecognized Apple build/upload; preserve everything")
    matches = [r for r in snapshot["builds"] if r["version"] == version and r["build"] == number]
    require(len(matches) == 1, "Current Apple build not unambiguous")
    r = matches[0]
    require(r.get("processingState") == "VALID" and r.get("betaInternalState") == "IN_BETA_TESTING"
            and r.get("buildAudienceType") == "INTERNAL_ONLY" and r.get("expired") is False,
            "Current build is not Internal / Testing")
    require(r["id"] == state["appleObservation"]["buildRecord"]["id"], "Apple build ID changed")
    groups = [g for page in client._pages("/v1/apps/6795645396/betaGroups?limit=200")
              for g in page["data"] if g.get("attributes", {}).get("name") == "Ole Internal"]
    require(len(groups) == 1 and groups[0]["attributes"].get("isInternalGroup") is True,
            "Internal group not unambiguous")
    require(r["id"] in client._group_build_ids(groups[0]["id"]), "Build absent from Ole Internal")
    return {"observedAt": snapshot["observedAt"], "build": r, "groupLinked": True}

CACHE_DIRS = {"Index.noindex", "ModuleCache.noindex", "SDKStatCaches.noindex",
              "SDKExplicitPrecompiledModules", "CompilationCache.noindex"}
OBJECT_SUFFIXES = {".o", ".pcm", ".pch", ".swiftmodule", ".swiftdoc", ".swiftsourceinfo",
                   ".swiftdeps", ".d"}
PROTECTED_SUFFIXES = {".json", ".jsonl", ".log", ".xcactivitylog", ".xcresult", ".xcarchive",
                      ".dsym", ".ipa", ".dia", ".app", ".appex", ".framework", ".swift", ".h", ".m", ".mm", ".c", ".cpp", ".txt",
                      ".plist", ".sqlite", ".db", ".yaml", ".yml", ".p8", ".mobileprovision"}
PROTECTED_NAMES = {"Logs", "TestResults", "Products", ".git", "SourcePackages", "Checkouts", "BuildProductsPath", "InstallationBuildProductsLocation"}

def disposable(relative):
    parts = relative.parts
    if any(p in PROTECTED_NAMES or Path(p).suffix.lower() in PROTECTED_SUFFIXES for p in parts):
        return False
    if parts[0] in CACHE_DIRS:
        return True
    return parts[:2] == ("Build", "Intermediates.noindex") and relative.suffix in OBJECT_SUFFIXES

def scan_derived(dd):
    require(dd.is_dir() and not dd.is_symlink(), "Unknown DerivedData root")
    files = []
    for instance in sorted(dd.iterdir()):
        # Finder may create this metadata file while inspecting DerivedData.
        # It is neither a build instance nor a deletion target.
        if instance.name == ".DS_Store" and instance.is_file() and not instance.is_symlink():
            continue
        require(instance.is_dir() and not instance.is_symlink(), "Unknown DerivedData instance")
        def error(e):
            raise e
        for base, dirs, names in os.walk(instance, followlinks=False, onerror=error):
            # Product links and diagnostic trees are never visited or modified.
            dirs[:] = [d for d in dirs if d not in PROTECTED_NAMES
                       and Path(d).suffix.lower() not in PROTECTED_SUFFIXES]
            # Reject links in the remaining candidate areas; never follow targets.
            for name in dirs + names:
                p = Path(base) / name
                require(not p.is_symlink(), "Symlink inside DerivedData: " + str(p))
            for name in names:
                p = Path(base) / name
                require(p.is_file(), "Special file inside DerivedData")
                if disposable(p.relative_to(instance)):
                    s = p.stat()
                    require(s.st_nlink == 1, "Hardlinked cache file")
                    files.append({"path": str(p), "fingerprint": fingerprint(p),
                                  "allocatedBytes": s.st_blocks * 512, "logicalBytes": s.st_size})
    return files

PRODUCT_PROTECTED_SUFFIXES = {".dsym", ".xcresult", ".xcarchive", ".ipa", ".swift", ".h",
                              ".m", ".mm", ".c", ".cpp", ".json", ".jsonl", ".log",
                              ".xcactivitylog", ".plist", ".yaml", ".yml", ".p8",
                              ".mobileprovision", ".md", ".txt", ".sqlite", ".db"}

def scan_generated_products(dd):
    """Select only generated product leaves, never release evidence or source."""
    files = []
    for instance in sorted(dd.iterdir()):
        if instance.name == ".DS_Store" and instance.is_file() and not instance.is_symlink():
            continue
        require(instance.is_dir() and not instance.is_symlink(), "Unknown DerivedData instance")
        products = instance / "Build/Products"
        if not products.exists():
            continue
        require(products.is_dir() and not products.is_symlink(), "Unknown product root")
        for base, dirs, names in os.walk(products, followlinks=False):
            for name in dirs + names:
                require(not (Path(base) / name).is_symlink(), "Symlink in generated products")
            dirs[:] = [d for d in dirs if Path(d).suffix.lower() not in PRODUCT_PROTECTED_SUFFIXES
                       and d not in {".git", "Logs", "TestResults", "SourcePackages"}]
            for name in names:
                p = Path(base) / name
                require(p.is_file(), "Special file in generated products")
                if p.suffix.lower() in PRODUCT_PROTECTED_SUFFIXES:
                    continue
                st = p.stat()
                require(st.st_nlink == 1, "Hardlinked generated product")
                files.append({"path": str(p), "fingerprint": fingerprint(p),
                              "allocatedBytes": st.st_blocks * 512, "logicalBytes": st.st_size,
                              "reason": "rebuildable Xcode product of a completed release"})
    return files

def verified_extraction(extracted, ipa):
    """Only remove exact, byte-identical expanded copies of the checked IPA."""
    require(extracted.is_dir() and not extracted.is_symlink(), "Unknown IPA extraction")
    actual = {}
    for base, dirs, names in os.walk(extracted, followlinks=False):
        for name in dirs + names:
            require(not (Path(base) / name).is_symlink(), "Link in IPA extraction")
        for name in names:
            p = Path(base) / name
            require(p.is_file() and p.stat().st_nlink == 1, "Special or hardlinked IPA copy")
            relative = p.relative_to(extracted).as_posix()
            require(relative not in actual, "Duplicate IPA extraction path")
            actual[relative] = p
    # A prior successful run leaves only empty directory containers.
    if not actual:
        return []
    with zipfile.ZipFile(ipa) as package:
        members = {i.filename: i for i in package.infolist() if not i.is_dir()}
        require(len(members) == sum(not i.is_dir() for i in package.infolist()),
                "Duplicate IPA member")
        require(set(actual) == set(members), "IPA extraction differs from archive")
        files = []
        for name, p in sorted(actual.items()):
            info = members[name]
            require(name.startswith(("Payload/", "Symbols/")) and ".." not in Path(name).parts,
                    "Unexpected IPA path")
            require(p.stat().st_size == info.file_size, "IPA copy size differs")
            digest = hashlib.sha256()
            with package.open(info) as stream:
                for block in iter(lambda: stream.read(1048576), b""):
                    digest.update(block)
            require(hash_file(p) == digest.hexdigest(), "IPA copy content differs")
            st = p.stat()
            files.append({"path": str(p), "fingerprint": fingerprint(p),
                          "allocatedBytes": st.st_blocks * 512, "logicalBytes": st.st_size,
                          "reason": "byte-identical expanded copy of retained IPA"})
    return files

def confirm_release_links(candidates):
    """Keep approved external release links fixed until each cache unlink."""
    for candidate in candidates:
        for link in candidate.get("releaseLinks", ()):
            path, target = Path(link["path"]), Path(link["target"])
            require(path.is_symlink() and fingerprint(path) == link["fingerprint"]
                    and Path(os.readlink(path)) == target and path.resolve() == target
                    and target.is_dir() and not target.is_symlink(),
                    "Release link changed during cleanup")

def release_candidates(root, current):
    candidates, kept = [], []
    completed_prior = []
    for folder in (root / "build").glob("testflight-*"):
        match = re.fullmatch(r"testflight-(\d+(?:\.\d+)+)-(\d+)", folder.name)
        if not match or match[1] != current["version"] or int(match[2]) >= int(current["build"]):
            continue
        try:
            state = read_json(folder / "release-state.json")
        except (CleanupBlocked, OSError, ValueError, KeyError):
            continue
        if (state.get("version"), state.get("build")) == (match[1], match[2]) and (
                state.get("step") == "status-recorded" and state.get("appleStatus") == "internal-testing"
                and state.get("tests", {}).get("verificationPassed") is True):
            completed_prior.append(int(match[2]))
    latest_prior = max(completed_prior, default=None)
    protected = []
    for folder in (root / "build").glob("testflight-*"):
        match = re.fullmatch(r"testflight-(\d+(?:\.\d+)+)-(\d+)", folder.name)
        if not match or int(match[2]) >= int(current["build"]) or (
                match[1] == current["version"] and int(match[2]) == latest_prior):
            protected.extend((folder.resolve(), (folder / "build").resolve(), (folder / "test").resolve()))
    for folder in sorted((root / "build").glob("testflight-*")):
        m = re.fullmatch(r"testflight-(\d+(?:\.\d+)+)-(\d+)", folder.name)
        if not m or int(m[2]) >= int(current["build"]) or (
                m[1] == current["version"] and int(m[2]) == latest_prior):
            reason = "latest previous verified build" if m and int(m[2]) == latest_prior else "current/newer/unknown build"
            kept.append({"path": str(folder), "reason": reason})
            continue
        try:
            require(not folder.is_symlink(), "Symlinked release root")
            s = read_json(folder / "release-state.json")
            require((s["version"], s["build"]) == (m[1], m[2]), "Release identity mismatch")
            require(s.get("step") == "status-recorded" and s.get("appleStatus") == "internal-testing",
                    "Release not completed Internal / Testing")
            require(s.get("tests", {}).get("verificationPassed") is True, "Test receipt missing")
            require(command(["git", "rev-parse", "refs/tags/" + s["tag"] + "^{}"], root).strip()
                    == s["checkpoint"], "Source tag does not match")
            out = folder / "build"
            external_output = None
            release_links = []
            if out.is_symlink():
                external_output = out.resolve()
                require(external_output == Path(s.get("signingOutputRoot", ""))
                        and external_output != root and root not in external_output.parents
                        and external_output not in root.parents,
                        "Unknown external signing output")
                require(Path(os.readlink(out)) == external_output
                        and external_output.is_dir() and not external_output.is_symlink(),
                        "Unknown external signing output")
                release_links.append({"path": str(out), "target": str(external_output),
                                      "fingerprint": fingerprint(out)})
            else:
                require(out.is_dir(), "Missing build output")
            ipa, archive = out / "export/xdrip.ipa", out / "archive/xdrip.xcarchive"
            require(ipa.is_file() and not ipa.is_symlink() and hash_file(ipa) == s["ipaSha256"],
                    "IPA missing or changed")
            require(archive.is_dir() and not archive.is_symlink() and (archive / "dSYMs").is_dir(),
                    "Archive or dSYMs missing")
            require((folder / "test/results/AllTests.xcresult").is_dir()
                    and (folder / "apple-status.json").is_file(), "Release evidence missing")
            local = []
            for dd in (folder / "test/DerivedData", out / "DerivedData"):
                if not dd.exists():
                    continue
                require(not dd.parent.is_symlink() or dd.parent == out, "Unknown parent link")
                real = dd.resolve()
                # Approved external build link is resolved once. Reject further links.
                require(real.parent == dd.parent.resolve(), "Unexpected DerivedData target")
                require(not any(real == p or p in real.parents or real in p.parents for p in protected),
                        "DerivedData overlaps a protected build")
                local.append({"build": s["build"], "path": str(real),
                              "files": scan_derived(real) + scan_generated_products(real),
                              "releaseLinks": release_links})
            extraction_roots = [out / "export-verification"]
            verify_root = folder / "verify"
            if verify_root.exists() or verify_root.is_symlink():
                if verify_root.is_symlink():
                    # The release exporter may link verify to the same approved
                    # external signing output. Accept only that direct target.
                    expected = external_output / "verification" if external_output else None
                    require(expected is not None and Path(os.readlink(verify_root)) == expected
                            and expected.is_dir() and not expected.is_symlink(), "Unknown verify root")
                    require(not any(expected == p or p in expected.parents or expected in p.parents
                                    for p in protected), "Verify root overlaps protected build")
                    release_links.append({"path": str(verify_root), "target": str(expected),
                                          "fingerprint": fingerprint(verify_root)})
                else:
                    require(verify_root.is_dir(), "Unknown verify root")
                extraction_roots += sorted(verify_root.glob("ipa-*"))
            for extracted in extraction_roots:
                if not extracted.exists():
                    continue
                real = extracted.resolve()
                require(real == extracted.parent.resolve() / extracted.name,
                        "Unexpected IPA extraction link")
                require(not any(real == p or p in real.parents or real in p.parents for p in protected),
                        "IPA extraction overlaps protected build")
                local.append({"build": s["build"], "path": str(real),
                              "files": verified_extraction(real, ipa),
                              "releaseLinks": release_links})
            candidates.extend(local)
        except (CleanupBlocked, OSError, ValueError, KeyError, zipfile.BadZipFile) as e:
            kept.append({"path": str(folder), "reason": str(e)})
    return candidates, kept

def ensure_unopened(paths):
    # lsof exit 1 + empty output is its documented no-match result. Any warning fails closed.
    for path in paths:
        p = subprocess.run(["/usr/sbin/lsof", "-nP", "+D", path], text=True, capture_output=True)
        require(p.returncode == 1 and not p.stdout.strip() and not p.stderr.strip(),
                "Open files or uncertain lsof result: " + path)


def local_candidates(root, current):
    """Only explicitly registered, immutable completed local runs are considered."""
    candidates, kept = [], []
    registry = root / "build/release-automation/local-runs"
    if not registry.exists():
        return candidates, kept
    require(not registry.is_symlink(), "Linked local-run registry")
    cutoff = current.get("statusRecordedAt")
    protected = [root, Path.home() / "DeveloperBuildData/xDrip/DerivedData"]
    for release in (root / "build").glob("testflight-*"):
        protected.extend((release.resolve(), (release / "build").resolve(),
                          (release / "test").resolve(), (release / "verify").resolve()))
    for registration in sorted(registry.glob("*.json")):
        try:
            row = read_json(registration)
            output = Path(row["outputRoot"])
            path = Path(row["receipt"])
            require(row.get("schemaVersion") == 1 and path == output / local_run_receipt.RECEIPT,
                    "Invalid local registration")
            require(output.is_absolute() and output == output.resolve()
                    and output != root and output not in root.parents,
                    "Unknown local output path")
            if root in output.parents:
                require(root / "build" in output.parents, "Local output overlaps source tree")
            receipt = read_json(path)
            # All release roots, including incomplete and previous releases, are
            # handled only by the stricter release-specific rules above.
            dd = output / "DerivedData"
            require(not any(p == dd or p in dd.parents or dd in p.parents
                            for p in protected[1:]), "Local cache overlaps a protected build/cache")
            require(cutoff is not None, "Current release has no completion timestamp")
            cutoff_ns = int(datetime.fromisoformat(cutoff).timestamp() * 1_000_000_000)
            derived = local_run_receipt.validate(receipt, root, output, cutoff_ns)
            candidates.append({"kind": "local-run", "path": str(derived),
                               "outputRoot": str(output), "receiptPath": str(path),
                               "receiptSha256": hash_file(path),
                               "registrationPath": str(registration),
                               "registrationSha256": hash_file(registration),
                               "files": scan_derived(derived) + scan_generated_products(derived)})
        except (CleanupBlocked, OSError, ValueError, KeyError, TypeError) as error:
            kept.append({"path": str(registration), "reason": str(error)})
    return candidates, kept


def confirm_local_receipts(candidates):
    for candidate in candidates:
        if candidate.get("kind") != "local-run":
            continue
        for prefix in ("receipt", "registration"):
            path = Path(candidate[prefix + "Path"])
            require(path == path.resolve() and path.is_file() and not path.is_symlink()
                    and hash_file(path) == candidate[prefix + "Sha256"],
                    "Local run registration/receipt changed during cleanup")

def safe_unlink(item):
    # Open every parent with NOFOLLOW and unlink relative to an open directory.
    p = Path(item["path"])
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in p.parts[1:-1]:
            new = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = new
        s = os.stat(p.name, dir_fd=fd, follow_symlinks=False)
        now = [s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns]
        require(now == item["fingerprint"] and stat.S_ISREG(s.st_mode) and s.st_nlink == 1,
                "Cache changed since plan")
        os.unlink(p.name, dir_fd=fd)
    finally:
        os.close(fd)

def preservation_inventory(root, deletions, local_outputs=()):
    """Metadata digest of every retained release file, including external signing output.

    Avoid reading multi-GiB XCResult/archives just to hash them. IPA content is
    separately checked for each deletion-eligible release. Directory mtimes may
    change when cache leaves are removed, so only files and links are compared.
    """
    result = {}
    for release in sorted(set((root / "build").glob("testflight-*")) | set(local_outputs)):
        bases = {release.resolve()}
        for name in ("build", "verify"):
            child = release / name
            if child.is_symlink():
                require(child.is_dir(), "Broken release output link")
                bases.add(child.resolve())
        digest, count = hashlib.sha256(), 0
        def error(e):
            raise e
        for base in sorted(bases):
            for parent, dirs, names in os.walk(base, followlinks=False, onerror=error):
                dirs.sort()
                links = [d for d in dirs if (Path(parent) / d).is_symlink()]
                for name in sorted(names + links):
                    # Finder owns this volatile metadata, not the release.
                    if name == ".DS_Store":
                        continue
                    p = Path(parent) / name
                    if str(p) in deletions:
                        continue
                    st = p.lstat()
                    value = [str(p), st.st_dev, st.st_ino, st.st_mode, st.st_size, st.st_mtime_ns]
                    if p.is_symlink():
                        value.append(os.readlink(p))
                    digest.update(json.dumps(value).encode() + b"\0")
                    count += 1
        result[str(release)] = {"retainedFiles": count, "metadataSha256": digest.hexdigest()}
    return result


BUILD_AREA_LIMIT_BYTES = 15 * 1024 ** 3

def build_area_usage(root, snapshot, local_outputs=()):
    """Count worktree build areas and external signed output without following links twice."""
    paths = set()
    works = [Path(p) for p in snapshot if p != "refs"]
    for work in works:
        candidate = work / "build"
        if candidate.exists():
            require(candidate.is_dir() and not candidate.is_symlink(), "Unknown worktree build root")
            paths.add(candidate.resolve())
    for folder in (root / "build").glob("testflight-*"):
        out = folder / "build"
        if out.is_symlink():
            target = out.resolve()
            require(target.is_dir(), "Broken signing output link")
            if not any(target == work or work in target.parents for work in works):
                paths.add(target)
    central = Path.home() / "DeveloperBuildData/xDrip"
    if central.exists():
        require(central.is_dir() and not central.is_symlink(), "Unknown central build root")
        paths.add(central.resolve())
    paths.update(Path(p).resolve() for p in local_outputs)
    # A local checkout or signing directory may itself live under the central
    # area. Count its outermost physical directory once, never add it twice.
    paths = {p for p in paths if not any(other in p.parents for other in paths)}
    result = {}
    for path in sorted(paths):
        result[str(path)] = int(command(["du", "-sk", str(path)]).split()[0]) * 1024
    return {"paths": result, "totalBytes": sum(result.values()),
            "limitBytes": BUILD_AREA_LIMIT_BYTES,
            "overLimitBytes": max(0, sum(result.values()) - BUILD_AREA_LIMIT_BYTES)}

def cleanup(root, client, apply=False):
    root = root.resolve()
    with build_lock():
        idle()
        require(not (root / "build").is_symlink(), "Unknown build-root link")
        active = read_json(root / "build/release-automation/active.json")
        require(re.fullmatch(r"\d+(?:\.\d+)+", str(active.get("version", "")))
                and re.fullmatch(r"[1-9]\d*", str(active.get("build", ""))), "Invalid active identity")
        current_root = root / ("build/testflight-%s-%s" % (active["version"], active["build"]))
        current = read_json(current_root / "release-state.json")
        require(current.get("step") == "status-recorded" and current.get("appleStatus") == "internal-testing",
                "Current release is incomplete")
        require((current["version"],current["build"]) == (active["version"],active["build"]),
                "Active release identity mismatch")
        apple = confirm_apple(client, current)
        before = git_snapshot(root)
        candidates, kept = release_candidates(root, current)
        local, local_kept = local_candidates(root, current)
        candidates.extend(local)
        kept.extend(local_kept)
        local_outputs = [Path(c["outputRoot"]) for c in local]
        confirm_release_links(candidates)
        usage_before = build_area_usage(root, before, local_outputs)
        files = [f for c in candidates for f in c["files"]]
        targets = {f["path"] for f in files}
        for work in (Path(p) for p in before if p != "refs"):
            tracked = command(["git", "ls-files", "-z"], work).split("\0")
            require(not any(str((work / p).resolve()) in targets for p in tracked if p),
                    "Candidate includes a tracked file")
        require(len({f["path"] for f in files}) == len(files), "Overlapping cleanup targets")
        retained = preservation_inventory(root, targets, local_outputs)
        ensure_unopened([c["path"] for c in candidates if c["files"]])
        idle()
        require(git_snapshot(root) == before, "Git changed during planning")
        require(read_json(root / "build/release-automation/active.json") == active, "Active release changed")
        confirm_local_receipts(candidates)
        confirm_release_links(candidates)
        for f in files:
            require(fingerprint(Path(f["path"])) == f["fingerprint"], "Cache changed during planning")
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        report_dir = root / "build/release-automation/cleanup" / stamp
        report_dir.mkdir(parents=True, exist_ok=False)
        report = {"apply": apply, "currentBuildPreserved": current["build"], "apple": apple,
                  "gitBefore": before, "retainedBefore": retained, "candidates": candidates, "kept": kept,
                  "buildAreaBefore": usage_before,
                  "plannedAllocatedBytes": sum(f["allocatedBytes"] for f in files),
                  "deletedAllocatedBytes": 0, "deletedFiles": 0, "status": "planned"}
        report_path = report_dir / "report.json"
        report["reportPath"] = str(report_path)
        report_path.write_text(json.dumps(report, indent=2) + "\n")
        free_before = shutil.disk_usage(root).free
        try:
            if apply:
                # Full planning gates finish before first unlink. Recheck between roots and batches.
                confirm_release_links(candidates)
                with (report_dir / "deleted.jsonl").open("x") as journal:
                    for c in candidates:
                        if not c["files"]:
                            continue
                        idle()
                        ensure_unopened([c["path"]])
                        confirm_local_receipts([c])
                        confirm_release_links([c])
                        for i, f in enumerate(c["files"]):
                            if i % 1000 == 0:
                                idle()
                            confirm_release_links([c])
                            safe_unlink(f)
                            journal.write(json.dumps({"path": f["path"], "allocatedBytes": f["allocatedBytes"],
                                                      "reason": f.get("reason", "rebuildable compiler cache")}) + "\n")
                            report["deletedAllocatedBytes"] += f["allocatedBytes"]
                            report["deletedFiles"] += 1
                        journal.flush()
                        os.fsync(journal.fileno())
            confirm_local_receipts(candidates)
            report["retainedAfter"] = preservation_inventory(root, targets, local_outputs)
            require(report["retainedAfter"] == retained, "Retained release files changed; inspect report")
            report["gitAfter"] = git_snapshot(root)
            require(report["gitAfter"] == before, "Git changed during cleanup; inspect report")
            report["buildAreaAfter"] = build_area_usage(root, before, local_outputs)
            report["spaceLimitResult"] = ("within-limit" if not report["buildAreaAfter"]["overLimitBytes"]
                                          else "limit-unmet; only protected or unclassified data remain")
            report["status"] = "completed" if apply else "dry-run"
        except Exception as e:
            report["status"] = "stopped"
            report["error"] = str(e)
            raise
        finally:
            report["freeSpaceDeltaBytes"] = shutil.disk_usage(root).free - free_before
            report_path.write_text(json.dumps(report, indent=2) + "\n")
            print("Cleanup report:", report_path, flush=True)
        return report
