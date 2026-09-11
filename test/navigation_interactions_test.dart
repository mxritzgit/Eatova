import 'dart:async';

import 'package:eatova/src/app/eatova_app.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/screens/training/training_plan_editor.dart';
import 'package:eatova/src/services/coach_chat_service.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/widgets/common/app_interactions.dart';
import 'package:eatova/src/widgets/design/sheets.dart';
import 'package:eatova/src/widgets/design/controls.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

class _Coach extends CoachChatService {
  _Coach(SupabaseClient client) : super(client, 'gesture-test');
  int sends = 0;

  @override
  Future<List<ChatSession>> loadSessions() async => [];
  @override
  Future<String?> ensureDefaultSession() async => 'session';
  @override
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async => [];
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
    void Function(String)? onPartialReply,
  }) async {
    sends++;
    throw StateError('Navigation must never send a message');
  }
}

Widget _host(Widget home) => MaterialApp(
  theme: buildEatovaTheme(Brightness.light),
  locale: const Locale('en'),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  builder: (context, child) => AppInteractions(child: child!),
  home: home,
);

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _phone(WidgetTester tester, TargetPlatform platform) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(() {
    tester.view.reset();
  });
}

Future<void> _edge(
  WidgetTester tester, {
  double distance = 160,
  double x = 2,
}) async {
  await tester.timedDragFrom(
    Offset(x, 220),
    Offset(distance, 0),
    const Duration(milliseconds: 400),
  );
  await _frames(tester);
}

void _interactionTest(
  String description,
  WidgetTesterCallback callback, {
  TargetPlatform platform = TargetPlatform.iOS,
}) {
  testWidgets(
    description,
    callback,
    variant: TargetPlatformVariant.only(platform),
  );
}

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    for (final gesture in ['tap', 'scroll']) {
      _interactionTest(
        'Empty Coach: $gesture dismisses keyboard without sending ($platform)',
        (tester) async {
          _phone(tester, platform);
          final client = SupabaseClient(
            'https://ci.invalid',
            'ci-dummy-key',
            httpClient: MockClient((_) async => http.Response('[]', 200)),
          );
          client.auth.stopAutoRefresh();
          final coach = _Coach(client);
          await tester.pumpWidget(
            _host(
              Scaffold(
                body: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: CoachChatScreen(service: coach),
                  ),
                ),
              ),
            ),
          );
          await _frames(tester);
          final input = find.byKey(const ValueKey('coach-input'));
          await tester.enterText(input, 'Unsent draft\nsecond line');
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await _frames(tester);
          final field = tester.widget<TextField>(input);
          expect(field.focusNode!.hasFocus, isTrue);
          if (gesture == 'tap') {
            await tester.tapAt(const Offset(25, 160));
          } else {
            await tester.drag(
              find.byKey(const ValueKey('coach-empty')),
              const Offset(0, -100),
            );
          }
          await _frames(tester);
          expect(field.focusNode!.hasFocus, isFalse);
          expect(tester.testTextInput.isVisible, isFalse);
          expect(field.controller!.text, 'Unsent draft\nsecond line');
          expect(coach.sends, 0);
          expect(find.byKey(const ValueKey('coach-empty')), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
        platform: platform,
      );
    }
  }

  _interactionTest(
    'Outside release preserves action taps and switching between fields',
    (tester) async {
      _phone(tester, TargetPlatform.iOS);
      final first = FocusNode();
      final second = FocusNode();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      var taps = 0;
      await tester.pumpWidget(
        _host(
          Scaffold(
            body: Column(
              children: [
                TextField(key: const ValueKey('first'), focusNode: first),
                TextField(key: const ValueKey('second'), focusNode: second),
                TextButton(
                  onPressed: () => taps++,
                  child: const Text('Action'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('first')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('second')));
      await tester.pump();
      expect(second.hasFocus, isTrue);
      final touch = await tester.startGesture(
        tester.getCenter(find.text('Action')),
      );
      await tester.pump();
      expect(
        second.hasFocus,
        isTrue,
        reason: 'Do not shift layouts during pointer down',
      );
      await touch.up();
      await tester.pump();
      expect(second.hasFocus, isFalse);
      expect(taps, 1);
    },
  );

  _interactionTest(
    'iOS guarded route: edge attempts exit, interior and cancelled swipes do not',
    (tester) async {
      _phone(tester, TargetPlatform.iOS);
      var exits = 0;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PopScope(
                      canPop: false,
                      onPopInvokedWithResult: (popped, _) {
                        if (!popped) exits++;
                      },
                      child: const Scaffold(body: Center(child: Text('Draft'))),
                    ),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await _frames(tester);
      await _edge(tester, x: 160);
      expect(exits, 0);
      await _edge(tester, distance: 35);
      expect(exits, 0);
      final interrupted = await tester.startGesture(const Offset(2, 220));
      await interrupted.moveBy(const Offset(180, 0));
      await tester.pump();
      await interrupted.cancel();
      await _frames(tester);
      expect(
        exits,
        0,
        reason: 'An interrupted pointer never commits navigation',
      );
      final reverse = await tester.startGesture(const Offset(2, 220));
      await reverse.moveBy(
        const Offset(240, 0),
        timeStamp: const Duration(milliseconds: 100),
      );
      for (var i = 1; i <= 4; i++) {
        await reverse.moveBy(
          const Offset(-25, 0),
          timeStamp: Duration(milliseconds: 100 + i * 20),
        );
      }
      await reverse.up(timeStamp: const Duration(milliseconds: 185));
      await _frames(tester);
      expect(
        exits,
        0,
        reason: 'A flick back toward the edge cancels navigation',
      );
      await _edge(tester);
      expect(exits, 1);
      expect(find.text('Draft'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  _interactionTest(
    'iOS normal route keeps interactive cancellation and back swipe',
    (tester) async {
      _phone(tester, TargetPlatform.iOS);
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        const Scaffold(body: Center(child: Text('Details'))),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await _frames(tester);
      final touch = await tester.startGesture(const Offset(2, 220));
      await touch.moveBy(const Offset(100, 0));
      await tester.pump();
      expect(tester.getCenter(find.text('Details')).dx, greaterThan(195));
      await touch.cancel();
      await _frames(tester);
      expect(find.text('Details'), findsOneWidget);
      await _edge(tester, distance: 300);
      expect(find.text('Details'), findsNothing);
      expect(find.text('Open'), findsOneWidget);
    },
  );

  _interactionTest(
    'Real app: recipe draft survives edge to Today and hidden tab loses focus',
    (tester) async {
      _phone(tester, TargetPlatform.iOS);
      await tester.pumpWidget(const EatovaApp());
      await _frames(tester);
      await tester.tap(find.byKey(const ValueKey('nav-Rezepte')));
      await _frames(tester);
      final search = find.byKey(const ValueKey('recipes-search-input'));
      await tester.enterText(search, 'chicken');
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await _frames(tester);
      final focus = tester
          .widget<EditableText>(
            find.descendant(of: search, matching: find.byType(EditableText)),
          )
          .focusNode;
      void closeKeyboard() {
        if (!focus.hasFocus) tester.view.viewInsets = FakeViewPadding.zero;
      }

      focus.addListener(closeKeyboard);
      await _edge(tester);
      focus.removeListener(closeKeyboard);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(find.byKey(const ValueKey('screen-recipes')), findsOneWidget);
      tester.view.viewInsets = FakeViewPadding.zero;
      await _frames(tester);
      await _edge(tester);
      expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nav-Rezepte')));
      await _frames(tester);
      expect(tester.widget<TextField>(search).controller!.text, 'chicken');
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.tap(search);
      await tester.pump();
      final home =
          tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess;
      home.debugStore.setTab(0);
      await _frames(tester);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  for (final dirty in [false, true]) {
    _interactionTest('Training editor pull-to-close respects dirty=$dirty', (
      tester,
    ) async {
      _phone(tester, TargetPlatform.iOS);
      var saves = 0;
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showTrainingPlanEditor(
                  context,
                  onSave: (_) async {
                    saves++;
                    throw StateError('Unexpected save');
                  },
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await _frames(tester);
      if (dirty) {
        await tester.enterText(find.byType(TextField).first, 'Unfinished plan');
        await tester.pump();
        expect(
          tester.testTextInput.isVisible,
          isTrue,
          reason: 'Guard change must retain focus',
        );
      }
      final interrupted = await tester.startGesture(
        Offset(
          30,
          tester
              .getCenter(find.byKey(const ValueKey('training-editor-close')))
              .dy,
        ),
      );
      await interrupted.moveBy(const Offset(0, 180));
      await tester.pump();
      await interrupted.cancel();
      await _frames(tester);
      expect(
        find.byKey(const ValueKey('training-editor-save')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('training-discard-dialog')),
        findsNothing,
      );
      await tester.dragFrom(
        Offset(
          30,
          tester
              .getCenter(find.byKey(const ValueKey('training-editor-close')))
              .dy,
        ),
        const Offset(0, 450),
      );
      await _frames(tester);
      if (dirty) {
        expect(
          find.byKey(const ValueKey('training-discard-dialog')),
          findsOneWidget,
        );
        expect(find.text('Unfinished plan'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('training-discard-confirm')),
        );
        await _frames(tester);
      }
      expect(find.byKey(const ValueKey('training-editor-save')), findsNothing);
      expect(saves, 0);
      expect(tester.takeException(), isNull);
    });
  }

  _interactionTest(
    'Training drag started before editing still asks before discarding',
    (tester) async {
      _phone(tester, TargetPlatform.iOS);
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showTrainingPlanEditor(
                  context,
                  onSave: (_) async => throw StateError('Unexpected save'),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await _frames(tester);
      final touch = await tester.startGesture(
        Offset(
          30,
          tester
              .getCenter(find.byKey(const ValueKey('training-editor-close')))
              .dy,
        ),
      );
      await tester.enterText(find.byType(TextField).first, 'Keep this draft');
      await tester.pump();
      await touch.moveBy(const Offset(0, 400));
      await touch.up();
      await _frames(tester);
      expect(
        find.byKey(const ValueKey('training-discard-dialog')),
        findsOneWidget,
      );
      expect(find.text('Keep this draft'), findsOneWidget);
    },
  );

  _interactionTest(
    'Edge completion preserves focus acquired during snap-back',
    (tester) async {
      _phone(tester, TargetPlatform.iOS);
      final first = FocusNode();
      final second = FocusNode();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await tester.pumpWidget(
        _host(
          PopScope(
            canPop: false,
            child: Scaffold(
              body: Column(
                children: [
                  TextField(key: const ValueKey('first'), focusNode: first),
                  TextField(key: const ValueKey('second'), focusNode: second),
                ],
              ),
            ),
          ),
        ),
      );
      await _frames(tester);
      await tester.tap(find.byKey(const ValueKey('first')));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      final touch = await tester.startGesture(const Offset(2, 220));
      await touch.moveBy(const Offset(170, 0));
      await touch.up();
      await tester.pump();
      second.requestFocus();
      await tester.pump();
      expect(second.hasFocus, isTrue);
      await _frames(tester);
      expect(second.hasFocus, isTrue);
    },
  );

  _interactionTest('Covered sheet ignores a late drag completion', (
    tester,
  ) async {
    _phone(tester, TargetPlatform.iOS);
    var dismissals = 0;
    late BuildContext sheetContext;
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showEatovaSheet(
                context,
                Builder(
                  builder: (context) {
                    sheetContext = context;
                    return SheetDismissGuard(
                      active: true,
                      followDrag: true,
                      onDismissAttempt: () {
                        dismissals++;
                        Navigator.of(context).pop();
                      },
                      child: const SizedBox(
                        key: ValueKey('drag-sheet'),
                        height: 250,
                        child: Center(child: Text('Sheet')),
                      ),
                    );
                  },
                ),
                dragHandle: false,
                enableDrag: false,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await _frames(tester);
    await tester.drag(
      find.byKey(const ValueKey('drag-sheet')),
      const Offset(0, 100),
    );
    unawaited(
      showDialog<void>(
        context: sheetContext,
        builder: (_) => const AlertDialog(title: Text('New dialog')),
      ),
    );
    await _frames(tester);
    expect(find.text('New dialog'), findsOneWidget);
    expect(dismissals, 0);
  });

  _interactionTest(
    'Training drag cannot dismiss a save begun after pointer-down',
    (tester) async {
      _phone(tester, TargetPlatform.iOS);
      final save = Completer<Never>();
      final draft = CoachTrainingProposal(
        title: 'Plan',
        description: 'Test',
        goal: 'Strength',
        workouts: [
          TrainingWorkout(
            title: 'Session',
            exercises: [
              TrainingExercise(name: 'Squat', sets: 1, reps: 5, restSeconds: 0),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showTrainingPlanEditor(
                  context,
                  initialDraft: draft,
                  onSave: (_) => save.future,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await _frames(tester);
      final touch = await tester.startGesture(
        Offset(
          30,
          tester
              .getCenter(find.byKey(const ValueKey('training-editor-close')))
              .dy,
        ),
      );
      tester
          .widget<PrimaryActionButton>(
            find.byKey(const ValueKey('training-editor-save')),
          )
          .onTap!();
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await touch.moveBy(const Offset(0, 400));
      await touch.up();
      await _frames(tester);
      expect(
        find.byKey(const ValueKey('training-editor-save')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('training-discard-dialog')),
        findsNothing,
      );
      save.completeError(StateError('Offline test failure'));
      await _frames(tester);
      expect(
        find.byKey(const ValueKey('training-editor-save')),
        findsOneWidget,
      );
      expect(find.byType(LinearProgressIndicator), findsNothing);
    },
  );
}
