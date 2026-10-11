// The native launch screens and the first frame of the Flutter welcome
// screen must be the same picture: page colour, focus ring in the accent,
// 80 logical px, centred. Any drift shows as a flash on every cold start, and
// nothing else would notice it, because native resources are invisible to
// widget tests. These checks read the resources straight from the project.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/auth/welcome_screen.dart';

const _res = 'android/app/src/main/res';
const _ios = 'ios/Runner';

String _read(String path) => File(path).readAsStringSync();

Color _androidColor(String name, {required String dir}) {
  final match = RegExp(
    '<color name="$name">#([0-9A-Fa-f]{6})</color>',
  ).firstMatch(_read('$_res/$dir/launch_colors.xml'));
  expect(match, isNotNull, reason: '$dir: @color/$name fehlt');
  return Color(int.parse('FF${match!.group(1)}', radix: 16));
}

/// The asset-catalog entries of [set], keyed by appearance: `any` for the
/// entry without one, otherwise the luminosity value (`dark`).
Map<String, List<Map<String, Object?>>> _byAppearance(
  String set,
  String list,
) {
  final json = jsonDecode(_read('$_ios/Assets.xcassets/$set/Contents.json'))
      as Map<String, Object?>;
  final result = <String, List<Map<String, Object?>>>{};
  final entries = (json[list] as List<Object?>).cast<Map<String, Object?>>();
  for (final entry in entries) {
    final appearances = (entry['appearances'] as List<Object?>?) ?? const [];
    final key = appearances.isEmpty
        ? 'any'
        : (appearances.single as Map<String, Object?>)['value'] as String;
    result.putIfAbsent(key, () => []).add(entry);
  }
  return result;
}

Color _catalogColor(Map<String, Object?> entry) {
  final color = entry['color'] as Map<String, Object?>;
  expect(color['color-space'], 'srgb');
  final c = color['components'] as Map<String, Object?>;
  int channel(String name) => int.parse(
        (c[name] as String).replaceFirst('0x', ''),
        radix: 16,
      );
  expect(c['alpha'], '1.000');
  return Color.fromARGB(255, channel('red'), channel('green'), channel('blue'));
}

void main() {
  const size = WelcomeScreen.launchMarkSize;
  // Both platforms resolve per OS mode, like the app's default
  // `ThemeMode.system`.

  test('Android: Startfarbe und Ringfarbe sind die Flutter-Tokens je Modus',
      () {
    for (final (dir, t) in <(String, AppTokens)>[
      ('values', AppTokens.light),
      ('values-night', AppTokens.dark),
    ]) {
      expect(_androidColor('launch_background', dir: dir), t.bg, reason: dir);
      expect(_androidColor('launch_mark', dir: dir), t.accent, reason: dir);
    }
  });

  test('Android: das Fenster-Theme folgt dem OS-Modus', () {
    for (final (dir, parent) in <(String, String)>[
      ('values', 'Theme.Light.NoTitleBar'),
      ('values-v31', 'Theme.Light.NoTitleBar'),
      ('values-night', 'Theme.Black.NoTitleBar'),
      ('values-night-v31', 'Theme.Black.NoTitleBar'),
    ]) {
      final xml = _read('$_res/$dir/styles.xml');
      for (final name in <String>['LaunchTheme', 'NormalTheme']) {
        expect(
          xml,
          contains('<style name="$name" parent="@android:style/$parent">'),
          reason: '$dir: $name',
        );
      }
      expect(
        xml,
        contains(
          '<item name="android:windowBackground">'
          '@color/launch_background</item>',
        ),
        reason: '$dir: Fenstergrund = Seitengrund',
      );
    }
  });

  test('Android 8-11: launch_background zeigt den Ring zentriert in 80 dp', () {
    for (final dir in ['drawable', 'drawable-v21']) {
      final xml = _read('$_res/$dir/launch_background.xml');
      expect(xml, contains('@drawable/launch_mark'), reason: dir);
      expect(xml, contains('android:gravity="center"'), reason: dir);
      expect(xml, contains('android:width="${size.toInt()}dp"'), reason: dir);
    }
    final mark = _read('$_res/drawable/launch_mark.xml');
    expect(mark, contains('android:width="${size.toInt()}dp"'));
    expect(mark, contains('android:viewportWidth="${size.toInt()}"'));
  });

  test('Android 12+: Splash-API mit Seitengrund und demselben Ring', () {
    for (final dir in ['values-v31', 'values-night-v31']) {
      final xml = _read('$_res/$dir/styles.xml');
      expect(
        xml,
        contains(
          '<item name="android:windowSplashScreenBackground">'
          '@color/launch_background</item>',
        ),
        reason: dir,
      );
      expect(
        xml,
        contains(
          '<item name="android:windowSplashScreenAnimatedIcon">'
          '@drawable/launch_splash_icon</item>',
        ),
        reason: dir,
      );
    }
    // 288 dp icon canvas (no icon background), drawn 1:1; the ring inside
    // keeps the 80 dp geometry, so its ticks reach 40 dp from the centre.
    final icon = _read('$_res/drawable/launch_splash_icon.xml');
    expect(icon, contains('android:width="288dp"'));
    expect(icon, contains('V${144 + size ~/ 2}H'));
  });

  test('iOS: Seitengrund je Modus als benannte Farbe', () {
    final colors = _byAppearance('LaunchBackground.colorset', 'colors');
    expect(colors.keys, unorderedEquals(['any', 'dark']));
    expect(_catalogColor(colors['any']!.single), AppTokens.light.bg);
    expect(_catalogColor(colors['dark']!.single), AppTokens.dark.bg);
  });

  // Main.storyboard: the ground behind the FlutterViewController, visible
  // during the UIScene relayout on resume.
  for (final name in ['LaunchScreen', 'Main']) {
    test('iOS: $name.storyboard nutzt den benannten Seitengrund', () {
      final storyboard = _read('$_ios/Base.lproj/$name.storyboard');
      expect(
        storyboard,
        contains('<color key="backgroundColor" name="LaunchBackground"/>'),
      );
      expect(
        storyboard,
        isNot(contains('<color key="backgroundColor" red=')),
        reason: 'a fixed colour cannot follow the OS mode',
      );
      expect(
        storyboard,
        contains('<capability name="Named colors" minToolsVersion="9.0"/>'),
      );
      expect(storyboard, contains('<namedColor name="LaunchBackground">'));
    });
  }

  test('iOS: LaunchImage 80 pt, Ring je Modus in der Akzentfarbe', () {
    final storyboard = _read('$_ios/Base.lproj/LaunchScreen.storyboard');
    expect(
      storyboard,
      contains('<image name="LaunchImage" width="80" height="80"/>'),
    );
    final images = _byAppearance('LaunchImage.imageset', 'images');
    expect(images.keys, unorderedEquals(['any', 'dark']));
    for (final (mode, t) in <(String, AppTokens)>[
      ('any', AppTokens.light),
      ('dark', AppTokens.dark),
    ]) {
      expect(
        images[mode]!.map((e) => e['scale']),
        unorderedEquals(['1x', '2x', '3x']),
        reason: mode,
      );
      for (final entry in images[mode]!) {
        final name = entry['filename']! as String;
        final scale = int.parse((entry['scale']! as String)[0]);
        final bytes = File(
          '$_ios/Assets.xcassets/LaunchImage.imageset/$name',
        ).readAsBytesSync();
        // PNG IHDR: width and height as big-endian ints at bytes 16 and 20.
        final header = ByteData.sublistView(bytes, 16, 24);
        expect(header.getUint32(0), size * scale, reason: name);
        expect(header.getUint32(4), size * scale, reason: name);
        // The centre dot is fully covered, so its pixel is the ring colour.
        final png = img.decodePng(bytes)!;
        final centre = png.getPixel(png.width ~/ 2, png.height ~/ 2);
        expect(
          Color.fromARGB(
            centre.a.toInt(),
            centre.r.toInt(),
            centre.g.toInt(),
            centre.b.toInt(),
          ),
          t.accent,
          reason: name,
        );
      }
    }
  });
}
