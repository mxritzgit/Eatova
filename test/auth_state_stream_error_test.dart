import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:eatova/src/config/supabase_config.dart';

// Sentry FLUTTER-8 (2026-08-23, level FATAL): gotrue's auto-refresh timer
// fired while iOS had the app in the background without network; the
// resulting `AuthRetryableFetchException` went into `onAuthStateChange` as a
// stream ERROR (`notifyException`). The OAuth-sheet listener in
// `EatovaSupabaseConfig` was the last subscriber without `onError`, so the
// error escaped as an unhandled zone error. Rule pinned here: that listener
// swallows stream errors and keeps working afterwards.

void main() {
  late StreamController<AuthState> auth;
  late List<int> geschlossen;
  late StreamSubscription<AuthState> sub;

  setUp(() {
    auth = StreamController<AuthState>();
    geschlossen = <int>[];
    sub = EatovaSupabaseConfig.wireOAuthSheetDismiss(
      auth.stream,
      closeSheet: () async => geschlossen.add(1),
    );
  });

  tearDown(() async {
    await sub.cancel();
    await auth.close();
  });

  test('ein Refresh-Fehler im Auth-Stream ist KEIN unbehandelter Zone-Fehler',
      () async {
    // An unhandled stream error would fail this test through the zone.
    auth.addError(
        AuthRetryableFetchException(message: 'offline'), StackTrace.current);
    await pumpEventQueue();
    expect(geschlossen, isEmpty);
  });

  test('nach dem Fehler reagiert der Listener weiterhin auf signedIn',
      () async {
    auth.addError(
        AuthRetryableFetchException(message: 'offline'), StackTrace.current);
    auth.add(const AuthState(AuthChangeEvent.tokenRefreshed, null));
    auth.add(const AuthState(AuthChangeEvent.signedIn, null));
    await pumpEventQueue();
    expect(geschlossen, hasLength(1),
        reason: 'nur signedIn schliesst das Sheet, tokenRefreshed nicht');
  });

  test('andere Ereignisse schliessen das Sheet nicht', () async {
    auth.add(const AuthState(AuthChangeEvent.initialSession, null));
    auth.add(const AuthState(AuthChangeEvent.signedOut, null));
    auth.add(const AuthState(AuthChangeEvent.userUpdated, null));
    await pumpEventQueue();
    expect(geschlossen, isEmpty);
  });
}
