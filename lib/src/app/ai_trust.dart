import 'dart:async';
import 'dart:developer' as dev;

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';

import '../models/ai_consent.dart';
import '../services/ai_trust_sync.dart';
import '../services/crash_reporter.dart';

/// The account's cached consent slot (the encrypted account cache; `HomeStore`
/// in the app).
abstract interface class AiConsentCache {
  Future<AiConsentRecord?> readAiConsent();
  Future<void> writeAiConsent(AiConsentRecord record);
}

/// How long an AI entry point waits for the cached (or, without a cache, the
/// logged) decision before it asks. Bounded so a hung keystore or a silent
/// socket never blocks the button; the sheet is the safe answer then.
const Duration kAiConsentReadyBudget = Duration(seconds: 4);

/// The AI consent and the Coach report path of ONE signed-in account
/// (review 2026-10-19, P1).
///
/// The shell creates it per account and session and binds it into the
/// app-level [AiTrustScope]; every AI entry point asks it through
/// `ensureAiConsent`. A grant counts only after the server logged it. A
/// withdrawal takes effect on the device at once and is uploaded as soon as
/// the server is reachable; until then it stays pending and no server read
/// turns it back into a grant.
class AiTrustController extends ChangeNotifier {
  AiTrustController({
    required AiConsentCache cache,
    AiConsentLog? consentLog,
    AiReportLog? reportLog,
  }) : _cache = cache,
       _consentLog = consentLog,
       _reportLog = reportLog,
       consentRequired = true;

  /// Preview and tests without a sync layer (debug builds only): nothing can
  /// be logged, so nothing is asked.
  AiTrustController.preview()
    : _cache = const _NoConsentCache(),
      _consentLog = null,
      _reportLog = null,
      consentRequired = false;

  final AiConsentCache _cache;
  final AiConsentLog? _consentLog;
  final AiReportLog? _reportLog;

  /// False only for [AiTrustController.preview].
  final bool consentRequired;

  AiConsentRecord? _record;
  bool _loaded = false;
  bool _disposed = false;

  /// Bumped by every local decision, so a server read that started before it
  /// cannot overwrite it when it lands.
  int _revision = 0;

  Future<void>? _loading;
  final Completer<void> _ready = Completer<void>();

  /// Server writes run one after another: a pending withdrawal always lands
  /// before a later grant.
  Future<void> _writes = Future<void>.value();

  /// The consent sheet on screen, shared by every entry point that asks while
  /// it is open.
  Future<bool>? _prompt;

  /// The latest known decision; null when there is none (or not yet loaded).
  AiConsentRecord? get record => _record;

  /// Whether the cached decision has been read.
  bool get loaded => _loaded;

  /// Whether AI features may send data now.
  bool get allowsAi => !consentRequired || (_record?.allowsAi ?? false);

  /// Whether a decision can be logged (a server log exists).
  bool get canRecord => _consentLog != null;

  /// Whether reports can be filed.
  bool get canReport => _reportLog != null;

  /// Completes once the decision is known well enough to ask or not: the
  /// cache answered, and without a cached decision the first server read
  /// answered or failed.
  Future<void> get ready => _ready.future;

  /// Reads the cache, then reconciles with the server in the background.
  /// Idempotent.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final revision = _revision;
    AiConsentRecord? cached;
    try {
      cached = await _cache.readAiConsent();
    } catch (e, st) {
      dev.log(
        'AI consent cache read failed',
        error: e,
        stackTrace: st,
        name: 'ai_trust',
      );
    }
    if (_disposed) return;
    if (revision == _revision) _record = cached;
    _loaded = true;
    notifyListeners();
    if (cached != null) _markReady();
    try {
      await refresh();
    } finally {
      _markReady();
    }
  }

  void _markReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  /// Uploads a pending withdrawal, otherwise adopts the server's latest
  /// decision. Failures leave the known state as it is.
  Future<void> refresh() async {
    final log = _consentLog;
    if (log == null || _disposed) return;
    final pending = _record;
    if (pending != null && pending.pendingUpload) {
      await _serialized(() => _uploadWithdrawal(pending));
      return;
    }
    final revision = _revision;
    final AiConsentRecord? latest;
    try {
      latest = await log.latest();
    } catch (_) {
      return; // Offline or unreadable: the cached decision stands.
    }
    if (_disposed || revision != _revision || latest == _record) return;
    _record = latest;
    notifyListeners();
    if (latest != null) await _writeCache(latest);
  }

  /// Logs a grant (with the health data consent) for the current text.
  /// Throws when the server did not log it; nothing is granted then.
  Future<void> grant() {
    // Both read at the tap, not when the queued write runs: a withdrawal
    // tapped after this grant is newer and must win.
    final revision = _revision;
    final current = _record;
    final pending = current != null && current.pendingUpload ? current : null;
    return _serialized(() async {
      final log = _consentLog;
      if (log == null) throw StateError('No consent log for this account');
      // The evidence log keeps the order of decisions.
      if (pending != null && !await _uploadWithdrawal(pending)) {
        throw StateError('Pending withdrawal could not be logged');
      }
      final logged = await log.record(granted: true, healthData: true);
      if (_disposed || revision != _revision) return;
      _revision++;
      _record = logged;
      notifyListeners();
      await _writeCache(logged);
    });
  }

  /// Withdraws the consent. Effective at once on this device; returns whether
  /// the server log already has it (otherwise it stays pending and the next
  /// [refresh] uploads it).
  Future<bool> withdraw() {
    _revision++;
    final local = AiConsentRecord.withdrawal(clock.now());
    _record = local;
    notifyListeners();
    unawaited(_writeCache(local));
    if (_consentLog == null) return Future<bool>.value(false);
    return _serialized(() => _uploadWithdrawal(local));
  }

  Future<bool> _uploadWithdrawal(AiConsentRecord pending) async {
    final log = _consentLog;
    if (log == null || _disposed) return false;
    // Already logged by an earlier queued write, or replaced by a newer
    // decision that is logged on its own.
    if (!identical(_record, pending)) return true;
    final AiConsentRecord logged;
    try {
      logged = await log.record(granted: false, healthData: false);
    } catch (e, st) {
      unawaited(
        CrashReporter.captureSyncFailure(e, st, context: 'ai-consent-withdraw'),
      );
      return false;
    }
    // A newer local decision owns the state; the row is logged either way.
    if (_disposed || !identical(_record, pending)) return true;
    _record = logged;
    notifyListeners();
    await _writeCache(logged);
    return true;
  }

  Future<void> _writeCache(AiConsentRecord record) async {
    try {
      await _cache.writeAiConsent(record);
    } catch (e, st) {
      dev.log(
        'AI consent cache write failed',
        error: e,
        stackTrace: st,
        name: 'ai_trust',
      );
    }
  }

  Future<T> _serialized<T>(Future<T> Function() body) {
    final result = _writes.then((_) => body());
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  /// Runs [ask] unless a consent prompt is already on screen, in which case
  /// every caller waits for that one.
  Future<bool> promptOnce(Future<bool> Function() ask) {
    final open = _prompt;
    if (open != null) return open;
    final prompt = ask().whenComplete(() => _prompt = null);
    _prompt = prompt;
    return prompt;
  }

  /// Files a report of Coach output. Throws on failure.
  Future<void> report({
    required String messageId,
    String? sessionId,
    required AiReportTarget target,
    required AiReportReason reason,
  }) {
    final log = _reportLog;
    if (log == null) {
      return Future<void>.error(StateError('No report log for this account'));
    }
    return log.report(
      messageId: messageId,
      sessionId: sessionId,
      target: target,
      reason: reason,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _markReady();
    super.dispose();
  }
}

class _NoConsentCache implements AiConsentCache {
  const _NoConsentCache();

  @override
  Future<AiConsentRecord?> readAiConsent() async => null;

  @override
  Future<void> writeAiConsent(AiConsentRecord record) async {}
}

/// The app-level slot the signed-in shell binds its account's
/// [AiTrustController] into. Plain holder, no notifications: binding happens
/// while the shell builds, and every reader looks the controller up when it
/// acts. A new account's shell replaces the binding; the leaving one unbinds
/// only itself.
class AiTrustBinding {
  AiTrustController? _controller;

  AiTrustController? get controller => _controller;

  void bind(AiTrustController controller) => _controller = controller;

  void unbind(AiTrustController controller) {
    if (identical(_controller, controller)) _controller = null;
  }
}

/// Provides the [AiTrustBinding] above the app's Navigator, so sheets and
/// pushed routes (Settings, the add-meal sheet, the import sheet) reach the
/// account's consent like the tabs do.
class AiTrustScope extends InheritedWidget {
  const AiTrustScope({super.key, required this.binding, required super.child});

  final AiTrustBinding binding;

  /// The binding, or null outside the app shell (widget tests, previews).
  static AiTrustBinding? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AiTrustScope>()?.binding;

  @override
  bool updateShouldNotify(AiTrustScope oldWidget) =>
      !identical(binding, oldWidget.binding);
}
