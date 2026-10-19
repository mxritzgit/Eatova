// Coach and the AI consent (review 2026-10-19, P1): no question, /recipe,
// /plan or /log reaches coach-chat before the account consented, "Not now"
// sends nothing and keeps the draft, and a coach answer can be reported by
// id and reason only.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/app/ai_trust.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/ai_consent.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/models/coach_recipe_proposal.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';

import '../support/ai_trust_fakes.dart';
import '../support/harness.dart';

/// One conversation with one coach answer; records every send.
class _RecordingCoach extends CoachChatService {
  _RecordingCoach(super.client, super.userId);

  static _RecordingCoach create({bool recipeCard = false}) {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _RecordingCoach(client, 'user-123')..recipeCard = recipeCard;
  }

  bool recipeCard = false;

  final List<String> sends = <String>[];

  @override
  Future<List<ChatSession>> loadSessions() async => <ChatSession>[
    ChatSession(
      id: 's1',
      title: 'Chat A',
      createdAt: DateTime(2026, 10, 19),
      lastMessageAt: DateTime(2026, 10, 19),
      messageCount: 1,
    ),
  ];

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  @override
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async => <ChatMessage>[
    if (recipeCard)
      ChatMessage(
        id: '7f1c2b9e-0000-4000-8000-0000000000aa',
        role: ChatRole.assistant,
        content: 'Rezeptvorschlag: Linsensuppe.',
        createdAt: DateTime(2026, 10, 19, 18),
        recipeProposal: CoachRecipeProposal(
          title: 'Linsensuppe',
          description: 'Warm und satt.',
          portion: '1 Teller',
          ingredients: '- 80 g Linsen',
          preparation: '1. Kochen.',
          caloriesKcal: 420,
          proteinG: 24,
          carbsG: 50,
          fatG: 9,
          estimatedGrams: 400,
          imageBytes: _png,
        ),
      )
    else
      ChatMessage(
        id: '7f1c2b9e-0000-4000-8000-000000000001',
        role: ChatRole.assistant,
        content: 'Iss mehr Gemuese zum Abendessen.',
        createdAt: DateTime(2026, 10, 19, 18),
      ),
  ];

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async =>
      const ChatQuotaSnapshot(used: 0, remaining: 5, dailyLimit: 5);

  @override
  Future<CoachChatReply> send(
    String message, {
    required String sessionId,
    String? imageBase64,
    String? imageMimeType,
    String? userContext,
    void Function(String text)? onPartialReply,
  }) async {
    sends.add(message);
    return const CoachChatReply(
      reply: 'Gern.',
      refusal: false,
      sessionId: 's1',
      remaining: 4,
      dailyLimit: 5,
    );
  }

  @override
  Future<CoachRecipeReply> requestRecipe(
    String wish, {
    required String sessionId,
    required String locale,
  }) async {
    sends.add('/recipe $wish');
    return const CoachRecipeReply(
      reply: 'Dazu habe ich gerade kein Rezept.',
      refusal: true,
      sessionId: 's1',
      remaining: 4,
      dailyLimit: 5,
    );
  }
}

final Finder _consentSheet = find.byKey(const ValueKey('ai-consent-sheet'));

/// 1x1 PNG for the generated recipe picture.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);
final Finder _input = find.byKey(const ValueKey('coach-input'));

Future<_RecordingCoach> _pumpCoach(
  WidgetTester tester,
  AiTrustController controller, {
  bool recipeCard = false,
}) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = const Size(402, 860) * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final coach = _RecordingCoach.create(recipeCard: recipeCard);
  await tester.pumpWidget(
    withAiTrust(
      controller,
      localizedApp(
        CoachChatScreen(service: coach, userName: 'Moritz'),
        padding: EdgeInsets.zero,
        safeArea: false,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return coach;
}

/// Long-press the answer and pick "Report answer" from its selection menu.
/// The test font draws every glyph a full em wide, so the label can land in
/// the toolbar's overflow; then the overflow opens first, as on a narrow
/// phone.
Future<void> _reportViaMenu(WidgetTester tester) async {
  await tester.longPress(find.text('Iss mehr Gemuese zum Abendessen.'));
  await tester.pumpAndSettle();
  if (find.text(deL10n.coachReportAction).evaluate().isEmpty) {
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text(deL10n.coachReportAction));
  await tester.pumpAndSettle();
}

Future<void> _typeAndSend(WidgetTester tester, String text) async {
  await tester.enterText(_input, text);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('coach-send')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('ohne Einwilligung fragt der Coach zuerst; "Nicht jetzt" '
      'sendet nichts und laesst den Entwurf stehen', (tester) async {
    final log = FakeAiTrustLog();
    final controller = await aiTrustController(log: log);
    final coach = await _pumpCoach(tester, controller);

    await _typeAndSend(tester, 'Was soll ich heute essen?');

    expect(_consentSheet, findsOneWidget);
    expect(coach.sends, isEmpty);

    await tester.tap(find.byKey(const ValueKey('ai-consent-not-now')));
    await tester.pumpAndSettle();

    expect(_consentSheet, findsNothing);
    expect(coach.sends, isEmpty);
    expect(log.rows, isEmpty, reason: 'declining logs nothing');
    expect(
      tester.widget<TextField>(_input).controller!.text,
      'Was soll ich heute essen?',
    );
  });

  testWidgets('/recipe geht denselben Weg: ohne Haken kein Weiter, mit Haken '
      'erst der Log-Eintrag, dann die Anfrage', (tester) async {
    final log = FakeAiTrustLog();
    final controller = await aiTrustController(log: log);
    final coach = await _pumpCoach(tester, controller);

    await _typeAndSend(tester, '/recipe Linsensuppe');
    expect(_consentSheet, findsOneWidget);

    // The health data checkbox starts unticked; the action is locked.
    await tester.tap(find.byKey(const ValueKey('ai-consent-accept')));
    await tester.pumpAndSettle();
    expect(_consentSheet, findsOneWidget);
    expect(log.rows, isEmpty);

    await tester.ensureVisible(
      find.byKey(const ValueKey('ai-consent-health-check')),
    );
    await tester.tap(find.byKey(const ValueKey('ai-consent-health-check')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-consent-accept')));
    await tester.pumpAndSettle();

    expect(_consentSheet, findsNothing);
    expect(log.rows.single.granted, isTrue);
    expect(log.rows.single.healthData, isTrue);
    expect(controller.allowsAi, isTrue);
    expect(coach.sends, ['/recipe Linsensuppe']);
    expect(tester.widget<TextField>(_input).controller!.text, isEmpty);
  });

  testWidgets('scheitert der Log-Eintrag, geht nichts raus', (tester) async {
    final log = FakeAiTrustLog()..failWrites = true;
    final controller = await aiTrustController(log: log);
    final coach = await _pumpCoach(tester, controller);

    await _typeAndSend(tester, 'Hallo Coach');
    final check = find.byKey(const ValueKey('ai-consent-health-check'));
    await tester.ensureVisible(check);
    await tester.tap(check);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-consent-accept')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('ai-consent-error')), findsOneWidget);
    expect(_consentSheet, findsOneWidget);
    expect(coach.sends, isEmpty);

    await tester.tap(find.byKey(const ValueKey('ai-consent-not-now')));
    await tester.pumpAndSettle();
    expect(coach.sends, isEmpty);
    expect(controller.allowsAi, isFalse);
  });

  testWidgets('mit Einwilligung geht die Frage ohne Blatt raus', (
    tester,
  ) async {
    final log = FakeAiTrustLog(rows: [grantedRecord()]);
    final controller = await aiTrustController(log: log);
    final coach = await _pumpCoach(tester, controller);

    await _typeAndSend(tester, 'Hallo Coach');

    expect(_consentSheet, findsNothing);
    expect(coach.sends, ['Hallo Coach']);
  });

  testWidgets('ohne gebundenes Konto geht nichts raus (fail closed)', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(402, 860) * 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final coach = _RecordingCoach.create();
    await tester.pumpWidget(
      withAiTrust(
        null,
        localizedApp(
          CoachChatScreen(service: coach, userName: 'Moritz'),
          padding: EdgeInsets.zero,
          safeArea: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _typeAndSend(tester, 'Hallo Coach');

    expect(coach.sends, isEmpty);
    expect(_consentSheet, findsNothing);
  });

  group('Antwort melden', () {
    testWidgets('Long-Press-Menue -> Grund -> nur ID, Sitzung und Grund', (
      tester,
    ) async {
      final log = FakeAiTrustLog(rows: [grantedRecord()]);
      final controller = await aiTrustController(log: log);
      await _pumpCoach(tester, controller);

      await _reportViaMenu(tester);

      expect(find.byKey(const ValueKey('ai-report-sheet')), findsOneWidget);
      // Nothing is filed before a reason is picked.
      await tester.tap(find.byKey(const ValueKey('ai-report-submit')));
      await tester.pumpAndSettle();
      expect(log.reports, isEmpty);

      await tester.tap(find.byKey(const ValueKey('ai-report-reason-harmful')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-report-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('ai-report-sheet')), findsNothing);
      expect(find.text(deL10n.coachReportDone), findsOneWidget);
      final report = log.reports.single;
      expect(report.messageId, '7f1c2b9e-0000-4000-8000-000000000001');
      expect(report.sessionId, 's1');
      expect(report.target, AiReportTarget.answer);
      expect(report.reason, AiReportReason.harmful);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('ein Fehler bleibt im Blatt und meldet nichts als erledigt', (
      tester,
    ) async {
      final log = FakeAiTrustLog(rows: [grantedRecord()])..failReports = true;
      final controller = await aiTrustController(log: log);
      await _pumpCoach(tester, controller);

      await _reportViaMenu(tester);
      await tester.tap(find.byKey(const ValueKey('ai-report-reason-other')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-report-submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('ai-report-error')), findsOneWidget);
      expect(find.text(deL10n.coachReportDone), findsNothing);
    });

    testWidgets('das generierte Rezeptbild laesst sich per Long-Press melden', (
      tester,
    ) async {
      final log = FakeAiTrustLog(rows: [grantedRecord()]);
      final controller = await aiTrustController(log: log);
      await _pumpCoach(tester, controller, recipeCard: true);

      final image = find.byKey(const ValueKey('coach-recipe-image-report'));
      await tester.ensureVisible(image);
      await tester.pumpAndSettle();
      await tester.longPress(image);
      await tester.pumpAndSettle();

      expect(find.text(deL10n.coachReportImageTitle), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('ai-report-reason-inappropriate')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-report-submit')));
      await tester.pumpAndSettle();

      final report = log.reports.single;
      expect(report.messageId, '7f1c2b9e-0000-4000-8000-0000000000aa');
      expect(report.target, AiReportTarget.recipeImage);
      expect(report.reason, AiReportReason.inappropriate);
      expect(find.text(deL10n.coachReportImageDone), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('Screenreader erreichen Melden als eigene Aktion', (
      tester,
    ) async {
      final controller = await aiTrustController(
        log: FakeAiTrustLog(rows: [grantedRecord()]),
      );
      await _pumpCoach(tester, controller);

      final melden = find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            (widget.properties.customSemanticsActions?.keys.any(
                  (action) => action.label == deL10n.coachReportAction,
                ) ??
                false),
      );
      expect(melden, findsOneWidget);
      expect(
        find.descendant(
          of: melden,
          matching: find.text('Iss mehr Gemuese zum Abendessen.'),
        ),
        findsOneWidget,
      );
    });
  });
}
