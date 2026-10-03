// WIRING GUARD — the iOS privacy manifest against the Runner's own code.
//
// App Store Connect rejects an upload (ITMS-91053) whose binary calls a
// required-reason API that ios/Runner/PrivacyInfo.xcprivacy does not declare.
// Device builds still work, and CI only checks that the manifest lands in the
// bundle, so a `systemUptime` in AppDelegate.swift went unnoticed (review F1,
// 2026-10-03). This guard maps the API symbols to Apple's categories and
// requires every category the Runner code uses to be declared. Pods ship
// their own manifests and are out of scope.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _manifestPath = 'ios/Runner/PrivacyInfo.xcprivacy';
const String _runnerDir = 'ios/Runner';

/// Apple's required-reason API categories and the symbols that fall under
/// them (the list the manifest's comment greps for). Matched as identifier
/// prefixes, so `volumeAvailableCapacityKey` counts too.
const Map<String, List<String>> _categories = {
  'NSPrivacyAccessedAPICategorySystemBootTime': [
    'systemUptime',
    'mach_absolute_time',
  ],
  'NSPrivacyAccessedAPICategoryUserDefaults': [
    'UserDefaults',
    'NSUserDefaults',
  ],
  'NSPrivacyAccessedAPICategoryFileTimestamp': [
    'creationDate',
    'modificationDate',
    'fileModificationDate',
    'contentModificationDate',
    'getattrlist',
  ],
  'NSPrivacyAccessedAPICategoryDiskSpace': [
    'statfs',
    'statvfs',
    'volumeAvailableCapacity',
    'systemFreeSize',
    'systemSize',
  ],
  'NSPrivacyAccessedAPICategoryActiveKeyboards': ['activeInputModes'],
};

final RegExp _blockComment = RegExp(r'/\*.*?\*/', dotAll: true);
final RegExp _lineComment = RegExp(r'//[^\n]*');
final RegExp _xmlComment = RegExp(r'<!--.*?-->', dotAll: true);
final RegExp _declaredType = RegExp(
  r'<key>NSPrivacyAccessedAPIType</key>\s*<string>([^<]+)</string>',
);

/// The categories [source] (Swift or Objective-C) uses outside comments.
Set<String> _usedCategories(String source) {
  final code = source
      .replaceAll(_blockComment, '')
      .replaceAll(_lineComment, '');
  return {
    for (final MapEntry(key: category, value: symbols) in _categories.entries)
      if (symbols.any((s) => RegExp('\\b${RegExp.escape(s)}').hasMatch(code)))
        category,
  };
}

/// The categories the manifest declares under NSPrivacyAccessedAPITypes.
Set<String> _declaredCategories(String manifest) => {
  for (final match in _declaredType.allMatches(
    manifest.replaceAll(_xmlComment, ''),
  ))
    match.group(1)!.trim(),
};

/// Every native source file compiled into the Runner target.
List<File> _runnerSources() =>
    Directory(_runnerDir)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => RegExp(r'\.(swift|m|mm|h)$').hasMatch(f.path))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

void main() {
  test('the guard reads the Runner sources and the manifest', () {
    final names = _runnerSources().map((f) => f.uri.pathSegments.last).toList();
    expect(names, contains('AppDelegate.swift'));
    expect(File(_manifestPath).existsSync(), isTrue);
  });

  test('the detector catches the old boot-time read and skips comments', () {
    expect(
      _usedCategories(
        'recordingStartedAt = ProcessInfo.processInfo.systemUptime',
      ),
      {'NSPrivacyAccessedAPICategorySystemBootTime'},
    );
    expect(
      _usedCategories(
        '/// `systemUptime` once.\n/* UserDefaults */\n'
        'let start = Date()\nlet s = Date().timeIntervalSince(start)',
      ),
      isEmpty,
    );
    expect(
      _declaredCategories(
        '<!-- <key>NSPrivacyAccessedAPIType</key>'
        '<string>NSPrivacyAccessedAPICategoryDiskSpace</string> -->'
        '<key>NSPrivacyAccessedAPIType</key>\n\t\t\t'
        '<string>NSPrivacyAccessedAPICategorySystemBootTime</string>',
      ),
      {'NSPrivacyAccessedAPICategorySystemBootTime'},
    );
  });

  test('every required-reason API in Runner is declared in the manifest', () {
    final declared = _declaredCategories(
      File(_manifestPath).readAsStringSync(),
    );
    final undeclared = <String>[
      for (final file in _runnerSources())
        for (final category in _usedCategories(file.readAsStringSync()))
          if (!declared.contains(category))
            '${file.uri.pathSegments.last}: $category',
    ];
    expect(
      undeclared,
      isEmpty,
      reason:
          'Declare the category with a reason in $_manifestPath or avoid the '
          'API; App Store Connect rejects the upload otherwise (ITMS-91053).',
    );
  });
}
