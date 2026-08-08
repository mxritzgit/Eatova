import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:eatova/src/auth/auth_repository.dart';

// Sentinel-Fund 1 (Nachverifikation 2026-08-08): `defaultAuthRepository()`
// fiel bei JEDEM Fehler auf PreviewAuthRepository zurueck — deren currentUser
// ist nie null (feste Identitaet 'preview-user') und deren signIn/signOut
// sind No-Ops. Aufgerufen wird die Funktion in eatova_app.dart in build():
// ein Fehler an dieser Stelle renderte also die EINGELOGGTE Ansicht ohne
// Anmeldung. Der Boot-Guard in main.dart deckt nur den Init-Pfad ab, nicht
// dieses spaetere Fenster.
//
// Neuer Vertrag: der Preview-Komfort bleibt auf Debug/Test beschraenkt
// (allowPreview, Default kDebugMode — daran haengen die Flow-Tests, die
// `EatovaApp()` ohne Repository pumpen). Im Release-Pfad gibt es bei einem
// Fehler KEINEN erfundenen Nutzer: AuthGate zeigt den Login, und ein
// Anmeldeversuch scheitert laut mit einer ehrlichen Meldung.
//
// WICHTIG: dieses File ruft bewusst NIE Supabase.initialize() — genau der
// Zustand, in dem Supabase.instance wirft und der Fallback greift.

void main() {
  group('buildDefaultAuthRepository ohne Supabase', () {
    test('Release-Pfad: es gibt KEINEN eingeloggten Nutzer', () {
      final repo = buildDefaultAuthRepository(allowPreview: false);
      expect(repo.currentUser, isNull,
          reason: 'ein erfundener Nutzer rendert die eingeloggte Ansicht '
              'ohne Anmeldung');
    });

    test('Release-Pfad: der Auth-Stream beginnt ausgeloggt', () async {
      final repo = buildDefaultAuthRepository(allowPreview: false);
      expect(await repo.authStateChanges.first, isNull,
          reason: 'AuthGate haengt am ersten Stream-Wert — der muss den '
              'Login zeigen, nicht die Home-Page');
    });

    test('Release-Pfad: Anmeldeversuche scheitern LAUT statt still', () async {
      final repo = buildDefaultAuthRepository(allowPreview: false);
      await expectLater(repo.signIn(email: 'a@example.com', password: 'pw'),
          throwsA(isA<AuthException>()),
          reason: 'ein stiller No-Op liesse den Nutzer endlos auf dem '
              'Login-Button druecken');
      await expectLater(
          repo.signUp(
              email: 'a@example.com', password: 'pw', displayName: 'A'),
          throwsA(isA<AuthException>()));
      await expectLater(repo.signInWithOAuth(EatovaOAuthProvider.google),
          throwsA(isA<AuthException>()));
    });

    test('Release-Pfad: signOut bleibt gefahrlos', () async {
      // Der Profil-Screen ruft signOut auch in Fehlerpfaden — das darf im
      // degradierten Zustand nie ZUSAETZLICH werfen.
      await expectLater(
          buildDefaultAuthRepository(allowPreview: false).signOut(),
          completes);
    });

    test('Debug/Test-Pfad: Preview bleibt fuer Widget-Tests erhalten', () {
      expect(buildDefaultAuthRepository(allowPreview: true),
          isA<PreviewAuthRepository>());
      // Der Default (kDebugMode, in Tests immer true) ist derselbe Pfad —
      // darauf stuetzen sich die Flow-Tests, die EatovaApp() ohne Repository
      // pumpen (navigation_flow, recipes_flow, localization_de, ...).
      expect(defaultAuthRepository(), isA<PreviewAuthRepository>());
    });
  });
}
