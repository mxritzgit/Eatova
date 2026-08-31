import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/auth_repository.dart';
import '../l10n/l10n.dart';
import '../services/local_cache.dart'
    show KeyValueStore, SharedPreferencesStore;
import '../services/secure_screen.dart';
import '../theme/app_tokens.dart';
import '../widgets/auth/auth_controls.dart';
import '../widgets/common/app_snack.dart';
import '../widgets/design/controls.dart';
import '../widgets/design/sheets.dart';
import 'settings/account_change_messages.dart'
    show
        AuthErrorBefund,
        AuthErrorKind,
        classifyAuthError,
        kAccountCodeLength,
        kAccountMinPasswordLength;

/// Which code flow is running: password reset or signup confirmation.
enum AuthCodeFlow { recovery, signup }

/// Above this many seconds the wait is spoken in minutes — a half-hour quota
/// block would otherwise read "in 1800 s".
const int _minutenSchwelleSekunden = 120;

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
  /// would hand out a fresh escape every time.
  ///
  /// It is bound to the ADDRESS like everything else here, and
  /// `rate_limit_email_sent` is NOT: that quota is PROJECT-wide. So typing a
  /// second address does yield a second escape against the same server bucket.
  /// That is a known property of the address binding, not something this flag
  /// closes — a guard keyed on one address cannot see a project-wide bucket,
  /// and the class comment on [_OtpSendThrottle] says why that is acceptable:
  /// this is a benign-case brake, the real limit is the server's (see
  /// supabase/AUTH_EMAIL_OTP.md).
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

  /// The escape shows while a GUESSED lock runs — in both steps that can walk
  /// into one, under the same rule (P4-03b).
  bool get _auswegSichtbar => _cooldownSeconds > 0 && _sperreIstSchaetzung;

  AppLocalizations get _l10n => context.l10n;

  /// The escape out of a GUESSED lock, traded for a sentence once spent — a
  /// dimmed dead link would say less. [onTap] is the send belonging to the
  /// current step; the rule around it is identical either way.
  Widget _ausweg(
    AppLocalizations l10n,
    AppTokens t, {
    required VoidCallback onTap,
  }) {
    return Center(
      child: _bypassUsed
          ? Padding(
              key: const ValueKey('code-send-anyway-used'),
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                l10n.authCodeSendAnywayUsed,
                textAlign: TextAlign.center,
                style: AppType.ui(12, color: t.ink2, height: 1.4),
              ),
            )
          : AuthTextLink(
              linkKey: const ValueKey('code-send-anyway'),
              label: l10n.authCodeSendAnyway,
              emphasis: true,
              onTap: _busy ? null : onTap,
            ),
    );
  }

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

  /// Marks the escape out of the current lock as spent WITHOUT touching that
  /// lock: stamp, duration and failure counter stay exactly as they are, only
  /// [_ThrottleState.bypassUsed] flips (P4-03b, hole 1).
  ///
  /// Restamping instead would push the lock's end 30 minutes into the future
  /// every time the escape hits a server error — punishing the user for the
  /// server's fault. The escape is a TRY, not a promise: it is spent because it
  /// went out, and the wait it was trying to skip is unchanged by that.
  void _markBypassUsed(String email) {
    if (_bypassUsed) return;
    _guardTouched = true;
    unawaited(_throttle.write(
      email,
      _ThrottleState(
        lastSent: _lastSent,
        failedAttempts: _failedAttempts,
        cooldown: _cooldownDauer,
        bypassUsed: true,
      ),
    ));
    if (!mounted) return;
    setState(() => _bypassUsed = true);
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
    final befund = classifyAuthError(error);
    switch (befund.kind) {
      case AuthErrorKind.unavailable:
        return _l10n.authErrorUnavailable;
      case AuthErrorKind.offline:
        return _l10n.authCodeOfflineError;
      case AuthErrorKind.serverFault:
        // gotrue reports EVERY 5xx as AuthRetryableFetchException, the same
        // type a dead radio cell produces. Sent as "offline" it told the user
        // to check a connection that was demonstrably fine — the server had
        // answered.
        return _l10n.authErrorServerFault;
      case AuthErrorKind.sendThrottled:
        // The number the guard really holds — not the server's raw one, which
        // can be below our own floor. Seconds or minutes by the SAME threshold
        // as the countdown link (P4-03c): a 180 s lock used to read "noch 180 s
        // gesperrt" right above "Neuen Code in 3 min anfordern".
        return _drosselHinweis(_sperrDauer(befund).inSeconds);
      case AuthErrorKind.quotaExhausted:
        return _l10n.authCodeQuotaExhausted;
      case AuthErrorKind.rateLimited:
        return _l10n.authCodeRateLimited;
      case AuthErrorKind.emailInvalid:
        // Reachable on the ADDRESS step: our own check is shape-only, GoTrue's
        // is stricter.
        return _l10n.authErrorInvalidEmail;
      case AuthErrorKind.passwordSameAsOld:
        return _l10n.settingsAccountPasswordSameAsOld;
      case AuthErrorKind.passwordWeak:
        return _l10n.settingsAccountPasswordWeak;
      case AuthErrorKind.codeRejected:
        return _l10n.authCodeErrorRejected;
      // Naming a taken address here would confirm account existence to whoever
      // typed it (house rule against enumeration), so it stays generic.
      case AuthErrorKind.emailTaken:
      case AuthErrorKind.unknown:
        return _l10n.authErrorGeneric;
    }
  }

  /// How long a rejected send blocks the next one — `Duration.zero` when the
  /// error says nothing about sending.
  ///
  /// [_OtpSendThrottle.cooldown] stays the floor: a server wait BELOW it must
  /// not weaken our own abuse brake, and the message quotes exactly the value
  /// used here, so hint and countdown can never disagree.
  Duration _sperrDauer(AuthErrorBefund befund) {
    switch (befund.kind) {
      case AuthErrorKind.quotaExhausted:
        return _OtpSendThrottle.quotaCooldown;
      case AuthErrorKind.sendThrottled:
        final genannt = befund.retryAfter ?? Duration.zero;
        return genannt > _OtpSendThrottle.cooldown
            ? genannt
            : _OtpSendThrottle.cooldown;
      case AuthErrorKind.rateLimited:
        return _OtpSendThrottle.cooldown;
      // A 5xx says nothing about sending: locking the button for it would
      // punish the user for a server outage.
      case AuthErrorKind.serverFault:
      case AuthErrorKind.unavailable:
      case AuthErrorKind.offline:
      case AuthErrorKind.emailTaken:
      case AuthErrorKind.emailInvalid:
      case AuthErrorKind.passwordSameAsOld:
      case AuthErrorKind.passwordWeak:
      case AuthErrorKind.codeRejected:
      case AuthErrorKind.unknown:
        return Duration.zero;
    }
  }

  /// Catches the server's throttle error and stamps the guard with the wait it
  /// really implies, so the countdown shows when sending resumes instead of
  /// inviting blind retries.
  ///
  /// [trotzdem] marks this call as the one escape out of the running lock. It
  /// is spent the moment the request LEAVES, whatever comes back.
  Future<void> _sendGuarded(
    String email,
    Future<void> Function() versand, {
    bool trotzdem = false,
  }) async {
    try {
      await versand();
    } catch (error) {
      final sperre = _sperrDauer(classifyAuthError(error));
      if (sperre > Duration.zero) {
        // [trotzdem] carries into the new stamp: the escape is one per lock,
        // and a failed escape must not hand out the next one.
        _stamp(
          email,
          resetAttempts: false,
          cooldown: sperre,
          bypassUsed: trotzdem,
        );
      } else if (trotzdem) {
        // ...and the same holds when the answer implies NO wait at all: a 500,
        // an `unexpected_failure`, a dead radio cell. Stamping only on
        // throttle-shaped errors left `bypassUsed` false, so the link came back
        // and every tap was another real request during the running lock — six
        // measured in one 30-minute block (hole 1). The escape is a try, not a
        // success promise; it is used up because it went out.
        _markBypassUsed(email);
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

  /// [trotzdem] is the escape described on [_resend] — same rule, same one
  /// shot, only from the ADDRESS step, where a first send can run straight into
  /// the quota and there is no resend link yet (P4-03b, hole 2).
  Future<void> _sendCode({bool trotzdem = false}) async {
    final email = _email.text.trim();
    if (!email.contains('@') || !email.contains('.')) {
      setState(() => _error = _l10n.authErrorInvalidEmail);
      return;
    }
    // The state for this address arrived while typing (_onEmailChanged); this
    // only reads what is already there — awaiting storage would stall the very
    // first send.
    final rest = _remainingSeconds();
    if (rest > 0 && !trotzdem) {
      setState(() => _error = _wartehinweis(rest));
      return;
    }
    await _run(() async {
      await _sendGuarded(
        email,
        () => widget.authRepository.sendPasswordReset(email),
        trotzdem: trotzdem,
      );
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
  /// whether the next mail goes out.
  ///
  /// One escape per lock, and it is spent as soon as it goes out — a throttle
  /// answer, a 500 and a dead radio cell all consume it alike. Only a send that
  /// really produced a mail lifts the lock and gives the next one back.
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
        trotzdem: trotzdem,
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
        if (classifyAuthError(error).kind == AuthErrorKind.codeRejected) {
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
                  // The ADDRESS step needs the escape too (P4-03b, hole 2):
                  // when the very FIRST send runs into the quota, the screen
                  // never reaches the code step, so there is no resend link
                  // and — before this — no way out at all for half an hour.
                  if (_step == _Step.email && _auswegSichtbar) ...[
                    const SizedBox(height: 12),
                    _ausweg(
                      l10n,
                      t,
                      onTap: () => _sendCode(trotzdem: true),
                    ),
                  ],
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
                    if (_auswegSichtbar)
                      _ausweg(
                        l10n,
                        t,
                        onTap: () => _resend(trotzdem: true),
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
