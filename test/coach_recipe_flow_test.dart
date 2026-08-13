import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/models/coach_recipe_proposal.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/theme/app_theme.dart';

// Coach-Rezept-Generator (Spec 2026-08-12 + Nachtrag 2026-08-13):
//   * NUR /recipe ist ein Befehl (englisch, in beiden App-Sprachen);
//     unbekannte /-Befehle (auch das alte /rezept) gehen NIE ans Modell —
//     lokaler Hinweis statt verbranntem Tages-Slot.
//   * Befehls-Menue: "/" im Composer schlaegt /recipe mit lokalisierter
//     Beschreibung vor, Tap vervollstaendigt.
//   * Karte -> Sheet -> genau EIN onCreateRecipe mit den Haus-Regeln.
//   * „Hinzugefuegt" gilt nur, solange das Rezept noch existiert — Loeschen
//     im Rezepte-Tab aktiviert den Button wieder.
//   * Vorschlaege aus dem VERLAUF (chat_messages.recipe) bauen die Karte
//     nach einem Reload wieder auf.

const Size _usableSize = Size(402, 781);

/// 1x1-PNG fuer Image.memory in der Karte.
final Uint8List _pngBytes = base64Decode(
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

class _RecipeCoach extends CoachChatService {
  _RecipeCoach(super.client, super.userId);

  static _RecipeCoach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _RecipeCoach(client, 'user-123');
  }

  int sendCalls = 0;
  final List<({String wish, String locale})> recipeCalls =
      <({String wish, String locale})>[];

  /// Verlauf, den loadHistory liefert (fuer die Reload-Karten-Tests).
  List<ChatMessage> history = const <ChatMessage>[];

  /// Ohne Override liefert requestRecipe den Standard-Vorschlag.
  CoachRecipeReply Function(String sessionId)? recipeReply;

  @override
  Future<List<ChatSession>> loadSessions() async => <ChatSession>[
        ChatSession(
          id: 's1',
          title: 'Chat A',
          createdAt: DateTime(2026, 8, 1),
          lastMessageAt: DateTime(2026, 8, 12),
          messageCount: 0,
        ),
      ];

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  @override
  Future<List<ChatMessage>> loadHistory(String sessionId,
          {int limit = 100}) async =>
      history;

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
  }) async {
    sendCalls++;
    return CoachChatReply(
      reply: 'Antwort vom Coach.',
      refusal: false,
      sessionId: sessionId,
    );
  }

  @override
  Future<CoachRecipeReply> requestRecipe(
    String wish, {
    required String sessionId,
    required String locale,
    String? userContext,
  }) async {
    recipeCalls.add((wish: wish, locale: locale));
    final builder = recipeReply;
    if (builder != null) return builder(sessionId);
    return CoachRecipeReply(
      reply: 'Rezeptvorschlag: Huehnchenauflauf.',
      refusal: false,
      proposal: _proposal(imageBytes: _pngBytes),
      remaining: 4,
      dailyLimit: 5,
      sessionId: sessionId,
    );
  }
}

Future<void> _pumpCoach(
  WidgetTester tester, {
  required _RecipeCoach service,
  List<FitnessRecipe>? created,
  Set<String>? userRecipeSlugs,
  Locale locale = const Locale('de'),
}) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = _usableSize * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      locale: locale,
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: MediaQuery(
        data: MediaQueryData.fromView(tester.view).copyWith(
          disableAnimations: true,
        ),
        child: Scaffold(
          body: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            child: CoachChatScreen(
              service: service,
              userName: 'Moritz',
              // Die Schale spiegelt hier den HomeStore: createUserRecipe
              // macht das Rezept SOFORT sichtbar — deshalb wandert der Slug
              // im selben Zug in die Live-Slug-Sicht.
              onCreateRecipe: created == null
                  ? null
                  : (recipe) async {
                      created.add(recipe);
                      userRecipeSlugs?.add(recipe.slug);
                      return SyncDelivery.delivered;
                    },
              userRecipeSlugs: userRecipeSlugs ?? const <String>{},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('coach-input')), text);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('coach-send')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('/recipe ruft requestRecipe statt send und zeigt die Karte',
      (tester) async {
    final svc = _RecipeCoach.create();
    await _pumpCoach(tester, service: svc, created: <FitnessRecipe>[]);

    await _type(tester, '/recipe Huehnchenauflauf mit Bild');

    expect(svc.recipeCalls, hasLength(1));
    expect(svc.recipeCalls.single.wish, 'Huehnchenauflauf mit Bild');
    expect(svc.recipeCalls.single.locale, 'de');
    expect(svc.sendCalls, 0, reason: 'der Chat-Pfad bleibt unberuehrt');
    expect(find.byKey(const ValueKey('coach-recipe-card')), findsOneWidget);
    expect(find.text('Huehnchenauflauf'), findsOneWidget);
    // Die User-Blase zeigt die Original-Eingabe inkl. Befehl.
    expect(find.text('/recipe Huehnchenauflauf mit Bild'), findsOneWidget);
  });

  testWidgets('/recipe ohne Wunschtext: lokaler Hinweis, kein Request',
      (tester) async {
    final svc = _RecipeCoach.create();
    await _pumpCoach(tester, service: svc, created: <FitnessRecipe>[]);

    await _type(tester, '/recipe');

    expect(svc.recipeCalls, isEmpty, reason: 'kein Request = kein Slot');
    expect(find.textContaining('Sag mir, was'), findsOneWidget);
  });

  testWidgets(
      'unbekannte Befehle (auch das alte /rezept) gehen NIE ans Modell',
      (tester) async {
    final svc = _RecipeCoach.create();
    await _pumpCoach(tester, service: svc, created: <FitnessRecipe>[]);

    await _type(tester, '/rezept Huehnchenauflauf');

    expect(svc.recipeCalls, isEmpty);
    expect(svc.sendCalls, 0,
        reason: 'ein Tippo darf keinen Tages-Slot verbrennen');
    expect(find.textContaining('Unbekannter Befehl'), findsOneWidget);
  });

  testWidgets('Befehls-Menue: "/" schlaegt /recipe vor, Tap vervollstaendigt',
      (tester) async {
    final svc = _RecipeCoach.create();
    await _pumpCoach(tester, service: svc, created: <FitnessRecipe>[]);

    await tester.enterText(find.byKey(const ValueKey('coach-input')), '/');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('coach-command-menu')), findsOneWidget);
    expect(find.text('/recipe'), findsOneWidget);
    expect(
      find.text('Erstellt ein neues Rezept mit passendem Bild'),
      findsOneWidget,
      reason: 'die Kurzbeschreibung folgt der App-Sprache (hier de)',
    );

    await tester.tap(find.byKey(const ValueKey('coach-command-recipe')));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('coach-input')),
    );
    expect(field.controller?.text, '/recipe ');

    // Normaler Text und Nicht-Praefixe zeigen kein Menue.
    await tester.enterText(
        find.byKey(const ValueKey('coach-input')), 'hallo Coach');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('coach-command-menu')), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('coach-input')), '/x');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('coach-command-menu')), findsNothing);
  });

  testWidgets('Befehls-Beschreibung unter en folgt der App-Sprache',
      (tester) async {
    final svc = _RecipeCoach.create();
    await _pumpCoach(
      tester,
      service: svc,
      created: <FitnessRecipe>[],
      locale: const Locale('en'),
    );

    await tester.enterText(find.byKey(const ValueKey('coach-input')), '/');
    await tester.pumpAndSettle();
    expect(
      find.text('Creates a new recipe with a matching photo'),
      findsOneWidget,
    );
  });

  testWidgets(
      'Bestaetigen speichert einmal; Loeschen im Rezepte-Tab reaktiviert den Button',
      (tester) async {
    final svc = _RecipeCoach.create()
      // Ohne Bild-Bytes: der Speicherpfad braucht dann keinen
      // RecipeImageStore (Plugin-Channel) — das Bild testet der Karten-Test.
      ..recipeReply = (sessionId) => CoachRecipeReply(
            reply: 'Rezeptvorschlag: Huehnchenauflauf.',
            refusal: false,
            proposal: _proposal(),
            remaining: 4,
            dailyLimit: 5,
            sessionId: sessionId,
          );
    final created = <FitnessRecipe>[];
    final slugs = <String>{};
    await _pumpCoach(
      tester,
      service: svc,
      created: created,
      userRecipeSlugs: slugs,
    );

    await _type(tester, '/recipe Huehnchenauflauf');
    await tester.tap(find.byKey(const ValueKey('coach-recipe-add')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('coach-recipe-sheet')), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('coach-recipe-sheet-confirm')),
    );
    await tester.tap(find.byKey(const ValueKey('coach-recipe-sheet-confirm')));
    await tester.pumpAndSettle();

    expect(created, hasLength(1));
    final recipe = created.single;
    expect(recipe.slug, startsWith('user_coach_'),
        reason: 'deterministischer Karten-Slug statt user_<ms> (Spec 2026-08-13)');
    expect(recipe.userCreated, isTrue);
    expect(recipe.categories, const <String>['Eigene']);
    expect(recipe.imageAsset, isEmpty, reason: 'kein Bild -> kein local:-Ref');
    expect(find.textContaining('gespeichert'), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-recipe-add')), findsNothing,
        reason: 'Doppel-Add gesperrt, solange das Rezept existiert');
    expect(find.text('Hinzugefügt'), findsOneWidget);

    // Nutzer loescht das Rezept im Rezepte-Tab: die Live-Slug-Sicht der
    // Schale verliert den Slug, der naechste Build reaktiviert den Button.
    slugs.remove(recipe.slug);
    await _pumpCoach(
      tester,
      service: svc,
      created: created,
      userRecipeSlugs: slugs,
    );
    expect(find.text('Hinzugefügt'), findsNothing,
        reason: 'ein geloeschtes Rezept darf nicht als hinzugefuegt gelten');
    expect(find.byKey(const ValueKey('coach-recipe-add')), findsOneWidget);
  });

  testWidgets(
      'Neustart: Verlaufs-Karte kennt „Hinzugefügt", solange das Rezept existiert',
      (tester) async {
    // DER Bug der Spec 2026-08-13: Karte aus dem Verlauf + Rezept existiert
    // noch -> frueher fragte die Karte erneut. Der Slug ist jetzt aus der
    // Message-Id ableitbar, die In-Memory-Map ist weg.
    final svc = _RecipeCoach.create()
      ..history = <ChatMessage>[
        ChatMessage(
          id: 'srv-msg-1',
          role: ChatRole.assistant,
          content: 'Rezeptvorschlag: Huehnchenauflauf.',
          createdAt: DateTime(2026, 8, 12, 18),
          recipeProposal: _proposal(),
        ),
      ];
    final slugs = <String>{FitnessRecipe.coachProposalSlug('srv-msg-1')};
    await _pumpCoach(
      tester,
      service: svc,
      created: <FitnessRecipe>[],
      userRecipeSlugs: slugs,
    );

    expect(find.byKey(const ValueKey('coach-recipe-card')), findsOneWidget);
    expect(find.text('Hinzugefügt'), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-recipe-add')), findsNothing,
        reason: 'das Rezept existiert noch — kein zweites Angebot');

    // Loeschen im Rezepte-Tab reaktiviert den Button (Live-Sicht).
    slugs.clear();
    await _pumpCoach(
      tester,
      service: svc,
      created: <FitnessRecipe>[],
      userRecipeSlugs: slugs,
    );
    expect(find.byKey(const ValueKey('coach-recipe-add')), findsOneWidget);
    expect(find.text('Hinzugefügt'), findsNothing);
  });

  testWidgets('Abbrechen im Sheet speichert nichts', (tester) async {
    final svc = _RecipeCoach.create()
      ..recipeReply = (sessionId) => CoachRecipeReply(
            reply: 'Rezeptvorschlag: Huehnchenauflauf.',
            refusal: false,
            proposal: _proposal(),
            sessionId: sessionId,
          );
    final created = <FitnessRecipe>[];
    await _pumpCoach(tester, service: svc, created: created);

    await _type(tester, '/recipe Huehnchenauflauf');
    await tester.tap(find.byKey(const ValueKey('coach-recipe-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();

    expect(created, isEmpty);
    expect(find.byKey(const ValueKey('coach-recipe-add')), findsOneWidget,
        reason:
            'der Button bleibt aktiv, der Nutzer kann es sich anders ueberlegen');
  });

  testWidgets('Refusal bleibt eine Text-Blase ohne Karte', (tester) async {
    final svc = _RecipeCoach.create()
      ..recipeReply = (sessionId) => CoachRecipeReply(
            reply: 'Ich erstelle nur Essensrezepte.',
            refusal: true,
            sessionId: sessionId,
          );
    await _pumpCoach(tester, service: svc, created: <FitnessRecipe>[]);

    await _type(tester, '/recipe Schreib meine Hausaufgaben');

    expect(find.byKey(const ValueKey('coach-recipe-card')), findsNothing);
    expect(find.text('Ich erstelle nur Essensrezepte.'), findsOneWidget);
  });

  testWidgets(
      'Reload-Karte: ein Vorschlag aus dem VERLAUF rendert mit aktivem Button',
      (tester) async {
    // Nachtrag 2026-08-13: chat_messages.recipe traegt das Rezept-JSON —
    // fromRow baut das Proposal (ohne Bytes), die Karte erscheint nach dem
    // Neustart wieder. Bild fehlt (kein Store im Test) -> Platzhalter.
    final svc = _RecipeCoach.create()
      ..history = <ChatMessage>[
        ChatMessage(
          id: 'srv-msg-1',
          role: ChatRole.assistant,
          content: 'Rezeptvorschlag: Huehnchenauflauf.',
          createdAt: DateTime(2026, 8, 12, 18),
          recipeProposal: _proposal(),
        ),
      ];
    await _pumpCoach(tester, service: svc, created: <FitnessRecipe>[]);

    expect(find.byKey(const ValueKey('coach-recipe-card')), findsOneWidget);
    expect(find.text('Huehnchenauflauf'), findsOneWidget);
    final button = find.byKey(const ValueKey('coach-recipe-add'));
    expect(button, findsOneWidget,
        reason: 'die Option zum Hinzufuegen ueberlebt den Reload');
  });
}
