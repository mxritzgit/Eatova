import 'dart:developer' as dev;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/ai_consent.dart';

/// The server log of AI consent decisions (`public.ai_consents`).
abstract interface class AiConsentLog {
  /// Logs one decision and returns the stored row. Throws on any failure: a
  /// grant counts only once the server has it.
  Future<AiConsentRecord> record({
    required bool granted,
    required bool healthData,
    int version = kAiConsentVersion,
  });

  /// The latest logged decision, null when the account has none. Throws when
  /// the log cannot be read.
  Future<AiConsentRecord?> latest();
}

/// The server log of reported Coach output (`public.ai_reports`).
abstract interface class AiReportLog {
  /// Files one report. Throws on any failure.
  Future<void> report({
    required String messageId,
    String? sessionId,
    required AiReportTarget target,
    required AiReportReason reason,
  });
}

/// Message ids the report table accepts (`ai_reports_message_id_check`):
/// server UUIDs and the client's local ids, never content.
final RegExp _messageIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
final RegExp _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// Whether a report for [messageId] can be filed at all.
bool isReportableMessageId(String messageId) =>
    _messageIdPattern.hasMatch(messageId);

/// Both logs over PostgREST for one account. Every request carries the bearer
/// of [_userId]'s session, checked before the call like `userRpc`, so a
/// decision taken just before an account switch can never land on the next
/// account.
class AiTrustSync implements AiConsentLog, AiReportLog {
  AiTrustSync(this._client, this._userId);

  final SupabaseClient _client;
  final String _userId;

  static const String _consentColumns =
      'version, granted, health_data, created_at';

  Future<String> _authorization() async {
    var session = _client.auth.currentSession;
    if (session == null || session.user.id != _userId) {
      throw const AuthException('Session changed');
    }
    if (session.isExpired) {
      await _client.auth.refreshSession();
      session = _client.auth.currentSession;
    }
    if (session == null || session.user.id != _userId) {
      throw const AuthException('Session changed');
    }
    return 'Bearer ${session.accessToken}';
  }

  @override
  Future<AiConsentRecord> record({
    required bool granted,
    required bool healthData,
    int version = kAiConsentVersion,
  }) async {
    try {
      final authorization = await _authorization();
      final row = await _client
          .from('ai_consents')
          .insert(<String, dynamic>{
            'version': version,
            'granted': granted,
            'health_data': healthData,
          })
          .select(_consentColumns)
          .single()
          .setHeader('Authorization', authorization);
      final record = AiConsentRecord.fromRow(row);
      if (record == null) {
        throw const FormatException('ai_consents row off the contract');
      }
      return record;
    } catch (e, st) {
      dev.log(
        'AiTrustSync.record failed',
        error: e,
        stackTrace: st,
        name: 'ai_trust_sync',
      );
      rethrow;
    }
  }

  @override
  Future<AiConsentRecord?> latest() async {
    try {
      final authorization = await _authorization();
      final rows = await _client
          .from('ai_consents')
          .select(_consentColumns)
          .eq('user_id', _userId)
          .order('created_at', ascending: false)
          .limit(1)
          .setHeader('Authorization', authorization);
      if (rows.isEmpty) return null;
      final record = AiConsentRecord.fromRow(rows.first);
      if (record == null) {
        throw const FormatException('ai_consents row off the contract');
      }
      return record;
    } catch (e, st) {
      dev.log(
        'AiTrustSync.latest failed',
        error: e,
        stackTrace: st,
        name: 'ai_trust_sync',
      );
      rethrow;
    }
  }

  @override
  Future<void> report({
    required String messageId,
    String? sessionId,
    required AiReportTarget target,
    required AiReportReason reason,
  }) async {
    if (!isReportableMessageId(messageId)) {
      throw ArgumentError.value(messageId, 'messageId', 'not reportable');
    }
    try {
      final authorization = await _authorization();
      await _client
          .from('ai_reports')
          .insert(<String, dynamic>{
            'message_id': messageId,
            if (sessionId != null && _uuidPattern.hasMatch(sessionId))
              'session_id': sessionId,
            'target': target.code,
            'reason': reason.code,
          })
          .setHeader('Authorization', authorization);
    } catch (e, st) {
      dev.log(
        'AiTrustSync.report failed',
        error: e,
        stackTrace: st,
        name: 'ai_trust_sync',
      );
      rethrow;
    }
  }
}
