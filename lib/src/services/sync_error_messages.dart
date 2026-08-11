import 'dart:async';
import 'dart:io';

// http kommt transitiv ueber supabase_flutter (postgrest/gotrue fussen darauf);
// depend_on_referenced_packages ist dafuer in analysis_options.yaml demotet.
import 'package:http/http.dart' show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthRetryableFetchException, PostgrestException;

import '../l10n/l10n.dart';
import 'sync_outbox.dart'
    show SyncOpKind, kOutboxDeleteMaxAttempts, kOutboxMaxAttempts;

/// UI-Fehlertexte fuer fehlgeschlagene Sync-/Profil-Writes (pur, unit-testbar).
///
/// Grundregel: NIE `error.toString()` in die UI. Postgrest-Fehler tragen
/// Tabellen-/Constraint-/Schema-Details (Leakage) und sind fuer Nutzer ohnehin
/// unlesbar. Hier wird nur klassifiziert:
///  * Netzwerkfehler (offline/DNS/Timeout) -> dezenter Offline-Hinweis; das
///    renkt sich von selbst ein, sobald das Geraet wieder online ist.
///  * alles andere (z.B. Postgrest-500/Constraint) -> kurze freundliche
///    Meldung ohne technische Details.
/// Die Roh-Exception geht parallel via CrashReporter.capture + dev.log an die
/// Diagnose-Kanaele — dort gehoert sie hin, nicht in einen Snack.

/// True bei Verbindungs-/Netzwerkfehlern — alles, was von selbst verschwindet,
/// sobald das Geraet wieder Netz hat. In den Sync-Pfaden kommen real an:
///  * [IOException] — die GANZE dart:io-Familie, nicht nur
///    [SocketException]/[HttpException]. Entscheidend ist der TLS-Zweig:
///    `class HandshakeException extends TlsException` und
///    `class TlsException implements IOException` — eine Einzelaufzaehlung
///    von Socket/Http laesst also ausgerechnet das Cafe-WLAN hinter dem
///    Captive Portal (CERTIFICATE_VERIFY_FAILED) durchrutschen, obwohl das
///    Geraet den Server nie erreicht hat. package:http wickelt NUR
///    Socket-/HttpException in [ClientException], postgrest rethrowt den Rest
///    unveraendert — der TLS-Fehler kaeme roh und unklassifiziert an. Auf die
///    Oberklasse zu pruefen deckt zugleich kuenftige dart:io-Typen ab; der
///    Preis ist, dass auch ein (in diesen Pfaden unerwartetes)
///    [FileSystemException] als "Netz" gilt: die sichere Richtung, denn sie
///    kostet nur Retries statt Nutzerdaten.
///  * [ClientException] — package:http; auch der MockClient der Tests wirft
///    diesen Typ (implementiert KEIN IOException),
///  * [TimeoutException] aus `.timeout(...)`-Kaskaden,
///  * [AuthRetryableFetchException] — gotrues "retryable fetch"-Huelle fuer
///    Netzfehler waehrend Auth-/Token-Refresh-Calls.
/// Server-Antworten mit Fehlerstatus (PostgrestException & Co.) sind bewusst
/// NICHT dabei: der Server war erreichbar, "Offline" waere gelogen.
///
/// dart:io ist hier unbedenklich: Eatova baut nur fuer Android und iOS (kein
/// web/-Verzeichnis, kein Web-Target in der CI). Kaeme je ein Web-Build dazu,
/// muesste dieser Arm hinter eine bedingte Import-Weiche.
bool isNetworkSyncError(Object error) =>
    error is IOException ||
    error is TimeoutException ||
    error is ClientException ||
    error is AuthRetryableFetchException;

/// Was mit einem Write TATSAECHLICH passiert ist — die Antwort, die der Store
/// dem Aufrufer schuldet, wenn der eine eigene Erfolgsmeldung zeigt (Luecke E).
///
/// Die drei Auspraegungen spiegeln exakt die Unterscheidung, die
/// [queuedSyncHint] schon immer getroffen hat: zugestellt, wegen fehlenden
/// Netzes eingereiht, oder wegen einer Server-Ablehnung eingereiht. Ein
/// blosses bool haette den dritten Fall in den zweiten gefaltet — und
/// „sobald du wieder online bist" waere gelogen, wenn der Server geantwortet
/// hat.
enum SyncDelivery {
  /// Live beim Server angekommen.
  delivered,

  /// In der persistierten Outbox gelandet, weil das Geraet kein Netz hatte.
  queuedOffline,

  /// In der persistierten Outbox gelandet, obwohl der Server erreichbar war
  /// (Ablehnung, oder die Entitaet hatte schon eine gescheiterte Op offen).
  queuedRetry,
}

/// Baut aus einer Erfolgs-Aussage (`'„Bowl" gespeichert'`) die Meldung, die den
/// tatsaechlichen Ausgang spiegelt.
///
/// Warum ueberhaupt: der Rezepte-Screen zeigte „gespeichert." synchron und
/// UNBEDINGT — auch wenn der Write nie beim Server ankam. Lokal stimmte die
/// Aussage (seit Luecke A liegt das Rezept im Cache), aber der danach vom Store
/// nachgeschobene Offline-Hinweis ersetzte den Toast sofort wieder
/// ([showAppSnack] raeumt den vorigen ab). Der Nutzer sah zwei Meldungen
/// aufblitzen, von denen die erste zu viel versprach. Jetzt sagt EINE Meldung
/// beides: der Eintrag ist sicher, und was noch aussteht.
String deliveryHint(
  String erfolg,
  SyncDelivery delivery, [
  AppLocalizations? l10n,
]) {
  final t = l10n ?? deL10n;
  return switch (delivery) {
    SyncDelivery.delivered => t.commonDeliverySuccess(erfolg),
    SyncDelivery.queuedOffline => t.commonDeliveryQueuedOffline(erfolg),
    SyncDelivery.queuedRetry => t.commonDeliveryQueuedRetry(erfolg),
  };
}

/// Klassifiziert einen Queue-Grund fuer [deliveryHint]. [error] ist null, wenn
/// die Op ohne Live-Versuch hinter eine bereits pendende eingereiht wurde.
SyncDelivery queuedDelivery(Object? error) =>
    error != null && isNetworkSyncError(error)
        ? SyncDelivery.queuedOffline
        : SyncDelivery.queuedRetry;

/// Dezenter Hinweis fuer einen Write, der in der Outbox gelandet ist: die
/// Outbox retryt automatisch (Boot, Lifecycle-Flush, Backoff-Timer), der User
/// muss nichts tun. Netzfehler -> ehrliches "Offline", alles andere (auch
/// `null`, wenn eine Op ohne Live-Versuch hinter eine pendende eingereiht
/// wurde) -> neutrale Meldung ohne Exception-Details.
String queuedSyncHint(Object? error, [AppLocalizations? l10n]) {
  final t = l10n ?? deL10n;
  return error != null && isNetworkSyncError(error)
      ? t.commonQueuedOfflineHint
      : t.commonQueuedRetryGenericHint;
}

// Hier stand bis Luecke D (2026-08-10) `profileSyncErrorMessage` — die
// Meldung „Profil konnte nicht gespeichert werden. Bitte versuch es später
// erneut." Sie war korrekt, solange der Profil-Save wirklich ohne Netz gegen
// Supabase lief. Seit er ueber die Outbox geht, gibt es einen Auto-Retry, und
// die Bitte, spaeter selbst erneut zu speichern, waere schlicht falsch: der
// Profil-Save nimmt jetzt denselben Weg wie jeder andere Write und damit
// [queuedSyncHint]. Ersatzlos entfallen statt ungenutzt liegengelassen — eine
// Meldung, die niemand mehr ausloest, ist der beste Kandidat dafuer, beim
// naechsten Umbau versehentlich wieder verdrahtet zu werden.

/// Generische Meldung fuer sonstige Operationen ohne Outbox-Netz (z.B.
/// Konto-Löschung): kein Auto-Retry, der User soll es erneut ausloesen.
String directSyncErrorMessage(Object error, [AppLocalizations? l10n]) {
  final t = l10n ?? deL10n;
  return isNetworkSyncError(error)
      ? t.commonSyncErrorOffline
      : t.commonGenericRetryError;
}

/// Hinweis, dass die Outbox Ops ENDGUELTIG verworfen hat (Gift-Op, aufgebrauchtes
/// Versuchs-Budget oder Queue-Cap). Echter Datenverlust — der User erfaehrt
/// davon, aber wie ueberall hier OHNE technische Details: kein SQLSTATE, kein
/// Tabellen-/Constraint-Name, kein Exception-Typ (Schema-Leakage).
String outboxLossHint([AppLocalizations? l10n]) =>
    (l10n ?? deL10n).commonOutboxLossHint;

/// Hinweis fuer den Sonderfall einer endgueltig gescheiterten LOESCHUNG.
///
/// Braucht einen eigenen Text, weil die Folge eine andere ist: bei einem
/// verworfenen Write fehlt etwas, bei einem verworfenen Delete ist etwas
/// WIEDER DA. Der Store blendet den betroffenen Eintrag im selben Zug lokal
/// wieder ein (sonst kaeme er beim naechsten Kaltstart still vom Server
/// zurueck und zaehlte erneut mit) — die Meldung sagt genau das und nennt die
/// eine Handlung, die hilft. Wie ueberall hier ohne technische Details.
String outboxDeleteLossHint([AppLocalizations? l10n]) =>
    (l10n ?? deL10n).commonOutboxDeleteLossHint;

/// Was mit einer fehlgeschlagenen Outbox-Op passieren soll.
enum OutboxVerdict {
  /// Endgueltig verwerfen — ein Retry kann nicht klappen bzw. das Budget ist
  /// aufgebraucht.
  drop,

  /// Liegen lassen und einen Zustellversuch verbuchen.
  retryCounted,

  /// Liegen lassen, OHNE einen Versuch zu verbuchen.
  retryFree,
}

/// Klassifiziert einen fehlgeschlagenen Outbox-Write.
///
/// WICHTIGSTE REGEL ZUERST: Netzwerkfehler sind [OutboxVerdict.retryFree].
/// Boot, Lifecycle-Flush und der Backoff-Timer koennen offline innerhalb
/// weniger Sekunden alle drei feuern; wuerden Netzfehler das Versuchs-Budget
/// verbrennen, wuerde ein Offline-Wochenende gueltige Nutzerdaten vernichten —
/// der Fix waere schlimmer als der Bug.
///
/// Danach entscheidet der Fehlercode. Achtung, hier liegt die Falle: eine
/// [PostgrestException] hat KEIN statusCode-Feld, und `fromJson` schreibt den
/// HTTP-Status nur dann nach `code`, wenn der Antwort-Body selbst keinen
/// `code` traegt. Eine echte PostgREST-Fehlerantwort traegt aber immer einen —
/// eine Check-Constraint-Verletzung kommt also als SQLSTATE `'23514'` an, NIE
/// als `'400'`. Die drei Code-Familien sind nur an ihrer FORM unterscheidbar:
/// SQLSTATEs sind exakt 5 Zeichen, PostgREST-Codes beginnen mit `PGRST`,
/// HTTP-Status sind 3 Ziffern.
///
/// Im Zweifel wird IMMER behalten ([OutboxVerdict.retryCounted]) — unbekannte
/// Codes und unbekannte Exception-Typen sind kein Grund, Nutzerdaten
/// wegzuwerfen. Das Versuchs-Budget begrenzt den Schaden ohnehin.
///
/// [kind] ist optional, sollte aber IMMER mitgegeben werden, wenn der Aufrufer
/// die Op kennt: fuer LOESCH-Ops gilt eine eigene Regel.
///
/// Ihr Verwurf ist der einzige, den ein Kaltstart nicht nur nicht heilt,
/// sondern aktiv rueckgaengig macht — die Serverzeile ueberlebt, der lokale
/// Zustand nicht, und der naechste Boot liest vom Server: die geloeschte
/// 1800-kcal-Mahlzeit ist wieder da und zaehlt erneut. Deshalb ist fuer sie
/// BEIDES ausgesetzt, das Schreib-Budget UND das Sofort-Verwurfs-Verdikt aus
/// dem Fehlercode. Letzteres ist keine Grosszuegigkeit, sondern Logik: die
/// Payload eines Deletes ist LEER. Eine payload-determinierte Verletzung
/// (Klasse 22, 23502) kann sie gar nicht ausloesen, und PGRST20x/404
/// beschreiben einen kalten Schema-Cache bzw. eine Route waehrend eines
/// Deploys — beides geht vorbei. Ein Sofort-Verwurf traefe hier also nie eine
/// wirklich unmoegliche Anfrage, sondern eine voruebergehend abgewiesene.
///
/// Begrenzt werden Deletes stattdessen durch [kOutboxDeleteMaxAttempts] — ein
/// Vielfaches des Schreib-Budgets, aber eben endlich (Begruendung dort: eine
/// unsterbliche Op haelt Retry-Timer, Queue-Cap und den Logout-Cleanup dauerhaft
/// in Geiselhaft). Der Store legt darueber zusaetzlich eine Wanduhr-Frist
/// (`kOutboxDeleteMinAge`) und blendet einen verworfenen Delete lokal wieder
/// ein — der Verlust ist damit sichtbar und vom Nutzer reparierbar.
OutboxVerdict classifyOutboxFailure(
  Object error,
  int attempts, {
  SyncOpKind? kind,
}) {
  if (isNetworkSyncError(error)) return OutboxVerdict.retryFree;
  if (kind != null && _isDeleteKind(kind)) {
    return attempts + 1 >= kOutboxDeleteMaxAttempts
        ? OutboxVerdict.drop
        : OutboxVerdict.retryCounted;
  }
  final verdict = _verdictForCode(error);
  if (verdict == OutboxVerdict.drop) return OutboxVerdict.drop;
  // Budget aufgebraucht: auch ein prinzipiell retrybarer Fehler endet hier.
  return attempts + 1 >= kOutboxMaxAttempts ? OutboxVerdict.drop : verdict;
}

/// Lokale Kopie von `SyncOp.isDelete` auf der Enum-Ebene: [classifyOutboxFailure]
/// bekommt nur den [SyncOpKind], nicht die Op.
bool _isDeleteKind(SyncOpKind kind) =>
    kind == SyncOpKind.mealDelete ||
    kind == SyncOpKind.favoriteDelete ||
    kind == SyncOpKind.recipeDelete;

OutboxVerdict _verdictForCode(Object error) {
  // Alles, was kein PostgREST-Fehler ist (StateError, FormatException,
  // AuthException, …), ist unklassifiziert -> behalten.
  if (error is! PostgrestException) return OutboxVerdict.retryCounted;
  final code = error.code;
  if (code == null || code.isEmpty) return OutboxVerdict.retryCounted;

  // --- PostgREST-eigene Codes ---------------------------------------------
  if (code.startsWith('PGRST')) {
    // PGRST301 = JWT abgelaufen. Heilt beim naechsten Token-Refresh von
    // selbst, also behalten. Alle anderen PGRST*-Codes beschreiben eine
    // strukturell kaputte Anfrage (Schema-Cache, Parser, Singular-Verletzung)
    // — identische Bytes erneut zu senden hilft nie.
    return code == 'PGRST301'
        ? OutboxVerdict.retryCounted
        : OutboxVerdict.drop;
  }

  // --- Roher HTTP-Status (Body ohne `code`, z.B. Proxy/Gateway) ------------
  final status = code.length == 3 ? int.tryParse(code) : null;
  if (status != null) {
    if (status == 429 || status >= 500) return OutboxVerdict.retryCounted;
    // 401/403: fast immer ein abgelaufener Token — der Refresh heilt das.
    if (status == 401 || status == 403) return OutboxVerdict.retryCounted;
    if (status >= 400) return OutboxVerdict.drop;
    return OutboxVerdict.retryCounted;
  }

  // --- SQLSTATE (immer exakt 5 Zeichen) ------------------------------------
  if (code.length == 5) {
    // 22 = data exception (Wert zu lang, Zahl ausserhalb des Bereichs,
    // kaputtes Datumsformat …). Rein payload-determiniert: dieselben Bytes
    // werden nie akzeptiert.
    if (code.startsWith('22')) return OutboxVerdict.drop;
    if (code.startsWith('23')) {
      // Klasse 23 = integrity constraint violation. NICHT die ganze Klasse
      // sofort verwerfen: 23503 (foreign_key_violation) kann waehrend eines
      // Migrations-Fensters oder eines Signup-Rennens transient sein, und ein
      // falscher Sofort-Drop ist unwiderruflicher Nutzer-Datenverlust.
      //
      // Sofort verworfen wird nur 23502 (not_null_violation): eine fehlende
      // Pflichtspalte erzeugt keine Nutzereingabe, das ist ein Client-Bug,
      // und dieselben Bytes werden nie akzeptiert.
      //
      // 23514 (check_violation) ist BEWUSST kein Sofort-Verwurf: solange die
      // Clamps an den Modellgrenzen fehlen, ist eine Check-Verletzung nicht
      // das Signal korrupter Daten, sondern das erwartbare Ergebnis einer
      // Nutzereingabe („75,5" ins Gewichtsfeld -> Komma weggefiltert ->
      // 755 kg; langes OFF-Etikett; 2000 g Portion). Der Sofort-Verwurf naehme
      // genau das Korrekturfenster weg, mit dem die Attempts-Ruecksetzung in
      // sync_outbox.dart begruendet ist — der Nutzer tippt 200000 kcal,
      // korrigiert auf 500, und die korrigierte Payload kaeme nie zum Zug,
      // weil die Op laengst weg ist. Das Versuchs-Budget bleibt die Notbremse.
      // TODO(clamps): zurueck auf OutboxVerdict.drop, sobald die Clamps an den
      // Modellgrenzen sitzen (lib/src/models/model_limits.dart + Anwendung in
      // fromOpenFoodFacts/adjustedToGrams/toMealResult/KcalCalculator/
      // _buildProfile). Dann ist ein 23514 wieder das, was diese Regel
      // annimmt: ein Bug, keine Eingabe.
      //
      // (23505 unique_violation ist unerreichbar — jeder Write ist ein Upsert
      // mit onConflict auf die Client-UUID bzw. den natuerlichen Schluessel.)
      // Der Rest laeuft ins Versuchs-Budget und endet dort ebenfalls.
      return code == '23502' ? OutboxVerdict.drop : OutboxVerdict.retryCounted;
    }
    switch (code.substring(0, 2)) {
      // 08 connection_exception, 40 transaction rollback/deadlock,
      // 53 insufficient_resources, 57 operator_intervention (Shutdown),
      // 58 system_error — allesamt Zustaende, die vorbeigehen.
      case '08':
      case '40':
      case '53':
      case '57':
      case '58':
        return OutboxVerdict.retryCounted;
      // 42 syntax_error_or_access_rule_violation, inkl. 42501 (RLS-Ablehnung).
      // Bewusst retrybar: ein abgelaufener/noch nicht gesetzter Token laesst
      // RLS greifen, und das heilt sich beim naechsten Refresh.
      case '42':
        return OutboxVerdict.retryCounted;
    }
  }
  return OutboxVerdict.retryCounted;
}
