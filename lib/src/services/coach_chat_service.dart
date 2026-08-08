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

  /// Schickt die User-Nachricht an die Edge Function.
  ///
  /// Fehlerbehandlung liegt komplett in den `on Functions*`-Armen: der
  /// functions_client liefert Nicht-2xx NICHT als [FunctionResponse.status]
  /// zurueck, sondern wirft (functions_client.dart:255-269). Nur ein 429 mit
  /// `error: quota_exceeded` wird zu [CoachQuotaExceeded] — jeder andere
  /// Fehler, auch ein 429 vom Burst-Rate-Limit, zu [CoachChatException] mit
  /// einer anzeigbaren deutschen Meldung. Optional kann ein komprimiertes Bild als Base64
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
      // Hier ankommen heisst: 2xx. functions_client wirft bei jedem anderen
      // Status (functions_client.dart:255-269), deshalb steht die
      // Fehlerbehandlung ausschliesslich in den `on Functions*`-Armen unten.
      final data = res.data;
      final map = data is Map ? data : const <dynamic, dynamic>{};
      final reply = map['reply'] is String
          ? (map['reply'] as String).trim()
          : '';
      if (reply.isEmpty) {
        throw const CoachChatException('Leere Antwort vom Coach.');
      }
      return CoachChatReply(
        reply: reply,
        refusal: map['refusal'] == true,
        refusalReason: map['refusal_reason']?.toString(),
        remaining: map['remaining'] is num
            ? (map['remaining'] as num).toInt()
            : null,
        sessionId: map['session_id']?.toString() ?? sessionId,
      );
    } on CoachQuotaExceeded {
      rethrow;
    } on CoachChatException {
      rethrow;
    } on FunctionsHttpException catch (e, stack) {
      // Die Edge Function selbst hat mit Nicht-2xx geantwortet
      // (functions_client.dart:265-269).
      _logSendFailure(e, stack);
      throw _failureForStatus(e.status, e.details);
    } on FunctionsRelayException catch (e, stack) {
      // Eigener Typ: der Supabase-Relay VOR der Function hat abgebrochen
      // (Header `x-relay-error`, functions_client.dart:258-264). Die Function
      // lief hier nie, also gibt es auch keine fachliche Aussage im Body —
      // das ist immer eine Infrastruktur-Stoerung.
      _logSendFailure(e, stack);
      throw const CoachChatException(_unreachableMessage);
    } on FunctionsFetchException catch (e, stack) {
      // Die Anfrage ging gar nicht erst raus (functions_client.dart:206-208).
      _logSendFailure(e, stack);
      throw const CoachChatException(
        'Keine Verbindung zum Coach. Prüf deine Internetverbindung und '
        'versuch es nochmal.',
      );
    } catch (e, stack) {
      _logSendFailure(e, stack);
      throw const CoachChatException(_unreachableMessage);
    }
  }

  static const String _unreachableMessage =
      'Der Coach ist gerade nicht erreichbar. Bitte versuch es gleich nochmal.';

  void _logSendFailure(Object error, StackTrace stack) {
    dev.log(
      'CoachChatService.send failed',
      error: error,
      stackTrace: stack,
      name: 'eatova.coach',
    );
  }

  /// Uebersetzt einen Fehlerstatus der Edge Function in die Exception, die der
  /// Coach-Screen versteht. Rohe Serverdaten landen NIE in der Meldung: nur
  /// eine von [_serverReply] freigegebene Klartext-Zeile oder ein fester
  /// deutscher Text.
  Exception _failureForStatus(int status, dynamic details) {
    // `details` ist dynamic: bei unserer Function ein JSON-Objekt, beim
    // Gateway auch mal Klartext oder eine HTML-Seite. Alles ausser einer Map
    // wird zu einer leeren Map — damit wirft keiner der Zugriffe unten.
    final map = details is Map ? details : const <dynamic, dynamic>{};
    final serverReply = _serverReply(map);

    // 401/403: die Session ist weg. Der Nutzer soll sich neu anmelden statt
    // "unbekannter Fehler" zu lesen; die Function schickt hier ohnehin nur
    // {"error":"Unauthorized"} ohne anzeigbaren Text.
    if (status == 401 || status == 403) {
      return const CoachChatException(
        'Deine Sitzung ist abgelaufen. Bitte melde dich neu an, dann '
        'antwortet der Coach wieder.',
      );
    }

    if (status == 429) {
      // NUR quota_exceeded ist das Tageslimit. `rate_limited` (Burst-Schutz)
      // traegt kein daily_limit und darf den Composer nicht fuer den Rest des
      // Tages sperren — der Nutzer darf gleich wieder senden.
      if (map['error'] == 'quota_exceeded') {
        final limit = map['daily_limit'];
        return CoachQuotaExceeded(
          message: serverReply ?? 'Tageslimit erreicht. Morgen geht\'s weiter.',
          dailyLimit: limit is num ? limit.toInt() : 5,
        );
      }
      return CoachChatException(
        serverReply ?? 'Zu viele Anfragen. Bitte versuch es gleich nochmal.',
      );
    }

    if (status == 413) {
      return CoachChatException(
        serverReply ??
            'Das Bild ist zu groß für den Coach. Bitte schick ein kleineres.',
      );
    }

    if (status >= 500) {
      // 5xx-Bodies sind Interna ("rpc_unavailable", Gateway-HTML) — nie
      // anzeigen, auch wenn ein reply-Feld dabei waere.
      return const CoachChatException(_unreachableMessage);
    }

    return CoachChatException(
      serverReply ?? 'Der Coach konnte deine Anfrage nicht verarbeiten.',
    );
  }

  /// Gibt den vom Server formulierten Anzeigetext frei — oder null, wenn er
  /// nicht wie eine fertige deutsche Meldung aussieht.
  ///
  /// Bewusst streng: `details` kann eine HTML-Fehlerseite, ein Stacktrace oder
  /// ein JSON-Fragment sein. Was hier durchfaellt, wird vom Aufrufer durch
  /// einen festen Text ersetzt — lieber generisch als ein Roh-Dump auf dem
  /// Bildschirm.
  static String? _serverReply(Map<dynamic, dynamic> details) {
    final raw = details['reply'];
    if (raw is! String) return null;
    final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty || text.length > 240) return null;
    // Markup- und Dump-Fragmente aussortieren.
    if (RegExp(r'[<>{}]').hasMatch(text)) return null;
    return text;
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
