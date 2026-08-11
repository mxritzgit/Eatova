import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_tokens.dart';
import 'controls.dart';

// ---------------------------------------------------------------------------
// ZEILEN — Seitenkopf, Einstellungsgruppe, Einstellungszeile.
//
// Geometrie 1:1 aus der Design-Vorlage; Farben aus [AppTokens].
// ---------------------------------------------------------------------------

/// Der Kopf einer Unterseite: Zurueck-Knopf plus Titel.
///
/// [title] setzt einen kleinen, mittigen Titel (Profil), [large] einen grossen
/// linksbuendigen (Einstellungen). Beides zugleich zu setzen ist sinnlos —
/// [large] gewinnt.
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    this.title,
    this.large,
    this.trailing,
    this.onBack,
    this.backKey,
  });

  final String? title;
  final String? large;
  final Widget? trailing;

  /// Standard ist [NavigatorState.maybePop]; Screens mit ungespeicherten
  /// Aenderungen haengen hier ihre Rueckfrage ein.
  final VoidCallback? onBack;

  /// Wandert an den Zurueck-Knopf (Tests tippen z.B. `profile-close`).
  final Key? backKey;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      children: <Widget>[
        SquareIconButton(
          key: backKey,
          icon: Icons.chevron_left_rounded,
          onTap: onBack ?? () => Navigator.of(context).maybePop(),
          // Umlaut, kein „ue": ein Semantics-Label ist GESPROCHENER Text —
          // TalkBack liest „Zurueck" als „zurookk" vor. Gleiche Korrektur wie
          // in today_day_strip.dart („Tag zurück") und today_screen.dart
          // („Profil öffnen"). Konsolidiert mit onboarding_screen.dart: der
          // Onboarding-Zurueck-Knopf traegt denselben deutschen Text —
          // [onboardingBackSemanticLabel] wiederverwendet statt einen
          // gleichbedeutenden zweiten Key (z.B. commonBackSemantics)
          // anzulegen.
          semanticLabel: context.l10n.onboardingBackSemanticLabel,
        ),
        if (large != null) ...<Widget>[
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              large!,
              style: AppType.display(28, color: t.ink, height: 1.1),
            ),
          ),
        ] else
          Expanded(
            child: Center(
              child: Text(
                title ?? '',
                textAlign: TextAlign.center,
                style: AppType.ui(13, weight: FontWeight.w600, color: t.ink),
              ),
            ),
          ),
        if (trailing != null)
          trailing!
        else if (large == null)
          // Gegengewicht zum Zurueck-Knopf, damit der mittige Titel wirklich
          // mittig steht.
          const SizedBox(width: 34),
      ],
    );
  }
}

/// Karte mit Versalien-Beschriftung darueber; Kinder werden durch 1-px-Linien
/// getrennt.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    required this.label,
    required this.children,
    this.labelColor,
    this.borderColor,
  });

  final String label;
  final List<Widget> children;
  final Color? labelColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          child: Text(label, style: AppType.eyebrow(labelColor ?? t.ink2)),
        ),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: t.surf,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: borderColor ?? t.line),
          ),
          child: Column(
            children: <Widget>[
              for (var i = 0; i < children.length; i++) ...<Widget>[
                if (i > 0) Divider(height: 1, thickness: 1, color: t.line),
                children[i],
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
      ],
    );
  }
}

/// Eine Zeile in einer [SettingsGroup].
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.subtitle,
    this.value,
    this.leading,
    this.trailing,
    this.chevron = true,
    this.onTap,
    this.titleColor,
  });

  final String title;
  final String? subtitle;

  /// Rechtsbuendiger Zustandstext („Metrisch", „An").
  final String? value;

  final Widget? leading;
  final Widget? trailing;
  final bool chevron;
  final VoidCallback? onTap;

  /// Faerbt den Titel um (z.B. [AppTokens.danger] fuer zerstoerende Zeilen)
  /// und zieht ihn dabei eine Gewichtsstufe hoeher.
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: <Widget>[
            if (leading != null) ...<Widget>[leading!, const SizedBox(width: 12)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: AppType.ui(
                      13.5,
                      weight:
                          titleColor == null ? FontWeight.w600 : FontWeight.w700,
                      color: titleColor ?? t.ink,
                    ),
                  ),
                  if (subtitle != null) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: AppType.ui(11.5, color: t.ink2)),
                  ],
                ],
              ),
            ),
            // Abweichung von der Vorlage: dort steht der Wert starr in der
            // Zeile. Bei textScaler 2.0 braucht er Nachgiebigkeit, sonst
            // sprengt eine lange E-Mail-Adresse die Zeile.
            if (value != null)
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Text(
                    value!,
                    textAlign: TextAlign.right,
                    style:
                        AppType.ui(12.5, weight: FontWeight.w500, color: t.ink2),
                  ),
                ),
              ),
            if (trailing != null)
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: trailing!,
              ),
            if (chevron)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 17,
                  color: t.ink2,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
