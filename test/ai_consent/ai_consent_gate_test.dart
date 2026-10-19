// `ensureAiConsent` itself (review 2026-10-19, P1): outside the app shell
// there is nothing to ask, inside it an unbound account fails closed, a
// known consent never shows the sheet, two callers share one sheet, and the
// app installs the scope above its Navigator with the shell's account bound.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/main.dart';
import 'package:eatova/src/app/ai_trust.dart';
import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/widgets/shared/ai_consent_sheet.dart';

import '../support/ai_trust_fakes.dart';
import '../support/harness.dart';

final Finder _consentSheet = find.byKey(const ValueKey('ai-consent-sheet'));

Future<BuildContext> _mount(
  WidgetTester tester,
  Widget Function(Widget) wrap,
) async {
  late BuildContext captured;
  await tester.pumpWidget(
    wrap(
      localizedApp(
        Builder(
          builder: (context) {
            captured = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return captured;
}

void main() {
  testWidgets('ohne App-Huelle (Widget-Tests, Vorschau) gibt es nichts zu '
      'fragen', (tester) async {
    final context = await _mount(tester, (app) => app);
    expect(aiConsentSettled(context), isTrue);
    expect(await ensureAiConsent(context), isTrue);
    expect(_consentSheet, findsNothing);
  });

  testWidgets('ohne gebundenes Konto geht nichts raus', (tester) async {
    final context = await _mount(tester, (app) => withAiTrust(null, app));
    expect(aiConsentSettled(context), isFalse);
    expect(await ensureAiConsent(context), isFalse);
    expect(_consentSheet, findsNothing);
  });

  testWidgets('die Vorschau ohne Sync fragt nie', (tester) async {
    final preview = AiTrustController.preview();
    final context = await _mount(tester, (app) => withAiTrust(preview, app));
    expect(await ensureAiConsent(context), isTrue);
  });

  testWidgets('eine bekannte Einwilligung zeigt kein Blatt', (tester) async {
    final controller = await aiTrustController(
      log: FakeAiTrustLog(rows: [grantedRecord()]),
    );
    final context = await _mount(tester, (app) => withAiTrust(controller, app));
    expect(aiConsentSettled(context), isTrue);
    expect(await ensureAiConsent(context), isTrue);
    expect(_consentSheet, findsNothing);
  });

  testWidgets('zwei Aufrufe teilen sich ein Blatt und eine Antwort', (
    tester,
  ) async {
    final log = FakeAiTrustLog();
    final controller = await aiTrustController(log: log);
    final context = await _mount(tester, (app) => withAiTrust(controller, app));

    final first = ensureAiConsent(context);
    final second = ensureAiConsent(context);
    await tester.pumpAndSettle();
    expect(_consentSheet, findsOneWidget);

    final check = find.byKey(const ValueKey('ai-consent-health-check'));
    await tester.ensureVisible(check);
    await tester.tap(check);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-consent-accept')));
    await tester.pumpAndSettle();

    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(log.rows, hasLength(1));
  });

  testWidgets('Wegwischen ist "Nicht jetzt"', (tester) async {
    final log = FakeAiTrustLog();
    final controller = await aiTrustController(log: log);
    final context = await _mount(tester, (app) => withAiTrust(controller, app));

    final asked = ensureAiConsent(context);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-consent-close')));
    await tester.pumpAndSettle();

    expect(await asked, isFalse);
    expect(log.rows, isEmpty);
  });

  testWidgets('ein haengender Cache blockiert den Knopf nicht: nach der '
      'Frist kommt das Blatt', (tester) async {
    final controller = AiTrustController(
      cache: _HangingCache(),
      consentLog: FakeAiTrustLog(),
      reportLog: FakeAiTrustLog(),
    );
    final context = await _mount(tester, (app) => withAiTrust(controller, app));

    final asked = ensureAiConsent(context);
    await tester.pump(kAiConsentReadyBudget);
    await tester.pumpAndSettle();
    expect(_consentSheet, findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai-consent-not-now')));
    await tester.pumpAndSettle();
    expect(await asked, isFalse);
  });

  testWidgetsRobust('die App stellt den Scope ueber den Navigator und die '
      'Huelle bindet ihr Konto', (tester) async {
    await tester.pumpWidget(const EatovaApp());
    await tester.pumpAndSettle();

    expect(find.byType(AiTrustScope), findsOneWidget);
    final home = tester.element(find.byType(EatovaHomePage));
    final binding = AiTrustScope.maybeOf(home);
    expect(binding, isNotNull);
    // Preview (no sync in this test): a bound controller that asks nothing.
    expect(binding!.controller, isNotNull);
    expect(binding.controller!.consentRequired, isFalse);
    // The scope sits above the MaterialApp, so a route context finds it too.
    final navigator = tester.element(find.byType(Navigator).first);
    expect(AiTrustScope.maybeOf(navigator), same(binding));
  });
}

class _HangingCache implements AiConsentCache {
  @override
  Future<Never> readAiConsent() => Completer<Never>().future;

  @override
  Future<void> writeAiConsent(_) async {}
}
