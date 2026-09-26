#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
# Re-exec under the host-wide lock. A release parent passes the same open lock.
if [[ -z "${XDRIP_BUILD_LOCK_FD:-}" ]]; then
  exec python3 -B "$repo_root/scripts/build_lock.py" /bin/bash "$0" "$@"
fi
python3 -B -c 'import sys; sys.path.insert(0, "scripts"); from build_lock import inherited_fd; inherited_fd()'
# The waiting shell retains the lock; long-lived Xcode helpers do not inherit it.
xcodebuild() { python3 -B "$repo_root/scripts/build_lock.py" --child xcodebuild "$@"; }
xcrun() { python3 -B "$repo_root/scripts/build_lock.py" --child xcrun "$@"; }


team_id="GFZ896KN66"
main_bundle_id="com.GFZ896KN66.xdripswift"
workspace="$repo_root/xdrip.xcworkspace"
run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
output_root="${XDRIP_OUTPUT_ROOT:-$repo_root/build/local/$run_stamp}"
logs_dir="$output_root/logs"
results_dir="$output_root/results"
derived_data="$output_root/DerivedData"
xcode_auth_args=(-allowProvisioningUpdates)

mkdir -p "$logs_dir" "$results_dir" "$derived_data"

die() {
  echo "error: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "required tool is missing: $1"
}

usage() {
  cat <<'EOF'
Usage: scripts/local-build.sh COMMAND

Commands:
  status              Show source, Xcode and local signing state.
  python              Run the offline Python verification sets.
  test-ci             Run Codemagic's eight required XCTest suites serially.
  test-all            Run the complete xdripTests target serially.
  build               Build the iPhone and Watch simulator products unsigned.
  all                 Run Python checks, test-ci and both simulator builds.
  release-test        Run Python, the complete XCTest suite and both builds.
  release-preflight   Check local inputs for Xcode cloud-managed signing.
  archive             Archive the clean, pushed TestFlight tag and export locally.
  verify-signed       Verify an existing archive/export app (XDRIP_APP_PATH,
                      XDRIP_SIGNING_PHASE, XDRIP_BUILD_NUMBER,
                      XDRIP_SOURCE_COMMIT).

The script has no upload command and never registers devices. The archive
command allows Xcode to manage signing assets, creates a developer-signed
.xcarchive, and then makes a cloud-signed App Store Connect export locally.
It requires a clean, remotely pushed release commit and tag, plus the matching
test receipt from scripts/release-testflight.py. That process automatically
queries Apple and supplies the build number and its allocation receipt.
EOF
}

ensure_tools() {
  need git
  need python3
  need xcodebuild
  need xcrun
}

ensure_identity_override() {
  local override="$repo_root/xDripConfigOverride.xcconfig"
  if [ ! -e "$override" ]; then
    cat > "$override" <<EOF
// Local, git-ignored identity override for Don-Olsen/xdripswift.
// Keep build/upload credentials and profile UUIDs out of this file.
XDRIP_DEVELOPMENT_TEAM = $team_id
XDRIP_CODE_SIGN_IDENTITY_RELEASE = Apple Development
EOF
  fi
  grep -Eq "^[[:space:]]*XDRIP_DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*$team_id[[:space:]]*$" "$override" \
    || die "xDripConfigOverride.xcconfig does not select team $team_id"
  grep -Eq "^[[:space:]]*XDRIP_CODE_SIGN_IDENTITY_RELEASE[[:space:]]*=[[:space:]]*Apple Development[[:space:]]*$" "$override" \
    || die "xDripConfigOverride.xcconfig must leave archive signing to Apple Development"
}

select_simulator() {
  if [ -n "${XDRIP_SIMULATOR_ID:-}" ]; then
    printf '%s\n' "$XDRIP_SIMULATOR_ID"
    return
  fi
  xcrun simctl list devices available -j | python3 -c '
import json, sys
payload = json.load(sys.stdin)
for devices in payload.get("devices", {}).values():
    for device in devices:
        if device.get("isAvailable", True) and device.get("name", "").startswith("iPhone"):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit("no available iPhone simulator")
'
}

boot_simulator() {
  local simulator_id="$1"
  xcrun simctl boot "$simulator_id" >/dev/null 2>&1 || :
  xcrun simctl bootstatus "$simulator_id" -b
}

show_status() {
  echo "Repository: $repo_root"
  git remote -v
  echo "Branch: $(git branch --show-current)"
  echo "Commit: $(git rev-parse HEAD)"
  git status --short --branch
  xcodebuild -version
  echo "Developer directory: $(xcode-select -p)"
  security find-identity -v -p codesigning
  echo "A local Apple Distribution identity is not required for cloud-managed export."
}

run_python_checks() {
  python3 -B scripts/test_release_cleanup.py 2>&1 \
    | tee "$logs_dir/python-release-cleanup.log"
  set -o pipefail
  python3 -B scripts/test-check-apple-processing.py 2>&1 \
    | tee "$logs_dir/python-check-apple-processing.log"
  python3 -B scripts/record-watch-test-results.py --self-test 2>&1 \
    | tee "$logs_dir/python-record-watch-self-test.log"
  python3 -B scripts/verify-watch-release.py --self-test 2>&1 \
    | tee "$logs_dir/python-verify-watch-release-self-test.log"
  python3 -B scripts/test_release_testflight.py 2>&1 \
    | tee "$logs_dir/python-release-guards.log"
  python3 -B scripts/test_apple_release.py 2>&1 \
    | tee "$logs_dir/python-apple-release.log"
}

run_ci_tests() {
  local simulator_id result_bundle
  simulator_id="$(select_simulator)"
  boot_simulator "$simulator_id"
  printf '%s\n' "$simulator_id" > "$results_dir/simulator-id.txt"
  result_bundle="$results_dir/Verification.xcresult"
  [ ! -e "$result_bundle" ] || die "result bundle already exists: $result_bundle"

  set -o pipefail
  xcodebuild test \
    -workspace "$workspace" \
    -scheme xdrip \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -parallel-testing-enabled NO \
    -only-testing:xdripTests/RootHomeInteractionTests \
    -only-testing:xdripTests/LibreWatchValuePipelineTests \
    -only-testing:xdripTests/TroubleshootingLogTests \
    -only-testing:xdripTests/WatchRefreshCoordinatorTests \
    -only-testing:xdripTests/WatchPhoneRefreshServiceTests \
    -only-testing:xdripTests/WatchSnapshotSemanticsTests \
    -only-testing:xdripTests/WatchDeliveryEvidenceTests \
    -only-testing:xdripTests/NightscoutHistoryWriteTests \
    -resultBundlePath "$result_bundle" \
    -derivedDataPath "$derived_data/verification" \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee "$logs_dir/xctest-verification.log"

  python3 -B scripts/record-watch-test-results.py \
    "$result_bundle" "$results_dir/stability-summary.json" \
    --include-verify-only 2>&1 | tee "$logs_dir/record-xctest-results.log"
}

run_all_tests() {
  local simulator_id result_bundle
  simulator_id="$(select_simulator)"
  boot_simulator "$simulator_id"
  result_bundle="$results_dir/AllTests.xcresult"
  [ ! -e "$result_bundle" ] || die "result bundle already exists: $result_bundle"

  set -o pipefail
  xcodebuild test \
    -workspace "$workspace" \
    -scheme xdrip \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$simulator_id" \
    -parallel-testing-enabled NO \
    -resultBundlePath "$result_bundle" \
    -derivedDataPath "$derived_data/all-tests" \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee "$logs_dir/all-xctest.log"
}

build_simulators() {
  set -o pipefail
  xcodebuild build \
    -workspace "$workspace" \
    -scheme xdrip \
    -configuration Debug \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$derived_data/iphone-build" \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee "$logs_dir/iphone-build.log"

  xcodebuild build \
    -workspace "$workspace" \
    -scheme "xDrip Watch App" \
    -configuration Debug \
    -destination "generic/platform=watchOS Simulator" \
    -derivedDataPath "$derived_data/watch-build" \
    CODE_SIGNING_ALLOWED=NO \
      2>&1 | tee "$logs_dir/watch-build.log"
}

verify_local_release_settings() {
  local settings_json="$results_dir/release-build-settings.json"
  xcodebuild -showBuildSettings -json \
    -project "$repo_root/xdrip.xcodeproj" \
    -alltargets \
    -configuration Release \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="Apple Development" \
    DEVELOPMENT_TEAM="$team_id" \
    XDRIP_DEVELOPMENT_TEAM="$team_id" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    > "$settings_json" 2> "$logs_dir/release-build-settings.log"

  SETTINGS_JSON="$settings_json" XDRIP_TEAM_ID="$team_id" XDRIP_MAIN_BUNDLE_ID="$main_bundle_id" \
    python3 - <<'PY'
import json
import os
from pathlib import Path

team = os.environ["XDRIP_TEAM_ID"]
main = os.environ["XDRIP_MAIN_BUNDLE_ID"]
expected = {
    "xdrip": main,
    "xDrip Widget Extension": main + ".xDripWidget",
    "xDrip Notification Context Extension": main + ".xDripNotificationContextExtension",
    "xDrip Watch App": main + ".watchkitapp",
    "xDrip Watch Complication Extension": main + ".watchkitapp.xDripWatchComplication",
}
payload = json.loads(Path(os.environ["SETTINGS_JSON"]).read_text(encoding="utf-8"))
seen = set()
for entry in payload:
    target = entry.get("target")
    if target not in expected:
        continue
    settings = entry.get("buildSettings", {})
    checks = {
        "PRODUCT_BUNDLE_IDENTIFIER": expected[target],
        "DEVELOPMENT_TEAM": team,
        "CODE_SIGN_STYLE": "Automatic",
        "CODE_SIGN_IDENTITY": "Apple Development",
        "PROVISIONING_PROFILE_SPECIFIER": "",
    }
    for key, wanted in checks.items():
        if settings.get(key, "") != wanted:
            raise SystemExit(f"{target}: unexpected {key}={settings.get(key)!r}")
    seen.add(target)
missing = sorted(set(expected) - seen)
if missing:
    raise SystemExit("missing Release build settings for: " + ", ".join(missing))
print("Verified local automatic signing settings for all five existing bundle IDs.")
PY
}

configure_xcode_auth() {
  local key_path="${XDRIP_XCODE_AUTH_KEY_PATH:-}"
  local key_id="${XDRIP_XCODE_AUTH_KEY_ID:-}"
  local issuer_id="${XDRIP_XCODE_AUTH_KEY_ISSUER_ID:-}"
  xcode_auth_args=(-allowProvisioningUpdates)
  if [ -n "$key_path$key_id$issuer_id" ]; then
    [ -f "$key_path" ] || die "Xcode team API private key is missing"
    [[ "$key_id" =~ ^[A-Za-z0-9]{10}$ ]] || die "Xcode team API key ID is invalid"
    [ -n "$issuer_id" ] || die "Xcode team API issuer ID is missing"
    xcode_auth_args+=(-authenticationKeyPath "$key_path"
                      -authenticationKeyID "$key_id"
                      -authenticationKeyIssuerID "$issuer_id")
  fi
}

release_preflight() {
  local account_count blocked=0
  configure_xcode_auth
  verify_local_release_settings
  account_count="$(python3 - <<'PY'
import plistlib
from pathlib import Path

path = Path.home() / "Library/Preferences/com.apple.dt.Xcode.plist"
try:
    with path.open("rb") as stream:
        payload = plistlib.load(stream)
    accounts = payload.get("DVTDeveloperAccountManagerAppleIDLists", {})
    print(len(accounts) if isinstance(accounts, dict) else 0)
except (OSError, plistlib.InvalidFileException):
    print(0)
PY
)"

  echo "Configured Xcode Apple ID account records: $account_count"
  if [ "$account_count" -lt 1 ] && [ "${#xcode_auth_args[@]}" -eq 1 ]; then
    echo "No Xcode account or team API key is available for signing."
    blocked=1
  fi

  echo "Signing mode: Xcode Automatic + cloud-managed local export"
  if [ "${#xcode_auth_args[@]}" -gt 1 ]; then
    echo "Authentication: external App Store Connect team API key"
  fi
  echo "Developer Team: $team_id"

  if [ -z "${XDRIP_BUILD_NUMBER:-}" ]; then
    echo "ASC-confirmed next build number: missing"
    blocked=1
  elif ! printf '%s' "$XDRIP_BUILD_NUMBER" | grep -Eq '^[1-9][0-9]*$'; then
    echo "ASC-confirmed next build number: invalid"
    blocked=1
  elif ! verify_apple_allocation; then
    echo "Apple allocation receipt missing or inconsistent; run release-testflight.py prepare"
    blocked=1
  else
    echo "ASC-confirmed next build number: $XDRIP_BUILD_NUMBER"
  fi

  [ "$blocked" -eq 0 ] || return 1
}

verify_apple_allocation() {
  python3 - <<'PY'
import json
import os
from pathlib import Path

path = os.environ.get("XDRIP_ASC_ALLOCATION_PATH", "")
if not path or not Path(path).is_file():
    raise SystemExit(1)
receipt = json.loads(Path(path).read_text(encoding="utf-8"))
if (receipt.get("appID") != "6795645396" or
        receipt.get("selectedBuild") != os.environ.get("XDRIP_BUILD_NUMBER") or
        not receipt.get("observedAt") or receipt.get("snapshot", {}).get("appID") != "6795645396"):
    raise SystemExit(1)
PY
}

verify_release_checkpoint() {
  local tag="${XDRIP_RELEASE_TAG:-}" state="${XDRIP_RELEASE_STATE_PATH:-}"
  local commit branch remote_branch remote_tag source_tree
  [ -n "$tag" ] || die "set XDRIP_RELEASE_TAG to the pushed TestFlight tag"
  [ -f "$state" ] || die "set XDRIP_RELEASE_STATE_PATH to the test receipt"
  case "$(git remote get-url origin)" in
    https://github.com/Don-Olsen/xdripswift.git|git@github.com:Don-Olsen/xdripswift.git|ssh://git@github.com/Don-Olsen/xdripswift.git) ;;
    *) die "origin is not Don-Olsen/xdripswift" ;;
  esac
  git check-ref-format "refs/tags/$tag" >/dev/null \
    || die "invalid release tag"
  [ -z "$(git status --porcelain --untracked-files=all)" ] \
    || die "release working tree is not clean"
  [ ! -e "$repo_root/xDrip/VersionOverride.xcconfig" ] \
    || die "remove the local version override before a tagged release"

  commit="$(git rev-parse HEAD)"
  source_tree="$(git rev-parse 'HEAD^{tree}')"
  branch="$(git branch --show-current)"
  [ -n "$branch" ] || die "release branch is detached"
  [ "$(git rev-parse "refs/tags/$tag^{}")" = "$commit" ] \
    || die "local TestFlight tag does not point to HEAD"
  [ "$tag" = "testflight-$(sed -n 's/^XDRIP_MARKETING_VERSION = //p' xDrip/Version.xcconfig)-${XDRIP_BUILD_NUMBER:-}" ] \
    || die "release tag does not match version and build"
  grep -Eq "^CURRENT_PROJECT_VERSION = ${XDRIP_BUILD_NUMBER:-}$" xDrip/Version.xcconfig \
    || die "checked-in CURRENT_PROJECT_VERSION does not match the release build"

  RELEASE_STATE_PATH="$state" RELEASE_COMMIT="$commit" RELEASE_TREE="$source_tree" \
    RELEASE_TAG="$tag" RELEASE_BUILD="${XDRIP_BUILD_NUMBER:-}" \
    python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path

state = json.loads(Path(os.environ["RELEASE_STATE_PATH"]).read_text(encoding="utf-8"))
for key, expected in (
    ("checkpoint", os.environ["RELEASE_COMMIT"]),
    ("tree", os.environ["RELEASE_TREE"]),
    ("tag", os.environ["RELEASE_TAG"]),
    ("build", os.environ["RELEASE_BUILD"]),
):
    if state.get(key) != expected:
        raise SystemExit(f"release receipt {key} does not match tagged HEAD")
if state.get("step") != "tagged":
    raise SystemExit("release receipt must be at the tagged step before archive")
if state.get("tests", {}).get("verificationPassed") is not True:
    raise SystemExit("release receipt does not confirm passing tests")
allocation = Path(os.environ.get("XDRIP_ASC_ALLOCATION_PATH", ""))
if not allocation.is_file() or str(allocation) != state.get("allocationPath"):
    raise SystemExit("release receipt is missing its Apple allocation")
if hashlib.sha256(allocation.read_bytes()).hexdigest() != state.get("allocationSha256"):
    raise SystemExit("Apple allocation changed since the tested checkpoint")
PY

  remote_branch="$(git ls-remote origin "refs/heads/$branch" | cut -f1)"
  [ "$remote_branch" = "$commit" ] || die "remote release branch is not the checkpoint commit"
  remote_tag="$(git ls-remote origin "refs/tags/$tag^{}" | cut -f1)"
  [ "$remote_tag" = "$commit" ] || die "remote TestFlight tag is not the checkpoint commit"
  printf '%s\n' "$commit"
}

verify_signed_bundle_tree() {
  local phone_app="$1" signing_phase="$2" source_commit="$3" build_number="$4" manifest="$5"
  PHONE_APP="$phone_app" SIGNING_PHASE="$signing_phase" \
    XDRIP_TEAM_ID="$team_id" XDRIP_MAIN_BUNDLE_ID="$main_bundle_id" \
    SOURCE_COMMIT="$source_commit" XDRIP_BUILD_NUMBER="$build_number" MANIFEST_PATH="$manifest" \
    python3 - <<'PY'
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import subprocess

phone = Path(os.environ["PHONE_APP"])
phase = os.environ["SIGNING_PHASE"]
team = os.environ["XDRIP_TEAM_ID"]
main_id = os.environ["XDRIP_MAIN_BUNDLE_ID"]
expected_build = os.environ["XDRIP_BUILD_NUMBER"]
loop_group = "group.com." + team + ".loopkit.LoopGroup"
trio_group = "group.org.nightscout." + team + ".trio.trio-app-group"
bundles = [
    (phone, main_id, {loop_group, trio_group}),
    (phone / "PlugIns/xDrip Widget Extension.appex", main_id + ".xDripWidget", {loop_group}),
    (phone / "PlugIns/xDrip Notification Context Extension.appex", main_id + ".xDripNotificationContextExtension", {loop_group}),
    (phone / "Watch/xDrip Watch App.app", main_id + ".watchkitapp", {loop_group}),
    (phone / "Watch/xDrip Watch App.app/PlugIns/xDrip Watch Complication Extension.appex",
     main_id + ".watchkitapp.xDripWatchComplication", {loop_group}),
]

def permits(claim, allowance):
    if isinstance(claim, str) and isinstance(allowance, str):
        if allowance.endswith("*") and allowance.count("*") == 1:
            return claim.startswith(allowance[:-1])
        return claim == allowance
    if isinstance(claim, list) and isinstance(allowance, list):
        return all(any(permits(item, candidate) for candidate in allowance) for item in claim)
    return claim == allowance

if phase not in {"archive-development", "export-distribution"}:
    raise SystemExit("unsupported signing phase: " + phase)

rows = []
version = None
for bundle, expected_id, expected_groups in bundles:
    if not bundle.is_dir():
        raise SystemExit("missing embedded bundle: " + str(bundle))
    with (bundle / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != expected_id:
        raise SystemExit("unexpected bundle ID: " + str(bundle))
    if info.get("CFBundleVersion") != expected_build:
        raise SystemExit("build mismatch: " + str(bundle))
    current_version = info.get("CFBundleShortVersionString")
    version = current_version if version is None else version
    if current_version != version:
        raise SystemExit("marketing version mismatch: " + str(bundle))

    subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True)
    detail = subprocess.check_output(
        ["codesign", "-dv", "--verbose=4", str(bundle)],
        stderr=subprocess.STDOUT,
        text=True,
    )
    if "TeamIdentifier=" + team not in detail:
        raise SystemExit("wrong signing team: " + str(bundle))
    if phase == "archive-development":
        if "Authority=Apple Development" not in detail and "Authority=iPhone Developer" not in detail:
            raise SystemExit("archive bundle is not development-signed: " + str(bundle))
    elif "Authority=Apple Distribution" not in detail and "Authority=iPhone Distribution" not in detail:
        raise SystemExit("export bundle is not distribution-signed: " + str(bundle))

    signed = plistlib.loads(subprocess.check_output(
        ["codesign", "--display", "--entitlements", "-", "--xml", str(bundle)],
        stderr=subprocess.DEVNULL,
    ))
    if signed.get("application-identifier") != team + "." + expected_id:
        raise SystemExit("wrong signed application identifier: " + str(bundle))
    if signed.get("com.apple.developer.team-identifier") != team:
        raise SystemExit("wrong signed entitlement team: " + str(bundle))
    debug_allowed = signed.get("get-task-allow", False)
    if phase == "archive-development" and debug_allowed is not True:
        raise SystemExit("development archive does not permit debugging: " + str(bundle))
    if phase == "export-distribution" and debug_allowed:
        raise SystemExit("distribution export permits debugging: " + str(bundle))
    actual_groups = set(signed.get("com.apple.security.application-groups", []))
    if actual_groups != expected_groups:
        raise SystemExit("unexpected App Groups: " + str(bundle))
    keychain_groups = signed.get("keychain-access-groups", [])
    permitted_keychain_groups = {team + ".*", team + "." + expected_id}
    if any(group not in permitted_keychain_groups for group in keychain_groups):
        raise SystemExit("unexpected explicit Keychain groups: " + str(bundle))
    if expected_id == main_id:
        if signed.get("com.apple.developer.healthkit") is not True:
            raise SystemExit("main app is missing HealthKit entitlement")
        if not signed.get("com.apple.developer.nfc.readersession.formats"):
            raise SystemExit("main app is missing NFC reader entitlement")

    profile_path = bundle / "embedded.mobileprovision"
    profile = plistlib.loads(subprocess.check_output(
        ["security", "cms", "-D", "-i", str(profile_path)],
        stderr=subprocess.DEVNULL,
    ))
    if team not in profile.get("TeamIdentifier", []):
        raise SystemExit("wrong provisioning team: " + str(bundle))
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime) or expiration.replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc):
        raise SystemExit("expired or invalid provisioning profile: " + str(bundle))
    allowed = profile.get("Entitlements", {})
    # Without an explicit Keychain group entitlement, Apple uses the app ID
    # as the default group. The provisioning profile must authorize that ID.
    if not keychain_groups and not any(
        permits(team + "." + expected_id, group)
        for group in allowed.get("keychain-access-groups", [])
    ):
        raise SystemExit("profile does not authorize default Keychain group: " + str(bundle))
    for key in ("application-identifier", "com.apple.developer.team-identifier",
                "com.apple.security.application-groups", "keychain-access-groups", "get-task-allow",
                "com.apple.developer.healthkit", "com.apple.developer.nfc.readersession.formats"):
        if key in signed and (key not in allowed or not permits(signed[key], allowed[key])):
            raise SystemExit("profile does not authorize signed entitlement " + key + ": " + str(bundle))

    rows.append({
        "bundleID": expected_id,
        "version": current_version,
        "build": info.get("CFBundleVersion"),
        "team": team,
        "signingPhase": phase,
        "appGroups": sorted(actual_groups),
        "keychainGroups": keychain_groups,
        "effectiveDefaultKeychainGroup": keychain_groups[0] if keychain_groups else team + "." + expected_id,
        "debugAllowed": debug_allowed,
        "profileExpiresAt": expiration.replace(tzinfo=timezone.utc).isoformat(),
        "signatureVerified": True,
    })

subprocess.run(["codesign", "--verify", "--deep", "--strict", str(phone)], check=True)

for stamped in (bundles[0][0], bundles[3][0]):
    with (stamped / "Info.plist").open("rb") as stream:
        if plistlib.load(stream).get("XDripSourceCommit") != os.environ["SOURCE_COMMIT"]:
            raise SystemExit("source commit stamp mismatch: " + str(stamped))

with (bundles[3][0] / "Info.plist").open("rb") as stream:
    watch_info = plistlib.load(stream)
if watch_info.get("WKCompanionAppBundleIdentifier") != main_id:
    raise SystemExit("Watch companion bundle ID mismatch")
if watch_info.get("WKApplication") is not True:
    raise SystemExit("Watch app marker is missing")
if watch_info.get("WKRunsIndependentlyOfCompanionApp") is not False:
    raise SystemExit("unexpected independent Watch app setting")
if "bluetooth-central" not in watch_info.get("UIBackgroundModes", []):
    raise SystemExit("Watch app is missing Bluetooth background mode")
if watch_info.get("WKBackgroundModes") != ["self-care"]:
    raise SystemExit("unexpected Watch extended runtime mode")

destination = Path(os.environ["MANIFEST_PATH"])
destination.write_text(json.dumps({
    "sourceCommit": os.environ["SOURCE_COMMIT"],
    "signingPhase": phase,
    "version": version,
    "build": expected_build,
    "bundles": rows,
}, indent=2), encoding="utf-8")
print(destination)
PY
}

archive_release() {
  local source_commit source_tree staging_source archive_path export_path export_options
  local ipa_count ipa_path unpacked_path exported_phone
  local build_number="${XDRIP_BUILD_NUMBER:-}"

  [ -n "$build_number" ] || die "run release-testflight.py prepare for automatic Apple build selection"
  case "$build_number" in
    *[!0-9]*|'') die "XDRIP_BUILD_NUMBER must be a positive integer" ;;
  esac
  [ "$build_number" -gt 0 ] || die "XDRIP_BUILD_NUMBER must be positive"
  verify_apple_allocation || die "Apple allocation receipt does not match the selected build"
  source_commit="$(verify_release_checkpoint)"
  source_tree="$(git rev-parse 'HEAD^{tree}')"
  release_preflight || die "release preflight is blocked"
  need tar
  need codesign
  need security
  need ditto

  staging_source="$output_root/staging/source"
  archive_path="$output_root/archive/xdrip.xcarchive"
  export_path="$output_root/export"
  export_options="$results_dir/ExportOptions.plist"
  [ ! -e "$staging_source" ] || die "staging source already exists: $staging_source"
  [ ! -e "$archive_path" ] || die "archive already exists: $archive_path"
  [ ! -e "$export_path" ] || die "export path already exists: $export_path"
  mkdir -p "$staging_source" "$(dirname "$archive_path")" "$export_path"

  {
    echo "repository=$repo_root"
    echo "remote=$(git remote get-url origin)"
    echo "branch=$(git branch --show-current)"
    echo "commit=$source_commit"
    echo "tree=$source_tree"
    echo "tag=$XDRIP_RELEASE_TAG"
    echo "marketingVersion=$(sed -n 's/^XDRIP_MARKETING_VERSION = //p' xDrip/Version.xcconfig)"
    echo "buildNumber=$build_number"
    echo "source=git archive of the pushed tag; only ignored signing override added"
  } > "$results_dir/archive-source-state.txt"
  git archive "$XDRIP_RELEASE_TAG" | tar -xf - -C "$staging_source"
  cp "$repo_root/xDripConfigOverride.xcconfig" "$staging_source/xDripConfigOverride.xcconfig"
  STAGING_SOURCE="$staging_source" SOURCE_MANIFEST="$results_dir/archive-staged-files.json" \
    python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path

root = Path(os.environ["STAGING_SOURCE"])
rows = []
for path in sorted(root.rglob("*")):
    relative = path.relative_to(root).as_posix()
    if path.is_symlink():
        rows.append({"path": relative, "symlink": os.readlink(path)})
    elif path.is_file():
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        rows.append({"path": relative, "bytes": path.stat().st_size, "sha256": digest.hexdigest()})
Path(os.environ["SOURCE_MANIFEST"]).write_text(
    json.dumps({"files": rows}, indent=2), encoding="utf-8"
)
PY

  set -o pipefail
  xcodebuild archive \
    -workspace "$staging_source/xdrip.xcworkspace" \
    -scheme xdrip \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$archive_path" \
    -derivedDataPath "$derived_data/archive" \
    "${xcode_auth_args[@]}" \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGN_IDENTITY="Apple Development" \
    DEVELOPMENT_TEAM="$team_id" \
    XDRIP_DEVELOPMENT_TEAM="$team_id" \
    XDRIP_SOURCE_COMMIT="$source_commit" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    2>&1 | tee "$logs_dir/archive.log"

  verify_signed_bundle_tree \
    "$archive_path/Products/Applications/xdrip.app" \
    archive-development "$source_commit" "$build_number" \
    "$results_dir/archive-signed-bundles.json"

  EXPORT_OPTIONS_PATH="$export_options" XDRIP_TEAM_ID="$team_id" python3 - <<'PY'
import os
from pathlib import Path
import plistlib

payload = {
    "destination": "export",
    "manageAppVersionAndBuildNumber": False,
    "method": "app-store-connect",
    "signingStyle": "automatic",
    "teamID": os.environ["XDRIP_TEAM_ID"],
    "testFlightInternalTestingOnly": True,
    "uploadSymbols": True,
}
with Path(os.environ["EXPORT_OPTIONS_PATH"]).open("wb") as stream:
    plistlib.dump(payload, stream, fmt=plistlib.FMT_XML, sort_keys=True)
PY

  set -o pipefail
  xcodebuild -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_path" \
    -exportOptionsPlist "$export_options" \
    "${xcode_auth_args[@]}" \
    2>&1 | tee "$logs_dir/export.log"

  ipa_count="$(find "$export_path" -maxdepth 1 -type f -name '*.ipa' | wc -l | tr -d ' ')"
  [ "$ipa_count" -eq 1 ] || die "expected one exported IPA, found $ipa_count"
  ipa_path="$(find "$export_path" -maxdepth 1 -type f -name '*.ipa' -print)"
  unpacked_path="$output_root/export-verification"
  mkdir -p "$unpacked_path"
  ditto -x -k "$ipa_path" "$unpacked_path"
  exported_phone="$unpacked_path/Payload/xdrip.app"
  [ -d "$exported_phone" ] || die "exported IPA does not contain Payload/xdrip.app"

  verify_signed_bundle_tree \
    "$exported_phone" export-distribution "$source_commit" "$build_number" \
    "$results_dir/export-signed-bundles.json"

  echo "Verified development-signed archive: $archive_path"
  echo "Verified cloud-signed local export: $ipa_path"
  echo "No upload was performed."
}

ensure_tools
ensure_identity_override

case "${1:-}" in
  status) show_status ;;
  python) run_python_checks ;;
  test-ci) run_ci_tests ;;
  test-all) run_all_tests ;;
  build) build_simulators ;;
  all)
    run_python_checks
    run_ci_tests
    build_simulators
    ;;
  release-test)
    run_python_checks
    run_all_tests
    python3 -B scripts/record-watch-test-results.py \
      "$results_dir/AllTests.xcresult" "$results_dir/stability-summary.json" \
      --include-verify-only 2>&1 | tee "$logs_dir/record-xctest-results.log"
    build_simulators
    ;;
  release-preflight) release_preflight ;;
  archive) archive_release ;;
  verify-signed)
    [ -d "${XDRIP_APP_PATH:-}" ] || die "set XDRIP_APP_PATH to an existing xdrip.app"
    [ -n "${XDRIP_SIGNING_PHASE:-}" ] || die "set XDRIP_SIGNING_PHASE"
    [ -n "${XDRIP_BUILD_NUMBER:-}" ] || die "set XDRIP_BUILD_NUMBER"
    verify_signed_bundle_tree "$XDRIP_APP_PATH" "$XDRIP_SIGNING_PHASE" \
      "${XDRIP_SOURCE_COMMIT:-$(git rev-parse HEAD)}" "$XDRIP_BUILD_NUMBER" \
      "$results_dir/${XDRIP_SIGNING_PHASE}-signed-bundles.json"
    ;;
  -h|--help|help|'') usage ;;
  *) usage >&2; die "unknown command: $1" ;;
esac

echo "Artifacts: $output_root"
