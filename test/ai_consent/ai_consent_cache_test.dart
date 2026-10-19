// The device copy of the AI consent (review 2026-10-19): one encrypted slot
// per account in the store's cache, read back as written, unreadable shapes
// count as "no consent", and logout or account deletion clears it like every
// other account slot while the other account keeps its own.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/models/ai_consent.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline_rounded,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

HomeStore _store(LocalCache cache) => HomeStore(
  sync: null,
  health: const NoopHealthService(),
  notificationService: const NoopNotificationService(),
  initialUserName: 'Test',
  emitSnack: _noopSnack,
  debugCache: cache,
);

final AiConsentRecord _grant = AiConsentRecord(
  version: kAiConsentVersion,
  granted: true,
  healthData: true,
  decidedAt: DateTime.utc(2026, 10, 19, 9, 30),
);

void main() {
  test('der Store schreibt und liest die Entscheidung im Kontoslot', () async {
    final storage = InMemoryKeyValueStore();
    final store = _store(LocalCache(storage, 'A'));
    addTearDown(store.dispose);

    expect(await store.readAiConsent(), isNull);
    await store.writeAiConsent(_grant);

    expect(storage.snapshot.keys, contains('eatova.v1.ai_consent.A'));
    expect(await store.readAiConsent(), _grant);
    expect((await store.readAiConsent())!.allowsAi, isTrue);
  });

  test('ein offener Widerruf bleibt offen', () async {
    final store = _store(LocalCache(InMemoryKeyValueStore(), 'A'));
    addTearDown(store.dispose);
    final pending = AiConsentRecord.withdrawal(DateTime.utc(2026, 10, 19, 10));

    await store.writeAiConsent(pending);
    final read = await store.readAiConsent();

    expect(read?.pendingUpload, isTrue);
    expect(read?.allowsAi, isFalse);
  });

  test('unlesbare Formen sind keine Einwilligung', () {
    expect(AiConsentRecord.fromJson(null), isNull);
    expect(AiConsentRecord.fromJson(const {'granted': true}), isNull);
    expect(
      AiConsentRecord.fromJson(const {
        'version': 1,
        'granted': false,
        'healthData': true,
        'decidedAt': '2026-10-19T09:30:00Z',
      }),
      isNull,
      reason: 'health data only with a grant',
    );
    expect(
      AiConsentRecord.fromJson(const {
        'version': 1,
        'granted': true,
        'healthData': true,
        'decidedAt': '2026-10-19T09:30:00Z',
        'pendingUpload': true,
      }),
      isNull,
      reason: 'only a withdrawal can be pending',
    );
    expect(AiConsentRecord.fromJson(_grant.toJson()), _grant);
  });

  test('Abmelden und Kontoloeschen raeumen den Slot, Konto B bleibt', () async {
    for (final preserveOutbox in [true, false]) {
      final storage = InMemoryKeyValueStore();
      for (final user in ['A', 'B']) {
        await LocalCache(storage, user).writeAiConsent(_grant.toJson());
      }

      await LocalCache(storage, 'A').clear(preserveOutbox: preserveOutbox);

      expect(storage.snapshot.keys, isNot(contains('eatova.v1.ai_consent.A')));
      expect(storage.snapshot.keys, contains('eatova.v1.ai_consent.B'));
    }
  });
}
