// WIRING GUARD SEC-1: what Android cloud backup and device-to-device transfer
// may carry (android/app/src/main/res/xml/data_extraction_rules.xml).
//
// The encrypted cache, the outbox and the DEK sentinel live in
// files/eatova-cache.sqlite with its WAL/SHM files (domain "file"). Their key
// never travels: the wrapped DEK sits in the excluded shared_prefs and the
// AndroidKeyStore key cannot leave the device. A transferred database looks
// like a vanished key on the new phone (no offline cache for two starts, then
// a reset notice), so it has to stay behind. Only a device test proves what
// the transfer really copies; this pins the rules that decide it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/durable_cache_store.dart';

const String _rulesPath =
    'android/app/src/main/res/xml/data_extraction_rules.xml';
const String _manifestPath = 'android/app/src/main/AndroidManifest.xml';

String _withoutXmlComments(String xml) =>
    xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

/// The (domain, path) pairs excluded in [section], attribute order ignored.
Set<(String, String)> _excludes(String xml, String section) {
  final body = RegExp(
    '<$section>(.*?)</$section>',
    dotAll: true,
  ).firstMatch(xml)?.group(1);
  if (body == null) fail('<$section> missing');
  String attribute(String element, String name) =>
      RegExp('$name="([^"]*)"').firstMatch(element)?.group(1) ?? '';
  return {
    for (final m in RegExp(r'<exclude\b[^>]*>').allMatches(body))
      (attribute(m.group(0)!, 'domain'), attribute(m.group(0)!, 'path')),
  };
}

void main() {
  late String rules;

  setUpAll(() {
    rules = _withoutXmlComments(File(_rulesPath).readAsStringSync());
  });

  test('the manifest applies these rules', () {
    final manifest = _withoutXmlComments(
      File(_manifestPath).readAsStringSync(),
    );
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
  });

  for (final section in <String>['cloud-backup', 'device-transfer']) {
    group(section, () {
      test('leaves the cache database and its journal files behind', () {
        final excludes = _excludes(rules, section);
        for (final suffix in <String>['', '-wal', '-shm', '-journal']) {
          final file = '${DurableCacheStore.databaseFileName}$suffix';
          expect(excludes, contains(('file', file)), reason: file);
        }
      });

      test('leaves the session and the wrapped DEK behind', () {
        final excludes = _excludes(rules, section);
        expect(excludes, contains(('sharedpref', '.')));
        expect(excludes, contains(('file', 'datastore')));
      });

      test('still carries the recipe photos (P10-04)', () {
        // They exist nowhere else; dropping them would lose the user's own
        // pictures on every phone switch.
        final excludes = _excludes(rules, section);
        expect(excludes, isNot(contains(('root', 'app_flutter'))));
        expect(excludes, isNot(contains(('root', '.'))));
        expect(excludes, isNot(contains(('file', '.'))));
      });
    });
  }
}
