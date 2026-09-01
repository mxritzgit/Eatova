import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter/foundation.dart'
    show kProfileMode, kReleaseMode, visibleForTesting;
import 'package:flutter/services.dart' show PlatformException;
import 'package:sentry_flutter/sentry_flutter.dart';
import 'sync_error_messages.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthException, FunctionException, PostgrestException, StorageException;

/// Thin static facade for crash reporting.
///
/// The app depends only on this class, never on Sentry directly. Whether
/// Sentry is behind it is decided solely by the `SENTRY_DSN` build flag;
/// without a DSN (dev, CI, tests) the facade is a no-op with
/// `dart:developer` logging — no network, no init, no throw.
///
/// Privacy: the app processes health data, so only technical fields
/// (operation, error type, stack) may reach [capture]/[breadcrumb].
///
/// That promise rests on three filters, because the facade is not the only
/// route to Sentry (C1):
///
/// 1. [sanitizeForReport] — everything passing through [capture].
/// 2. [sanitizeSentryEvent] as `beforeSend` — unhandled errors grabbed by
///    the Flutter/onError/runZonedGuarded integrations.
/// 3. [sanitizeSentryBreadcrumb] as `beforeBreadcrumb` — breadcrumbs are
///    mirrored into the native scope, and a native crash report leaves
///    without any Dart hook.
///
/// [configureSentry] wires 2 and 3.
class CrashReporter {
  const CrashReporter._();

  /// Sentry DSN from `--dart-define=SENTRY_DSN=...`. Empty by default, which
  /// turns crash reporting off entirely.
  static const String dsn = String.fromEnvironment('SENTRY_DSN');

  /// True when a DSN is set AND `SentryFlutter.init` ran. Always false in
  /// tests (empty DSN, no-op hub).
  static bool get isActive => dsn.isNotEmpty && Sentry.isEnabled;

  /// Test seam: when set, the object that would go to
  /// `Sentry.captureException` goes here instead, unchanged and at the same
  /// point in the flow. Always `null` in production. Sits BEFORE the
  /// [isActive] gate — with an empty DSN nothing would be observable behind
  /// it, and this is the only way to test the privacy promise above.
  @visibleForTesting
  static void Function(Object error, StackTrace stack, String? context)?
      debugSentrySink;

  /// Test seam for [breadcrumb], like [debugSentrySink].
  @visibleForTesting
  static void Function(String message)? debugBreadcrumbSink;

  /// Reports a failed sync write, but only when it means something.
  ///
  /// A plain outage on this path is the designed flow: the op sits in the
  /// persisted queue and replay catches it up. Reporting those would drown
  /// real errors and burn the quota.
  ///
  /// Uses the same classification as the user-facing message
  /// ([isNetworkSyncError]); a second threshold would be a second place for
  /// the two to drift apart.
  static Future<void> captureSyncFailure(
    Object error,
    StackTrace stack, {
    String? context,
  }) async {
    if (isNetworkSyncError(error)) {
      dev.log(
        'Sync-Write offline gescheitert — eingereiht, nicht gemeldet',
        error: error,
        name: 'eatova_sync',
      );
      return;
    }
    await capture(error, stack, context: context);
  }

  /// Reports a handled error. Always logs via `dart:developer`; only reaches
  /// Sentry (sanitized) when [isActive]. Never throws — reporting must not
  /// break the error paths that call it.
  ///
  /// [sanitizeForReport] decides what Sentry sees, not the caller, so it does
  /// not matter whether a caller knows its `error` carries user data.
  static Future<void> capture(
    Object error,
    StackTrace stack, {
    String? context,
  }) async {
    try {
      // The RAW object on purpose: dart:developer only writes to the local
      // device/IDE console and Sentry does not read it, so the full message
      // stays visible while developing.
      dev.log(
        context == null ? 'capture' : 'capture ($context)',
        name: 'crash_reporter',
        error: error,
        stackTrace: stack,
        level: 1000, // SEVERE
      );
      final sink = debugSentrySink;
      // No sink and no active Sentry means no consumer, so skip sanitizing.
      // That is the normal case in dev/CI/tests, and `capture` sits in error
      // paths that can loop (outbox replay).
      if (sink == null && !isActive) return;

      final SanitizedError sanitized = sanitizeForReport(error);
      if (sink != null) {
        sink(sanitized, stack, context);
        return;
      }
      await Sentry.captureException(
        // Never `error` — see sanitizeForReport.
        sanitized,
        // The stack stays RAW: a Dart stack trace holds only library URIs,
        // class/method names and line numbers — all compile-time fixed, never
        // runtime values. It is the actual diagnosis once everything else is
        // stripped.
        stackTrace: stack,
        withScope: (scope) {
          if (context != null) scope.setTag('context', context);
          // Sentry derives the event `type` from `runtimeType`, which is now
          // `SanitizedError` for every report. The real type goes into this
          // tag so Sentry can still filter and group by it.
          scope.setTag('error_type', sanitized.type);
        },
      );
    } catch (e, s) {
      // Never propagate a reporting error; the inner try also covers
      // pathological error objects (e.g. a throwing toString()).
      try {
        dev.log('CrashReporter.capture failed',
            name: 'crash_reporter', error: e, stackTrace: s);
      } catch (_) {
        // Swallowed on purpose: capture must never throw.
      }
    }
  }

  /// Attaches a context trail to the next report. Without active Sentry just
  /// a `dart:developer` log. Never throws.
  ///
  /// [message] cannot be sanitized — free text is not separable from user
  /// data automatically. Callers must pass constants and counters only, never
  /// values from profile, meals or the weight series.
  static void breadcrumb(String message) {
    try {
      dev.log(message, name: 'crash_reporter');
      final sink = debugBreadcrumbSink;
      if (sink != null) {
        sink(message);
        return;
      }
      if (!isActive) return;
      unawaited(Sentry.addBreadcrumb(buildBreadcrumb(message)));
    } catch (e) {
      try {
        dev.log('CrashReporter.breadcrumb failed',
            name: 'crash_reporter', error: e);
      } catch (_) {
        // Swallowed on purpose: breadcrumb must never throw.
      }
    }
  }

  /// Category of every breadcrumb from this facade. Without it our own trails
  /// would be indistinguishable from foreign ones and dropped by our own
  /// allowlist filter ([sanitizeSentryBreadcrumb]).
  static const String breadcrumbCategory = 'eatova';

  /// Builds the breadcrumb [breadcrumb] hands to Sentry. Separate method so a
  /// test can prove our own breadcrumbs survive our own filter.
  @visibleForTesting
  static Breadcrumb buildBreadcrumb(String message) =>
      Breadcrumb(message: message, category: breadcrumbCategory);
}

/// The app's complete Sentry configuration — the seam that makes the wiring
/// testable.
///
/// `main.dart` passes only this function to `SentryFlutter.init` and never
/// touches `options` itself: a closure inside `main()` cannot be called and
/// therefore cannot be tested, so a deleted `beforeSend` line went unnoticed
/// once. A named function taking `SentryFlutterOptions` can be tested.
void configureSentry(SentryFlutterOptions options) {
  options.dsn = CrashReporter.dsn;

  // Conservative configuration — health data must never travel automatically.
  options.sendDefaultPii = false;
  options.attachScreenshot = false;
  // Explicit although the default is `false`: this is the list of switches
  // that must never flip. The experimental-member warning is accepted; a
  // default flip in a future sentry_flutter would cost far more.
  // ignore: experimental_member_use
  options.attachViewHierarchy = false;

  // C1, leak 1 — prevention at the source. `DebugPrintIntegration` turns
  // `debugPrint` into a breadcrumb collector and installs itself only in
  // release builds, where Flutter's `dumpErrorToConsole` writes the RAW
  // `toString()` of every unhandled framework error — exactly the texts
  // [sanitizeForReport] holds back on the exception side.
  options.enablePrintBreadcrumbs = false;

  // C1, leak 1 — backstop. Breadcrumbs also reach the hub from the native
  // scope and are mirrored back into it, and a native crash report leaves
  // without any Dart `beforeSend`. `beforeBreadcrumb` runs before the scope
  // observers, so only there are both directions caught.
  options.beforeBreadcrumb = sanitizeSentryBreadcrumb;

  // C1, leak 2/3: CrashReporter.capture only sanitizes what goes through the
  // facade; the Flutter/onError/runZonedGuarded integrations grab unhandled
  // errors DIRECTLY.
  options.beforeSend = sanitizeSentryEvent;

  // Review P10-01. Unlike the switches below this one defaults to TRUE
  // (sentry_flutter_options.dart:42), so it has to be assigned: left alone,
  // every release build with a DSN reports app starts and foreground changes
  // (session id, install id, start, duration, status) — usage telemetry, not
  // errors. The value is handed to the native SDKs
  // (sentry_native_channel.dart:47), which build the session envelopes
  // THEMSELVES; they never pass `beforeSend`, so none of the filters above
  // touch them. The price is Sentry's Release Health (crash-free rate), which
  // this project does not use; crash reporting itself is unaffected.
  options.enableAutoSessionTracking = false;

  // Deliberately NOT set (and pinned by the wiring test): `tracesSampleRate`
  // (spans carry transaction names, i.e. routes) and `replay.*` (session
  // replay films the screen). Both default to off.
  options.environment = kReleaseMode
      ? 'production'
      : kProfileMode
          ? 'profile'
          : 'development';
}

/// Breadcrumb categories whose content is known and free of user data.
///
/// Allowlist, not blocklist: an unknown category from a new Sentry version or
/// plugin falls into the closing default branch.
///
/// Kept out on purpose: `console` (arbitrary free text), `navigation` (route
/// names like `/meal/<uuid>`), `ui.click` (widget labels are displayed user
/// text). `http` is truncated rather than dropped
/// ([_kuerzeHttpBreadcrumb]). The app registers neither the navigator
/// observer nor the interaction widget today, but closing them now covers a
/// later addition.
const Set<String> _erlaubteBreadcrumbKategorien = <String>{
  CrashReporter.breadcrumbCategory,
  'app.lifecycle',
  'ui.lifecycle',
  'device.screen',
  'device.event',
  'device.orientation',
  'device.connectivity',
  'sentry.event',
  'sentry.transaction',
};

/// `Breadcrumb.http` fields that carry no runtime values.
///
/// Excluded: `reason` (raw server text), `http.query`/`http.fragment` (the
/// PostgREST query carries the user UUID in its filter) and `url`, which is
/// truncated to `scheme://host` separately.
const Set<String> _erlaubteHttpDatenfelder = <String>{
  'method',
  'status_code',
  'duration',
  'request_body_size',
  'response_body_size',
  'start_timestamp',
  'end_timestamp',
};

/// `beforeBreadcrumb` hook for [configureSentry] — C1, leak 1.
///
/// Runs before the scope observers that mirror the breadcrumb into the native
/// scope; only here are the breadcrumbs caught that later end up in a NATIVE
/// crash report, which leaves without any Dart `beforeSend`.
///
/// Never throws: `Scope` catches a throw but then lets the breadcrumb
/// THROUGH, so the closing has to happen here.
Breadcrumb? sanitizeSentryBreadcrumb(Breadcrumb? breadcrumb, Hint hint) {
  try {
    if (breadcrumb == null) return null;
    final String? kategorie = breadcrumb.category;
    // No category means unknown origin — covers the `print()` breadcrumb path
    // and any hand-built `Breadcrumb(message:)` from a third-party library.
    if (kategorie == null) return null;
    if (kategorie == 'http') return _kuerzeHttpBreadcrumb(breadcrumb);
    if (!_erlaubteBreadcrumbKategorien.contains(kategorie)) return null;
    return breadcrumb;
  } catch (_) {
    // When in doubt drop: a missing breadcrumb costs diagnosis, a leaked one
    // costs health data.
    return null;
  }
}

/// `http` breadcrumbs are truncated rather than dropped: method, status and
/// duration are the actual diagnosis of a sync failure and do not live in the
/// URL. Path and query must go — `?user_id=eq.<uuid>` on PostgREST,
/// `meal-images/<uuid>/...` on storage.
Breadcrumb _kuerzeHttpBreadcrumb(Breadcrumb breadcrumb) {
  // Under native instrumentation the free-text message is the whole request
  // line.
  breadcrumb.message = null;
  final Map<String, dynamic>? daten = breadcrumb.data;
  if (daten == null) return breadcrumb;
  final Map<String, dynamic> gefiltert = <String, dynamic>{};
  for (final MapEntry<String, dynamic> feld in daten.entries) {
    if (_erlaubteHttpDatenfelder.contains(feld.key)) {
      gefiltert[feld.key] = feld.value;
    }
  }
  gefiltert['url'] = _nurHerkunft(daten['url']);
  breadcrumb.data = gefiltert;
  return breadcrumb;
}

/// Reduces a URL to `scheme://host`. Anything not safely readable as an
/// http(s) URL with a host falls back to the placeholder, never the raw
/// value.
String _nurHerkunft(Object? url) {
  const String entfernt = '<URL entfernt>';
  if (url is! String) return entfernt;
  final Uri? uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return entfernt;
  if (uri.scheme != 'http' && uri.scheme != 'https') return entfernt;
  return '${uri.scheme}://${uri.host}';
}

/// Context keys Sentry may serialize.
///
/// `Contexts.toJson` passes every UNKNOWN key through unchanged — that is how
/// `flutter_error_details` escapes with its rendered `informationCollector`
/// text. Kept: device, OS, runtime, app, browser, GPU, culture, trace.
/// Dropped: `flutter_error_details` and any other unknown key, `feedback`
/// (verbatim user text plus contact data), `response` (HTTP metadata incl.
/// headers) and `flags` (feature-flag evaluations are user segmentation).
const Set<String> _erlaubteContextSchluessel = <String>{
  'app',
  'device',
  'os',
  'runtime',
  'runtimes',
  'browser',
  'gpu',
  'culture',
  'trace',
};

/// The ONLY error object this facade hands to Sentry.
///
/// Sentry builds its event from two strings of the throwable
/// (`toString()` and `runtimeType`), and both are free of user data here by
/// construction: the class holds only pre-filtered strings.
class SanitizedError implements Exception {
  const SanitizedError(this.type, [this.detail]);

  /// Runtime type of the original error, e.g. `PostgrestException`.
  final String type;

  /// The technical fields that passed, e.g. `code=23514`. Null when the type
  /// is not on the allowlist.
  final String? detail;

  @override
  String toString() => detail == null ? type : '$type $detail';
}

/// Type names of app-owned errors that are sanitized by construction, so
/// their full `toString()` passes.
///
/// `UndecryptableCacheSlot`: its fields are an error type name and a slot key
/// already stripped of the user UUID. The default branch would drop exactly
/// the information it exists for — WHICH slot failed to decrypt.
///
/// The three DEK bootstrap objects joined it on 2026-09-01 (mutation run T3,
/// confirmed by T11). They build a strike counter, the budget and the number
/// of purged slots into their message and were arriving in Sentry as a bare
/// type name, so "start 1 of 3" could not be told from "start 2 of 3" and
/// nobody learned how many dead slots a give-up had cleared. Their payload is
/// integers plus `error.runtimeType.toString()` — a type name, never the
/// error text, which is what the OS reason would sit in.
///
/// Matched by name, not `is`: the typed route would create an import cycle.
/// Under `--obfuscate` the name comparison fails and falls into the closing
/// default branch, i.e. the safe direction.
const Set<String> _sanitisiertPerKonstruktion = <String>{
  'UndecryptableCacheSlot',
  'VanishedCacheKey',
  'UnreadableCacheKey',
  'AbandonedCacheKey',
};

/// `beforeSend` hook for [configureSentry] — the second half of C1.
///
/// [CrashReporter.capture] is not the only route to Sentry: the Flutter,
/// onError and runZonedGuarded integrations grab unhandled errors directly,
/// so a `PostgrestException` from an uncaught future would otherwise leave
/// raw, `Failing row contains (…)` included.
///
/// The pass covers the whole event, not just `exceptions[].value`: events
/// from `FlutterErrorIntegration` often have no `exceptions` at all and carry
/// their payload in `contexts['flutter_error_details']`. Sanitized or
/// dropped: exception values, `mechanism.data`/`.meta` (see
/// [_redigiereMechanismus]), `contexts`, `message`, `breadcrumbs`, `extra`,
/// `request`, `user`. Types, stacks, tags and the compile-time-fixed fields
/// pass so grouping keeps working.
///
/// Never throws: a throw from `beforeSend` drops the WHOLE event, so a broken
/// filter would silently disable crash reporting.
SentryEvent? sanitizeSentryEvent(SentryEvent event, Hint hint) {
  try {
    _sanitisiereExceptions(event);
    _sanitisiereContexts(event);
    _sanitisiereMessage(event);
    _sanitisiereBreadcrumbs(event, hint);
    // ignore: deprecated_member_use
    event.extra = null;
    event.request = null;
    event.user = null;
  } catch (_) {
    // Unlike breadcrumbs, dropping is the worse option here: without an event
    // there is no diagnosis left. So clear every field that can carry free
    // text and keep the skeleton (type, stack, tags).
    try {
      event.message = null;
      event.breadcrumbs = null;
      // ignore: deprecated_member_use
      event.extra = null;
      event.request = null;
      event.user = null;
      for (final SentryException e in event.exceptions ?? const []) {
        e.value = e.type ?? 'Exception';
        final Mechanism? mechanismus = e.mechanism;
        // Empty reference value = nothing survives; otherwise the raw
        // `data['message']` of PlatformExceptionEventProcessor stays attached.
        if (mechanismus != null) {
          e.mechanism = _redigiereMechanismus(mechanismus, '');
        }
      }
    } catch (_) {
      // Swallowed on purpose: beforeSend must never throw.
    }
  }
  return event;
}

void _sanitisiereExceptions(SentryEvent event) {
  final List<SentryException>? exceptions = event.exceptions;
  if (exceptions == null || exceptions.isEmpty) return;
  for (final SentryException e in exceptions) {
    // Direct assignment instead of copyWith: `copyWith` is deprecated in
    // sentry 9.26 and `value` is a mutable field. The event goes out right
    // after, so a shared object is fine.
    //
    // `throwable` stays: it is not serialized, so it never leaves the device,
    // and Sentry's grouping still reads it.
    //
    // Without `throwable` (native-layer events) `e.type` must NOT go through
    // sanitizeForReport: it is a String and would hit the default branch,
    // yielding `String` instead of the real type name. `type` is a type name
    // by construction anyway — the user data sits only in `value`.
    final String wert = e.throwable == null
        ? SanitizedError(e.type ?? 'Exception').toString()
        : sanitizeForReport(e.throwable as Object).toString();
    e.value = wert;

    final Mechanism? mechanismus = e.mechanism;
    if (mechanismus != null) {
      e.mechanism = _redigiereMechanismus(mechanismus, wert);
    }
  }
}

/// C1, leak 4: `mechanism` carries free text that an event processor writes
/// BEFORE `beforeSend`.
///
/// `PlatformExceptionEventProcessor` puts `code` AND `message` of the
/// `PlatformException` into `mechanism.data`, so exactly the `message`
/// [sanitizeForReport] holds back on the `value` side escaped through it.
///
/// No second filter on purpose: a field survives only if it already appears
/// verbatim as `key=value` in the sanitized [wert]. By construction
/// `mechanism` can then carry nothing the allowlist did not already pass,
/// even if a future sentry_flutter adds another field.
///
/// A new object rather than mutation: `Mechanism.meta` only has a getter onto
/// an unmodifiable map, and `copyWith` is deprecated and would re-insert
/// `data`/`meta` via `??`.
Mechanism _redigiereMechanismus(Mechanism mechanism, String wert) => Mechanism(
      type: mechanism.type,
      // `description` is free text and `helpLink` a URL that may be
      // interpolated with error parameters — both stay out.
      handled: mechanism.handled,
      synthetic: mechanism.synthetic,
      // These four hold together the exception group built before
      // `beforeSend`; they are indices and field names, not runtime values.
      isExceptionGroup: mechanism.isExceptionGroup,
      source: mechanism.source,
      exceptionId: mechanism.exceptionId,
      parentId: mechanism.parentId,
      data: _nurSchonDurchgelassene(mechanism.data, wert),
      meta: _nurSchonDurchgelassene(mechanism.meta, wert),
    );

/// Keeps only the fields that already appear as `key=value` in the sanitized
/// exception value, so nothing new can escape. Everything else drops,
/// including nested entries whose `toString()` never matches [_feld]'s form.
Map<String, dynamic>? _nurSchonDurchgelassene(
  Map<String, dynamic> felder,
  String wert,
) {
  final Map<String, dynamic> gefiltert = <String, dynamic>{};
  for (final MapEntry<String, dynamic> feld in felder.entries) {
    if (wert.contains('${feld.key}=${feld.value}')) {
      gefiltert[feld.key] = feld.value;
    }
  }
  return gefiltert.isEmpty ? null : gefiltert;
}

/// C1, leak 2. `Contexts` is a `MapView`; the keys are copied first,
/// otherwise removing would raise a ConcurrentModificationError.
void _sanitisiereContexts(SentryEvent event) {
  final Contexts contexts = event.contexts;
  for (final String schluessel in contexts.keys.toList(growable: false)) {
    if (!_erlaubteContextSchluessel.contains(schluessel)) {
      contexts.remove(schluessel);
    }
  }
}

/// `SentryMessage.formatted` carries the interpolated runtime values, while
/// `template` is a source literal and still lets Sentry group. Leaving the
/// event without a message would be worse: Sentry would group everything.
void _sanitisiereMessage(SentryEvent event) {
  final SentryMessage? message = event.message;
  if (message == null) return;
  message.formatted = message.template ?? '<Nachricht entfernt>';
  message.params = null;
}

/// Second line behind [sanitizeSentryBreadcrumb]: the native contexts
/// integration writes breadcrumbs straight into `event.breadcrumbs`, and an
/// event can also be hand-built with breadcrumbs.
void _sanitisiereBreadcrumbs(SentryEvent event, Hint hint) {
  final List<Breadcrumb>? breadcrumbs = event.breadcrumbs;
  if (breadcrumbs == null) return;
  event.breadcrumbs = breadcrumbs
      .map((Breadcrumb b) => sanitizeSentryBreadcrumb(b, hint))
      .whereType<Breadcrumb>()
      .toList();
}

/// Reduces an arbitrary error object to what Sentry may see.
///
/// **Allowlist, not blocklist.** An unknown type yields only its type name.
/// A new dependency with a chatty `toString()` therefore cannot leak anything
/// unless someone adds a branch here on purpose.
///
/// Nearly every real `toString()` carries foreign data. Passed through: the
/// `code`/`statusCode`/`status`/`duration` fields of the Supabase, platform
/// and timeout exceptions. Held back: every `message` (Supabase generates
/// them server-side, often with the email address), every `uri` (the
/// PostgREST query carries the user UUID), `FormatException.source`,
/// `ArgumentError.invalidValue`/`RangeError` (the typed weight or height),
/// `NoSuchMethodError` (receiver and arguments) and `AssertionError`/
/// `FlutterError` (they render a diagnostics tree with displayed text).
///
/// The worst field is `PostgrestException.details`: on a CHECK violation it
/// is `Failing row contains (<uuid>, <email>, …)` — identity plus Art. 9
/// health values in one string.
///
/// [TypeError] is the only type passed in full: the runtime builds its text
/// from type names only, and it is the most valuable diagnosis there is.
///
/// Not `@visibleForTesting`: [sanitizeSentryEvent] needs it in production.
SanitizedError sanitizeForReport(Object error) {
  try {
    // Idempotent, because callers (e.g. secure_cache_store) may pre-filter.
    if (error is SanitizedError) return error;

    final String typ = error.runtimeType.toString();

    if (_sanitisiertPerKonstruktion.contains(typ)) {
      return SanitizedError(typ, error.toString());
    }

    if (error is PostgrestException) {
      // The SQLSTATE is the diagnosis: 23514 = CHECK, 23505 = unique,
      // 42501 = RLS. No user content.
      return SanitizedError(typ, _feld('code', error.code));
    }
    if (error is AuthException) {
      // Covers all AuthException subclasses; `typ` records the concrete one.
      // `originalError` (a raw http.Response with body) and `reasons` stay
      // out.
      return SanitizedError(
        typ,
        _felder(<String, Object?>{
          'statusCode': error.statusCode,
          'code': error.code,
        }),
      );
    }
    if (error is StorageException) {
      // `error` (the server slug) stays out: it comes raw from the response.
      return SanitizedError(typ, _feld('statusCode', error.statusCode));
    }
    if (error is FunctionException) {
      // `details` is the raw function response body — for analyze-meal that
      // is the user's recognised meal.
      return SanitizedError(typ, _feld('status', error.status));
    }
    if (error is PlatformException) {
      // `code` is a plugin-assigned constant ("sign_in_failed"); `details` is
      // arbitrary.
      return SanitizedError(typ, _feld('code', error.code));
    }
    if (error is TimeoutException) {
      return SanitizedError(typ, _feld('duration', error.duration));
    }
    if (error is TypeError) {
      return SanitizedError(typ, error.toString());
    }

    // Default: closed. Type name only.
    return SanitizedError(typ);
  } catch (_) {
    // Even `runtimeType.toString()` must not kill this. A useless report
    // beats a lost one, and beats a throw out of an error path.
    return const SanitizedError('<Fehlertyp nicht ermittelbar>');
  }
}

String? _feld(String name, Object? wert) => wert == null ? null : '$name=$wert';

String? _felder(Map<String, Object?> werte) {
  final Iterable<String> gesetzt = werte.entries
      .where((e) => e.value != null)
      .map((e) => '${e.key}=${e.value}');
  return gesetzt.isEmpty ? null : gesetzt.join(' ');
}
