import 'package:clock/clock.dart';

import '../models/favorite_meal.dart';
import '../models/fitness_recipe.dart';
import '../models/logged_meal.dart';
import '../models/user_profile.dart';
import 'meals_sync.dart' show mealResultFromJson, mealResultToJson;

/// DATA-7 Write-Outbox: fehlgeschlagene Sync-Writes werden NICHT mehr
/// zurueckgerollt, sondern als [SyncOp] persistiert (LocalCache) und spaeter
/// idempotent nachgespielt (Boot, Lifecycle-Flush, naechster Erfolg,
/// Backoff-Timer). Dieses File enthaelt NUR das serialisierbare Op-Modell und
/// die (reine, unit-testbare) Einreih-Logik — Replay + Trigger leben im
/// HomeStore, die Persistenz im LocalCache.

/// Harte Obergrenze der persistierten Outbox.
///
/// Warum ueberhaupt ein Cap: im systemischen Fehlerfall (z.B. eine neue
/// Check-Constraint lehnt JEDEN logged_meals-Write ab) traegt jede weitere
/// Nutzer-Aktion eine eigene Entitaet (frische Meal-UUID) — die Koaleszenz
/// greift dort nicht, es haengt sich also pro Aktion eine volle Payload-Op an,
/// und der SharedPreferences-Blob waechst unbegrenzt (JSON-Encode/Decode bei
/// JEDEM Write, irgendwann ein ANR bzw. ein nicht mehr lesbarer Cache).
///
/// Warum 500: eine Meal-Op wiegt ~0,3–1 kB JSON, 500 Ops sind also ein
/// Blob im niedrigen dreistelligen kB-Bereich — das schreibt sich noch in
/// Millisekunden. Gleichzeitig sind 500 pendende Writes weit mehr, als ein
/// Nutzer in einer realistischen Offline-Phase erzeugt (ein Vielfaches von
/// „drei Wochen Urlaub ohne Netz, fuenf Mahlzeiten am Tag"). Wer den Cap
/// erreicht, steckt nicht in einer Offline-Phase, sondern in einem
/// systemischen Fehler — und dafuer ist der Cap die Notbremse.
const int kOutboxMaxOps = 500;

/// Maximale Zustellversuche pro Op, bevor sie endgueltig verworfen wird.
///
/// Zaehlt NUR Versuche, die der Server aktiv abgelehnt hat (5xx, 429, unklare
/// Codes) — Netzfehler sind gratis (siehe classifyOutboxFailure), sonst wuerde
/// ein Offline-Wochenende das Budget verbrennen und gueltige Nutzerdaten
/// vernichten. Loesch-Ops ([SyncOp.isDelete]) laufen NICHT hier hinein,
/// sondern in ihr eigenes, viel groesseres [kOutboxDeleteMaxAttempts]: ihr
/// Verwurf laesst die geloeschte Zeile beim naechsten Boot vom Server
/// zurueckkehren.
///
/// Warum 8: der Backoff laeuft 30s → 1m → 2m → 4m (Cap). Acht gezaehlte
/// Versuche ueberdauern damit locker eine halbe Stunde Server-Ausfall bzw.
/// (weil Boot und Lifecycle-Flush ebenfalls zaehlen) mehrere App-Starts —
/// genug, dass ein echter Ausfall sich erholt, aber klein genug, dass eine
/// wirklich unschreibbare Op nicht Monate lang Akku und Traffic frisst.
const int kOutboxMaxAttempts = 8;

/// Maximale Zustellversuche einer LOESCH-Op ([SyncOp.isDelete]).
///
/// Deletes bekommen ein eigenes Budget, weil ihr Verwurf teurer ist als der
/// eines Writes: der naechste Kaltstart HEILT einen verworfenen Write nicht,
/// aber er macht einen verworfenen Delete aktiv rueckgaengig — die Serverzeile
/// ueberlebt, der lokale Zustand nicht, die geloeschte 1800-kcal-Mahlzeit ist
/// wieder da und zaehlt erneut.
///
/// Warum ueberhaupt eines (und nicht „nie verwerfen"): eine Op ohne Budget ist
/// unsterblich, und daran haengt mehr, als es zunaechst aussieht — der
/// 4-Minuten-Retry-Timer feuert dann dauerhaft ueber alle Sessions, die Outbox
/// wird nie leer (also nagelt `signOutCleanup` `preserveOutbox` fuer immer auf
/// true und die Audit-M-1-Eigenschaft „PII ueberlebt den Logout nicht" ist
/// aufgehoben), und [capOutbox] kann einen Ueberlauf aus lauter Deletes nicht
/// mehr abbauen. Die Zielkollision „Deletes nie verwerfen" vs. „harte
/// Obergrenze" ist damit zugunsten einer sehr langen, aber endlichen Frist
/// entschieden — tragbar nur, weil der Store einen verworfenen Delete lokal
/// wieder EINBLENDET und meldet (siehe `_restoreDroppedDeletes`), der Verlust
/// also sichtbar und vom Nutzer reparierbar ist statt still.
///
/// Warum 64 (8x das Schreib-Budget): gezaehlt werden nur aktive
/// Server-Ablehnungen (Netzfehler sind gratis), und der Backoff steht bei 4
/// Minuten — 64 gezaehlte Ablehnungen sind also mindestens ein halber
/// Arbeitstag ununterbrochener Server-Ablehnung. Wirksam wird das Budget
/// ohnehin erst zusammen mit `kOutboxDeleteMinAge` (UND-Bedingung im Store),
/// weil Lifecycle-Churn den Zaehler sonst in Sekunden hochtreiben koennte.
const int kOutboxDeleteMaxAttempts = 64;

/// Art der nachzuholenden Operation. Jede Op ist fuer sich idempotent
/// wiederholbar (siehe Doku an den Sync-Methoden):
///  * mealInsert/mealUpsert -> MealsSync.insertLoggedMeal ist ein Upsert auf
///    die Client-UUID (onConflict:'id').
///  * weightInsert -> TrackingSync.insertWeight mit Client-UUID + Upsert.
///  * favoriteUpsert -> Upsert auf (user_id, favorite_key).
///  * recipeUpsert -> Upsert auf (user_id, slug).
///  * profileUpsert -> ProfileSync.save ist ein Upsert auf die User-Id.
///  * *Delete -> Deletes sind von Natur aus idempotent (0 Zeilen beim Retry).
/// mealInsert vs. mealUpsert: NUR ein nachgeholter Erst-Insert zaehlt beim
/// Replay die Lifetime-Stats (+1 Mahlzeit, ggf. Streak-Tag); Update/Restore
/// laufen als mealUpsert ohne Zaehlung — exakt wie im Online-Pfad.
enum SyncOpKind {
  mealInsert,
  mealUpsert,
  mealDelete,
  weightInsert,
  favoriteUpsert,
  favoriteDelete,
  recipeUpsert,
  recipeDelete,

  /// Luecke D: Profil/Ziele (Gewicht, kcal-Ziel, Diaet, Onboarding-Flag).
  /// Kam als letzte Op-Familie dazu — bis dahin liefen `applySettings` und
  /// `completeOnboarding` OHNE Netz gegen Supabase, und der naechste Boot
  /// ueberschrieb die offline gemachte Aenderung still mit der alten
  /// Serverzeile.
  profileUpsert,

  /// Zweitpruefung 2026-08-10: ein getrackter Logging-Tag
  /// (`record_tracking_day`).
  ///
  /// Der Streak-Tag war die letzte Nutzer-Groesse mit **null** Netzen: der RPC
  /// lief als reines fire-and-forget aus `_recordTrackingDay`, sein Fehler
  /// wurde geloggt und danach vergessen. Der optimistische lokale Stand hielt
  /// nicht einmal bis zum naechsten Atemzug — 600 ms spaeter adoptierte
  /// `_flushStatsDelta` die frische Serverzeile, die den Tag naturgemaess
  /// nicht kennt, und `_cacheLifetimeStats` schrieb den Verlust fest. Ergebnis:
  /// der Nutzer hat geloggt, die Mahlzeit ist angekommen, und seine Streak ist
  /// trotzdem gerissen — ohne Hinweis und ohne irgendeine Stelle, die es je
  /// reparieren koennte.
  trackingDay,
}

/// Eine persistierbare, nachholbare Sync-Operation.
class SyncOp {
  SyncOp._({
    required this.kind,
    required this.entityId,
    required this.payload,
    DateTime? queuedAt,
    this.attempts = 0,
    // clock.now() statt DateTime.now(): [queuedAt] ist die eine Haelfte der
    // Verwurfs-Frist (kOutboxMinAgeBeforeDrop / kOutboxDeleteMinAge), und die
    // war mit der System-Uhr ueberhaupt nicht mit einer kontrollierten Uhr
    // pruefbar. Der Rest des Stores haengt ohnehin an package:clock.
  }) : queuedAt = queuedAt ?? clock.now();

  final SyncOpKind kind;

  /// Roh-Schluessel der Entitaet (Meal-UUID, weight_log-UUID, favorite_key,
  /// Rezept-Slug). Fuer Queue-Logik immer [entityKey] verwenden — der ist
  /// ueber die Op-Familien hinweg kollisionsfrei.
  final String entityId;
  final DateTime queuedAt;
  final Map<String, dynamic> payload;

  /// Wie oft der Server DIESE Payload bereits aktiv abgelehnt hat. Alle
  /// Factories starten bei 0; hochgezaehlt wird ausschliesslich im
  /// Replay-Loop, und auch dort nur bei einem gezaehlten Verdikt
  /// (classifyOutboxFailure) — Netzfehler sind gratis. Erreicht der Zaehler
  /// [kOutboxMaxAttempts], wird die Op verworfen.
  final int attempts;

  /// Kopie mit einem verbrauchten Zustellversuch. Alles andere — insbesondere
  /// [queuedAt], die FIFO-Position der Entitaet — bleibt erhalten.
  ///
  /// Gilt auch fuer [isDelete]-Ops. Die zaehlten eine Zeit lang bewusst NICHT
  /// („Deletes duerfen ewig retryen"), und genau das hat eine unsterbliche Op
  /// erzeugt: ohne Zaehler wird sie nie verworfen, die Queue laeuft nie leer,
  /// der Backoff-Timer feuert alle vier Minuten ueber alle Sessions hinweg,
  /// `signOutCleanup` nagelt `preserveOutbox` dauerhaft auf true (Audit M-1
  /// ausgehebelt) und [capOutbox] kann den Ueberlauf nicht mehr abbauen.
  /// Deletes zaehlen deshalb wieder — nur gegen ein viel groesseres Budget
  /// ([kOutboxDeleteMaxAttempts]).
  ///
  /// Der Zaehler wird damit auch fuer Deletes persistiert. Das ist der Preis:
  /// ein Downgrade auf einen Build ohne die Delete-Regel liest ihn als
  /// Schreib-Budget und verwirft frueher. Hinnehmbar, weil genau dieser Build
  /// den Delete ohnehin nach acht eigenen Durchlaeufen verwirft — persistiert
  /// wird der Verwurf nur vorgezogen, nicht ueberhaupt erst ermoeglicht.
  SyncOp incrementAttempt() => SyncOp._(
        kind: kind,
        entityId: entityId,
        payload: payload,
        queuedAt: queuedAt,
        attempts: attempts + 1,
      );

  factory SyncOp.mealInsert(LoggedMeal meal, {required bool trackDay}) =>
      SyncOp._(kind: SyncOpKind.mealInsert, entityId: meal.id, payload: {
        'meal': loggedMealToJson(meal),
        'track_day': trackDay,
      });

  factory SyncOp.mealUpsert(LoggedMeal meal) =>
      SyncOp._(kind: SyncOpKind.mealUpsert, entityId: meal.id, payload: {
        'meal': loggedMealToJson(meal),
      });

  factory SyncOp.mealDelete(String id) => SyncOp._(
      kind: SyncOpKind.mealDelete, entityId: id, payload: const {});

  factory SyncOp.weightInsert({
    required String id,
    required double weightKg,
    required DateTime recordedAt,
  }) =>
      SyncOp._(kind: SyncOpKind.weightInsert, entityId: id, payload: {
        'weight_kg': weightKg,
        'recorded_at': recordedAt.toIso8601String(),
      });

  factory SyncOp.favoriteUpsert(FavoriteMeal fav) =>
      SyncOp._(kind: SyncOpKind.favoriteUpsert, entityId: fav.id, payload: {
        'favorite': favoriteMealToJson(fav),
      });

  factory SyncOp.favoriteDelete(String favoriteKey) => SyncOp._(
      kind: SyncOpKind.favoriteDelete, entityId: favoriteKey,
      payload: const {});

  factory SyncOp.recipeUpsert(FitnessRecipe recipe) =>
      SyncOp._(kind: SyncOpKind.recipeUpsert, entityId: recipe.slug, payload: {
        'recipe': recipe.toRow(),
      });

  factory SyncOp.recipeDelete(String slug) => SyncOp._(
      kind: SyncOpKind.recipeDelete, entityId: slug, payload: const {});

  /// Das Profil ist EINE Zeile pro Nutzer (public.profiles.id = auth-User).
  /// Deshalb ein fester [entityId] statt eines Schluessels aus den Daten: alle
  /// Profil-Ops teilen sich denselben [entityKey], koaleszieren dadurch zu
  /// genau einem Eintrag, und die letzte Aenderung gewinnt. Zwei nebenlaeufige
  /// Ops wuerden sich beim Replay sonst gegenseitig ueberholen.
  static const String profileEntityId = 'self';

  factory SyncOp.profileUpsert(UserProfile profile) => SyncOp._(
        kind: SyncOpKind.profileUpsert,
        entityId: profileEntityId,
        payload: {'profile': userProfileToJson(profile)},
      );

  /// Ein getrackter Logging-Tag ([LifetimeStatsSync.recordTrackingDay]).
  ///
  /// [localDay] ist der kanonische Tages-Schluessel `YYYY-MM-DD` (localDayKey)
  /// und zugleich der [entityId]: alle Versuche fuer DENSELBEN Tag teilen sich
  /// damit einen [entityKey] und koaleszieren zu genau einer Op. Die Payload
  /// ist leer — der Tag IST die ganze Information.
  ///
  /// Idempotent in beide Richtungen: der RPC zaehlt pro Tag nur einmal und ist
  /// fuer Tage vor dem zuletzt gezaehlten serverseitig ein No-op. Ein Replay
  /// kann die Streak also weder doppelt hochzaehlen noch zurueckdrehen — genau
  /// deshalb darf der Tag ueberhaupt in die Outbox.
  factory SyncOp.trackingDay(String localDay) => SyncOp._(
        kind: SyncOpKind.trackingDay,
        entityId: localDay,
        payload: const <String, dynamic>{},
      );

  /// Kollisionsfreier Entitaets-Schluessel ueber alle Op-Familien
  /// (`meal:<id>`, `weight:<id>`, `favorite:<key>`, `recipe:<slug>`,
  /// `profile:self`, `tracking:<YYYY-MM-DD>`).
  String get entityKey => switch (kind) {
        SyncOpKind.mealInsert ||
        SyncOpKind.mealUpsert ||
        SyncOpKind.mealDelete =>
          'meal:$entityId',
        SyncOpKind.weightInsert => 'weight:$entityId',
        SyncOpKind.favoriteUpsert ||
        SyncOpKind.favoriteDelete =>
          'favorite:$entityId',
        SyncOpKind.recipeUpsert ||
        SyncOpKind.recipeDelete =>
          'recipe:$entityId',
        SyncOpKind.profileUpsert => 'profile:$entityId',
        SyncOpKind.trackingDay => 'tracking:$entityId',
      };

  /// True fuer die drei Loesch-Familien.
  ///
  /// Sonderstellung im Verwurfs-Pfad: der Verlust eines Deletes ist der
  /// einzige, den ein Kaltstart nicht nur nicht heilt, sondern aktiv
  /// RUECKGAENGIG macht — die Serverzeile ueberlebt, der lokale Zustand nicht,
  /// und der naechste Boot liest vom Server. Deshalb ist ein Delete an jeder
  /// Verwurfsstelle die LETZTE Wahl: kein Sofort-Verwurf aus dem Fehlercode,
  /// ein Vielfaches an Zustellversuchen ([kOutboxDeleteMaxAttempts]), im Store
  /// zusaetzlich eine Wanduhr-Frist, und beim Queue-Cap faellt er erst, wenn
  /// keine Schreib-Op mehr da ist (siehe [capOutbox], classifyOutboxFailure).
  /// Unverwerfbar ist er aber NICHT — das waere eine unsterbliche Op; wo er
  /// faellt, blendet der Store den Eintrag lokal wieder ein und meldet es.
  bool get isDelete =>
      kind == SyncOpKind.mealDelete ||
      kind == SyncOpKind.favoriteDelete ||
      kind == SyncOpKind.recipeDelete;

  /// True fuer Upsert-artige Ops — nur die duerfen beim Einreihen koalesziert
  /// (Payload ersetzt) werden.
  ///
  /// [SyncOpKind.trackingDay] zaehlt bewusst dazu, obwohl es kein Zeilen-
  /// Upsert ist: die Payload ist leer, „ersetzen" ist damit dasselbe wie
  /// „behalten" — und ohne Koaleszenz haengte sich fuer denselben Tag bei
  /// jedem weiteren Log eine zusaetzliche, voellig gleiche Op an.
  bool get isUpsert =>
      kind == SyncOpKind.mealInsert ||
      kind == SyncOpKind.mealUpsert ||
      kind == SyncOpKind.favoriteUpsert ||
      kind == SyncOpKind.recipeUpsert ||
      kind == SyncOpKind.profileUpsert ||
      kind == SyncOpKind.trackingDay;

  // ---- Payload-Zugriffe (defensiv: korrupt -> null) ------------------------

  LoggedMeal? get meal {
    final raw = payload['meal'];
    if (raw is! Map) return null;
    try {
      return loggedMealFromJson(raw.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  /// Nur fuer [SyncOpKind.mealInsert] relevant: zaehlte der Log-Tag zum
  /// Zeitpunkt des Loggens fuer die Streak (Mahlzeit fuer HEUTE, kein
  /// Nachtrag)?
  bool get trackDay => payload['track_day'] == true;

  double? get weightKg {
    final raw = payload['weight_kg'];
    return raw is num ? raw.toDouble() : null;
  }

  DateTime? get recordedAt {
    final raw = payload['recorded_at'];
    return raw is String ? DateTime.tryParse(raw) : null;
  }

  FavoriteMeal? get favorite {
    final raw = payload['favorite'];
    if (raw is! Map) return null;
    try {
      return favoriteMealFromJson(raw.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  FitnessRecipe? get recipe {
    final raw = payload['recipe'];
    if (raw is! Map) return null;
    try {
      return FitnessRecipe.fromRow(raw.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  /// Das Profil der Op — null, wenn die Payload unlesbar oder unvollstaendig
  /// ist. Unvollstaendig zaehlt hier bewusst als unlesbar (siehe
  /// [userProfileFromJson]): eine Op, die auf halb erfundenen Zahlen sitzt,
  /// wuerde beim Replay eine echte Serverzeile mit Fantasie ueberschreiben.
  /// Der Replay wirft dafuer und verwirft die Op (A8-Pfad).
  UserProfile? get profile {
    final raw = payload['profile'];
    if (raw is! Map) return null;
    try {
      return userProfileFromJson(raw.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  // ---- Wire-Format ---------------------------------------------------------

  /// [attempts] wird NUR geschrieben, wenn es > 0 ist. Der Normalfall (frisch
  /// eingereihte Op) bleibt damit byte-identisch zum alten 4-Key-Format:
  /// ein Downgrade auf einen aelteren Build liest die Queue unveraendert
  /// weiter, und der persistierte Blob waechst nicht ohne Not.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind.name,
        'entity_id': entityId,
        'queued_at': queuedAt.toIso8601String(),
        'payload': payload,
        if (attempts > 0) 'attempts': attempts,
      };

  /// Defensiv: unbekannte Kinds / kaputte Eintraege liefern null, damit EINE
  /// korrupte Op nicht die ganze Queue mitreisst.
  static SyncOp? tryFromJson(Map<String, dynamic> json) {
    final rawKind = json['kind'];
    if (rawKind is! String) return null;
    SyncOpKind? kind;
    for (final k in SyncOpKind.values) {
      if (k.name == rawKind) {
        kind = k;
        break;
      }
    }
    if (kind == null) return null;
    final entityId = json['entity_id'];
    if (entityId is! String || entityId.isEmpty) return null;
    final rawPayload = json['payload'];
    final payload = rawPayload is Map
        ? rawPayload.cast<String, dynamic>()
        : <String, dynamic>{};
    final queuedAt = json['queued_at'];
    // Fehlend (Legacy-Eintrag eines alten Builds), nicht-numerisch oder
    // negativ -> 0. Das ist bewusst die SICHERE Richtung: ein zu niedriger
    // Zaehler kostet hoechstens ein paar zusaetzliche Zustellversuche, ein
    // aufgeblaehter wuerde gueltige Nutzer-Writes sofort verwerfen.
    final rawAttempts = json['attempts'];
    final attempts =
        rawAttempts is num && rawAttempts > 0 ? rawAttempts.toInt() : 0;
    return SyncOp._(
      kind: kind,
      entityId: entityId,
      payload: payload,
      queuedAt:
          queuedAt is String ? DateTime.tryParse(queuedAt) : null,
      attempts: attempts,
    );
  }
}

/// Reiht [op] FIFO in die Queue ein. Koaleszenz haelt die Queue kurz, OHNE die
/// Reihenfolge pro Entitaet zu brechen:
///  * Ist die LETZTE gemerkte Op derselben Entitaet ebenfalls ein Upsert,
///    wird ihr Payload ersetzt statt angehaengt (wiederholtes Editieren
///    offline waechst nicht). Ein pendender mealInsert behaelt dabei Kind +
///    track_day, damit die Stats-Zaehlung beim Replay erhalten bleibt.
///  * Alles andere (Deletes, Upsert nach Delete, fremde Entitaeten) wird
///    angehaengt — striktes FIFO wahrt insert -> update -> delete.
/// [appendOnly] MUSS gesetzt sein, solange ein Replay laeuft: der koennte
/// gerade genau die Op abspielen, deren Payload sonst ersetzt (und beim
/// Entfernen verloren) wuerde.
///
/// Beim Koaleszieren startet [SyncOp.attempts] wieder bei 0 — der Zaehler
/// misst, wie oft der Server GENAU DIESE Payload abgelehnt hat, und die
/// Payload ist gerade eine andere geworden. Konkret: tippt jemand 200000 kcal
/// (Check-Constraint, Zaehler klettert) und korrigiert das dann auf 500,
/// wuerde ein uebernommener Zaehler die korrigierte, voellig gueltige
/// Aenderung sofort wegwerfen. [SyncOp.queuedAt] bleibt dagegen erhalten: das
/// ist die FIFO-Position der Entitaet und hat mit der Payload-Gueltigkeit
/// nichts zu tun.
/// Bewusst in Kauf genommen: eine dauerhaft kaputte Entitaet, die der Nutzer
/// immer wieder anfasst, wird nie verworfen. Das ist in Ordnung — die
/// Koaleszenz haelt sie bei GENAU EINEM Slot (kein Queue-Wachstum), und der
/// Nutzer arbeitet aktiv daran. Das NICHT durch Uebernehmen des Zaehlers
/// „reparieren".
List<SyncOp> enqueueCoalesced(
  List<SyncOp> queue,
  SyncOp op, {
  bool appendOnly = false,
}) {
  if (op.isUpsert && !appendOnly) {
    for (var i = queue.length - 1; i >= 0; i--) {
      final existing = queue[i];
      if (existing.entityKey != op.entityKey) continue;
      if (!existing.isUpsert) break; // Delete dazwischen -> anhaengen.
      final merged = existing.kind == SyncOpKind.mealInsert &&
              op.kind == SyncOpKind.mealUpsert
          ? SyncOp._(
              kind: SyncOpKind.mealInsert,
              entityId: op.entityId,
              payload: {...op.payload, 'track_day': existing.trackDay},
              queuedAt: existing.queuedAt,
              // attempts bleibt beim Default 0 — NICHT existing.attempts,
              // siehe Doku oben.
            )
          : op; // kommt aus einer Factory, hat also ebenfalls attempts == 0.
      final next = [...queue];
      next[i] = merged;
      return next;
    }
  }
  return [...queue, op];
}

/// Deckelt die Outbox auf [maxOps] und liefert Queue UND Verworfenes getrennt
/// zurueck.
///
/// Bewusst eine eigene, reine Funktion statt eines Parameters an
/// [enqueueCoalesced]: der Aufrufer MUSS sehen, was verlorengegangen ist (er
/// meldet es dem Nutzer und loggt es), und der Cap muss auch auf dem
/// Hydrations-Pfad laufen — eine von einem aelteren, ungedeckelten Build
/// gewachsene Queue kommt aus dem Cache zurueck, ohne je durch das Einreihen
/// zu laufen.
///
/// Verworfen werden die aeltesten Ops (Kopf der Queue), SCHREIB-Ops zuerst;
/// [SyncOp.isDelete] kommt erst dran, wenn keine Schreib-Op mehr uebrig ist.
/// Der Cap bleibt damit eine HARTE Obergrenze — eine Queue aus lauter
/// unzustellbaren Deletes haette ihn sonst vollstaendig ausgehebelt und genau
/// das unbegrenzte Blob-Wachstum erzeugt, gegen das er geschrieben wurde.
/// Tragbar ist das nur, weil der Store einen verworfenen Delete lokal wieder
/// einblendet und meldet (`_restoreDroppedDeletes`, `outboxDeleteLossHint`).
/// Begruendung fuer die Reihenfolge:
///  (a) Drop-Newest wuerde eine volle Queue in einen dauerhaften Total-
///      Schreibausfall verwandeln: eine volle Queue leert sich per Definition
///      gerade nicht, also kaeme ab da NIE wieder ein Write durch.
///  (b) Die neueste Op ist genau das, worauf der Nutzer gerade schaut — der
///      lokale State wird VOR dem Write mutiert, ein Drop-Newest liesse die
///      eben eingetragene Mahlzeit beim naechsten Kaltstart verschwinden.
///  (c) Die aeltesten Ops einer vollen Queue scheitern am laengsten, sind also
///      die wahrscheinlichsten Gift-Kandidaten.
///  (d) In der ANLEGE-Richtung ueberlebt die Korrektheit pro Entitaet einen
///      Kopf-Trim: jeder Write ist ein VOLLER Zeilen-Upsert auf eine
///      Client-UUID (keine Deltas), verloren geht einzig der Stats-/Streak-
///      Seiteneffekt eines mealInsert — ein Zaehler, kein Nutzer-Inhalt. Fuer
///      Deletes gilt das ausdruecklich NICHT: „idempotent" heisst nur, dass
///      ein Retry schadlos ist, nicht dass ein Verwurf folgenlos waere. Beim
///      Delete ueberlebt die Serverzeile, der lokale Zustand nicht — der
///      naechste Boot liest vom Server, und die geloeschte 1800-kcal-Mahlzeit
///      ist wieder da und zaehlt erneut. Deletes kosten ausserdem fast nichts
///      (leere Payload, ~120 Byte JSON). Sie fallen deshalb ZULETZT — aber sie
///      fallen: eine Queue, die nur noch aus ihnen besteht, waechst sonst
///      unbegrenzt weiter, und ein ANR beim Cache-Write kostet mehr als die
///      aelteste von 500 haengenden Loeschungen.
({List<SyncOp> queue, List<SyncOp> dropped}) capOutbox(
  List<SyncOp> queue, {
  int maxOps = kOutboxMaxOps,
}) {
  if (queue.length <= maxOps) {
    return (queue: queue, dropped: const <SyncOp>[]);
  }
  var overflow = queue.length - maxOps;
  var kept = <SyncOp>[];
  final dropped = <SyncOp>[];
  // 1. Durchgang: Schreib-Ops, aelteste zuerst.
  for (final op in queue) {
    if (overflow > 0 && !op.isDelete) {
      dropped.add(op);
      overflow--;
    } else {
      kept.add(op);
    }
  }
  // 2. Durchgang: die Queue besteht jetzt nur noch aus Deletes und liegt
  // immer noch ueber dem Cap. Auch hier aelteste zuerst.
  if (overflow > 0) {
    final survivors = <SyncOp>[];
    for (final op in kept) {
      if (overflow > 0) {
        dropped.add(op);
        overflow--;
      } else {
        survivors.add(op);
      }
    }
    kept = survivors;
  }
  return (queue: kept, dropped: dropped);
}

// ---- (De)Serialisierung LoggedMeal / FavoriteMeal ---------------------------
// Bewusst hier statt auf den Modellen (gleiches Muster wie mealResultTo/From-
// Json in meals_sync.dart): die Domain-Modelle bleiben persistence-frei, die
// Outbox besitzt ihr eigenes, versioniertes Wire-Format. Wird auch vom
// LocalCache fuer die Tagebuch-/Favoriten-Snapshots mitbenutzt.

Map<String, dynamic> loggedMealToJson(LoggedMeal m) => <String, dynamic>{
      'id': m.id,
      'logged_at': m.loggedAt.toIso8601String(),
      'forced_slot': m.forcedSlot?.name,
      'local_day': m.effectiveLocalDay,
      'result': mealResultToJson(m.result),
    };

LoggedMeal loggedMealFromJson(Map<String, dynamic> j) {
  return LoggedMeal(
    id: j['id'] as String,
    loggedAt: DateTime.parse(j['logged_at'] as String),
    forcedSlot: _parseSlot(j['forced_slot']?.toString()),
    localDay: j['local_day']?.toString(),
    result: mealResultFromJson((j['result'] as Map).cast<String, dynamic>()),
  );
}

Map<String, dynamic> favoriteMealToJson(FavoriteMeal f) => <String, dynamic>{
      'id': f.id,
      'added_at': f.addedAt.toIso8601String(),
      'pinned': f.pinned,
      'result': mealResultToJson(f.result),
    };

FavoriteMeal favoriteMealFromJson(Map<String, dynamic> j) {
  return FavoriteMeal(
    id: j['id'] as String,
    addedAt: DateTime.parse(j['added_at'] as String),
    pinned: j['pinned'] == true,
    result: mealResultFromJson((j['result'] as Map).cast<String, dynamic>()),
  );
}

MealSlot? _parseSlot(String? raw) {
  if (raw == null) return null;
  for (final v in MealSlot.values) {
    if (v.name == raw) return v;
  }
  return null;
}

// ---- (De)Serialisierung UserProfile -----------------------------------------
// Wohnt hier und nicht mehr im LocalCache, weil das Profil seit Luecke D ZWEI
// Persistenzwege hat: den Cache-Slot und die Outbox-Op. Zwei Kopien desselben
// Mappings waeren genau die Falle, gegen die local_cache_test's
// „Wire-Format deckt JEDES UserProfile-Feld ab" geschrieben ist — ein neues
// Feld waere in der einen Kopie gelandet und in der anderen nicht. Die
// Schluesselnamen sind unveraendert (sie stehen auf dem Geraet jeder
// bestehenden Installation) und folgen den Spalten von public.profiles.

Map<String, dynamic> userProfileToJson(UserProfile p) => <String, dynamic>{
      'weight_kg': p.weightKg,
      'height_cm': p.heightCm,
      'age_years': p.ageYears,
      'sex': p.sex.name,
      'activity_level': p.activityLevel.name,
      'target_weight_kg': p.targetWeightKg,
      'daily_steps_goal': p.dailyStepsGoal,
      'daily_kcal_goal': p.dailyKcalGoal,
      'daily_water_goal_ml': p.dailyWaterGoalMl,
      'daily_sleep_goal_minutes': p.dailySleepGoalMinutes,
      'protein_goal_g': p.proteinGoalG,
      'carbs_goal_g': p.carbsGoalG,
      'fat_goal_g': p.fatGoalG,
      'weight_goal': p.weightGoal.name,
      // A7: MUSS mitgeschrieben werden. Der Cache ist die ERSTE
      // Hydrationsquelle und setzt dabei die Clobber-Sperre
      // (_hydratedFromRealSource). Fehlte der Schluessel, fiel `diet` beim
      // Kaltstart still auf den Ctor-Default none zurueck — und der naechste
      // profile.save() schrieb dieses none dauerhaft auf den Server, ohne dass
      // der User es ueber die UI je wieder haette reparieren koennen.
      // Schluesselname wie serverseitig: profiles.diet_preference.
      'diet_preference': p.diet.name,
      'onboarding_completed': p.onboardingCompleted,
    };

/// Sentinel-Fund 3 (Nachverifikation 2026-08-08): fehlende/unlesbare
/// Zahlenfelder wurden hier mit erfundenen Werten aufgefuellt (78 kg, 178 cm,
/// 2200 kcal, ...) — und die Cache-Hydration setzte damit die Clobber-Sperre
/// (_hydratedFromRealSource), der naechste profile.save() schrieb die Fantasie
/// dauerhaft auf den Server. Ein Blob, dem Zahlen fehlen (Alt-Build vor einer
/// Felderweiterung, korrupte Zeile), ist deshalb ALS GANZES keine
/// Hydrationsquelle: null. Fuer den Cache liefert der Server-Load direkt
/// danach die Wahrheit, fuer eine Outbox-Op ist es der Verwurfs-Pfad (A8).
/// Die Enum-Felder bleiben bewusst nachsichtig (A7: kuenftige Enum-Werte
/// fallen lesbar zurueck — sie erfinden Einordnungen, keine Messwerte).
UserProfile? userProfileFromJson(Map<String, dynamic> j) {
  final weightKg = _profileInt(j['weight_kg']);
  final heightCm = _profileInt(j['height_cm']);
  final ageYears = _profileInt(j['age_years']);
  final targetWeightKg = _profileInt(j['target_weight_kg']);
  final dailyStepsGoal = _profileInt(j['daily_steps_goal']);
  final dailyKcalGoal = _profileInt(j['daily_kcal_goal']);
  final dailyWaterGoalMl = _profileInt(j['daily_water_goal_ml']);
  final dailySleepGoalMinutes = _profileInt(j['daily_sleep_goal_minutes']);
  final proteinGoalG = _profileInt(j['protein_goal_g']);
  final carbsGoalG = _profileInt(j['carbs_goal_g']);
  final fatGoalG = _profileInt(j['fat_goal_g']);
  if (weightKg == null ||
      heightCm == null ||
      ageYears == null ||
      targetWeightKg == null ||
      dailyStepsGoal == null ||
      dailyKcalGoal == null ||
      dailyWaterGoalMl == null ||
      dailySleepGoalMinutes == null ||
      proteinGoalG == null ||
      carbsGoalG == null ||
      fatGoalG == null) {
    return null;
  }
  return UserProfile(
    weightKg: weightKg,
    heightCm: heightCm,
    ageYears: ageYears,
    sex: _profileEnum(BiologicalSex.values, j['sex'], BiologicalSex.neutral),
    activityLevel: _profileEnum(
        ActivityLevel.values, j['activity_level'], ActivityLevel.sedentary),
    targetWeightKg: targetWeightKg,
    dailyStepsGoal: dailyStepsGoal,
    dailyKcalGoal: dailyKcalGoal,
    dailyWaterGoalMl: dailyWaterGoalMl,
    dailySleepGoalMinutes: dailySleepGoalMinutes,
    proteinGoalG: proteinGoalG,
    carbsGoalG: carbsGoalG,
    fatGoalG: fatGoalG,
    weightGoal:
        _profileEnum(WeightGoal.values, j['weight_goal'], WeightGoal.maintain),
    // Gegenstueck zu 'diet_preference' oben. Unbekannte/fehlende Werte
    // (Alt-Eintrag vor A7, kuenftige Enum-Werte) fallen auf none.
    diet: _profileEnum(
        DietPreference.values, j['diet_preference'], DietPreference.none),
    onboardingCompleted: j['onboarding_completed'] == true,
  );
}

int? _profileInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

T _profileEnum<T extends Enum>(List<T> values, Object? raw, T fallback) {
  if (raw is! String) return fallback;
  for (final v in values) {
    if (v.name == raw) return v;
  }
  return fallback;
}
