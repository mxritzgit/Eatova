// WIRING GUARD for the iOS snapshot cover (EatovaSecureScreenPlugin in
// ios/Runner/AppDelegate.swift). Swift does not run in `flutter test`, so this
// reads the source: the cover must paint the page tone Dart reports over
// `setCoverColor` (SecureScreenCoverColor, the theme's AppTokens.bg). A fixed
// near-black cover turned the light app into a dark slab on every system
// alert and in the app switcher. The look itself needs a device.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _appDelegatePath = 'ios/Runner/AppDelegate.swift';

/// Swift source without comments, so a comment naming an API does not count
/// as a use.
String _withoutCodeComments(String source) => source
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .split('\n')
    .map((line) {
      final i = line.indexOf('//');
      return i < 0 ? line : line.substring(0, i);
    })
    .join('\n');

/// The body of the declaration that starts with [header], braces balanced.
String _body(String source, String header) {
  final start = source.indexOf(header);
  if (start < 0) fail('`$header` missing');
  final open = source.indexOf('{', start);
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) {
      return source.substring(open + 1, i);
    }
  }
  fail('`$header`: unbalanced braces');
}

void main() {
  late String plugin;

  setUpAll(() {
    final file = File(_appDelegatePath);
    if (!file.existsSync()) fail('$_appDelegatePath missing');
    plugin = _body(
      _withoutCodeComments(file.readAsStringSync()),
      'final class EatovaSecureScreenPlugin',
    );
  });

  test('setCoverColor stores the ARGB page tone Dart reports', () {
    final handle = _body(plugin, 'public func handle(');
    final setter = RegExp(
      r'case "setCoverColor":(.*?)(?:case "|default:)',
      dotAll: true,
    ).firstMatch(handle)?.group(1);
    expect(setter, isNotNull, reason: 'setCoverColor is not handled');
    expect(setter, contains('["color"] as? Int'));
    // Color.toARGB32(): alpha in the top byte, then red, green, blue.
    expect(setter, contains('(argb >> 16) & 0xFF'));
    expect(setter, contains('(argb >> 8) & 0xFF'));
    expect(setter, contains('argb & 0xFF'));
    expect(setter, contains('coverColor = UIColor('));
    expect(
      setter,
      contains('alpha: 1'),
      reason: 'the cover must stay opaque whatever arrives',
    );
  });

  test('the cover paints that tone and no fixed dark material', () {
    final resign = _body(plugin, 'private func willResignActive(');
    expect(resign, contains('cover.backgroundColor = coverColor'));
    expect(resign, isNot(contains('UIBlurEffect')));
    expect(plugin, isNot(contains('UIColor(red: 0.043')));
  });
}
