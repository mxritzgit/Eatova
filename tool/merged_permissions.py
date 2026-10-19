"""Compare the merged release manifest's permissions with the reviewed allowlist.

  merged_permissions.py --manifest-dir build/app/intermediates/merged_manifests/release
                        [--allowlist android/permissions_allowlist.txt]

Plugins add permissions in the manifest merge (workmanager, androidx.core), so
the source manifest alone does not say what the shipped app requests, and
Play's Data Safety form must match the shipped app. Every `uses-permission`
and `uses-permission-sdk-23` of the merged manifest must be listed, and every
listed permission must still be requested: both directions fail, so the list,
the form and the build change together. Exit 0 on a match, 1 on a difference,
2 when the manifest or the list cannot be read.
"""

import argparse
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ALLOWLIST = ROOT / 'android' / 'permissions_allowlist.txt'
ANDROID = '{http://schemas.android.com/apk/res/android}'
TOOLS = '{http://schemas.android.com/tools}'
PERMISSION = re.compile(r'[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+')
TAGS = ('uses-permission', 'uses-permission-sdk-23')


class ManifestError(Exception):
    """A manifest or list that cannot be read."""


def read_allowlist(text):
    """Permission names, one per line; `#` starts a comment."""
    names = []
    for number, line in enumerate(text.splitlines(), 1):
        entry = line.split('#', 1)[0].strip()
        if not entry:
            continue
        if not PERMISSION.fullmatch(entry):
            raise ManifestError(f'allowlist line {number} is not a permission name')
        if entry in names:
            raise ManifestError(f'allowlist line {number} repeats {entry}')
        names.append(entry)
    if not names:
        raise ManifestError('allowlist is empty')
    return set(names)


def _parse(text):
    try:
        return ET.fromstring(text)
    except ET.ParseError:
        raise ManifestError('manifest is not XML') from None


def manifest_permissions(text):
    """Requested permission names, without entries a manifest removes."""
    root = _parse(text)
    names = set()
    for tag in TAGS:
        for element in root.iter(tag):
            name = element.get(ANDROID + 'name')
            if not name:
                raise ManifestError(tag + ' without android:name')
            if element.get(TOOLS + 'node') == 'remove':
                continue
            names.add(name)
    return names


def removed_permissions(text):
    """Permissions a source manifest strips from the merge (tools:node=remove)."""
    root = _parse(text)
    return {element.get(ANDROID + 'name') for tag in TAGS for element in root.iter(tag)
            if element.get(TOOLS + 'node') == 'remove'}


def find_manifest(directory):
    found = sorted(Path(directory).rglob('AndroidManifest.xml'))
    if len(found) != 1:
        raise ManifestError(f'expected one merged AndroidManifest.xml under {directory}, found {len(found)}')
    return found[0]


def compare(requested, allowed):
    return {'unlisted': sorted(requested - allowed), 'no_longer_requested': sorted(allowed - requested)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--manifest-dir', required=True)
    parser.add_argument('--allowlist', default=str(ALLOWLIST))
    args = parser.parse_args(argv)
    try:
        manifest = find_manifest(args.manifest_dir)
        requested = manifest_permissions(manifest.read_text(encoding='utf-8'))
        allowed = read_allowlist(Path(args.allowlist).read_text(encoding='utf-8'))
    except (OSError, ManifestError) as error:
        print('::error::merged permissions: ' + str(error), file=sys.stderr)
        return 2
    difference = compare(requested, allowed)
    for name in difference['unlisted']:
        print(f'::error::{name} is requested by the merged release manifest but not in '
              'android/permissions_allowlist.txt: remove it in the source manifest (tools:node="remove") '
              'or list it and update the Play Data Safety form', file=sys.stderr)
    for name in difference['no_longer_requested']:
        print(f'::error::{name} is listed in android/permissions_allowlist.txt but no longer requested: '
              'drop it from the list and the Play Data Safety form', file=sys.stderr)
    if difference['unlisted'] or difference['no_longer_requested']:
        return 1
    print(f'Merged release manifest requests exactly the {len(allowed)} listed permissions.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
