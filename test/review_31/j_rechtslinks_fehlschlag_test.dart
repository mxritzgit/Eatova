import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/config/legal_links.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/settings/settings_controls.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';

import '../support/harness.dart';

// J2 — die drei Rechtslinks ohne Fehlerbehandlung.
//
// Fuer den Einwilligungshinweis der Anmeldung wurde P4-05 gefixt
// (auth_screen.dart), die drei ANDEREN Aufrufstellen blieben blanke
// `launchUrl`-Aufrufe: die Fussleiste der Ziele-Seite
// ([SettingsLegalLinks]), die drei Rechts-Zeilen der Einstellungen und die
// Datenschutz-Zeile im „Über Eatova"-Sheet.
//
// Auf einem Geraet ohne Browser-Handler (Arbeitsprofil, Kiosk, abgespecktes
// ROM) meldet `launchUrl` das in zwei Gestalten: `false` und — unter Android —
// eine geworfene PlatformException('ACTIVITY_NOT_FOUND'). Gelesen wurde
// keine: der Tipp tat sichtbar NICHTS, und die Ausnahme landete unbehandelt in
// PlatformDispatcher.onError, also als Sentry-Ereignis ohne Nutzerbezug.
// Impressum, AGB und Datenschutz sind § 5 DDG / DSGVO Art. 13 und
// Store-Pflicht, deshalb nennt der Ersatzweg die URL zum Abtippen.
//
// Schwesterdatei: test/review0829_auth_legal_links_test.dart (dieselbe
// Zusicherung fuer den Einwilligungshinweis).

const MethodChannel _urlLauncherKanal =
    MethodChannel('plugins.flutter.io/url_launcher');

/// Installiert [antwort] fuer den url_launcher-Kanal und schreibt jede
/// gestartete URL mit. Zurueck kommt die Mitschrift.
List<String> _fakeLauncher(
  WidgetTester tester,
  Future<Object?> Function(String url) antwort,
) {
  final versuche = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_urlLauncherKanal, (call) async {
    if (call.method != 'launch') return null;
    final url = (call.arguments as Map<Object?, Object?>)['url']! as String;
    versuche.add(url);
    return antwort(url);
  });
  addTearDown(
      () => messenger.setMockMethodCallHandler(_urlLauncherKanal, null));
  return versuche;
}

/// Die zwei Gestalten von „kein Handler". Beide muessen dasselbe sagen.
final Map<String, Future<Object?> Function(String)> _fehlschlaege =
    <String, Future<Object?> Function(String)>{
  'launchUrl gibt false zurueck': (_) async => false,
  'Android wirft ACTIVITY_NOT_FOUND': (_) async => throw PlatformException(
        code: 'ACTIVITY_NOT_FOUND',
        message: 'No Activity found to handle Intent',
      ),
};

/// Laesst den stehenden Toast ablaufen, sonst meldet der Test einen offenen
/// Timer.
Future<void> _raeumeToastAb(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

/// Der Satz, den der Nutzer sehen muss, wenn der Link nicht aufgeht.
String _hinweis(String url) => deL10n.authLegalLinkFailed(url);

/// Quelltext ohne Kommentarzeilen — sonst zaehlt die Doku des Helfers als
/// Aufrufstelle mit.
String _codeOhneKommentare(String pfad) => File(pfad)
    .readAsStringSync()
    .split('\n')
    .where((z) => !z.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  // =========================================================================
  // Stelle 1 — die Fussleiste (settings_controls.dart)
  // =========================================================================
  group('Fussleiste der Ziele-Seite', () {
    Future<void> pumpe(WidgetTester tester) async {
      await pumpLocalized(
        tester,
        const SettingsLegalLinks(),
        brightness: Brightness.light,
        settle: true,
      );
    }

    // Alle drei Links der Leiste, damit keiner davon zurueckfaellt.
    const links = <({String key, String url})>[
      (key: 'settings-privacy-link', url: kPrivacyUrl),
      (key: 'settings-terms-link', url: kTermsUrl),
      (key: 'settings-imprint-link', url: kImprintUrl),
    ];

    for (final link in links) {
      for (final fall in _fehlschlaege.entries) {
        testWidgets('${link.key}: ${fall.key} — der Tipp sagt das',
            (tester) async {
          final versuche = _fakeLauncher(tester, fall.value);
          await pumpe(tester);

          await tester.tap(find.byKey(ValueKey<String>(link.key)));
          await tester.pumpAndSettle();

          expect(versuche, <String>[link.url]);
          expect(tester.takeException(), isNull,
              reason: 'die Ausnahme landete vorher in '
                  'PlatformDispatcher.onError — ein Sentry-Ereignis ohne '
                  'Nutzerbezug');
          expect(find.text(_hinweis(link.url)), findsOneWidget,
              reason: '§ 5 DDG / DSGVO Art. 13: der Text muss erreichbar '
                  'bleiben, notfalls per Abtippen der URL');
          await _raeumeToastAb(tester);
        });
      }
    }

    testWidgets('ein geglueckter Start sagt nichts', (tester) async {
      final versuche = _fakeLauncher(tester, (_) async => true);
      await pumpe(tester);

      await tester.tap(find.byKey(const ValueKey('settings-imprint-link')));
      await tester.pumpAndSettle();

      expect(versuche, <String>[kImprintUrl]);
      expect(find.textContaining('Der Link ließ sich'), findsNothing);
    });
  });

  // =========================================================================
  // Stellen 2 und 3 — die Einstellungen (settings_screen.dart)
  // =========================================================================
  group('Einstellungen', () {
    Future<void> pumpe(WidgetTester tester) async {
      pinPhoneViewport(tester);
      await pumpLocalized(
        tester,
        const SettingsScreen(),
        brightness: Brightness.light,
        // Die Seite bringt Scaffold und SafeArea selbst mit.
        scaffold: false,
        safeArea: false,
        settle: true,
      );
      expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
    }

    /// Die Seite ist eine faule Liste — was unterhalb der Kante liegt, steht
    /// bis zum Scrollen gar nicht im Baum. `ensureVisible` obendrauf, weil
    /// „im Baum" noch nicht „unter dem Finger" heisst.
    Future<void> scrolleZu(WidgetTester tester, String key) async {
      final finder = find.byKey(ValueKey<String>(key));
      await tester.scrollUntilVisible(
        finder,
        300,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('screen-settings')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
    }

    // Stelle 2: die drei Rechts-Zeilen unter DATEN & PRIVATSPHÄRE.
    const zeilen = <({String key, String url})>[
      (key: 'settings-privacy-link', url: kPrivacyUrl),
      (key: 'settings-terms-link', url: kTermsUrl),
      (key: 'settings-imprint-link', url: kImprintUrl),
    ];

    for (final zeile in zeilen) {
      for (final fall in _fehlschlaege.entries) {
        testWidgets('Zeile ${zeile.key}: ${fall.key} — der Tipp sagt das',
            (tester) async {
          final versuche = _fakeLauncher(tester, fall.value);
          await pumpe(tester);
          await scrolleZu(tester, zeile.key);

          await tester.tap(find.byKey(ValueKey<String>(zeile.key)));
          await tester.pumpAndSettle();

          expect(versuche, <String>[zeile.url]);
          expect(tester.takeException(), isNull);
          expect(find.text(_hinweis(zeile.url)), findsOneWidget);
          await _raeumeToastAb(tester);
        });
      }
    }

    // Stelle 3: die Datenschutz-Zeile im „Über Eatova"-Sheet. Der Key ist
    // mit dem Sheet aus dem Profil mitgewandert (DESIGN_REFACTOR §6).
    for (final fall in _fehlschlaege.entries) {
      testWidgets('„Über Eatova"-Sheet: ${fall.key} — der Tipp sagt das',
          (tester) async {
        final versuche = _fakeLauncher(tester, fall.value);
        await pumpe(tester);
        await scrolleZu(tester, 'settings-about');

        await tester.tap(find.byKey(const ValueKey('settings-about')));
        await tester.pumpAndSettle();
        final zeile = find.byKey(const ValueKey('profile-privacy-link'));
        expect(zeile, findsOneWidget);

        await tester.ensureVisible(zeile);
        await tester.pumpAndSettle();
        await tester.tap(zeile);
        await tester.pumpAndSettle();

        expect(versuche, <String>[kPrivacyUrl]);
        expect(tester.takeException(), isNull);
        expect(find.text(_hinweis(kPrivacyUrl)), findsOneWidget,
            reason: 'DSGVO Art. 13 gilt auch hinter dem Sheet');
        await _raeumeToastAb(tester);
      });
    }

    testWidgets('ein geglueckter Start sagt auch hier nichts', (tester) async {
      final versuche = _fakeLauncher(tester, (_) async => true);
      await pumpe(tester);
      await scrolleZu(tester, 'settings-terms-link');

      await tester.tap(find.byKey(const ValueKey('settings-terms-link')));
      await tester.pumpAndSettle();

      expect(versuche, <String>[kTermsUrl]);
      expect(find.textContaining('Der Link ließ sich'), findsNothing);
    });
  });

  // =========================================================================
  // Eine Kopie pro Aufrufstelle waere der schlechtere Fix gewesen
  // =========================================================================
  test('alle Rechtslinks gehen durch EINEN Helfer', () {
    // Der Punkt von J2: nicht dass die Stellen heute dasselbe tun, sondern
    // dass es nur noch EINE gibt, an der es steht. Vier gleichlautende Kopien
    // haetten genau so wieder auseinanderlaufen koennen wie die drei, die den
    // Fix des Einwilligungshinweises nicht mitbekommen haben.
    //
    // `auth_screen.dart` traegt seine byte-gleiche Kopie noch (fremdes
    // Eigentum in diesem Lauf) und fehlt deshalb in der Liste — beim Anziehen
    // des Helfers gehoert es dazu.
    final controls =
        _codeOhneKommentare('lib/src/screens/settings/settings_controls.dart');
    final screen =
        _codeOhneKommentare('lib/src/screens/settings/settings_screen.dart');

    expect(
      controls,
      contains('Future<void> openLegalLink(BuildContext context, String url)'),
      reason: 'der Helfer ist oeffentlich, damit auth_screen ihn anziehen kann',
    );
    expect(
      'launchUrl('.allMatches(controls).length,
      1,
      reason: 'genau ein launchUrl im ganzen Paket: das im Helfer',
    );
    expect(
      screen,
      isNot(contains('launchUrl(')),
      reason: 'die Rechts-Zeilen und die Datenschutz-Zeile riefen launchUrl '
          'selbst auf — ohne jede Auswertung des Ergebnisses',
    );
    expect('openLegalLink('.allMatches(screen).length, 2,
        reason: 'die Rechts-Zeile und die Datenschutz-Zeile im Sheet');
  });
}
