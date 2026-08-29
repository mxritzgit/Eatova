import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;

import '../auth/auth_repository.dart';
import '../l10n/l10n.dart';
import '../services/local_cache.dart'
    show KeyValueStore, SharedPreferencesStore;
import '../services/secure_screen.dart';
import '../services/sync_error_messages.dart' show isNetworkSyncError;
import '../theme/app_tokens.dart';
import '../widgets/auth/auth_controls.dart';
import '../widgets/common/app_snack.dart';
import '../widgets/design/controls.dart';
import '../widgets/design/sheets.dart';
import 'settings/account_change_messages.dart'
    show kAccountCodeLength, kAccountMinPasswordLength;

/// Which code flow is running: password reset or signup confirmation.
enum AuthCodeFlow { recovery, signup }

/// Coarse classification of an auth error — one branch per statement this page
/// can honestly make.
///
/// The first two are TYPED (P4-02). Classifying by server text alone had no
/// answer offline (there is no server text to read) and none for a failed auth
/// layer, so both landed in [unknown] — "please try again", advice that cannot
/// work in either case.
enum _AuthErrorKind {
  /// The auth layer never came up (see `UnavailableAuthRepository`); only a
  /// restart helps. Same statement as `auth_screen.dart` makes.
  unavailable,

  /// No connection to the server: nothing was sent, nothing was checked.
  offline,

  /// GoTrue's PER-REQUEST send lock, which names the seconds it has left.
  sendThrottled,

  /// GoTrue's HOURLY mail quota (`rate_limit_email_sent` = 2, see
  /// supabase/AUTH_EMAIL_OTP.md) is spent. That is minutes to an hour, not
  /// the "about a minute" both throttles used to claim.
  quotaExhausted,

  /// A throttle without a usable number in it.
  rateLimited,

  /// The server really did check the code and refused it.
  codeRejected,

  unknown,
}

/// A classified error plus what the server said about the wait.
class _AuthErrorBefund {
  const _AuthErrorBefund(this.kind, {this.retryAfter});

  final _AuthErrorKind kind;

  /// The wait GoTrue named, when it named one at all.
  final Duration? retryAfter;
}

/// GoTrue's per-request lock carries its remaining time in the message:
/// "For security purposes, you can only request this after 51 seconds."
final RegExp _sekundenImText = RegExp(r'(\d+)\s*second');

/// Above this many seconds the wait is spoken in minutes — a half-hour quota
/// block would otherwise read "in 1800 s".
const int _minutenSchwelleSekunden = 120;

/// GoTrue codes that really mean "the code did not work".
const Set<String> _abgelehnteCodes = <String>{
  'otp_expired',
  'otp_disabled',
  'invalid_credentials',
};

/// Text fallback for GoTrue answers that carry no code ("Token has expired or
/// is invalid", "Invalid token"). A bare `invalid` is missing on purpose — see
/// [_classifyAuthError].
final RegExp _abgelehntImText =
    RegExp(r'expired|invalid token|invalid otp|invalid code|\botp\b');

/// Classifies [error] for [_AuthCodeScreenState._friendlyError].
///
/// TYPE first, text fragments only as the last stage. The reverse order let
/// "invalid certificate" pass as an expired code and dropped every offline
/// error into the catch-all (P4-02).
_AuthErrorBefund _classifyAuthError(Object error) {
  if (error is AuthUnavailableException) {
    return const _AuthErrorBefund(_AuthErrorKind.unavailable);
  }
  // Same helper and same position as `settings/account_change_messages.dart`:
  // IOException (Socket/Tls), TimeoutException, ClientException and GoTrue's
  // own AuthRetryableFetchException. A 429 becomes an AuthApiException in
  // gotrue's fetch.dart, so this branch cannot swallow a throttle.
  if (isNetworkSyncError(error)) {
    return const _AuthErrorBefund(_AuthErrorKind.offline);
  }

  final raw = error.toString().toLowerCase();
  final code = error is AuthException ? error.code : null;
  final istMailDrossel = code == 'over_email_send_rate_limit';
  final istDrossel = istMailDrossel ||
      code == 'over_request_rate_limit' ||
      raw.contains('rate limit') ||
      raw.contains('rate_limit') ||
      raw.contains('too many') ||
      raw.contains('for security purposes');

  if (istDrossel) {
    // Both mail throttles ship the SAME error code; only the message tells
    // them apart — the per-request lock names its seconds, the hourly quota
    // does not (P4-03).
    final treffer = _sekundenImText.firstMatch(raw);
    final sekunden = treffer == null ? null : int.tryParse(treffer.group(1)!);
    if (sekunden != null && sekunden > 0) {
      return _AuthErrorBefund(
        _AuthErrorKind.sendThrottled,
        retryAfter: Duration(seconds: sekunden),
      );
    }
    if (istMailDrossel || raw.contains('email rate limit')) {
      return const _AuthErrorBefund(_AuthErrorKind.quotaExhausted);
    }
    return const _AuthErrorBefund(_AuthErrorKind.rateLimited);
  }

  // GoTrue's OWN code for a refused code first (P4-02c) — `auth_screen.dart`
  // takes exactly this route for `invalid_credentials`.
  if (code != null && _abgelehnteCodes.contains(code)) {
    return const _AuthErrorBefund(_AuthErrorKind.codeRejected);
  }
  // Text fallback for answers without a code. The bare `invalid` that used to
  // stand here also caught `AuthApiException('Invalid API key')` — a
  // misconfigured anon key read as "your code is wrong" AND burned one of the
  // five attempts against a lockout only a new code can lift.
  if (_abgelehntImText.hasMatch(raw)) {
    return const _AuthErrorBefund(_AuthErrorKind.codeRejected);
  }
  return const _AuthErrorBefund(_AuthErrorKind.unknown);
}

/// Guard state for ONE address.
class _ThrottleState {
  const _ThrottleState({
    this.lastSent,
    this.failedAttempts = 0,
    this.cooldown = _OtpSendThrottle.cooldown,
    this.bypassUsed = false,
  });

  final DateTime? lastSent;
  final int failedAttempts;

  /// How long [lastSent] blocks the next send. Variable since P4-03: the
  /// server's own wait wins when it is longer, and the mail quota blocks for
  /// [_OtpSendThrottle.quotaCooldown] instead of a minute.
  final Duration cooldown;

  /// The "try anyway" escape out of the quota block was already spent for this
  /// lock (P4-03b). Persisted with the rest, or leaving and reopening the page
  /// would hand out a fresh escape every time — exactly the hole the address
  /// binding closed in the first place.
  final bool bypassUsed;
}

/// Persistent, ADDRESS-bound guard for sending codes (audit 2026-08-14).
///
/// `sendPasswordReset` mails any typed address, so a guard living only on the
/// screen instance is none: leaving and reopening the page would reset it and
/// let a stranger's inbox be flooded while the GoTrue hourly quota drains.
/// The timestamp therefore goes to device storage, keyed by the address.
///
/// The key holds an FNV-1a digest of the normalized address, not its plaintext,
/// so prefs keep no list of typed (possibly foreign) addresses. The digest only
/// needs to be stable and collision-poor, not cryptographic.
///
/// Storage carries the guard's DURABILITY, it is not its precondition: if it
/// does not answer, sending still proceeds — the state is read ahead (while
/// typing) and written alongside, never awaited on the send path. Awaiting it
/// once made the button fail-closed and could block every mail.
///
/// Deliberately FAIL-OPEN and purely CLIENT-SIDE: another client (curl, a
/// second device, a patched app) bypasses it trivially, [maxAttempts]
/// included. It is a cost and abuse brake for the benign case, NOT brute-force
/// protection — that must come from the server (see
/// supabase/AUTH_EMAIL_OTP.md).
class _OtpSendThrottle {
  _OtpSendThrottle(this._injected);

  /// Floor for every lock, and the wait after a successful send. A shorter
  /// value named by the server does not lower it: the brake is ours.
  static const Duration cooldown = Duration(seconds: 60);

  /// Lock after GoTrue's mail quota (`rate_limit_email_sent` = 2/h) is spent.
  ///
  /// Not an hour: that quota is a TOKEN BUCKET (burst 2, refill 2 per hour), so
  /// the FIRST token is back after ~1800 s, not after 3600 (P4-03b). A full
  /// hour was the honest upper bound for the bucket to be full again — but the
  /// user only needs one token, and locking them out for twice the real wait
  /// with no way out was the one path where the P4-03 fix made things worse.
  /// The escape link ([_AuthCodeScreenState._resend] with `trotzdem: true`)
  /// covers the rest of the guess. Verifying a code that already arrived stays
  /// possible the whole time.
  static const Duration quotaCooldown = Duration(minutes: 30);

  static const int maxAttempts = 5;
  static const String storagePrefix = 'eatova.v1.otp_guard.';

  final KeyValueStore? _injected;

  /// The single in-flight resolution; without it every read and write would
  /// start another `SharedPreferences.getInstance()`.
  Future<KeyValueStore?>? _resolving;

  Future<KeyValueStore?> _store() {
    final injiziert = _injected;
    if (injiziert != null) return Future<KeyValueStore?>.value(injiziert);
    return _resolving ??= _resolve();
  }

  Future<KeyValueStore?> _resolve() async {
    try {
      return await SharedPreferencesStore.create();
    } catch (_) {
      // Prefs unavailable: see class comment (fail-open).
      return null;
    }
  }

  static String _key(String email) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(email.trim().toLowerCase())) {
      hash = (hash ^ byte) & 0xFFFFFFFF;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return '$storagePrefix${hash.toRadixString(16)}';
  }

  Future<_ThrottleState> read(String email) async {
    final store = await _store();
    if (store == null) return const _ThrottleState();
    final key = _key(email);
    try {
      final roh = await store.getString(key);
      if (roh == null) return const _ThrottleState();
      final map = jsonDecode(roh) as Map<String, dynamic>;
      final gesendet = map['sent'];
      final fehl = map['failed'];
      final warte = map['wait'];
      final stand = _ThrottleState(
        lastSent: gesendet is int
            ? DateTime.fromMillisecondsSinceEpoch(gesendet)
            : null,
        failedAttempts: fehl is int && fehl > 0 ? fehl : 0,
        // Clamped to [quotaCooldown]: an entry written by an older build has
        // no 'wait' at all, and a broken (or tampered) one must not be able to
        // block sending for days.
        cooldown: warte is int && warte > 0
            ? Duration(seconds: warte.clamp(1, quotaCooldown.inSeconds))
            : cooldown,
        bypassUsed: map['bypass'] == true,
      );
      // Clean up on read (W3c): `otp_guard.<hash>` keys would otherwise pile
      // up forever; no background job needed.
      if (_expired(stand)) {
        unawaited(store.remove(key));
        return const _ThrottleState();
      }
      return stand;
    } catch (_) {
      // A broken entry must not block the flow.
      return const _ThrottleState();
    }
  }

  /// `true` when [stand] no longer has any effect and may be evicted.
  ///
  /// An active lockout (>= [maxAttempts]) never expires on its own — it holds
  /// until a real new send ([_stamp] with `resetAttempts: true`) and must not
  /// be lifted silently by the cleanup.
  bool _expired(_ThrottleState stand) {
    if (stand.failedAttempts >= maxAttempts) return false;
    final start = stand.lastSent;
    if (start == null) return false;
    return clock.now().difference(start) >= stand.cooldown;
  }

  /// `true` when the state was actually persisted.
  Future<bool> write(String email, _ThrottleState state) async {
    final store = await _store();
    if (store == null) return false;
    try {
      await store.setString(
        _key(email),
        jsonEncode(<String, dynamic>{
          'sent': state.lastSent?.millisecondsSinceEpoch,
          'failed': state.failedAttempts,
          'wait': state.cooldown.inSeconds,
          'bypass': state.bypassUsed,
        }),
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Page for the 8-digit e-mail codes (OTP instead of mail link, length in
/// [kAccountCodeLength]). Codes are valid 10 minutes (mailer_otp_exp).
///
///  * [AuthCodeFlow.recovery]: enter mail -> request code -> verify (creates
///    the session) -> set new password. The send confirmation stays NEUTRAL:
///    it never reveals whether an account exists for the address.
///  * [AuthCodeFlow.signup]: address is fixed, only the code is checked; the
///    AuthGate then switches to the home page on its own.
class AuthCodeScreen extends StatefulWidget {
  const AuthCodeScreen({
    super.key,
    required this.authRepository,
    required this.flow,
    this.initialEmail = '',
    this.throttleStore,
  });

  final AuthRepository authRepository;
  final AuthCodeFlow flow;
  final String initialEmail;

  /// Replaces SharedPreferences as the guard's storage — for tests that
  /// reproduce the cooldown without a plugin channel.
  final KeyValueStore? throttleStore;

  @override
  State<AuthCodeScreen> createState() => _AuthCodeScreenState();
}

/// Steps of the recovery flow; signup starts at the code.
enum _Step { email, code, password }

class _AuthCodeScreenState extends State<AuthCodeScreen> {
  late final TextEditingController _email =
      TextEditingController(text: widget.initialEmail);
  final TextEditingController _code = TextEditingController();
  final TextEditingController _password = TextEditingController();

  late _Step _step =
      widget.flow == AuthCodeFlow.signup ? _Step.code : _Step.email;
  bool _busy = false;
  bool _passwordVisible = false;
  String? _error;
  String? _message;

  late final _OtpSendThrottle _throttle =
      _OtpSendThrottle(widget.throttleStore);
  DateTime? _lastSent;
  int _failedAttempts = 0;
  int _cooldownSeconds = 0;

  /// How long [_lastSent] blocks — 60 s after a normal send, the server's own
  /// wait when it is longer, [_OtpSendThrottle.quotaCooldown] after the mail
  /// quota (P4-03).
  Duration _cooldownDauer = _OtpSendThrottle.cooldown;

  /// The escape out of the quota block is spent for the current lock (P4-03b).
  bool _bypassUsed = false;

  Timer? _ticker;

  /// Address [_lastSent] and [_failedAttempts] currently belong to, and the
  /// token that fences off late-arriving reads.
  String? _guardFor;

  /// `true` once this session stamped or counted for [_guardFor]; a read
  /// arriving afterwards is stale and must not roll the screen state back.
  bool _guardTouched = false;

  bool get _isRecovery => widget.flow == AuthCodeFlow.recovery;

  /// Address the guard and the failure counter hang on. From the code step on
  /// the field is hidden, so the value is stable.
  String get _guardEmail => _email.text.trim();

  /// Storage and guard must mean the same address — same normalization as
  /// [_OtpSendThrottle._key].
  static String _normalisiert(String email) => email.trim().toLowerCase();

  bool get _locked => _failedAttempts >= _OtpSendThrottle.maxAttempts;

  /// True while the running lock is our own ESTIMATE of the mail quota rather
  /// than a wait the server named. Only then is "try anyway" honest — a
  /// server-named number is authoritative and needs no escape (P4-03b).
  bool get _sperreIstSchaetzung =>
      _cooldownDauer >= _OtpSendThrottle.quotaCooldown;

  AppLocalizations get _l10n => context.l10n;

  @override
  void initState() {
    super.initState();
    _email.addListener(_onEmailChanged);
    unawaited(_hydrate(widget.initialEmail));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _email.removeListener(_onEmailChanged);
    _email.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Loads stamp and failure counter from storage, on page build and on every
  /// address change — that is how the guard survives navigation and restarts.
  ///
  /// Deliberately NOT on the send path: the tap must never wait for device
  /// storage (see [_OtpSendThrottle]). If the state is still pending, the
  /// guard simply does not apply — fail-open.
  Future<void> _hydrate(String email) async {
    final ziel = _normalisiert(email);
    if (ziel.isEmpty) return;
    _guardFor = ziel;
    final stand = await _throttle.read(ziel);
    // Different address by now — or the screen already knows better?
    if (!mounted || _guardFor != ziel || _guardTouched) return;
    setState(() {
      _lastSent = stand.lastSent;
      _failedAttempts = stand.failedAttempts;
      _cooldownDauer = stand.cooldown;
      _bypassUsed = stand.bypassUsed;
      _cooldownSeconds = _remainingSeconds();
    });
    _syncTicker();
  }

  /// The guard is bound to the ADDRESS, so a newly typed one starts fresh.
  /// Storage is read while typing, so the state is there before the tap.
  void _onEmailChanged() {
    final ziel = _normalisiert(_email.text);
    if (ziel == _guardFor) return;
    setState(() {
      _guardFor = null;
      _guardTouched = false;
      _lastSent = null;
      _failedAttempts = 0;
      _cooldownDauer = _OtpSendThrottle.cooldown;
      _bypassUsed = false;
      _cooldownSeconds = 0;
    });
    _syncTicker();
    unawaited(_hydrate(ziel));
  }

  int _remainingSeconds() {
    final start = _lastSent;
    if (start == null) return 0;
    final dauer = _cooldownDauer;
    final rest = dauer - clock.now().difference(start);
    // `isNegative` clamps the low end; the high end needs the same clamp: a
    // remainder above the cooldown itself means a rewound device clock, not a
    // longer cooldown. Without it the user is stuck in a persistent self-DoS
    // ("next code in 86400 s") (W3b).
    if (rest.isNegative || rest > dauer) return 0;
    return (rest.inMilliseconds / 1000).ceil();
  }

  /// Label of the resend link. Seconds up to [_minutenSchwelleSekunden],
  /// minutes above it — the hourly quota block would otherwise count down
  /// from "3600 s" (P4-03).
  String _countdownLabel(int sekunden) => sekunden > _minutenSchwelleSekunden
      ? _l10n.authCodeResendCountdownMinutes((sekunden / 60).ceil())
      : _l10n.authCodeResendCountdown(sekunden);

  /// Same split for the inline hint on a tap that came too early.
  String _wartehinweis(int sekunden) => sekunden > _minutenSchwelleSekunden
      ? _l10n.authCodeThrottleWaitMinutes((sekunden / 60).ceil())
      : _l10n.authCodeThrottleWait(sekunden);

  /// And for the server's own throttle answer.
  String _drosselHinweis(int sekunden) => sekunden > _minutenSchwelleSekunden
      ? _l10n.authCodeRateLimitedMinutes((sekunden / 60).ceil())
      : _l10n.authCodeRateLimitedSeconds(sekunden);

  void _syncTicker() {
    if (_cooldownSeconds <= 0) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _tick() {
    final rest = _remainingSeconds();
    // No rebuild without a visible change.
    if (rest == _cooldownSeconds) return;
    // Above the threshold only a changed MINUTE is visible; an hour-long quota
    // block would otherwise rebuild the page 3600 times to show the same text.
    // The value still has to advance, or the next tick compares against a
    // stale one.
    if (rest > _minutenSchwelleSekunden &&
        _cooldownSeconds > _minutenSchwelleSekunden &&
        (rest / 60).ceil() == (_cooldownSeconds / 60).ceil()) {
      _cooldownSeconds = rest;
      return;
    }
    setState(() => _cooldownSeconds = rest);
    if (rest <= 0) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  /// Stamps a send. The guard applies IMMEDIATELY; persisting runs alongside
  /// and only makes it durable. [resetAttempts] is for real sends — a new code
  /// voids the old failed attempts. [cooldown] is how long the stamp blocks;
  /// it goes to storage too, so the block survives navigation and restarts.
  void _stamp(
    String email, {
    required bool resetAttempts,
    required Duration cooldown,
    bool bypassUsed = false,
  }) {
    final jetzt = clock.now();
    final versuche = resetAttempts ? 0 : _failedAttempts;
    _guardTouched = true;
    unawaited(_throttle.write(
      email,
      _ThrottleState(
        lastSent: jetzt,
        failedAttempts: versuche,
        cooldown: cooldown,
        bypassUsed: bypassUsed,
      ),
    ));
    if (!mounted) return;
    setState(() {
      _guardFor = _normalisiert(email);
      _lastSent = jetzt;
      _failedAttempts = versuche;
      _cooldownDauer = cooldown;
      _bypassUsed = bypassUsed;
      _cooldownSeconds = _remainingSeconds();
    });
    _syncTicker();
  }

  /// Like [_stamp] without awaiting storage: the counter costs no mail, it
  /// only locks the input until a new code arrives.
  void _countFailedAttempt(String email) {
    final naechster = _failedAttempts + 1;
    _guardTouched = true;
    unawaited(_throttle.write(
      email,
      _ThrottleState(
        lastSent: _lastSent,
        failedAttempts: naechster,
        cooldown: _cooldownDauer,
        bypassUsed: _bypassUsed,
      ),
    ));
    if (!mounted) return;
    setState(() => _failedAttempts = naechster);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendlyError(Object error) {
    final befund = _classifyAuthError(error);
    switch (befund.kind) {
      case _AuthErrorKind.unavailable:
        return _l10n.authErrorUnavailable;
      case _AuthErrorKind.offline:
        return _l10n.authCodeOfflineError;
      case _AuthErrorKind.sendThrottled:
        // The number the guard really holds — not the server's raw one, which
        // can be below our own floor. Seconds or minutes by the SAME threshold
        // as the countdown link (P4-03c): a 180 s lock used to read "noch 180 s
        // gesperrt" right above "Neuen Code in 3 min anfordern".
        return _drosselHinweis(_sperrDauer(befund).inSeconds);
      case _AuthErrorKind.quotaExhausted:
        return _l10n.authCodeQuotaExhausted;
      case _AuthErrorKind.rateLimited:
        return _l10n.authCodeRateLimited;
      case _AuthErrorKind.codeRejected:
        return _l10n.authCodeErrorRejected;
      case _AuthErrorKind.unknown:
        return _l10n.authErrorGeneric;
    }
  }

  /// How long a rejected send blocks the next one — `Duration.zero` when the
  /// error says nothing about sending.
  ///
  /// [_OtpSendThrottle.cooldown] stays the floor: a server wait BELOW it must
  /// not weaken our own abuse brake, and the message quotes exactly the value
  /// used here, so hint and countdown can never disagree.
  Duration _sperrDauer(_AuthErrorBefund befund) {
    switch (befund.kind) {
      case _AuthErrorKind.quotaExhausted:
        return _OtpSendThrottle.quotaCooldown;
      case _AuthErrorKind.sendThrottled:
        final genannt = befund.retryAfter ?? Duration.zero;
        return genannt > _OtpSendThrottle.cooldown
            ? genannt
            : _OtpSendThrottle.cooldown;
      case _AuthErrorKind.rateLimited:
        return _OtpSendThrottle.cooldown;
      case _AuthErrorKind.unavailable:
      case _AuthErrorKind.offline:
      case _AuthErrorKind.codeRejected:
      case _AuthErrorKind.unknown:
        return Duration.zero;
    }
  }

  /// Catches the server's throttle error and stamps the guard with the wait it
  /// really implies, so the countdown shows when sending resumes instead of
  /// inviting blind retries.
  Future<void> _sendGuarded(
    String email,
    Future<void> Function() versand, {
    bool bypassUsed = false,
  }) async {
    try {
      await versand();
    } catch (error) {
      final sperre = _sperrDauer(_classifyAuthError(error));
      if (sperre > Duration.zero) {
        // [bypassUsed] carries into the new stamp: the escape is one per lock,
        // and a failed escape must not hand out the next one.
        _stamp(
          email,
          resetAttempts: false,
          cooldown: sperre,
          bypassUsed: bypassUsed,
        );
      }
      rethrow;
    }
    // A mail really went out: the lock is over and its escape with it.
    _stamp(
      email,
      resetAttempts: true,
      cooldown: _OtpSendThrottle.cooldown,
    );
  }

  Future<void> _sendCode() async {
    final email = _email.text.trim();
    if (!email.contains('@') || !email.contains('.')) {
      setState(() => _error = _l10n.authErrorInvalidEmail);
      return;
    }
    // The state for this address arrived while typing (_onEmailChanged); this
    // only reads what is already there — awaiting storage would stall the very
    // first send.
    final rest = _remainingSeconds();
    if (rest > 0) {
      setState(() => _error = _wartehinweis(rest));
      return;
    }
    await _run(() async {
      await _sendGuarded(
          email, () => widget.authRepository.sendPasswordReset(email));
      if (!mounted) return;
      setState(() {
        _step = _Step.code;
        _message = _l10n.authCodeSentNeutral(kAccountCodeLength);
      });
    });
  }

  /// [trotzdem] is the escape out of a lock this app only GUESSED at
  /// ([_sperreIstSchaetzung]): it sends once despite the countdown. See
  /// [_OtpSendThrottle.quotaCooldown] — the mail bucket refills gradually and
  /// the server never says when, so the server is the only authority on
  /// whether the next mail goes out. One escape per lock; if it fails, the
  /// lock is stamped anew and the link is gone.
  Future<void> _resend({bool trotzdem = false}) async {
    final email = _guardEmail;
    final rest = _remainingSeconds();
    if (rest > 0 && !trotzdem) {
      setState(() => _error = _wartehinweis(rest));
      return;
    }
    await _run(() async {
      await _sendGuarded(
        email,
        () => _isRecovery
            ? widget.authRepository.sendPasswordReset(email)
            : widget.authRepository.resendSignupCode(email),
        bypassUsed: trotzdem,
      );
      if (!mounted) return;
      setState(() => _message = _l10n.authCodeResent);
    });
  }

  Future<void> _verify() async {
    if (_locked) return;
    final code = _code.text.trim();
    if (code.length != kAccountCodeLength) {
      setState(() => _error = _l10n.authCodeErrorLength(kAccountCodeLength));
      return;
    }
    final email = _guardEmail;
    await _run(() async {
      try {
        if (_isRecovery) {
          await widget.authRepository
              .verifyRecoveryCode(email: email, code: code);
          if (!mounted) return;
          setState(() => _step = _Step.password);
        } else {
          await widget.authRepository
              .verifySignupCode(email: email, code: code);
          if (!mounted) return;
          // Session established — the AuthGate below this route switches to
          // the home page, so this screen is done.
          Navigator.of(context).pop();
        }
      } catch (error) {
        // Only a truly REJECTED code counts: a network or throttle error means
        // the server never checked it.
        if (_classifyAuthError(error).kind == _AuthErrorKind.codeRejected) {
          _countFailedAttempt(email);
          if (_locked) {
            // This attempt just triggered the lockout; from here the standing
            // hint in build() owns the message. Rethrowing would let `_run`
            // put the code-specific text into `_error`, which takes precedence
            // over that hint even though the field is locked.
            return;
          }
        }
        rethrow;
      }
    });
  }

  Future<void> _savePassword() async {
    if (_password.text.length < kAccountMinPasswordLength) {
      setState(() => _error =
          _l10n.authErrorPasswordTooShort(kAccountMinPasswordLength));
      return;
    }
    await _run(() async {
      await widget.authRepository.updatePassword(_password.text);
      if (!mounted) return;
      // Lets the password manager store the new password.
      TextInput.finishAutofillContext();
      final done = _l10n.authCodePasswordUpdated;
      Navigator.of(context).pop();
      showAppSnack(context, done, icon: Icons.lock_reset_rounded);
    });
  }

  @override
  Widget build(BuildContext context) {
    final gesperrt = _locked && _step == _Step.code;
    // A CURRENT error (e.g. a failed resend during the lockout) outranks the
    // lockout's standing hint; without `_error` the hint shows. The reverse
    // order swallowed every later error once locked, making the link look dead
    // (W3).
    final fehlerText =
        _error ?? (gesperrt ? _l10n.authCodeTooManyAttempts : null);
    final t = context.t;
    final l10n = _l10n;
    final email = _email.text.trim();
    return SecureScreenGuard(
      child: Scaffold(
        key: const ValueKey('auth-code-screen'),
        backgroundColor: t.bg,
        body: SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
                20, 8, 20, 24 + MediaQuery.viewInsetsOf(context).bottom),
            // One autofill context: the password manager sees e-mail and new
            // password together and is told when they are final.
            child: AutofillGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Own header instead of a Material AppBar: the AppBar drew
                  // its scheme surface over the page ground (F2-01).
                  Row(
                    children: [
                      SquareIconButton(
                        key: const ValueKey('auth-code-back'),
                        icon: Icons.chevron_left_rounded,
                        onTap: _busy
                            ? null
                            : () => Navigator.of(context).maybePop(),
                        semanticLabel: l10n.authBackSemanticLabel,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text(
                    switch (_step) {
                      _Step.email => l10n.authCodeTitleEmail,
                      _Step.code => l10n.authCodeTitleCode,
                      _Step.password => l10n.authCodeTitlePassword,
                    },
                    style: AppType.display(28, color: t.ink, height: 1.08),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    switch (_step) {
                      _Step.email =>
                        l10n.authCodeSubtitleEmail(kAccountCodeLength),
                      _Step.code => _isRecovery
                          ? l10n.authCodeSubtitleRecovery(email)
                          : l10n.authCodeSubtitleSignup(email),
                      _Step.password => l10n.authCodeSubtitlePassword,
                    },
                    style: AppType.ui(13.5, color: t.ink2, height: 1.45),
                  ),
                  const SizedBox(height: 26),
                  if (_step == _Step.email) ...[
                    AuthField(
                      fieldKey: const ValueKey('code-email-field'),
                      controller: _email,
                      label: l10n.authFieldEmailLabel,
                      hint: l10n.authFieldEmailHint,
                      icon: Icons.alternate_email_rounded,
                      enabled: !_busy,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.done,
                      autocorrect: false,
                      enableSuggestions: false,
                      autofillHints: const [AutofillHints.email],
                      onSubmitted: (_) => _sendCode(),
                    ),
                  ],
                  if (_step == _Step.code) ...[
                    _CodeField(
                      fieldKey: const ValueKey('code-field'),
                      controller: _code,
                      enabled: !_busy && !gesperrt,
                      onSubmitted: _verify,
                    ),
                  ],
                  if (_step == _Step.password) ...[
                    AuthField(
                      fieldKey: const ValueKey('code-password-field'),
                      controller: _password,
                      label: l10n.authCodeTitlePassword,
                      hint: l10n.authFieldPasswordHint,
                      icon: Icons.lock_outline_rounded,
                      enabled: !_busy,
                      textInputAction: TextInputAction.done,
                      autofillHints: const [AutofillHints.newPassword],
                      obscure: !_passwordVisible,
                      onSubmitted: (_) => _savePassword(),
                      trailing: AuthPasswordToggle(
                        toggleKey: const ValueKey('code-toggle-password'),
                        visible: _passwordVisible,
                        showLabel: l10n.authShowPasswordTooltip,
                        hideLabel: l10n.authHidePasswordTooltip,
                        onTap: () => setState(
                            () => _passwordVisible = !_passwordVisible),
                      ),
                    ),
                  ],
                  if (fehlerText != null) ...[
                    const SizedBox(height: 14),
                    AuthInlineNote(
                      noteKey: const ValueKey('code-error'),
                      text: fehlerText,
                      tone: AuthNoteTone.error,
                    ),
                  ],
                  if (_message != null) ...[
                    const SizedBox(height: 14),
                    AuthInlineNote(
                      noteKey: const ValueKey('code-message'),
                      text: _message!,
                      tone: AuthNoteTone.info,
                    ),
                  ],
                  const SizedBox(height: 22),
                  AuthPrimaryButton(
                    buttonKey: const ValueKey('code-primary'),
                    label: switch (_step) {
                      _Step.email => l10n.authCodeRequestCta,
                      _Step.code => l10n.authCodeVerifyCta,
                      _Step.password => l10n.authCodeSavePasswordCta,
                    },
                    loading: _busy,
                    enabled: !_busy && !gesperrt,
                    onTap: switch (_step) {
                      _Step.email => _sendCode,
                      _Step.code => _verify,
                      _Step.password => _savePassword,
                    },
                  ),
                  if (_step == _Step.code) ...[
                    const SizedBox(height: 12),
                    Center(
                      child: AuthTextLink(
                        linkKey: const ValueKey('code-resend'),
                        label: _cooldownSeconds > 0
                            ? _countdownLabel(_cooldownSeconds)
                            : l10n.authCodeResendCta,
                        // The tap stays enabled during the cooldown so
                        // _resend can say how long is left; a dead link
                        // would leave the user guessing.
                        onTap: _busy ? null : () => _resend(),
                      ),
                    ),
                    // The escape out of a GUESSED lock (P4-03b). Shown only
                    // while that lock runs, and traded for a sentence once
                    // spent — a dimmed dead link would say less.
                    if (_cooldownSeconds > 0 && _sperreIstSchaetzung)
                      Center(
                        child: _bypassUsed
                            ? Padding(
                                key: const ValueKey('code-send-anyway-used'),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 6),
                                child: Text(
                                  l10n.authCodeSendAnywayUsed,
                                  textAlign: TextAlign.center,
                                  style: AppType.ui(12, color: t.ink2,
                                      height: 1.4),
                                ),
                              )
                            : AuthTextLink(
                                linkKey: const ValueKey('code-send-anyway'),
                                label: l10n.authCodeSendAnyway,
                                emphasis: true,
                                onTap: _busy
                                    ? null
                                    : () => _resend(trotzdem: true),
                              ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Large code capsule: [kAccountCodeLength] digits, wide tracking, tabular.
/// A [FieldCapsule] like [AuthField] (field / fieldFocus, no ring); a minimum
/// height instead of a fixed one, so 200 % system font does not overflow.
class _CodeField extends StatelessWidget {
  const _CodeField({
    required this.fieldKey,
    required this.controller,
    required this.enabled,
    required this.onSubmitted,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final label = context.l10n.authCodeFieldLabel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: AppType.eyebrow(t.ink2, size: 10.5),
        ),
        const SizedBox(height: 8),
        // The `Focus` ancestor only observes (cannot take focus, skipped in
        // traversal): `Focus.of` rebuilds the capsule on focus changes.
        Focus(
          canRequestFocus: false,
          skipTraversal: true,
          includeSemantics: false,
          child: Builder(
            builder: (context) => FieldCapsule(
              focused: Focus.of(context).hasFocus,
              enabled: enabled,
              constraints: const BoxConstraints(minHeight: 64),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              alignment: Alignment.center,
              // Spoken name for the field; without it a screen reader only
              // reads the dot hint.
              child: Semantics(
                label: label,
                child: TextField(
                  key: fieldKey,
                  controller: controller,
                  enabled: enabled,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  // Without this hint the password manager never offers the
                  // code.
                  autofillHints: const [AutofillHints.oneTimeCode],
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(kAccountCodeLength),
                  ],
                  textAlign: TextAlign.center,
                  cursorColor: t.accent,
                  onSubmitted: (_) => onSubmitted(),
                  style: AppType.display(26, color: t.ink, letterSpacing: 10),
                  decoration: InputDecoration(
                    // One placeholder dot per digit.
                    hintText: '·' * kAccountCodeLength,
                    hintStyle:
                        AppType.display(26, color: t.ink2, letterSpacing: 10),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    filled: false,
                    isCollapsed: true,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
