#!/usr/bin/env python3
"""Small, fail-closed App Store Connect client for this app's local releases.

Uses Apple's public REST API and an external ES256 API key. It never reads
browser cookies, Xcode credentials, or private Apple APIs. No dependencies
beyond Python 3.9+ and the system openssl executable are required.
"""
import base64
import datetime
import email.utils
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

APP_ID = "6795645396"
BUNDLE_ID = "com.GFZ896KN66.xdripswift"
API_ORIGIN = "https://api.appstoreconnect.apple.com"
CONFIG_PATH = Path.home() / ".config/xdrip-release/app-store-connect.json"


class AppleError(RuntimeError):
    """A sanitized error safe to include in a local release log."""


def _fail(message):
    raise AppleError(message) from None


def _utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def _b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _der_signature(der):
    """Convert OpenSSL's DER ECDSA signature to JWT's fixed-width R || S."""
    def element(offset, expected):
        if offset + 2 > len(der) or der[offset] != expected:
            _fail("Apple API signing returned an invalid signature")
        length = der[offset + 1]
        start = offset + 2
        if length & 0x80:
            count = length & 0x7f
            if not count or count > 2 or start + count > len(der):
                _fail("Apple API signing returned an invalid signature")
            length = int.from_bytes(der[start:start + count], "big")
            start += count
        end = start + length
        if end > len(der):
            _fail("Apple API signing returned an invalid signature")
        return start, end
    begin, end = element(0, 0x30)
    if end != len(der):
        _fail("Apple API signing returned an invalid signature")
    rb, re_ = element(begin, 0x02)
    sb, se = element(re_, 0x02)
    if se != end:
        _fail("Apple API signing returned an invalid signature")
    values = []
    for value in (der[rb:re_], der[sb:se]):
        if not value or value[0] & 0x80:
            _fail("Apple API signing returned an invalid signature")
        value = value.lstrip(b"\x00")
        if not value or len(value) > 32:
            _fail("Apple API signing returned an invalid signature")
        values.append(value.rjust(32, b"\x00"))
    return b"".join(values)


def _private_file(path, label):
    try:
        resolved = path.expanduser().resolve(strict=True)
        metadata = resolved.stat()
    except (OSError, RuntimeError):
        _fail("{} is unavailable; configure the external App Store Connect API key".format(label))
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o077:
        _fail("{} must be a regular file readable only by its owner (chmod 600)".format(label))
    if metadata.st_uid != os.getuid():
        _fail("{} must belong to the current macOS user".format(label))
    if any((parent / ".git").exists() for parent in resolved.parents):
        _fail("{} must be stored outside all Git working trees".format(label))
    return resolved


def next_build_number(numbers):
    """Return an integer greater than every known numeric Apple build tuple.

    Both 4263 and 4263.2.1 reserve the next integer 4264. Unknown/development
    suffixes fail closed instead of silently ignoring an occupied build.
    """
    parsed = []
    for number in numbers:
        if not isinstance(number, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", number):
            _fail("Apple returned a build number with an unsupported format; allocation stopped")
        if any(len(part) > 18 for part in number.split(".")):
            _fail("Apple returned an oversized build number; allocation stopped")
        parts = tuple(int(part) for part in number.split("."))
        parsed.append((parts + (0,) * (3 - len(parts)), number))
    if not parsed:
        return None, "1"
    highest = max(parsed, key=lambda item: item[0])
    return highest[1], str(highest[0][0] + 1)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class AppleClient:
    def __init__(self, key_id, issuer_id, private_key_path):
        self.key_id = key_id
        self.issuer_id = issuer_id
        self.private_key_path = Path(private_key_path)
        self._token = None
        self._token_expires = 0
        self._opener = urllib.request.build_opener(_NoRedirect())

    @classmethod
    def from_environment(cls):
        config = _private_file(Path(os.environ.get("XDRIP_ASC_CONFIG", CONFIG_PATH)),
                               "App Store Connect API configuration")
        try:
            data = json.loads(config.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            _fail("App Store Connect API configuration is not valid JSON")
        if not isinstance(data, dict) or set(data) - {"keyID", "issuerID", "privateKeyPath"}:
            _fail("Apple API configuration accepts only keyID, issuerID, and privateKeyPath")
        key_id = data.get("keyID")
        issuer_id = data.get("issuerID")
        private_path = data.get("privateKeyPath")
        if not isinstance(key_id, str) or not re.fullmatch(r"[A-Za-z0-9]{10}", key_id):
            _fail("Apple API configuration needs a valid keyID")
        if issuer_id is not None and (not isinstance(issuer_id, str) or not re.fullmatch(
                r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", issuer_id)):
            _fail("Apple API configuration has an invalid issuerID")
        if not isinstance(private_path, str) or not Path(private_path).expanduser().is_absolute():
            _fail("Apple API configuration needs an absolute external privateKeyPath")
        key_path = _private_file(Path(private_path), "App Store Connect private key")
        return cls(key_id, issuer_id, key_path)

    def upload_auth_args(self):
        """Only public key identifiers and a path; never private key contents/JWT."""
        _private_file(self.private_key_path, "App Store Connect private key")
        args = ["--api-key", self.key_id, "--p8-file-path", str(self.private_key_path)]
        if self.issuer_id:
            args += ["--api-issuer", self.issuer_id]
        else:
            args += ["--api-key-subject", "user"]
        return args

    def _jwt(self):
        now = int(time.time())
        if self._token and self._token_expires > now + 60:
            return self._token
        _private_file(self.private_key_path, "App Store Connect private key")
        header = {"alg": "ES256", "kid": self.key_id, "typ": "JWT"}
        payload = {"iat": now - 5, "exp": now + 600, "aud": "appstoreconnect-v1"}
        if self.issuer_id:
            payload["iss"] = self.issuer_id
        else:
            payload["sub"] = "user"
        signed = (_b64(json.dumps(header, separators=(",", ":")).encode()) + "." +
                  _b64(json.dumps(payload, separators=(",", ":")).encode())).encode("ascii")
        try:
            result = subprocess.run(["/usr/bin/openssl", "dgst", "-sha256", "-sign",
                                     str(self.private_key_path)], input=signed,
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                    check=False, timeout=15)
        except (OSError, subprocess.TimeoutExpired):
            _fail("Apple API JWT signing failed; check the external ES256 private key")
        if result.returncode:
            _fail("Apple API JWT signing failed; check the external ES256 private key")
        self._token = signed.decode("ascii") + "." + _b64(_der_signature(result.stdout))
        self._token_expires = payload["exp"]
        return self._token

    @staticmethod
    def _safe_url(path):
        url = path if path.startswith("https://") else API_ORIGIN + path
        try:
            parsed = urllib.parse.urlsplit(url)
            unsafe = (parsed.scheme != "https" or parsed.hostname != "api.appstoreconnect.apple.com"
                      or parsed.port not in (None, 443) or parsed.username or parsed.password
                      or parsed.fragment or not parsed.path.startswith("/v1/"))
        except ValueError:
            unsafe = True
        if unsafe:
            _fail("Apple API returned an unsafe URL; request refused")
        return url

    def _request(self, path, method="GET", body=None):
        url = self._safe_url(path)
        if method not in ("GET", "POST"):
            _fail("Unsupported Apple API mutation refused")
        headers = {"Authorization": "Bearer " + self._jwt(), "Accept": "application/json"}
        data = None
        if body is not None:
            data = json.dumps(body, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        attempts = 3 if method == "GET" else 1
        for attempt in range(attempts):
            try:
                with self._opener.open(request, timeout=45) as response:
                    raw = response.read(16 * 1024 * 1024 + 1)
                    if len(raw) > 16 * 1024 * 1024:
                        _fail("Apple API response exceeded the safety limit")
                    if response.status == 204:
                        return {}
                break
            except urllib.error.HTTPError as error:
                if error.code in (429, 502, 503, 504) and attempt + 1 < attempts:
                    delay = self._retry_delay(error.headers, attempt)
                    if error.fp is not None:
                        error.close()
                    time.sleep(delay)
                    continue
                if error.code == 401:
                    _fail("Apple API authentication failed (401); verify the API key's access")
                if error.code == 403:
                    _fail("Apple API access denied (403); required account permissions or an Apple agreement may be missing")
                if 300 <= error.code < 400:
                    _fail("Apple API redirect refused; authentication was not forwarded")
                _fail("Apple API request failed (HTTP {}); no build number was guessed".format(error.code))
            except (urllib.error.URLError, TimeoutError, OSError):
                if attempt + 1 < attempts:
                    time.sleep(self._retry_delay(None, attempt))
                    continue
                _fail("Apple API connection failed; the request outcome must be checked before retrying a mutation")
        try:
            document = json.loads(raw)
        except (ValueError, UnicodeError):
            _fail("Apple API returned invalid JSON")
        if not isinstance(document, dict):
            _fail("Apple API returned an unexpected response")
        return document

    @staticmethod
    def _retry_delay(headers, attempt):
        retry_after = headers.get("Retry-After") if headers else None
        delay = min(30, 2 ** attempt)
        if retry_after:
            try:
                delay = float(retry_after)
            except (TypeError, ValueError):
                try:
                    retry_at = email.utils.parsedate_to_datetime(retry_after)
                    delay = retry_at.timestamp() - time.time()
                except (TypeError, ValueError, OverflowError):
                    pass
        return max(0, min(30, delay))

    def _pages(self, path):
        visited = set()
        count = 0
        total = None
        while path:
            url = self._safe_url(path)
            if url in visited or len(visited) >= 10000:
                _fail("Apple API pagination is incomplete or cyclic; allocation stopped")
            visited.add(url)
            page = self._request(url)
            if not isinstance(page.get("data"), list):
                _fail("Apple API list response is incomplete; allocation stopped")
            expected = page.get("meta", {}).get("paging", {}).get("total")
            if expected is not None:
                if not isinstance(expected, int) or (total is not None and expected != total):
                    _fail("Apple API inventory changed during pagination; repeat the status lookup")
                total = expected
            count += len(page["data"])
            yield page
            links = page.get("links")
            if not isinstance(links, dict):
                _fail("Apple API response lacks pagination completion evidence")
            path = links.get("next")
            if path is not None and (not isinstance(path, str) or not path):
                _fail("Apple API returned an invalid next-page link")
        if total is not None and count != total:
            _fail("Apple API inventory was incomplete; allocation stopped")

    def _app(self):
        app = self._request("/v1/apps/" + APP_ID).get("data", {})
        if (app.get("type") != "apps" or app.get("id") != APP_ID
                or app.get("attributes", {}).get("bundleId") != BUNDLE_ID):
            _fail("Apple API app identity does not match the existing xDrip app")

    @staticmethod
    def _included(page, resource):
        relation = resource.get("data")
        if not isinstance(relation, dict):
            return None
        return next((item for item in page.get("included", [])
                     if item.get("type") == relation.get("type")
                     and item.get("id") == relation.get("id")), None)

    def _builds(self, version=None):
        query = {"filter[app]": APP_ID, "include": "preReleaseVersion,buildBetaDetail", "limit": 200}
        if version is not None:
            query["filter[preReleaseVersion.version]"] = version
        path = "/v1/builds?" + urllib.parse.urlencode(query)
        result = []
        ids = set()
        for page in self._pages(path):
            for resource in page["data"]:
                identifier = resource.get("id")
                attributes = resource.get("attributes", {})
                if resource.get("type") != "builds" or not identifier or identifier in ids:
                    _fail("Apple API build inventory is ambiguous")
                ids.add(identifier)
                relations = resource.get("relationships", {})
                prerelease = self._included(page, relations.get("preReleaseVersion", {}))
                if prerelease is None:
                    prerelease = self._request("/v1/builds/{}/preReleaseVersion".format(identifier)).get("data")
                release = (prerelease or {}).get("attributes", {})
                if release.get("platform") != "IOS" or not isinstance(release.get("version"), str):
                    _fail("Apple build platform/version could not be verified as iOS")
                if version is not None and release["version"] != version:
                    _fail("Apple's version-filtered build response does not match the requested release")
                # Failed and newly processing builds can have no beta detail.
                # They still reserve a number; missing beta status never proves
                # Internal / Testing and must not turn into a blocking 404 here.
                beta = self._included(page, relations.get("buildBetaDetail", {}))
                if not isinstance(attributes.get("processingState"), str):
                    _fail("Apple build processing state is missing")
                result.append({"id": identifier, "version": release["version"],
                               "build": attributes.get("version"),
                               "processingState": attributes["processingState"],
                               "betaInternalState": (beta or {}).get("attributes", {}).get("internalBuildState"),
                               "expired": attributes.get("expired"),
                               "buildAudienceType": attributes.get("buildAudienceType"),
                               "uploadedDate": attributes.get("uploadedDate")})
        return result

    def _uploads(self, version=None):
        query = {"limit": 200}
        if version is not None:
            query.update({"filter[cfBundleShortVersionString]": version, "filter[platform]": "IOS"})
        path = "/v1/apps/{}/buildUploads?".format(APP_ID) + urllib.parse.urlencode(query)
        result = []
        ids = set()
        for page in self._pages(path):
            for resource in page["data"]:
                identifier = resource.get("id")
                attributes = resource.get("attributes", {})
                if resource.get("type") != "buildUploads" or not identifier or identifier in ids:
                    _fail("Apple API build-upload inventory is ambiguous")
                ids.add(identifier)
                if attributes.get("platform") != "IOS":
                    _fail("Apple upload platform could not be verified as iOS")
                state = attributes.get("state")
                state = state.get("state") if isinstance(state, dict) else None
                if (not isinstance(attributes.get("cfBundleShortVersionString"), str)
                        or state not in {"AWAITING_UPLOAD", "PROCESSING", "FAILED", "COMPLETE"}):
                    _fail("Apple upload version/state is missing or unsupported")
                if version is not None and attributes["cfBundleShortVersionString"] != version:
                    _fail("Apple's version-filtered upload response does not match the requested release")
                result.append({"id": identifier, "version": attributes["cfBundleShortVersionString"],
                               "build": attributes.get("cfBundleVersion"), "state": state})
        return result

    def snapshot(self, version):
        if not isinstance(version, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", version):
            _fail("Release version has an invalid format")
        self._app()
        builds = self._builds()
        uploads = self._uploads()
        version_builds = self._builds(version)
        builds_by_id = {item["id"]: item for item in builds}
        for item in version_builds:
            previous = builds_by_id.get(item["id"])
            if previous and (previous["build"], previous["version"]) != (item["build"], item["version"]):
                _fail("Apple build identity changed during status lookup")
            builds_by_id[item["id"]] = item
        builds = list(builds_by_id.values())
        # Query this release's upload train explicitly, including submissions not
        # yet represented by a Build. A newer scoped response may advance a state
        # or reserve a slot that appeared while the all-version list was read.
        version_uploads = self._uploads(version)
        uploads_by_id = {item["id"]: item for item in uploads}
        for item in version_uploads:
            previous = uploads_by_id.get(item["id"])
            if previous and (previous["build"], previous["version"]) != (item["build"], item["version"]):
                _fail("Apple upload identity changed during status lookup")
            uploads_by_id[item["id"]] = item
        uploads = list(uploads_by_id.values())
        highest, next_build = next_build_number([item["build"] for item in builds + uploads])
        return {"appID": APP_ID, "bundleID": BUNDLE_ID, "platform": "IOS", "version": version,
                "observedAt": _utc_now(), "builds": builds, "uploads": uploads,
                "versionBuilds": [item for item in builds if item["version"] == version],
                "versionUploads": version_uploads, "highestBuild": highest, "nextBuild": next_build}

    def build_status(self, version, build):
        snapshot = self.snapshot(version)
        matches = [item for item in snapshot["builds"]
                   if item["version"] == version and item["build"] == build]
        uploads = [item for item in snapshot["uploads"]
                   if item["version"] == version and item["build"] == build]
        if len(matches) > 1:
            _fail("Apple returned multiple builds for the same version/build")
        if not matches and not uploads:
            return None
        result = dict(matches[0]) if matches else {
            "id": None, "version": version, "build": build,
            "processingState": None, "betaInternalState": None,
            "buildAudienceType": None, "expired": None}
        states = set(item["state"] for item in uploads)
        result.update(appID=APP_ID, observedAt=snapshot["observedAt"], uploads=uploads,
                      uploadState=next(iter(states)) if len(states) == 1 else
                      ("MULTIPLE" if states else None))
        return result

    def _group_build_ids(self, group_id):
        ids = set()
        for page in self._pages("/v1/betaGroups/{}/relationships/builds?limit=200".format(group_id)):
            for item in page["data"]:
                if item.get("type") != "builds" or not isinstance(item.get("id"), str):
                    _fail("Apple internal-group build relationship is incomplete")
                ids.add(item["id"])
        return ids

    def ensure_internal_group(self, build_id, groupName="Ole Internal"):
        if groupName != "Ole Internal":
            _fail("Only the existing Ole Internal tester group is authorized")
        self._app()
        matching_builds = [item for item in self._builds() if item["id"] == build_id]
        if (len(matching_builds) != 1 or matching_builds[0]["processingState"] != "VALID"
                or matching_builds[0]["buildAudienceType"] != "INTERNAL_ONLY"):
            _fail("The requested build is not a verified, processed Internal Only build of the existing app")
        groups = []
        path = "/v1/apps/{}/betaGroups?limit=200".format(APP_ID)
        for page in self._pages(path):
            groups += [item for item in page["data"]
                       if item.get("attributes", {}).get("name") == groupName]
        if len(groups) != 1 or groups[0].get("type") != "betaGroups":
            _fail("The existing Ole Internal group could not be identified unambiguously")
        group = groups[0]
        if group.get("attributes", {}).get("isInternalGroup") is not True:
            _fail("Ole Internal is not an internal tester group; distribution refused")
        group_id = group.get("id")
        if not isinstance(group_id, str) or not group_id:
            _fail("The existing internal group's identifier is missing")
        present = build_id in self._group_build_ids(group_id)
        mutation_error = None
        if not present:
            try:
                self._request("/v1/betaGroups/{}/relationships/builds".format(group_id), "POST",
                              {"data": [{"type": "builds", "id": build_id}]})
            except AppleError as error:
                # A lost response can follow a successful write. Read the actual
                # relationship instead of repeating the mutation blindly.
                mutation_error = str(error)
        if build_id not in self._group_build_ids(group_id):
            prefix = mutation_error + ". " if mutation_error else ""
            _fail(prefix + "Apple did not confirm the internal-group relationship; check Apple before retrying")
        return {"id": group_id, "name": groupName, "isInternalGroup": True,
                "buildID": build_id, "buildLinked": True, "alreadyAttached": present,
                "confirmedAfterUncertainWrite": mutation_error is not None}
