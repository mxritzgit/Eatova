import 'dart:developer' as dev;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/chat_message.dart';
import '../models/chat_session.dart';

/// Coach-Chat Backend-Brücke.
///
/// Rate-Limit (5/Tag), Safety-Filter und Grok-Call laufen alle in der
/// Edge Function `coach-chat`. Hier passiert nur:
///   - Historie aus public.chat_messages laden (RLS schraenkt automatisch
///     auf den eigenen User ein).
///   - send() ruft die Edge Function auf und bekommt die Assistant-
///     Antwort + neuen Quota-Rest zurueck.
///   - loadQuotaToday() liest den Counter via get_chat_quota_today RPC.
///   - Sessions: list / create / rename / delete via RPCs.
class CoachChatService {
  CoachChatService(this._client, this._userId);

  final SupabaseClient _client;
  final String _userId;

  // -------------------------------------------------------------------------
  // Sessions
  // -------------------------------------------------------------------------
  Future<List<ChatSession>> loadSessions() async {
    try {
      final res = await _client.rpc('list_chat_sessions');
      if (res is! List) return const <ChatSession>[];
      return res
          .map<ChatSession>((row) =>
              ChatSession.fromRow((row as Map).cast<String, dynamic>()))
          .toList();
    } catch (e, stack) {
      dev.log(
        'CoachChatService.loadSessions failed',
        error: e,
        stackTrace: stack,
        name: 'eatova.coach',
      );
      return const <ChatSession>[];
    }
  }

  /// Liefert die Default-Session-ID; legt bei Bedarf eine an.
  Future<String?> ensureDefaultSession() async {
    try {
      final res = await _client.rpc('ensure_default_chat_session');
      if (res is String) return res;
      if (res is List && res.isNotEmpty) return res.first.toString();
      return null;
    } catch (e, stack) {
      dev.log(
        'CoachChatService.ensureDefaultSession failed',
        error: e,
        stackTrace: stack,
        name: 'eatova.coach',
      );
      return null;
    }
  }

  Future<String?> createSession({String title = 'Neue Unterhaltung'}) async {
    try {
      final res = await _client.rpc(
        'create_chat_session',
        params: {'p_title': title},
      );
      if (res is String) return res;
      if (res is List && res.isNotEmpty) return res.first.toString();
      return null;
    } catch (e, stack) {
      dev.log(
        'CoachChatService.createSession failed',
        error: e,
        stackTrace: stack,
        name: 'eatova.coach',
      );
      return null;
    }
  }

  Future<void> renameSession(String sessionId, String title) async {
    try {
      await _client.rpc('rename_chat_session', params: {
        'p_session_id': sessionId,
        'p_title': title,
      });
    } catch (e, stack) {
      dev.log(
        'CoachChatService.renameSession failed',
        error: e,
        stackTrace: stack,
        name: 'eatova.coach',
      );
    }
  }

  Future<void> deleteSession(String sessionId) async {
    try {
      await _client.rpc('delete_chat_session', params: {
        'p_session_id': sessionId,
      });
    } catch (e, stack) {
      dev.log(
        'CoachChatService.deleteSession failed',
        error: e,
        stackTrace: stack,
        name: 'eatova.coach',
      );
    }
  }

  // -------------------------------------------------------------------------
  // Historie / Quota / Send
  // -------------------------------------------------------------------------
  /// Letzte n Nachrichten in chronologischer Reihenfolge, gefiltert auf eine
  /// Session.
  Future<List<ChatMessage>> loadHistory(
    String sessionId, {
    int limit = 100,
  }) async {
    try {
      final rows = await _client
          .from('chat_messages')
          .select('id, role, content, refusal, created_at')
          .eq('user_id', _userId)
          .eq('session_id', sessionId)
          .inFilter('role', ['user', 'assistant'])
          .order('created_at', ascending: false)
          .limit(limit);
      final list = rows.map<ChatMessage>((row) {
        return ChatMessage.fromRow((row as Map).cast<String, dynamic>());
      }).toList();
      return list.reversed.toList();
    } catch (e, stack) {
      dev.log(
        'CoachChatService.loadHistory failed',
        error: e,
        stackTrace: stack,
        name: 'eatova.coach',
      );
      return const <ChatMessage>[];
    }
  }

  Future<ChatQuotaSnapshot> loadQuotaToday() async {
    try {
      final res = await _client.rpc(
        'get_chat_quota_today',
        params: {'p_daily_limit': 5},
      );
      // RPC liefert table-return als Liste.
      final row = res is List && res.isNotEmpty
          ? (res.first as Map).cast<String, dynamic>()
          : (res is Map ? res.cast<String, dynamic>() : const <String, dynamic>{});
      return ChatQuotaSnapshot(
        used: (row['used'] as num?)?.toInt() ?? 0,
        remaining: (row['remaining'] as num?)?.toInt() ?? 5,
        dailyLimit: (row['daily_limit'] as num?)?.toInt() ?? 5,
      );
    } catch (e, stack) {
      dev.log(
        'CoachChatService.loadQuotaToday failed',
        error: e,
        stackTrace: stack,
        name: 'eatova.coach',
      );
      return ChatQuotaSnapshot.unknown;
    }
  }

  /// Schickt die User-Nachricht an die Edge Function. Bei 429 wird
  /// [CoachQuotaExceeded] geworfen - bei Netzwerk- oder Serverfehlern
  /// [CoachChatException]. Optional kann ein komprimiertes Bild als Base64
  /// mitgeschickt werden; die eigentliche Vision-/Safety-Logik bleibt
  /// serverseitig in Supabase.
  Future<CoachChatReply> send(
    String message, {
    required String sessionId,
    String? imageBase64,
    String? imageMimeType,
    String? userContext,
  }) async {
    try {
      final res = await _client.functions.invoke(
        'coach-chat',
        body: {
          'message': message,
          'session_id': sessionId,
          if (imageBase64 != null && imageBase64.isNotEmpty)
            'image_base64': imageBase64,
          if (imageMimeType != null && imageMimeType.isNotEmpty)
            'image_mime_type': imageMimeType,
          if (userContext != null && userContext.trim().isNotEmpty)
            'user_context': userContext.trim(),
        },
      );
      final status = res.status;
      final data = res.data;
      final map = data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};
      if (status == 429 || map['error'] == 'quota_exceeded') {
        throw CoachQuotaExceeded(
          message: (map['reply'] as String?) ??
              'Tageslimit erreicht. Morgen geht\'s weiter.',
          dailyLimit: (map['daily_limit'] as num?)?.toInt() ?? 5,
        );
      }
      if (status < 200 || status >= 300) {
        throw CoachChatException(
          (map['error'] as String?) ?? 'Unbekannter Fehler ($status).',
        );
      }
      final reply = (map['reply'] as String?)?.trim() ?? '';
      if (reply.isEmpty) {
        throw const CoachChatException('Leere Antwort vom Coach.');
      }
      return CoachChatReply(
        reply: reply,
        refusal: map['refusal'] == true,
        refusalReason: map['refusal_reason']?.toString(),
        remaining: (map['remaining'] as num?)?.toInt(),
        sessionId: map['session_id']?.toString() ?? sessionId,
      );
    } on CoachQuotaExceeded {
      rethrow;
    } on CoachChatException {
      rethrow;
    } catch (e, stack) {
      dev.log(
        'CoachChatService.send failed',
        error: e,
        stackTrace: stack,
        name: 'eatova.coach',
      );
      throw CoachChatException(e.toString());
    }
  }
}

class CoachChatReply {
  const CoachChatReply({
    required this.reply,
    required this.refusal,
    required this.sessionId,
    this.refusalReason,
    this.remaining,
  });

  final String reply;
  final bool refusal;
  final String sessionId;
  final String? refusalReason;
  final int? remaining;
}

class CoachChatException implements Exception {
  const CoachChatException(this.message);
  final String message;
  @override
  String toString() => 'CoachChatException: $message';
}

class CoachQuotaExceeded implements Exception {
  const CoachQuotaExceeded({required this.message, required this.dailyLimit});
  final String message;
  final int dailyLimit;
}
