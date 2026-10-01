// The native launch screens and the first frame of the Flutter welcome
// screen must be the same picture: page colour, focus ring in the accent,
// 80 logical px, centred. Any drift shows as a flash on every cold start, and
// nothing else would notice it, because native resources are invisible to
// widget tests. These checks read the resources straight from the project.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/auth/welcome_screen.dart';

const _res = 'android/app/src/main/res';
const _ios = 'ios/Runner';

String _read(String path) => File(path).readAsStringSync();

Color _androidColor(String name) {
  final match = RegExp(
    '<color name="$name">#([0-9A-Fa-f]{6})</color>',
  ).firstMatch(_read('$_res/values/launch_colors.xml'));
  expect(match, isNotNull, reason: '@color/$name fehlt');
  return Color(int.parse('FF${match!.group(1)}', radix: 16));
}

void main() {
  const size = WelcomeScreen.launchMarkSize;
  final page = AppTokens.dark.bg;
  final ring = AppTokens.dark.accent;

  test('Android: Startfarbe und Ringfarbe sind die Flutter-Tokens', () {
    expect(_androidColor('launch_background'), page);
    expect(_androidColor('launch_mark'), ring);
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

  test('iOS: Storyboard-Grund ist der Seitengrund, LaunchImage 80 pt', () {
    final storyboard = _read('$_ios/Base.lproj/LaunchScreen.storyboard');
    final bg = RegExp(
      r'<color key="backgroundColor" red="([0-9.]+)" green="([0-9.]+)" '
      r'blue="([0-9.]+)" alpha="1" colorSpace="custom" '
      r'customColorSpace="sRGB"/>',
    ).firstMatch(storyboard);
    expect(bg, isNotNull);
    int channel(int i) => (double.parse(bg!.group(i)!) * 255).round();
    expect(Color.fromARGB(255, channel(1), channel(2), channel(3)), page);
    expect(
      storyboard,
      contains('<image name="LaunchImage" width="80" height="80"/>'),
    );
    for (final (name, scale) in [
      ('LaunchImage.png', 1),
      ('LaunchImage@2x.png', 2),
      ('LaunchImage@3x.png', 3),
    ]) {
      final bytes = File(
        '$_ios/Assets.xcassets/LaunchImage.imageset/$name',
      ).readAsBytesSync();
      // PNG IHDR: width and height as big-endian ints at bytes 16 and 20.
      final header = ByteData.sublistView(bytes, 16, 24);
      expect(header.getUint32(0), size * scale, reason: name);
      expect(header.getUint32(4), size * scale, reason: name);
    }
  });
}
