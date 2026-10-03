import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show ValueListenable, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/models/coach_recipe_proposal.dart';
import 'package:eatova/src/models/coach_training_context.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/fitness_recipe.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/dictation_language.dart';
import 'package:eatova/src/services/screen_awake.dart';
import 'package:eatova/src/services/sync_error_messages.dart';

import 'support/harness.dart';

// Spec §9 (Part E) and rulings R17: the verified Coach-tab defects of the
// 2026-10-03 review. One regression per item; each failed before its fix.

final _date = DateTime(2026, 10, 3, 12);

ChatSession _session(String id, String title) => ChatSession(
  id: id,
  title: title,
  createdAt: _date,
  lastMessageAt: _date,
  messageCount: 1,
);

CoachTrainingProposal _plan(List<List<String>> days) => CoachTrainingProposal(
  title: 'Kraft im Alltag',
  workouts: [
    for (final (index, names) in days.indexed)
      TrainingWorkout(
        title: 'Tag ${index + 1}',
        exercises: [
          for (final name in names)
            TrainingExercise(name: name, sets: 3, reps: 10, restSeconds: 60),
        ],
      ),
  ],
);

const _recipe = CoachRecipeProposal(
  title: 'Haehnchenauflauf',
  description: 'Cremig und proteinreich.',
  portion: '1 Portion',
  ingredients: '- 250 g Haehnchenbrust',
  preparation: '1. Ofen vorheizen.',
  caloriesKcal: 520,
  proteinG: 48,
  carbsG: 32,
  fatG: 18,
  estimatedGrams: 450,
);

ChatMessage _recipeMessage() => ChatMessage(
  id: 'server-r-1',
  role: ChatRole.assistant,
  content: 'Dein Rezept.',
  createdAt: _date,
  recipeProposal: _recipe,
);

class _Coach extends CoachChatService {
  _Coach(super.client, super.userId);

  static _Coach create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((_) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _Coach(client, 'user-a');
  }

  List<ChatSession> sessions = [
    _session('s1', 'Chat A'),
    _session('s2', 'Chat B'),
  ];
  Map<String, List<ChatMessage>> history = {};
  int historyFailures = 0;
  ChatQuotaSnapshot quota = const ChatQuotaSnapshot(
    used: 0,
    remaining: 5,
    dailyLimit: 5,
  );
  String? createdSession = 's3';
  String? defaultSession = 's1';

  final sent = <({String text, String? image})>[];
  final planCalls = <String>[];
  final recipeCalls = <String>[];
  Completer<CoachChatReply>? hold;
  CoachChatException? sendFailure;

  /// The session the server reports for a plan; null = the one asked for.
  String? planSessionId;

  @override
  Future<List<ChatSession>> loadSessions() async => sessions;

  @override
  Future<String?> ensureDefaultSession() async => defaultSession;

  @override
  Future<String?> createSession({required String title}) async =>
      createdSession;

  @override
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async {
    if (historyFailures > 0) {
      historyFailures--;
      throw const CoachDataUnavailable('offline');
    }
    return history[sessionId] ?? const <ChatMessage>[];
  }

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async => quota;

  @override
  Future<CoachChatReply> send(
    String message, {
    required String sessionId,
    String? imageBase64,
    String? imageMimeType,
    String? userContext,
    void Function(String text)? onPartialReply,
  }) async {
    sent.add((text: message, image: imageBase64));
    final failure = sendFailure;
    if (failure != null) throw failure;
    final gate = hold;
    if (gate != null) return gate.future;
    return CoachChatReply(
      reply: 'Antwort vom Coach.',
      refusal: false,
      remaining: 4,
      dailyLimit: 5,
      sessionId: sessionId,
    );
  }

  @override
  Future<CoachPlanReply> requestPlan(
    String wish, {
    required String sessionId,
    required String locale,
  }) async {
    planCalls.add(wish);
    return CoachPlanReply(
      reply: 'Dein Trainingsplan.',
      refusal: false,
      proposal: _plan([
        ['Kniebeuge'],
      ]),
      sessionId: planSessionId ?? sessionId,
      assistantMessageId: 'server-plan-1',
      remaining: 4,
      dailyLimit: 5,
    );
  }

  @override
  Future<CoachPlanReply> requestPlanWithContext(
    String wish, {
    required String sessionId,
    required String locale,
    required CoachTrainingContext trainingContext,
  }) => requestPlan(wish, sessionId: sessionId, locale: locale);

  @override
  Future<CoachRecipeReply> requestRecipe(
    String wish, {
    required String sessionId,
    required String locale,
  }) async {
    recipeCalls.add(wish);
    return CoachRecipeReply(
      reply: 'Dein Rezept.',
      refusal: false,
      proposal: _recipe,
      sessionId: sessionId,
      remaining: 4,
      dailyLimit: 5,
    );
  }
}

/// Serves an in-memory JPEG. [tor] holds the picker (the gallery is in the
/// foreground); [readGate] holds the read, the start of the scrub window.
class _Picker extends ImagePicker {
  _Picker(this.bytes);

  final Uint8List bytes;
  Completer<void>? tor;
  Completer<void>? readGate;
  String path = 'foto.jpg';

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    await tor?.future;
    return _GatedFile(bytes, readGate, path);
  }
}

class _GatedFile extends XFile {
  _GatedFile(super.bytes, this.gate, String path)
    : super.fromData(mimeType: 'image/jpeg', path: path);

  final Completer<void>? gate;

  @override
  Future<Uint8List> readAsBytes() async {
    await gate?.future;
    return super.readAsBytes();
  }
}

Uint8List _jpeg() => Uint8List.fromList(
  img.encodeJpg(img.Image(width: 64, height: 48), quality: 90),
);

// --- Dictation channel stand-in (see coach_dictation_test.dart) ------------

const MethodChannel _speech = MethodChannel('eatova/speech');

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

class _Native {
  final calls = <MethodCall>[];
  final tokens = <int>[];
  final _open = <Completer<Object?>>[];
  String _last = '';

  void install() {
    _messenger.setMockMethodCallHandler(_speech, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'listen':
          final args = call.arguments as Map<Object?, Object?>;
          tokens.add(args['token']! as int);
          _last = '';
          final result = Completer<Object?>();
          _open.add(result);
          return result.future;
        case 'cancel':
          _complete(_last, 'cancel');
          return null;
      }
      return null;
    });
    addTearDown(() => _messenger.setMockMethodCallHandler(_speech, null));
  }

  int count(String method) => calls.where((c) => c.method == method).length;

  void partial(String text, {int? token}) {
    _last = text;
    unawaited(
      _messenger.handlePlatformMessage(
        'eatova/speech',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('partial', <String, Object?>{
            'token': token ?? tokens.last,
            'text': text,
          }),
        ),
        (_) {},
      ),
    );
  }

  void finish(String text) => _complete(text, 'final');

  void _complete(String text, String reason) {
    for (final open in _open.reversed) {
      if (!open.isCompleted) {
        open.complete(<String, Object?>{'text': text, 'reason': reason});
        return;
      }
    }
  }
}

/// The mic exists on iOS only; reset before the binding checks it.
Future<void> _ios(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

// --- Mounting and gestures --------------------------------------------------

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<ValueNotifier<int>> _mount(
  WidgetTester tester,
  _Coach coach, {
  int planDraftRequest = 0,
  ImagePicker? picker,
  Set<String> recipeSlugs = const <String>{},
  Future<SyncDelivery> Function(FitnessRecipe recipe)? onCreateRecipe,
  ValueListenable<bool> tabVisible = const AlwaysStoppedAnimation<bool>(true),
}) async {
  final planDraft = ValueNotifier<int>(planDraftRequest);
  addTearDown(planDraft.dispose);
  await pumpLocalized(
    tester,
    ValueListenableBuilder<int>(
      valueListenable: planDraft,
      // The shell's tab signal (`TickerMode`, see eatova_home_page.dart).
      builder: (_, request, __) => ValueListenableBuilder<bool>(
        valueListenable: tabVisible,
        builder: (_, visible, __) => TickerMode(
          enabled: visible,
          child: CoachChatScreen(
            service: coach,
            userName: 'M',
            planDraftRequest: request,
            imagePicker: picker,
            userRecipeSlugs: recipeSlugs,
            onCreateRecipe: onCreateRecipe,
            screenAwake: const NoopScreenAwake(),
            dictationLanguageStore: const PrefsDictationLanguageStore(),
          ),
        ),
      ),
    ),
    surfaceSize: const Size(402, 820),
    safeArea: false,
  );
  await _frames(tester);
  return planDraft;
}

final _input = find.byKey(const ValueKey('coach-input'));
final _briefSubmit = find.byKey(const ValueKey('coach-brief-submit'));

TextField _field(WidgetTester tester) => tester.widget<TextField>(_input);

String _text(WidgetTester tester) => _field(tester).controller!.text;

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(_input, text);
  await tester.pump();
}

Future<void> _sendText(WidgetTester tester, String text) async {
  await _type(tester, text);
  await tester.tap(find.byKey(const ValueKey('coach-send')));
  await _frames(tester);
}

Future<void> _openSessions(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
  await _frames(tester);
}

Future<void> _pickFromGallery(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('coach-attach')));
  await _frames(tester);
  await tester.tap(find.byKey(const ValueKey('coach-gallery')));
  await _frames(tester);
}

/// The scrub runs through `compute()` in a real isolate the fake clock never
/// reaches: wait real time until [done] or a cap.
Future<void> _awaitScrub(WidgetTester tester, bool Function() done) async {
  final watch = Stopwatch()..start();
  while (!done() && watch.elapsed < const Duration(seconds: 6)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
  await _frames(tester);
}

// --- Answer announcements ---------------------------------------------------

/// Each place where `_announceAnswer` runs on an arriving answer.
enum _AnswerKind { chat, recipe, plan, remappedPlan }

/// The live region that stands in for an announcement (Android).
Finder get _answerCue => find.bySemanticsLabel(deL10n.coachAnswerAnnouncement);

void _announcing(WidgetTester tester, bool supportsAnnounce) {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures(supportsAnnounce: supportsAnnounce);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

/// One request of [kind], made the way a user makes it.
Future<void> _ask(
  WidgetTester tester,
  ValueNotifier<int> planDraft,
  _AnswerKind kind,
) async {
  switch (kind) {
    case _AnswerKind.chat:
      await _sendText(tester, 'Frage');
    case _AnswerKind.recipe:
      await _sendText(tester, '/recipe Auflauf');
    case _AnswerKind.plan || _AnswerKind.remappedPlan:
      planDraft.value++;
      await _frames(tester);
      await tester.ensureVisible(_briefSubmit);
      await tester.tap(_briefSubmit);
      await _frames(tester);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('Trainings-Brief', () {
    testWidgets('eine Brief-Anfrage waehrend einer laufenden Anfrage wartet '
        'und oeffnet nach der Antwort', (tester) async {
      final coach = _Coach.create()..hold = Completer<CoachChatReply>();
      final planDraft = await _mount(tester, coach);
      await _sendText(tester, 'Erste Frage');
      expect(coach.sent, hasLength(1));

      planDraft.value = 1;
      await _frames(tester);
      expect(
        _briefSubmit,
        findsNothing,
        reason: 'nichts schiebt sich ueber die laufende Antwort',
      );

      coach.hold!.complete(
        const CoachChatReply(
          reply: 'Antwort vom Coach.',
          refusal: false,
          remaining: 4,
          dailyLimit: 5,
          sessionId: 's1',
        ),
      );
      await _frames(tester);
      expect(_briefSubmit, findsOneWidget, reason: 'nicht verschluckt');
      expect(coach.planCalls, isEmpty);
    });

    for (final (draft, kept, wish) in <(String, String, String)>[
      ('Halb getippte Frage', 'Halb getippte Frage', ''),
      ('/plan Beine', '', 'Beine'),
    ]) {
      testWidgets('Brief-Absenden mit dem Entwurf "$draft" laesst "$kept" im '
          'Feld', (tester) async {
        final coach = _Coach.create();
        final planDraft = await _mount(tester, coach);
        await _type(tester, draft);
        planDraft.value = 1;
        await _frames(tester);

        await tester.ensureVisible(_briefSubmit);
        await tester.tap(_briefSubmit);
        await _frames(tester);

        expect(coach.planCalls, hasLength(1));
        if (wish.isNotEmpty) expect(coach.planCalls.single, wish);
        expect(
          _text(tester),
          kept,
          reason: 'ein fremder Entwurf bleibt, /plan geht im Brief auf',
        );
      });
    }

    testWidgets('bei erschoepftem Kontingent oeffnet der Brief nicht und der '
        'Grund steht da', (tester) async {
      final coach = _Coach.create()
        ..quota = const ChatQuotaSnapshot(
          used: 5,
          remaining: 0,
          dailyLimit: 5,
        );
      // Requested from Training on the first visit, while the chat loads.
      await _mount(tester, coach, planDraftRequest: 1);

      expect(_briefSubmit, findsNothing);
      expect(find.text(deL10n.coachErrorDailyLimitReached(5)), findsOneWidget);
      expect(coach.planCalls, isEmpty);
    });

    for (final loadsOnRetry in [true, false]) {
      testWidgets('ohne Session laedt der Brief sie einmal nach und '
          '${loadsOnRetry ? 'oeffnet' : 'nennt den Grund'}', (tester) async {
        final coach = _Coach.create()
          ..sessions = []
          ..defaultSession = null;
        final planDraft = await _mount(tester, coach);
        expect(find.text(deL10n.coachErrorNoSession), findsOneWidget);
        expect(_field(tester).enabled, isFalse);

        if (loadsOnRetry) coach.defaultSession = 's1';
        planDraft.value = 1;
        await _frames(tester);

        expect(_briefSubmit, loadsOnRetry ? findsOneWidget : findsNothing);
        expect(
          find.text(deL10n.coachErrorNoSession),
          loadsOnRetry ? findsNothing : findsOneWidget,
        );
      });
    }
  });

  group('Screenreader', () {
    testWidgets('Fehlerbanner und "Nicht gesendet" sind Live-Regionen', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final coach = _Coach.create()
        ..sendFailure = const CoachChatException('Keine Verbindung.');
      await _mount(tester, coach);
      await _sendText(tester, 'Frage');

      expect(
        tester.getSemantics(find.text('Keine Verbindung.')),
        isSemantics(isLiveRegion: true),
      );
      expect(
        tester.getSemantics(find.text(deL10n.coachMessageNotSent)),
        isSemantics(isLiveRegion: true),
      );
      semantics.dispose();
    });

    testWidgets('die Denk-Zeile hat einen Namen und meldet sich an', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final coach = _Coach.create()..hold = Completer<CoachChatReply>();
      await _mount(tester, coach);
      await _sendText(tester, 'Frage');

      expect(
        tester.getSemantics(find.byKey(const ValueKey('coach-thinking'))),
        isSemantics(
          label: deL10n.coachThinkingLabel,
          isLiveRegion: true,
        ),
      );
      coach.hold!.complete(
        const CoachChatReply(reply: 'Ok.', refusal: false, sessionId: 's1'),
      );
      await _frames(tester);
      semantics.dispose();
    });

    // Every answer path, on both platform kinds: iOS announces, Android
    // reports `supportsAnnounce: false` and gets a polite live region.
    for (final announces in [true, false]) {
      for (final kind in _AnswerKind.values) {
        testWidgets('eine eingetroffene ${kind.name}-Antwort wird '
            '${announces ? 'angesagt' : 'ueber eine Live-Region gemeldet'}', (
          tester,
        ) async {
          final semantics = tester.ensureSemantics();
          _announcing(tester, announces);
          final coach = _Coach.create();
          if (kind == _AnswerKind.remappedPlan) coach.planSessionId = 's2';
          final planDraft = await _mount(tester, coach);
          tester.takeAnnouncements();
          expect(_answerCue, findsNothing);

          await _ask(tester, planDraft, kind);
          final List<Object> requests = switch (kind) {
            _AnswerKind.chat => coach.sent,
            _AnswerKind.recipe => coach.recipeCalls,
            _AnswerKind.plan || _AnswerKind.remappedPlan => coach.planCalls,
          };
          expect(requests, hasLength(1));

          final announced = tester.takeAnnouncements();
          if (announces) {
            expect(
              announced,
              contains(
                isAccessibilityAnnouncement(deL10n.coachAnswerAnnouncement),
              ),
            );
            expect(_answerCue, findsNothing, reason: 'nicht doppelt');
          } else {
            expect(announced, isEmpty);
            final cue = tester.getSemantics(_answerCue);
            expect(
              cue,
              isSemantics(
                label: deL10n.coachAnswerAnnouncement,
                isLiveRegion: true,
              ),
            );
            final flags = cue.getSemanticsData().flagsCollection;
            expect(
              flags.isAccessibilityFocusBlocked,
              isTrue,
              reason: 'spricht nur, ist kein Halt beim Wischen',
            );
          }
          semantics.dispose();
        });
      }
    }

    testWidgets('ohne Ansage meldet jede weitere Antwort eine frische '
        'Live-Region, das Verlassen des Tabs raeumt sie ab', (tester) async {
      final semantics = tester.ensureSemantics();
      _announcing(tester, false);
      final tab = ValueNotifier<bool>(true);
      addTearDown(tab.dispose);
      final coach = _Coach.create();
      await _mount(tester, coach, tabVisible: tab);

      await _sendText(tester, 'Frage');
      final first = tester.getSemantics(_answerCue).id;
      await _sendText(tester, 'Noch eine Frage');
      expect(_answerCue, findsOneWidget);
      expect(
        tester.getSemantics(_answerCue).id,
        isNot(first),
        reason: 'auf Android spricht nur ein neuer Knoten erneut',
      );

      // A tab return rebuilds the semantics subtree; a stale cue would claim
      // a new answer.
      tab.value = false;
      await _frames(tester);
      tab.value = true;
      await _frames(tester);
      expect(_answerCue, findsNothing);
      semantics.dispose();
    });

    testWidgets('"Hinzugefuegt" an der Rezeptkarte ist eine Live-Region', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final coach = _Coach.create()..history = {'s1': [_recipeMessage()]};
      await _mount(
        tester,
        coach,
        recipeSlugs: {FitnessRecipe.coachProposalSlug('server-r-1')},
      );

      expect(
        tester.getSemantics(find.text(deL10n.coachRecipeAddedLabel)),
        isSemantics(isLiveRegion: true),
      );
      semantics.dispose();
    });

    testWidgets('Loeschen im Gespraechs-Sheet hat mindestens 48 dp', (
      tester,
    ) async {
      await _mount(tester, _Coach.create());
      await _openSessions(tester);

      final delete = find
          .ancestor(
            of: find.byIcon(Icons.delete_outline_rounded),
            matching: find.byType(IconButton),
          )
          .first;
      final size = tester.getSize(delete);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    });
  });

  group('Gespraeche', () {
    testWidgets('nach gescheitertem Verlauf zeigt das Sheet die Liste, und '
        'ein erneuter Versuch entsperrt den Composer', (tester) async {
      final coach = _Coach.create()..historyFailures = 1;
      await _mount(tester, coach);
      expect(find.text(deL10n.coachErrorHistoryUnavailable), findsOneWidget);
      expect(_field(tester).enabled, isFalse);

      await _openSessions(tester);
      expect(find.text(deL10n.coachSessionsEmpty), findsNothing);
      expect(find.text('Chat B'), findsOneWidget);
      await tester.tap(find.text('Chat A'));
      await _frames(tester);

      expect(_field(tester).enabled, isTrue);
    });

    testWidgets('scheitert "Neues Gespraech", sagt es eine Meldung', (
      tester,
    ) async {
      final coach = _Coach.create()..createdSession = null;
      await _mount(tester, coach);
      await _openSessions(tester);
      await tester.tap(find.byKey(const ValueKey('coach-sessions-new')));
      await _frames(tester);

      expect(find.text(deL10n.coachErrorNewSessionFailed), findsOneWidget);
    });
  });

  group('Foto', () {
    testWidgets('Tippen waehrend der Verkleinerung verwirft das Foto nicht', (
      tester,
    ) async {
      final bytes = _jpeg();
      final directory = Directory.systemTemp.createTempSync('coach-c3-');
      final photo = File('${directory.path}/photo.jpg')
        ..writeAsBytesSync(bytes);
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final coach = _Coach.create();
      final picker = _Picker(bytes)
        ..readGate = Completer<void>()
        ..path = photo.path;
      await _mount(tester, coach, picker: picker);
      await _type(tester, 'Was ist das?');
      await _pickFromGallery(tester);

      await _type(tester, 'Was ist das? Und wie viel Protein?');
      picker.readGate!.complete();
      await _awaitScrub(tester, () => !photo.existsSync());

      expect(coach.sent, hasLength(1), reason: 'das Foto ging raus');
      expect(coach.sent.single.text, 'Was ist das?');
      expect(coach.sent.single.image, isNotNull);
      expect(
        _text(tester),
        'Was ist das? Und wie viel Protein?',
        reason: 'der neue Text bleibt im Feld',
      );
    });

    testWidgets('Anhaengen beendet ein laufendes Diktat; das Foto geht mit '
        'dem gezeigten Text raus', (tester) async {
      await _ios(() async {
        final native = _Native()..install();
        final coach = _Coach.create();
        final picker = _Picker(_jpeg())..tor = Completer<void>();
        await _mount(tester, coach, picker: picker);
        await tester.tap(find.byKey(const ValueKey('coach-mic')));
        await _frames(tester);
        native.partial('Was ist');
        await tester.pump();

        await tester.tap(find.byKey(const ValueKey('coach-attach')));
        await _frames(tester);
        expect(native.count('cancel'), 1, reason: 'sofort, nicht mit Nachlauf');
        expect(_field(tester).readOnly, isFalse);
        expect(_text(tester), 'Was ist');

        await tester.tap(find.byKey(const ValueKey('coach-gallery')));
        await _frames(tester);
        native.partial('Was ist das hier', token: native.tokens.single);
        await tester.pump();
        picker.tor!.complete();
        await _awaitScrub(tester, () => coach.sent.isNotEmpty);

        expect(coach.sent, hasLength(1));
        expect(coach.sent.single.text, 'Was ist');
        expect(coach.sent.single.image, isNotNull);
      });
    });

    testWidgets('waehrend des Diktats heisst Senden "Spracheingabe '
        'abschliessen"', (tester) async {
      await _ios(() async {
        final semantics = tester.ensureSemantics();
        final native = _Native()..install();
        await _mount(tester, _Coach.create());
        await tester.tap(find.byKey(const ValueKey('coach-mic')));
        await _frames(tester);

        final finish = find.bySemanticsLabel(deL10n.coachDictationSendLabel);
        expect(finish, findsOneWidget);
        expect(
          tester.getSemantics(finish),
          isSemantics(
            hint: deL10n.coachDictationSendHint,
            isButton: true,
          ),
        );

        native.finish('fertig');
        await _frames(tester);
        expect(finish, findsNothing);
        expect(find.bySemanticsLabel(deL10n.coachSendLabel), findsOneWidget);
        semantics.dispose();
      });
    });
  });

  group('Karten', () {
    testWidgets('zweimal "Hinzufuegen" im selben Frame oeffnet ein Sheet; '
        'Abbrechen gibt die Sperre frei', (tester) async {
      final semantics = tester.ensureSemantics();
      final coach = _Coach.create()..history = {'s1': [_recipeMessage()]};
      await _mount(
        tester,
        coach,
        onCreateRecipe: (_) async => SyncDelivery.delivered,
      );
      final add = find.byKey(const ValueKey('coach-recipe-add'));
      await tester.ensureVisible(add);
      await tester.pump();

      // The navigator absorbs pointers once a route is pushed, but not
      // accessibility actions: a double activation reaches the card twice.
      final node = tester.getSemantics(add);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      node.owner!.performAction(node.id, SemanticsAction.tap);
      node.owner!.performAction(node.id, SemanticsAction.tap);
      await _frames(tester);
      expect(find.byKey(const ValueKey('coach-recipe-sheet')), findsOneWidget);

      await tester.tap(find.text(deL10n.commonCancel));
      await _frames(tester);
      expect(find.byKey(const ValueKey('coach-recipe-sheet')), findsNothing);
      await tester.tap(add);
      await _frames(tester);
      expect(find.byKey(const ValueKey('coach-recipe-sheet')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('die Plankarte nennt bis zu drei Uebungen und "+N weitere"', (
      tester,
    ) async {
      final coach = _Coach.create()
        ..history = {
          's1': [
            ChatMessage(
              id: 'server-plan-1',
              role: ChatRole.assistant,
              content: 'Dein Trainingsplan.',
              createdAt: _date,
              trainingPlanProposal: _plan([
                ['Kniebeuge', 'Unterarmstütz'],
                ['Schulterkreisen', 'Kniebeuge', 'Ausfallschritt', 'Rudern'],
              ]),
            ),
          ],
        };
      await _mount(tester, coach);
      final card = find.byKey(const ValueKey('coach-plan-card'));
      Finder inCard(String text) =>
          find.descendant(of: card, matching: find.text(text));

      for (final name in ['Kniebeuge', 'Unterarmstütz', 'Schulterkreisen']) {
        expect(inCard(name), findsOneWidget, reason: name);
      }
      expect(inCard('Ausfallschritt'), findsNothing);
      expect(inCard(deL10n.coachPlanCardMoreExercises(2)), findsOneWidget);
    });
  });
}
