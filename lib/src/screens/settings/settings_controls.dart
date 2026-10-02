import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/legal_links.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/app_snack.dart';
import '../../widgets/common/motion.dart';
// Only for [SelectionTone]: the settings pills speak the app's selection
// language, not a second one.
import '../../widgets/design/controls.dart';
import '../../widgets/design/sheets.dart'
    show FieldCapsule, SheetFieldShape;

// ---------------------------------------------------------------------------
// Controls of the settings page. Package-local clones because the shared
// library covers none of these four cases: a key on the inner field, keys per
// pill option, a tonal secondary button, and explanatory rows. Once the library
// catches up, they can go.
// ---------------------------------------------------------------------------

/// A row with a right-aligned number field: label, value, unit.
///
/// [fieldKey] sits on the inner [TextField] because tests read
/// `widget<TextField>(...).controller`. The error text is a separate [Text]
/// below the row, or the range message would appear twice and break
/// `findsOneWidget`. **A11y:** [MergeSemantics] folds the three siblings into
/// one node.
///
/// Number and unit sit in a borderless [FieldCapsule]: the soft fill shows it
/// is editable, and focus lightens it (the app's focus language).
class SettingsNumberRow extends StatefulWidget {
  const SettingsNumberRow({
    super.key,
    required this.label,
    required this.suffix,
    required this.controller,
    required this.fieldKey,
    this.errorText,
    this.onChanged,
  });

  final String label;

  /// Unit shown right of the field.
  final String suffix;

  final TextEditingController controller;
  final Key fieldKey;

  /// C1: the allowed range, shown once the typed value leaves it. No
  /// character filter: `digitsOnly` turned "75,5" into 755, so the caller
  /// validates the unchanged text (whole number, ambiguity, range).
  final String? errorText;

  final ValueChanged<String>? onChanged;

  @override
  State<SettingsNumberRow> createState() => _SettingsNumberRowState();
}

class _SettingsNumberRowState extends State<SettingsNumberRow> {
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
  }

  @override
  void didUpdateWidget(SettingsNumberRow old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onText);
      widget.controller.addListener(_onText);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    _focus.dispose();
    super.dispose();
  }

  /// The capsule hugs the number, so it grows as digits are typed.
  void _onText() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final hatFehler = widget.errorText != null;
    final zahlStil = AppType.display(
      18,
      weight: FontWeight.w700,
      color: hatFehler ? t.danger : t.ink,
    );
    // Field width = the typed number plus room for the caret, never under two
    // digits and capped, so at textScaler 2.0 the label keeps its line.
    final scaler = MediaQuery.textScalerOf(context);
    final painter = TextPainter(
      text: TextSpan(
        text: widget.controller.text.isEmpty ? '00' : widget.controller.text,
        style: zahlStil,
      ),
      textDirection: Directionality.of(context),
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final feldBreite = (painter.width + 4).clamp(
      scaler.scale(24),
      scaler.scale(64).clamp(64.0, 132.0),
    );
    painter.dispose();

    // From about 1.6x system font the capsule takes its own line under the
    // label; beside it, label and number would fight for a 320 px row.
    final stacked = scaler.scale(15) > 24;
    final label = Text(
      widget.label,
      style: AppType.ui(15, weight: FontWeight.w600, color: t.ink),
    );
    // The whole capsule focuses the field, not just the digits.
    final capsule = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _focus.requestFocus,
      child: FieldCapsule(
        focusNode: _focus,
        error: hatFehler,
        shape: SheetFieldShape.pill,
        shadow: false,
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: feldBreite,
              child: TextField(
                key: widget.fieldKey,
                controller: widget.controller,
                focusNode: _focus,
                // Without this the cursor fade never settles and
                // `pumpAndSettle` hangs.
                cursorOpacityAnimates: false,
                cursorColor: t.accent,
                textAlign: TextAlign.right,
                keyboardType: TextInputType.number,
                onChanged: widget.onChanged,
                style: zahlStil,
                // All border slots off and unfilled: the capsule around it is
                // the field's surface.
                decoration: const InputDecoration(
                  filled: false,
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  focusedErrorBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                widget.suffix,
                style: AppType.ui(13, weight: FontWeight.w600, color: t.ink2),
              ),
            ),
          ],
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 14, 10),
      child: MergeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (stacked) ...<Widget>[
              label,
              const SizedBox(height: 8),
              capsule,
            ] else
              Row(
                children: <Widget>[
                  Expanded(child: label),
                  const SizedBox(width: 12),
                  capsule,
                ],
              ),
            if (hatFehler) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                widget.errorText!,
                style:
                    AppType.ui(12, weight: FontWeight.w500, color: t.danger),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Explanatory row with an icon. Without [boxed] a plain child of a settings
/// group; with [boxed] it carries its own tinted surface.
class SettingsNote extends StatelessWidget {
  const SettingsNote(
    this.text, {
    super.key,
    this.tone,
    this.icon = Icons.info_outline_rounded,
    this.boxed = false,
  });

  final String text;

  /// Glyph color — and, on an UNBOXED note, the text color too; defaults to
  /// the quiet [AppTokens.ink2]. [AppTokens.warning] and [AppTokens.danger]
  /// mark notes that need action. A [boxed] note always writes in `ink`.
  final Color? tone;

  final IconData icon;
  final bool boxed;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final ton = tone ?? t.ink2;
    // Signal-banner contract (hell_modus_audit_test): fill = tone at 10 %,
    // GLYPH in the full tone, TEXT in `ink`. The tinted fill eats the
    // headroom the tone still had on the bare ground — over `bg` (where these
    // boxes actually sit) 13 px text measures warning 4.20:1, danger 4.48:1
    // and even the quiet ink2 4.48:1, all below AA. `ink` gives 12.9-14.7:1.
    // Unboxed notes keep the tone as text color: without a fill it carries
    // (warning 4.76:1 on bg, 5.38:1 on surf), and the tone IS the signal
    // there.
    final textFarbe = boxed ? t.ink : ton;

    final zeile = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 17, color: ton),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: AppType.ui(
              13,
              weight: FontWeight.w500,
              color: textFarbe,
              height: 1.4,
            ),
          ),
        ),
      ],
    );

    if (!boxed) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
        child: zeile,
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: ton.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(rTile),
        border: Border.all(color: ton.withValues(alpha: 0.24)),
      ),
      child: zeile,
    );
  }
}

/// Shared rendering base of the settings pills: a recessed capsule track
/// with full-width segments of at least 48 px and a test key per option.
class _SettingsChoicePill<T> extends StatelessWidget {
  const _SettingsChoicePill({
    required this.value,
    required this.optionen,
    required this.onChanged,
  });

  final T value;
  final List<(T, String, String)> optionen;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // A recessed capsule track with the options inside, the chosen one an
    // accent pill — the tabs' segmented language. At large text sizes the
    // options stack into a full-width list in the same track.
    return LayoutBuilder(
      builder: (context, constraints) {
        const inset = 4.0;
        final inner = constraints.maxWidth - inset * 2;
        // Side by side while the widest label plus its padding fits a
        // third of the track; otherwise one option per line.
        final labelStyle = AppType.ui(14, weight: FontWeight.w700);
        var widest = 0.0;
        for (final (_, label, _) in optionen) {
          final painter = TextPainter(
            text: TextSpan(text: label, style: labelStyle),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          widest = math.max(widest, painter.width);
          painter.dispose();
        }
        final stacked = (widest + 24) * optionen.length > inner;
        final width = stacked ? inner : inner / 3;
        final segmentShape = stacked
            ? RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(rControl),
              )
            : const StadiumBorder();
        return Container(
          padding: const EdgeInsets.all(inset),
          decoration: BoxDecoration(
            color: t.bg,
            borderRadius: BorderRadius.circular(
              stacked ? rControl + inset : rPill,
            ),
          ),
          child: Wrap(
            runSpacing: inset,
            children: [
              for (final (option, label, optionKey) in optionen)
                SizedBox(
                  width: width,
                  child: Semantics(
                    selected: option == value,
                    button: true,
                    child: Material(
                      color: option == value
                          ? t.selectedFill
                          : Colors.transparent,
                      animationDuration: motionDuration(
                        context,
                        const Duration(milliseconds: 160),
                      ),
                      shape: segmentShape,
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        key: ValueKey(optionKey),
                        onTap: () => onChanged(option),
                        focusColor: t.accent.withValues(alpha: 0.20),
                        hoverColor: t.accent.withValues(alpha: 0.10),
                        customBorder: segmentShape,
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 48),
                          alignment: stacked
                              ? AlignmentDirectional.centerStart
                              : Alignment.center,
                          padding: EdgeInsets.symmetric(
                            horizontal: stacked ? 16 : 8,
                            vertical: 12,
                          ),
                          child: Text(
                            label,
                            textAlign: stacked
                                ? TextAlign.start
                                : TextAlign.center,
                            style: AppType.ui(
                              14,
                              weight: option == value
                                  ? FontWeight.w700
                                  : FontWeight.w600,
                              color: option == value ? t.onSelected : t.ink2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Three-segment pill for the display mode.
class SettingsThemeModePill extends StatelessWidget {
  const SettingsThemeModePill({
    super.key,
    required this.mode,
    required this.onChanged,
  });

  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final optionen = <(ThemeMode, String, String)>[
      (ThemeMode.system, l10n.languageSystem, 'settings-theme-mode-system'),
      (
        ThemeMode.light,
        l10n.settingsThemeModeLight,
        'settings-theme-mode-light',
      ),
      (ThemeMode.dark, l10n.settingsThemeModeDark, 'settings-theme-mode-dark'),
    ];
    return _SettingsChoicePill<ThemeMode>(
      value: mode,
      optionen: optionen,
      onChanged: onChanged,
    );
  }
}

/// Three-segment pill for the display language: mirror of
/// [SettingsThemeModePill] with `Locale?` as value. Labels are translations
/// built in `build()`, so they cannot be `static const`.
class SettingsLanguagePill extends StatelessWidget {
  const SettingsLanguagePill({
    super.key,
    required this.value,
    required this.onChanged,
  });

  /// null = system (device language).
  final Locale? value;
  final ValueChanged<Locale?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final optionen = <(Locale?, String, String)>[
      (null, l10n.languageSystem, 'settings-language-system'),
      (const Locale('de'), l10n.languageGerman, 'settings-language-de'),
      (const Locale('en'), l10n.languageEnglish, 'settings-language-en'),
    ];
    return _SettingsChoicePill<Locale?>(
      value: value,
      optionen: optionen,
      onChanged: onChanged,
    );
  }
}

/// Tonal button for a secondary action. `onTap == null` means disabled:
/// dimmed and inert, not hidden. **A11y:** a bare [InkWell] carries neither
/// `isButton` nor the enabled state, so the explicit [Semantics] is what keeps
/// a disabled button from sounding enabled to a screen reader (D11).
class SettingsSecondaryButton extends StatelessWidget {
  const SettingsSecondaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.tone,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;

  /// Tints fill and icon; defaults to the neutral tile tone.
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final ton = tone;
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: Opacity(
        opacity: onTap == null ? 0.4 : 1,
        // A tonal capsule, no outline: the tone tints the fill and the glyph,
        // the label stays `ink` so it reads on every tint.
        child: Material(
          color: ton == null ? t.tile : ton.withValues(alpha: 0.14),
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: 50),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  if (icon != null) ...<Widget>[
                    Icon(icon, size: 18, color: ton ?? t.ink2),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: AppType.ui(
                        14,
                        weight: FontWeight.w700,
                        color: t.ink,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens a legal page in the browser and SAYS SO when that fails (P4-05).
///
/// `launchUrl` reports "no handler" in two shapes: `false`, and — on Android —
/// a thrown `PlatformException('ACTIVITY_NOT_FOUND')`. Reading neither made the
/// tap do visibly nothing on a device without a browser handler (work profile,
/// kiosk, stripped ROM) and sent the exception on to
/// `PlatformDispatcher.onError`, i.e. a Sentry event nobody could tie to a
/// user. Imprint, terms and privacy are § 5 DDG / GDPR Art. 13 and app-store
/// obligations, so the fallback names the URL to type by hand.
///
/// ONE helper for every legal link, not one copy per call site: the auth
/// screen's consent notice fixed this for itself and left the three settings
/// links behind (J2). `auth_screen.dart` still carries its own byte-identical
/// `_open` and should call this instead — it is public and takes nothing but a
/// context and the URL.
Future<void> openLegalLink(BuildContext context, String url) async {
  var geoeffnet = false;
  try {
    geoeffnet =
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    geoeffnet = false;
  }
  if (geoeffnet || !context.mounted) return;
  showAppSnack(
    context,
    context.l10n.authLegalLinkFailed(url),
    icon: Icons.link_off_rounded,
    tone: SnackTone.warning,
  );
}

/// Legal links in the page footer. GDPR Art. 13 / § 5 DDG / app stores: they
/// must stay reachable after login, not only on the auth screen.
class SettingsLegalLinks extends StatelessWidget {
  const SettingsLegalLinks({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          _LegalLink(
            key: const ValueKey('settings-privacy-link'),
            label: l10n.settingsLegalPrivacy,
            url: kPrivacyUrl,
          ),
          const _LegalDot(),
          _LegalLink(
            key: const ValueKey('settings-terms-link'),
            label: l10n.settingsLegalTerms,
            url: kTermsUrl,
          ),
          const _LegalDot(),
          _LegalLink(
            key: const ValueKey('settings-imprint-link'),
            label: l10n.settingsLegalImprint,
            url: kImprintUrl,
          ),
        ],
      ),
    );
  }
}

class _LegalLink extends StatelessWidget {
  const _LegalLink({super.key, required this.label, required this.url});

  final String label;
  final String url;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return TextButton(
      onPressed: () => openLegalLink(context, url),
      style: TextButton.styleFrom(
        foregroundColor: t.ink2,
        minimumSize: Size.zero,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        label,
        style: AppType.ui(12, weight: FontWeight.w500, color: t.ink2),
      ),
    );
  }
}

class _LegalDot extends StatelessWidget {
  const _LegalDot();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Text('·', style: AppType.ui(12, color: t.ink2));
  }
}
