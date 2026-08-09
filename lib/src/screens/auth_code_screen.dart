import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/auth_repository.dart';
import '../services/secure_screen.dart';
import '../theme/app_colors.dart';
import '../widgets/common/app_snack.dart';

/// Welcher Code-Flow laeuft: Passwort-Reset oder Registrierungs-Bestaetigung.
enum AuthCodeFlow { recovery, signup }

/// Eigene Seite fuer die 6-stelligen E-Mail-Codes (OTP statt Mail-Link).
///
///  * [AuthCodeFlow.recovery]: E-Mail eingeben -> Code anfordern -> Code
///    pruefen (verifyOTP recovery, stellt die Session her) -> neues Passwort
///    setzen. Die Versand-Bestaetigung bleibt NEUTRAL — ob zur Adresse ein
///    Konto existiert (oder ein reines Google-Konto), verraet die App nicht.
///  * [AuthCodeFlow.signup]: die Adresse steht fest (frisch registriert),
///    nur der Code wird geprueft; der AuthGate wechselt danach von selbst
///    auf die Home-Page (Session-Stream).
///
/// Die Codes sind serverseitig 10 Minuten gueltig (mailer_otp_exp).
class AuthCodeScreen extends StatefulWidget {
  const AuthCodeScreen({
    super.key,
    required this.authRepository,
    required this.flow,
    this.initialEmail = '',
  });

  final AuthRepository authRepository;
  final AuthCodeFlow flow;
  final String initialEmail;

  @override
  State<AuthCodeScreen> createState() => _AuthCodeScreenState();
}

/// Schritte des Recovery-Flows; Signup startet direkt beim Code.
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

  bool get _isRecovery => widget.flow == AuthCodeFlow.recovery;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
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
    final raw = error.toString().toLowerCase();
    if (raw.contains('expired') || raw.contains('invalid')) {
      return 'Der Code stimmt nicht oder ist abgelaufen. Fordere unten '
          'einfach einen neuen an.';
    }
    return 'Das hat gerade nicht geklappt. Bitte nochmal versuchen.';
  }

  Future<void> _sendCode() async {
    final email = _email.text.trim();
    if (!email.contains('@') || !email.contains('.')) {
      setState(() => _error = 'Bitte gib eine gültige E-Mail ein.');
      return;
    }
    await _run(() async {
      await widget.authRepository.sendPasswordReset(email);
      if (!mounted) return;
      setState(() {
        _step = _Step.code;
        _message = 'Falls ein Konto mit dieser E-Mail existiert, ist der '
            '6-stellige Code unterwegs. Er ist 10 Minuten gültig.';
      });
    });
  }

  Future<void> _resend() => _run(() async {
        if (_isRecovery) {
          await widget.authRepository.sendPasswordReset(_email.text);
        } else {
          await widget.authRepository.resendSignupCode(_email.text);
        }
        if (!mounted) return;
        setState(() => _message =
            'Neuer Code angefordert — er ist 10 Minuten gültig.');
      });

  Future<void> _verify() async {
    final code = _code.text.trim();
    if (code.length != 6) {
      setState(() => _error = 'Der Code hat 6 Ziffern.');
      return;
    }
    await _run(() async {
      if (_isRecovery) {
        await widget.authRepository
            .verifyRecoveryCode(email: _email.text, code: code);
        if (!mounted) return;
        setState(() => _step = _Step.password);
      } else {
        await widget.authRepository
            .verifySignupCode(email: _email.text, code: code);
        if (!mounted) return;
        // Session steht — der AuthGate unter dieser Route wechselt auf die
        // Home-Page, die Seite hat ihren Zweck erfuellt.
        Navigator.of(context).pop();
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
                    'Wir schicken dir einen 6-stelligen Code per E-Mail.',
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
                  enabled: !_busy,
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
              if (_error != null) ...[
                const SizedBox(height: 14),
                _Note(
                    noteKey: const ValueKey('code-error'),
                    text: _error!,
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
                onPressed: _busy
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
                    onTap: _busy ? null : _resend,
                    behavior: HitTestBehavior.opaque,
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Text(
                        'Keinen Code bekommen? Neuen anfordern',
                        style: TextStyle(
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

/// Rahmenlose Soft-Kapsel (Design-Vorgabe: keine Hairlines/Fokusringe,
/// Fokus = Flaechen-Aufhellung).
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
    this.trailing,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final bool enabled;
  final bool obscure;
  final TextInputType? keyboardType;
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

/// Grosse Code-Kapsel: 6 Ziffern, weit gesperrt, tabular — die Zahl ist der
/// Held der Seite.
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
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(6),
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
          hintText: '······',
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
