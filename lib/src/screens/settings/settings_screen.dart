import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/legal_links.dart';
import '../../app/locale_controller.dart';
import '../../auth/auth_repository.dart';
import '../../l10n/l10n.dart';
import '../../services/crash_reporter.dart';
import '../../services/secure_screen.dart';
import '../../theme/app_tokens.dart';
import '../../theme/theme_mode_controller.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/design/design.dart';
import '../../widgets/shared/data_export_sheet.dart';
import 'account_change_messages.dart';
import 'account_change_sheets.dart';
import 'settings_controls.dart';

/// Settings — account, appearance, data, danger zone.
///
/// Body data, activity, goals and daily targets live on their own page
/// ([GoalsScreen], reachable via "Profil & Ziele"); this page keeps what
/// concerns the account and the app.
///
/// Deliberately absent: units, weekly summary mail and connected accounts have
/// no function here, and a switch without effect is worse than none. No
/// "VERIFIED" badge either — the app does not know the confirmation state.
/// Apple Health lives in the profile only; the same state in two places would
/// be a bug.
///
/// Rows depending on [AuthRepository] (password and e-mail change) drop out
/// entirely without it — same rule as export and sign-out. "Über Eatova"
/// carries the ODbL attribution for OpenFoodFacts data and the GDPR Art. 13
/// privacy link, hence its place in DATEN & PRIVATSPHÄRE.
///
/// The screen returns nothing; every action runs through its callback.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.email,
    this.authRepository,
    this.onOpenGoals,
    this.onSignOut,
    this.onDeleteAccount,
    this.onExportData,
  });

  /// Session mail address. Null in previews/tests without auth — the row is
  /// hidden instead of filled with a placeholder.
  final String? email;

  /// Carries account changes (password, mail) and the re-authentication before
  /// account deletion. Null in previews/tests without auth — the affected rows
  /// then drop out instead of leading nowhere.
  final AuthRepository? authRepository;

  /// Leads to "Profil & Ziele".
  final VoidCallback? onOpenGoals;

  final Future<void> Function()? onSignOut;
  final Future<void> Function()? onDeleteAccount;

  /// Supplies the full data export as JSON (GDPR Art. 15). Null without sync,
  /// in which case the entry drops out.
  final Future<String> Function()? onExportData;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// App metadata at runtime instead of hardcoded strings that drift on a
/// version bump. In widget tests the channel is unmocked and the future fails,
/// so the rows show "—".
///
/// A private twin exists in `profile_screen.dart`; both should share one
/// accessor.
final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

class _SettingsScreenState extends State<SettingsScreen> {
  /// Address from the running session.
  ///
  /// [SettingsScreen.email] freezes when the route is built and would keep the
  /// old address after a change, so this screen listens to `authStateChanges`
  /// itself (contract in `test/auth_account_change_test.dart`).
  String? _sessionEmail;
  StreamSubscription<EatovaUser?>? _sessionSub;

  @override
  void initState() {
    super.initState();
    final repo = widget.authRepository;
    if (repo == null) return;
    _sessionEmail = repo.currentUser?.email;
    _sessionSub = repo.authStateChanges.listen((user) {
      final adresse = user?.email;
      // `null` means signed out, not "address gone": the AuthGate tears this
      // route down anyway, and until then the last known address is honest.
      if (!mounted || adresse == null || adresse == _sessionEmail) return;
      setState(() => _sessionEmail = adresse);
    }, onError: (Object e, StackTrace st) {
      // gotrue actively pushes errors into this stream; without a handler they
      // become unhandled zone errors, triggerable from outside via the
      // BROWSABLE intent. Report, do not escalate.
      unawaited(CrashReporter.capture(e, st, context: 'settings-session-stream'));
    });
  }

  @override
  void dispose() {
    _sessionSub?.cancel();
    super.dispose();
  }

  /// Mail address to display — session beats constructor parameter.
  String? get _adresse => _sessionEmail ?? widget.email;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;

    // The page shows only the mail address, but the export sheet shows the full
    // record. That sheet is a route ABOVE this one, so this guard stays held
    // and covers it too.
    return SecureScreenGuard(
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: ListView(
            key: const ValueKey('screen-settings'),
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 32),
            children: <Widget>[
              PageHeader(
                large: l10n.settingsPageTitle,
                backKey: const ValueKey('settings-back'),
              ),
              const SizedBox(height: 16),
              ..._kontoGruppe(t, l10n),
              ..._praeferenzenGruppe(l10n),
              ..._datenGruppe(l10n),
              ..._gefahrenzone(t, l10n),
            ],
          ),
        ),
      ),
    );
  }

  /// Builds a [SettingsGroup] only when it has rows; otherwise an empty card
  /// with its caption would sit on the page.
  List<Widget> _gruppe(
    String label,
    List<Widget> kinder, {
    Color? labelColor,
    Color? borderColor,
  }) {
    if (kinder.isEmpty) return const <Widget>[];
    return <Widget>[
      SettingsGroup(
        label: label,
        labelColor: labelColor,
        borderColor: borderColor,
        children: kinder,
      ),
    ];
  }

  // --- ACCOUNT --------------------------------------------------------------

  List<Widget> _kontoGruppe(AppTokens t, AppLocalizations l10n) {
    final email = _adresse;
    final repo = widget.authRepository;
    return _gruppe(l10n.settingsGroupAccount, <Widget>[
      if (email != null)
        SettingsRow(
          key: const ValueKey('settings-email'),
          // Display only, no chevron: the row below does the change, and a
          // "VERIFIED" badge cannot be substantiated. `accent` instead of a
          // macro tone — macro colors encode nutrients only (DESIGN_REFACTOR
          // §3, lock 1).
          leading: IconTile(icon: Icons.mail_outline_rounded, color: t.accent),
          title: l10n.settingsEmailLabel,
          subtitle: email,
          chevron: false,
        ),
      if (repo != null)
        SettingsRow(
          key: const ValueKey('settings-change-password'),
          // `accent` instead of a macro tone: macro colors encode nutrients
          // only (DESIGN_REFACTOR §3, lock 1).
          leading: IconTile(icon: Icons.lock_outline_rounded, color: t.accent),
          title: l10n.settingsChangePasswordTitle,
          subtitle: l10n.settingsChangePasswordSubtitle,
          onTap: () => _openPasswortAendern(repo, email),
        ),
      // No change without a known address: the first of the two codes is
      // verified against the CURRENT address.
      if (repo != null && email != null)
        SettingsRow(
          key: const ValueKey('settings-change-email'),
          leading:
              IconTile(icon: Icons.alternate_email_rounded, color: t.accent),
          title: l10n.settingsChangeEmailTitle,
          subtitle: l10n.settingsChangeEmailSubtitle,
          onTap: () => _openMailAendern(repo, email),
        ),
    ]);
  }

  Future<void> _openPasswortAendern(
    AuthRepository repo,
    String? email,
  ) async {
    final l10n = context.l10n;
    final erfolg = await showPasswordChangeSheet(
      context,
      authRepository: repo,
      email: email,
    );
    if (!erfolg || !mounted) return;
    showAppSnack(
      context,
      l10n.settingsPasswordChangedSnack,
      icon: Icons.lock_reset_rounded,
    );
  }

  Future<void> _openMailAendern(AuthRepository repo, String email) async {
    final l10n = context.l10n;
    final erfolg = await showEmailChangeSheet(
      context,
      authRepository: repo,
      currentEmail: email,
    );
    if (!erfolg || !mounted) return;
    // The new address is already in the row above: the stream reported it
    // before the sheet closed.
    showAppSnack(
      context,
      l10n.settingsEmailChangedSnack,
      icon: Icons.mark_email_read_rounded,
    );
  }

  // --- PREFERENCES ----------------------------------------------------------

  List<Widget> _praeferenzenGruppe(AppLocalizations l10n) {
    // Without [ThemeModeScope] (previews, widget tests) the row drops out — a
    // switch without a controller would be a dead switch.
    final controller = ThemeModeScope.maybeOf(context);
    // Same guard for the language row: without [LocaleScope] nothing could set
    // the override.
    final localeController = LocaleScope.maybeOf(context);
    return _gruppe(l10n.settingsGroupPreferences, <Widget>[
      if (widget.onOpenGoals != null)
        SettingsRow(
          key: const ValueKey('settings-open-goals'),
          title: l10n.goalsPageTitle,
          subtitle: l10n.settingsOpenGoalsSubtitle,
          onTap: widget.onOpenGoals,
        ),
      if (controller != null)
        SettingsRow(
          // Three states, not a toggle (DESIGN_REFACTOR §2: default is
          // ThemeMode.system), so the row is named after what it sets, not
          // after one of its values.
          title: l10n.settingsAppearanceTitle,
          subtitle: l10n.settingsAppearanceSubtitle,
          chevron: false,
          trailing: SettingsThemeModePill(
            key: const ValueKey('settings-theme-mode'),
            mode: controller.mode,
            // Device setting: persisted immediately, nothing to save or drop.
            onChanged: controller.setMode,
          ),
        ),
      if (localeController != null)
        SettingsRow(
          title: l10n.settingsLanguageTitle,
          subtitle: l10n.settingsLanguageSubtitle,
          chevron: false,
          trailing: SettingsLanguagePill(
            key: const ValueKey('settings-language'),
            value: localeController.override,
            // Device setting: persisted immediately, nothing to drop.
            onChanged: localeController.setOverride,
          ),
        ),
    ]);
  }

  // --- DATA & PRIVACY -------------------------------------------------------

  List<Widget> _datenGruppe(AppLocalizations l10n) {
    return _gruppe(l10n.settingsGroupDataPrivacy, <Widget>[
      if (widget.onExportData != null)
        SettingsRow(
          key: const ValueKey('settings-export'),
          title: l10n.settingsExportDataTitle,
          subtitle: l10n.settingsExportDataSubtitle,
          onTap: _openExport,
        ),
      // The three legal pages as rows, not a footer; keys unchanged from
      // [SettingsLegalLinks] (DESIGN_REFACTOR §6).
      _LegalRow(
        rowKey: const ValueKey('settings-privacy-link'),
        title: l10n.settingsLegalPrivacy,
        url: kPrivacyUrl,
      ),
      _LegalRow(
        rowKey: const ValueKey('settings-terms-link'),
        title: l10n.settingsLegalTerms,
        url: kTermsUrl,
      ),
      _LegalRow(
        rowKey: const ValueKey('settings-imprint-link'),
        title: l10n.settingsLegalImprint,
        url: kImprintUrl,
      ),
      // Version, data provenance (ODbL attribution for OpenFoodFacts) and the
      // privacy link — in this group because the sheet is entirely about data.
      SettingsRow(
        key: const ValueKey('settings-about'),
        title: l10n.settingsAboutTitle,
        subtitle: l10n.settingsAboutSubtitle,
        onTap: () => showEatovaSheet<void>(context, const _AboutSheet()),
      ),
    ]);
  }

  Future<void> _openExport() async {
    final bauen = widget.onExportData;
    if (bauen == null) return;
    await showDataExportSheet(
      context,
      snapshot: bauen,
      vollstaendig: true,
    );
  }

  // --- DANGER ZONE ----------------------------------------------------------

  List<Widget> _gefahrenzone(AppTokens t, AppLocalizations l10n) {
    final repo = widget.authRepository;
    final email = _adresse;
    return _gruppe(
      l10n.settingsGroupDangerZone,
      <Widget>[
        if (widget.onSignOut != null)
          SettingsRow(
            key: const ValueKey('settings-sign-out'),
            title: l10n.settingsSignOutTitle,
            onTap: _signOut,
          ),
        // Without an auth layer OR a known address there is nothing to
        // re-authenticate against, so the row drops out rather than offering
        // the irreversible action without a second hurdle.
        //
        // Verified 2026-08-18: an account without an e-mail address cannot
        // arise here (only e-mail and Google providers, both always carry the
        // claim). The null branch is defensive for tests/previews — deletion
        // stays reachable for every real user, so no GDPR gap.
        if (widget.onDeleteAccount != null && repo != null && email != null)
          _deleteBlock(t, l10n, repo, email),
      ],
      labelColor: t.danger,
      borderColor: t.danger.withValues(alpha: 0.35),
    );
  }

  Widget _deleteBlock(
    AppTokens t,
    AppLocalizations l10n,
    AuthRepository repo,
    String email,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              IconTile(icon: Icons.delete_outline_rounded, color: t.danger),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      l10n.settingsDeleteAccountTitle,
                      style: AppType.ui(
                        13.5,
                        weight: FontWeight.w700,
                        color: t.danger,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.settingsDeleteAccountBlockSubtitle,
                      style: AppType.ui(11.5, color: t.ink2),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Material(
            color: t.danger.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(13),
            child: InkWell(
              key: const ValueKey('settings-delete-account'),
              onTap: () => _openDeleteSheet(repo, email),
              borderRadius: BorderRadius.circular(13),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
                child: Text.rich(
                  TextSpan(
                    text: l10n.settingsDeleteAccountPromptPrefix,
                    children: <InlineSpan>[
                      TextSpan(
                        text: l10n.settingsDeleteConfirmWord,
                        style: AppType.ui(
                          11.5,
                          weight: FontWeight.w700,
                          color: t.ink,
                          height: 1.45,
                        ),
                      ),
                      // The identity confirmation is real (second step with a
                      // mail code, [_DeleteAccountSheet]). No grace period is
                      // promised: deletion is immediate and irreversible.
                      TextSpan(
                        text: l10n.settingsDeleteAccountPromptSuffixCode,
                      ),
                    ],
                    style: AppType.ui(11.5, color: t.ink2, height: 1.45),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Close the page first, then sign out.
  ///
  /// The order matters: `AuthGate` tears down everything above the root route
  /// on an identity change and shows a session-expired message. A deliberate
  /// sign-out must not produce that, so it pops itself before the callback.
  Future<void> _signOut() async {
    final abmelden = widget.onSignOut;
    if (abmelden == null) return;
    final navigator = Navigator.of(context);
    await navigator.maybePop();
    await abmelden();
  }

  Future<void> _openDeleteSheet(AuthRepository repo, String email) async {
    final loeschen = widget.onDeleteAccount;
    if (loeschen == null) return;
    // Two hurdles for two cases: the typed word catches accidents, the mail
    // code catches a stranger's finger on an unlocked device. The server
    // enforces the second one too — `delete_account()` rejects any JWT whose
    // `amr` claim lacks an 'otp'/'recovery' entry from the last 5 minutes
    // (EX_REAUTH_REQUIRED, migration 20260815120000_delete_account_reauth.sql),
    // and `verifyRecoveryCode` creates exactly such a session. The UI hurdles
    // still matter: they act BEFORE any mail goes out.
    final bestaetigt = await showEatovaSheet<bool>(
      context,
      _DeleteAccountSheet(
        key: const ValueKey<String>('delete-account-sheet'),
        authRepository: repo,
        email: email,
      ),
    );
    if (bestaetigt != true || !mounted) return;
    final navigator = Navigator.of(context);
    await navigator.maybePop();
    await loeschen();
  }
}

// ---------------------------------------------------------------------------
// Building blocks of this screen
// ---------------------------------------------------------------------------

/// A row that opens a legal page in the browser.
///
/// External icon instead of a chevron: a chevron promises a follow-up page
/// inside the app, this one leaves it.
class _LegalRow extends StatelessWidget {
  const _LegalRow({
    required this.rowKey,
    required this.title,
    required this.url,
  });

  final Key rowKey;
  final String title;
  final String url;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return SettingsRow(
      key: rowKey,
      title: title,
      chevron: false,
      trailing: Icon(Icons.open_in_new_rounded, size: 15, color: t.ink2),
      onTap: () => launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      ),
    );
  }
}

/// The "Über Eatova" sheet.
///
/// Two rows in it are mandatory, not decoration:
///  * **Sources** — ODbL attribution for the OpenFoodFacts data.
///  * **Privacy policy** — GDPR Art. 13 requires it after login too, not just
///    on the auth screen.
///
/// The test key `profile-privacy-link` travelled with the sheet from the
/// profile and is deliberately NOT renamed (DESIGN_REFACTOR §6).
class _AboutSheet extends StatelessWidget {
  const _AboutSheet();

  /// Data sources, per platform: product data from OpenFoodFacts and the own
  /// search index; steps from Apple Health on iOS only, since the health path
  /// is a no-op on Android.
  static String _sources(AppLocalizations l10n) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return l10n.settingsAboutSourcesWithAppleHealth;
    }
    return l10n.settingsAboutSourcesDefault;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    // Scrollable, not rigid: at double system font the block overflows the
    // screen (~251 px), and the privacy link at the bottom must never be cut.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              IconTile(
                icon: Icons.bolt_rounded,
                color: t.accent,
                size: 44,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      l10n.settingsAboutAppName,
                      style: AppType.display(20, color: t.ink),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.settingsAboutTagline,
                      style: AppType.ui(
                        12,
                        weight: FontWeight.w500,
                        color: t.ink2,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            l10n.settingsAboutDescription,
            style: AppType.ui(13, color: t.ink2, height: 1.45),
          ),
          const SizedBox(height: 16),
          FutureBuilder<PackageInfo>(
            future: _packageInfo,
            builder: (context, snapshot) {
              final info = snapshot.data;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _AboutRow(
                    label: l10n.settingsAboutVersionLabel,
                    value: info?.version ?? '—',
                  ),
                  const SizedBox(height: 6),
                  _AboutRow(
                    label: l10n.settingsAboutBuildLabel,
                    value: info?.buildNumber ?? '—',
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 6),
          _AboutRow(
            label: l10n.settingsAboutSourcesLabel,
            value: _sources(l10n),
          ),
          const SizedBox(height: 14),
          // GDPR Art. 13 / app stores: privacy reachable after login too.
          const _PrivacyLinkRow(),
        ],
      ),
    );
  }
}

/// Tappable privacy row in the [_AboutSheet]; opens the policy externally.
///
/// The key stays `profile-privacy-link` (DESIGN_REFACTOR §6);
/// `settings-privacy-link` one level up is a DIFFERENT control.
class _PrivacyLinkRow extends StatelessWidget {
  const _PrivacyLinkRow();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return InkWell(
      key: const ValueKey('profile-privacy-link'),
      onTap: () => launchUrl(
        Uri.parse(kPrivacyUrl),
        mode: LaunchMode.externalApplication,
      ),
      borderRadius: BorderRadius.circular(rControl),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: t.surf,
          borderRadius: BorderRadius.circular(rControl),
          border: Border.all(color: t.line),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.shield_outlined, color: t.ink2, size: 16),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                context.l10n.settingsPrivacyPolicyLinkLabel,
                style: AppType.ui(13, weight: FontWeight.w600, color: t.ink),
              ),
            ),
            Icon(Icons.open_in_new_rounded, color: t.ink2, size: 15),
          ],
        ),
      ),
    );
  }
}

/// Label left, value right — the row shape of the [_AboutSheet].
class _AboutRow extends StatelessWidget {
  const _AboutRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      children: <Widget>[
        Text(
          label,
          style: AppType.ui(12, weight: FontWeight.w500, color: t.ink2),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: AppType.ui(12, weight: FontWeight.w600, color: t.ink),
          ),
        ),
      ],
    );
  }
}

enum _LoeschSchritt { wort, code }

/// Two-step confirmation for account deletion.
///
/// Pops `true` once the user typed the confirm word AND confirmed the mail
/// code; otherwise `null`. Both steps live in the SAME sheet — a sheet that
/// closes and reopens looks like an error.
///
/// Why the recovery code and not `startPasswordChange()`: GoTrue's reauth
/// nonce can only be redeemed TOGETHER with a new password, and silently
/// swapping the password is not an option. `sendPasswordReset` +
/// `verifyRecoveryCode` is the only pair where the SERVER really checks the
/// code.
///
/// The database enforces it too: `delete_account()` requires a JWT whose `amr`
/// claim carries an 'otp'/'recovery' entry younger than 5 minutes (migration
/// 20260815120000_delete_account_reauth.sql), else `EX_REAUTH_REQUIRED`.
/// Reordering the steps — skipping the code, deferring the delete call — breaks
/// that server contract.
class _DeleteAccountSheet extends StatefulWidget {
  const _DeleteAccountSheet({
    super.key,
    required this.authRepository,
    required this.email,
  });

  final AuthRepository authRepository;

  /// Address the code goes to — required, because it is verified against
  /// exactly this one.
  final String email;

  @override
  State<_DeleteAccountSheet> createState() => _DeleteAccountSheetState();
}

class _DeleteAccountSheetState extends State<_DeleteAccountSheet> {
  final TextEditingController _confirm = TextEditingController();
  final TextEditingController _code = TextEditingController();

  _LoeschSchritt _schritt = _LoeschSchritt.wort;
  bool _busy = false;
  String? _fehler;
  String? _codeFehler;

  @override
  void dispose() {
    _confirm.dispose();
    _code.dispose();
    super.dispose();
  }

  /// Case-insensitive: the confirmation guards against accidents, not against
  /// the shift key. The expected word comes from the ARB, hence a
  /// context-taking method instead of a `static const`.
  bool _scharf(String wort) => _confirm.text.trim().toUpperCase() == wort;

  Future<void> _codeAnfordern(String wort) async {
    // Double-tap guard here AND on `actionEnabled`: the button lock only takes
    // effect next frame, and a second mail would hit the GoTrue throttle and
    // burn the first code.
    if (_busy || !_scharf(wort)) return;
    setState(() {
      _busy = true;
      _fehler = null;
    });
    try {
      await widget.authRepository.sendPasswordReset(widget.email);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _fehler = accountChangeErrorMessage(error, context.l10n);
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _schritt = _LoeschSchritt.code;
    });
  }

  Future<void> _loeschenBestaetigen() async {
    if (_busy) return;
    final l10n = context.l10n;
    final code = _code.text.trim();
    // Caught locally: a too-short code would only earn a server error and be
    // burnt afterwards.
    if (!isAccountCode(code)) {
      setState(() {
        _fehler = null;
        _codeFehler = kAccountCodeInvalid(l10n);
      });
      return;
    }

    setState(() {
      _busy = true;
      _fehler = null;
      _codeFehler = null;
    });
    try {
      await widget.authRepository
          .verifyRecoveryCode(email: widget.email, code: code);
    } catch (error) {
      if (!mounted) return;
      // Do not clear the field: a typo should be correctable, not restarted.
      setState(() {
        _busy = false;
        _fehler = accountChangeErrorMessage(error, context.l10n);
      });
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final wort = l10n.settingsDeleteConfirmWord;
    final ersterSchritt = _schritt == _LoeschSchritt.wort;
    // The scroller lives in [SheetScaffold] itself: large system fonts can
    // overflow any sheet, not just this one.
    return SheetScaffold(
      title: l10n.settingsDeleteAccountTitle,
      subtitle: ersterSchritt
          ? l10n.settingsDeleteAccountSheetSubtitle
          : l10n.settingsDeleteAccountCodeSentTo(widget.email),
      destructive: true,
      actionLabel: _aktionsBeschriftung(l10n, ersterSchritt),
      actionEnabled: ersterSchritt ? !_busy && _scharf(wort) : !_busy,
      onAction:
          ersterSchritt ? () => _codeAnfordern(wort) : _loeschenBestaetigen,
      children: <Widget>[
        if (ersterSchritt)
          SheetField(
            key: const ValueKey('settings-delete-confirm-field'),
            label: l10n.settingsDeleteAccountFieldLabel(wort),
            hint: wort,
            controller: _confirm,
            enabled: !_busy,
            onChanged: (_) => setState(() {}),
          )
        else
          SheetField(
            key: const ValueKey('settings-delete-code-field'),
            label: l10n.settingsDeleteAccountCodeFieldLabel,
            hint: '••••••••',
            controller: _code,
            enabled: !_busy,
            keyboardType: TextInputType.number,
            errorText: _codeFehler,
          ),
        if (_fehler != null)
          SettingsNote(
            key: const ValueKey('settings-delete-error'),
            _fehler!,
            tone: context.t.danger,
            icon: Icons.error_outline_rounded,
            boxed: true,
          ),
      ],
    );
  }

  String _aktionsBeschriftung(AppLocalizations l10n, bool ersterSchritt) {
    if (_busy) {
      return ersterSchritt
          ? l10n.settingsDeleteAccountRequestingCta
          : l10n.settingsDeleteAccountCheckingCta;
    }
    // The delete label appears only in the SECOND step; the first only
    // requests the code.
    return ersterSchritt
        ? l10n.settingsDeleteAccountRequestCta
        : l10n.settingsDeleteAccountActionLabel;
  }
}
