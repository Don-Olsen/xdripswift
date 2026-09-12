"""Read-only post-upload observation. Pending/unavailable never requests re-upload."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

WAIT_SECONDS = 900
POLL_SECONDS = 30
CALL_SECONDS = 25


class ObservationError(Exception):
    pass


def require(condition):
    if not condition:
        raise ObservationError('identity_or_response_mismatch')


def cli_preflight(report, deadline):
    """Record installed CLI support without credentials or raw help/error output."""
    required = {
        'list': ['--app-id', '--build-version-number', '--pre-release-version', '--platform'],
        'get': [],
        'app': [],
        'pre-release-version': [],
        'beta-details': [],
    }
    common = ['--json', '--no-color', '--log-stream', '--api-unauthorized-retries',
              '--api-server-error-retries']
    report['cliHelpChecks'] = {}
    commands = [(['--version'], None)] + [(['builds', action, '--help'], action) for action in required]
    for arguments, action in commands:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ObservationError('command_timeout')
        try:
            result = subprocess.run(['app-store-connect', *arguments], capture_output=True,
                                    text=True, timeout=min(CALL_SECONDS, remaining))
        except FileNotFoundError:
            raise ObservationError('cli_unavailable') from None
        except subprocess.TimeoutExpired:
            raise ObservationError('command_timeout') from None
        if result.returncode:
            raise ObservationError('cli_command_unsupported')
        output = result.stdout + result.stderr
        if action is None:
            version = re.search(r'\b\d+\.\d+\.\d+(?:[a-zA-Z0-9.+-]*)?', output)
            report['cliVersion'] = version.group() if version else 'unrecognized'
        else:
            supported = all(argument in output for argument in required[action] + common)
            report['cliHelpChecks']['builds ' + action] = supported
            if not supported:
                raise ObservationError('cli_command_unsupported')
    print('APPLE_BUILD_CLI_PREFLIGHT ' + json.dumps({
        'cliVersion': report['cliVersion'], 'helpChecks': report['cliHelpChecks']}, sort_keys=True), flush=True)


def cli_read(arguments, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ObservationError('command_timeout')
    try:
        result = subprocess.run(
            ['app-store-connect', *arguments, '--json', '--no-color',
             '--log-stream', 'stderr', '--api-unauthorized-retries', '0',
             '--api-server-error-retries', '0'],
            capture_output=True, text=True, timeout=min(CALL_SECONDS, remaining))
    except FileNotFoundError:
        raise ObservationError('cli_unavailable') from None
    except subprocess.TimeoutExpired:
        raise ObservationError('command_timeout') from None
    if result.returncode:
        # Inspect locally for a fixed classification; never print CLI error bodies.
        diagnostic = (result.stderr + result.stdout).lower()
        if re.search(r'\b(401|403)\b|unauthorized|forbidden|private.key|issuer.id|key.identifier', diagnostic):
            raise ObservationError('access_unavailable')
        if re.search(r'\b404\b|not found', diagnostic):
            raise ObservationError('resource_not_visible')
        if re.search(r'\b429\b|too many requests', diagnostic):
            raise ObservationError('rate_limited')
        raise ObservationError('cli_read_failed')
    try:
        return json.loads(result.stdout)
    except ValueError:
        raise ObservationError('invalid_cli_json') from None


def archive_identity(path):
    manifest = json.loads(path.read_text(encoding='utf-8'))
    main_id = os.environ['XDRIP_MAIN_BUNDLE_ID']
    app_id = str(os.environ['APP_STORE_APPLE_ID'])
    sha = manifest['sourceCommit']
    require(bool(re.fullmatch(r'[0-9a-f]{40}', sha)))
    require(manifest['codemagicBuildID'] == os.environ['CM_BUILD_ID'])
    checkout = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True, timeout=10).strip()
    require(sha == checkout)
    applications = manifest['applications']
    require(len(applications) == 2)
    by_id = {app['bundleID']: app for app in applications}
    require(set(by_id) == {main_id, main_id + '.watchkitapp'})
    phone, watch = by_id[main_id], by_id[main_id + '.watchkitapp']
    for app in (phone, watch):
        require(app['codeSignatureVerified'] is True and app['sourceCommit'] == sha)
        require(app['profileNotExpired'] is True)
    require(phone['version'] == watch['version'] and phone['build'] == watch['build'])
    require(bool(re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', str(phone['version']))))
    require(bool(re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,3}', str(phone['build']))))
    require(bool(re.fullmatch(r'[0-9]+', app_id)))
    return {'appID': app_id, 'bundleID': main_id, 'version': str(phone['version']),
            'build': str(phone['build']), 'sourceCommit': sha,
            'codemagicBuildID': manifest['codemagicBuildID']}


def poll(report, read=cli_read, now=time.monotonic, sleep=time.sleep, deadline=None):
    if deadline is None:
        deadline = now() + WAIT_SECONDS
    report.update(outcome='pending', polls=0, groupAssignment='not_queried',
                  deviceInstallation='not_tested', maximumWaitSeconds=WAIT_SECONDS,
                  uploadConfirmation='see_separate_Codemagic_upload_log')
    identity_verified = False
    while now() < deadline:
        report['polls'] += 1
        try:
            if 'appleBuildID' not in report:
                matches = read(['builds', 'list', '--app-id', report['appID'],
                    '--build-version-number', report['build'],
                    '--pre-release-version', report['version'], '--platform', 'IOS'], deadline)
                require(isinstance(matches, list) and len(matches) <= 1)
                if not matches:
                    raise ObservationError('resource_not_visible')
                report['appleBuildID'] = matches[0]['id']
            build_id = report['appleBuildID']
            build = read(['builds', 'get', build_id], deadline)
            require(build['id'] == build_id and str(build['attributes']['version']) == report['build'])
            if not identity_verified:
                app = read(['builds', 'app', build_id], deadline)
                version = read(['builds', 'pre-release-version', build_id], deadline)
                require(app['id'] == report['appID'] and app['attributes']['bundleId'] == report['bundleID'])
                require(version['attributes']['version'] == report['version'])
                require(version['attributes']['platform'] == 'IOS')
                identity_verified = True
            attributes = build['attributes']
            state = attributes['processingState']
            report.update(processingState=state, uploadedDate=attributes.get('uploadedDate'),
                          expired=attributes.get('expired'), expirationDate=attributes.get('expirationDate'))
            if state in ('FAILED', 'INVALID'):
                report['outcome'] = 'apple_processing_failed'
                break
            if state == 'VALID':
                detail = read(['builds', 'beta-details', build_id], deadline)['attributes']
                internal = detail['internalBuildState']
                report.update(internalBuildState=internal, externalBuildState=detail['externalBuildState'])
                if internal in ('READY_FOR_BETA_TESTING', 'IN_BETA_TESTING') and attributes.get('expired') is False:
                    report['outcome'] = 'internal_state_ready_group_and_device_unverified'
                    break
                if internal != 'PROCESSING':
                    report['outcome'] = 'internal_state_requires_attention'
                    break
            elif state != 'PROCESSING':
                report['outcome'] = 'unknown_apple_processing_state'
                break
            report.pop('lastReadIssue', None)
        except ObservationError as error:
            report['lastReadIssue'] = str(error)
            if str(error) in ('access_unavailable', 'cli_unavailable', 'invalid_cli_json',
                              'identity_or_response_mismatch'):
                report['outcome'] = 'observation_unavailable'
                break
        except (KeyError, TypeError, ValueError):
            report.update(outcome='observation_unavailable', lastReadIssue='unexpected_response_schema')
            break
        remaining = deadline - now()
        if remaining > 0:
            sleep(min(POLL_SECONDS, remaining))
    return report


def main():
    report = {'outcome': 'observation_unavailable', 'noUploadRetryRequested': True}
    destination = Path(sys.argv[2])
    try:
        report.update(archive_identity(Path(sys.argv[1])))
        deadline = time.monotonic() + WAIT_SECONDS
        cli_preflight(report, deadline)
        poll(report, deadline=deadline)
    except ObservationError as error:
        report['lastReadIssue'] = str(error)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        report['lastReadIssue'] = 'missing_or_invalid_archive_identity'
    report['observedAt'] = datetime.now(timezone.utc).isoformat()
    serialized = json.dumps(report, sort_keys=True)
    # A post-publish log is durable evidence even if artifact collection already ran.
    print('APPLE_BUILD_OBSERVATION ' + serialized, flush=True)
    try:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(serialized + '\n', encoding='utf-8')
    except OSError:
        print('APPLE_BUILD_OBSERVATION_FILE_UNAVAILABLE', flush=True)
    # Pending/access errors are explicitly inconclusive; they do not request a new upload.
    return 2 if report['outcome'] == 'apple_processing_failed' else 0


if __name__ == '__main__':
    sys.exit(main())
