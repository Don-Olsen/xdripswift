"""Validate own archive; output selected entitlements, never certificates/full profiles.
Apple allowlists and trailing wildcards: developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
"""
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

KEYS = ('application-identifier', 'com.apple.developer.team-identifier',
        'com.apple.security.application-groups', 'keychain-access-groups', 'get-task-allow',
        'com.apple.developer.bluetooth-central-background')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def allowed(claim, permission):
    """Exact claims or one profile suffix wildcard; arrays are permitted subsets."""
    if isinstance(claim, str):
        if not isinstance(permission, str) or '*' in claim:
            return False
        if '*' not in permission:
            return claim == permission
        return permission.count('*') == 1 and permission.endswith('*') and claim.startswith(permission[:-1])
    if isinstance(claim, list):
        return isinstance(permission, list) and all(any(allowed(item, candidate) for candidate in permission) for item in claim)
    if isinstance(claim, dict):
        return isinstance(permission, dict) and all(key in permission and allowed(value, permission[key]) for key, value in claim.items())
    return type(claim) is type(permission) and claim == permission


def utc(value):
    require(isinstance(value, datetime), 'Invalid provisioning expiration timestamp')
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def verify_profile(signed, profile, team, now):
    approved = profile.get('Entitlements')
    require(isinstance(approved, dict), 'Missing profile entitlement allowlist')
    require(team in profile.get('TeamIdentifier', []), 'Unexpected provisioning team')
    expires = utc(profile.get('ExpirationDate'))
    require(expires > utc(now), 'Provisioning profile expired')
    verified = []
    for key in KEYS:
        if key in signed:
            require(key in approved and allowed(signed[key], approved[key]),
                    'Signed entitlement not authorized by embedded profile: ' + key)
            verified.append(key)
    return approved, expires, verified


def main(archive, destination):
    team, main_id = os.environ['XDRIP_TEAM_ID'], os.environ['XDRIP_MAIN_BUNDLE_ID']
    sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    phone = archive / 'Products/Applications/xdrip.app'
    watch = phone / 'Watch/xDrip Watch App.app'
    require(phone.is_dir() and watch.is_dir(), 'Missing phone or embedded Watch app')
    now = datetime.now(timezone.utc)
    manifest = {'sourceCommit': sha, 'codemagicBuildID': os.environ.get('CM_BUILD_ID'),
                'verifiedAt': now.isoformat(),
                'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
                'scope': 'Own archive before IPA export; selected allowlist check only, not Apple distribution validation or capability eligibility.',
                'applications': []}
    for app, bundle_id in [(phone, main_id), (watch, main_id + '.watchkitapp')]:
        with (app / 'Info.plist').open('rb') as stream:
            info = plistlib.load(stream)
        require(info['CFBundleIdentifier'] == bundle_id, 'Unexpected bundle ID')
        require(info['XDripSourceCommit'] == sha, 'Archive SHA differs from tested checkout')
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        signed = plistlib.loads(subprocess.check_output(
            ['codesign', '--display', '--entitlements', '-', '--xml', str(app)], stderr=subprocess.PIPE))
        require(signed.get('com.apple.developer.team-identifier') == team, 'Unexpected signing team')
        require(signed.get('application-identifier') == team + '.' + bundle_id, 'Unexpected signed App ID')
        require(signed.get('get-task-allow', False) is False, 'Distribution archive permits debugging')
        profile = plistlib.loads(subprocess.check_output(
            ['security', 'cms', '-D', '-i', str(app / 'embedded.mobileprovision')], stderr=subprocess.PIPE))
        approved, expires, verified = verify_profile(signed, profile, team, now)
        manifest['applications'].append({
            'bundleID': bundle_id, 'version': info['CFBundleShortVersionString'],
            'build': info['CFBundleVersion'], 'sourceCommit': info['XDripSourceCommit'],
            'signedEntitlementKeys': sorted(signed),
            'selectedSignedEntitlements': {k: signed[k] for k in KEYS if k in signed},
            'selectedProfileEntitlements': {k: approved[k] for k in KEYS if k in approved},
            'profileAuthorizedSignedKeys': verified, 'profileNotExpired': True,
            'profileExpiresAt': expires.isoformat(),
            'publicBackgroundModes': info.get('UIBackgroundModes', []),
            'extendedRuntimeModes': info.get('WKBackgroundModes', []),
            'codeSignatureVerified': True})
    first, second = manifest['applications']
    require(first['build'] == second['build'], 'Phone/Watch build mismatch')
    require(first['version'] == second['version'], 'Phone/Watch version mismatch')
    require('bluetooth-central' in second['publicBackgroundModes'], 'Missing Watch Bluetooth mode')
    require(second['extendedRuntimeModes'] == ['physical-therapy'], 'Unexpected Watch runtime mode')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    print(json.dumps(manifest, indent=2))


def self_test():
    cases = [
        ('TEAM.app', 'TEAM.app', True), ('TEAM.app', 'TEAM.*', True),
        ('OTHER.app', 'TEAM.*', False), ('TEAM.*', 'TEAM.*', False),
        ('TEAM.app', 'TEAM.*.app', False), ('TEAM.app', 'TEAM.ap?', False),
        (['group.a'], ['group.a', 'group.b'], True),
        (['group.a', 'group.x'], ['group.a'], False),
        (['TEAM.app'], ['TEAM.*'], True), (['group.a'], 'group.*', False),
        (True, 1, False), (False, False, True)]
    for claim, permission, expected in json.loads(json.dumps(cases)):
        require(allowed(claim, permission) is expected, 'Synthetic entitlement fixture failed')
    now = datetime(2026, 9, 12, tzinfo=timezone.utc)
    profile = {'TeamIdentifier': ['TEAM'], 'ExpirationDate': (now + timedelta(days=1)).replace(tzinfo=None),
               'Entitlements': {'application-identifier': 'TEAM.*', 'get-task-allow': False}}
    verify_profile({'application-identifier': 'TEAM.app', 'get-task-allow': False}, profile, 'TEAM', now)
    for invalid in [dict(profile, ExpirationDate=now), dict(profile, ExpirationDate=None),
                    dict(profile, TeamIdentifier=['OTHER']), dict(profile, Entitlements={})]:
        try:
            verify_profile({'application-identifier': 'TEAM.app'}, invalid, 'TEAM', now)
        except ValueError:
            pass
        else:
            raise ValueError('Synthetic profile rejection did not fail')
    print(json.dumps({'verification': 'synthetic local Python fixtures only', 'checksPassed': len(cases) + 5}))


if __name__ == '__main__':
    if sys.argv[1:] == ['--self-test']:
        self_test()
    else:
        require(len(sys.argv) == 3, 'Usage: verify-watch-release.py ARCHIVE MANIFEST or --self-test')
        main(Path(sys.argv[1]), Path(sys.argv[2]))
