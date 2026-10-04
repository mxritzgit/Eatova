"""Device and store builds with a build number that changes on every commit.

  device_build.py run [flutter args]              flutter run --release
  device_build.py ipa|apk|appbundle [flutter args] flutter build <target> --release

Sentry's iOS SDK reports a WatchdogTermination when the previous run ended in
the foreground without a crash while the release (version plus build number)
stayed the same. Reinstalling a build over the running app looks exactly like
that, and pubspec's build number stays the same across many merges: FLUTTER-C
fired on 1.1.0 (2) and 1.1.0 (3) right after such reinstalls. Here the build
number is the commit count of HEAD, which grows with every merge, so each
installed build is its own release and an update is told apart from a kill.

The git-ignored dart_defines.json is passed as for every release build
(docs/DEVELOPMENT.md). FLUTTER names the flutter executable (default: flutter
on PATH; on Windows the full path to flutter.bat).
"""

import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
DEFINES = 'dart_defines.json'
TARGETS = {
    'run': ['run'],
    'ipa': ['build', 'ipa'],
    'apk': ['build', 'apk'],
    'appbundle': ['build', 'appbundle'],
}


def git(*args, runner=subprocess.run):
    """Output of a git command in the repository root."""
    done = runner(['git', *args], cwd=ROOT, capture_output=True, text=True,
                  check=True)
    return done.stdout.strip()


def build_number(runner=subprocess.run):
    """Commit count of HEAD: grows with every merge, never repeats on main."""
    count = int(git('rev-list', '--count', 'HEAD', runner=runner))
    if count <= 0:
        raise ValueError('HEAD has no commits')
    return count


def dirty(runner=subprocess.run):
    """Tracked files with uncommitted changes (the build number is HEAD's)."""
    return bool(git('status', '--porcelain', '--untracked-files=no',
                    runner=runner))


def command(target, number, extra, flutter='flutter'):
    """The flutter invocation for [target] with the given build number."""
    if target not in TARGETS:
        raise KeyError(target)
    return [flutter, *TARGETS[target], '--release',
            f'--dart-define-from-file={DEFINES}', f'--build-number={number}',
            *extra]


def main(argv=None, runner=subprocess.run, call=subprocess.call):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] not in TARGETS:
        print(__doc__.strip(), file=sys.stderr)
        return 64
    target, extra = argv[0], argv[1:]
    if not (ROOT / DEFINES).is_file():
        print(f'{DEFINES} is missing in {ROOT}; a release build needs it '
              '(docs/DEVELOPMENT.md).', file=sys.stderr)
        return 2
    number = build_number(runner)
    if dirty(runner):
        print(f'note: uncommitted changes; build {number} is the number of '
              'HEAD, so reinstalling this tree twice repeats it.',
              file=sys.stderr)
    cmd = command(target, number, extra, os.environ.get('FLUTTER', 'flutter'))
    print('build number', number, file=sys.stderr)
    return call(cmd, cwd=ROOT)


if __name__ == '__main__':
    sys.exit(main())
