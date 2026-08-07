import '../models/favorite_meal.dart';
import '../models/fitness_recipe.dart';
import '../models/logged_meal.dart';
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
/// vernichten.
///
/// Warum 8: der Backoff laeuft 30s → 1m → 2m → 4m (Cap). Acht gezaehlte
/// Versuche ueberdauern damit locker eine halbe Stunde Server-Ausfall bzw.
/// (weil Boot und Lifecycle-Flush ebenfalls zaehlen) mehrere App-Starts —
/// genug, dass ein echter Ausfall sich erholt, aber klein genug, dass eine
/// wirklich unschreibbare Op nicht Monate lang Akku und Traffic frisst.
const int kOutboxMaxAttempts = 8;

/// Art der nachzuholenden Operation. Jede Op ist fuer sich idempotent
/// wiederholbar (siehe Doku an den Sync-Methoden):
///  * mealInsert/mealUpsert -> MealsSync.insertLoggedMeal ist ein Upsert auf
///    die Client-UUID (onConflict:'id').
///  * weightInsert -> TrackingSync.insertWeight mit Client-UUID + Upsert.
///  * favoriteUpsert -> Upsert auf (user_id, favorite_key).
///  * recipeUpsert -> Upsert auf (user_id, slug).
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
}

/// Eine persistierbare, nachholbare Sync-Operation.
class SyncOp {
  SyncOp._({
    required this.kind,
    required this.entityId,
    required this.payload,
    DateTime? queuedAt,
    this.attempts = 0,
  }) : queuedAt = queuedAt ?? DateTime.now();

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

  /// Kollisionsfreier Entitaets-Schluessel ueber alle Op-Familien
  /// (`meal:<id>`, `weight:<id>`, `favorite:<key>`, `recipe:<slug>`).
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
      };

  /// True fuer Upsert-artige Ops — nur die duerfen beim Einreihen koalesziert
  /// (Payload ersetzt) werden.
  bool get isUpsert =>
      kind == SyncOpKind.mealInsert ||
      kind == SyncOpKind.mealUpsert ||
      kind == SyncOpKind.favoriteUpsert ||
      kind == SyncOpKind.recipeUpsert;

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
/// Verworfen werden die AELTESTEN Ops (Kopf der Queue). Begruendung:
///  (a) Drop-Newest wuerde eine volle Queue in einen dauerhaften Total-
///      Schreibausfall verwandeln: eine volle Queue leert sich per Definition
///      gerade nicht, also kaeme ab da NIE wieder ein Write durch.
///  (b) Die neueste Op ist genau das, worauf der Nutzer gerade schaut — der
///      lokale State wird VOR dem Write mutiert, ein Drop-Newest liesse die
///      eben eingetragene Mahlzeit beim naechsten Kaltstart verschwinden.
///  (c) Die aeltesten Ops einer vollen Queue scheitern am laengsten, sind also
///      die wahrscheinlichsten Gift-Kandidaten.
///  (d) Die Korrektheit pro Entitaet ueberlebt einen Kopf-Trim: jeder Write
///      ist ein VOLLER Zeilen-Upsert auf eine Client-UUID (keine Deltas), und
///      jeder Delete ist idempotent. Verloren geht einzig der Stats-/Streak-
///      Seiteneffekt eines mealInsert — ein Zaehler, kein Nutzer-Inhalt.
({List<SyncOp> queue, List<SyncOp> dropped}) capOutbox(
  List<SyncOp> queue, {
  int maxOps = kOutboxMaxOps,
}) {
  if (queue.length <= maxOps) {
    return (queue: queue, dropped: const <SyncOp>[]);
  }
  final overflow = queue.length - maxOps;
  return (
    queue: queue.sublist(overflow),
    dropped: queue.sublist(0, overflow),
  );
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
