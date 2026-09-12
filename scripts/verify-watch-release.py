"""Validate our own signed archive; emit a small manifest, never certificate/profile data."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

archive = Path(sys.argv[1])
destination = Path(sys.argv[2])
team = os.environ['XDRIP_TEAM_ID']
main_id = os.environ['XDRIP_MAIN_BUNDLE_ID']
sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
main = archive / 'Products/Applications/xdrip.app'
watch = main / 'Watch/xDrip Watch App.app'
assert main.is_dir() and watch.is_dir(), 'Missing phone or embedded Watch app'
selected_keys = ['application-identifier', 'com.apple.developer.team-identifier',
                 'com.apple.security.application-groups', 'get-task-allow',
                 'com.apple.developer.bluetooth-central-background']
manifest = {'sourceCommit': sha, 'codemagicBuildID': os.environ.get('CM_BUILD_ID'),
            'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
            'scope': 'Our own archive only; capability absence is not an Apple eligibility decision.',
            'applications': []}
for app, bundle_id in [(main, main_id), (watch, main_id + '.watchkitapp')]:
    with (app / 'Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    assert info['CFBundleIdentifier'] == bundle_id, 'Unexpected bundle ID'
    assert info['XDripSourceCommit'] == sha, 'Archived source stamp differs from tested checkout'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    signed = plistlib.loads(subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(app)], stderr=subprocess.PIPE))
    assert signed.get('com.apple.developer.team-identifier') == team, 'Unexpected signing team'
    assert signed.get('application-identifier') == team + '.' + bundle_id, 'Unexpected signed App ID'
    assert signed.get('get-task-allow', False) is False, 'Distribution archive permits debugging'
    profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(app / 'embedded.mobileprovision')], stderr=subprocess.PIPE))
    approved = profile.get('Entitlements', {})
    assert team in profile.get('TeamIdentifier', []), 'Unexpected provisioning team'
    row = {'bundleID': bundle_id, 'version': info['CFBundleShortVersionString'],
           'build': info['CFBundleVersion'], 'sourceCommit': info['XDripSourceCommit'],
           'signedEntitlementKeys': sorted(signed),
           'selectedSignedEntitlements': {k: signed[k] for k in selected_keys if k in signed},
           'selectedProfileEntitlements': {k: approved[k] for k in selected_keys if k in approved},
           'profileExpiresAt': profile['ExpirationDate'].isoformat(),
           'publicBackgroundModes': info.get('UIBackgroundModes', []),
           'extendedRuntimeModes': info.get('WKBackgroundModes', []),
           'codeSignatureVerified': True}
    manifest['applications'].append(row)
assert manifest['applications'][0]['build'] == manifest['applications'][1]['build'], 'Phone/Watch build mismatch'
assert manifest['applications'][0]['version'] == manifest['applications'][1]['version'], 'Phone/Watch version mismatch'
assert 'bluetooth-central' in manifest['applications'][1]['publicBackgroundModes']
assert manifest['applications'][1]['extendedRuntimeModes'] == ['self-care']
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(manifest, indent=2), encoding='utf-8')
print(json.dumps(manifest, indent=2))
