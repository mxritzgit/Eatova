import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase/supabase.dart';
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/models/coach_workout_log.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/screens/training/training_log_editor.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/services/dictation_language.dart';
import 'package:eatova/src/services/screen_awake.dart';
import 'package:eatova/src/services/uuid.dart';
import 'package:eatova/src/widgets/design/design.dart';

import 'support/harness.dart';

// Spec C1: Coach `/log`. A typed or dictated `/log` sends once and turns into
// a draft card; the history row is written only by the review sheet's Add,
// with the id derived from the answer (or allocated once for a local-only
// answer). The card state is derived from the live history: added, removed,
// or waiting while history is not authoritative. A second tap, a second
// device or a deleted entry never produce a second row.

/// Saturday 2026-10-03, 18:30 local.
final _now = DateTime(2026, 10, 3, 18, 30);
const _assistantId = '0b6f2a4e-8c1d-4f7a-9e3b-5d2c1a0f9e8d';
final _historyId = deriveCoachWorkoutLogId(_assistantId)!;
const _wish = 'gestern Kniebeugen 2x8 mit 100 kg, dann Plank 60 s';

Map<String, Object?> _logJson({
  String? performedOn = '2026-10-02',
  bool omitted = false,
}) => {
  'schema_version': 1,
  'title': 'Beintag',
  'performed_on': performedOn,
  'duration_minutes': null,
  'other_days_omitted': omitted,
  'note': '',
  'exercises': [
    {
      'name': 'Kniebeuge',
      'kind': 'reps',
      'duration_seconds': null,
      'sets': [
        {'reps': 8, 'weight_kg': 100},
        {'reps': 8, 'weight_kg': 100},
      ],
    },
    {
      'name': 'Plank',
      'kind': 'timed',
      'duration_seconds': 60,
      'sets': [
        {'reps': null, 'weight_kg': null},
      ],
    },
  ],
};

ChatMessage _logRow({Map<String, Object?>? log}) => ChatMessage.fromRow({
  'id': _assistantId,
  'role': 'assistant',
  'content': 'Beintag erkannt.',
  'refusal': false,
  'created_at': '2026-10-03T08:00:00Z',
  'recipe': null,
  'training_plan': null,
  'workout_log': log ?? _logJson(),
});

/// JSON on the calling isolate: the SDK's default codec answers through a
/// real isolate port, which a widget test's fake time cannot advance.
class _InlineJson implements YAJsonIsolate {
  @override
  String? get debugName => null;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<dynamic> decode(String json) async => jsonDecode(json);

  @override
  Future<String> encode(Object? json) async => jsonEncode(json);
}

class _LogCoach extends CoachChatService {
  _LogCoach(super.client, super.userId);

  static _LogCoach create([String userId = 'user-a']) {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((_) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _LogCoach(client, userId);
  }

  /// The real request path against a server that cannot take `/log` (an
  /// older or rolled-back function): every function call answers 400.
  static _LogCoach oldServer(String error) {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient(
        (request) async => request.url.path.contains('/functions/')
            ? http.Response(
                jsonEncode({'error': error}),
                400,
                headers: {'content-type': 'application/json'},
              )
            : http.Response('[]', 200),
      ),
      isolate: _InlineJson(),
    );
    client.auth.stopAutoRefresh();
    return _LogCoach(client, 'user-a').._passThrough = true;
  }

  bool _passThrough = false;
  final calls = <({String wish, String locale, String session})>[];
  int chats = 0;
  int plans = 0;
  int recipes = 0;
  List<ChatMessage> history = const [];
  Map<String, Object?> log = _logJson();
  String? assistantId = _assistantId;
  Completer<CoachWorkoutLogReply>? pending;

  @override
  Future<List<ChatSession>> loadSessions() async => [
    for (final id in ['a', 'b'])
      ChatSession(
        id: id,
        title: 'Chat $id',
        createdAt: _now,
        lastMessageAt: _now,
        messageCount: 0,
      ),
  ];

  @override
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async => sessionId == 'a' ? history : const <ChatMessage>[];

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async =>
      const ChatQuotaSnapshot(used: 0, remaining: 5, dailyLimit: 5);

  @override
  Future<CoachWorkoutLogReply> requestWorkoutLog(
    String wish, {
    required String sessionId,
    required String locale,
  }) async {
    calls.add((wish: wish, locale: locale, session: sessionId));
    if (_passThrough) {
      return super.requestWorkoutLog(
        wish,
        sessionId: sessionId,
        locale: locale,
      );
    }
    return pending?.future ??
        CoachWorkoutLogReply(
          reply: 'Beintag erkannt.',
          refusal: false,
          proposal: CoachWorkoutLog.fromJson(log),
          sessionId: sessionId,
          assistantMessageId: assistantId,
          remaining: 4,
          dailyLimit: 5,
        );
  }

  @override
  Future<CoachChatReply> send(
    String message, {
    required String sessionId,
    String? imageBase64,
    String? imageMimeType,
    String? userContext,
    void Function(String text)? onPartialReply,
  }) async {
    chats++;
    return CoachChatReply(
      reply: 'Antwort',
      refusal: false,
      sessionId: sessionId,
    );
  }

  @override
  Future<CoachPlanReply> requestPlan(
    String wish, {
    required String sessionId,
    required String locale,
  }) async {
    plans++;
    return CoachPlanReply(reply: 'Plan', refusal: true, sessionId: sessionId);
  }

  @override
  Future<CoachRecipeReply> requestRecipe(
    String wish, {
    required String sessionId,
    required String locale,
  }) async {
    recipes++;
    return CoachRecipeReply(
      reply: 'Rezept',
      refusal: true,
      sessionId: sessionId,
    );
  }
}

/// What the shell hands the Coach: the live history ids, the deletion
/// receipts and whether the history is known.
typedef _Shell = ({
  Set<String> ids,
  Set<String> deleted,
  bool authoritative,
  int logDraft,
});

class _Harness {
  _Harness(this.shell, this.account, this.outcomes);

  final ValueNotifier<_Shell> shell;
  final ValueNotifier<_LogCoach> account;
  final List<TrainingLogSaveOutcome> outcomes;
  final saved = <TrainingHistoryEntry>[];
  Completer<TrainingLogSaveOutcome>? pendingSave;

  /// Stands in for `HomeStore.logCompletedWorkout`: a saved entry appears in
  /// the live history the shell passes back.
  Future<TrainingLogSaveOutcome> save(TrainingHistoryEntry entry) async {
    saved.add(entry);
    final outcome = pendingSave != null
        ? await pendingSave!.future
        : saved.length <= outcomes.length
        ? outcomes[saved.length - 1]
        : TrainingLogSaveOutcome.saved;
    if (outcome == TrainingLogSaveOutcome.saved ||
        outcome == TrainingLogSaveOutcome.queued) {
      final s = shell.value;
      shell.value = (
        ids: {...s.ids, entry.id},
        deleted: s.deleted,
        authoritative: s.authoritative,
        logDraft: s.logDraft,
      );
    }
    return outcome;
  }

  void update({Set<String>? ids, Set<String>? deleted, bool? authoritative}) {
    final s = shell.value;
    shell.value = (
      ids: ids ?? s.ids,
      deleted: deleted ?? s.deleted,
      authoritative: authoritative ?? s.authoritative,
      logDraft: s.logDraft,
    );
  }

  void requestLogDraft() {
    final s = shell.value;
    shell.value = (
      ids: s.ids,
      deleted: s.deleted,
      authoritative: s.authoritative,
      logDraft: s.logDraft + 1,
    );
  }
}

/// Every test runs on a frozen Saturday evening: the card's "Yesterday" and
/// the editor's date checks read the clock.
void _test(String description, Future<void> Function(WidgetTester) body) =>
    testWidgets(
      description,
      (tester) => withClock(Clock.fixed(_now), () => body(tester)),
    );

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<_Harness> _mount(
  WidgetTester tester,
  _LogCoach coach, {
  bool hook = true,
  List<TrainingLogSaveOutcome> outcomes = const [],
  Set<String> ids = const {},
  Set<String> deleted = const {},
  bool authoritative = true,
  Locale locale = const Locale('de'),
  VoidCallback? onOpenTraining,
  ImagePicker? picker,
  double scale = 1,
  Size size = const Size(402, 820),
}) async {
  final shell = ValueNotifier<_Shell>((
    ids: ids,
    deleted: deleted,
    authoritative: authoritative,
    logDraft: 0,
  ));
  final account = ValueNotifier<_LogCoach>(coach);
  addTearDown(shell.dispose);
  addTearDown(account.dispose);
  final harness = _Harness(shell, account, outcomes);
  await pumpLocalized(
    tester,
    ValueListenableBuilder<_LogCoach>(
      valueListenable: account,
      builder: (_, service, __) => ValueListenableBuilder<_Shell>(
        valueListenable: shell,
        builder: (_, s, __) => CoachChatScreen(
          service: service,
          userName: 'M',
          onLogWorkout: hook ? harness.save : null,
          trainingHistoryIds: s.ids,
          trainingHistoryDeletedIds: s.deleted,
          trainingHistoryAuthoritative: s.authoritative,
          logDraftRequest: s.logDraft,
          onOpenTraining: onOpenTraining,
          imagePicker: picker,
          screenAwake: const NoopScreenAwake(),
          dictationLanguageStore: const PrefsDictationLanguageStore(),
        ),
      ),
    ),
    locale: locale,
    textScale: scale,
    surfaceSize: size,
    safeArea: false,
  );
  await _frames(tester);
  return harness;
}

final _input = find.byKey(const ValueKey('coach-input'));
final _add = find.byKey(const ValueKey('coach-workout-log-add'));
final _card = find.byKey(const ValueKey('coach-workout-log-card'));
final _editorSave = find.byKey(const ValueKey('training-log-save'));

String _text(WidgetTester tester) =>
    tester.widget<TextField>(_input).controller!.text;

String _field(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text;

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(_input, text);
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('coach-send')));
  await _frames(tester);
}

Future<void> _tapAdd(WidgetTester tester) async {
  await tester.ensureVisible(_add);
  await tester.pump();
  expect(_add.hitTestable(), findsOneWidget);
  await tester.tap(_add);
  await _frames(tester);
}

Future<void> _confirm(WidgetTester tester) async {
  await tester.ensureVisible(_editorSave);
  await tester.pump();
  await tester.tap(_editorSave);
  await _frames(tester);
}

bool _addEnabled(WidgetTester tester) =>
    tester.widget<PrimaryActionButton>(_add).onTap != null;

// --- Photo and dictation stand-ins ----------------------------------------

class _Picker extends ImagePicker {
  _Picker(this.bytes);

  final Uint8List bytes;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async => XFile.fromData(bytes, mimeType: 'image/jpeg', path: 'foto.jpg');
}

const MethodChannel _speech = MethodChannel('eatova/speech');

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// Stand-in for the iOS speech plugin (see coach_dictation_test.dart).
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

  void finish(String text) {
    for (final open in _open.reversed) {
      if (!open.isCompleted) {
        open.complete(<String, Object?>{'text': text, 'reason': 'final'});
        return;
      }
    }
  }

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

Future<void> _tapMic(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('coach-mic')));
  await _frames(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  // --- Sending --------------------------------------------------------------

  _test('/log sends once and shows a draft; nothing is written', (
    tester,
  ) async {
    final coach = _LogCoach.create();
    final h = await _mount(tester, coach);
    await _send(tester, '/LOG\n$_wish');

    expect(coach.calls.single.wish, _wish);
    expect(coach.calls.single.locale, 'de');
    expect(coach.calls.single.session, 'a');
    expect(coach.chats + coach.plans + coach.recipes, 0);
    expect(_card, findsOneWidget);
    expect(find.text(deL10n.coachWorkoutLogCardEyebrow), findsOneWidget);
    expect(find.text('Beintag'), findsOneWidget);
    expect(find.text(deL10n.trainingLogYesterday), findsOneWidget);
    expect(find.text('Kniebeuge · 2 × 8 Wdh. · 100 kg'), findsOneWidget);
    expect(find.text('Plank · 1 × 60 Sek.'), findsOneWidget);
    expect(h.saved, isEmpty, reason: 'nothing before the explicit Add');
    expect(_text(tester), isEmpty);
  });

  for (final draft in ['/log', '/LOG   ']) {
    _test('an empty "$draft" sends nothing and explains', (tester) async {
      final coach = _LogCoach.create();
      await _mount(tester, coach);
      await _send(tester, draft);
      expect(coach.calls, isEmpty);
      expect(coach.chats, 0);
      expect(find.text(deL10n.coachWorkoutLogEmptyHint), findsOneWidget);
    });
  }

  _test('a photo with /log sends nothing', (tester) async {
    final coach = _LogCoach.create();
    await _mount(
      tester,
      coach,
      picker: _Picker(
        Uint8List.fromList(
          img.encodeJpg(img.Image(width: 64, height: 48), quality: 90),
        ),
      ),
    );
    await tester.enterText(_input, '/log $_wish');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('coach-attach')));
    await _frames(tester);
    await tester.tap(find.byKey(const ValueKey('coach-gallery')));
    await _frames(tester);
    // The scrub runs in a real isolate the fake clock never reaches.
    final error = find.text(deL10n.coachWorkoutLogPhotoUnsupported);
    final watch = Stopwatch()..start();
    while (error.evaluate().isEmpty &&
        watch.elapsed < const Duration(seconds: 6)) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    await _frames(tester);
    expect(error, findsOneWidget);
    expect(coach.calls, isEmpty);
    expect(coach.chats, 0, reason: 'never a paid chat question either');
    expect(_text(tester), '/log $_wish', reason: 'the draft stays');
  });

  for (final code in ['invalid_mode', 'invalid_body']) {
    _test('a server without /log ($code): the error, the draft back, '
        'no Retry', (tester) async {
      final coach = _LogCoach.oldServer(code);
      final h = await _mount(tester, coach);
      await _send(tester, '/log $_wish');
      expect(coach.calls, hasLength(1));
      expect(find.text(deL10n.coachWorkoutLogUnavailable), findsOneWidget);
      expect(
        find.byKey(const ValueKey('coach-unsent')),
        findsNothing,
        reason: 'a certain 400: a Retry could only loop',
      );
      expect(_text(tester), '/log $_wish', reason: 'the draft stays');
      expect(
        find.text('/log $_wish'),
        findsOneWidget,
        reason: 'in the composer only, not also as a sent-looking bubble',
      );
      expect(_card, findsNothing);
      expect(h.saved, isEmpty);
    });
  }

  _test('an unknown command names /log in both languages', (tester) async {
    expect(deL10n.coachPlanUnknownCommandHint, contains('/log'));
    expect(enL10n.coachPlanUnknownCommandHint, contains('/log'));
    final coach = _LogCoach.create();
    await _mount(tester, coach);
    await _send(tester, '/logout bitte');
    expect(find.text(deL10n.coachPlanUnknownCommandHint), findsOneWidget);
    expect(coach.calls, isEmpty);
  });

  _test('a late answer for another conversation is not shown there', (
    tester,
  ) async {
    final coach = _LogCoach.create()
      ..pending = Completer<CoachWorkoutLogReply>();
    await _mount(tester, coach);
    await _send(tester, '/log $_wish');
    await tester.tap(find.byKey(const ValueKey('coach-sessions-open')));
    await _frames(tester);
    await tester.tap(find.text('Chat b'));
    await _frames(tester);
    coach.pending!.complete(
      CoachWorkoutLogReply(
        reply: 'Beintag erkannt.',
        refusal: false,
        proposal: CoachWorkoutLog.fromJson(_logJson()),
        sessionId: 'a',
        assistantMessageId: _assistantId,
        remaining: 4,
        dailyLimit: 5,
      ),
    );
    await _frames(tester);
    expect(_card, findsNothing);
  });

  for (final announces in [true, false]) {
    _test('the arriving card is '
        '${announces ? 'announced' : 'spoken by a live region'}', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures(supportsAnnounce: announces);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await _mount(tester, _LogCoach.create());
      tester.takeAnnouncements();
      await _send(tester, '/log $_wish');
      final cue = find.bySemanticsLabel(deL10n.coachAnswerAnnouncement);
      if (announces) {
        expect(
          tester.takeAnnouncements(),
          contains(isAccessibilityAnnouncement(deL10n.coachAnswerAnnouncement)),
        );
      } else {
        expect(cue, findsOneWidget);
      }
      semantics.dispose();
    });
  }

  // --- The card -------------------------------------------------------------

  _test('other days omitted: the card names the one day it took', (
    tester,
  ) async {
    final coach = _LogCoach.create()
      ..history = [
        _logRow(log: _logJson(performedOn: '2026-10-03', omitted: true)),
      ];
    await _mount(tester, coach, locale: const Locale('en'));
    expect(find.text(enL10n.trainingLogToday), findsOneWidget);
    expect(
      find.text(
        enL10n.coachWorkoutLogOnlyDay(
          DateFormat.MMMEd('en').format(DateTime(2026, 10, 3)),
        ),
      ),
      findsOneWidget,
    );
  });

  _test('an unknown day says so; the hint still appears', (tester) async {
    final coach = _LogCoach.create()
      ..history = [_logRow(log: _logJson(performedOn: null, omitted: true))];
    await _mount(tester, coach);
    expect(find.text(deL10n.coachWorkoutLogDayMissing), findsOneWidget);
    expect(find.text(deL10n.coachWorkoutLogOnlyOneDay), findsOneWidget);
  });

  _test('English UI keeps English card texts for German content', (
    tester,
  ) async {
    final coach = _LogCoach.create();
    await _mount(tester, coach, locale: const Locale('en'));
    await _send(tester, '/log $_wish');
    expect(coach.calls.single.locale, 'en');
    expect(find.text(enL10n.coachWorkoutLogCardEyebrow), findsOneWidget);
    expect(find.text(enL10n.trainingLogYesterday), findsOneWidget);
    expect(find.text('Kniebeuge · 2 × 8 reps · 100 kg'), findsOneWidget);
    expect(find.text('Plank · 1 × 60s'), findsOneWidget);
    expect(find.text(enL10n.coachWorkoutLogAddButton), findsOneWidget);
    expect(find.text(deL10n.coachWorkoutLogCardEyebrow), findsNothing);
  });

  _test('a reload rebuilds the card from the history row', (tester) async {
    final coach = _LogCoach.create()..history = [_logRow()];
    final h = await _mount(tester, coach);
    expect(_card, findsOneWidget);
    expect(find.text('Beintag'), findsOneWidget);
    await _tapAdd(tester);
    await _confirm(tester);
    expect(h.saved.single.id, _historyId);
  });

  // --- Review and confirmation ------------------------------------------------

  _test('Add opens the editor prefilled; cancel writes nothing', (
    tester,
  ) async {
    final coach = _LogCoach.create();
    final h = await _mount(tester, coach);
    await _send(tester, '/log $_wish');
    await _tapAdd(tester);
    expect(_editorSave, findsOneWidget);
    expect(find.text(deL10n.trainingLogReviewTitle), findsOneWidget);
    expect(_field(tester, 'training-log-title'), 'Beintag');
    expect(_field(tester, 'training-log-exercise-0-name'), 'Kniebeuge');
    expect(_field(tester, 'training-log-exercise-0-set-0-reps'), '8');
    expect(_field(tester, 'training-log-exercise-1-name'), 'Plank');
    expect(h.saved, isEmpty);

    await tester.tap(find.byKey(const ValueKey('training-log-close')));
    await _frames(tester);
    expect(_editorSave, findsNothing);
    expect(h.saved, isEmpty);
    expect(_add, findsOneWidget);
    expect(_addEnabled(tester), isTrue);
  });

  _test('the editor Add writes once with the derived id; the card flips', (
    tester,
  ) async {
    var opens = 0;
    final coach = _LogCoach.create();
    final h = await _mount(tester, coach, onOpenTraining: () => opens++);
    await _send(tester, '/log $_wish');
    await _tapAdd(tester);
    await _confirm(tester);

    expect(h.saved, hasLength(1));
    final entry = h.saved.single;
    expect(entry.id, _historyId);
    // Ruling R21: the time of the confirmation on yesterday's date.
    expect(entry.finishedAt, DateTime(2026, 10, 2, 18, 30).toUtc());
    expect(entry.snapshot.workout.exercises.map((e) => e.name), [
      'Kniebeuge',
      'Plank',
    ]);
    expect(_editorSave, findsNothing);
    expect(_add, findsNothing, reason: 'no second editable save');
    expect(find.text(deL10n.coachWorkoutLogAddedLabel), findsOneWidget);
    final open = find.byKey(const ValueKey('coach-workout-log-open-training'));
    await tester.ensureVisible(open);
    await tester.tap(open);
    expect(opens, 1);
  });

  _test('a double activation in one frame opens one sheet', (tester) async {
    final coach = _LogCoach.create()..history = [_logRow()];
    await _mount(tester, coach);
    await tester.ensureVisible(_add);
    await tester.pump();
    // Both activations reach the button before a frame can disable it (a
    // fast double tap or a second accessibility action).
    final activate = tester.widget<PrimaryActionButton>(_add).onTap!;
    activate();
    activate();
    await _frames(tester);
    expect(_editorSave, findsOneWidget);
  });

  _test('an id already in history: Added, and a stale sheet writes nothing', (
    tester,
  ) async {
    final coach = _LogCoach.create()..history = [_logRow()];
    final h = await _mount(tester, coach);
    await _tapAdd(tester);
    // A second device added it while the sheet was open.
    h.update(ids: {_historyId});
    await _frames(tester);
    await _confirm(tester);
    expect(h.saved, isEmpty);
    expect(_editorSave, findsNothing);
    expect(_add, findsNothing);
    expect(find.text(deL10n.coachWorkoutLogAddedLabel), findsOneWidget);
  });

  _test('a deleted id is "Removed from history" and never added again', (
    tester,
  ) async {
    final coach = _LogCoach.create()..history = [_logRow()];
    final h = await _mount(tester, coach);
    await _tapAdd(tester);
    // Deleted (local receipt or entity_deleted) while the sheet was open.
    h.update(deleted: {_historyId});
    await _frames(tester);
    await _confirm(tester);
    expect(h.saved, isEmpty);
    expect(_editorSave, findsNothing);
    expect(find.text(deL10n.coachWorkoutLogRemovedLabel), findsOneWidget);
    expect(_add, findsNothing);
  });

  _test('history not authoritative: Add waits disabled', (tester) async {
    final coach = _LogCoach.create()..history = [_logRow()];
    final h = await _mount(tester, coach, authoritative: false);
    expect(_add, findsOneWidget);
    expect(_addEnabled(tester), isFalse);
    await tester.tap(_add, warnIfMissed: false);
    await _frames(tester);
    expect(_editorSave, findsNothing);
    h.update(authoritative: true);
    await _frames(tester);
    expect(_addEnabled(tester), isTrue);
  });

  _test('history turning non-authoritative under an open sheet: Add writes '
      'nothing', (tester) async {
    final coach = _LogCoach.create()..history = [_logRow()];
    final h = await _mount(tester, coach);
    await _tapAdd(tester);
    expect(_editorSave, findsOneWidget);
    // A reload or an account change on the way: the ids may be stale.
    h.update(authoritative: false);
    await _frames(tester);
    await _confirm(tester);
    expect(h.saved, isEmpty, reason: 'no onLogWorkout call');
    expect(find.text(deL10n.trainingLogSaveError), findsOneWidget);
    expect(_editorSave, findsOneWidget, reason: 'the sheet stays open');

    // Known again: the same sheet's Add writes once.
    h.update(authoritative: true);
    await _frames(tester);
    await _confirm(tester);
    expect(h.saved.map((e) => e.id), [_historyId]);
  });

  _test('without a save hook the card has no Add', (tester) async {
    final coach = _LogCoach.create()..history = [_logRow()];
    await _mount(tester, coach, hook: false);
    expect(_card, findsOneWidget);
    expect(_add, findsNothing);
  });

  _test('a local-only answer keeps one allocated id across retries', (
    tester,
  ) async {
    final coach = _LogCoach.create()..assistantId = null;
    final h = await _mount(
      tester,
      coach,
      outcomes: [TrainingLogSaveOutcome.failed, TrainingLogSaveOutcome.failed],
    );
    await _send(tester, '/log $_wish');
    await _tapAdd(tester);
    await _confirm(tester);
    expect(h.saved, hasLength(1));
    expect(find.text(deL10n.trainingLogSaveError), findsOneWidget);
    await _confirm(tester);
    // Closed and opened again: still the same card, still the same id.
    await tester.tap(find.byKey(const ValueKey('training-log-close')));
    await _frames(tester);
    await _tapAdd(tester);
    await _confirm(tester);
    expect(h.saved, hasLength(3));
    final id = h.saved.first.id;
    expect(isUuidShape(id), isTrue);
    expect(id, id.toLowerCase());
    expect(h.saved.map((e) => e.id).toSet(), {id});
    expect(find.text(deL10n.coachWorkoutLogAddedLabel), findsOneWidget);
  });

  _test('a replacement account cannot write from an older open sheet', (
    tester,
  ) async {
    final coach = _LogCoach.create()..history = [_logRow()];
    final h = await _mount(tester, coach);
    await _tapAdd(tester);
    h.account.value = _LogCoach.create('user-b');
    await _frames(tester);
    await _confirm(tester);
    expect(h.saved, isEmpty);
    expect(find.text(deL10n.trainingLogSaveError), findsOneWidget);
  });

  _test('a late save result in a replaced account is not reported as saved', (
    tester,
  ) async {
    final coach = _LogCoach.create()..history = [_logRow()];
    final h = await _mount(tester, coach)
      ..pendingSave = Completer<TrainingLogSaveOutcome>();
    await _tapAdd(tester);
    await _confirm(tester);
    expect(h.saved, hasLength(1));
    h.account.value = _LogCoach.create('user-b');
    await _frames(tester);
    h.pendingSave!.complete(TrainingLogSaveOutcome.saved);
    await _frames(tester);
    expect(find.text(deL10n.trainingLogSaved), findsNothing);
    expect(find.text(deL10n.trainingLogSaveError), findsOneWidget);
  });

  // --- Discovery ------------------------------------------------------------

  _test('the command menu offers /log and only prepares the composer', (
    tester,
  ) async {
    final coach = _LogCoach.create();
    await _mount(tester, coach);
    await tester.enterText(_input, '/');
    await _frames(tester);
    expect(find.byKey(const ValueKey('coach-command-log')), findsOneWidget);
    await tester.enterText(_input, '/L');
    await _frames(tester);
    expect(find.byKey(const ValueKey('coach-command-plan')), findsNothing);
    expect(find.byKey(const ValueKey('coach-command-recipe')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('coach-command-log')));
    await _frames(tester);
    expect(_text(tester), '/log ');
    expect(coach.calls, isEmpty);
  });

  test('the /log menu entry promises a draft to review, like /plan', () {
    // Nothing is written before the review sheet's Add.
    for (final (l10n, review) in [(enL10n, 'review'), (deL10n, 'Prüfen')]) {
      expect(l10n.coachPlanCommandDescription, contains(review));
      expect(l10n.coachWorkoutLogCommandDescription, contains(review));
    }
    expect(enL10n.coachWorkoutLogCommandDescription, isNot(startsWith('Adds')));
    expect(deL10n.coachWorkoutLogCommandDescription, isNot(contains('Trägt')));
  });

  _test('the third hero chip prepares /log', (tester) async {
    final coach = _LogCoach.create();
    await _mount(tester, coach);
    final chip = find.byKey(const ValueKey('coach-try-log'));
    await tester.ensureVisible(chip);
    await tester.tap(chip);
    await _frames(tester);
    expect(_text(tester), '/log ');
    expect(coach.calls, isEmpty);
  });

  _test('a log draft request prefills /log and focuses the composer', (
    tester,
  ) async {
    final coach = _LogCoach.create();
    final h = await _mount(tester, coach);
    h.requestLogDraft();
    await _frames(tester);
    expect(_text(tester), '/log ');
    expect(tester.widget<TextField>(_input).focusNode!.hasFocus, isTrue);
    expect(coach.calls, isEmpty);
  });

  for (final locale in [const Locale('de'), const Locale('en')]) {
    _test('card states and menu reflow at 320px with 2x text '
        '(${locale.languageCode})', (tester) async {
      final l10n = locale.languageCode == 'en' ? enL10n : deL10n;
      final coach = _LogCoach.create()
        ..history = [_logRow(log: _logJson(omitted: true))];
      final errors = await collectOverflows(() async {
        final h = await _mount(
          tester,
          coach,
          locale: locale,
          scale: 2,
          size: const Size(320, 568),
          onOpenTraining: () {},
        );
        await tester.ensureVisible(_add);
        await _frames(tester);
        h.update(ids: {_historyId});
        await _frames(tester);
        expect(
          find.byKey(const ValueKey('coach-workout-log-open-training')),
          findsOneWidget,
        );
        h.update(ids: const {}, deleted: {_historyId});
        await _frames(tester);
        expect(find.text(l10n.coachWorkoutLogRemovedLabel), findsOneWidget);

        await tester.enterText(_input, '/');
        await _frames(tester);
        final log = find.byKey(const ValueKey('coach-command-log'));
        await tester.ensureVisible(log);
        await tester.pump();
        await tester.tap(log);
        await _frames(tester);
        expect(_text(tester), '/log ');
      });
      expect(errors, isEmpty, reason: describeOverflows(errors));
    });
  }

  // --- Dictation (rulings R17, C3) --------------------------------------------

  _test('a /log chip while dictating keeps the command under later partials', (
    tester,
  ) async {
    await _ios(() async {
      final native = _Native()..install();
      final coach = _LogCoach.create();
      await _mount(tester, coach);
      await _tapMic(tester);
      native.partial('gestern Kniebeugen');
      await tester.pump();
      expect(_text(tester), 'gestern Kniebeugen');

      final chip = find.byKey(const ValueKey('coach-try-log'));
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await _frames(tester);
      expect(_text(tester), '/log gestern Kniebeugen');

      native.partial('gestern Kniebeugen 2x8');
      await tester.pump();
      expect(_text(tester), '/log gestern Kniebeugen 2x8');
      native.finish('gestern Kniebeugen 2x8 mit 100 kg');
      await _frames(tester);
      expect(_text(tester), '/log gestern Kniebeugen 2x8 mit 100 kg');
      expect(coach.calls, isEmpty);
    });
  });

  _test('a /log menu pick while dictating keeps the command', (tester) async {
    await _ios(() async {
      final native = _Native()..install();
      final coach = _LogCoach.create();
      await _mount(tester, coach);
      await tester.enterText(_input, '/l');
      await tester.pump();
      await _tapMic(tester);
      await tester.tap(find.byKey(const ValueKey('coach-command-log')));
      await _frames(tester);
      expect(_text(tester), '/log ');
      native.partial('Kniebeugen');
      await tester.pump();
      expect(_text(tester), '/log Kniebeugen');
    });
  });

  _test('the review sheet ends a running dictation first', (tester) async {
    await _ios(() async {
      final native = _Native()..install();
      final coach = _LogCoach.create()..history = [_logRow()];
      await _mount(tester, coach);
      await _tapMic(tester);
      native.partial('Notiz');
      await tester.pump();
      final stale = native.tokens.last;
      await _tapAdd(tester);
      expect(native.count('cancel'), 1);
      expect(_editorSave, findsOneWidget);
      native.partial('Notiz und mehr', token: stale);
      await _frames(tester);
      expect(_text(tester), 'Notiz', reason: 'nothing rewrites the field');
    });
  });
}
