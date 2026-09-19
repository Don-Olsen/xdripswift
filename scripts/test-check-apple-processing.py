"""Offline tests of the production observation command; never uses Apple credentials."""
import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    'apple_processing', Path(__file__).with_name('check-apple-processing.py'))
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)


class AppleProcessingCommandTests(unittest.TestCase):
    def read_error(self, diagnostic, expected, returncode=2):
        result = subprocess.CompletedProcess([], returncode, stdout='', stderr=diagnostic)
        with patch.object(observer.subprocess, 'run', return_value=result), \
                patch.object(observer.time, 'monotonic', return_value=100), \
                contextlib.redirect_stdout(io.StringIO()) as stdout, \
                contextlib.redirect_stderr(io.StringIO()) as stderr:
            with self.assertRaises(observer.ObservationError) as caught:
                observer.cli_read(['builds', 'get', 'synthetic-build-id'], 125)
        self.assertEqual(str(caught.exception), expected)
        self.assertEqual(stdout.getvalue(), '')
        self.assertEqual(stderr.getvalue(), '')

    def test_command_uses_positive_supported_retries_and_finite_deadline(self):
        result = subprocess.CompletedProcess([], 0, stdout='[]', stderr='')
        arguments = ['builds', 'list', '--app-id', '123', '--build-version-number', '456',
                     '--pre-release-version', '1.2.3', '--platform', 'IOS']
        with patch.object(observer.subprocess, 'run', return_value=result) as run, \
                patch.object(observer.time, 'monotonic', return_value=100):
            self.assertEqual(observer.cli_read(arguments, 104), [])
        run.assert_called_once_with(
            ['app-store-connect', *arguments, '--json', '--no-color', '--log-stream', 'stderr',
             '--api-unauthorized-retries', '1', '--api-server-error-retries', '1'],
            capture_output=True, text=True, timeout=4)

    def test_command_timeout_is_capped_even_with_long_poll_deadline(self):
        result = subprocess.CompletedProcess([], 0, stdout='{}', stderr='')
        with patch.object(observer.subprocess, 'run', return_value=result) as run, \
                patch.object(observer.time, 'monotonic', return_value=100):
            self.assertEqual(observer.cli_read(['builds', 'get', 'synthetic-build-id'], 1000), {})
        self.assertEqual(run.call_args.kwargs['timeout'], observer.CALL_SECONDS)

    def test_zero_retry_argument_failure_is_not_reported_as_apple_denial(self):
        # v0.69.0's retry argument validators require > 0. Its argparse output
        # contains these auth option names even though Apple was never contacted.
        for flag in ['--api-unauthorized-retries', '--api-server-error-retries']:
            with self.subTest(flag=flag):
                self.read_error(
                    'usage: app-store-connect [--issuer-id ISSUER_ID] [--private-key PRIVATE_KEY]\n'
                    f'app-store-connect: error: argument {flag}: Provided value "0" is not valid\n',
                    'cli_argument_invalid')

    def test_usage_and_invalid_choices_are_classified_before_auth_words(self):
        for diagnostic in [
            'usage: app-store-connect --api-unauthorized-retries N\nerror: unrecognized arguments: --bogus',
            "error: argument --platform: invalid choice: 'UNKNOWN'",
            'error: argument --issuer-id: expected one argument',
        ]:
            with self.subTest(diagnostic=diagnostic):
                self.read_error(diagnostic, 'cli_argument_invalid')

    def test_option_names_alone_do_not_establish_authentication_failure(self):
        self.read_error('failed while preparing --api-unauthorized-retries --private-key --issuer-id',
                        'cli_read_failed', returncode=1)

    def test_actual_http_authentication_failures_remain_classified(self):
        for diagnostic in ['401 Unauthorized', '403 Forbidden', 'Unauthorized', 'Forbidden']:
            with self.subTest(diagnostic=diagnostic):
                self.read_error(diagnostic, 'access_unavailable', returncode=1)

    def test_resource_visibility_and_rate_limits_remain_separate(self):
        self.read_error('404 Not found', 'resource_not_visible', returncode=1)
        self.read_error('429 Too many requests', 'rate_limited', returncode=1)

    def test_generic_failure_does_not_print_unsanitized_diagnostics(self):
        self.read_error('unexpected failure synthetic-sensitive-value-do-not-print',
                        'cli_read_failed', returncode=1)

    def test_invalid_json_is_not_authentication_failure(self):
        result = subprocess.CompletedProcess([], 0, stdout='not json', stderr='')
        with patch.object(observer.subprocess, 'run', return_value=result), \
                patch.object(observer.time, 'monotonic', return_value=100):
            with self.assertRaisesRegex(observer.ObservationError, '^invalid_cli_json$'):
                observer.cli_read(['builds', 'get', 'synthetic-build-id'], 125)

    def test_expired_deadline_never_starts_a_subprocess(self):
        with patch.object(observer.subprocess, 'run') as run, \
                patch.object(observer.time, 'monotonic', return_value=100):
            with self.assertRaisesRegex(observer.ObservationError, '^command_timeout$'):
                observer.cli_read(['builds', 'get', 'synthetic-build-id'], 100)
        run.assert_not_called()

    def test_missing_cli_and_subprocess_timeout_are_distinct(self):
        for failure, expected in [(FileNotFoundError(), 'cli_unavailable'),
                                  (subprocess.TimeoutExpired('app-store-connect', 25), 'command_timeout')]:
            with self.subTest(expected=expected), \
                    patch.object(observer.subprocess, 'run', side_effect=failure), \
                    patch.object(observer.time, 'monotonic', return_value=100):
                with self.assertRaisesRegex(observer.ObservationError, '^' + expected + '$'):
                    observer.cli_read(['builds', 'get', 'synthetic-build-id'], 125)

    def test_invalid_cli_arguments_stop_polling_without_upload_or_sleep(self):
        report = {'appID': '123', 'build': '456', 'version': '1.2.3', 'noUploadRetryRequested': True}
        calls = []

        def read(arguments, deadline):
            calls.append(arguments)
            raise observer.ObservationError('cli_argument_invalid')

        with patch.object(observer.subprocess, 'run') as run, \
                patch.object(observer.time, 'sleep') as sleep:
            observer.poll(report, read=read, now=lambda: 100, sleep=sleep, deadline=125)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][:2], ['builds', 'list'])
        self.assertEqual(report['outcome'], 'observation_unavailable')
        self.assertEqual(report['lastReadIssue'], 'cli_argument_invalid')
        self.assertEqual(report['polls'], 1)
        self.assertTrue(report['noUploadRetryRequested'])
        run.assert_not_called()
        sleep.assert_not_called()


if __name__ == '__main__':
    unittest.main(verbosity=2)
