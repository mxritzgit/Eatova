// WIRING GUARD P3-01 — the install marker on the production boot path.
//
// `test/services/fresh_install_guard_test.dart` covers the guard through its
// seams. What makes it effective is the call in
// `EatovaSupabaseConfig.initialize()` BEFORE `Supabase.initialize` restores
// the persisted session; called after it, or not at all, the previous owner's
// account is already signed in. This drives the real initialize on the
// packages' in-memory test platforms: an empty app container (fresh install)
// next to a Keychain that still holds a session (iOS keeps it across
// uninstall).

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:eatova/src/config/install_marker.dart';
import 'package:eatova/src/config/supabase_config.dart';

/// Not a JWT, so `recoverSession` would never refresh over the network.
const String _leftover = '{"access_token":"access-vom-vorbesitzer",'
    '"refresh_token":"refresh-vom-vorbesitzer","token_type":"bearer",'
    '"expires_in":3600,'
    '"user":{"id":"11111111-2222-3333-4444-555555555555",'
    '"aud":"authenticated","created_at":"2026-01-01T00:00:00Z",'
    '"email":"vorbesitzer@example.de","app_metadata":{},'
    '"user_metadata":{}}}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('fresh_install_wiring');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => support.path,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (Supabase.instance.isInitialized) await Supabase.instance.dispose();
    if (await support.exists()) await support.delete(recursive: true);
  });

  test(
    'P3-01-Verdrahtung: nach einer Neuinstallation stellt der echte '
    'App-Start die Keychain-Session des Vorbesitzers NICHT wieder her',
    () async {
      final key = EatovaSupabaseConfig.sessionPersistKey;
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final keystore = <String, String>{key: _leftover};
      FlutterSecureStorage.setMockInitialValues(keystore);

      await EatovaSupabaseConfig.initialize();

      expect(Supabase.instance.client.auth.currentSession, isNull,
          reason: 'Ohne den Guard vor Supabase.initialize landet die '
              'Neuinstallation im Konto des Vorbesitzers.');
      expect(keystore.containsKey(key), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(FreshInstallGuard.markerKey), isTrue);
    },
  );
}
