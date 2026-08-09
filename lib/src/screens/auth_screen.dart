import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth/auth_repository.dart';
import '../config/legal_links.dart';
import '../services/secure_screen.dart';
import 'auth_code_screen.dart';
import '../theme/app_colors.dart';
import '../widgets/shared/eatova_wordmark.dart';

/// Eatova Auth - ruhiger, immersiver Dark-Screen.
///
/// Bewusst minimal: tiefes Schwarz mit einer einzigen weichen Lime-Aurora,
/// kompakter Brand-Mark, große Headline und Google-OAuth als prominente
/// Primär-Aktion. Darunter cleane E-Mail-Felder und ein Lime-CTA; der
/// Login/Registrieren-Wechsel sitzt als dezenter Text-Toggle ganz unten.
/// Single-Screen; die Auth-Logik (Validierung, OAuth, Fehler-Mapping)
/// ist unverändert.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.authRepository});

  final AuthRepository authRepository;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

const _dim = Color(0xFF5A5B63);
const _ink = bg; // Text/Glyph auf Lime

class _AuthScreenState extends State<AuthScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isRegister = false;
  bool _loading = false;
  bool _passwordVisible = false;
  EatovaOAuthProvider? _oauthLoading;
  String? _message;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  bool get _busy => _loading || _oauthLoading != null;

  Future<void> _startOAuth(EatovaOAuthProvider provider) async {
    setState(() {
      _error = null;
      _message = null;
      _oauthLoading = provider;
    });
    try {
      await widget.authRepository.signInWithOAuth(provider);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _oauthLoading = null);
    }
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final name = _nameController.text.trim();

    setState(() {
      _error = null;
      _message = null;
    });

    if (!email.contains('@') || !email.contains('.')) {
      setState(() => _error = 'Bitte gib eine gültige E-Mail ein.');
      return;
    }
    if (password.length < 8) {
      setState(() => _error = 'Das Passwort braucht mindestens 8 Zeichen.');
      return;
    }
    if (_isRegister && name.length < 2) {
      setState(() => _error = 'Wie dürfen wir dich nennen?');
      return;
    }

    setState(() => _loading = true);
    try {
      if (_isRegister) {
        await widget.authRepository.signUp(
          email: email,
          password: password,
          displayName: name,
        );
        if (!mounted) return;
        setState(
          () => _message =
              'Bestätigungs-Code unterwegs an $email (10 Minuten gültig).',
        );
        // Direkt zur Code-Eingabe: die Bestaetigung laeuft ueber den
        // 6-stelligen Code aus der Mail, nicht mehr ueber einen Link.
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => AuthCodeScreen(
            authRepository: widget.authRepository,
            flow: AuthCodeFlow.signup,
            initialEmail: email,
          ),
        ));
      } else {
        await widget.authRepository.signIn(email: email, password: password);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Eigene Seite fuer den Code-Flow (6-stelliger OTP statt Mail-Link):
  /// E-Mail wird vorbefuellt, eingeben/aendern passiert dort.
  void _forgotPassword() {
    setState(() {
      _error = null;
      _message = null;
    });
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AuthCodeScreen(
        authRepository: widget.authRepository,
        flow: AuthCodeFlow.recovery,
        initialEmail: _emailController.text.trim(),
      ),
    ));
  }

  String _friendlyError(Object error) {
    final raw = error.toString().toLowerCase();
    if (raw.contains('invalid login') || raw.contains('invalid credentials')) {
      return 'E-Mail oder Passwort stimmt nicht.';
    }
    if (raw.contains('already registered') || raw.contains('already exists')) {
      return 'Diese E-Mail ist schon registriert. Versuch Login.';
    }
    if (raw.contains('email not confirmed')) {
      return 'Bitte bestätige zuerst deine E-Mail.';
    }
    if (raw.contains('provider') && raw.contains('enabled')) {
      return 'Dieser Login-Anbieter ist in Supabase noch nicht aktiviert.';
    }
    if (raw.contains('redirect') || raw.contains('callback')) {
      return 'OAuth Redirect ist noch nicht korrekt eingetragen.';
    }
    // 'cancel' faengt englische SDK-Fehler, 'abgebrochen' unsere eigenen
    // deutschen AuthExceptions (z. B. Google-Abbruch im nativen Flow) -
    // sonst landet ein simpler User-Abbruch in der Generik-Meldung.
    if (raw.contains('cancel') || raw.contains('abgebrochen')) {
      return 'Login wurde abgebrochen.';
    }
    return 'Das hat gerade nicht geklappt. Bitte nochmal versuchen.';
  }

  void _setMode(bool register) {
    if (register == _isRegister) return;
    setState(() {
      _isRegister = register;
      _error = null;
      _message = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.viewInsetsOf(context).bottom;

    return SecureScreenGuard(
      child: Scaffold(
      key: const ValueKey('screen-auth'),
      backgroundColor: bg,
      body: Stack(
        children: [
          const Positioned.fill(child: _AuroraBackdrop()),
          SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 28 + insets),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 420),
                curve: Curves.easeOutCubic,
                // Statischer Auftritt: die frühere Opacity/Transform-Animation
                // ließ den unteren Bildschirmteil im ersten Frame ungemalt
                // (NEEDS-PAINT) → der Mode-Toggle war im Test nicht hit-testbar.
                builder: (context, t, child) => child!,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 8),
                    const _BrandMark(),
                    const SizedBox(height: 16),
                    _Hero(isRegister: _isRegister),
                    const SizedBox(height: 18),
                    _GoogleButton(
                      enabled: !_busy,
                      loading: _oauthLoading == EatovaOAuthProvider.google,
                      onTap: () => _startOAuth(EatovaOAuthProvider.google),
                    ),
                    const SizedBox(height: 14),
                    const _OrDivider(),
                    const SizedBox(height: 14),
                    _EmailForm(
                      isRegister: _isRegister,
                      loading: _loading,
                      busy: _busy,
                      passwordVisible: _passwordVisible,
                      nameController: _nameController,
                      emailController: _emailController,
                      passwordController: _passwordController,
                      error: _error,
                      message: _message,
                      onTogglePassword: () =>
                          setState(() => _passwordVisible = !_passwordVisible),
                      onSubmit: _submit,
                      onForgotPassword: _forgotPassword,
                    ),
                    const SizedBox(height: 14),
                    _ModeToggle(
                      isRegister: _isRegister,
                      onTap: _busy ? null : () => _setMode(!_isRegister),
                    ),
                    const SizedBox(height: 16),
                    const _ConsentNotice(),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Aurora-Hintergrund - eine weiche Lime-Lichtquelle oben, sonst ruhig.
// ═════════════════════════════════════════════════════════════════════

class _AuroraBackdrop extends StatelessWidget {
  const _AuroraBackdrop();

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.0, -1.15),
            radius: 1.05,
            colors: [Color(0x2BB6F36A), Color(0x00B6F36A)],
            stops: [0.0, 1.0],
          ),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Brand-Mark - Eatova-Wortmarke mit Fokusring-o (Logo 2026-08).
// ═════════════════════════════════════════════════════════════════════

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    return const Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [EatovaWordmark(fontSize: 26)],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Hero - Eyebrow + große Headline + ruhige Subline.
// ═════════════════════════════════════════════════════════════════════

class _Hero extends StatelessWidget {
  const _Hero({required this.isRegister});

  final bool isRegister;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('auth-hero'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isRegister ? 'KONTO ERSTELLEN' : 'WILLKOMMEN ZURÜCK',
          style: const TextStyle(
            fontSize: 11,
            letterSpacing: 1.2,
            fontWeight: FontWeight.w600,
            color: lime,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          isRegister ? 'Starte deine\nReise.' : 'Schön,\ndich zu sehen.',
          style: const TextStyle(
            fontSize: 30,
            height: 1.08,
            letterSpacing: -1.0,
            fontWeight: FontWeight.w700,
            color: textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          isRegister
              ? 'Erstell dein Konto und richte in einer Minute dein Tagesziel ein.'
              : 'Melde dich an und mach genau da weiter, wo du aufgehört hast.',
          style: const TextStyle(
            color: textMuted,
            fontSize: 15,
            height: 1.45,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Google-Button - weiße, prominente Primär-Aktion (OAuth).
// ═════════════════════════════════════════════════════════════════════

class _GoogleButton extends StatelessWidget {
  const _GoogleButton({
    required this.enabled,
    required this.loading,
    required this.onTap,
  });

  final bool enabled;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('auth-google-oauth'),
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 160),
        opacity: enabled ? 1 : 0.55,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(rPill),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 20,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: loading
                    ? const CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: _ink,
                      )
                    : const CustomPaint(painter: _GoogleGPainter()),
              ),
              const SizedBox(width: 12),
              // Flexible + ellipsis: bei 200%-Systemschrift (textScale-Cap
              // 2.0) sprengt das Label sonst die Button-Breite.
              const Flexible(
                child: Text(
                  'Mit Google anmelden',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1A1C1E),
                    letterSpacing: -0.1,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GoogleGPainter extends CustomPainter {
  const _GoogleGPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2 - 1;
    const stroke = 2.8;

    void arc(double startDeg, double sweepDeg, Color color) {
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = color;
      canvas.drawArc(
        Rect.fromCircle(center: Offset(cx, cy), radius: r),
        startDeg * math.pi / 180,
        sweepDeg * math.pi / 180,
        false,
        p,
      );
    }

    arc(-90, 90, const Color(0xFF4285F4));
    arc(0, 90, const Color(0xFF34A853));
    arc(90, 90, const Color(0xFFFBBC05));
    arc(180, 90, const Color(0xFFEA4335));

    final p = Paint()..color = const Color(0xFF4285F4);
    canvas.drawRect(Rect.fromLTWH(cx, cy - 1.4, r, 2.8), p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ═════════════════════════════════════════════════════════════════════
// ODER-Divider
// ═════════════════════════════════════════════════════════════════════

class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(child: Divider(color: hairline, height: 1)),
        const SizedBox(width: 12),
        // Flexible + ellipsis: bei grosser Systemschrift darf der Text die
        // Divider-Zeile nicht sprengen.
        Flexible(
          child: Text(
            'oder mit E-Mail',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: textMuted.withValues(alpha: 0.85),
              letterSpacing: 0.2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(child: Divider(color: hairline, height: 1)),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// E-Mail-Form
// ═════════════════════════════════════════════════════════════════════

class _EmailForm extends StatelessWidget {
  const _EmailForm({
    required this.isRegister,
    required this.loading,
    required this.busy,
    required this.passwordVisible,
    required this.nameController,
    required this.emailController,
    required this.passwordController,
    required this.error,
    required this.message,
    required this.onTogglePassword,
    required this.onSubmit,
    required this.onForgotPassword,
  });

  final bool isRegister;
  final bool loading;
  final bool busy;
  final bool passwordVisible;
  final TextEditingController nameController;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final String? error;
  final String? message;
  final VoidCallback onTogglePassword;
  final VoidCallback onSubmit;
  final VoidCallback onForgotPassword;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('auth-email-card'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: isRegister
              ? Padding(
                  key: const ValueKey('name-field-wrap'),
                  padding: const EdgeInsets.only(bottom: 14),
                  child: _AuthField(
                    fieldKey: const ValueKey('auth-name-field'),
                    icon: Icons.person_outline_rounded,
                    label: 'Name',
                    hint: 'Dein Name',
                    controller: nameController,
                    enabled: !busy,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.name],
                  ),
                )
              : const SizedBox.shrink(key: ValueKey('no-name-field')),
        ),
        _AuthField(
          fieldKey: const ValueKey('auth-email-field'),
          icon: Icons.alternate_email_rounded,
          label: 'E-Mail',
          hint: 'du@beispiel.de',
          controller: emailController,
          enabled: !busy,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.email],
        ),
        const SizedBox(height: 14),
        _AuthField(
          fieldKey: const ValueKey('auth-password-field'),
          icon: Icons.lock_outline_rounded,
          label: 'Passwort',
          hint: 'Mind. 8 Zeichen',
          controller: passwordController,
          enabled: !busy,
          obscure: !passwordVisible,
          textInputAction: TextInputAction.done,
          autofillHints: isRegister
              ? const [AutofillHints.newPassword]
              : const [AutofillHints.password],
          onSubmitted: (_) => busy ? null : onSubmit(),
          trailing: GestureDetector(
            key: const ValueKey('auth-toggle-password'),
            onTap: busy ? null : onTogglePassword,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Icon(
                passwordVisible
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                size: 19,
                color: textMuted,
              ),
            ),
          ),
        ),
        if (!isRegister) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              key: const ValueKey('auth-forgot-password'),
              onTap: busy ? null : onForgotPassword,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                child: Text(
                  'Passwort vergessen?',
                  style: TextStyle(
                    color: textMuted,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.underline,
                    decorationColor: textMuted.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ),
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: 14),
          _InlineNote(text: error!, isError: true),
        ],
        if (message != null) ...[
          const SizedBox(height: 14),
          _InlineNote(text: message!, isError: false),
        ],
        const SizedBox(height: 22),
        _PrimaryCta(
          buttonKey: const ValueKey('auth-submit'),
          label: isRegister ? 'Account erstellen' : 'Einloggen',
          loading: loading,
          enabled: !busy,
          onTap: onSubmit,
        ),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Auth-Field - Label oben, gefülltes Feld mit Leading-Icon, Lime-Fokus.
// ═════════════════════════════════════════════════════════════════════

class _AuthField extends StatefulWidget {
  const _AuthField({
    required this.fieldKey,
    required this.icon,
    required this.label,
    required this.hint,
    required this.controller,
    this.enabled = true,
    this.obscure = false,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.onSubmitted,
    this.trailing,
  });

  final Key fieldKey;
  final IconData icon;
  final String label;
  final String hint;
  final TextEditingController controller;
  final bool enabled;
  final bool obscure;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final ValueChanged<String>? onSubmitted;
  final Widget? trailing;

  @override
  State<_AuthField> createState() => _AuthFieldState();
}

class _AuthFieldState extends State<_AuthField> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _focus.hasFocus;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            letterSpacing: 1.2,
            color: textMuted,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: surfaceSoft,
            borderRadius: BorderRadius.circular(rControl),
            border: Border.all(
              color: focused ? lime : hairline,
              width: focused ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 19, color: focused ? lime : textMuted),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  key: widget.fieldKey,
                  cursorOpacityAnimates: false,
                  controller: widget.controller,
                  focusNode: _focus,
                  enabled: widget.enabled,
                  obscureText: widget.obscure,
                  keyboardType: widget.keyboardType,
                  textInputAction: widget.textInputAction,
                  autofillHints: widget.autofillHints,
                  onSubmitted: widget.onSubmitted,
                  cursorColor: lime,
                  cursorWidth: 1.6,
                  style: const TextStyle(
                    fontSize: 15.5,
                    color: textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                  decoration: InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    contentPadding: const EdgeInsets.symmetric(vertical: 16),
                    hintText: widget.hint,
                    hintStyle: const TextStyle(
                      fontSize: 15.5,
                      color: _dim,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ),
              if (widget.trailing != null) widget.trailing!,
            ],
          ),
        ),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Primär-CTA - Lime-Pill (E-Mail-Login/Registrieren).
// ═════════════════════════════════════════════════════════════════════

class _PrimaryCta extends StatelessWidget {
  const _PrimaryCta({
    required this.buttonKey,
    required this.label,
    required this.loading,
    required this.enabled,
    required this.onTap,
  });

  final Key buttonKey;
  final String label;
  final bool loading;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = !enabled;
    return GestureDetector(
      key: buttonKey,
      onTap: disabled ? null : onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 17),
        decoration: BoxDecoration(
          color: disabled ? surfaceSoft : lime,
          borderRadius: BorderRadius.circular(rPill),
          boxShadow: disabled
              ? null
              : [
                  BoxShadow(
                    color: lime.withValues(alpha: 0.30),
                    blurRadius: 22,
                    offset: const Offset(0, 8),
                  ),
                ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2.2, color: _ink),
              )
            else ...[
              // Flexible + ellipsis: bei 200%-Systemschrift bleibt der
              // Pfeil sichtbar statt die Zeile zu sprengen.
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: disabled ? textMuted : _ink,
                    letterSpacing: -0.1,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_forward_rounded,
                size: 18,
                color: disabled ? textMuted : _ink,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Mode-Toggle - dezenter Text-Wechsel Login/Registrieren.
// ═════════════════════════════════════════════════════════════════════

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.isRegister, required this.onTap});

  final bool isRegister;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: ValueKey(isRegister ? 'auth-toggle-login' : 'auth-toggle-register'),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        // Wrap statt Row: bei 200%-Systemschrift brechen die beiden Texte
        // untereinander um, statt rechts aus dem Screen zu laufen — beide
        // bleiben vollstaendig lesbar (WCAG 1.4.4).
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          children: [
            Text(
              isRegister ? 'Schon dabei?' : 'Noch kein Konto?',
              style: const TextStyle(
                color: textMuted,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            Text(
              isRegister ? 'Einloggen' : 'Registrieren',
              style: const TextStyle(
                color: lime,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Inline-Note - Fehler (danger) / Bestätigung (lime).
// ═════════════════════════════════════════════════════════════════════

class _InlineNote extends StatelessWidget {
  const _InlineNote({required this.text, required this.isError});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError ? danger : lime;
    return Container(
      key: ValueKey(isError ? 'auth-error' : 'auth-message'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(rControl),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError
                ? Icons.error_outline_rounded
                : Icons.check_circle_outline_rounded,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: color,
                fontSize: 12.5,
                height: 1.4,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Rechts-Hinweis + tappbare Links auf AGB und Datenschutzerklärung
/// (DSGVO Art. 13 / App-Store); beide liegen auf eatova.de.
class _ConsentNotice extends StatelessWidget {
  const _ConsentNotice();

  static Future<void> _open(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  TextSpan _link(String text, String url) {
    return TextSpan(
      text: text,
      style: const TextStyle(color: forgeLime, fontWeight: FontWeight.w700),
      recognizer: TapGestureRecognizer()..onTap = () => _open(url),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text.rich(
        key: const ValueKey('auth-consent-notice'),
        TextSpan(
          style: const TextStyle(
            color: textMuted,
            fontSize: 11.5,
            height: 1.4,
            fontWeight: FontWeight.w500,
          ),
          children: [
            const TextSpan(text: 'Mit der Anmeldung akzeptierst du unsere '),
            _link('AGB', kTermsUrl),
            const TextSpan(
              text:
                  ' und stimmst der Verarbeitung deiner Gesundheits- und '
                  'Ernährungsdaten gemäß der ',
            ),
            _link('Datenschutzerklärung', kPrivacyUrl),
            const TextSpan(text: ' zu.'),
          ],
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}
