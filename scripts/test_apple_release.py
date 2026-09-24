#!/usr/bin/env python3
"""Offline synthetic tests; no real account, credentials or network are used."""
import base64
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import traceback
import unittest
from unittest import mock
import urllib.error
import urllib.parse

from apple_release import (APP_ID, BUNDLE_ID, API_ORIGIN, AppleClient, AppleError,
                           _der_signature, next_build_number)


def page(data, included=None, next_page=None, total=None):
    value = {"data": data, "links": {"next": next_page}}
    if included is not None:
        value["included"] = included
    if total is not None:
        value["meta"] = {"paging": {"total": total}}
    return value


def build(identifier="b1", number="4263", version="7.0.0", state="VALID"):
    resource = {"type": "builds", "id": identifier,
                "attributes": {"version": number, "processingState": state,
                               "expired": False, "buildAudienceType": "INTERNAL_ONLY"},
                "relationships": {
                    "preReleaseVersion": {"data": {"type": "preReleaseVersions", "id": "v" + identifier}},
                    "buildBetaDetail": {"data": {"type": "buildBetaDetails", "id": "d" + identifier}}}}
    included = [
        {"type": "preReleaseVersions", "id": "v" + identifier,
         "attributes": {"version": version, "platform": "IOS"}},
        {"type": "buildBetaDetails", "id": "d" + identifier,
         "attributes": {"internalBuildState": "IN_BETA_TESTING"}}]
    return resource, included


def upload(number="4264", version="7.1.1", state="PROCESSING", identifier="u1"):
    return {"type": "buildUploads", "id": identifier, "attributes": {
        "cfBundleVersion": number, "cfBundleShortVersionString": version,
        "platform": "IOS", "state": {"state": state, "errors": [], "warnings": [], "infos": []}}}


class FakeApple(AppleClient):
    def __init__(self):
        super().__init__("ABCDEFGHIJ", None, "/synthetic/missing.p8")
        self.calls = []
        resource, included = build()
        self.build_pages = [page([resource], included)]
        self.upload_pages = [page([])]
        self.app_bundle = BUNDLE_ID
        self.group_internal = True
        self.group_name = "Ole Internal"
        self.group_builds = []
        self.link_succeeds = True
        self.extra_pages = {}

    def _request(self, path, method="GET", body=None):
        self.calls.append((path, method, copy.deepcopy(body)))
        parsed = urllib.parse.urlsplit(path)
        path = parsed.path
        if method == "POST":
            if self.link_succeeds:
                self.group_builds.append(body["data"][0]["id"])
            return {}
        if path in self.extra_pages:
            return copy.deepcopy(self.extra_pages[path])
        if path == "/v1/apps/" + APP_ID:
            return {"data": {"type": "apps", "id": APP_ID,
                             "attributes": {"bundleId": self.app_bundle}}}
        if path == "/v1/builds":
            version = urllib.parse.parse_qs(parsed.query).get("filter[preReleaseVersion.version]")
            if version:
                all_pages = self.build_pages + list(self.extra_pages.values())
                included = [item for candidate in all_pages for item in candidate.get("included", [])]
                release_ids = {item["id"] for item in included if item.get("type") == "preReleaseVersions"
                               and item.get("attributes", {}).get("version") == version[0]}
                resources = [item for candidate in all_pages for item in candidate["data"]
                             if item.get("type") == "builds" and
                             item["relationships"]["preReleaseVersion"]["data"]["id"] in release_ids]
                return page(copy.deepcopy(resources), copy.deepcopy(included))
            return copy.deepcopy(self.build_pages[0])
        if path == "/v1/apps/{}/buildUploads".format(APP_ID):
            version = urllib.parse.parse_qs(parsed.query).get("filter[cfBundleShortVersionString]")
            if version:
                all_resources = list(self.upload_pages[0]["data"])
                for extra in self.extra_pages.values():
                    all_resources += [item for item in extra["data"] if item.get("type") == "buildUploads"]
                return page([item for item in all_resources
                             if item["attributes"].get("cfBundleShortVersionString") == version[0]])
            return copy.deepcopy(self.upload_pages[0])
        if path == "/v1/apps/{}/betaGroups".format(APP_ID):
            return page([{"type": "betaGroups", "id": "g1", "attributes": {
                "name": self.group_name, "isInternalGroup": self.group_internal}}])
        if path == "/v1/betaGroups/g1/relationships/builds":
            return page([{"type": "builds", "id": identifier} for identifier in self.group_builds])
        raise AssertionError("Unexpected synthetic request " + path)


class BuildAllocationTests(unittest.TestCase):
    def test_empty_inventory(self):
        self.assertEqual(next_build_number([]), (None, "1"))

    def test_numbers_sort_numerically_not_lexically(self):
        self.assertEqual(next_build_number(["99", "100", "4263"]), ("4263", "4264"))

    def test_dotted_builds_reserve_whole_next_integer(self):
        self.assertEqual(next_build_number(["4263", "4263.2.9", "4262.99"]), ("4263.2.9", "4264"))

    def test_unknown_number_is_not_silently_ignored(self):
        for number in (None, 4263, "4263b1", "4.2.6.3", "-1", "1e4", "", "1" * 20):
            with self.subTest(number=number), self.assertRaises(AppleError):
                next_build_number(["4263", number])


class SnapshotTests(unittest.TestCase):
    def test_all_build_and_upload_pages_reserve_failed_and_inflight_slots(self):
        client = FakeApple()
        first = client.build_pages[0]
        first["links"]["next"] = API_ORIGIN + "/v1/build-page-2"
        first["meta"] = {"paging": {"total": 2}}
        resource, included = build("b2", "4264", "7.1.1", "PROCESSING")
        client.extra_pages["/v1/build-page-2"] = page([resource], included, total=2)
        client.upload_pages[0] = page([upload("4265", state="FAILED")],
                                      next_page=API_ORIGIN + "/v1/upload-page-2", total=2)
        client.extra_pages["/v1/upload-page-2"] = page([upload("4266", identifier="u2")], total=2)
        result = client.snapshot("7.1.1")
        self.assertEqual(result["highestBuild"], "4266")
        self.assertEqual(result["nextBuild"], "4267")
        self.assertEqual([item["id"] for item in result["versionBuilds"]], ["b2"])
        self.assertEqual(len(result["builds"]), 2)
        self.assertEqual(len(result["uploads"]), 2)
        self.assertEqual(len(result["versionUploads"]), 2)
        version_calls = [call for call in client.calls if "filter%5BcfBundleShortVersionString%5D=7.1.1" in call[0]]
        self.assertEqual(len(version_calls), 1)
        self.assertIn("filter%5Bplatform%5D=IOS", version_calls[0][0])
        build_version_calls = [call for call in client.calls
                               if "filter%5BpreReleaseVersion.version%5D=7.1.1" in call[0]]
        self.assertEqual(len(build_version_calls), 1)

    def test_wrong_app_identity_aborts_before_inventory(self):
        client = FakeApple()
        client.app_bundle = "com.somebody.else"
        with self.assertRaises(AppleError):
            client.snapshot("7.1.1")
        self.assertEqual(len(client.calls), 1)

    def test_other_platform_is_not_assumed_ios(self):
        client = FakeApple()
        client.build_pages[0]["included"][0]["attributes"]["platform"] = "MAC_OS"
        with self.assertRaises(AppleError):
            client.snapshot("7.1.1")

    def test_unknown_upload_state_missing_version_blocks_allocation(self):
        client = FakeApple()
        malformed = upload()
        del malformed["attributes"]["cfBundleShortVersionString"]
        client.upload_pages[0] = page([malformed])
        with self.assertRaises(AppleError):
            client.snapshot("7.1.1")

    def test_cyclic_pagination_blocks_allocation(self):
        client = FakeApple()
        client.build_pages[0]["links"]["next"] = API_ORIGIN + "/v1/builds"
        with self.assertRaises(AppleError):
            client.snapshot("7.1.1")

    def test_incomplete_total_blocks_allocation(self):
        client = FakeApple()
        client.build_pages[0]["meta"] = {"paging": {"total": 2}}
        with self.assertRaises(AppleError):
            client.snapshot("7.1.1")

    def test_next_link_may_be_omitted_on_terminal_page(self):
        client = FakeApple()
        client.build_pages[0]["links"] = {"self": API_ORIGIN + "/v1/builds"}
        self.assertEqual(client.snapshot("7.1.1")["nextBuild"], "4264")

    def test_duplicate_record_across_pages_fails_closed(self):
        client = FakeApple()
        client.build_pages[0]["data"] *= 2
        with self.assertRaises(AppleError):
            client.snapshot("7.1.1")

    def test_build_without_beta_detail_still_reserves_number(self):
        for processing_state in ("PROCESSING", "FAILED", "INVALID"):
            with self.subTest(processing_state=processing_state):
                client = FakeApple()
                resource, included = build("b2", "4265", "7.1.1", processing_state)
                resource["relationships"].pop("buildBetaDetail")
                client.build_pages[0] = page([resource], included[:1])
                result = client.snapshot("7.1.1")
                self.assertEqual(result["nextBuild"], "4266")
                self.assertIsNone(result["builds"][0]["betaInternalState"])
                self.assertFalse(any("/buildBetaDetail" in call[0] for call in client.calls))

    def test_new_build_in_scoped_lookup_reserves_next_number(self):
        client = FakeApple()
        original_request = client._request
        def latest_build(path, method="GET", body=None):
            if "filter%5BpreReleaseVersion.version%5D=7.1.1" in path:
                resource, included = build("new-build", "4268", "7.1.1", "PROCESSING")
                return page([resource], included)
            return original_request(path, method, body)
        client._request = latest_build
        snapshot = client.snapshot("7.1.1")
        self.assertEqual(snapshot["nextBuild"], "4269")
        self.assertEqual(snapshot["versionBuilds"][0]["id"], "new-build")

    def test_scoped_build_cannot_change_existing_build_identity(self):
        client = FakeApple()
        original_request = client._request
        def changed_identity(path, method="GET", body=None):
            if "filter%5BpreReleaseVersion.version%5D=7.1.1" in path:
                resource, included = build("b1", "4263", "7.1.1")
                return page([resource], included)
            return original_request(path, method, body)
        client._request = changed_identity
        with self.assertRaises(AppleError):
            client.snapshot("7.1.1")

    def test_unknown_upload_state_never_allocates_a_number(self):
        client = FakeApple()
        client.upload_pages[0] = page([upload(state="FUTURE_UNKNOWN_STATE")])
        with self.assertRaises(AppleError):
            client.snapshot("7.1.1")

    def test_external_pagination_link_is_refused_before_request(self):
        client = FakeApple()
        client.build_pages[0]["links"]["next"] = "https://other.example/v1/builds"
        with self.assertRaises(AppleError):
            client.snapshot("7.1.1")
        self.assertFalse(any("other.example" in call[0] for call in client.calls))

    def test_missing_build_returns_none(self):
        self.assertIsNone(FakeApple().build_status("7.1.1", "4264"))

    def test_inflight_upload_returns_receipt_not_testing(self):
        client = FakeApple()
        client.upload_pages[0] = page([upload()])
        status = client.build_status("7.1.1", "4264")
        self.assertIsNone(status["id"])
        self.assertIsNone(status["betaInternalState"])
        self.assertEqual(status["uploadState"], "PROCESSING")

    def test_processed_build_returns_exact_internal_state(self):
        status = FakeApple().build_status("7.0.0", "4263")
        self.assertEqual(status["id"], "b1")
        self.assertEqual(status["processingState"], "VALID")
        self.assertEqual(status["betaInternalState"], "IN_BETA_TESTING")
        self.assertEqual(status["buildAudienceType"], "INTERNAL_ONLY")


class InternalGroupTests(unittest.TestCase):
    def test_existing_internal_group_gets_only_missing_build_relation(self):
        client = FakeApple()
        result = client.ensure_internal_group("b1")
        self.assertTrue(result["buildLinked"])
        mutations = [call for call in client.calls if call[1] == "POST"]
        self.assertEqual(mutations, [("/v1/betaGroups/g1/relationships/builds", "POST",
                                     {"data": [{"type": "builds", "id": "b1"}]})])

    def test_existing_membership_is_read_only(self):
        client = FakeApple()
        client.group_builds = ["b1"]
        self.assertTrue(client.ensure_internal_group("b1")["alreadyAttached"])
        self.assertFalse(any(call[1] != "GET" for call in client.calls))

    def test_external_group_rejected_without_mutation(self):
        client = FakeApple()
        client.group_internal = False
        with self.assertRaises(AppleError):
            client.ensure_internal_group("b1")
        self.assertFalse(any(call[1] != "GET" for call in client.calls))

    def test_missing_group_is_never_created(self):
        client = FakeApple()
        client.group_name = "Other group"
        with self.assertRaises(AppleError):
            client.ensure_internal_group("b1")
        self.assertFalse(any(call[1] != "GET" for call in client.calls))

    def test_different_requested_group_refused(self):
        client = FakeApple()
        with self.assertRaises(AppleError):
            client.ensure_internal_group("b1", "New group")
        self.assertFalse(client.calls)

    def test_foreign_build_refused(self):
        client = FakeApple()
        with self.assertRaises(AppleError):
            client.ensure_internal_group("not-this-app")
        self.assertFalse(any(call[1] != "GET" for call in client.calls))

    def test_app_store_eligible_build_is_not_attached(self):
        client = FakeApple()
        client.build_pages[0]["data"][0]["attributes"]["buildAudienceType"] = "APP_STORE_ELIGIBLE"
        with self.assertRaises(AppleError):
            client.ensure_internal_group("b1")
        self.assertFalse(any(call[1] != "GET" for call in client.calls))

    def test_ambiguous_group_write_is_not_retried(self):
        client = FakeApple()
        original_request = client._request
        writes = []
        def uncertain_request(path, method="GET", body=None):
            if method == "POST":
                writes.append(path)
                raise AppleError("Synthetic uncertain transport outcome")
            return original_request(path, method, body)
        client._request = uncertain_request
        with self.assertRaises(AppleError):
            client.ensure_internal_group("b1")
        self.assertEqual(len(writes), 1)

    def test_uncertain_group_write_is_confirmed_by_read_without_retry(self):
        client = FakeApple()
        original_request = client._request
        writes = []
        def committed_but_response_lost(path, method="GET", body=None):
            result = original_request(path, method, body)
            if method == "POST":
                writes.append(path)
                raise AppleError("Synthetic response lost after successful write")
            return result
        client._request = committed_but_response_lost
        result = client.ensure_internal_group("b1")
        self.assertTrue(result["buildLinked"])
        self.assertTrue(result["confirmedAfterUncertainWrite"])
        self.assertEqual(len(writes), 1)

    def test_unconfirmed_relation_is_not_reported_success(self):
        client = FakeApple()
        client.link_succeeds = False
        with self.assertRaises(AppleError):
            client.ensure_internal_group("b1")
        self.assertEqual(len([call for call in client.calls if call[1] == "POST"]), 1)


class AuthAndTransportTests(unittest.TestCase):
    def test_pagination_cannot_forward_auth_to_another_host(self):
        for path in ("https://evil.example/v1/builds", "http://api.appstoreconnect.apple.com/v1/builds",
                     "https://api.appstoreconnect.apple.com@evil.example/v1/builds",
                     "https://api.appstoreconnect.apple.com:444/v1/builds"):
            with self.subTest(path=path), self.assertRaises(AppleError):
                AppleClient._safe_url(path)

    @mock.patch("apple_release.time.sleep")
    def test_http_auth_errors_are_sanitized(self, sleep):
        client = AppleClient("ABCDEFGHIJ", None, "/synthetic/key.p8")
        client._jwt = lambda: "synthetic.jwt.never.log"
        for code in (401, 403, 429, 500, 302):
            with self.subTest(code=code):
                client._opener.open = mock.Mock(side_effect=urllib.error.HTTPError(
                    API_ORIGIN, code, "SECRET SERVER MESSAGE", {}, None))
                try:
                    client._request("/v1/apps/" + APP_ID)
                except AppleError:
                    self.assertNotIn("SECRET", traceback.format_exc())
                else:
                    self.fail("The synthetic Apple error was not rejected")
                with self.assertRaises(AppleError) as error:
                    client._request("/v1/apps/" + APP_ID)
                self.assertNotIn("SECRET", str(error.exception))
                self.assertNotIn("synthetic.jwt", str(error.exception))

    @mock.patch("apple_release.time.sleep")
    def test_transient_get_retries_honor_capped_retry_after(self, sleep):
        client = AppleClient("ABCDEFGHIJ", None, "/synthetic/key.p8")
        client._jwt = lambda: "synthetic.jwt.never.log"
        response = mock.MagicMock()
        response.status = 200
        response.read.return_value = b'{"data": []}'
        response.__enter__.return_value = response
        for code in (429, 502, 503, 504):
            with self.subTest(code=code):
                sleep.reset_mock()
                client._opener.open = mock.Mock(side_effect=[
                    urllib.error.HTTPError(API_ORIGIN, code, "temporary", {"Retry-After": "90"}, None),
                    response])
                self.assertEqual(client._request("/v1/builds"), {"data": []})
                self.assertEqual(client._opener.open.call_count, 2)
                sleep.assert_called_once_with(30)

    @mock.patch("apple_release.time.sleep")
    def test_get_transport_retries_are_bounded(self, sleep):
        client = AppleClient("ABCDEFGHIJ", None, "/synthetic/key.p8")
        client._jwt = lambda: "synthetic.jwt.never.log"
        client._opener.open = mock.Mock(side_effect=TimeoutError())
        with self.assertRaises(AppleError):
            client._request("/v1/builds")
        self.assertEqual(client._opener.open.call_count, 3)
        self.assertEqual(sleep.call_count, 2)

    @mock.patch("apple_release.time.sleep")
    def test_auth_errors_and_post_requests_are_never_retried(self, sleep):
        client = AppleClient("ABCDEFGHIJ", None, "/synthetic/key.p8")
        client._jwt = lambda: "synthetic.jwt.never.log"
        for method, code in (("GET", 401), ("GET", 403), ("POST", 429), ("POST", 503)):
            with self.subTest(method=method, code=code):
                sleep.reset_mock()
                client._opener.open = mock.Mock(side_effect=urllib.error.HTTPError(
                    API_ORIGIN, code, "synthetic", {"Retry-After": "1"}, None))
                with self.assertRaises(AppleError):
                    client._request("/v1/betaGroups/g1/relationships/builds", method, {"data": []})
                self.assertEqual(client._opener.open.call_count, 1)
                sleep.assert_not_called()

    def test_retry_after_accepts_http_date_and_limits_negative_values(self):
        with mock.patch("apple_release.time.time", return_value=1000):
            self.assertEqual(AppleClient._retry_delay(
                {"Retry-After": "Thu, 01 Jan 1970 00:17:00 GMT"}, 0), 20)
        self.assertEqual(AppleClient._retry_delay({"Retry-After": "-1"}, 0), 0)
        self.assertEqual(AppleClient._retry_delay({"Retry-After": "invalid"}, 1), 2)

    def test_missing_config_requests_api_access_not_build_number(self):
        with mock.patch.dict(os.environ, {"XDRIP_ASC_CONFIG": "/synthetic/missing-config.json"}):
            with self.assertRaises(AppleError) as error:
                AppleClient.from_environment()
            self.assertIn("API", str(error.exception))
            self.assertNotIn("build number", str(error.exception))

    def test_config_and_key_must_stay_private_and_outside_git(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "config.json"
            key = Path(directory) / "key.p8"
            key.write_text("synthetic placeholder")
            key.chmod(0o600)
            config.write_text(json.dumps({"keyID": "ABCDEFGHIJ", "privateKeyPath": str(key)}))
            config.chmod(0o600)
            with mock.patch.dict(os.environ, {"XDRIP_ASC_CONFIG": str(config)}):
                self.assertIsNone(AppleClient.from_environment().issuer_id)
                key.chmod(0o644)
                with self.assertRaises(AppleError):
                    AppleClient.from_environment()
                key.chmod(0o600)
                (Path(directory) / ".git").mkdir()
                with self.assertRaises(AppleError):
                    AppleClient.from_environment()

    def test_team_and_individual_jwt_claims_and_raw_signature(self):
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory) / "synthetic.p8"
            subprocess.run(["/usr/bin/openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout",
                            "-out", str(key)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            key.chmod(0o600)
            for issuer in (None, "00000000-0000-0000-0000-000000000001"):
                client = AppleClient("ABCDEFGHIJ", issuer, key)
                token = client._jwt()
                header, payload, signature = token.split(".")
                claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
                raw = base64.urlsafe_b64decode(signature + "=" * (-len(signature) % 4))
                self.assertEqual(len(raw), 64)
                self.assertEqual(claims["aud"], "appstoreconnect-v1")
                self.assertLessEqual(claims["exp"] - claims["iat"], 1200)
                self.assertEqual(claims.get("iss"), issuer)
                self.assertEqual(claims.get("sub"), None if issuer else "user")
                self.assertNotIn(token, client.upload_auth_args())
                self.assertIn("--p8-file-path", client.upload_auth_args())

    def test_malformed_ecdsa_signature_fails_closed(self):
        for value in (b"", b"\x30\x00", b"\x30\x04\x02\x00\x02\x00"):
            with self.assertRaises(AppleError):
                _der_signature(value)


if __name__ == "__main__":
    unittest.main(verbosity=2)
