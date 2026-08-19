import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../l10n/l10n.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../models/coach_recipe_proposal.dart';
import 'crash_reporter.dart';
import 'sync_error_messages.dart';

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

  /// Sprachpaket fuer die Fallback-Fehlertexte aus [send]/[_failureForStatus]
  /// (user-sichtbar im Coach-`_ErrorBanner`). Der Service haelt bewusst
  /// keinen BuildContext — der Coach-Screen liest `context.l10n` ohnehin
  /// unmittelbar vor jedem Sendeversuch frisch (Aufruf-Trap: nicht in
  /// initState) und reicht es hier direkt rein, statt die `send()`-Signatur
  /// zu aendern. Eine geaenderte Signatur haette jeden `@override send(...)`
  /// in den Test-Doubles (`coach_design_test.dart`,
  /// `coach_image_privacy_test.dart` u.a.) mitgerissen — mit diesem Setter
  /// bleiben deren Konstruktoren (`super.client, super.userId`) unveraendert.
  /// Default Deutsch ([deL10n]): `test/coach_error_mapping_test.dart` ruft
  /// [send] weiterhin kontextfrei und bleibt damit unveraendert gruen.
  AppLocalizations _l10n = deL10n;

  set l10n(AppLocalizations value) => _l10n = value;

  /// Request-locale fuer die Edge Function — dieselbe Normalisierung wie in
  /// [requestRecipe] (:341); alles ausser en faellt serverseitig ohnehin auf de.
  String get _localeCode =>
      _l10n.localeName.toLowerCase().startsWith('en') ? 'en' : 'de';

  // -------------------------------------------------------------------------
  // Diagnose
  // -------------------------------------------------------------------------
  /// Meldet einen Fehlerpfad an den [CrashReporter] — aber nur, wenn er
  /// ueberhaupt etwas bedeutet.
  ///
  /// Bis zum Komplettreview 2026-08-19 endete JEDER Fehlerarm dieser Klasse
  /// ausschliesslich in einem `dev.log`, und das schreibt nur in die lokale
  /// Geraete-/IDE-Konsole. Der Coach war damit der einzige Bereich der App
  /// ohne einen einzigen Crash-Reporter-Ausloeser: ein Totalausfall der Edge
  /// Function — 500er ueber Stunden, ein kaputter RPC nach einer Migration —
  /// war in der Produktion schlicht unsichtbar.
  ///
  /// Netzfehler bleiben draussen, dieselbe Klassifizierung wie in
  /// [CrashReporter.captureSyncFailure] und aus demselben Grund: der Coach
  /// setzt beim Oeffnen Sitzungsliste, Verlauf UND Tageszaehler ab. Ohne
  /// diesen Filter erzeugte eine U-Bahn-Fahrt drei Reports pro Tab-Wechsel,
  /// und das Sentry-Kontingent waere verbraucht, bevor der erste echte
  /// Ausfall ankommt.
  ///
  /// [operation] ist IMMER ein Literal aus dem Quelltext und wird zum
  /// Sentry-Tag `context`. Nie etwas anderes: Nachrichtentexte, Rezeptwuensche,
  /// Sitzungstitel und Ids haben in einem Report nichts verloren — die App
  /// verarbeitet Gesundheitsdaten. Das Fehlerobjekt selbst deckelt ohnehin
  /// `sanitizeForReport` (Allowlist, s. crash_reporter.dart).
  static void _melde(String operation, Object error, StackTrace stack) {
    if (isNetworkSyncError(error)) return;
    unawaited(CrashReporter.capture(error, stack, context: operation));
  }

  /// Ob ein Fehlerstatus der Edge Function einen Vorfall beschreibt.
  ///
  /// 401/403 (Sitzung abgelaufen), 413 (Bild zu gross) und 429 (Tageslimit
  /// bzw. Burst-Bremse) sind VORGESEHENE Antworten: sie stehen als Text im
  /// Banner und sind kein Fehler des Systems, sondern seine Funktionsweise.
  /// Ein Report daraus waere reines Rauschen — und zwar ausgerechnet
  /// nutzerproportionales. Alles andere, insbesondere jedes 5xx, ist der
  /// Ausfall, den sonst niemand sieht.
  static bool _statusIstVorfall(int status) =>
      status != 401 && status != 403 && status != 413 && status != 429;

  // -------------------------------------------------------------------------
  // Sessions
  // -------------------------------------------------------------------------
  /// Die Sessions des Nutzers.
  ///
  /// Wirft [CoachDataUnavailable], statt bei einem Fehler eine leere Liste zu
  /// liefern: „offline" und „du hast noch keine Unterhaltung" sind zwei
  /// verschiedene Aussagen, und die leere Liste hat die zweite behauptet,
  /// wenn nur die erste zutraf — das Sessions-Sheet raeumte sich dann selbst
  /// leer.
  Future<List<ChatSession>> loadSessions() async {
    final dynamic res;
    try {
      res = await _client.rpc('list_chat_sessions');
    } catch (e, stack) {
      dev.log(
        'CoachChatService.loadSessions failed',
        error: e,
        stackTrace: stack,
        name: 'eatova.coach',
      );
      _melde('coach.loadSessions', e, stack);
      throw CoachDataUnavailable('Sessionliste nicht abrufbar', e);
    }
    if (res is! List) {
      dev.log(
        'CoachChatService.loadSessions: unerwartete Form ${res.runtimeType}',
        name: 'eatova.coach',
      );
      // Gebrochener Vertrag, nie ein Netzfehler: der RPC liefert eine Tabelle.
      // Der Laufzeittyp bleibt im lokalen Log — den Report ordnet das
      // `context`-Tag zu, mehr braucht es dafuer nicht.
      const fehler = CoachDataUnavailable('Sessionliste in unerwarteter Form');
      _melde('coach.loadSessions.form', fehler, StackTrace.current);
      throw fehler;
    }
    return res
        .map<ChatSession>((row) =>
            ChatSession.fromRow((row as Map).cast<String, dynamic>()))
        .toList();
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
      // Der `null`-Rueckweg sperrt den Composer fuer den Rest des App-Laufs
      // (der Screen hat dann keine Sitzung) — kein Zustand, den man nur lokal
      // loggt.
      _melde('coach.ensureDefaultSession', e, stack);
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
      _melde('coach.createSession', e, stack);
      return null;
    }
  }

  /// Sentinel-Rest S8: rename/delete meldeten Fehler frueher nur ins Log und
  /// kehrten normal zurueck — ein `Future<void>`, das completed, IST fuer den
  /// Aufrufer die positive Behauptung „ist umbenannt/geloescht". Der Screen
  /// fuhr mit dem Erfolgsfall fort. Jetzt werfen beide [CoachDataUnavailable],
  /// dasselbe Muster wie loadSessions/loadQuotaToday/loadHistory.
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
      _melde('coach.renameSession', e, stack);
      throw CoachDataUnavailable('Umbenennen fehlgeschlagen', e);
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
      _melde('coach.deleteSession', e, stack);
      throw CoachDataUnavailable('Loeschen fehlgeschlagen', e);
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
          // `recipe` (Migration 20260813090000): das Rezept-JSON eines
          // /recipe-Vorschlags — die Karte ueberlebt damit den Reload.
          .select('id, role, content, refusal, created_at, recipe')
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
      _melde('coach.loadHistory', e, stack);
      // Sentinel-Rest S3: hier stand `return const <ChatMessage>[]` — der
      // Screen setzte die leere Liste als _messages und zeigte den
      // Hero-Leerzustand: der Nutzer sah seinen Verlauf als geloescht, ohne
      // Hinweis und ohne Retry. Exakt das Muster, das loadSessions und
      // loadQuotaToday bereits abgelegt haben.
      throw CoachDataUnavailable('Verlauf nicht abrufbar', e);
    }
  }

  /// Der Tageszaehler, wie ihn der Server nennt.
  ///
  /// `p_daily_limit` ist reine Anzeige-Arithmetik (Befund-Verifikation
  /// 2026-08-19, kein Handlungsbedarf): der RPC ist read-only und rechnet
  /// `remaining` nur aus dem uebergebenen Wert. Durchgesetzt wird das Limit
  /// serverseitig in der Edge Function via `claim_chat_quota`
  /// (service_role-only) — ein manipulierter Client, der hier andere Zahlen
  /// uebergibt, beluegt ausschliesslich seine eigene Anzeige.
  ///
  /// Wirft [CoachDataUnavailable], wenn der RPC scheitert ODER keine
  /// verwertbaren Zahlen liefert. Beides hiess frueher „5 von 5 frei":
  /// der `catch` gab `ChatQuotaSnapshot.unknown` zurueck, die `?? 5` im Parser
  /// erfanden dieselben Zahlen aus einer leeren Zeile. Der Aufrufer konnte das
  /// nicht von einer echten Serverantwort unterscheiden und hat damit eine
  /// bestehende Sperre aufgehoben.
  Future<ChatQuotaSnapshot> loadQuotaToday() async {
    final dynamic res;
    try {
      res = await _client.rpc(
        'get_chat_quota_today',
        params: {'p_daily_limit': ChatQuotaSnapshot.standardTageslimit},
      );
    } catch (e, stack) {
      dev.log(
        'CoachChatService.loadQuotaToday failed',
        error: e,
        stackTrace: stack,
        name: 'eatova.coach',
      );
      _melde('coach.loadQuotaToday', e, stack);
      throw CoachDataUnavailable('Tageszaehler nicht abrufbar', e);
    }
    // RPC liefert table-return als Liste.
    var row = const <String, dynamic>{};
    if (res is List && res.isNotEmpty && res.first is Map) {
      row = (res.first as Map).cast<String, dynamic>();
    } else if (res is Map) {
      row = res.cast<String, dynamic>();
    }
    final used = (row['used'] as num?)?.toInt();
    final remaining = (row['remaining'] as num?)?.toInt();
    final dailyLimit = (row['daily_limit'] as num?)?.toInt();
    if (used == null || remaining == null || dailyLimit == null) {
      dev.log(
        'CoachChatService.loadQuotaToday: Antwort ohne verwertbare Zahlen',
        name: 'eatova.coach',
      );
      // Wie oben ein gebrochener Vertrag: der RPC hat geantwortet, nur ohne
      // die Spalten, die seine Signatur zusagt. Typisch nach einer Migration —
      // und genau dann muss es jemand erfahren.
      const fehler =
          CoachDataUnavailable('Tageszaehler ohne verwertbare Zahlen');
      _melde('coach.loadQuotaToday.form', fehler, StackTrace.current);
      throw fehler;
    }
    return ChatQuotaSnapshot(
      used: used,
      remaining: remaining,
      dailyLimit: dailyLimit,
    );
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
          'locale': _localeCode,
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
        // 2xx ohne Text: die Function hat geantwortet, aber nichts gesagt.
        // Fuer den Nutzer ein Fehlschlag wie jeder andere, technisch ein
        // gebrochener Vertrag — und der einzige Ausfall dieser Klasse, den
        // kein Status verraet.
        final leer = CoachChatException(_l10n.coachErrorEmptyReply);
        _melde('coach.send.leereAntwort', leer, StackTrace.current);
        throw leer;
      }
      return CoachChatReply(
        reply: reply,
        refusal: map['refusal'] == true,
        refusalReason: map['refusal_reason']?.toString(),
        remaining: map['remaining'] is num
            ? (map['remaining'] as num).toInt()
            : null,
        dailyLimit: map['daily_limit'] is num
            ? (map['daily_limit'] as num).toInt()
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
      if (_statusIstVorfall(e.status)) _melde('coach.send.http', e, stack);
      throw _failureForStatus(e.status, e.details);
    } on FunctionsRelayException catch (e, stack) {
      // Eigener Typ: der Supabase-Relay VOR der Function hat abgebrochen
      // (Header `x-relay-error`, functions_client.dart:258-264). Die Function
      // lief hier nie, also gibt es auch keine fachliche Aussage im Body —
      // das ist immer eine Infrastruktur-Stoerung.
      _logSendFailure(e, stack);
      _melde('coach.send.relay', e, stack);
      throw CoachChatException(_unreachableMessage);
    } on FunctionsFetchException catch (e, stack) {
      // Die Anfrage ging gar nicht erst raus (functions_client.dart:206-208).
      // BEWUSST ohne Report: das ist der Offline-Fall in Reinform, und er
      // traegt keinen Typ, den [isNetworkSyncError] erkennen wuerde — die
      // Ausnahme steht deshalb hier und nicht im Filter.
      _logSendFailure(e, stack);
      throw CoachChatException(_l10n.coachErrorNoConnection);
    } catch (e, stack) {
      _logSendFailure(e, stack);
      _melde('coach.send.unbekannt', e, stack);
      throw CoachChatException(_unreachableMessage);
    }
  }

  /// /rezept: laesst die Function ein Rezept + Bild generieren
  /// (`mode: "recipe"`, Spec 2026-08-12). Kostet 1 Coach-Tages-Slot.
  ///
  /// Die Function LIEFERT NUR DATEN — gespeichert wird erst clientseitig,
  /// nachdem der Nutzer im Sheet bestaetigt hat. Fehler-Mapping identisch zu
  /// [send] (gleiche `on Functions*`-Arme, gleiche Status-Uebersetzung).
  Future<CoachRecipeReply> requestRecipe(
    String wish, {
    required String sessionId,
    required String locale,
    String? userContext,
  }) async {
    try {
      final res = await _client.functions.invoke(
        'coach-chat',
        body: {
          'message': wish,
          'mode': 'recipe',
          'locale': locale.toLowerCase().startsWith('en') ? 'en' : 'de',
          'session_id': sessionId,
          if (userContext != null && userContext.trim().isNotEmpty)
            'user_context': userContext.trim(),
        },
      );
      final data = res.data;
      final map = data is Map ? data : const <dynamic, dynamic>{};
      final reply =
          map['reply'] is String ? (map['reply'] as String).trim() : '';
      final refusal = map['refusal'] == true;

      // Kaputtes Base64 kostet nur das Bild, nie das Rezept.
      Uint8List? imageBytes;
      final rawImage = map['image_base64'];
      if (rawImage is String && rawImage.isNotEmpty) {
        try {
          imageBytes = base64Decode(rawImage);
        } catch (_) {
          imageBytes = null;
        }
      }

      CoachRecipeProposal? proposal;
      final rawRecipe = map['recipe'];
      if (!refusal && rawRecipe is Map) {
        proposal = CoachRecipeProposal.fromJson(
          rawRecipe,
          imageBytes: imageBytes,
        );
      }
      // Ein 200 ohne brauchbares Rezept UND ohne Refusal ist keine Antwort.
      if (reply.isEmpty || (!refusal && proposal == null)) {
        final leer = CoachChatException(_l10n.coachErrorEmptyReply);
        _melde('coach.recipe.leereAntwort', leer, StackTrace.current);
        throw leer;
      }
      return CoachRecipeReply(
        reply: reply,
        refusal: refusal,
        proposal: proposal,
        remaining: map['remaining'] is num
            ? (map['remaining'] as num).toInt()
            : null,
        dailyLimit: map['daily_limit'] is num
            ? (map['daily_limit'] as num).toInt()
            : null,
        sessionId: map['session_id']?.toString() ?? sessionId,
        // Fuer die lokale Bild-Ablage (Reload-Karte); fehlt bei aelteren
        // Function-Deployments oder wenn der Insert scheiterte.
        assistantMessageId: map['assistant_message_id'] is String
            ? map['assistant_message_id'] as String
            : null,
      );
    } on CoachQuotaExceeded {
      rethrow;
    } on CoachChatException {
      rethrow;
    } on FunctionsHttpException catch (e, stack) {
      _logSendFailure(e, stack);
      if (_statusIstVorfall(e.status)) _melde('coach.recipe.http', e, stack);
      throw _failureForStatus(e.status, e.details);
    } on FunctionsRelayException catch (e, stack) {
      _logSendFailure(e, stack);
      _melde('coach.recipe.relay', e, stack);
      throw CoachChatException(_unreachableMessage);
    } on FunctionsFetchException catch (e, stack) {
      // Wie in [send] bewusst ohne Report: die Anfrage ging nie raus.
      _logSendFailure(e, stack);
      throw CoachChatException(_l10n.coachErrorNoConnection);
    } catch (e, stack) {
      _logSendFailure(e, stack);
      _melde('coach.recipe.unbekannt', e, stack);
      throw CoachChatException(_unreachableMessage);
    }
  }

  String get _unreachableMessage => _l10n.coachErrorUnreachable;

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
      return CoachChatException(_l10n.coachErrorSessionExpired);
    }

    if (status == 429) {
      // NUR quota_exceeded ist das Tageslimit. `rate_limited` (Burst-Schutz)
      // traegt kein daily_limit und darf den Composer nicht fuer den Rest des
      // Tages sperren — der Nutzer darf gleich wieder senden.
      if (map['error'] == 'quota_exceeded') {
        final limit = map['daily_limit'];
        return CoachQuotaExceeded(
          message: serverReply ?? _l10n.coachErrorQuotaFallback,
          // Der 429er der Function traegt daily_limit immer (handler.ts);
          // fehlt es (Gateway-Body), bleibt nur der Anzeige-Ersatz — dieselbe
          // Konstante wie ueberall, kein eigenes Literal.
          dailyLimit:
              limit is num ? limit.toInt() : ChatQuotaSnapshot.standardTageslimit,
        );
      }
      return CoachChatException(
        serverReply ?? _l10n.coachErrorTooManyRequests,
      );
    }

    if (status == 413) {
      return CoachChatException(
        serverReply ?? _l10n.coachErrorImageTooLarge,
      );
    }

    if (status >= 500) {
      // 5xx-Bodies sind Interna ("rpc_unavailable", Gateway-HTML) — nie
      // anzeigen, auch wenn ein reply-Feld dabei waere.
      return CoachChatException(_unreachableMessage);
    }

    return CoachChatException(
      serverReply ?? _l10n.coachErrorRequestFailed,
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
    this.dailyLimit,
  });

  final String reply;
  final bool refusal;
  final String sessionId;
  final String? refusalReason;
  final int? remaining;

  /// Das Tageslimit, wie der SERVER es nennt (COACH_DAILY_LIMIT). Ohne das
  /// Feld rechnete der Screen jeden remaining-Wert gegen sein angenommenes
  /// Standard-Limit — mit serverseitig anderem Limit war der angezeigte
  /// Zaehler erfunden. null nur bei aelteren Function-Deployments.
  final int? dailyLimit;
}

/// Antwort des Recipe-Mode. Bei [refusal] ist [proposal] null und [reply]
/// der Refusal-Satz; sonst traegt [proposal] das Rezept (ggf. mit Bild) und
/// [reply] die Text-Zusammenfassung, die auch im Verlauf steht.
class CoachRecipeReply {
  const CoachRecipeReply({
    required this.reply,
    required this.refusal,
    required this.sessionId,
    this.proposal,
    this.remaining,
    this.dailyLimit,
    this.assistantMessageId,
  });

  final String reply;
  final bool refusal;
  final String sessionId;
  final CoachRecipeProposal? proposal;
  final int? remaining;
  final int? dailyLimit;

  /// id der persistierten Assistant-Zeile (chat_messages) — Schluessel der
  /// lokalen Bild-Ablage, damit die Karte den Reload ueberlebt. null bei
  /// aelteren Function-Deployments: die Karte ist dann nur ephemer.
  final String? assistantMessageId;
}

class CoachChatException implements Exception {
  const CoachChatException(this.message);
  final String message;
  @override
  String toString() => 'CoachChatException: $message';
}

/// „Ich weiss es nicht" — der Server hat keinen belastbaren Stand geliefert
/// (offline, abgelaufener Token, kaputter RPC, Antwort ohne Zahlen).
///
/// Bewusst eine Exception und kein Sentinel-Wert: ein Platzhalter-Objekt sieht
/// im Aufrufer aus wie eine echte Serverantwort und wird auch so behandelt.
/// Genau daran ist die Quota-Sperre gescheitert. Wer das hier faengt, muss
/// entscheiden, ob er seinen letzten bekannten Stand behaelt (Regel: ja) —
/// er darf ihn nicht durch eine Vermutung ersetzen.
///
/// Kein Anzeigetext: das ist kein Fehler, den der Nutzer lesen muss, sondern
/// eine fehlende Information.
class CoachDataUnavailable implements Exception {
  const CoachDataUnavailable(this.reason, [this.cause]);

  final String reason;
  final Object? cause;

  @override
  String toString() => 'CoachDataUnavailable: $reason';
}

class CoachQuotaExceeded implements Exception {
  const CoachQuotaExceeded({required this.message, required this.dailyLimit});
  final String message;
  final int dailyLimit;
}
