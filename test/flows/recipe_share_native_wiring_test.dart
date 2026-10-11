// WIRING GUARD for the Android share entry (`eatova/recipe_share`). Kotlin
// does not run in `flutter test`, so this reads MainActivity.kt and pins the
// hand-off the Dart receiver relies on: a share that starts a new activity
// must reach the process-wide queue that `consumePending` drains.
//
// FlutterFragmentActivity adds its FlutterFragment with an asynchronous
// commit(), so configureFlutterEngine (and with it the bridge) runs only in
// onStart, after onCreate has returned. A share handed to the bridge from
// onCreate was therefore dropped on every new MainActivity. Whether Android
// really delivers the share needs a device; see docs/NATIVE_RECIPE_SHARE.md.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _activityPath =
    'android/app/src/main/kotlin/com/eatova/app/MainActivity.kt';
const String _bridgePath =
    'android/app/src/main/kotlin/com/eatova/app/RecipeShareBridge.kt';

String _read(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    fail('$path missing (resolved from ${Directory.current.path})');
  }
  return file.readAsStringSync();
}

/// Kotlin source without comments, so a comment naming an API does not count
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
  late String activity;
  late String onCreate;
  late String onNewIntent;
  late String configure;

  setUpAll(() {
    activity = _withoutCodeComments(_read(_activityPath));
    onCreate = _body(activity, 'override fun onCreate(');
    onNewIntent = _body(activity, 'override fun onNewIntent(');
    configure = _body(activity, 'override fun configureFlutterEngine(');
  });

  test(
    'onCreate does not hand the share to a bridge that cannot exist yet',
    () {
      expect(onCreate, isNot(contains('recipeShareBridge?.receive(')));
      expect(onCreate, isNot(contains('recipeShareBridge!!.receive(')));
    },
  );

  test('the launch share is held and delivered once the bridge exists', () {
    final held = RegExp(
      r'private var (\w+): Intent\? = null',
    ).firstMatch(activity)?.group(1);
    expect(held, isNotNull, reason: 'MainActivity holds no early share');

    final created = configure.indexOf(
      'recipeShareBridge = RecipeShareBridge(this, flutterEngine)',
    );
    expect(created, isNonNegative);
    final afterCreate = configure.substring(created);
    expect(
      afterCreate,
      matches(RegExp('\\.receive\\($held\\)')),
      reason: 'the held share must reach the new bridge',
    );
    expect(
      afterCreate,
      contains('$held = null'),
      reason: 'a later engine attach must not deliver it again',
    );

    // The share takes the same path from onCreate and onNewIntent: straight
    // to the bridge if there is one, otherwise into the held slot.
    final offer = RegExp(
      r'private fun (\w+)\(intent: Intent\) \{',
    ).firstMatch(activity)?.group(1);
    expect(offer, isNotNull);
    final offerBody = _body(activity, 'private fun $offer(');
    expect(offerBody, contains('recipeShareBridge'));
    expect(offerBody, contains('.receive(intent)'));
    expect(offerBody, contains('$held = intent'));
    expect(onCreate, contains('$offer(intent)'));
    expect(onNewIntent, contains('setIntent(intent)'));
    expect(onNewIntent, contains('$offer(intent)'));
  });

  test('a restored activity or a relaunch from Recents never replays it', () {
    // Both start with the original intent, EXTRA_TEXT included: removeExtra
    // only changes this process's copy, not the system's activity record.
    expect(onCreate, contains('savedInstanceState == null'));
    expect(onCreate, contains('Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY'));

    final receive = _body(
      _withoutCodeComments(_read(_bridgePath)),
      'fun receive(',
    );
    expect(
      receive,
      contains('intent.removeExtra(Intent.EXTRA_TEXT)'),
      reason: 'the in-process intent must not deliver the text twice',
    );
  });
}
