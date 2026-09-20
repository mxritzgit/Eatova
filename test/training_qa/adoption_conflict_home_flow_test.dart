import 'dart:async';
import 'dart:convert';

import 'package:eatova/src/app/eatova_home_page.dart';
import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/coach_training_proposal.dart';
import 'package:eatova/src/models/training_plan.dart';
import 'package:eatova/src/models/training_plan_head.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

import '../fixlauf_a_helpers.dart';
import '../support/harness.dart';
import '../support/sync_session_fixture.dart';
import 'fixtures.dart';

final _draft = TrainingPlan(
  id: 'coach_shared-proposal',
  sourceId: 'shared-proposal',
  proposal: CoachTrainingProposal.fromJson(
    trainingDraft(),
  )!.copyWith(title: 'My unchanged draft'),
);

class _Fixture {
  final server = FixlaufServer()
    ..profileRow = serverProfileRow(completedProfile);
  final cache = LocalCache(InMemoryKeyValueStore(), kFixlaufUser);
  final operation = SyncOp.trainingPlanUpsert(
    _draft,
    adoption: true,
  ).withBlockedReason(SyncBlockedReason.trainingHeadConflict);
  late final SupabaseClient client;
  late HomeStore store;
  TrainingPlanHead? head;
  Completer<void>? headGate;
  bool failHead = false;
  int headReads = 0;
  TrainingPlan visibleDraft = _draft;
  SyncOp? followup;

  Future<void> prepare({
    bool deleted = false,
    bool withFollowup = false,
  }) async {
    final current = _draft.copyWith(
      incarnation: 2,
      proposal: _draft.proposal.copyWith(title: 'Current server plan'),
    );
    head = TrainingPlanHead(
      sourceId: current.sourceId!,
      planId: current.id,
      incarnation: current.incarnation,
      deleted: deleted,
      plan: deleted ? null : current,
    );
    if (!deleted) server.trainingRows[current.id] = current.toRow();
    server.syncOperations.trainingHeads[current.sourceId!] = {
      'source_id': current.sourceId,
      'plan_id': current.id,
      'incarnation': current.incarnation,
      'deleted': deleted,
    };
    await cache.writeProfile(completedProfile);
    if (withFollowup) {
      visibleDraft = _draft.copyWith(
        proposal: _draft.proposal.copyWith(title: 'My latest confirmed edit'),
      );
      followup = SyncOp.trainingPlanUpsert(visibleDraft);
    }
    await cache.writeTrainingPlans([visibleDraft]);
    await cache.writeOutbox([operation, if (followup != null) followup!]);
    final base = server.client();
    client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/rpc/load_training_plan_head')) {
          headReads++;
          final source =
              (jsonDecode(request.body) as Map)['p_source_id'] as String;
          final currentHead = server.syncOperations.readTrainingHead(source);
          await headGate?.future;
          if (failHead) {
            throw http.ClientException('Simulated head read failure');
          }
          return http.Response(
            jsonEncode(currentHead),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
            request: request,
          );
        }
        final forwarded = http.Request(request.method, request.url)
          ..headers.addAll(request.headers)
          ..bodyBytes = request.bodyBytes;
        return http.Response.fromStream(await base.send(forwarded));
      }),
    );
    await signInSyncFixture(client, kFixlaufUser);
  }

  Future<void> mount(WidgetTester tester) async {
    await pumpLocalized(
      tester,
      EatovaHomePage(
        debugCache: cache,
        sync: EatovaSync.forUser(client, kFixlaufUser),
      ),
      locale: const Locale('en'),
      surfaceSize: const Size(430, 900),
      scaffold: false,
      safeArea: false,
    );
    store = (tester.state(find.byType(EatovaHomePage)) as HomePageDebugAccess)
        .debugStore;
    await _until(
      tester,
      () => !store.bootLoadInFlight && store.trainingPlans.isNotEmpty,
    );
    store.setTab(3);
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('training-review-adoption'))
          .evaluate()
          .isNotEmpty,
    );
    expect(store.trainingPlans.single.title, visibleDraft.title);
    expect(
      store.pendingTrainingAdoptions.single.operationId,
      operation.operationId,
    );
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(client.dispose);
  }

  Future<List<Map<String, dynamic>>> queueJson() async => [
    for (final op in await cache.readOutbox() ?? <SyncOp>[]) op.toJson(),
  ];

  int get mutationRequests => server.requests
      .where(
        (request) =>
            request.url.path.endsWith('/rpc/apply_sync_operation') &&
            (jsonDecode(request.body) as Map)['p_kind'].toString().startsWith(
              'trainingPlan',
            ),
      )
      .length;
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var frame = 0; frame < 150 && !condition(); frame++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(
    condition(),
    isTrue,
    reason: 'The real store/UI operation must settle',
  );
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(target);
  await tester.pump();
}

void main() {
  testWidgets(
    'review uses the latest confirmed follow-up and resolves both intents together',
    (tester) async {
      final fixture = _Fixture();
      await tester.runAsync(() => fixture.prepare(withFollowup: true));
      await fixture.mount(tester);
      await _tap(tester, 'training-review-adoption');
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('training-editor-save'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('training-editor-scroll')),
          matching: find.text(fixture.visibleDraft.title),
        ),
        findsOneWidget,
        reason: 'The latest locally confirmed edit must be offered for review',
      );
      expect(find.text(_draft.title), findsNothing);
      await _tap(tester, 'training-editor-save');
      await _until(tester, () => fixture.store.pendingOutbox.isEmpty);
      expect(
        fixture.server.trainingRows.values.single['plan']['title'],
        fixture.visibleDraft.title,
      );
      expect(
        fixture.mutationRequests,
        1,
        reason:
            'The superseded local edit must not be sent as an obsolete generation',
      );
      await fixture.close(tester);
    },
  );

  testWidgets(
    'an edit confirmed after opening review cannot be overwritten by that review',
    (tester) async {
      final fixture = _Fixture();
      await tester.runAsync(() => fixture.prepare(withFollowup: true));
      await fixture.mount(tester);
      await _tap(tester, 'training-review-adoption');
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('training-editor-save'))
            .evaluate()
            .isNotEmpty,
      );
      final later = _draft.copyWith(
        proposal: _draft.proposal.copyWith(
          title: 'Confirmed while review was open',
        ),
      );
      final saved = fixture.store.saveTrainingPlan(later);
      await _until(
        tester,
        () => fixture.store.trainingPlans.single.title == later.title,
      );
      await saved;
      final before = await fixture.queueJson();
      await _tap(tester, 'training-editor-save');
      final l10n = tester.element(find.byType(EatovaHomePage)).l10n;
      await _until(
        tester,
        () => find.text(l10n.trainingPageSaveError).evaluate().isNotEmpty,
      );
      expect(await fixture.queueJson(), before);
      expect(fixture.store.trainingPlans.single.toJson(), later.toJson());
      expect(fixture.mutationRequests, 0);
      await fixture.close(tester);
    },
  );

  for (final deleted in [false, true]) {
    testWidgets(
      'explicit review resolves the exact intent against a ${deleted ? 'deleted' : 'active'} head',
      (tester) async {
        final fixture = _Fixture();
        await tester.runAsync(() => fixture.prepare(deleted: deleted));
        await fixture.mount(tester);
        await _tap(tester, 'training-review-adoption');
        await _until(
          tester,
          () => find
              .byKey(const ValueKey('training-editor-save'))
              .evaluate()
              .isNotEmpty,
        );
        expect(fixture.mutationRequests, 0);
        expect(
          fixture.store.pendingTrainingAdoptions.single.operationId,
          fixture.operation.operationId,
        );
        await _tap(tester, 'training-editor-save');
        await _until(tester, () => fixture.store.pendingOutbox.isEmpty);
        final confirmed = fixture.store.trainingPlans.single;
        expect(confirmed.id, _draft.id);
        expect(confirmed.sourceId, _draft.sourceId);
        expect(confirmed.incarnation, deleted ? 3 : 2);
        expect(confirmed.proposal.toJson(), _draft.proposal.toJson());
        expect(fixture.server.trainingRows.values.single, confirmed.toRow());
        expect(fixture.mutationRequests, 1);
        final request = fixture.server.requests.singleWhere(
          (request) =>
              request.url.path.endsWith('/rpc/apply_sync_operation') &&
              (jsonDecode(request.body) as Map)['p_kind'] ==
                  'trainingPlanUpsert',
        );
        final body = jsonDecode(request.body) as Map;
        expect(body['p_operation_id'], isNot(fixture.operation.operationId));
        expect(body['p_training_protocol'], 2);
        expect(body['p_payload']['adoption'], isTrue);
        expect(body['p_payload']['row']['incarnation'], deleted ? 3 : 2);
        expect(
          find.byKey(const ValueKey('training-review-adoption')),
          findsNothing,
        );
        expect(
          (await fixture.cache.readTrainingPlans())!.single.toJson(),
          confirmed.toJson(),
        );
        await fixture.close(tester);
      },
    );
  }

  testWidgets(
    'a newer head after review keeps the confirmed draft blocked instead of advancing silently',
    (tester) async {
      final fixture = _Fixture();
      await tester.runAsync(fixture.prepare);
      await fixture.mount(tester);
      await _tap(tester, 'training-review-adoption');
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('training-editor-save'))
            .evaluate()
            .isNotEmpty,
      );
      final newer = _draft.copyWith(
        incarnation: 3,
        proposal: _draft.proposal.copyWith(title: 'Newer remote generation'),
      );
      fixture.server.trainingRows[newer.id] = newer.toRow();
      fixture.server.syncOperations.trainingHeads[newer.sourceId!] = {
        'source_id': newer.sourceId,
        'plan_id': newer.id,
        'incarnation': 3,
        'deleted': false,
      };
      await _tap(tester, 'training-editor-save');
      await _until(
        tester,
        () =>
            fixture.store.pendingTrainingAdoptions.isNotEmpty &&
            fixture.store.pendingTrainingAdoptions.single.operationId !=
                fixture.operation.operationId,
      );
      final blocked = fixture.store.pendingTrainingAdoptions.single;
      expect(blocked.trainingIncarnation, 2);
      expect(blocked.trainingPlan!.proposal.toJson(), _draft.proposal.toJson());
      expect(fixture.server.trainingRows[newer.id], newer.toRow());
      expect(fixture.mutationRequests, 1);
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('training-editor-save'))
            .evaluate()
            .isEmpty,
      );
      expect(
        find.byKey(const ValueKey('training-review-adoption')),
        findsOneWidget,
      );
      expect(
        find.text(
          tester
              .element(find.byType(EatovaHomePage))
              .l10n
              .settingsSyncTrainingConflict,
        ),
        findsOneWidget,
      );
      await fixture.close(tester);
    },
  );

  for (final discard in [false, true]) {
    testWidgets(
      'account switch before ${discard ? 'discard' : 'review'} confirmation keeps the original intent',
      (tester) async {
        final fixture = _Fixture();
        await tester.runAsync(fixture.prepare);
        await fixture.mount(tester);
        final before = await fixture.queueJson();
        final openKey = discard
            ? 'training-discard-adoption'
            : 'training-review-adoption';
        final confirmKey = discard
            ? 'training-discard-confirm'
            : 'training-editor-save';
        await _tap(tester, openKey);
        await _until(
          tester,
          () => find.byKey(ValueKey(confirmKey)).evaluate().isNotEmpty,
        );
        await tester.runAsync(
          () => signInSyncFixture(fixture.client, 'other-account'),
        );
        await _tap(tester, confirmKey);
        for (var frame = 0; frame < 5; frame++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(await fixture.queueJson(), before);
        expect(fixture.mutationRequests, 0);
        expect(fixture.store.trainingPlans.single.toJson(), _draft.toJson());
        await fixture.close(tester);
      },
    );
  }

  testWidgets(
    'failed head read and cancelled review retain the exact draft and operation',
    (tester) async {
      final fixture = _Fixture();
      await tester.runAsync(fixture.prepare);
      await fixture.mount(tester);
      final before = await fixture.queueJson();
      fixture.failHead = true;
      await _tap(tester, 'training-review-adoption');
      await _until(tester, () => fixture.headReads == 1);
      await _until(
        tester,
        () =>
            tester
                .widget<TextButton>(
                  find.byKey(const ValueKey('training-review-adoption')),
                )
                .onPressed !=
            null,
      );
      expect(find.byKey(const ValueKey('training-editor-save')), findsNothing);
      expect(await fixture.queueJson(), before);
      expect(fixture.mutationRequests, 0);

      fixture.failHead = false;
      await _tap(tester, 'training-review-adoption');
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('training-editor-save'))
            .evaluate()
            .isNotEmpty,
      );
      expect(find.textContaining('Current server plan'), findsOneWidget);
      expect(find.text(_draft.title), findsWidgets);
      expect(fixture.mutationRequests, 0);
      await _tap(tester, 'training-editor-close');
      await tester.pumpAndSettle();
      expect(await fixture.queueJson(), before);
      expect(fixture.store.trainingPlans.single.toJson(), _draft.toJson());
      await fixture.close(tester);
    },
  );

  testWidgets(
    'offline discard requires confirmation and never deletes the server plan',
    (tester) async {
      final fixture = _Fixture();
      await tester.runAsync(fixture.prepare);
      await fixture.mount(tester);
      fixture.server.offline = true;
      final before = await fixture.queueJson();
      final serverBefore = jsonEncode(fixture.server.trainingRows);
      await _tap(tester, 'training-discard-adoption');
      expect(
        find.byKey(const ValueKey('training-discard-confirm')),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(await fixture.queueJson(), before);
      await _tap(tester, 'training-discard-adoption');
      await _tap(tester, 'training-discard-confirm');
      await _until(
        tester,
        () => fixture.store.pendingTrainingAdoptions.isEmpty,
      );
      expect(fixture.store.pendingOutbox, isEmpty);
      expect(fixture.store.trainingPlans, isEmpty);
      expect(jsonEncode(fixture.server.trainingRows), serverBefore);
      expect(fixture.mutationRequests, 0);
      expect(fixture.headReads, 0);
      await fixture.close(tester);
    },
  );

  testWidgets(
    'a head answer after switching accounts cannot open the old draft',
    (tester) async {
      final fixture = _Fixture();
      await tester.runAsync(fixture.prepare);
      await fixture.mount(tester);
      final before = await fixture.queueJson();
      fixture.headGate = Completer<void>();
      await _tap(tester, 'training-review-adoption');
      await _until(tester, () => fixture.headReads == 1);
      await tester.runAsync(
        () => signInSyncFixture(fixture.client, 'other-account'),
      );
      fixture.headGate!.complete();
      await _until(
        tester,
        () =>
            tester
                .widget<TextButton>(
                  find.byKey(const ValueKey('training-review-adoption')),
                )
                .onPressed !=
            null,
      );
      expect(find.byKey(const ValueKey('training-editor-save')), findsNothing);
      expect(await fixture.queueJson(), before);
      expect(fixture.mutationRequests, 0);
      await fixture.close(tester);
    },
  );
}
