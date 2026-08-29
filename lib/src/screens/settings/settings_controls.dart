import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/legal_links.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/motion.dart';
// Only for [SelectionTone]: these pills are a clone of [SegmentedPill] and
// must speak the same selection language, not a second one.
import '../../widgets/design/controls.dart';

// ---------------------------------------------------------------------------
// Controls of the settings page. Package-local clones because the shared
// library covers none of these four cases: a key on the inner field, keys per
// pill option, an outline button style, and explanatory rows. Once the library
// catches up, they can go.
// ---------------------------------------------------------------------------

/// A row with a right-aligned number field: label, value, unit.
///
/// [fieldKey] sits on the inner [TextField] because tests read
/// `widget<TextField>(...).controller`. The error text is a separate [Text]
/// below the row, or the range message would appear twice and break
/// `findsOneWidget`. **A11y:** [MergeSemantics] folds the three siblings into
/// one node.
class SettingsNumberRow extends StatelessWidget {
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

  /// C1: the allowed range, shown once the typed value leaves it. The
  /// `digitsOnly` formatter filters characters only; the caller checks range.
  final String? errorText;

  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final hatFehler = errorText != null;
    // Field width follows the system font but stays capped; at textScaler 2.0
    // it would otherwise push the label out of the row.
    final feldBreite =
        MediaQuery.textScalerOf(context).scale(72).clamp(72.0, 140.0);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
      child: MergeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    label,
                    style:
                        AppType.ui(13.5, weight: FontWeight.w600, color: t.ink),
                  ),
                ),
                SizedBox(
                  width: feldBreite,
                  child: TextField(
                    key: fieldKey,
                    controller: controller,
                    // Without this the cursor fade never settles and
                    // `pumpAndSettle` hangs.
                    cursorOpacityAnimates: false,
                    cursorColor: t.accent,
                    textAlign: TextAlign.right,
                    keyboardType: TextInputType.number,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    onChanged: onChanged,
                    style: AppType.display(
                      17,
                      weight: FontWeight.w700,
                      color: hatFehler ? t.danger : t.ink,
                    ),
                    // All border slots off and unfilled, or the app's
                    // inputDecorationTheme paints a capsule inside the row.
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
                const SizedBox(width: 7),
                Text(
                  suffix,
                  style: AppType.ui(12, weight: FontWeight.w600, color: t.ink2),
                ),
              ],
            ),
            if (hatFehler) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                errorText!,
                style:
                    AppType.ui(11.5, weight: FontWeight.w500, color: t.danger),
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
    // boxes actually sit) 12 px text measures warning 4.20:1, danger 4.48:1
    // and even the quiet ink2 4.48:1, all below AA. `ink` gives 12.9-14.7:1.
    // Unboxed notes keep the tone as text color: without a fill it carries
    // (warning 4.76:1 on bg, 5.38:1 on surf), and the tone IS the signal
    // there.
    final textFarbe = boxed ? t.ink : ton;

    final zeile = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 15, color: ton),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            text,
            style: AppType.ui(
              12,
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
        padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
        child: zeile,
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ton.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(rControl),
        border: Border.all(color: ton.withValues(alpha: 0.32)),
      ),
      child: zeile,
    );
  }
}

/// Transparent tap margin above and below a segment. The drawn capsule is
/// ~22 px tall (11 px label + 2x5 padding), which was the whole target; 12 px
/// of invisible margin per side lifts it over the 44 px floor without moving
/// a single pixel of paint — the same trick [AppToggle] uses.
const double _segmentSaum = 12;

/// Inset of the PAINTED pill inside that enlarged target. The capsule keeps
/// the 3 px gutter it always had ([_segmentSaum] - 3), so the pill still
/// measures capsule + 6 in height no matter how the label scales.
const double _pillSaum = _segmentSaum - 3;

/// Shared rendering base of the settings pills: geometry of [SegmentedPill],
/// plus test keys per option and a width cap so segments wrap at textScaler
/// 2.0 instead of blowing up the row.
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
    return ConstrainedBox(
      constraints:
          BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.55),
      // The tap floor lives in transparent margins around the segments, so
      // the pill must NOT grow with it — it is painted as a background layer
      // inset by exactly those margins and keeps its compact geometry.
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: _pillSaum),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: t.tile,
                  borderRadius: BorderRadius.circular(9),
                ),
              ),
            ),
          ),
          Padding(
            // The 3 px side gutter of the old `EdgeInsets.all(3)`; the
            // vertical half of it is inside [_pillSaum].
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Wrap(
              // No runSpacing: the transparent margins already separate the
              // rows once the labels wrap at textScaler 2.0.
              children: <Widget>[
                for (final (wert, beschriftung, schluessel) in optionen)
                  GestureDetector(
                    key: ValueKey<String>(schluessel),
                    // Opaque, or the margin is not part of the target: the
                    // default `deferToChild` ends it at the drawn capsule.
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onChanged(wert),
                    // Outside the padding, so the semantics node covers the
                    // whole 44 px target and not just the label.
                    child: Semantics(
                      selected: wert == value,
                      button: true,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: _segmentSaum,
                        ),
                        child: AnimatedContainer(
                          // DESIGN_REFACTOR §5: respects "reduce motion".
                          duration: motionDuration(
                            context,
                            const Duration(milliseconds: 160),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 11,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            // App-wide selection language ([SelectionTone]):
                            // `forest` measured 1.10:1 against this `tile`
                            // track in dark mode.
                            color: wert == value
                                ? t.selectedFill
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            beschriftung,
                            style: AppType.ui(
                              11,
                              weight: FontWeight.w600,
                              color: wert == value ? t.onSelected : t.ink2,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
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
      (ThemeMode.light, l10n.settingsThemeModeLight, 'settings-theme-mode-light'),
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

/// Outline button for a secondary action. `onTap == null` means disabled:
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

  /// Colors border, icon and text; defaults to the quiet card line.
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
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(18),
            child: Container(
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: 50),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: ton == null ? t.line : ton.withValues(alpha: 0.45),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  if (icon != null) ...<Widget>[
                    Icon(icon, size: 17, color: ton ?? t.ink2),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: AppType.ui(
                        14,
                        weight: FontWeight.w700,
                        color: ton ?? t.ink,
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
      onPressed: () => launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      ),
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
