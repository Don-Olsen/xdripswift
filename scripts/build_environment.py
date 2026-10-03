#!/usr/bin/env python3
"""Read-only preflight for local Xcode input/output locations and disk space."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

MIN_FREE_BYTES = 10 * 1024 ** 3

class EnvironmentBlocked(RuntimeError):
    pass


def existing_parent(path):
    path = Path(path).expanduser().resolve()
    for candidate in (path, *path.parents):
        if candidate.exists():
            if not candidate.is_dir():
                raise EnvironmentBlocked('Build location is not a directory: ' + str(candidate))
            return candidate
    raise EnvironmentBlocked('Cannot inspect build location: ' + str(path))


def attributes(path):
    try:
        result = subprocess.run(['/usr/bin/xattr', str(path)], capture_output=True,
                                text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise EnvironmentBlocked('Cannot verify local filesystem: ' + str(path)) from error
    if result.returncode:
        raise EnvironmentBlocked('Cannot verify local filesystem: ' + str(path))
    return result.stdout.splitlines()


def check_environment(repo, output, derived_data):
    checked = set()
    free_by_location = {}
    for label, value in (('source', repo), ('output', output), ('DerivedData', derived_data)):
        nearest = existing_parent(value)
        for path in (nearest, *nearest.parents):
            if path in checked:
                continue
            checked.add(path)
            if any(name.startswith(('com.apple.fileprovider.', 'com.apple.file-provider-'))
                   for name in attributes(path)):
                raise EnvironmentBlocked(
                    'Xcode ' + label + ' is in a File Provider folder: ' + str(path) +
                    '. Use the local checkout documented in docs/MAC-BUILD.md; no build started.')
        try:
            free = shutil.disk_usage(nearest).free
        except OSError as error:
            raise EnvironmentBlocked('Cannot measure free disk space: ' + str(nearest)) from error
        free_by_location[label] = free
        if free < MIN_FREE_BYTES:
            raise EnvironmentBlocked(
                '%s has %.2f GiB free; at least 10 GiB is required before Xcode starts. '
                'Run the verified cleanup process first; protected releases must be kept.'
                % (label, free / 1024 ** 3))
    return free_by_location


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('repo', 'output', 'derived-data'):
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    try:
        free = check_environment(args.repo, args.output, args.derived_data)
    except EnvironmentBlocked as error:
        parser.exit(1, 'Build preflight blocked: ' + str(error) + '\n')
    print('Build preflight: local filesystem verified; minimum free space %.2f GiB.'
          % (min(free.values()) / 1024 ** 3))

if __name__ == '__main__':
    main()
