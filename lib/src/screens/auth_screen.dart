import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;
import 'package:url_launcher/url_launcher.dart';

import '../auth/auth_repository.dart';
import '../config/legal_links.dart';
import '../l10n/l10n.dart';
import '../services/secure_screen.dart';
import '../services/sync_error_messages.dart' show isNetworkSyncError;
import '../theme/app_tokens.dart';
import '../widgets/auth/auth_controls.dart';
import '../widgets/common/app_snack.dart';
import '../widgets/common/motion.dart';
import '../widgets/shared/eatova_wordmark.dart';
import 'auth_code_screen.dart';
import 'settings/account_change_messages.dart' show kAccountMinPasswordLength;

/// Eatova auth: one calm single screen that follows the display mode.
///
/// Soft accent aurora at the top, compact brand mark, large headline, Google
/// OAuth as the primary action, borderless e-mail fields and the primary CTA
/// below, the login/register switch as a quiet text toggle at the bottom.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.authRepository});

  final AuthRepository authRepository;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

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

  /// Address whose login failed with "e-mail not confirmed": the error note
  /// then offers the signup code page instead of ending in a dead end.
  String? _unconfirmedEmail;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  bool get _busy => _loading || _oauthLoading != null;

  void _clearNotes() {
    _error = null;
    _message = null;
    _unconfirmedEmail = null;
  }

  Future<void> _startOAuth(EatovaOAuthProvider provider) async {
    // Double-tap latch here AND on the button (`enabled`): the button lock
    // only takes effect with the next frame.
    if (_busy) return;
    setState(() {
      _clearNotes();
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
    // Latch as in [_startOAuth]: `_busy` flips now, the CTA only next frame.
    if (_busy) return;
    final l10n = context.l10n;
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final name = _nameController.text.trim();

    setState(_clearNotes);

    if (!email.contains('@') || !email.contains('.')) {
      setState(() => _error = l10n.authErrorInvalidEmail);
      return;
    }
    if (password.length < kAccountMinPasswordLength) {
      setState(() => _error =
          l10n.authErrorPasswordTooShort(kAccountMinPasswordLength));
      return;
    }
    if (_isRegister && name.length < 2) {
      setState(() => _error = l10n.authErrorNameMissing);
      return;
    }

    setState(() => _loading = true);
    try {
      if (_isRegister) {
        final ergebnis = await widget.authRepository.signUp(
          email: email,
          password: password,
          displayName: name,
        );
        if (!mounted) return;
        if (ergebnis == SignUpOutcome.emailAlreadyRegistered) {
          _zeigeNeutralenLoginHinweis();
          return;
        }
        // Lets the password manager store the new credentials.
        TextInput.finishAutofillContext();
        setState(() => _message = l10n.authSignupCodeSent(email));
        // Straight to code entry: confirmation runs through the 8-digit code
        // from the mail, no longer a link.
        await _openSignupCode(email);
      } else {
        await widget.authRepository.signIn(email: email, password: password);
        TextInput.finishAutofillContext();
      }
    } catch (error) {
      if (!mounted) return;
      if (_isRegister && _isExistingAccount(error)) {
        _zeigeNeutralenLoginHinweis();
      } else {
        setState(() {
          _error = _friendlyError(error);
          if (_isEmailNotConfirmed(error)) _unconfirmedEmail = email;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openSignupCode(String email) {
    return Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AuthCodeScreen(
        authRepository: widget.authRepository,
        flow: AuthCodeFlow.signup,
        initialEmail: email,
      ),
    ));
  }

  /// Answer to "this address already has an account", in both shapes GoTrue
  /// reports it: silently as [SignUpOutcome.emailAlreadyRegistered] (empty
  /// `identities`, no mail sent) and loudly as an `AuthException`
  /// ([_isExistingAccount]). Both end here because the code page is a dead end
  /// without a mail. The wording stays NEUTRAL — it never confirms whether the
  /// account exists (house rule against account enumeration).
  void _zeigeNeutralenLoginHinweis() {
    setState(() {
      _isRegister = false;
      _message = context.l10n.authSignupExistingAccountHint;
    });
  }

  bool _isExistingAccount(Object error) {
    final raw = error.toString().toLowerCase();
    return raw.contains('already registered') || raw.contains('already exists');
  }

  /// GoTrue code first, then its known sentence — never a localized text.
  static bool _matches(Object error, String code, String sentence) {
    if (error is AuthException && error.code == code) return true;
    return error.toString().toLowerCase().contains(sentence);
  }

  bool _isEmailNotConfirmed(Object error) =>
      _matches(error, 'email_not_confirmed', 'email not confirmed');

  /// Opens the code flow page (8-digit OTP instead of a mail link) with the
  /// email prefilled; entering/changing it happens there.
  void _forgotPassword() {
    setState(_clearNotes);
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => AuthCodeScreen(
        authRepository: widget.authRepository,
        flow: AuthCodeFlow.recovery,
        initialEmail: _emailController.text.trim(),
      ),
    ));
  }

  String _friendlyError(Object error) {
    final l10n = context.l10n;
    if (error is AuthCancelledException) return l10n.authErrorCancelled;
    if (error is AuthUnavailableException) return l10n.authErrorUnavailable;
    // Same TYPED branch and same position as `auth_code_screen.dart` (P4-02b):
    // offline there is no server text to classify, so a dead radio cell used to
    // fall through to `authErrorGeneric` and let the user suspect their
    // password. A 429 arrives as an AuthApiException, so no throttle is
    // swallowed here.
    if (isNetworkSyncError(error)) return l10n.authCodeOfflineError;
    if (_matches(error, 'invalid_credentials', 'invalid login') ||
        _matches(error, 'invalid_credentials', 'invalid credentials')) {
      return l10n.authErrorInvalidCredentials;
    }
    // No branch for 'already registered': that case belongs to
    // [_isExistingAccount] and is answered neutrally there — naming it would
    // confirm account existence to a stranger.
    if (_isEmailNotConfirmed(error)) return l10n.authErrorEmailNotConfirmed;
    final raw = error.toString().toLowerCase();
    if (raw.contains('provider') && raw.contains('enabled')) {
      return l10n.authErrorProviderDisabled;
    }
    if (raw.contains('redirect') || raw.contains('callback')) {
      return l10n.authErrorRedirect;
    }
    // Our own cancellations are typed (above); 'cancel' only catches the
    // English SDK/platform errors of the browser sheet.
    if (raw.contains('cancel')) return l10n.authErrorCancelled;
    return l10n.authErrorGeneric;
  }

  void _setMode(bool register) {
    if (register == _isRegister) return;
    setState(() {
      _isRegister = register;
      _clearNotes();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    final unconfirmed = _unconfirmedEmail;

    return SecureScreenGuard(
      child: Scaffold(
        key: const ValueKey('screen-auth'),
        backgroundColor: t.bg,
        body: Stack(
          children: [
            const Positioned.fill(child: _AuroraBackdrop()),
            SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(24, 0, 24, 28 + insets),
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
                    // One autofill context for the whole form, so the
                    // password manager sees name, e-mail and password together.
                    AutofillGroup(
                      child: _EmailForm(
                        isRegister: _isRegister,
                        loading: _loading,
                        busy: _busy,
                        passwordVisible: _passwordVisible,
                        nameController: _nameController,
                        emailController: _emailController,
                        passwordController: _passwordController,
                        error: _error,
                        message: _message,
                        onTogglePassword: () => setState(
                            () => _passwordVisible = !_passwordVisible),
                        onSubmit: _submit,
                        onForgotPassword: _forgotPassword,
                        onEnterCode: unconfirmed == null
                            ? null
                            : () => _openSignupCode(unconfirmed),
                      ),
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
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Aurora backdrop - one soft accent light source at the top, decorative.
// ═════════════════════════════════════════════════════════════════════

class _AuroraBackdrop extends StatelessWidget {
  const _AuroraBackdrop();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0.0, -1.15),
            radius: 1.05,
            colors: [
              t.lime.withValues(alpha: 0.17),
              t.lime.withValues(alpha: 0.0),
            ],
            stops: const [0.0, 1.0],
          ),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Brand mark - Eatova wordmark with the focus-ring o.
// ═════════════════════════════════════════════════════════════════════

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // On the mode ground the mark takes ink/accent, not the brand pair.
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        EatovaWordmark(fontSize: 26, textColor: t.ink, ringColor: t.accent),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Hero - eyebrow, large headline, quiet subline.
// ═════════════════════════════════════════════════════════════════════

class _Hero extends StatelessWidget {
  const _Hero({required this.isRegister});

  final bool isRegister;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Column(
      key: const ValueKey('auth-hero'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isRegister ? l10n.authEyebrowRegister : l10n.authEyebrowLogin,
          style: AppType.eyebrow(t.accent, size: 11),
        ),
        const SizedBox(height: 12),
        Text(
          isRegister ? l10n.authHeadlineRegister : l10n.authHeadlineLogin,
          style: AppType.display(30, color: t.ink, height: 1.08),
        ),
        const SizedBox(height: 12),
        Text(
          isRegister ? l10n.authSublineRegister : l10n.authSublineLogin,
          style: AppType.ui(
            15,
            weight: FontWeight.w500,
            color: t.ink2,
            height: 1.45,
          ),
        ),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Google button - card surface, prominent primary action (OAuth).
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
    final t = context.t;
    return Semantics(
      button: true,
      enabled: enabled,
      child: AnimatedOpacity(
        duration: motionDuration(context, const Duration(milliseconds: 160)),
        opacity: enabled ? 1 : 0.55,
        child: Container(
          decoration: BoxDecoration(
            color: t.surf,
            borderRadius: BorderRadius.circular(rPill),
            border: Border.all(color: t.line),
            boxShadow: softShadow(t),
          ),
          child: Material(
            type: MaterialType.transparency,
            borderRadius: BorderRadius.circular(rPill),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('auth-google-oauth'),
              onTap: enabled ? onTap : null,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 16, horizontal: 18),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: loading
                          ? CircularProgressIndicator(
                              strokeWidth: 2.2,
                              color: t.ink,
                            )
                          : const CustomPaint(painter: _GoogleGPainter()),
                    ),
                    const SizedBox(width: 12),
                    // Flexible + ellipsis: at 200% system font the label would
                    // otherwise burst the button width.
                    Flexible(
                      child: Text(
                        context.l10n.authGoogleCta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.ui(
                          15.5,
                          weight: FontWeight.w700,
                          color: t.ink,
                          letterSpacing: -0.1,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GoogleGPainter extends CustomPainter {
  const _GoogleGPainter();

  // Google's own brand colors (sign-in branding guidelines): the "G" must not
  // follow the app theme, so these are the one place with fixed colors.
  static const Color _blue = Color.fromARGB(255, 66, 133, 244);
  static const Color _green = Color.fromARGB(255, 52, 168, 83);
  static const Color _yellow = Color.fromARGB(255, 251, 188, 5);
  static const Color _red = Color.fromARGB(255, 234, 67, 53);

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

    arc(-90, 90, _blue);
    arc(0, 90, _green);
    arc(90, 90, _yellow);
    arc(180, 90, _red);

    final p = Paint()..color = _blue;
    canvas.drawRect(Rect.fromLTWH(cx, cy - 1.4, r, 2.8), p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ═════════════════════════════════════════════════════════════════════
// OR divider
// ═════════════════════════════════════════════════════════════════════

class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      children: [
        const Expanded(child: Divider()),
        const SizedBox(width: 12),
        // Flexible + ellipsis: large system fonts must not burst the
        // divider row.
        Flexible(
          child: Text(
            context.l10n.authOrWithEmail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.ui(
              12,
              weight: FontWeight.w600,
              color: t.ink2,
              letterSpacing: 0.2,
            ),
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(child: Divider()),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Email form
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
    required this.onEnterCode,
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

  /// Set only after "e-mail not confirmed": opens the signup code page.
  final VoidCallback? onEnterCode;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      key: const ValueKey('auth-email-card'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        maybeAnimatedSize(
          context,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: isRegister
              ? Padding(
                  key: const ValueKey('name-field-wrap'),
                  padding: const EdgeInsets.only(bottom: 14),
                  child: AuthField(
                    fieldKey: const ValueKey('auth-name-field'),
                    icon: Icons.person_outline_rounded,
                    label: l10n.authFieldNameLabel,
                    hint: l10n.authFieldNameHint,
                    controller: nameController,
                    enabled: !busy,
                    textInputAction: TextInputAction.next,
                    textCapitalization: TextCapitalization.words,
                    autofillHints: const [AutofillHints.name],
                  ),
                )
              : const SizedBox.shrink(key: ValueKey('no-name-field')),
        ),
        AuthField(
          fieldKey: const ValueKey('auth-email-field'),
          icon: Icons.alternate_email_rounded,
          label: l10n.authFieldEmailLabel,
          hint: l10n.authFieldEmailHint,
          controller: emailController,
          enabled: !busy,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.email],
        ),
        const SizedBox(height: 14),
        AuthField(
          fieldKey: const ValueKey('auth-password-field'),
          icon: Icons.lock_outline_rounded,
          label: l10n.authFieldPasswordLabel,
          hint: l10n.authFieldPasswordHint,
          controller: passwordController,
          enabled: !busy,
          obscure: !passwordVisible,
          textInputAction: TextInputAction.done,
          autofillHints: isRegister
              ? const [AutofillHints.newPassword]
              : const [AutofillHints.password],
          onSubmitted: (_) => busy ? null : onSubmit(),
          trailing: AuthPasswordToggle(
            toggleKey: const ValueKey('auth-toggle-password'),
            visible: passwordVisible,
            showLabel: l10n.authShowPasswordTooltip,
            hideLabel: l10n.authHidePasswordTooltip,
            onTap: busy ? null : onTogglePassword,
          ),
        ),
        if (!isRegister) ...[
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: AuthTextLink(
              linkKey: const ValueKey('auth-forgot-password'),
              label: l10n.authForgotPasswordCta,
              onTap: busy ? null : onForgotPassword,
            ),
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: 14),
          AuthInlineNote(
            noteKey: const ValueKey('auth-error'),
            text: error!,
            tone: AuthNoteTone.error,
            actionKey: const ValueKey('auth-enter-code'),
            actionLabel: onEnterCode == null ? null : l10n.authEnterCodeCta,
            onAction: busy ? null : onEnterCode,
          ),
        ],
        if (message != null) ...[
          const SizedBox(height: 14),
          AuthInlineNote(
            noteKey: const ValueKey('auth-message'),
            text: message!,
            tone: AuthNoteTone.info,
          ),
        ],
        const SizedBox(height: 22),
        AuthPrimaryButton(
          buttonKey: const ValueKey('auth-submit'),
          label: isRegister ? l10n.authSubmitRegister : l10n.authSubmitLogin,
          icon: Icons.arrow_forward_rounded,
          loading: loading,
          enabled: !busy,
          onTap: onSubmit,
        ),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Mode toggle - quiet text switch between login and register.
// ═════════════════════════════════════════════════════════════════════

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.isRegister, required this.onTap});

  final bool isRegister;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    // MergeSemantics: prompt and action read as ONE button, not two texts.
    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: onTap != null,
        child: InkWell(
          key: ValueKey(
              isRegister ? 'auth-toggle-login' : 'auth-toggle-register'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(rChip),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Center(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                // Wrap, not Row: at 200% system font the two texts stack
                // instead of running off screen (WCAG 1.4.4).
                child: Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  children: [
                    Text(
                      isRegister
                          ? l10n.authTogglePromptRegister
                          : l10n.authTogglePromptLogin,
                      style: AppType.ui(
                        14,
                        weight: FontWeight.w500,
                        color: t.ink2,
                      ),
                    ),
                    Text(
                      isRegister
                          ? l10n.authToggleActionLogin
                          : l10n.authToggleActionRegister,
                      style: AppType.ui(
                        14,
                        weight: FontWeight.w700,
                        color: t.accent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Legal notice with tappable links to the terms and the privacy policy
/// (GDPR Art. 13 / app store); both live on eatova.de.
///
/// Stateful only for the two recognizers, which must be disposed.
class _ConsentNotice extends StatefulWidget {
  const _ConsentNotice();

  @override
  State<_ConsentNotice> createState() => _ConsentNoticeState();
}

class _ConsentNoticeState extends State<_ConsentNotice> {
  late final TapGestureRecognizer _terms = TapGestureRecognizer()
    ..onTap = () => _open(kTermsUrl);
  late final TapGestureRecognizer _privacy = TapGestureRecognizer()
    ..onTap = () => _open(kPrivacyUrl);

  /// Opens a legal link and SAYS SO when that fails (P4-05).
  ///
  /// `launchUrl` reports "no handler" in two shapes: `false`, and — on Android
  /// — a thrown `PlatformException('ACTIVITY_NOT_FOUND')`. Neither was read
  /// before: the tap did visibly nothing and the exception ended up unhandled
  /// in `PlatformDispatcher.onError`, i.e. as a Sentry event nobody could tie
  /// to a user. Both links are GDPR Art. 13 and store obligations on exactly
  /// this screen, so the fallback names the URL to type by hand.
  Future<void> _open(String url) async {
    var geoeffnet = false;
    try {
      geoeffnet =
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      geoeffnet = false;
    }
    if (geoeffnet || !mounted) return;
    showAppSnack(
      context,
      context.l10n.authLegalLinkFailed(url),
      icon: Icons.link_off_rounded,
      tone: SnackTone.warning,
    );
  }

  @override
  void dispose() {
    _terms.dispose();
    _privacy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final linkStyle = TextStyle(color: t.accent, fontWeight: FontWeight.w700);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text.rich(
        key: const ValueKey('auth-consent-notice'),
        TextSpan(
          style: AppType.ui(
            11.5,
            weight: FontWeight.w500,
            color: t.ink2,
            height: 1.4,
          ),
          children: [
            TextSpan(text: l10n.authConsentPrefix),
            TextSpan(
              text: l10n.authConsentTerms,
              style: linkStyle,
              recognizer: _terms,
            ),
            TextSpan(text: l10n.authConsentMiddle),
            TextSpan(
              text: l10n.authConsentPrivacy,
              style: linkStyle,
              recognizer: _privacy,
            ),
            TextSpan(text: l10n.authConsentSuffix),
          ],
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}
