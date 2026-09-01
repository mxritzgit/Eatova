import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:eatova/src/config/supabase_config.dart';

// Sentry FLUTTER-8 (2026-08-23, level FATAL): gotrue's auto-refresh timer
// fired while iOS had the app in the background without network; the
// resulting `AuthRetryableFetchException` went into `onAuthStateChange` as a
// stream ERROR (`notifyException`). The OAuth-sheet listener in
// `EatovaSupabaseConfig` was the last subscriber without `onError`, so the
// error escaped as an unhandled zone error. Rule pinned here: that listener
// swallows stream errors and keeps working afterwards — plus, at the end, the
// same rule for EVERY auth-stream listener in the tree.

/// Source without whole-line comments. Enough here: the scan below only looks
/// for `<etwas mit auth>.listen(`, and no string literal in `lib/` carries
/// that. A `//` inside a literal never starts a line, so nothing is cut that
/// belongs to code (the trap from repo_rules_test.dart's P10-03b).
String _ohneKommentarzeilen(String quelle) => quelle
    .split('\n')
    .where((zeile) {
      final t = zeile.trimLeft();
      return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
    })
    .join('\n');

/// Index just past the `)` matching the `(` at [start].
int _klammerEnde(String quelle, int start) {
  var tiefe = 0;
  for (var i = start; i < quelle.length; i++) {
    if (quelle[i] == '(') tiefe++;
    if (quelle[i] == ')') {
      tiefe--;
      if (tiefe == 0) return i + 1;
    }
  }
  return quelle.length;
}

/// Every `<receiver containing "auth">.listen(` in `lib/`, as
/// `pfad: argumente`.
List<(String, String)> _authListenAufrufe() {
  final treffer = <(String, String)>[];
  // Receiver chain plus `.listen(`. `[A-Za-z0-9_.]*auth[A-Za-z0-9_.]*` covers
  // `authStateChanges`, `authStates` and `...auth.onAuthStateChange`; the
  // `\s*` around the dot because the formatter breaks the line before
  // `.listen(` as soon as the chain is long enough.
  final muster =
      RegExp(r'\b[A-Za-z0-9_.]*[Aa]uth[A-Za-z0-9_.]*\s*\.\s*listen\(');
  for (final eintrag in Directory('lib').listSync(recursive: true)) {
    if (eintrag is! File || !eintrag.path.endsWith('.dart')) continue;
    final pfad = eintrag.path.replaceAll(r'\', '/');
    final quelle = _ohneKommentarzeilen(eintrag.readAsStringSync());
    for (final m in muster.allMatches(quelle)) {
      final auf = m.end - 1;
      treffer.add((pfad, quelle.substring(auf, _klammerEnde(quelle, auf))));
    }
  }
  return treffer;
}

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

  // ...und dieselbe Regel fuer den ganzen Baum.
  //
  // The three tests above pin ONE listener, and the AuthGate has its own
  // (test/gate_sync_auth_gate_test.dart, Fund 2). Both were written after the
  // Sentry event that taught them — a listener added tomorrow gets no such
  // lesson, and two of the existing ones (the AuthGate's re-subscription in
  // `didUpdateWidget`, the settings screen's session stream) could lose their
  // handler today without a single test noticing. Hence the rule at the
  // source: whoever subscribes to an auth stream names an `onError`.
  test('jeder Auth-Strom-Listener in lib/ nennt ein onError', () {
    final aufrufe = _authListenAufrufe();

    expect(aufrufe, hasLength(greaterThanOrEqualTo(4)),
        reason: 'der Scan findet sonst nichts mehr und waere gruen, weil er '
            'nicht mehr hinsieht (auth_gate 2x, settings_screen, '
            'supabase_config)');

    final ohne = <String>[
      for (final (pfad, argumente) in aufrufe)
        if (!argumente.contains('onError')) pfad,
    ];
    expect(ohne, isEmpty,
        reason: 'gotrue schiebt Fehler AKTIV in diese Stroeme '
            '(`notifyException`); ohne Handler wird daraus ein unbehandelter '
            'Zone-Fehler — von aussen ausloesbar ueber den BROWSABLE '
            'Deeplink-Intent und in Sentry als FATAL gebucht (FLUTTER-8)');
  });
}
