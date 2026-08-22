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
import '../theme/app_colors.dart';
import '../widgets/common/app_snack.dart';
import 'settings/account_change_messages.dart' show kAccountCodeLength;

/// Which code flow is running: password reset or signup confirmation.
enum AuthCodeFlow { recovery, signup }

/// Coarse classification of an auth error — enough for the three messages
/// this page shows.
enum _AuthErrorKind { rateLimited, codeRejected, unknown }

/// Order as in `settings/account_change_messages.dart`: rate limit first, then
/// the rejected code. GoTrue's throttle message must NOT fall into the catch-all
/// branch that invites a retry — that is the tap loop which drains the quota.
_AuthErrorKind _classifyAuthError(Object error) {
  final raw = error.toString().toLowerCase();
  if (raw.contains('rate limit') ||
      raw.contains('rate_limit') ||
      raw.contains('too many') ||
      raw.contains('for security purposes')) {
    return _AuthErrorKind.rateLimited;
  }
  if (raw.contains('expired') || raw.contains('invalid')) {
    return _AuthErrorKind.codeRejected;
  }
  return _AuthErrorKind.unknown;
}

/// Guard state for ONE address.
class _ThrottleState {
  const _ThrottleState({this.lastSent, this.failedAttempts = 0});

  final DateTime? lastSent;
  final int failedAttempts;
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

  static const Duration cooldown = Duration(seconds: 60);
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
      final stand = _ThrottleState(
        lastSent: gesendet is int
            ? DateTime.fromMillisecondsSinceEpoch(gesendet)
            : null,
        failedAttempts: fehl is int && fehl > 0 ? fehl : 0,
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
    return clock.now().difference(start) >= cooldown;
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

  /// The auth pages still await the i18n migration and existing tests pump
  /// them WITHOUT localization delegates, where `context.l10n` would throw —
  /// hence the same German default as in `sync_error_messages.dart`.
  AppLocalizations get _l10n =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ?? deL10n;

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
      _cooldownSeconds = 0;
    });
    _syncTicker();
    unawaited(_hydrate(ziel));
  }

  int _remainingSeconds() {
    final start = _lastSent;
    if (start == null) return 0;
    final rest = _OtpSendThrottle.cooldown - clock.now().difference(start);
    // `isNegative` clamps the low end; the high end needs the same clamp: a
    // remainder above the cooldown itself means a rewound device clock, not a
    // longer cooldown. Without it the user is stuck in a persistent self-DoS
    // ("next code in 86400 s") (W3b).
    if (rest.isNegative || rest > _OtpSendThrottle.cooldown) return 0;
    return (rest.inMilliseconds / 1000).ceil();
  }

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
    setState(() => _cooldownSeconds = rest);
    if (rest <= 0) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  /// Stamps a send. The guard applies IMMEDIATELY; persisting runs alongside
  /// and only makes it durable. [resetAttempts] is for real sends — a new code
  /// voids the old failed attempts.
  void _stamp(String email, {required bool resetAttempts}) {
    final jetzt = clock.now();
    final versuche = resetAttempts ? 0 : _failedAttempts;
    _guardTouched = true;
    unawaited(_throttle.write(
      email,
      _ThrottleState(lastSent: jetzt, failedAttempts: versuche),
    ));
    if (!mounted) return;
    setState(() {
      _guardFor = _normalisiert(email);
      _lastSent = jetzt;
      _failedAttempts = versuche;
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
      _ThrottleState(lastSent: _lastSent, failedAttempts: naechster),
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
    switch (_classifyAuthError(error)) {
      case _AuthErrorKind.rateLimited:
        return _l10n.authCodeRateLimited;
      case _AuthErrorKind.codeRejected:
        return 'Der Code stimmt nicht oder ist abgelaufen. Fordere unten '
            'einfach einen neuen an.';
      case _AuthErrorKind.unknown:
        return 'Das hat gerade nicht geklappt. Bitte nochmal versuchen.';
    }
  }

  /// Catches the server's throttle error and stamps the guard too, so the
  /// countdown shows when sending resumes instead of blind retries.
  Future<void> _sendGuarded(
    String email,
    Future<void> Function() versand,
  ) async {
    try {
      await versand();
    } catch (error) {
      if (_classifyAuthError(error) == _AuthErrorKind.rateLimited) {
        _stamp(email, resetAttempts: false);
      }
      rethrow;
    }
    _stamp(email, resetAttempts: true);
  }

  Future<void> _sendCode() async {
    final email = _email.text.trim();
    if (!email.contains('@') || !email.contains('.')) {
      setState(() => _error = 'Bitte gib eine gültige E-Mail ein.');
      return;
    }
    // The state for this address arrived while typing (_onEmailChanged); this
    // only reads what is already there — awaiting storage would stall the very
    // first send.
    final rest = _remainingSeconds();
    if (rest > 0) {
      setState(() => _error = _l10n.authCodeThrottleWait(rest));
      return;
    }
    await _run(() async {
      await _sendGuarded(
          email, () => widget.authRepository.sendPasswordReset(email));
      if (!mounted) return;
      setState(() {
        _step = _Step.code;
        _message = 'Falls ein Konto mit dieser E-Mail existiert, ist der '
            '8-stellige Code unterwegs. Er ist 10 Minuten gültig.';
      });
    });
  }

  Future<void> _resend() async {
    final email = _guardEmail;
    final rest = _remainingSeconds();
    if (rest > 0) {
      setState(() => _error = _l10n.authCodeThrottleWait(rest));
      return;
    }
    await _run(() async {
      await _sendGuarded(
        email,
        () => _isRecovery
            ? widget.authRepository.sendPasswordReset(email)
            : widget.authRepository.resendSignupCode(email),
      );
      if (!mounted) return;
      setState(() => _message =
          'Neuer Code angefordert — er ist 10 Minuten gültig.');
    });
  }

  Future<void> _verify() async {
    if (_locked) return;
    final code = _code.text.trim();
    if (code.length != kAccountCodeLength) {
      setState(() => _error = 'Der Code hat $kAccountCodeLength Ziffern.');
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
        if (_classifyAuthError(error) == _AuthErrorKind.codeRejected) {
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
    if (_password.text.length < 8) {
      setState(() => _error = 'Das Passwort braucht mindestens 8 Zeichen.');
      return;
    }
    await _run(() async {
      await widget.authRepository.updatePassword(_password.text);
      if (!mounted) return;
      Navigator.of(context).pop();
      showAppSnack(
        context,
        'Passwort aktualisiert. Du bist eingeloggt.',
        icon: Icons.lock_reset_rounded,
      );
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
    return SecureScreenGuard(
      child: Scaffold(
      key: const ValueKey('auth-code-screen'),
      backgroundColor: bg,
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          key: const ValueKey('auth-code-back'),
          onPressed: _busy ? null : () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_rounded, size: 20),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
              24, 8, 24, 24 + MediaQuery.viewInsetsOf(context).bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                switch (_step) {
                  _Step.email => 'Passwort zurücksetzen',
                  _Step.code => 'Code eingeben',
                  _Step.password => 'Neues Passwort',
                },
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.8,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                switch (_step) {
                  _Step.email =>
                    'Wir schicken dir einen 8-stelligen Code per E-Mail.',
                  _Step.code => _isRecovery
                      ? 'Gib den Code aus der E-Mail an ${_email.text.trim()} ein.'
                      : 'Bestätige deine E-Mail ${_email.text.trim()} mit dem '
                          'Code aus der Willkommens-Mail.',
                  _Step.password =>
                    'Der Code stimmt. Leg jetzt dein neues Passwort fest.',
                },
                style: const TextStyle(
                  color: textMuted,
                  fontSize: 13.5,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 26),
              if (_step == _Step.email) ...[
                _CapsuleField(
                  fieldKey: const ValueKey('code-email-field'),
                  controller: _email,
                  hint: 'du@beispiel.de',
                  icon: Icons.alternate_email_rounded,
                  enabled: !_busy,
                  keyboardType: TextInputType.emailAddress,
                  onSubmitted: _sendCode,
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
                _CapsuleField(
                  fieldKey: const ValueKey('code-password-field'),
                  controller: _password,
                  hint: 'Mind. 8 Zeichen',
                  icon: Icons.lock_outline_rounded,
                  enabled: !_busy,
                  autofillHints: const [AutofillHints.newPassword],
                  obscure: !_passwordVisible,
                  onSubmitted: _savePassword,
                  trailing: GestureDetector(
                    onTap: () =>
                        setState(() => _passwordVisible = !_passwordVisible),
                    child: Icon(
                      _passwordVisible
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                      size: 19,
                      color: textMuted,
                    ),
                  ),
                ),
              ],
              if (fehlerText != null) ...[
                const SizedBox(height: 14),
                _Note(
                    noteKey: const ValueKey('code-error'),
                    text: fehlerText,
                    color: danger),
              ],
              if (_message != null) ...[
                const SizedBox(height: 14),
                _Note(
                    noteKey: const ValueKey('code-message'),
                    text: _message!,
                    color: lime),
              ],
              const SizedBox(height: 22),
              FilledButton(
                key: const ValueKey('code-primary'),
                onPressed: _busy || gesperrt
                    ? null
                    : switch (_step) {
                        _Step.email => _sendCode,
                        _Step.code => _verify,
                        _Step.password => _savePassword,
                      },
                style: FilledButton.styleFrom(
                  backgroundColor: lime,
                  foregroundColor: bg,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(rControl),
                  ),
                ),
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: bg),
                      )
                    : Text(
                        switch (_step) {
                          _Step.email => 'Code anfordern',
                          _Step.code => 'Code prüfen',
                          _Step.password => 'Passwort speichern',
                        },
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 14),
                      ),
              ),
              if (_step == _Step.code) ...[
                const SizedBox(height: 12),
                Center(
                  child: GestureDetector(
                    key: const ValueKey('code-resend'),
                    // The tap stays enabled during the cooldown so _resend can
                    // say how long is left; a dead link would leave the user
                    // guessing.
                    onTap: _busy ? null : _resend,
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Text(
                        _cooldownSeconds > 0
                            ? _l10n.authCodeResendCountdown(_cooldownSeconds)
                            : 'Keinen Code bekommen? Neuen anfordern',
                        style: const TextStyle(
                          color: textMuted,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
    );
  }
}

/// Borderless soft capsule (design rule: no hairlines or focus rings, focus is
/// a surface lightening).
class _CapsuleField extends StatefulWidget {
  const _CapsuleField({
    required this.fieldKey,
    required this.controller,
    required this.hint,
    required this.icon,
    required this.enabled,
    required this.onSubmitted,
    this.obscure = false,
    this.keyboardType,
    this.autofillHints,
    this.trailing,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool enabled;
  final bool obscure;
  final TextInputType? keyboardType;
  final Iterable<String>? autofillHints;
  final Widget? trailing;
  final VoidCallback onSubmitted;

  @override
  State<_CapsuleField> createState() => _CapsuleFieldState();
}

class _CapsuleFieldState extends State<_CapsuleField> {
  final FocusNode _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focused != _focus.hasFocus) {
        setState(() => _focused = _focus.hasFocus);
      }
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      height: 52,
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          Colors.white.withValues(alpha: _focused ? 0.055 : 0.0),
          surfaceSoft,
        ),
        borderRadius: BorderRadius.circular(rControl),
      ),
      child: Row(
        children: [
          Icon(widget.icon, size: 18, color: _focused ? lime : textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              key: widget.fieldKey,
              controller: widget.controller,
              focusNode: _focus,
              enabled: widget.enabled,
              obscureText: widget.obscure,
              keyboardType: widget.keyboardType,
              autofillHints: widget.autofillHints,
              cursorColor: lime,
              onSubmitted: (_) => widget.onSubmitted(),
              style: const TextStyle(fontSize: 14.5),
              decoration: InputDecoration(
                hintText: widget.hint,
                hintStyle: const TextStyle(color: textMuted, fontSize: 14),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                filled: false,
                isCollapsed: true,
              ),
            ),
          ),
          if (widget.trailing != null) widget.trailing!,
        ],
      ),
    );
  }
}

/// Large code capsule: [kAccountCodeLength] digits, wide tracking, tabular.
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
    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: surfaceSoft,
        borderRadius: BorderRadius.circular(rCard),
      ),
      alignment: Alignment.center,
      child: TextField(
        key: fieldKey,
        controller: controller,
        enabled: enabled,
        autofocus: true,
        keyboardType: TextInputType.number,
        // Without this hint the password manager never offers the code.
        autofillHints: const [AutofillHints.oneTimeCode],
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(kAccountCodeLength),
        ],
        textAlign: TextAlign.center,
        cursorColor: lime,
        onSubmitted: (_) => onSubmitted(),
        style: const TextStyle(
          fontSize: 26,
          fontWeight: FontWeight.w800,
          letterSpacing: 10,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
        decoration: const InputDecoration(
          hintText: '········',
          hintStyle: TextStyle(color: textMuted, letterSpacing: 10),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          filled: false,
          isCollapsed: true,
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.noteKey, required this.text, required this.color});

  final Key noteKey;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: noteKey,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(rControl),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 12.5, height: 1.4),
      ),
    );
  }
}
