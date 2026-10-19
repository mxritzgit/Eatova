"""Device and store builds with a build number that changes on every commit.

  device_build.py iphone  -d <device> [--dry-run] [flutter build args]
  device_build.py android [-d <device>] [--dry-run] [flutter build args]
  device_build.py ipa|apk|appbundle [--dry-run] [flutter build args]
  device_build.py build-number

iphone and android build a release with the build number and then install it
over the build on the device, keeping the app's data: Android with
`adb install -r`, iPhone with `xcrun devicectl device install app`.
`flutter install` is not used: Flutter 3.47.2 uninstalls the app first
(`installApp(..., uninstall = true)`), which deletes the unsent outbox, the
encrypted cache, reminders and Health grants, so the real update path (old
cache, new build) never ran on a device. Nothing here uninstalls. An install
the OS refuses (a lower build number, another signing key) fails and leaves
the old build and its data in place; uninstalling is then a manual decision.

`flutter run` accepts no build number. iPhone builds need macOS with Xcode
and the device id from `flutter devices`. ipa, apk and appbundle only build;
appbundle is also the manual Play build (docs/DEVELOPMENT.md). build-number
prints the number. --dry-run prints the commands without running them.

Sentry's iOS SDK reports a WatchdogTermination when the previous run ended in
the foreground without a crash while the release (version plus build number)
stayed the same. Reinstalling a build over the running app looks exactly like
that, and pubspec's build number stays the same across many merges: FLUTTER-C
fired on 1.1.0 (2) and 1.1.0 (3) right after such reinstalls. Here the build
number is the commit count of HEAD, which grows with every merge, so each
installed build is its own release and an update is told apart from a kill.

The git-ignored dart_defines.json is passed as for every release build
(docs/DEVELOPMENT.md). FLUTTER names the flutter executable (default: flutter
on PATH; on Windows the full path to flutter.bat). ADB names adb (default:
platform-tools of ANDROID_HOME or ANDROID_SDK_ROOT, else adb on PATH).
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
# What `flutter build apk|ios --release` writes, relative to ROOT.
APK = 'build/app/outputs/flutter-apk/app-release.apk'
IOS_APP = 'build/ios/iphoneos/Runner.app'
# Build flags that rename or split the APK the install step expects.
APK_LAYOUT_FLAGS = ('--split-per-abi', '--flavor')


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


def adb_executable(environ, is_file=os.path.isfile):
    """ADB, else the SDK's platform-tools adb, else adb on PATH."""
    if environ.get('ADB'):
        return environ['ADB']
    name = 'adb.exe' if os.name == 'nt' else 'adb'
    for variable in ('ANDROID_HOME', 'ANDROID_SDK_ROOT'):
        sdk = environ.get(variable)
        if sdk and is_file(os.path.join(sdk, 'platform-tools', name)):
            return os.path.join(sdk, 'platform-tools', name)
    return 'adb'


def install_command(target, device, adb='adb'):
    """Installs the fresh build over the old one; never uninstalls first."""
    if target == 'android':
        # -r replaces the app and keeps its data; -s picks the device.
        return [adb, *(['-s', device] if device else []), 'install', '-r', APK]
    if device is None:
        raise ValueError('iphone needs -d <device id> (see `flutter devices`)')
    # devicectl updates an installed app in place, data container included.
    return ['xcrun', 'devicectl', 'device', 'install', 'app',
            '--device', device, IOS_APP]


def commands(target, number, extra, flutter='flutter', adb='adb'):
    """The invocations for [target]: the build, then the install."""
    if target not in TARGETS:
        raise KeyError(target)
    subcommand, installs = TARGETS[target]
    rest, device = split_device(extra) if installs else (list(extra), None)
    if target == 'android':
        moved = [arg for arg in rest
                 if arg.split('=', 1)[0] in APK_LAYOUT_FLAGS]
        if moved:
            raise ValueError(f'{moved[0]} changes the APK path; the install '
                             f'needs the single {APK}')
    build = [flutter, 'build', subcommand, '--release',
             f'--dart-define-from-file={DEFINES}', f'--build-number={number}',
             *rest]
    if not installs:
        return [build]
    return [build, install_command(target, device, adb)]


def main(argv=None, runner=subprocess.run, call=subprocess.call,
         platform=sys.platform, environ=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    environ = os.environ if environ is None else environ
    if argv == ['build-number']:
        print(build_number(runner))
        return 0
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
                         environ.get('FLUTTER', 'flutter'),
                         adb_executable(environ))
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
