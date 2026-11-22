"""Verified iCloud offload of completed releases; never invoked by app builds.

The local catalog is authoritative for resumption. Originals are removed only
following an uploaded -> evicted -> downloaded -> SHA256 -> full restore check.
All removal uses the enumerated manifest, nofollow directory descriptors and a
write-ahead journal. Cloud metadata is never consulted by inspect_stub().
"""
import ctypes
import errno
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import time

from build_lock import build_lock, pass_fds
import release_cleanup as guard

DEFAULT_CLOUD_ROOT = Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/xDrip-arkiv"
NAME = re.compile(r"testflight-(\d+(?:\.\d+)+)-([1-9]\d*)\Z")
STUB = "archive-receipt.json"
SCHEMA = 1
EMBEDDED_MANIFEST = "__xdrip_archive_manifest__.json"


class ArchiveBlocked(RuntimeError):
    pass


def require(value, message):
    if not value:
        raise ArchiveBlocked(message)


def stamp():
    return datetime.now(timezone.utc).isoformat()


def digest(path):
    return guard.hash_file(Path(path))


def safe_path(path):
    path = Path(path)
    require(path.is_absolute() and str(path) == os.path.normpath(str(path)), "Noncanonical path")
    cursor = Path(path.anchor)
    for part in path.parts[1:]:
        cursor /= part
        require(not cursor.is_symlink(), "Symlinked path component: " + str(cursor))
    return path


def read_json(path):
    safe_path(path)
    require(path.is_file() and path.stat().st_nlink == 1, "Missing or linked catalog file: " + str(path))
    return json.loads(path.read_text())


def save_json(path, value):
    safe_path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp = path.with_name(path.name + ".tmp-" + str(time.time_ns()))
    require(not temp.is_symlink(), "Symlinked catalog temporary file")
    fd = os.open(str(temp), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
        directory = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except Exception:
        raise


def catalog_root(root):
    return Path(root) / "build/release-automation/archive"


def load_config(root):
    path = catalog_root(root) / "config.json"
    if not path.exists() and not path.is_symlink():
        return None
    value = read_json(path)
    require(value.get("enabled") in (True, False), "Archive enabled must be boolean")
    if value["enabled"] is False:
        return None
    cloud_root = Path(value.get("icloudRoot", ""))
    require(cloud_root == DEFAULT_CLOUD_ROOT, "Archive destination must be the configured private xDrip iCloud folder")
    safe_path(cloud_root)
    value["icloudRoot"] = str(cloud_root)
    value.setdefault("waitSeconds", 120)
    require(isinstance(value["waitSeconds"], (int, float)) and 0 < value["waitSeconds"] <= 7200,
            "Invalid cloud wait timeout")
    if "maxReleases" in value:
        require(type(value["maxReleases"]) is int and 1 <= value["maxReleases"] <= 1000, "Invalid archive batch limit")
    return value


class CloudBackend:
    """The only production backend is our source-hashed public Foundation helper."""
    def __init__(self, root):
        source = Path(root) / "scripts/icloud_archive.swift"
        safe_path(source)
        cache = catalog_root(root) / "helper" / digest(source)
        safe_path(cache)
        cache.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.binary = cache / "icloud-archive"
        if not self.binary.exists():
            result = subprocess.run(["xcrun", "swiftc", "-O", "-module-cache-path", str(cache / "modules"),
                                     str(source), "-o", str(self.binary)], capture_output=True)
            require(result.returncode == 0, "Cannot compile iCloud Foundation helper")
        safe_path(self.binary)
        require(self.binary.is_file() and self.binary.stat().st_uid == os.getuid(), "Unsafe iCloud helper")

    def _call(self, operation, path):
        safe_path(path)
        result = subprocess.run([str(self.binary), operation, str(path)], text=True, capture_output=True,
                                pass_fds=pass_fds())
        try:
            value = json.loads(result.stdout)
        except (ValueError, TypeError):
            raise ArchiveBlocked("Uncertain iCloud helper response")
        if operation != "status":
            require(result.returncode == 0 and not value.get("error"), "iCloud " + operation + " is not ready")
        return value

    def status(self, path):
        return self._call("status", path)

    def evict(self, path):
        return self._call("evict", path)

    def download(self, path):
        return self._call("download", path)


def wait_cloud(cloud, path, predicate, timeout):
    deadline = time.monotonic() + timeout
    while True:
        value = cloud.status(path)
        if value.get("isUbiquitous") is True and not value.get("hasConflicts") and not value.get("error") and predicate(value):
            return value
        if time.monotonic() >= deadline:
            raise ArchiveBlocked("iCloud transfer pending; originals retained, rerun archive --apply later")
        time.sleep(min(5, max(0, deadline - time.monotonic())))


# Python supplied with Xcode lacks os.listxattr on some Macs. Use the public
# libc interfaces directly; do not shell out once for each of thousands of files.
_LIB = ctypes.CDLL(None, use_errno=True)
if sys.platform == "darwin":
    _LIB.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    _LIB.listxattr.restype = ctypes.c_ssize_t
    _LIB.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    _LIB.getxattr.restype = ctypes.c_ssize_t
    _LIB.acl_get_link_np.argtypes = [ctypes.c_char_p, ctypes.c_int]
    _LIB.acl_get_link_np.restype = ctypes.c_void_p
    _LIB.acl_to_text.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ssize_t)]
    _LIB.acl_to_text.restype = ctypes.c_void_p
    _LIB.acl_free.argtypes = [ctypes.c_void_p]


def attributes(path, info):
    if sys.platform != "darwin":
        attrs = {name: hashlib.sha256(os.getxattr(path, name, follow_symlinks=False)).hexdigest()
                 for name in os.listxattr(path, follow_symlinks=False)}
        return {"xattrs": attrs, "acl": ""}
    raw = os.fsencode(path)
    count = _LIB.listxattr(raw, None, 0, 1)  # XATTR_NOFOLLOW
    require(count >= 0, "Cannot enumerate extended attributes: " + str(path))
    buffer = ctypes.create_string_buffer(count)
    require(_LIB.listxattr(raw, buffer, count, 1) == count, "Extended attributes changed")
    names = [name for name in buffer.raw.split(b"\0") if name]
    attrs = {}
    compressed = b"com.apple.decmpfs" in names and bool(getattr(info, "st_flags", 0) & 0x20)
    for name in sorted(names):
        # These encode physical compression, not an ordinary resource fork.
        if compressed and name in (b"com.apple.decmpfs", b"com.apple.ResourceFork"):
            continue
        size = _LIB.getxattr(raw, name, None, 0, 0, 1)
        require(size >= 0, "Cannot read extended attribute")
        value = ctypes.create_string_buffer(size)
        require(_LIB.getxattr(raw, name, value, size, 0, 1) == size, "Extended attribute changed")
        attrs[os.fsdecode(name)] = hashlib.sha256(value.raw).hexdigest()
    ctypes.set_errno(0)
    acl = _LIB.acl_get_link_np(raw, 0x100)  # ACL_TYPE_EXTENDED
    if not acl and ctypes.get_errno() == errno.ENOENT:
        return {"xattrs": attrs, "acl": ""}  # macOS uses ENOENT for no ACL.
    require(bool(acl), "Cannot read ACL: " + str(path))
    try:
        length = ctypes.c_ssize_t()
        pointer = _LIB.acl_to_text(acl, ctypes.byref(length))
        require(bool(pointer), "Cannot serialize ACL")
        try:
            acl_text = ctypes.string_at(pointer, length.value).decode("utf-8")
        finally:
            _LIB.acl_free(pointer)
    finally:
        _LIB.acl_free(acl)
    return {"xattrs": attrs, "acl": acl_text}


def record(path):
    info = path.lstat()
    item = {"path": str(path), "member": str(path).lstrip("/"),
            "mode": stat.S_IMODE(info.st_mode), "mtimeNs": info.st_mtime_ns,
            "identity": [info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns],
            "allocatedBytes": info.st_blocks * 512}
    if stat.S_ISREG(info.st_mode):
        require(info.st_nlink == 1, "Hardlinked original is not eligible: " + str(path))
        item.update(kind="file", size=info.st_size, sha256=digest(path))
    elif stat.S_ISDIR(info.st_mode):
        item.update(kind="directory")
    elif stat.S_ISLNK(info.st_mode):
        target = os.readlink(path)
        item.update(kind="symlink", target=target, sha256=hashlib.sha256(os.fsencode(target)).hexdigest())
    else:
        raise ArchiveBlocked("Special original is not eligible: " + str(path))
    item.update(attributes(path, info))
    return item


def walk_paths(roots):
    seen = set()
    for root in roots:
        root = safe_path(Path(root))
        require(root.is_dir(), "Original root is missing: " + str(root))
        pending = [root]
        while pending:
            path = pending.pop()
            require(str(path) not in seen, "Overlapping original roots")
            seen.add(str(path))
            require(path.name != ".git", "Git repository found in release artifacts")
            yield path
            if not path.is_symlink() and path.is_dir():
                pending.extend(sorted(path.iterdir(), reverse=True))


def make_manifest(roots, state):
    files = [record(path) for path in walk_paths(roots)]
    return {"schema": SCHEMA, "release": state["tag"], "version": state["version"], "build": state["build"],
            "tag": state["tag"], "sourceCommit": state["checkpoint"], "state": state,
            "roots": [{"original": str(p), "member": str(p).lstrip("/")} for p in roots],
            "files": files, "createdAt": stamp()}


def fidelity(item):
    return {k: item[k] for k in ("kind", "mode", "mtimeNs", "xattrs", "acl", "size", "sha256", "target") if k in item}


def validate_manifest(value):
    require(value.get("schema") == SCHEMA and NAME.fullmatch(value.get("release", "")), "Invalid archive manifest")
    roots = [str(safe_path(Path(r["original"]))) for r in value["roots"]]
    require(bool(roots) and len(roots) == len(set(roots)), "Invalid original root map")
    files = value["files"]
    paths = {f["path"] for f in files}
    require(len(paths) == len(files), "Duplicate manifest paths")
    for item in files:
        path = Path(item["path"])
        require(path.is_absolute() and ".." not in path.parts and item["member"] == str(path).lstrip("/"), "Unsafe manifest path")
        require(any(str(path) == r or Path(r) in path.parents for r in roots), "Manifest path outside roots")
        require(item["kind"] in {"file", "directory", "symlink"}, "Unsafe manifest file type")
    for root in roots:
        require(root in paths, "Missing root in manifest")
    return value


def check_originals(manifest, intents=()):
    expected = {f["path"]: f for f in manifest["files"]}
    actual_paths = set()
    for entry in manifest["roots"]:
        path = Path(entry["original"])
        if not path.exists():
            require(str(path) in intents, "Original root disappeared")
            continue
        for current in walk_paths([path]):
            actual_paths.add(str(current))
            require(str(current) in expected, "Unexpected file added to original: " + str(current))
            item, actual = expected[str(current)], record(current)
            require(fidelity(actual) == fidelity(item) or (item["kind"] == "directory" and intents
                    and {k: v for k, v in fidelity(actual).items() if k != "mtimeNs"}
                    == {k: v for k, v in fidelity(item).items() if k != "mtimeNs"}),
                    "Original content or metadata changed: " + str(current))
            # Directory sizes/mtime legitimately change during recorded removal.
            fields = 3 if item["kind"] == "directory" and intents else 5
            require(actual["identity"][:fields] == item["identity"][:fields], "Original identity changed")
    require(set(expected) - actual_paths <= set(intents), "Unjournaled original disappearance")


def inspect_stub(folder):
    """Inspect only private local files; never stat/read/hydrate archivePath."""
    folder = Path(folder)
    require(not folder.is_symlink(), "Symlinked release directory")
    marker = folder / STUB
    if not marker.exists() and not marker.is_symlink():
        return None
    safe_path(folder)
    require(NAME.fullmatch(folder.name), "Archive receipt outside release directory")
    require({p.name for p in folder.iterdir()} == {STUB}, "Archive stub contains unexpected files")
    receipt = read_json(marker)
    cat = folder.parent / "release-automation/archive" / folder.name
    transaction = read_json(cat / "transaction.json")
    manifest_path = cat / "manifest.json"
    require(receipt.get("schema") == SCHEMA and receipt.get("stage") == "offloaded"
            and receipt.get("release") == folder.name, "Invalid local archive receipt")
    require(transaction.get("stage") == "offloaded" and transaction.get("receipt") == receipt,
            "Local archive receipt does not match catalog")
    require(digest(manifest_path) == receipt.get("manifestSHA256"), "Local archive manifest changed")
    manifest = validate_manifest(read_json(manifest_path))
    require((manifest["release"], manifest["tag"], manifest["sourceCommit"], manifest["version"], manifest["build"])
            == tuple(receipt.get(k) for k in ("release", "tag", "sourceCommit", "version", "build")),
            "Local archive identity differs")
    require(manifest["roots"][0]["original"] == str(folder), "Original release path differs")
    return receipt


def current_release(root):
    active = read_json(root / "build/release-automation/active.json")
    name = "testflight-%s-%s" % (active["version"], active["build"])
    require(NAME.fullmatch(name), "Invalid active release")
    folder = root / "build" / name
    require(inspect_stub(folder) is None, "Current release must be local")
    state = read_json(folder / "release-state.json")
    require((state.get("version"), state.get("build")) == (active["version"], active["build"])
            and state.get("step") == "status-recorded" and state.get("appleStatus") == "internal-testing",
            "Current release incomplete")
    return active, state


def candidates(root, current):
    known, kept = [], []
    folders = sorted((root / "build").glob("testflight-*"))
    catalog = catalog_root(root)
    # A partially removed release may have no release-state.json anymore.
    for cat in catalog.glob("testflight-*"):
        if (cat / "transaction.json").exists():
            folder = root / "build" / cat.name
            if folder not in folders:
                folders.append(folder)
    for folder in folders:
        match = NAME.fullmatch(folder.name)
        if not match:
            kept.append({"release": folder.name, "reason": "unknown name"})
            continue
        stub = inspect_stub(folder)
        if stub is not None:
            known.append((folder, read_json(catalog / folder.name / "manifest.json")["state"], True))
            continue
        txpath = catalog / folder.name / "transaction.json"
        if txpath.exists():
            tx = read_json(txpath)
            state = read_json(catalog / folder.name / "manifest.json")["state"]
        else:
            tx = None
            try:
                state = read_json(folder / "release-state.json")
            except (OSError, ValueError, ArchiveBlocked):
                kept.append({"release": folder.name, "reason": "unknown release state"})
                continue
        if (state.get("version"), state.get("build")) != (match[1], match[2]) or state.get("step") != "status-recorded" or state.get("appleStatus") != "internal-testing" or state.get("tests", {}).get("verificationPassed") is not True:
            kept.append({"release": folder.name, "reason": "incomplete release"})
            continue
        known.append((folder, state, bool(tx and tx.get("stage") == "offloaded")))
    prior = max((int(s["build"]) for _, s, _ in known if int(s["build"]) < int(current["build"])), default=None)
    result = []
    all_roots = []
    for folder in folders:
        all_roots.append((folder, folder))
        for name in ("build", "verify", "test"):
            child = folder / name
            if child.is_symlink():
                all_roots.append((folder, child.resolve()))
    for folder, state, offloaded in known:
        all_roots.append((folder, folder))
        if state.get("signingOutputRoot"):
            all_roots.append((folder, Path(state["signingOutputRoot"])))
    for folder, state, offloaded in sorted(known, key=lambda row: int(row[1]["build"])):
        if int(state["build"]) >= int(current["build"]) or int(state["build"]) == prior:
            require(not offloaded, "Current/latest previous release must remain local")
            kept.append({"release": folder.name, "reason": "current/newer/latest previous"})
            continue
        if offloaded and inspect_stub(folder) is not None:
            kept.append({"release": folder.name, "reason": "verified offloaded archive"})
            # A fully offloaded archive with unfinished cache eviction is resumed.
            existing_tx = read_json(catalog / folder.name / "transaction.json")
            if existing_tx.get("cloudEvictedAt") and not (catalog / folder.name / "package.tar.gz").exists():
                continue
        if offloaded:
            # Complete a crash between committing offloaded and installing stub.
            result.append({"folder": folder, "state": state, "roots": [folder], "offloaded": True})
            continue
        require(guard.command(["git", "rev-parse", "refs/tags/" + state["tag"] + "^{}"], root).strip() == state["checkpoint"], "Release source tag changed")
        require(state["tag"] == folder.name, "Release tag/name mismatch")
        txpath = catalog / folder.name / "transaction.json"
        if txpath.exists():
            manifest = validate_manifest(read_json(catalog / folder.name / "manifest.json"))
            roots = [Path(r["original"]) for r in manifest["roots"]]
            expected_roots = [folder] + ([Path(state["signingOutputRoot"])] if state.get("signingOutputRoot") else [])
            require(roots == expected_roots, "Catalog source root changed")
        else:
            roots = [safe_path(folder)]
            out = folder / "build"
            external = state.get("signingOutputRoot")
            if external:
                external = safe_path(Path(external))
                require(out.is_symlink() and os.readlink(out) == str(external) and external.is_dir(), "Unrecognized signing output link")
                require(external != root and root not in external.parents and external not in root.parents, "Signing output overlaps source")
                roots.append(external)
                verify = folder / "verify"
                if verify.is_symlink():
                    require(os.readlink(verify) == str(external / "verification") and (external / "verification").is_dir()
                            and not (external / "verification").is_symlink(), "Unknown external verification link")
            else:
                require(not out.is_symlink() and out.is_dir(), "Missing or unknown build output")
                require(not (folder / "verify").is_symlink(), "Unknown verification link")
            ipa = out / "export/xdrip.ipa"
            require(ipa.is_file() and not ipa.is_symlink() and digest(ipa) == state["ipaSha256"], "IPA missing or changed")
            require((out / "archive/xdrip.xcarchive/dSYMs").is_dir()
                    and (folder / "test/results/AllTests.xcresult").is_dir()
                    and (folder / "apple-status.json").is_file(), "Release evidence missing")
        for original in roots:
            for owner, other in all_roots:
                if owner != folder:
                    require(original != other and original not in other.parents and other not in original.parents,
                            "Original overlaps another release")
        result.append({"folder": folder, "state": state, "roots": roots, "offloaded": False})
    return result, kept, prior


def tar_check(package, manifest):
    expected = {f["member"]: f for f in manifest["files"]}
    links = {n for n, f in expected.items() if f["kind"] == "symlink"}
    found = set()
    embedded_seen = False
    with tarfile.open(package, "r:*") as source:
        for entry in source:
            name = entry.name.rstrip("/")
            require(not name.startswith("/") and ".." not in Path(name).parts, "Unsafe archive member")
            if name == EMBEDDED_MANIFEST:
                require(entry.isfile() and not embedded_seen, "Invalid embedded manifest")
                require(json.load(source.extractfile(entry)) == manifest, "Embedded manifest differs")
                embedded_seen = True
                continue
            # bsdtar's AppleDouble carries native xattrs/ACLs, consumed on extraction.
            logical = str(Path(name).with_name(Path(name).name[2:])) if Path(name).name.startswith("._") else name
            if name not in expected and (logical in expected or logical == EMBEDDED_MANIFEST) and entry.isfile():
                continue
            require(name in expected and name not in found, "Unexpected or duplicate archive member: " + name)
            require(not any(str(p) in links for p in Path(name).parents), "Archive member traverses symlink")
            item = expected[name]
            require((entry.isfile() and item["kind"] == "file") or (entry.isdir() and item["kind"] == "directory")
                    or (entry.issym() and item["kind"] == "symlink" and entry.linkname == item["target"]), "Archive file type differs")
            found.add(name)
    require(found == set(expected) and embedded_seen, "Archive members or embedded manifest incomplete")


def run_tar(args):
    result = subprocess.run(["/usr/bin/tar"] + args, capture_output=True, pass_fds=pass_fds(),
                            env={k: v for k, v in os.environ.items() if k not in {"COPYFILE_DISABLE", "COPY_EXTENDED_ATTRIBUTES_DISABLE"}})
    require(result.returncode == 0, "Native tar failed; original artifacts retained")


def create_package(cat, manifest):
    package = cat / "package.tar.gz"
    temporary = cat / "package.partial"
    safe_path(temporary)
    if temporary.exists():
        require(temporary.is_file() and temporary.stat().st_nlink == 1, "Unrecognized partial package")
        temporary.unlink()
    if package.exists():
        require(not package.is_symlink() and package.stat().st_nlink == 1, "Unsafe local package")
        tar_check(package, manifest)
        return package  # Restart after rename but before durable packaged stage.
    embedded = cat / EMBEDDED_MANIFEST
    save_json(embedded, manifest)
    listing = cat / ("members-%d.nul" % time.time_ns())
    with listing.open("xb") as stream:
        for item in manifest["files"]:
            stream.write(os.fsencode(item["member"]) + b"\0")
        stream.write(os.fsencode(str(embedded).lstrip("/")) + b"\0")
    os.chmod(listing, 0o600)
    substitution = "|^" + re.escape(str(embedded).lstrip("/")) + "$|" + EMBEDDED_MANIFEST + "|"
    run_tar(["--format", "pax", "--acls", "--xattrs", "--options", "gzip:compression-level=1",
             "-czf", str(temporary), "--no-recursion", "-s", substitution, "-C", "/", "--null", "-T", str(listing)])
    os.chmod(temporary, 0o600)
    tar_check(temporary, manifest)
    os.replace(temporary, package)
    listing.unlink()
    return package


def extraction_check(package, manifest, destination, resume=False):
    require(not destination.is_symlink(), "Symlinked restore destination")
    require(resume or not destination.exists(), "Restore destination already exists")
    safe_path(destination)
    tar_check(package, manifest)
    if not destination.exists():
        destination.mkdir(parents=True, mode=0o700)
        run_tar(["--acls", "--xattrs", "-xpf", str(package), "-C", str(destination)])
    # A complete interrupted verification can resume; an incomplete/changed tree
    # fails closed at this same path instead of accumulating additional copies.
    expected = {f["member"]: f for f in manifest["files"]}
    for name, item in expected.items():
        restored = destination / name
        require(restored.exists() or restored.is_symlink(), "Restored member missing")
        actual = record(restored)
        require(fidelity(actual) == fidelity(item), "Restored content/metadata mismatch: " + name)
    # Parent containers above manifest roots are generated by tar, not originals.
    require(read_json(destination / EMBEDDED_MANIFEST) == manifest, "Restored embedded manifest differs")
    allowed = set(expected) | {EMBEDDED_MANIFEST}
    for name in list(allowed):
        allowed.update(str(p) for p in Path(name).parents if str(p) != ".")
    for base, dirs, names in os.walk(destination, followlinks=False):
        for name in dirs + names:
            require((Path(base) / name).relative_to(destination).as_posix() in allowed, "Unexpected restored file")
    return {r["original"]: str(destination / r["member"]) for r in manifest["roots"]}


def remove_verification(destination, manifest):
    """Remove only verified archive members and their now-empty containers."""
    if not destination.exists():
        return
    (destination / EMBEDDED_MANIFEST).unlink()
    for item in reversed(manifest["files"]):
        path = destination / item["member"]
        if item["kind"] == "directory":
            path.rmdir()
        else:
            path.unlink()
    for base, dirs, names in os.walk(destination, topdown=False, followlinks=False):
        require(not names, "Unexpected verification artifact")
        for name in dirs:
            (Path(base) / name).rmdir()
    destination.rmdir()


def journal_intents(path):
    if not path.exists():
        return set()
    require(not path.is_symlink(), "Symlinked removal journal")
    return {json.loads(line)["path"] for line in path.read_text().splitlines()}


def unlink_manifest_item(item, directories):
    """No symlink component is followed, including if a parent was replaced."""
    path = Path(item["path"])
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        cursor = Path("/")
        for part in path.parts[1:-1]:
            cursor /= part
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
            if str(cursor) in directories:
                info = os.fstat(fd)
                require([info.st_dev, info.st_ino, info.st_mode] == directories[str(cursor)]["identity"][:3], "Original parent replaced")
        try:
            info = os.stat(path.name, dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            return False
        fields = [info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns]
        count = 3 if item["kind"] == "directory" else 5
        require(fields[:count] == item["identity"][:count], "Original replaced before removal")
        if item["kind"] == "directory":
            os.rmdir(path.name, dir_fd=fd)
        else:
            require(item["kind"] == "symlink" or info.st_nlink == 1, "Original hardlink appeared")
            os.unlink(path.name, dir_fd=fd)
        return True
    finally:
        os.close(fd)


def install_stub(folder, cat, tx):
    receipt = {"schema": SCHEMA, "stage": "offloaded", "release": tx["release"],
               "version": tx["version"], "build": tx["build"], "tag": tx["tag"],
               "sourceCommit": tx["sourceCommit"], "manifestSHA256": tx["manifestSHA256"],
               "archiveSHA256": tx["archiveSHA256"], "archivePath": tx["archivePath"],
               "catalogPath": str(cat), "offloadedAt": tx.get("offloadedAt", stamp())}
    require(not folder.is_symlink(), "Original release root replaced")
    if folder.exists():
        require(not list(folder.iterdir()) or inspect_stub(folder) is not None, "Cannot install stub over original files")
    tx.update(stage="offloaded", receipt=receipt, offloadedAt=receipt["offloadedAt"])
    save_json(cat / "transaction.json", tx)
    folder.mkdir(mode=0o700, exist_ok=True)
    save_json(folder / STUB, receipt)
    inspect_stub(folder)


def archive_one(root, candidate, config, cloud, recheck, before_removal=None):
    folder, state = candidate["folder"], candidate["state"]
    def progress(message):
        if config.get("progress", True):
            print("Archive %s: %s" % (folder.name, message), flush=True)
    progress("checking catalog and source roots")
    cat = catalog_root(root) / folder.name
    safe_path(cat)
    cat.mkdir(parents=True, exist_ok=True, mode=0o700)
    manifest_path, txpath = cat / "manifest.json", cat / "transaction.json"
    if txpath.exists():
        tx = read_json(txpath)
        require(digest(manifest_path) == tx["manifestSHA256"], "Archive catalog manifest changed")
        manifest = validate_manifest(read_json(manifest_path))
    else:
        guard.ensure_unopened([str(p) for p in candidate["roots"]])
        progress("hashing originals and recording native metadata")
        manifest = make_manifest(candidate["roots"], state)
        save_json(manifest_path, manifest)
        tx = {"schema": SCHEMA, "release": folder.name, "version": state["version"], "build": state["build"],
              "tag": state["tag"], "sourceCommit": state["checkpoint"], "stage": "packaging",
              "manifestSHA256": digest(manifest_path), "createdAt": stamp()}
        save_json(txpath, tx)
    if tx["stage"] == "offloaded":
        if inspect_stub(folder) is None:
            install_stub(folder, cat, tx)
        finish_eviction(cat, tx, cloud, config)
        return tx
    roots = [r["original"] for r in manifest["roots"]]
    recheck()
    if tx["stage"] == "packaging":
        check_originals(manifest)
        progress("packaging %d manifest entries" % len(manifest["files"]))
        package = create_package(cat, manifest)
        check_originals(manifest)
        tx.update(stage="packaged", archiveSHA256=digest(package), archiveBytes=package.stat().st_size)
        archive_name = "%s-%s-%s.tar.gz" % (folder.name, state["checkpoint"][:12], tx["manifestSHA256"][:12])
        tx["archivePath"] = str(Path(config["icloudRoot"]) / archive_name)
        save_json(txpath, tx)
    package = Path(tx["archivePath"])
    safe_path(package)
    require(package.parent == Path(config["icloudRoot"]), "Archive path outside configured iCloud root")
    if tx["stage"] == "packaged":
        local = cat / "package.tar.gz"
        require(digest(local) == tx["archiveSHA256"], "Local archive changed")
        package.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        partial = package.with_suffix(package.suffix + ".partial")
        safe_path(partial)
        if package.exists():
            require(digest(package) == tx["archiveSHA256"], "Cloud archive filename collision")
        else:
            if partial.exists():
                require(partial.is_file() and partial.stat().st_nlink == 1, "Unexpected cloud partial file")
                partial.unlink()
            with local.open("rb") as source, partial.open("xb") as output:
                shutil.copyfileobj(source, output, 1024 * 1024)
                output.flush()
                os.fsync(output.fileno())
            os.chmod(partial, 0o600)
            require(digest(partial) == tx["archiveSHA256"], "Cloud staging copy differs")
            os.rename(partial, package)
        tx.update(stage="upload-pending")
        save_json(txpath, tx)
    if tx["stage"] == "upload-pending":
        progress("waiting for iCloud upload, eviction and fresh download")
        timeout = config["waitSeconds"]
        wait_cloud(cloud, package, lambda s: s.get("isUploaded") is True and s.get("isUploading") is False, timeout)
        cloud.evict(package)
        wait_cloud(cloud, package, lambda s: s.get("dataless") is True, timeout)
        tx["evictedAt"] = stamp()
        save_json(txpath, tx)
        cloud.download(package)
        wait_cloud(cloud, package, lambda s: s.get("downloaded") is True and s.get("dataless") is False, timeout)
        require(digest(package) == tx["archiveSHA256"], "Cloud roundtrip archive checksum differs")
        verified = cat / "restore-check"
        require(not list(cat.glob("restore-check-*")), "Older incomplete verification trees need inspection: " + str(cat))
        progress("verifying full restored content and metadata")
        extraction_check(package, manifest, verified, resume=True)
        remove_verification(verified, manifest)
        tx.update(stage="cloud-roundtrip-verified", verifiedAt=stamp())
        save_json(txpath, tx)
    require(tx["stage"] in {"cloud-roundtrip-verified", "removing"}, "Unknown archive stage")
    # A resumed removal still needs the exact remote-backed package to be usable.
    cloud.download(package)
    wait_cloud(cloud, package, lambda s: s.get("downloaded") is True and s.get("isUploaded") is True
               and s.get("dataless") is False, config["waitSeconds"])
    require(digest(package) == tx["archiveSHA256"], "Verified cloud package changed")
    recheck()
    guard.ensure_unopened([p for p in roots if Path(p).exists()])
    intents = journal_intents(cat / "removal.jsonl")
    progress("checking unchanged originals before bounded removal")
    check_originals(manifest, intents)
    if before_removal is not None:
        before_removal()
    recheck(full=True)
    guard.ensure_unopened([p for p in roots if Path(p).exists()])
    tx["stage"] = "removing"
    save_json(txpath, tx)
    directories = {f["path"]: f for f in manifest["files"] if f["kind"] == "directory"}
    # Children precede their parent; authorized journal intents are durable first.
    ordered = sorted(manifest["files"], key=lambda f: len(Path(f["path"]).parts), reverse=True)
    with (cat / "removal.jsonl").open("a") as journal:
        os.chmod(cat / "removal.jsonl", 0o600)
        for offset in range(0, len(ordered), 1024):
            recheck()
            batch = ordered[offset:offset + 1024]
            for item in batch:
                if item["path"] not in intents:
                    journal.write(json.dumps({"path": item["path"], "identity": item["identity"]}) + "\n")
            journal.flush()
            os.fsync(journal.fileno())
            for item in batch:
                try:
                    unlink_manifest_item(item, directories)
                except FileNotFoundError:
                    require(item["path"] in intents, "Original parent disappeared without removal intent")
            intents.update(item["path"] for item in batch)
    install_stub(folder, cat, tx)
    finish_eviction(cat, tx, cloud, config)
    progress("offloaded; local archive download evicted")
    return tx


def finish_eviction(cat, tx, cloud, config):
    # On crash-resume the local package may be the only surviving copy. Prove
    # the remote package again before releasing either local download.
    package = safe_path(Path(tx["archivePath"]))
    require(package.parent == Path(config["icloudRoot"]), "Archive path outside configured iCloud root")
    cloud.download(package)
    wait_cloud(cloud, package, lambda s: s.get("isUploaded") is True and s.get("isUploading") is False
               and s.get("downloaded") is True and s.get("dataless") is False, config["waitSeconds"])
    require(digest(package) == tx["archiveSHA256"], "Cloud package changed; local archive retained")
    cloud.evict(package)
    wait_cloud(cloud, package, lambda s: s.get("dataless") is True, config["waitSeconds"])
    local = cat / "package.tar.gz"
    if local.exists():
        require(not local.is_symlink() and digest(local) == tx["archiveSHA256"], "Local package changed")
        local.unlink()
    tx["cloudEvictedAt"] = stamp()
    save_json(cat / "transaction.json", tx)


def protected_git_roots(root, snapshot):
    protected = {Path(p) for p in snapshot if p != "refs"}
    common = (root / guard.command(["git", "rev-parse", "--git-common-dir"], root).strip()).resolve()
    protected.add(common)
    pending, seen = [common / "objects"], set()
    while pending:
        objects = pending.pop().resolve()
        if objects in seen:
            continue
        seen.add(objects)
        require(len(seen) <= 64, "Uncertain Git alternate inventory")
        # Protect the whole object-recovery repository, not merely its objects.
        protected.add(objects.parent if objects.name == "objects" else objects)
        alternates = objects / "info/alternates"
        if alternates.exists():
            require(not alternates.is_symlink(), "Symlinked Git alternate inventory")
            for line in alternates.read_text().splitlines():
                if line:
                    alternate = Path(line)
                    pending.append(alternate if alternate.is_absolute() else objects / alternate)
    return protected


def archive(root, client, apply=False, cloud=None):
    root = Path(root).resolve()
    config = load_config(root)
    if config is None:
        return {"status": "disabled", "apply": apply, "releases": []}
    # Swift compiler must finish before entering the shared build lock/idle gate.
    if apply and cloud is None:
        cloud = CloudBackend(root)
    with build_lock():
        guard.idle()
        safe_path(root / "build")
        active, current = current_release(root)
        before = guard.git_snapshot(root)
        apple = guard.confirm_apple(client, current)
        selected, kept, previous = candidates(root, current)
        if config.get("maxReleases"):
            selected = selected[:config["maxReleases"]]
        git_roots = protected_git_roots(root, before)
        protected = []
        for work in (Path(p) for p in before if p != "refs"):
            protected.extend(str(work / path) for path in guard.command(["git", "ls-files", "-z"], work).split("\0") if path)
        for c in selected:
            for original in c["roots"][1:]:
                for work in git_roots:
                    require(original != work and original not in work.parents and work not in original.parents,
                            "External archive root overlaps a Git worktree")
            for original in c["roots"]:
                require(not any(original == p or original in p.parents for p in git_roots),
                        "Archive root contains Git source or object storage")
                require(not any(Path(p) == original or original in Path(p).parents for p in protected), "Archive includes tracked source")
        report = {"apply": apply, "status": "planned", "currentBuildPreserved": current["build"],
                  "previousBuildPreserved": str(previous) if previous else None, "apple": apple,
                  "releases": [], "kept": kept, "startedAt": stamp()}
        def recheck(full=False):
            guard.idle()
            require(read_json(root / "build/release-automation/active.json") == active, "Current release changed")
            if full:
                require(guard.git_snapshot(root) == before, "Git changed during archive")
        apple_before_removal = False
        def before_removal():
            nonlocal apple_before_removal
            if not apple_before_removal:
                guard.confirm_apple(client, current)
                apple_before_removal = True
        free_before = shutil.disk_usage(root).free
        for c in selected:
            if not apply:
                if c["offloaded"]:
                    continue
                report["releases"].append({"release": c["folder"].name, "roots": [str(p) for p in c["roots"]]})
            else:
                recheck(full=True)
                result = archive_one(root, c, config, cloud, recheck, before_removal)
                report["releases"].append({k: result[k] for k in ("release", "stage", "archivePath", "archiveSHA256")})
        recheck(full=True)
        report.update(status="completed" if apply else "dry-run", freeSpaceDeltaBytes=shutil.disk_usage(root).free - free_before,
                      finishedAt=stamp())
        report_path = catalog_root(root) / ("report-%d.json" % time.time_ns())
        save_json(report_path, report)
        report["reportPath"] = str(report_path)
        return report


def restore_archive(root, target, destination=None, apply=False, cloud=None):
    root = Path(root).resolve()
    require(NAME.fullmatch(str(target)), "Choose a cataloged testflight-version-build")
    require(destination is not None, "Restore requires a new local destination")
    destination = Path(destination)
    safe_path(destination)
    require(not destination.exists(), "Restore destination must not exist")
    require("Mobile Documents" not in destination.parts and "CloudStorage" not in destination.parts,
            "Restore destination must be local")
    cat = catalog_root(root) / str(target)
    tx = read_json(cat / "transaction.json")
    manifest_path = cat / "manifest.json"
    require(tx["stage"] in {"cloud-roundtrip-verified", "removing", "offloaded"}, "Archive not verified")
    require(digest(manifest_path) == tx["manifestSHA256"], "Catalog manifest changed")
    manifest = validate_manifest(read_json(manifest_path))
    report = {"release": str(target), "apply": apply, "archivePath": tx["archivePath"],
              "destination": str(destination), "rootMap": {r["original"]: str(destination / r["member"]) for r in manifest["roots"]},
              "status": "dry-run"}
    if not apply:
        return report
    config = load_config(root)
    require(config is not None, "Archive configuration disabled")
    cloud = cloud or CloudBackend(root)
    package = Path(tx["archivePath"])
    require(package.parent == Path(config["icloudRoot"]), "Archive outside configured iCloud root")
    with build_lock():
        guard.idle()
        before = guard.git_snapshot(root)
        cloud.download(package)
        wait_cloud(cloud, package, lambda s: s.get("downloaded") is True and s.get("dataless") is False, config["waitSeconds"])
        require(digest(package) == tx["archiveSHA256"], "Downloaded archive checksum differs")
        extraction_check(package, manifest, destination)
        # Preserve original symbolic links exactly. The returned absolute map lets
        # callers locate both release and external signing roots without overwrite.
        save_json(destination / "RESTORE-MAP.json", {"release": target, "roots": report["rootMap"],
                                                     "archiveSHA256": tx["archiveSHA256"], "verifiedAt": stamp()})
        require(guard.git_snapshot(root) == before, "Git changed during restore")
        report["status"] = "restored-and-verified"
    return report
