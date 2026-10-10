// WIRING GUARD for `eatova/speech` on the native sides. Neither Swift nor
// Kotlin runs in `flutter test`, so this reads the sources that go into the
// builds and pins what the Dart contract (lib/src/services/speech_input.dart)
// relies on. It cannot prove recognition works: that needs a device.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/speech_input.dart';

const String _manifestPath = 'android/app/src/main/AndroidManifest.xml';
const String _bridgePath =
    'android/app/src/main/kotlin/com/eatova/app/SpeechBridge.kt';
const String _activityPath =
    'android/app/src/main/kotlin/com/eatova/app/MainActivity.kt';
const String _appDelegatePath = 'ios/Runner/AppDelegate.swift';

String _read(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    fail('$path missing (resolved from ${Directory.current.path})');
  }
  return file.readAsStringSync();
}

String _withoutXmlComments(String xml) =>
    xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

/// Kotlin/Swift source without comments, so a comment naming an API does
/// not count as a use.
String _withoutCodeComments(String source) => source
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .split('\n')
    .map((line) {
      final i = line.indexOf('//');
      return i < 0 ? line : line.substring(0, i);
    })
    .join('\n');

void main() {
  group('Android', () {
    late String manifest;
    late String bridge;
    late String activity;

    setUpAll(() {
      manifest = _withoutXmlComments(_read(_manifestPath));
      bridge = _withoutCodeComments(_read(_bridgePath));
      activity = _withoutCodeComments(_read(_activityPath));
    });

    test('the recognizer dialog is visible to the app (Android 11+)', () {
      final queries = RegExp(
        r'<queries>(.*?)</queries>',
        dotAll: true,
      ).firstMatch(manifest);
      expect(queries, isNotNull);
      expect(
        queries!.group(1),
        contains('android:name="android.speech.action.RECOGNIZE_SPEECH"'),
        reason:
            'Without the <queries> entry resolveActivity finds no '
            'recognizer on Android 11+ and every listen is `unavailable`.',
      );
    });

    test('RECORD_AUDIO stays removed because the recognizer app records', () {
      expect(
        manifest,
        matches(
          RegExp(
            r'<uses-permission\s+android:name="android\.permission\.RECORD_AUDIO"'
            r'\s+tools:node="remove"\s*/>',
          ),
        ),
      );
      // In-app recognition would need RECORD_AUDIO back; with the permission
      // removed it would fail at runtime without a prompt.
      for (final api in <String>[
        'SpeechRecognizer.',
        'createSpeechRecognizer',
        'AudioRecord',
        'MediaRecorder',
      ]) {
        expect(bridge, isNot(contains(api)), reason: api);
      }
      expect(bridge, contains('RecognizerIntent.ACTION_RECOGNIZE_SPEECH'));
    });

    test('SpeechBridge serves the shared channel and never logs', () {
      expect(bridge, contains('"eatova/speech"'));
      for (final method in <String>['listen', 'stop', 'cancel', 'available']) {
        expect(bridge, contains('"$method"'), reason: method);
      }
      expect(bridge, isNot(contains('Log.')));
      expect(bridge, isNot(contains('println')));
    });

    test('the launcher is a field (registered before STARTED), the bridge '
        'lives with the engine', () {
      final launcher = RegExp(
        r'^    private val speechLauncher =\s*\n\s*registerForActivityResult\(',
        multiLine: true,
      );
      expect(
        activity,
        matches(launcher),
        reason:
            'registerForActivityResult after STARTED throws; a field '
            'initializer is always before onCreate.',
      );
      expect(
        activity,
        contains(
          'speechBridge = SpeechBridge(this, flutterEngine, speechLauncher)',
        ),
      );
      expect(activity, contains('speechBridge?.onHostResumed()'));
      expect(activity, contains('speechBridge?.close()'));
    });
  });

  group('iOS', () {
    late String plugin;

    setUpAll(() => plugin = _withoutCodeComments(_read(_appDelegatePath)));

    test('listen reads vocabulary and maxUnits, defaulting to the coach', () {
      expect(plugin, contains('args?["vocabulary"] as? String'));
      expect(
        plugin,
        contains('== "${SpeechVocabulary.food.name}"'),
        reason: 'Dart sends SpeechVocabulary.name on the wire.',
      );
      expect(
        plugin,
        contains('args?["maxUnits"] as? Int ?? Self.defaultMaxTranscriptUnits'),
      );
      expect(
        plugin,
        contains('private static let defaultMaxTranscriptUnits = 1000'),
      );
      expect(plugin, contains('request.contextualStrings = contextualStrings'));
      expect(
        plugin,
        contains('self.transcript.text.utf16.count >= self.maxTranscriptUnits'),
      );
    });

    test('the food vocabulary covers the words recognizers mishear', () {
      final list = RegExp(
        r'foodVocabulary: \[String\] = \[(.*?)\]',
        dotAll: true,
      ).firstMatch(plugin);
      expect(list, isNotNull);
      final words = RegExp(
        r'"([^"]+)"',
      ).allMatches(list!.group(1)!).map((m) => m.group(1)!).toList();
      expect(words.toSet(), hasLength(words.length), reason: 'duplicates');
      // Apple advises at most about 100 contextual strings.
      expect(words.length, inInclusiveRange(40, 100));
      expect(
        words,
        containsAll(<String>[
          'Nutella',
          'Skyr',
          'Magerquark',
          'Haferflocken',
          'Hähnchenbrust',
          'Toastbrot',
          'Vollkornbrot',
          'Müsli',
          'Joghurt',
          'Gramm',
          'Scheibe',
          'Esslöffel',
          'Teelöffel',
          'Lidl',
          'Aldi',
          'Rewe',
          'Edeka',
        ]),
      );
    });
  });

  test('every iOS purpose string names the meal description', () {
    final english = <String>[
      _read('ios/Runner/Info.plist'),
      _read('ios/Runner/en.lproj/InfoPlist.strings'),
    ];
    for (final source in english) {
      for (final key in <String>[
        'NSMicrophoneUsageDescription',
        'NSSpeechRecognitionUsageDescription',
      ]) {
        expect(_purpose(source, key), contains('meal'), reason: key);
        expect(_purpose(source, key), contains('coach'), reason: key);
      }
    }
    final german = _read('ios/Runner/de.lproj/InfoPlist.strings');
    for (final key in <String>[
      'NSMicrophoneUsageDescription',
      'NSSpeechRecognitionUsageDescription',
    ]) {
      expect(_purpose(german, key), contains('Mahlzeit'), reason: key);
      expect(_purpose(german, key), contains('Coach'), reason: key);
    }
  });
}

/// The value for [key] in an Info.plist or an InfoPlist.strings file.
String _purpose(String source, String key) {
  final plist = RegExp(
    '<key>$key</key>\\s*<string>([^<]*)</string>',
  ).firstMatch(source);
  final strings = RegExp('"$key" = "([^"]*)";').firstMatch(source);
  final value = plist?.group(1) ?? strings?.group(1);
  if (value == null) fail('$key missing');
  return value;
}
