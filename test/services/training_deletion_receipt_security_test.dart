import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:eatova/src/models/training_history.dart';
import 'package:eatova/src/models/training_session.dart';
import 'package:eatova/src/services/crash_reporter.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/services/secure_cache_store.dart';
import 'package:eatova/src/services/training_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../training/training_timer_fixtures.dart';

const _first = '11111111-1111-4111-8111-111111111111';
const _second = '22222222-2222-4222-8222-222222222222';
const _owner = 'receipt-security-A';
const _receiptKey = 'eatova.v1.training_history_deletions.$_owner';

CacheCipher _cipher() => AesGcmCacheCipher(Uint8List(32));

LocalCache _cache(
  KeyValueStore raw, {
  String owner = _owner,
  CacheCipher? cipher,
}) {
  final cache = LocalCache(
    EncryptedKeyValueStore(
      raw,
      cipher ?? _cipher(),
      acceptLegacyPlaintext: false,
    ),
    owner,
  );
  addTearDown(cache.close);
  return cache;
}

/// The actual SharedPreferences client maintains the optimistic memory cache;
/// only its platform disk boundary is fake. Errors and false both reject IO.
class _PreferenceDisk extends InMemorySharedPreferencesStore {
  _PreferenceDisk({required this.throwOnFailure}) : super.empty();
  final bool throwOnFailure;
  bool failWrites = true;
  bool failRemoves = false;
  int attempts = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    attempts++;
    if (failWrites) {
      if (throwOnFailure) throw StateError('fixture disk unavailable');
      return false;
    }
    return super.setValue(valueType, key, value);
  }

  @override
  Future<bool> remove(String key) async {
    if (failRemoves) return false;
    return super.remove(key);
  }
}

Future<SharedPreferencesStore> _preferences(_PreferenceDisk disk) async {
  final original = SharedPreferencesStorePlatform.instance;
  SharedPreferences.resetStatic();
  SharedPreferencesStorePlatform.instance = disk;
  addTearDown(() {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = original;
  });
  return SharedPreferencesStore.create();
}

class _HeldCipher implements CacheCipher {
  final delegate = _cipher();
  final release = Completer<void>();
  int writes = 0;

  @override
  Future<String> encrypt(String key, String plaintext) async {
    writes++;
    await release.future;
    return delegate.encrypt(key, plaintext);
  }

  @override
  Future<String> decrypt(String key, String armored) =>
      delegate.decrypt(key, armored);
}

class _FailingRemovalStorage extends InMemoryKeyValueStore {
  String? failingKey;
  final entered = Completer<void>();
  final release = Completer<void>();
  int receiptRemoves = 0;

  @override
  Future<void> remove(String key) async {
    if (key == _receiptKey) receiptRemoves++;
    if (key == failingKey) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
      throw StateError('private fixture payload must not leave the cache');
    }
    await super.remove(key);
  }
}

TrainingHistoryEntry _entry() =>
    withClock(Clock.fixed(DateTime.utc(2026, 9, 10, 12)), () {
      final controller = TrainingSessionController(
        plan: timerPlan(),
        workoutIndex: 1,
        autoTick: false,
      );
      controller.start();
      controller.completeCurrentSet();
      final completed = controller.completion();
      controller.dispose();
      return TrainingHistoryEntry(
        snapshot: TrainingSessionSnapshot.fromJson({
          ...completed.snapshot.toJson(),
          'session_id': _first,
        }),
        finishedAt: completed.finishedAt,
      );
    });

String _badTag(String armored) {
  final bytes = base64Decode(armored.substring(cacheCipherMagic.length));
  bytes[bytes.length - 1] ^= 1;
  return '$cacheCipherMagic${base64Encode(bytes)}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    EncryptedKeyValueStore.debugResetReportGuards();
    CrashReporter.debugSentrySink = (_, _, _) {};
  });
  tearDown(() {
    CrashReporter.debugSentrySink = null;
    EncryptedKeyValueStore.debugResetReportGuards();
  });

  for (final throws in [true, false]) {
    test(
      'optimistic receipt cannot prove disk success (platform throws: $throws)',
      () async {
        final disk = _PreferenceDisk(throwOnFailure: throws);
        final raw = await _preferences(disk);
        final cache = _cache(raw);
        expect(await cache.rememberTrainingHistoryDeletion(_first), isFalse);
        expect(await cache.readTrainingHistoryDeletions(), {_first});
        expect(
          await disk.getAll(),
          isEmpty,
          reason: 'only the plugin memory was updated',
        );

        // A second instance sees the same optimistic memory. The old shortcut
        // returned true here without touching disk and let the outbox consume it.
        final retry = _cache(raw);
        expect(await retry.rememberTrainingHistoryDeletion(_first), isFalse);
        expect(disk.attempts, 2);
        expect(await disk.getAll(), isEmpty);
        disk.failWrites = false;
        expect(await retry.rememberTrainingHistoryDeletion(_first), isTrue);
        expect(disk.attempts, 3);

        SharedPreferences.resetStatic();
        final cold = _cache(await SharedPreferencesStore.create());
        expect(await cold.readTrainingHistoryDeletions(), {_first});
      },
    );
  }

  test(
    'platform false on removal is reported and an explicit retry removes disk state',
    () async {
      final disk = _PreferenceDisk(throwOnFailure: false)..failWrites = false;
      final raw = await _preferences(disk);
      await raw.setString(_receiptKey, 'fixture ciphertext');
      disk.failRemoves = true;
      await expectLater(raw.remove(_receiptKey), throwsStateError);
      expect(
        await disk.getAll(),
        containsPair('flutter.$_receiptKey', 'fixture ciphertext'),
      );
      disk.failRemoves = false;
      await raw.remove(_receiptKey);
      expect(await disk.getAll(), isEmpty);
    },
  );

  for (final corruption in <String, String Function(String)>{
    'authentication tag': _badTag,
    'truncated frame': (_) => '${cacheCipherMagic}AA==',
    'invalid base64': (_) => '${cacheCipherMagic}not-base64!',
    'missing magic': (blob) => blob.substring(cacheCipherMagic.length),
    'empty stored string': (_) => '',
  }.entries) {
    test(
      'corrupt ${corruption.key} keeps the receipt fence across cold starts',
      () async {
        final raw = InMemoryKeyValueStore();
        final cache = _cache(raw);
        final entry = _entry();
        await cache.writeTrainingHistory([entry]);
        expect(
          await cache.writeTrainingSession(entry.recoverySnapshot()),
          isTrue,
        );
        expect(await cache.rememberTrainingHistoryDeletion(_first), isTrue);
        final validReceipt = raw.snapshot[_receiptKey]!;
        final corrupted = corruption.value(validReceipt);
        await raw.setString(_receiptKey, corrupted);

        // Only the receipt is damaged; stale mirrors really are still readable.
        expect((await cache.readTrainingHistory())!.single.id, _first);
        expect((await cache.readTrainingSession())!.sessionId, _first);
        await expectLater(
          cache.readTrainingHistoryDeletions(),
          throwsA(isA<UnreadableCacheSlot>()),
        );
        expect(raw.snapshot[_receiptKey], corrupted);
        final cold = _cache(raw);
        await expectLater(
          cold.readTrainingHistoryDeletions(),
          throwsA(isA<UnreadableCacheSlot>()),
        );
        await expectLater(
          cold.rememberTrainingHistoryDeletion(_second),
          throwsA(isA<UnreadableCacheSlot>()),
        );
        expect(raw.snapshot[_receiptKey], corrupted);

        await cold.clear(preserveOutbox: true);
        expect(
          raw.snapshot[_receiptKey],
          corrupted,
          reason: 'logout must not turn unknown deletions into no deletions',
        );
        final retry = _cache(raw);
        await expectLater(
          retry.readTrainingHistoryDeletions(),
          throwsA(isA<UnreadableCacheSlot>()),
        );
        // An actual repair can succeed on Retry; the failure is never memoized.
        await raw.setString(_receiptKey, validReceipt);
        expect(await retry.readTrainingHistoryDeletions(), {_first});
        await raw.setString(_receiptKey, corrupted);
        await retry.clear();
        expect(
          raw.snapshot.containsKey(_receiptKey),
          isFalse,
          reason: 'explicit account deletion still removes a damaged fence',
        );
        expect(await _cache(raw).readTrainingHistoryDeletions(), isEmpty);
      },
    );
  }

  test(
    'decrypted but invalid receipt JSON remains occupied and sanitized',
    () async {
      final raw = InMemoryKeyValueStore();
      final cipher = _cipher();
      final cache = _cache(raw, cipher: cipher);
      for (final content in [
        '',
        '{sensitive invalid JSON',
        '[]',
        '{"ids":null}',
      ]) {
        final blob = await cipher.encrypt(_receiptKey, content);
        await raw.setString(_receiptKey, blob);
        await expectLater(
          cache.readTrainingHistoryDeletions(),
          throwsA(
            isA<FormatException>().having(
              (error) => error.toString(),
              'diagnostic',
              isNot(contains('sensitive')),
            ),
          ),
        );
        expect(raw.snapshot[_receiptKey], blob);
      }
    },
  );

  testWidgets(
    'timed-out old encryption and relogin merge without bypassing the queue',
    (tester) async {
      final raw = InMemoryKeyValueStore();
      final held = _HeldCipher();
      final old = _cache(raw, cipher: held);
      final oldWrite = old.rememberTrainingHistoryDeletion(_first);
      await tester.pump();
      expect(held.writes, 1);
      final closing = LocalCache.closeInstancesFor(_owner);
      await tester.pump(
        LocalCache.settleBudget + const Duration(milliseconds: 1),
      );
      await closing;
      expect(await oldWrite, isFalse);
      await _cache(raw).clear(preserveOutbox: true);

      final relogin = _cache(raw);
      var nextFinished = false;
      final nextWrite = relogin.rememberTrainingHistoryDeletion(_second).then((
        saved,
      ) {
        nextFinished = true;
        return saved;
      });
      await tester.pump();
      expect(
        nextFinished,
        isFalse,
        reason: 'new account instance cannot overtake old encryption',
      );
      expect(raw.snapshot[_receiptKey], isNull);
      expect(
        await _cache(
          raw,
          owner: 'receipt-security-B',
        ).rememberTrainingHistoryDeletion(_second),
        isTrue,
        reason: 'another account has its own independent queue',
      );

      final blockedRead = expectLater(
        relogin.readTrainingHistoryDeletions(),
        throwsA(
          isA<UnreadableCacheSlot>().having(
            (error) => error.transient,
            'retryable',
            isTrue,
          ),
        ),
      );
      await tester.pump(
        LocalCache.settleBudget + const Duration(milliseconds: 1),
      );
      await blockedRead;
      expect(
        await nextWrite,
        isFalse,
        reason: 'stuck mutation reports failure within the budget',
      );
      expect(
        raw.snapshot[_receiptKey],
        isNull,
        reason: 'timeout must not release the namespace lock',
      );

      held.release.complete();
      await tester.pump();
      await relogin.settle();
      expect(await relogin.readTrainingHistoryDeletions(), {_first, _second});
      final cold = _cache(InMemoryKeyValueStore(raw.snapshot));
      expect(await cold.readTrainingHistoryDeletions(), {_first, _second});
    },
  );

  testWidgets(
    'account deletion stays ordered after a receipt write exceeds its budget',
    (tester) async {
      final raw = InMemoryKeyValueStore();
      final held = _HeldCipher();
      final old = _cache(raw, cipher: held);
      final write = old.rememberTrainingHistoryDeletion(_first);
      await tester.pump();
      expect(held.writes, 1);
      old.close();
      final purge = _cache(raw);
      final purged = expectLater(
        purge.clear(),
        throwsA(isA<TimeoutException>()),
      );
      await tester.pump(
        LocalCache.settleBudget + const Duration(milliseconds: 1),
      );
      await purged;
      expect(await write, isFalse);
      final next = _cache(raw);
      final nextWrite = next.rememberTrainingHistoryDeletion(_second);
      await tester.pump();
      expect(raw.snapshot[_receiptKey], isNull);

      held.release.complete();
      await tester.pump();
      expect(await nextWrite, isTrue);
      expect(
        await next.readTrainingHistoryDeletions(),
        {_second},
        reason:
            'purge follows the old write and precedes the new namespace write',
      );
      expect(
        await _cache(
          InMemoryKeyValueStore(raw.snapshot),
        ).readTrainingHistoryDeletions(),
        {_second},
      );
    },
  );

  test(
    'failed dependent cleanup preserves cold-start receipt and releases its reserved barrier',
    () async {
      final raw = _FailingRemovalStorage();
      addTearDown(() {
        if (!raw.release.isCompleted) raw.release.complete();
      });
      final old = _cache(raw);
      final entry = _entry();
      await old.writeTrainingHistory([entry]);
      expect(await old.writeTrainingSession(entry.recoverySnapshot()), isTrue);
      expect(await old.rememberTrainingHistoryDeletion(_first), isTrue);
      final receiptBefore = raw.snapshot[_receiptKey];
      raw.failingKey = 'eatova.v1.profile.$_owner';
      final cleanup = expectLater(
        old.clear(),
        throwsA(
          isA<UnwritableCacheSlot>().having(
            (error) => error.toString(),
            'sanitized failure',
            isNot(contains('private fixture payload')),
          ),
        ),
      );
      await raw.entered.future;

      // Reserving the receipt operation only AFTER cleanup would let this new
      // instance pass and its receipt would later be erased by a successful purge.
      final next = _cache(raw);
      var nextFinished = false;
      final nextWrite = next.rememberTrainingHistoryDeletion(_second).then((
        saved,
      ) {
        nextFinished = true;
        return saved;
      });
      await pumpEventQueue();
      final finishedBeforeRelease = nextFinished;
      final removesBeforeRelease = raw.receiptRemoves;
      final receiptDuringCleanup = raw.snapshot[_receiptKey];
      raw.release.complete();
      await cleanup;
      expect(
        await nextWrite,
        isTrue,
        reason: 'failed cleanup releases the barrier for a safe retry',
      );
      final cold = _cache(InMemoryKeyValueStore(raw.snapshot));
      expect((await cold.readTrainingHistory())!.single.id, _first);
      expect((await cold.readTrainingSession())!.sessionId, _first);
      expect(
        await cold.readTrainingHistoryDeletions(),
        {_first, _second},
        reason:
            'stale payloads remain fenced after restart despite the failed cleanup',
      );
      expect(
        finishedBeforeRelease,
        isFalse,
        reason: 'cleanup owns its reserved namespace position',
      );
      expect(
        removesBeforeRelease,
        0,
        reason:
            'the receipt cannot be removed while dependent cleanup is incomplete',
      );
      expect(receiptDuringCleanup, receiptBefore);
      expect(raw.receiptRemoves, 0);

      raw.failingKey = null;
      await next.clear();
      expect(raw.snapshot.containsKey(_receiptKey), isFalse);
      expect(
        raw.snapshot.containsKey('eatova.v1.training_history.$_owner'),
        isFalse,
      );
      expect(
        raw.snapshot.containsKey('eatova.v1.training_session.$_owner'),
        isFalse,
      );
    },
  );

  testWidgets(
    'failed cleanup releases its barrier behind a timed-out old encryption',
    (tester) async {
      const third = '33333333-3333-4333-8333-333333333333';
      final raw = _FailingRemovalStorage();
      expect(await _cache(raw).rememberTrainingHistoryDeletion(_first), isTrue);
      final held = _HeldCipher();
      final old = _cache(raw, cipher: held);
      final oldWrite = old.rememberTrainingHistoryDeletion(_second);
      await tester.pump();
      expect(held.writes, 1);
      old.close();
      raw.failingKey = 'eatova.v1.profile.$_owner';
      raw.release.complete();
      await expectLater(
        _cache(raw).clear(),
        throwsA(isA<UnwritableCacheSlot>()),
      );
      final next = _cache(raw);
      final nextWrite = next.rememberTrainingHistoryDeletion(third);
      await tester.pump(
        LocalCache.settleBudget + const Duration(milliseconds: 1),
      );
      expect(await oldWrite, isFalse);
      expect(await nextWrite, isFalse);
      expect(raw.receiptRemoves, 0);

      held.release.complete();
      await tester.pump();
      expect(await next.readTrainingHistoryDeletions(), {
        _first,
        _second,
        third,
      });
      expect(
        raw.receiptRemoves,
        0,
        reason:
            'the failed cleanup reservation releases without deleting any receipt',
      );
    },
  );
}
