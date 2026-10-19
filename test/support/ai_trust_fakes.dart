// Fakes for the AI consent and report path (2026-10-19): an in-memory server
// log, an in-memory account cache and a helper that mounts an app below an
// AiTrustScope, the way EatovaApp does.
// Deliberately no `_test` suffix — this file is not a suite.

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:eatova/src/app/ai_trust.dart';
import 'package:eatova/src/models/ai_consent.dart';
import 'package:eatova/src/services/ai_trust_sync.dart';

/// A fixed server timestamp for logged rows.
final DateTime kLoggedAt = DateTime.utc(2026, 10, 19, 9, 30);

/// The server logs in memory. [failWrites] makes every insert throw (offline);
/// [gate] holds inserts until completed, to test what happens meanwhile.
class FakeAiTrustLog implements AiConsentLog, AiReportLog {
  FakeAiTrustLog({List<AiConsentRecord>? rows}) : rows = rows ?? [];

  final List<AiConsentRecord> rows;
  final List<
    ({
      String messageId,
      String? sessionId,
      AiReportTarget target,
      AiReportReason reason,
    })
  >
  reports = [];
  bool failWrites = false;
  bool failReads = false;
  bool failReports = false;
  Completer<void>? gate;
  int latestCalls = 0;

  @override
  Future<AiConsentRecord> record({
    required bool granted,
    required bool healthData,
    int version = kAiConsentVersion,
  }) async {
    final hold = gate;
    if (hold != null) await hold.future;
    if (failWrites) throw const SocketExceptionLike();
    final row = AiConsentRecord(
      version: version,
      granted: granted,
      healthData: healthData,
      decidedAt: kLoggedAt.add(Duration(minutes: rows.length)),
    );
    rows.add(row);
    return row;
  }

  @override
  Future<AiConsentRecord?> latest() async {
    latestCalls++;
    if (failReads) throw const SocketExceptionLike();
    return rows.isEmpty ? null : rows.last;
  }

  @override
  Future<void> report({
    required String messageId,
    String? sessionId,
    required AiReportTarget target,
    required AiReportReason reason,
  }) async {
    if (failReports) throw const SocketExceptionLike();
    reports.add((
      messageId: messageId,
      sessionId: sessionId,
      target: target,
      reason: reason,
    ));
  }
}

/// Stands in for a network error without touching dart:io.
class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}

/// The account cache slot in memory.
class MemoryAiConsentCache implements AiConsentCache {
  MemoryAiConsentCache([this.stored]);

  AiConsentRecord? stored;
  int writes = 0;

  @override
  Future<AiConsentRecord?> readAiConsent() async => stored;

  @override
  Future<void> writeAiConsent(AiConsentRecord record) async {
    writes++;
    stored = record;
  }
}

/// A logged grant of the current text.
AiConsentRecord grantedRecord() => AiConsentRecord(
  version: kAiConsentVersion,
  granted: true,
  healthData: true,
  decidedAt: kLoggedAt,
);

/// A controller over [log] and [cache]; [loaded] runs its load first.
Future<AiTrustController> aiTrustController({
  FakeAiTrustLog? log,
  MemoryAiConsentCache? cache,
  bool loaded = true,
}) async {
  final serverLog = log ?? FakeAiTrustLog();
  final controller = AiTrustController(
    cache: cache ?? MemoryAiConsentCache(),
    consentLog: serverLog,
    reportLog: serverLog,
  );
  if (loaded) await controller.load();
  return controller;
}

/// [app] below an [AiTrustScope] bound to [controller] (null: a scope with no
/// account bound, as before sign-in).
Widget withAiTrust(AiTrustController? controller, Widget app) {
  final binding = AiTrustBinding();
  if (controller != null) binding.bind(controller);
  return AiTrustScope(binding: binding, child: app);
}
