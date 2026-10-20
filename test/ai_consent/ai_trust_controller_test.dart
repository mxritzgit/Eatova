// The account's AI consent state (review 2026-10-19, P1): a grant counts only
// once the server logged it, a withdrawal works at once on the device and
// stays pending until the server has it, and no server read turns a pending
// withdrawal back into a grant.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/ai_trust.dart';
import 'package:eatova/src/models/ai_consent.dart';
import 'package:eatova/src/services/ai_trust_sync.dart';

import '../support/ai_trust_fakes.dart';

void main() {
  group('Laden', () {
    test('ohne Eintrag ist nichts erlaubt, der Server wird gefragt', () async {
      final log = FakeAiTrustLog();
      final controller = await aiTrustController(log: log);

      expect(controller.loaded, isTrue);
      expect(controller.allowsAi, isFalse);
      expect(controller.record, isNull);
      expect(log.latestCalls, 1);
    });

    test('ein gecachter Grant gilt sofort, auch offline', () async {
      final log = FakeAiTrustLog()..failReads = true;
      final controller = await aiTrustController(
        log: log,
        cache: MemoryAiConsentCache(grantedRecord()),
      );

      expect(controller.allowsAi, isTrue);
    });

    test('ein anderes Geraet hat widerrufen: der Server gewinnt', () async {
      final log = FakeAiTrustLog(
        rows: [
          AiConsentRecord(
            version: kAiConsentVersion,
            granted: false,
            healthData: false,
            decidedAt: kLoggedAt,
          ),
        ],
      );
      final cache = MemoryAiConsentCache(grantedRecord());
      final controller = await aiTrustController(log: log, cache: cache);

      expect(controller.allowsAi, isFalse);
      expect(cache.stored?.granted, isFalse, reason: 'cache follows the log');
    });

    test('eine aeltere Fassung des Textes erlaubt nichts', () {
      final old = AiConsentRecord(
        version: kAiConsentVersion - 1,
        granted: true,
        healthData: true,
        decidedAt: kLoggedAt,
      );
      expect(old.allowsAi, isFalse);
    });

    test('ohne Gesundheitsdaten-Einwilligung ist nichts erlaubt', () {
      final partial = AiConsentRecord(
        version: kAiConsentVersion,
        granted: true,
        healthData: false,
        decidedAt: kLoggedAt,
      );
      expect(partial.allowsAi, isFalse);
    });

    test('Vorschau ohne Sync fragt nie', () {
      final preview = AiTrustController.preview();
      expect(preview.consentRequired, isFalse);
      expect(preview.allowsAi, isTrue);
      expect(preview.canRecord, isFalse);
      expect(preview.canReport, isFalse);
    });
  });

  group('Einwilligen', () {
    test('erst der Server-Eintrag, dann der Cache, dann erlaubt', () async {
      final log = FakeAiTrustLog();
      final cache = MemoryAiConsentCache();
      final controller = await aiTrustController(log: log, cache: cache);

      await controller.grant();

      expect(log.rows.single.granted, isTrue);
      expect(log.rows.single.healthData, isTrue);
      expect(log.rows.single.version, kAiConsentVersion);
      expect(controller.allowsAi, isTrue);
      expect(cache.stored, log.rows.single);
    });

    test('ohne Server kein Grant, auch nicht im Cache', () async {
      final log = FakeAiTrustLog()..failWrites = true;
      final cache = MemoryAiConsentCache();
      final controller = await aiTrustController(log: log, cache: cache);

      await expectLater(
        controller.grant(),
        throwsA(isA<SocketExceptionLike>()),
      );

      expect(controller.allowsAi, isFalse);
      expect(cache.stored, isNull);
    });

    test('ein offener Widerruf geht vor dem neuen Grant in den Log', () async {
      final log = FakeAiTrustLog()..failWrites = true;
      final controller = await aiTrustController(
        log: log,
        cache: MemoryAiConsentCache(grantedRecord()),
      );
      expect(await controller.withdraw(), isFalse);

      log.failWrites = false;
      await controller.grant();

      expect(log.rows.map((r) => r.granted), [false, true]);
      expect(controller.allowsAi, isTrue);
    });
  });

  group('Widerrufen', () {
    test('wirkt sofort und landet im Log', () async {
      final log = FakeAiTrustLog(rows: [grantedRecord()]);
      final controller = await aiTrustController(log: log);
      expect(controller.allowsAi, isTrue);

      final logged = controller.withdraw();
      // Before the server answered.
      expect(controller.allowsAi, isFalse);

      expect(await logged, isTrue);
      expect(log.rows.last.granted, isFalse);
      expect(controller.record?.pendingUpload, isFalse);
    });

    test('offline bleibt er offen, der naechste Abgleich laedt ihn hoch '
        'und ein Server-Grant macht ihn nicht rueckgaengig', () async {
      final log = FakeAiTrustLog(rows: [grantedRecord()]);
      final cache = MemoryAiConsentCache();
      final controller = await aiTrustController(log: log, cache: cache);

      log.failWrites = true;
      final withdrawn = await withClock(
        Clock.fixed(DateTime.utc(2026, 10, 19, 12)),
        controller.withdraw,
      );
      expect(withdrawn, isFalse);
      expect(controller.allowsAi, isFalse);
      expect(cache.stored?.pendingUpload, isTrue);

      // Still offline: the server's latest row is the old grant; it must
      // not come back.
      await controller.refresh();
      expect(controller.allowsAi, isFalse);
      expect(log.rows, hasLength(1));

      // A new session reads the pending withdrawal from the cache.
      log.failWrites = false;
      final next = await aiTrustController(log: log, cache: cache);
      expect(next.allowsAi, isFalse);
      expect(log.rows.last.granted, isFalse);
      expect(cache.stored?.pendingUpload, isFalse);
    });

    test('ein Widerruf waehrend des Grants ueberlebt dessen Antwort', () async {
      final log = FakeAiTrustLog();
      final controller = await aiTrustController(log: log);
      log.gate = Completer<void>();

      final granting = controller.grant();
      final withdrawing = controller.withdraw();
      log.gate!.complete();
      await granting;
      await withdrawing;

      expect(controller.allowsAi, isFalse);
      expect(log.rows.map((r) => r.granted), [true, false]);
    });
  });

  test(
    'ein Abgleich, der vor dem Grant startete, ueberschreibt ihn nicht',
    () async {
      final log = FakeAiTrustLog();
      final controller = AiTrustController(
        cache: MemoryAiConsentCache(),
        consentLog: _SlowLatest(log),
        reportLog: log,
      );
      final loading = controller.load();
      await Future<void>.delayed(Duration.zero);
      await controller.grant();
      _SlowLatest.release.complete();
      await loading;

      expect(controller.allowsAi, isTrue);
    },
  );

  test('nur ein Einwilligungsblatt fuer gleichzeitige Anfragen', () async {
    final controller = await aiTrustController();
    var asked = 0;
    final open = Completer<bool>();
    Future<bool> ask() {
      asked++;
      return open.future;
    }

    final first = controller.promptOnce(ask);
    final second = controller.promptOnce(ask);
    open.complete(true);

    expect(await first, isTrue);
    expect(await second, isTrue);
    expect(asked, 1);
    // Closed: the next request asks again.
    unawaited(controller.promptOnce(() async => false));
    expect(asked, 1);
  });

  test('Melden geht an den Report-Log, ohne Log scheitert es', () async {
    final log = FakeAiTrustLog();
    final controller = await aiTrustController(log: log);

    await controller.report(
      messageId: 'm-1',
      sessionId: 's-1',
      target: AiReportTarget.answer,
      reason: AiReportReason.harmful,
    );
    expect(log.reports.single.messageId, 'm-1');
    expect(log.reports.single.reason, AiReportReason.harmful);

    await expectLater(
      AiTrustController.preview().report(
        messageId: 'm-1',
        target: AiReportTarget.answer,
        reason: AiReportReason.other,
      ),
      throwsStateError,
    );
  });
}

/// A log whose first read answers only after [release]: the server's "no
/// consent yet" lands after a grant on the device.
class _SlowLatest implements AiConsentLog {
  _SlowLatest(this._inner);

  static Completer<void> release = Completer<void>();
  final FakeAiTrustLog _inner;
  bool _first = true;

  @override
  Future<AiConsentRecord?> latest() async {
    if (_first) {
      _first = false;
      const AiConsentRecord? none = null;
      await release.future;
      return none;
    }
    return _inner.latest();
  }

  @override
  Future<AiConsentRecord> record({
    required bool granted,
    required bool healthData,
    int version = kAiConsentVersion,
  }) =>
      _inner.record(granted: granted, healthData: healthData, version: version);
}
