import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/config/legal_links.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/auth_screen.dart';

import 'support/harness.dart';

// The two legal links under the login form (Review 2026-08-29, P4-05).
//
// `_open` was `async`, called from a TapGestureRecognizer, and nothing read
// its outcome: neither the `bool` of `launchUrl` nor an exception. On a device
// without a handler `url_launcher_android` throws
// PlatformException('ACTIVITY_NOT_FOUND') — the tap then did visibly NOTHING
// and the exception ended up unhandled in PlatformDispatcher.onError, i.e. as
// a Sentry event nobody could tie to a user. AGB and Datenschutz are GDPR
// Art. 13 and app-store obligations on exactly this screen, so a dead tap is
// not a cosmetic issue.

const MethodChannel _urlLauncherKanal =
    MethodChannel('plugins.flutter.io/url_launcher');

/// Installs [handler] for the url_launcher channel and records the launched
/// URLs. Returns the recording list.
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

Future<void> _pumpAuth(WidgetTester tester) async {
  // iPhone 14 portrait: on the 800x600 default the consent notice sits below
  // the fold and `tapOnText` finds no hit-testable offset in it.
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await pumpLocalized(
    tester,
    AuthScreen(authRepository: InMemoryAuthRepository()),
    reducedMotion: false,
    scaffold: false,
    safeArea: false,
  );
  await tester.pumpAndSettle();
}

/// Taps the link span with [text] inside the consent notice.
Future<void> _tippeLink(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.byKey(const ValueKey('auth-consent-notice')));
  await tester.pumpAndSettle();
  await tester.tapOnText(find.textRange.ofSubstring(text));
  await tester.pumpAndSettle();
}

/// Lets the standing toast expire, else the test reports a live timer.
Future<void> _raeumeToastAb(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('der AGB-Link oeffnet die AGB-URL (Normalfall bleibt heil)',
      (tester) async {
    final versuche = _fakeLauncher(tester, (_) async => true);
    await _pumpAuth(tester);

    await _tippeLink(tester, 'AGB');

    expect(versuche, <String>[kTermsUrl]);
    expect(find.textContaining('Der Link ließ sich'), findsNothing,
        reason: 'ein geglueckter Start sagt nichts');
  });

  testWidgets(
      'ein Geraet ohne Browser wirft ACTIVITY_NOT_FOUND — der Tap sagt das, '
      'statt die Ausnahme unbehandelt nach Sentry zu schicken', (tester) async {
    // The real exception url_launcher_android:124-125 throws.
    final versuche = _fakeLauncher(
      tester,
      (_) async => throw PlatformException(
        code: 'ACTIVITY_NOT_FOUND',
        message: 'No Activity found to handle Intent',
      ),
    );
    await _pumpAuth(tester);

    await _tippeLink(tester, 'Datenschutzerklärung');

    expect(versuche, <String>[kPrivacyUrl]);
    expect(tester.takeException(), isNull,
        reason: 'die Ausnahme landete vorher in PlatformDispatcher.onError — '
            'ein Sentry-Ereignis ohne Nutzerbezug');
    expect(find.text(deL10n.authLegalLinkFailed(kPrivacyUrl)), findsOneWidget,
        reason: 'DSGVO Art. 13: der Text muss erreichbar bleiben, notfalls '
            'per Abtippen der URL');
    await _raeumeToastAb(tester);
  });

  testWidgets('ein false von launchUrl ist genauso ein Fehlschlag',
      (tester) async {
    // The second shape of "no handler": no exception, just `false`.
    final versuche = _fakeLauncher(tester, (_) async => false);
    await _pumpAuth(tester);

    await _tippeLink(tester, 'AGB');

    expect(versuche, <String>[kTermsUrl]);
    expect(find.text(deL10n.authLegalLinkFailed(kTermsUrl)), findsOneWidget,
        reason: 'der Rueckgabewert wurde vorher verworfen — der Tap tat '
            'sichtbar nichts');
    await _raeumeToastAb(tester);
  });
}
