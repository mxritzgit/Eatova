"""Device and store builds with a build number that changes on every commit.

  device_build.py iphone  [-d <device>] [--dry-run] [flutter build args]
  device_build.py android [-d <device>] [--dry-run] [flutter build args]
  device_build.py ipa|apk|appbundle [--dry-run] [flutter build args]

iphone and android build a release with the build number and then install it
on the attached device (`flutter install`); `flutter run` accepts no build
number. iPhone builds need macOS with Xcode. ipa, apk and appbundle only
build. --dry-run prints the flutter commands without running them.

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
# target: (flutter build subcommand, installs on a device afterwards)
TARGETS = {
    'iphone': ('ios', True),
    'android': ('apk', True),
    'ipa': ('ipa', False),
    'apk': ('apk', False),
    'appbundle': ('appbundle', False),
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


def split_device(extra):
    """Pulls `-d <id>` / `--device-id <id>` out of [extra] for the install."""
    rest, device = [], None
    args = iter(extra)
    for arg in args:
        if arg in ('-d', '--device-id'):
            device = next(args, None)
            if device is None:
                raise ValueError(f'{arg} needs a device id')
        elif arg.startswith('--device-id='):
            device = arg.split('=', 1)[1]
        else:
            rest.append(arg)
    return rest, device


def commands(target, number, extra, flutter='flutter'):
    """The flutter invocations for [target]: the build, then the install."""
    if target not in TARGETS:
        raise KeyError(target)
    subcommand, installs = TARGETS[target]
    rest, device = split_device(extra) if installs else (list(extra), None)
    build = [flutter, 'build', subcommand, '--release',
             f'--dart-define-from-file={DEFINES}', f'--build-number={number}',
             *rest]
    if not installs:
        return [build]
    install = [flutter, 'install', '--release']
    if device is not None:
        install += ['-d', device]
    return [build, install]


def main(argv=None, runner=subprocess.run, call=subprocess.call,
         platform=sys.platform):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] not in TARGETS:
        print(__doc__.strip(), file=sys.stderr)
        return 64
    target, extra = argv[0], argv[1:]
    dry_run = '--dry-run' in extra
    extra = [arg for arg in extra if arg != '--dry-run']
    if target in ('iphone', 'ipa') and platform != 'darwin' and not dry_run:
        print('iPhone builds need macOS with Xcode; run this on the Mac.',
              file=sys.stderr)
        return 2
    if not (ROOT / DEFINES).is_file():
        print(f'{DEFINES} is missing in {ROOT}; a release build needs it '
              '(docs/DEVELOPMENT.md).', file=sys.stderr)
        return 2
    number = build_number(runner)
    if dirty(runner):
        print(f'note: uncommitted changes; build {number} is the number of '
              'HEAD, so reinstalling this tree twice repeats it.',
              file=sys.stderr)
    try:
        steps = commands(target, number, extra,
                         os.environ.get('FLUTTER', 'flutter'))
    except ValueError as error:
        print(error, file=sys.stderr)
        return 64
    print('build number', number, file=sys.stderr)
    for step in steps:
        if dry_run:
            print(' '.join(step))
            continue
        code = call(step, cwd=ROOT)
        if code != 0:
            return code
    return 0


if __name__ == '__main__':
    sys.exit(main())
