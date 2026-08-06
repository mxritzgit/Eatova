import 'dart:async';
import 'dart:io';

// http kommt transitiv ueber supabase_flutter (postgrest/gotrue fussen darauf);
// depend_on_referenced_packages ist dafuer in analysis_options.yaml demotet.
import 'package:http/http.dart' show ClientException;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthRetryableFetchException;

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
///  * [SocketException]/[HttpException] direkt aus dart:io,
///  * [ClientException] — package:http (IOClient) wickelt Socket-Fehler ein;
///    auch der MockClient der Tests wirft diesen Typ,
///  * [TimeoutException] aus `.timeout(...)`-Kaskaden,
///  * [AuthRetryableFetchException] — gotrues "retryable fetch"-Huelle fuer
///    Netzfehler waehrend Auth-/Token-Refresh-Calls.
/// Server-Antworten mit Fehlerstatus (PostgrestException & Co.) sind bewusst
/// NICHT dabei: der Server war erreichbar, "Offline" waere gelogen.
bool isNetworkSyncError(Object error) =>
    error is SocketException ||
    error is HttpException ||
    error is TimeoutException ||
    error is ClientException ||
    error is AuthRetryableFetchException;

/// Dezenter Hinweis fuer einen Write, der in der Outbox gelandet ist: die
/// Outbox retryt automatisch (Boot, Lifecycle-Flush, Backoff-Timer), der User
/// muss nichts tun. Netzfehler -> ehrliches "Offline", alles andere (auch
/// `null`, wenn eine Op ohne Live-Versuch hinter eine pendende eingereiht
/// wurde) -> neutrale Meldung ohne Exception-Details.
String queuedSyncHint(Object? error) => error != null &&
        isNetworkSyncError(error)
    ? 'Offline — wird synchronisiert, sobald du wieder online bist.'
    : 'Änderung konnte nicht gespeichert werden — wird automatisch erneut versucht.';

/// Meldung fuer den Profil-Save (Settings/Onboarding). Der laeuft NICHT ueber
/// die Outbox — es gibt keinen Auto-Retry, der User muss selbst erneut
/// speichern; die Meldung sagt das ehrlich.
String profileSyncErrorMessage(Object error) => isNetworkSyncError(error)
    ? 'Offline — Profil konnte nicht synchronisiert werden. Bitte speichere es später erneut.'
    : 'Profil konnte nicht gespeichert werden. Bitte versuch es später erneut.';

/// Generische Meldung fuer sonstige Operationen ohne Outbox-Netz (z.B.
/// Konto-Löschung): kein Auto-Retry, der User soll es erneut ausloesen.
String directSyncErrorMessage(Object error) => isNetworkSyncError(error)
    ? 'Offline — das hat gerade nicht geklappt. Bitte versuch es mit Internetverbindung erneut.'
    : 'Das hat gerade nicht geklappt. Bitte versuch es später erneut.';
