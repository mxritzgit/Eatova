import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/screens/training/training_player_screen.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import '../fixlauf_a_helpers.dart';
import '../support/harness.dart';
import '../training/legacy_checkpoint_fixture.dart';
import 'flow_test_helpers.dart' show pumpUntil;

const _sessionKey = 'eatova.v1.training_session.$kFixlaufUser';
const _plansKey = 'eatova.v1.training_plans.$kFixlaufUser';
const _firstSquat = TrainingSetReference(exerciseIndex: 0, setIndex: 0);

Map<String, dynamic>? _persisted(InMemoryKeyValueStore storage) =>
    (jsonDecode(storage.snapshot[_sessionKey]!) as Map)['snapshot']
        as Map<String, dynamic>?;

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await _frames(tester);
}

Future<HomeStore> _mount(
  WidgetTester tester,
  LocalCache cache,
  FixlaufServer server,
) async {
  await pumpLocalized(
    tester,
    EatovaHomePage(
      debugCache: cache,
      sync: EatovaSync.forUser(
        SupabaseClient(
          'https://example.supabase.co',
          'test-anon-key',
          httpClient: server.client(),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
        kFixlaufUser,
      ),
    ),
    surfaceSize: const Size(390, 844),
    scaffold: false,
    safeArea: false,
  );
  await pumpUntil(
    tester,
    () => find.byKey(const ValueKey('screen-welcome')).evaluate().isEmpty,
    'the mock account is ready',
  );
  final store =
      (tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess)
          .debugStore;
  await pumpUntil(
    tester,
    () => !store.bootLoadInFlight,
    'the server library confirms the legacy source',
  );
  return store;
}

void main() {
  for (final exit in ['save', 'discard']) {
    testWidgets(
      'a #70 recovery resumes, checkpoints and can $exit after time passes',
      (tester) async {
        var now = DateTime.utc(2026, 9, 28, 8);
        await withClock(Clock(() => now), () async {
          final storage = InMemoryKeyValueStore({
            _sessionKey: legacyCheckpointSlot,
            _plansKey: legacyPlanLibrarySlot,
          });
          final cache = LocalCache(storage, kFixlaufUser);
          await cache.writeProfile(completedProfile);
          final server = FixlaufServer()
            ..profileRow = serverProfileRow(completedProfile);
          server.trainingRows[legacyPlanId] =
              ((jsonDecode(legacyPlanLibrarySlot) as Map)['items'] as List)
                      .single
                  as Map<String, dynamic>;
          final store = await _mount(tester, cache, server);
          store.setTab(3);
          await _frames(tester);

          // Real time passes between app start and resuming the workout.
          now = now.add(const Duration(minutes: 7));
          await _tap(tester, 'training-resume');
          final player = tester.widget<TrainingPlayerScreen>(
            find.byType(TrainingPlayerScreen),
          );
          final recovery = player.initialSnapshot!;
          expect(recovery.plan.id, legacyPlanId);
          expect(recovery.completedSets, [_firstSquat]);
          final l10n = tester.element(find.byType(TrainingPlayerScreen)).l10n;
          const saveError = ValueKey('training-timer-save-error');
          String status() => tester
              .widget<Text>(
                find.byKey(const ValueKey('training-timer-save-status')),
              )
              .data!;
          await pumpUntil(
            tester,
            () =>
                status() == l10n.trainingTimerSaved ||
                find.byKey(saveError).evaluate().isNotEmpty,
            'the resumed checkpoint settles',
          );
          expect(
            find.byKey(saveError),
            findsNothing,
            reason: 'A legacy recovery must be savable after resuming',
          );
          expect(_persisted(storage)!['session_id'], recovery.sessionId);

          now = now.add(const Duration(seconds: 30));
          await _tap(tester, 'training-timer-skip-rest');
          await pumpUntil(
            tester,
            () => _persisted(storage)?['set_index'] == 1,
            'the later checkpoint update is durable',
          );
          expect(find.byKey(saveError), findsNothing);
          expect(store.trainingSession!.toJson(), _persisted(storage));

          now = now.add(const Duration(seconds: 5));
          if (exit == 'save') {
            await _tap(tester, 'training-timer-back');
          } else {
            await _tap(tester, 'training-timer-menu');
            await _tap(tester, 'training-timer-discard');
          }
          await _tap(tester, 'training-timer-confirm-exit');
          await pumpUntil(
            tester,
            () => find.byType(TrainingPlayerScreen).evaluate().isEmpty,
            'the player closes after the confirmed $exit',
          );
          if (exit == 'save') {
            final saved = _persisted(storage)!;
            expect(saved['session_id'], recovery.sessionId);
            expect(saved['completed_sets'], [_firstSquat.toJson()]);
            expect(store.trainingSession!.toJson(), saved);
            expect(
              find.byKey(const ValueKey('training-resume')),
              findsOneWidget,
            );
          } else {
            expect(_persisted(storage), isNull);
            expect(store.trainingSession, isNull);
            expect(find.byKey(const ValueKey('training-resume')), findsNothing);
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await _frames(tester);
        });
      },
    );
  }
}
