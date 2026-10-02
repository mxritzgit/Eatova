import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;
import 'package:url_launcher/url_launcher.dart';

import '../auth/auth_repository.dart';
import '../config/legal_links.dart';
import '../l10n/l10n.dart';
import '../services/secure_screen.dart';
import '../services/sync_error_messages.dart'
    show isAuthNetworkError, isAuthServerFaultError;
import '../theme/app_tokens.dart';
import '../widgets/auth/auth_controls.dart';
import '../widgets/auth/auth_entry_header.dart';
import '../widgets/common/app_snack.dart';
import '../widgets/common/motion.dart';
import 'auth_code_screen.dart';
import 'settings/account_change_messages.dart'
    show kAccountMinPasswordLength, classifyAuthError, AuthErrorKind;

/// A focused account entry with persistent fields and a visible mode switch.
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
  bool _codeRouteOpen = false;
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

  bool get _busy => _loading || _oauthLoading != null || _codeRouteOpen;

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
    if (password.isEmpty) {
      setState(() => _error = l10n.authErrorPasswordMissing);
      return;
    }
    if (_isRegister && password.length < kAccountMinPasswordLength) {
      setState(
        () =>
            _error = l10n.authErrorPasswordTooShort(kAccountMinPasswordLength),
      );
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

  Future<void> _openSignupCode(String email) async {
    if (_codeRouteOpen) return;
    setState(() => _codeRouteOpen = true);
    try {
      final result = await Navigator.of(context).push<AuthCodeResult>(
        MaterialPageRoute<AuthCodeResult>(
          builder: (_) => AuthCodeScreen(
            authRepository: widget.authRepository,
            flow: AuthCodeFlow.signup,
            initialEmail: email,
          ),
        ),
      );
      if (mounted && result != null) _finishEmailFlow(result);
    } finally {
      if (mounted) setState(() => _codeRouteOpen = false);
    }
  }

  void _finishEmailFlow(AuthCodeResult result) {
    setState(() {
      _clearNotes();
      _isRegister = false;
      _emailController.text = result.email;
      _passwordController.clear();
      _message = result.flow == AuthCodeFlow.recovery
          ? context.l10n.authCodePasswordUpdated
          : context.l10n.authCodeSignupConfirmed;
    });
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
    if (error is AuthException &&
        (error.code == 'user_already_exists' || error.code == 'email_exists')) {
      return true;
    }
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
  Future<void> _forgotPassword() async {
    if (_busy || _codeRouteOpen) return;
    setState(() {
      _clearNotes();
      _codeRouteOpen = true;
    });
    try {
      final result = await Navigator.of(context).push<AuthCodeResult>(
        MaterialPageRoute<AuthCodeResult>(
          builder: (_) => AuthCodeScreen(
            authRepository: widget.authRepository,
            flow: AuthCodeFlow.recovery,
            initialEmail: _emailController.text.trim(),
          ),
        ),
      );
      if (mounted && result != null) _finishEmailFlow(result);
    } finally {
      if (mounted) setState(() => _codeRouteOpen = false);
    }
  }

  String _friendlyError(Object error) {
    final l10n = context.l10n;
    if (error is AuthCancelledException) return l10n.authErrorCancelled;
    if (error is AuthUnavailableException) return l10n.authErrorUnavailable;
    // A 5xx BEFORE the offline branch: gotrue wraps every HTTP >= 500 in the
    // same AuthRetryableFetchException a dead radio cell produces, so the
    // offline sentence told the user to check a connection that had just
    // carried the server's own answer (see [isAuthServerFaultError]).
    if (isAuthServerFaultError(error)) return l10n.authErrorServerFault;
    // Same TYPED branch and same position as `auth_code_screen.dart` (P4-02b):
    // offline there is no server text to classify, so a dead radio cell used to
    // fall through to `authErrorGeneric` and let the user suspect their
    // password. A 429 arrives as an AuthApiException, so no throttle is
    // swallowed here.
    if (isAuthNetworkError(error)) return l10n.authCodeOfflineError;
    final classified = classifyAuthError(error);
    switch (classified.kind) {
      case AuthErrorKind.quotaExhausted:
        return l10n.authCodeQuotaExhausted;
      case AuthErrorKind.sendThrottled:
        if (_isRegister) {
          return l10n.authCodeRateLimitedSeconds(
            classified.retryAfter!.inSeconds,
          );
        }
        return l10n.settingsAccountRateLimited;
      case AuthErrorKind.rateLimited:
        return l10n.settingsAccountRateLimited;
      default:
        break;
    }
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
    if (_busy || register == _isRegister) return;
    setState(() {
      _isRegister = register;
      _clearNotes();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final unconfirmed = _unconfirmedEmail;
    // Which field a LOCAL validation note is about, read off the note itself:
    // that field's capsule takes the error tint. Server answers name no field.
    final error = _error;
    final invalidField = error == null
        ? null
        : error == l10n.authErrorInvalidEmail
        ? _FormField.email
        : error == l10n.authErrorPasswordMissing ||
              error ==
                  l10n.authErrorPasswordTooShort(kAccountMinPasswordLength)
        ? _FormField.password
        : error == l10n.authErrorNameMissing
        ? _FormField.name
        : null;
    // Scaffold removes this inset from its resized body's MediaQuery.
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;

    return SecureScreenGuard(
      child: Scaffold(
        key: const ValueKey('screen-auth'),
        backgroundColor: t.bg,
        body: SafeArea(
          child: AuthPageLayout(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AuthEntryHeader(
                  key: const ValueKey('auth-hero'),
                  isRegister: _isRegister,
                  keyboardOpen: keyboardOpen,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AuthModeSelector(
                        isRegister: _isRegister,
                        enabled: !_busy,
                        onChanged: _setMode,
                      ),
                      const SizedBox(height: 24),
                      _GoogleButton(
                        enabled: !_busy,
                        loading: _oauthLoading == EatovaOAuthProvider.google,
                        onTap: () => _startOAuth(EatovaOAuthProvider.google),
                      ),
                      const SizedBox(height: 18),
                      const _OrDivider(),
                      const SizedBox(height: 18),
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
                          invalidField: invalidField,
                          message: _message,
                          onTogglePassword: () => setState(
                            () => _passwordVisible = !_passwordVisible,
                          ),
                          onSubmit: _submit,
                          onForgotPassword: _forgotPassword,
                          onEnterCode: unconfirmed == null
                              ? null
                              : () {
                                  if (!_busy) _openSignupCode(unconfirmed);
                                },
                        ),
                      ),
                      const SizedBox(height: 24),
                      const _ConsentNotice(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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
    return AuthSecondaryButton(
      buttonKey: const ValueKey('auth-google-oauth'),
      label: context.l10n.authGoogleCta,
      enabled: enabled,
      onTap: onTap,
      leading: loading
          ? CircularProgressIndicator(strokeWidth: 2.2, color: t.inkMuted)
          : const CustomPaint(painter: _GoogleGPainter()),
    );
  }
}

/// Google's "G" as Google ships it (sign-in branding guidelines), drawn from
/// the official 48 x 48 vector paths so no image asset is needed.
class _GoogleGPainter extends CustomPainter {
  const _GoogleGPainter();

  // Google's own brand colors: the "G" must not follow the app theme, so
  // these are the one place with fixed colors.
  static const Color _blue = Color.fromARGB(255, 66, 133, 244);
  static const Color _green = Color.fromARGB(255, 52, 168, 83);
  static const Color _yellow = Color.fromARGB(255, 251, 188, 5);
  static const Color _red = Color.fromARGB(255, 234, 67, 53);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 48, size.height / 48);
    final paint = Paint()..isAntiAlias = true;

    canvas.drawPath(
      Path()
        ..moveTo(24, 9.5)
        ..cubicTo(27.54, 9.5, 30.71, 10.72, 33.21, 13.1)
        ..lineTo(40.06, 6.25)
        ..cubicTo(35.9, 2.38, 30.47, 0, 24, 0)
        ..cubicTo(14.62, 0, 6.51, 5.38, 2.56, 13.22)
        ..lineTo(10.54, 19.41)
        ..cubicTo(12.43, 13.72, 17.74, 9.5, 24, 9.5)
        ..close(),
      paint..color = _red,
    );
    canvas.drawPath(
      Path()
        ..moveTo(46.98, 24.55)
        ..cubicTo(46.98, 22.98, 46.83, 21.46, 46.6, 20)
        ..lineTo(24, 20)
        ..lineTo(24, 29.02)
        ..lineTo(36.94, 29.02)
        ..cubicTo(36.36, 31.98, 34.68, 34.5, 32.16, 36.2)
        ..lineTo(39.89, 42.2)
        ..cubicTo(44.4, 38.02, 46.98, 31.84, 46.98, 24.55)
        ..close(),
      paint..color = _blue,
    );
    canvas.drawPath(
      Path()
        ..moveTo(10.53, 28.59)
        ..cubicTo(10.05, 27.14, 9.77, 25.6, 9.77, 24)
        ..cubicTo(9.77, 22.4, 10.04, 20.86, 10.53, 19.41)
        ..lineTo(2.55, 13.22)
        ..cubicTo(0.92, 16.46, 0, 20.12, 0, 24)
        ..cubicTo(0, 27.88, 0.92, 31.54, 2.56, 34.78)
        ..lineTo(10.53, 28.59)
        ..close(),
      paint..color = _yellow,
    );
    canvas.drawPath(
      Path()
        ..moveTo(24, 48)
        ..cubicTo(30.48, 48, 35.93, 45.87, 39.89, 42.19)
        ..lineTo(32.16, 36.19)
        ..cubicTo(30.01, 37.64, 27.24, 38.49, 24, 38.49)
        ..cubicTo(17.74, 38.49, 12.43, 34.27, 10.53, 28.58)
        ..lineTo(2.55, 34.77)
        ..cubicTo(6.51, 42.62, 14.62, 48, 24, 48)
        ..close(),
      paint..color = _green,
    );
    canvas.restore();
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
    final rule = Expanded(child: Container(height: 1, color: t.lineStrong));
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          rule,
          const SizedBox(width: 14),
          // Capped, not Flexible: the label keeps its own width and the two
          // rules share the rest evenly; only very large system fonts wrap
          // it, and then both rules keep a stub.
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: (constraints.maxWidth - 28 - 64).clamp(
                0.0,
                double.infinity,
              ),
            ),
            child: Text(
              context.l10n.authOrWithEmail,
              textAlign: TextAlign.center,
              style: AppType.ui(
                12.5,
                weight: FontWeight.w600,
                color: t.ink2,
                letterSpacing: 0.2,
              ),
            ),
          ),
          const SizedBox(width: 14),
          rule,
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Email form
// ═════════════════════════════════════════════════════════════════════

/// The form's fields, for pointing a validation note at one of them.
enum _FormField { name, email, password }

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
    required this.invalidField,
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

  /// The field a local validation [error] is about; it takes the error tint.
  final _FormField? invalidField;
  final String? message;
  final VoidCallback onTogglePassword;
  final VoidCallback onSubmit;
  final VoidCallback onForgotPassword;

  /// Set only after "e-mail not confirmed": opens the signup code page.
  final VoidCallback? onEnterCode;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // In login mode the forgot-password link already spaces the password
    // field from what follows.
    final afterFields = isRegister ? 18.0 : 6.0;
    final hasNote = error != null || message != null;
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
                  padding: const EdgeInsets.only(bottom: 16),
                  child: AuthField(
                    fieldKey: const ValueKey('auth-name-field'),
                    error: invalidField == _FormField.name,
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
          error: invalidField == _FormField.email,
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
        const SizedBox(height: 16),
        AuthField(
          fieldKey: const ValueKey('auth-password-field'),
          error: invalidField == _FormField.password,
          icon: Icons.lock_outline_rounded,
          label: l10n.authFieldPasswordLabel,
          hint: isRegister
              ? l10n.authFieldPasswordHint
              : l10n.authFieldPasswordLoginHint,
          controller: passwordController,
          enabled: !busy,
          obscure: !passwordVisible,
          autocorrect: false,
          enableSuggestions: false,
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
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: AuthTextLink(
              linkKey: const ValueKey('auth-forgot-password'),
              label: l10n.authForgotPasswordCta,
              emphasis: true,
              onTap: busy ? null : onForgotPassword,
            ),
          ),
        ],
        if (error != null) ...[
          SizedBox(height: afterFields),
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
          SizedBox(height: error == null ? afterFields : 10),
          AuthInlineNote(
            noteKey: const ValueKey('auth-message'),
            text: message!,
            tone: AuthNoteTone.info,
          ),
        ],
        SizedBox(height: hasNote ? 20 : afterFields + 6),
        AuthPrimaryButton(
          buttonKey: const ValueKey('auth-submit'),
          label: isRegister ? l10n.authSubmitRegister : l10n.authSubmitLogin,
          loading: loading,
          enabled: !busy,
          onTap: onSubmit,
        ),
      ],
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
      geoeffnet = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
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
    final linkStyle = TextStyle(
      color: t.accentText,
      fontWeight: FontWeight.w700,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Text.rich(
        key: const ValueKey('auth-consent-notice'),
        TextSpan(
          style: AppType.ui(
            12,
            weight: FontWeight.w500,
            color: t.ink2,
            height: 1.5,
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
