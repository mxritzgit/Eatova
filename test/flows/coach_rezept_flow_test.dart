// Coach -> recipe flow: ask a normal question, read the answer, then let
// `/recipe` produce a proposal card, confirm it in the sheet and find the
// recipe again in the recipes tab under "Eigene" and on its detail page.
//
// The coach has NO write rights on meals (coach_recipe.dart): the shell's
// `onCreateRecipe` is the only way anything leaves the chat, so the recipes
// tab's `onAddMeal` must stay untouched by this flow — asserted at the end.
//
// Why a shell instead of `EatovaApp`: the coach service comes from
// `EatovaSync.forUser` (no injection point on EatovaApp/EatovaHomePage) and
// both `onCreateRecipe` hooks are null while `sync == null`, which is exactly
// the preview mode the flow tests run in. The shell therefore mirrors
// eatova_home_page's wiring around the two REAL screens: one shared user-recipe
// list, a new list identity per mutation (RecipesScreen.didUpdateWidget checks
// identity), and TickerMode on the hidden tab.
//
// `disableAnimations` keeps the CoachOrb static (coach_orb.dart honours reduce
// motion); every wait is still a BOUNDED pump loop, never pumpAndSettle.
// Runs in English.

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
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/sync_error_messages.dart';
import 'package:eatova/src/theme/app_theme.dart';

import 'flow_test_helpers.dart';

const String _question = 'What should I cook tonight?';
const String _answer = 'Something with chicken and rice.';
const String _wish = 'a high protein chicken bake';

/// Server id of the assistant answer. The card slug is derived from it
/// (`FitnessRecipe.coachProposalSlug`), so the recipes tab has a deterministic
/// ValueKey to look for.
const String _assistantId = 'srv-msg-1';
final String _slug = FitnessRecipe.coachProposalSlug(_assistantId);

/// Deliberately WITHOUT image bytes: the save path would otherwise write
/// through `RecipeImageStore` and hit a platform channel. The card's
/// placeholder is covered by test/coach_recipe_flow_test.dart.
const CoachRecipeProposal _proposal = CoachRecipeProposal(
  title: 'Protein Chicken Bake',
  description: 'Creamy, high in protein.',
  portion: '1 large portion',
  ingredients: '- 250 g chicken breast',
  preparation: '1. Preheat the oven.',
  caloriesKcal: 520,
  proteinG: 48,
  carbsG: 32,
  fatG: 18,
  estimatedGrams: 450,
);

/// In-memory coach: plain chat answers plus one recipe proposal.
class _FlowCoach extends CoachChatService {
  _FlowCoach(super.client, super.userId);

  /// `stopAutoRefresh()` is mandatory: GoTrue starts a periodic timer in its
  /// constructor that fails every widget test.
  static _FlowCoach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _FlowCoach(client, 'user-coach-recipe-flow');
  }

  int sendCalls = 0;
  final List<({String wish, String locale})> recipeCalls =
      <({String wish, String locale})>[];

  @override
  Future<List<ChatSession>> loadSessions() async => <ChatSession>[
        ChatSession(
          id: 's1',
          title: 'Evening plan',
          createdAt: DateTime(2026, 8, 28),
          lastMessageAt: DateTime(2026, 8, 28),
          messageCount: 0,
        ),
      ];

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  @override
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async =>
      const <ChatMessage>[];

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
    sendCalls++;
    return CoachChatReply(
      reply: _answer,
      refusal: false,
      remaining: 4,
      dailyLimit: 5,
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
    return CoachRecipeReply(
      reply: 'Recipe suggestion: Protein Chicken Bake.',
      refusal: false,
      proposal: _proposal,
      remaining: 3,
      dailyLimit: 5,
      sessionId: sessionId,
      assistantMessageId: _assistantId,
    );
  }
}

/// What the shell recorded — read by the assertions.
class _Mitschrift {
  final List<FitnessRecipe> created = <FitnessRecipe>[];
  final List<String> deleted = <String>[];

  /// Every meal the RECIPES tab logged. The coach must never fill this.
  final List<MealSlot> loggedSlots = <MealSlot>[];
}

/// Two-tab shell around the real screens, wired like `eatova_home_page.dart`.
class _CoachRecipeShell extends StatefulWidget {
  const _CoachRecipeShell({required this.service, required this.log});

  final CoachChatService service;
  final _Mitschrift log;

  @override
  State<_CoachRecipeShell> createState() => _CoachRecipeShellState();
}

class _CoachRecipeShellState extends State<_CoachRecipeShell> {
  int _tab = 0;

  /// Mirror of `HomeStore.userRecipes`: reassigned per mutation, so identity
  /// is the "something changed" fingerprint RecipesScreen relies on.
  List<FitnessRecipe> _userRecipes = const <FitnessRecipe>[];

  /// Mirror of `HomeStore.pendingRecipeDeletes` (2026-09-02): slugs inside
  /// the recipes tab's undo window. The coach gets `visibleUserRecipes`.
  final Set<String> _pendingDeletes = <String>{};

  void _setPending(String slug, {required bool pending}) {
    setState(() {
      if (pending) {
        _pendingDeletes.add(slug);
      } else {
        _pendingDeletes.remove(slug);
      }
    });
  }

  Future<SyncDelivery> _create(FitnessRecipe recipe) async {
    widget.log.created.add(recipe);
    setState(() {
      _userRecipes = <FitnessRecipe>[
        recipe,
        ..._userRecipes.where((r) => r.slug != recipe.slug),
      ];
    });
    return SyncDelivery.delivered;
  }

  Future<SyncDelivery> _delete(String slug) async {
    widget.log.deleted.add(slug);
    setState(() {
      _userRecipes =
          _userRecipes.where((r) => r.slug != slug).toList(growable: false);
    });
    return SyncDelivery.delivered;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: Row(
        children: <Widget>[
          Expanded(
            child: TextButton(
              key: const ValueKey('flow-nav-coach'),
              onPressed: () => setState(() => _tab = 0),
              child: const Text('Coach'),
            ),
          ),
          Expanded(
            child: TextButton(
              key: const ValueKey('flow-nav-recipes'),
              onPressed: () => setState(() => _tab = 1),
              child: const Text('Recipes'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          // Same shell padding as eatova_home_page.dart.
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: IndexedStack(
            key: const ValueKey('flow-tab-stack'),
            index: _tab,
            sizing: StackFit.expand,
            children: <Widget>[
              TickerMode(
                enabled: _tab == 0,
                child: CoachChatScreen(
                  service: widget.service,
                  userName: 'Moritz',
                  streak: 3,
                  onCreateRecipe: _create,
                  // Like eatova_home_page.dart: the visible list, not the
                  // full one (2026-09-02).
                  userRecipeSlugs: <String>{
                    for (final recipe in _userRecipes)
                      if (!_pendingDeletes.contains(recipe.slug)) recipe.slug,
                  },
                ),
              ),
              TickerMode(
                enabled: _tab == 1,
                child: RecipesScreen(
                  onAddMeal: (MealAnalysisResult result, MealSlot slot) =>
                      widget.log.loggedSlots.add(slot),
                  initialUserRecipes: _userRecipes,
                  onCreateRecipe: _create,
                  onDeleteRecipe: _delete,
                  onDeletePendingChanged: _setPending,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bounded "settle": never pumpAndSettle on the coach tab — the CoachOrb spins
/// forever unless reduce motion is on, and a bounded loop cannot hang either
/// way. 24 x 50 ms covers route/sheet transitions and the fake's futures.
///
/// A coarser step than [settleFrames]' 16 ms default: the coach's futures are
/// awaited, not animated, so fewer and longer frames get there quicker.
Future<void> _settle(WidgetTester tester, {int rounds = 24}) =>
    settleFrames(tester,
        rounds: rounds, step: const Duration(milliseconds: 50));

Finder _inList(Finder matching) => find.descendant(
      of: find.byKey(const ValueKey('coach-message-list')),
      matching: matching,
    );

Future<void> _frage(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('coach-input')), text);
  await _settle(tester, rounds: 3);
  await tester.tap(find.byKey(const ValueKey('coach-send')));
  await _settle(tester);
}

void main() {
  testWidgetsRobust(
      'Coach: Frage, Antwort, /recipe-Karte, Hinzufügen, Rezept im Rezepte-Tab',
      (WidgetTester tester) async {
    final svc = _FlowCoach.create();
    final log = _Mitschrift();

    await tester.pumpWidget(MaterialApp(
      theme: buildEatovaTheme(Brightness.dark),
      locale: const Locale('en'),
      supportedLocales: const [Locale('de'), Locale('en')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // Above the Navigator, so pushed sheets inherit it too: the orb stays
      // static and no decorative animation outlives a bounded pump loop.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child ?? const SizedBox.shrink(),
      ),
      home: _CoachRecipeShell(service: svc, log: log),
    ));
    await _settle(tester);

    // --- 1. plain question -------------------------------------------------
    expect(find.byKey(const ValueKey('screen-coach')), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-empty')), findsOneWidget);

    await _frage(tester, _question);

    expect(svc.sendCalls, 1);
    expect(_inList(find.text(_question)), findsOneWidget,
        reason: 'die eigene Frage fehlt als Blase');
    expect(_inList(find.text(_answer)), findsOneWidget,
        reason: 'die Coach-Antwort fehlt als Blase');
    expect(find.byKey(const ValueKey('coach-empty')), findsNothing);
    expect(find.byKey(const ValueKey('coach-recipe-card')), findsNothing,
        reason: 'eine normale Frage erzeugt keine Rezeptkarte');

    // --- 2. /recipe -> proposal card ---------------------------------------
    await _frage(tester, '/recipe $_wish');

    expect(svc.recipeCalls, hasLength(1));
    expect(svc.recipeCalls.single.wish, _wish);
    expect(svc.recipeCalls.single.locale, 'en',
        reason: 'der Request folgt der App-Sprache');
    expect(svc.sendCalls, 1, reason: '/recipe nimmt NICHT den Chat-Pfad');
    expect(find.byKey(const ValueKey('coach-recipe-card')), findsOneWidget);
    expect(find.text(_proposal.title), findsOneWidget);
    expect(find.byKey(const ValueKey('coach-recipe-add')), findsOneWidget);

    // --- 3. add -> sheet -> confirm ----------------------------------------
    await tester.tap(find.byKey(const ValueKey('coach-recipe-add')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('coach-recipe-sheet')), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const ValueKey('coach-recipe-sheet-confirm')),
    );
    await _settle(tester, rounds: 3);
    await tester.tap(find.byKey(const ValueKey('coach-recipe-sheet-confirm')));
    await _settle(tester);

    expect(log.created, hasLength(1));
    final recipe = log.created.single;
    expect(recipe.slug, _slug,
        reason: 'deterministischer Slug aus der Message-Id');
    expect(recipe.userCreated, isTrue);
    expect(recipe.categories, const <String>['Eigene']);
    expect(recipe.caloriesKcal, _proposal.caloriesKcal);
    // The card locks itself while the recipe exists.
    expect(find.byKey(const ValueKey('coach-recipe-add')), findsNothing);
    expect(find.text(enL10n.coachRecipeAddedLabel), findsOneWidget);

    // --- 4. recipes tab: the "Eigene" filter carries it --------------------
    await tester.tap(find.byKey(const ValueKey('flow-nav-recipes')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('screen-recipes')), findsOneWidget);
    final eigeneChip = find.byKey(const ValueKey('recipe-filter-Eigene'));
    expect(eigeneChip, findsOneWidget,
        reason: 'die „Eigene"-Kachel erscheint erst mit dem ersten Rezept');
    await tester.ensureVisible(eigeneChip);
    await tester.pumpAndSettle();
    await tester.tap(eigeneChip);
    await tester.pumpAndSettle();

    final tile = find.byKey(ValueKey('recipe-tile-$_slug'));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    expect(tile, findsOneWidget);
    expect(find.text(_proposal.title), findsWidgets);
    // Under "Eigene" only the coach recipe is left — no catalog dish.
    expect(
      find.byKey(
        const ValueKey('recipe-tile-hahnchen_mit_reis_and_brokkoli'),
      ),
      findsNothing,
    );

    // --- 5. detail page ----------------------------------------------------
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(find.byKey(ValueKey('recipe-detail-$_slug')), findsOneWidget);
    expect(find.text(_proposal.title), findsWidgets);
    expect(find.text(_proposal.preparation), findsOneWidget);
    expect(find.byKey(const ValueKey('recipe-detail-delete')), findsOneWidget,
        reason: 'ein eigenes Rezept ist löschbar');
    expect(find.byKey(const ValueKey('recipe-add-button')), findsOneWidget);

    // --- 6. the coach never logged a meal ----------------------------------
    // Everything up to here ran through the COACH; `onAddMeal` belongs to the
    // recipes tab alone.
    expect(log.loggedSlots, isEmpty,
        reason: 'der Coach hat bewusst keine Schreibrechte auf Mahlzeiten');
    expect(log.deleted, isEmpty);

    // --- 7. counter-check: the recorder is wired ---------------------------
    // Without this the line above would also hold for an `onAddMeal` that
    // nothing can ever reach — the recipes tab's OWN add button must fill the
    // very list the coach left empty.
    await tester.tap(find.byKey(const ValueKey('recipe-add-button')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('recipe-meal-picker-sheet')),
        findsOneWidget);
    final slotButton = find.byKey(const ValueKey('recipe-meal-picker-lunch'));
    await tester.ensureVisible(slotButton);
    await _settle(tester, rounds: 3);
    await tester.tap(slotButton);
    await _settle(tester);

    expect(log.loggedSlots, <MealSlot>[MealSlot.lunch],
        reason: 'der Rezepte-Tab loggt sehr wohl — die leere Liste oben ist '
            'eine Aussage ueber den Coach, kein toter Recorder');

    await tester.tap(find.byKey(const ValueKey('recipe-detail-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-recipes')), findsOneWidget);

    // --- 8. delete inside the undo window -> the card offers "add" again ---
    // Bug 2026-09-02: the card kept "Added" until the undo toast had gone,
    // because it read the full list instead of the visible one.
    await tester.tap(tile);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recipe-detail-delete')));
    await tester.pumpAndSettle();
    expect(find.text(enL10n.commonUndo), findsOneWidget,
        reason: 'der Undo-Snack steht');
    expect(log.deleted, isEmpty, reason: 'in der Frist ist nichts persistiert');

    // Few rounds: the undo toast lives 2.2 s and step 9 still has to tap it.
    await tester.tap(find.byKey(const ValueKey('flow-nav-coach')));
    await _settle(tester, rounds: 6);
    expect(find.byKey(const ValueKey('coach-recipe-add')), findsOneWidget,
        reason: 'aus Nutzersicht ist das Rezept weg — der Knopf muss SOFORT '
            'zurück sein, nicht erst nach dem Snack');
    expect(find.text(enL10n.coachRecipeAddedLabel), findsNothing);

    // --- 9. undo -> the card locks again ------------------------------------
    await tester.tap(find.byKey(const ValueKey('flow-nav-recipes')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(enL10n.commonUndo));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('flow-nav-coach')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('coach-recipe-add')), findsNothing,
        reason: 'Undo: das Rezept existiert wieder, die Karte ist gesperrt');
    expect(find.text(enL10n.coachRecipeAddedLabel), findsOneWidget);
    expect(log.deleted, isEmpty, reason: 'Undo: der Hook lief nie');
  });
}
