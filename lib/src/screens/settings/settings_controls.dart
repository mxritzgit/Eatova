import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/legal_links.dart';
import '../../theme/app_tokens.dart';
import '../../widgets/common/motion.dart';

// ---------------------------------------------------------------------------
// Bedienelemente der Einstellungs-Seite.
//
// Alles hier ist paket-lokal, weil die gemeinsame Bibliothek
// (lib/src/widgets/design/**) genau diese vier Faelle heute nicht abdeckt:
//
//   * SheetField legt seinen Key auf den Wrapper — `settings_discard_test`
//     liest aber `widget<TextField>(byKey(...))`. Deshalb [SettingsNumberRow]
//     mit eigenem [SettingsNumberRow.fieldKey] am inneren Feld.
//   * SegmentedPill vergibt keine Keys an die einzelnen Optionen — deshalb
//     [SettingsThemeModePill].
//   * PrimaryActionButton kennt keinen Sekundaer-/Umriss-Stil — deshalb
//     [SettingsSecondaryButton].
//   * Fuer die erklaerenden Zeilen unter einer Gruppe gibt es kein Pendant —
//     deshalb [SettingsNote] (Nachfolger von `_InfoNote`).
//
// Sobald die Bibliothek nachzieht, koennen die Klone ersatzlos weg.
// ---------------------------------------------------------------------------

/// Eine Zeile mit rechtsbuendigem Zahlenfeld: „Gewicht ⟶ 78 kg".
///
/// Der [fieldKey] liegt bewusst auf dem inneren [TextField] und nicht auf
/// dieser Zeile: Tests tippen ueber `enterText` hinein **und** lesen
/// `widget<TextField>(...).controller`. Ein Key auf dem Wrapper wuerde nur
/// Ersteres ueberleben.
///
/// Der Fehlertext steht als eigenes [Text] UNTER der Zeile statt in
/// `InputDecoration.errorText` — sonst stuende der Bereichstext zweimal im
/// Baum (einmal als Feldfehler, einmal in der Sammelmeldung am Seitenfuss)
/// und `findsOneWidget` braeche.
///
/// **A11y:** Das alte `_SettingsField` gab dem Feld ueber
/// `InputDecoration.labelText` einen echten Semantik-Namen; hier stehen
/// Beschriftung, Feld und Einheit als drei Geschwister nebeneinander, und der
/// Knoten des Feldes traegt sonst nur seinen Wert („78") — wer mit
/// Screenreader direkt ins Feld springt, wuesste nicht, welches es ist.
/// [MergeSemantics] fasst Beschriftung, Wert, Einheit und Fehlertext deshalb
/// zu einem Knoten zusammen („Gewicht, kg, 30–300 kg (ganze Zahl)" mit dem
/// Wert 78).
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

  /// Einheit rechts vom Feld („kg", „cm", „kcal", „/Tag").
  final String suffix;

  final TextEditingController controller;
  final Key fieldKey;

  /// C1: der erlaubte Bereich, sobald der getippte Wert ihn verlaesst. Der
  /// `digitsOnly`-Formatter filtert nur Zeichen — den Wertebereich prueft der
  /// Aufrufer.
  final String? errorText;

  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final hatFehler = errorText != null;
    // Die Feldbreite waechst mit der Systemschrift (Vorbild MacroBar), bleibt
    // aber gedeckelt — sonst draengt sie bei textScaler 2.0 die Beschriftung
    // aus der Zeile.
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
                    // Ohne das laeuft der Cursor-Fade als Dauer-Animation und
                    // `pumpAndSettle` kaeme nie zur Ruhe.
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
                    // Alle fuenf Rahmen-Slots aus, `filled: false`, kein
                    // Innenabstand: sonst malt das inputDecorationTheme der App
                    // eine gefuellte Kapsel IN die Zeile.
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

/// Erklaerende Zeile mit Icon — Nachfolger des `_InfoNote` aus dem Sheet.
///
/// Ohne [boxed] ist sie ein normales Kind einer [SettingsGroup] (die Karte
/// zeichnet den Rahmen); mit [boxed] traegt sie eine eigene, im Ton getoente
/// Flaeche und steht damit frei auf der Seite.
class SettingsNote extends StatelessWidget {
  const SettingsNote(
    this.text, {
    super.key,
    this.tone,
    this.icon = Icons.info_outline_rounded,
    this.boxed = false,
  });

  final String text;

  /// Farbe von Icon und Text; Standard ist der ruhige [AppTokens.ink2].
  /// [AppTokens.warning] und [AppTokens.danger] heben Hinweise heraus, die
  /// eine Handlung nach sich ziehen.
  final Color? tone;

  final IconData icon;
  final bool boxed;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final ton = tone ?? t.ink2;

    final zeile = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 15, color: ton),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            text,
            style: AppType.ui(12, weight: FontWeight.w500, color: ton, height: 1.4),
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

/// Die Drei-Segment-Pille fuer den Anzeige-Modus.
///
/// Geometrisch identisch zu [SegmentedPill] aus der Bibliothek, nur mit
/// Testschluesseln an den einzelnen Optionen. Die Breite ist zusaetzlich
/// gedeckelt, damit die drei Segmente bei textScaler 2.0 in eine zweite
/// Zeile umbrechen statt die Einstellungszeile zu sprengen.
class SettingsThemeModePill extends StatelessWidget {
  const SettingsThemeModePill({
    super.key,
    required this.mode,
    required this.onChanged,
  });

  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;

  static const List<(ThemeMode, String, String)> _optionen =
      <(ThemeMode, String, String)>[
    (ThemeMode.system, 'System', 'settings-theme-mode-system'),
    (ThemeMode.light, 'Hell', 'settings-theme-mode-light'),
    (ThemeMode.dark, 'Dunkel', 'settings-theme-mode-dark'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ConstrainedBox(
      constraints:
          BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.55),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: t.tile,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Wrap(
          runSpacing: 3,
          children: <Widget>[
            for (final (modus, beschriftung, schluessel) in _optionen)
              GestureDetector(
                key: ValueKey<String>(schluessel),
                onTap: () => onChanged(modus),
                child: AnimatedContainer(
                  // DESIGN_REFACTOR §5: respektiert „Bewegung reduzieren"
                  // (Klon von SegmentedPill, dort ebenso).
                  duration:
                      motionDuration(context, const Duration(milliseconds: 160)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                  decoration: BoxDecoration(
                    color: modus == mode ? t.forest : Colors.transparent,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Semantics(
                    selected: modus == mode,
                    button: true,
                    child: Text(
                      beschriftung,
                      style: AppType.ui(
                        11,
                        weight: FontWeight.w600,
                        color: modus == mode ? t.onForest : t.ink2,
                      ),
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

/// Umriss-Knopf fuer eine zweite, nachgeordnete Aktion („Systemeinstellungen
/// oeffnen"). Bis 2026-08-10 trug er auch „Tagesdaten zuruecksetzen" — die
/// Aktion ist auf Nutzer-Entscheid ersatzlos entfallen.
///
/// `onTap == null` heisst gesperrt: gedaempft und taub, nicht unsichtbar —
/// dieselbe Loesung, die [SheetScaffold.actionEnabled] fuer die Hauptaktion
/// waehlt.
///
/// **A11y:** Der Vorgaenger war ein `OutlinedButton.icon` und trug damit
/// `isButton` und den Enabled-Zustand im Semantik-Baum; ein blosses [InkWell]
/// traegt beides nicht. Ohne das eigene [Semantics] klaenge ein gesperrter
/// Knopf fuer einen Screenreader wie ein normaler, nur eben ohne Wirkung —
/// genau die Sorte stille Luege, gegen die D11 geschrieben wurde.
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

  /// Faerbt Rand, Icon und Schrift (z.B. [AppTokens.warning] fuer den Weg in
  /// die Systemeinstellungen). Standard ist die ruhige Kartenlinie.
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

/// Datenschutz · AGB · Impressum am Seitenfuss.
///
/// DSGVO Art. 13 / § 5 DDG / App-Store: die Rechtsseiten muessen auch NACH
/// dem Login erreichbar sein, nicht nur auf dem Auth-Screen.
class SettingsLegalLinks extends StatelessWidget {
  const SettingsLegalLinks({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          _LegalLink(
            key: ValueKey('settings-privacy-link'),
            label: 'Datenschutz',
            url: kPrivacyUrl,
          ),
          _LegalDot(),
          _LegalLink(
            key: ValueKey('settings-terms-link'),
            label: 'AGB',
            url: kTermsUrl,
          ),
          _LegalDot(),
          _LegalLink(
            key: ValueKey('settings-imprint-link'),
            label: 'Impressum',
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
