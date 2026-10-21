import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/config/legal_links.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/settings/settings_controls.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';

import '../support/harness.dart';

// J2 — legal links that fail to open must say so.
//
// On a device without a browser handler (work profile, kiosk, stripped ROM)
// `launchUrl` reports that in two shapes: `false` and — on Android — a thrown
// PlatformException('ACTIVITY_NOT_FOUND'). Neither was read: the tap visibly
// did NOTHING and the exception landed unhandled in
// PlatformDispatcher.onError. Imprint, terms and privacy are § 5 DDG / GDPR
// Art. 13 and a store requirement, so the fallback names the URL to type.
//
// All call sites share `openLegalLink`; each site is walked once with every
// link, and the two failure shapes alternate across links and sites.
//
// Sister file: test/auth/review0829_auth_legal_links_test.dart (the same
// promise for the sign-in consent note).

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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  const links = <({String key, String url})>[
    (key: 'settings-privacy-link', url: kPrivacyUrl),
    (key: 'settings-terms-link', url: kTermsUrl),
    (key: 'settings-imprint-link', url: kImprintUrl),
  ];
  final fehlschlaege = _fehlschlaege.values.toList();

  /// Taps [link] with the launcher failing as [fall] and expects the hint.
  Future<void> erwarteHinweis(
    WidgetTester tester,
    Finder link,
    String url,
    Future<Object?> Function(String) fall,
  ) async {
    final versuche = _fakeLauncher(tester, fall);
    await tester.tap(link);
    await tester.pumpAndSettle();

    expect(versuche, <String>[url]);
    expect(tester.takeException(), isNull,
        reason: 'the exception used to land in PlatformDispatcher.onError — '
            'a Sentry event without user context');
    expect(find.text(_hinweis(url)), findsOneWidget,
        reason: '§ 5 DDG / GDPR Art. 13: the text must stay reachable, if '
            'need be by typing the URL');
    await _raeumeToastAb(tester);
  }

  // Site 1 — the footer of the goals page (settings_controls.dart).
  group('Fussleiste der Ziele-Seite', () {
    Future<void> pumpe(WidgetTester tester) => pumpLocalized(
          tester,
          const SettingsLegalLinks(),
          brightness: Brightness.light,
          settle: true,
        );

    testWidgets('jeder Link meldet einen gescheiterten Start', (tester) async {
      await pumpe(tester);
      for (var i = 0; i < links.length; i++) {
        await erwarteHinweis(
          tester,
          find.byKey(ValueKey<String>(links[i].key)),
          links[i].url,
          fehlschlaege[i % fehlschlaege.length],
        );
      }
    });

    testWidgets('ein geglueckter Start sagt nichts', (tester) async {
      final versuche = _fakeLauncher(tester, (_) async => true);
      await pumpe(tester);

      await tester.tap(find.byKey(const ValueKey('settings-imprint-link')));
      await tester.pumpAndSettle();

      expect(versuche, <String>[kImprintUrl]);
      expect(find.textContaining('Der Link ließ sich'), findsNothing);
    });
  });

  // Sites 2 and 3 — the settings (settings_screen.dart).
  group('Einstellungen', () {
    Future<void> pumpe(WidgetTester tester) async {
      pinPhoneViewport(tester);
      await pumpLocalized(
        tester,
        const SettingsScreen(),
        brightness: Brightness.light,
        // The page brings its own Scaffold and SafeArea.
        scaffold: false,
        safeArea: false,
        settle: true,
      );
      expect(find.byKey(const ValueKey('screen-settings')), findsOneWidget);
    }

    /// The rows sit below the fold: scroll there first, then `ensureVisible`
    /// so they really are under the finger.
    Future<Finder> scrolleZu(WidgetTester tester, String key) async {
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
      return finder;
    }

    testWidgets('jede Rechts-Zeile meldet einen gescheiterten Start',
        (tester) async {
      await pumpe(tester);
      for (var i = 0; i < links.length; i++) {
        // The other shape than the footer used for the same link.
        await erwarteHinweis(
          tester,
          await scrolleZu(tester, links[i].key),
          links[i].url,
          fehlschlaege[(i + 1) % fehlschlaege.length],
        );
      }
    });

    // The privacy row of the "About Eatova" sheet; its key moved with the
    // sheet from the profile (DESIGN_REFACTOR §6).
    testWidgets('„Über Eatova"-Sheet meldet einen gescheiterten Start',
        (tester) async {
      await pumpe(tester);
      await tester.tap(await scrolleZu(tester, 'settings-about'));
      await tester.pumpAndSettle();
      final zeile = find.byKey(const ValueKey('profile-privacy-link'));
      expect(zeile, findsOneWidget);
      await tester.ensureVisible(zeile);
      await tester.pumpAndSettle();

      await erwarteHinweis(
        tester,
        zeile,
        kPrivacyUrl,
        _fehlschlaege['Android wirft ACTIVITY_NOT_FOUND']!,
      );
    });
  });
}
