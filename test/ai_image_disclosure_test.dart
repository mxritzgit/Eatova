// KI-Kennzeichnung der Rezeptbilder (2026-09-01).
//
// Two halves of one contradiction, both pinned here:
//
//   * The 30 catalog images in `assets/recipes/` are AI-generated and carry a
//     burnt-in "AI Generated" badge; the imprint on eatova.de says so. The
//     recipe header used to advertise them as "echte Bilder" / "real photos"
//     one line above that grid. The wording guard for that half lives in
//     `repo_rules_test.dart` (it reads the ARB, no widget involved).
//
//   * The coach generates its recipe images at RUNTIME, and its image prompt
//     asks for no watermark — so those pictures carry no mark at all. This
//     suite is the behaviour half: the badge must be there at BOTH display
//     places, in both display modes and both languages, reachable by a screen
//     reader, and it sits on the photo instead of pushing the card apart.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/models/coach_recipe_proposal.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/sync_error_messages.dart';

import 'support/harness.dart';

const Size _viewport = Size(402, 781);

final Finder _badge = find.byKey(const ValueKey('coach-recipe-ai-badge'));
final Finder _card = find.byKey(const ValueKey('coach-recipe-card'));
final Finder _sheet = find.byKey(const ValueKey('coach-recipe-sheet'));

/// 1x1 PNG — enough for `Image.memory`; every size assertion below is about
/// the BOX, which comes from the layout, not from the decoded pixels.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

CoachRecipeProposal _proposal({Uint8List? imageBytes}) => CoachRecipeProposal(
  title: 'Huehnchenauflauf',
  description: 'Cremig und proteinreich.',
  portion: '1 grosse Portion',
  ingredients: '- 250 g Haehnchenbrust',
  preparation: '1. Ofen vorheizen.',
  caloriesKcal: 520,
  proteinG: 48,
  carbsG: 32,
  fatG: 18,
  estimatedGrams: 450,
  imageBytes: imageBytes,
);

/// Serves ONE assistant message that already carries the proposal. Going
/// through the history instead of typing `/recipe` keeps this suite on the
/// rendering it is about — the request path has its own suite
/// (coach_recipe_flow_test.dart).
class _HistoryCoach extends CoachChatService {
  _HistoryCoach(super.client, super.userId);

  static _HistoryCoach create({Uint8List? imageBytes}) {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _HistoryCoach(client, 'user-123')..bytes = imageBytes;
  }

  Uint8List? bytes;

  @override
  Future<List<ChatSession>> loadSessions() async => <ChatSession>[
    ChatSession(
      id: 's1',
      title: 'Chat A',
      createdAt: DateTime(2026, 9, 1),
      lastMessageAt: DateTime(2026, 9, 1),
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
    ChatMessage(
      id: 'srv-msg-1',
      role: ChatRole.assistant,
      content: 'Rezeptvorschlag: Huehnchenauflauf.',
      createdAt: DateTime(2026, 9, 1, 18),
      recipeProposal: _proposal(imageBytes: bytes),
    ),
  ];

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async =>
      const ChatQuotaSnapshot(used: 0, remaining: 5, dailyLimit: 5);
}

Future<BuildContext> _pumpCoach(
  WidgetTester tester, {
  Uint8List? imageBytes,
  Locale locale = const Locale('de'),
  Brightness brightness = Brightness.dark,
  double textScale = 1.0,
}) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = _viewport * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  return pumpLocalizedContext(
    tester,
    CoachChatScreen(
      service: _HistoryCoach.create(imageBytes: imageBytes),
      userName: 'Moritz',
      onCreateRecipe: (recipe) async => SyncDelivery.delivered,
      userRecipeSlugs: const <String>{},
    ),
    locale: locale,
    brightness: brightness,
    textScale: textScale,
    // The coach tab owns its gutters (the shell passes no padding).
    padding: EdgeInsets.zero,
    safeArea: false,
    settle: true,
  );
}

/// Opens the confirmation sheet from the rendered card.
Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('coach-recipe-add')));
  await tester.pumpAndSettle();
  expect(_sheet, findsOneWidget);
}

/// The badge inside [host] (card or sheet): from the ARB, an opaque
/// forest/onForest pill (the photo underneath is arbitrarily bright or dark,
/// so a translucent scrim would lose in one of the two modes), and laid OVER
/// the photo, not stacked into the column where it would push the card apart.
void _expectBadgeOnPhoto(WidgetTester tester, Finder host, RenderCase c) {
  final abzeichen = find.descendant(of: host, matching: _badge);
  expect(abzeichen, findsOneWidget);
  final text = tester.widget<Text>(
    find.descendant(of: abzeichen, matching: find.byType(Text)),
  );
  expect(text.data, c.l10n.coachRecipeAiImageBadge);
  // Not `decorationOf`: that helper reads the first Container BELOW its
  // finder, and here the key sits ON the Container.
  final pille =
      tester.widget<Container>(abzeichen).decoration! as BoxDecoration;
  expect(pille.color, c.t.forest);
  expect(text.style?.color, c.t.onForest);

  final bild = tester.getRect(
    find.descendant(of: host, matching: find.byType(Image)),
  );
  final abzeichenRect = tester.getRect(abzeichen);
  expect(
    bild.contains(abzeichenRect.topLeft) &&
        bild.contains(abzeichenRect.bottomRight - const Offset(1, 1)),
    isTrue,
    reason: 'das Abzeichen muss INNERHALB des Bildes sitzen '
        '($abzeichenRect vs. $bild)',
  );
}

void main() {
  renderMatrix(
    'Karte und Bestaetigungs-Sheet kennzeichnen das KI-Bild',
    (tester, c) async {
      await _pumpCoach(
        tester,
        imageBytes: _png,
        locale: c.locale,
        brightness: c.brightness,
      );
      expect(_card, findsOneWidget);
      _expectBadgeOnPhoto(tester, _card, c);

      await _openSheet(tester);
      _expectBadgeOnPhoto(tester, _sheet, c);
    },
    locales: const <Locale>[Locale('de'), Locale('en')],
    brightnesses: bothBrightnesses,
  );

  testWidgets('ohne Bildbytes gibt es kein Abzeichen (nichts zu kennzeichnen)',
      (tester) async {
    // A proposal reloaded from chat_messages.recipe carries no bytes; the
    // card then shows the striped placeholder, and there is no AI image to
    // declare.
    await _pumpCoach(tester);

    expect(_card, findsOneWidget);
    expect(_badge, findsNothing);
  });

  group('Barrierefreiheit', () {
    // PR #53 wrote down the trap: `excludeSemantics` swallows the labels and
    // actions of everything below it. The badge is a plain `Text` and lands in
    // no such tree today — but the claim worth pinning is not "it has a node
    // of its own", it is "a screen reader reads it out".
    //
    // It has no node of its own either: the card folds into ONE node
    // ("REZEPTVORSCHLAG / KI-Bild / Huehnchenauflauf / 520 kcal … / Rezept
    // hinzufuegen"), which is why `find.bySemanticsLabel` — an EXACT match on
    // a node label — is the wrong instrument here and `getSemantics` (the
    // nearest node above the finder, as in a11y_headings_test.dart) is the
    // right one. An exclusion above the bubble drops the word from that label
    // and turns this red.
    testWidgets('der Screenreader erreicht das Abzeichen an beiden Stellen', (
      tester,
    ) async {
      // Disposed by hand, not via addTearDown: the runner verifies the handle
      // at the END OF THE BODY, before tear-downs run.
      final handle = tester.ensureSemantics();

      final context = await _pumpCoach(tester, imageBytes: _png);
      final label = context.l10n.coachRecipeAiImageBadge;

      final karte = tester
          .getSemantics(find.descendant(of: _card, matching: find.text(label)))
          .label;

      await _openSheet(tester);
      final sheet = tester
          .getSemantics(find.descendant(of: _sheet, matching: find.text(label)))
          .label;
      handle.dispose();

      expect(
        karte,
        contains(label),
        reason: 'die Karte muss ihr KI-Bild auch ansagen, nicht nur zeigen',
      );
      expect(
        sheet,
        contains(label),
        reason: 'im Sheet ebenso — es ist dieselbe Aussage ueber dasselbe Bild',
      );
    });
  });

  // The pill is pinned on BOTH sides inside the photo, so at double text size
  // it wraps into the picture instead of running off it. renderMatrix fails
  // the case on any layout error by itself.
  renderMatrix(
    'Karte und Sheet ueberstehen doppelte Schrift',
    (tester, c) async {
      await _pumpCoach(
        tester,
        imageBytes: _png,
        locale: c.locale,
        brightness: c.brightness,
        textScale: c.textScale,
      );
      expect(find.descendant(of: _card, matching: _badge), findsOneWidget);

      await _openSheet(tester);
      expect(find.descendant(of: _sheet, matching: _badge), findsOneWidget);
    },
    brightnesses: const <Brightness>[Brightness.dark],
    textScales: const <double>[2.0],
  );
}
