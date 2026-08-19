import 'package:flutter/material.dart';

import '../../theme/app_tokens.dart';
import '../common/motion.dart';

// ---------------------------------------------------------------------------
// BEDIENELEMENTE — Icon-Knopf, Icon-Kachel, Schalter, Segment-Pille,
// Filter-Chip, Primaeraktion, Navigationsleiste.
//
// Material traegt Verhalten und Semantik (InkWell, Semantics), die Tokens
// tragen die Pixel. Geometrie 1:1 aus der Design-Vorlage.
//
// A11y-Regel fuer diese Datei (DESIGN_REFACTOR §5): jede Dauer laeuft durch
// [motionDuration]. Eine fest verdrahtete `Duration` ignoriert den System-
// Schalter „Bewegung reduzieren" — und diese Bausteine stehen auf JEDEM
// Screen, der Schalter waere damit praktisch wirkungslos.
// ---------------------------------------------------------------------------

/// Quadratischer 34er-Knopf mit Rand — Zurueck, Schliessen, Menue.
class SquareIconButton extends StatelessWidget {
  const SquareIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.semanticLabel,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // Sichtbar bleiben die 34 px des Entwurfs — tippbar sind 44 px.
    // Die Vorlage macht die ganze Kachel zur Trefferflaeche und landet damit
    // unter der 44-px-Mindestgroesse, die fuer jeden Zurueck-Knopf und jedes
    // Kopfzeilen-Icon der App gilt. Der Zuwachs ist transparent: er liegt
    // ausserhalb der gezeichneten Flaeche.
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: semanticLabel,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(rChip),
            child: Center(
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: t.surf,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: t.line),
                ),
                child: Icon(icon, size: 17, color: t.ink2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Schwach getoente Kachel hinter einem Icon (Listenzeilen, Statistiken).
class IconTile extends StatelessWidget {
  const IconTile({super.key, required this.icon, this.color, this.size = 34});

  final IconData icon;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color == null ? t.tile : color!.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(11),
      ),
      // Nicht die volle Kategoriefarbe: der Glyph saesse dann auf seiner
      // EIGENEN 15-%-Tint und traegt im Hell-Modus rund 2.2:1. Genau dafuer
      // ist [AppTokens.readableOnTint] gebaut — [MealAvatar] und
      // [SlotSelector] fahren dieselbe Korrektur, diese Kachel war die letzte
      // Stelle ohne. Ohne Farbe liegt der Glyph auf `tile` (fast farblos) und
      // bleibt `ink`.
      child: Icon(
        icon,
        size: 16,
        color: color == null ? t.ink : t.readableOnTint(color!),
      ),
    );
  }
}

/// Der Schalter der neuen Sprache: Kapsel mit wanderndem Knauf.
class AppToggle extends StatelessWidget {
  const AppToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  /// Gesperrter Schalter (Settings-Sheet zeigt Schalter, die an eine noch
  /// fehlende Berechtigung gebunden sind): gedaempft und taub. Bewusst kein
  /// `onChanged: null`, damit der Aufrufer den Callback behalten kann.
  final bool enabled;

  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final motion = motionDuration(context, const Duration(milliseconds: 180));
    return Semantics(
      toggled: value,
      enabled: enabled,
      label: semanticLabel,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: GestureDetector(
          // Opak, damit der durchsichtige Saum der Trefferflaeche wirklich
          // traegt — mit dem Standard `deferToChild` endete das Ziel exakt an
          // der gezeichneten Kapsel.
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? () => onChanged(!value) : null,
          // Sichtbar bleiben die 46x27 des Entwurfs — tippbar sind 44 px hoch,
          // dieselbe Untergrenze, die [SquareIconButton] weiter oben schon
          // haelt. Die Kapsel haengt als `trailing` in Einstellungszeilen und
          // war dort mit 27 px das kleinste Ziel der ganzen Seite. Die Zeile
          // waechst dadurch mit; das ist der Preis, und er faellt nur dort an,
          // wo wirklich ein Schalter steht.
          child: SizedBox(
            width: 46,
            height: 44,
            child: Center(
              child: AnimatedContainer(
                duration: motion,
                curve: Curves.easeOut,
                width: 46,
                height: 27,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: value ? t.forest : t.tile,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: AnimatedAlign(
                  duration: motion,
                  curve: Curves.easeOut,
                  alignment:
                      value ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    width: 21,
                    height: 21,
                    decoration: BoxDecoration(
                      color: value ? t.lime : t.surf,
                      shape: BoxShape.circle,
                      border: value ? null : Border.all(color: t.line),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Zwei bis drei sich ausschliessende Kurzoptionen (kg/lb, Woche/Monat).
class SegmentedPill extends StatelessWidget {
  const SegmentedPill({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<String> options;
  final String selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final motion = motionDuration(context, const Duration(milliseconds: 160));
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: t.tile,
        borderRadius: BorderRadius.circular(9),
      ),
      // Abweichung von der Vorlage: dort steht hier eine Row. Ein Wrap sieht
      // bei normaler Schrift identisch aus, bricht bei textScaler 2.0 aber in
      // eine zweite Zeile um, statt die Zeile zu sprengen.
      child: Wrap(
        spacing: 0,
        runSpacing: 3,
        children: <Widget>[
          for (final option in options)
            // Wie [FilterChipPill]: ein blanker GestureDetector traegt weder
            // `isButton` noch die Auswahl. Der Klon in den Einstellungen
            // (SettingsThemeModePill) tut das schon — hier fehlte es.
            Semantics(
              button: true,
              selected: option == selected,
              child: GestureDetector(
                onTap: () => onChanged(option),
                child: AnimatedContainer(
                  duration: motion,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                  decoration: BoxDecoration(
                    color: option == selected ? t.forest : Colors.transparent,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    option,
                    style: AppType.ui(
                      11,
                      weight: FontWeight.w600,
                      color: option == selected ? t.onForest : t.ink2,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Rechteckige Filter-Pille fuer waagerechte Chip-Leisten.
class FilterChipPill extends StatelessWidget {
  const FilterChipPill({
    super.key,
    required this.label,
    required this.selected,
    this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // Die Auswahl steckt allein in Fuell- und Schriftfarbe. Ohne `selected`
    // im Semantik-Baum kann ein Screenreader-Nutzer in der Filterleiste der
    // Rezepte nicht feststellen, welcher Filter gerade greift — dieselbe
    // Zusicherung, die [AppNavBar] fuer die Tabs schon traegt.
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? t.forest : t.surf,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(11),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: selected ? Colors.transparent : t.line),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
            child: Text(
              label,
              style: AppType.ui(
                12,
                weight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? t.onForest : t.ink2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Die breite Hauptaktion am Fuss eines Screens („Essen eintragen").
///
/// Die Beschriftung nimmt [AppTokens.bg]: `ink` und `bg` sind in beiden Modi
/// die Gegenpole zueinander, und auch auf `danger` (hell im Dunkelmodus,
/// dunkel im Hellmodus) traegt `bg` deshalb immer den lesbaren Kontrast.
class PrimaryActionButton extends StatelessWidget {
  const PrimaryActionButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.destructive = false,
    this.height = 54,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool destructive;
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final fill = destructive ? t.danger : t.ink;
    // Ein blankes InkWell traegt WEDER `isButton` NOCH einen Enabled-Zustand:
    // ein Screenreader kuendigte die Hauptaktion jedes Screens nur als Text
    // an, und ein gesperrtes „Speichern" klang wie ein normaler Knopf, der
    // nichts tut. Onboarding (onboarding_screen.dart:315) und Einstellungen
    // (settings_screen.dart:564) hatten beide dieselbe Huelle lokal
    // nachgebaut und in ihren Berichten hierher verwiesen — jetzt steht sie
    // an EINER Stelle. `onTap == null` ist app-weit die Sperr-Konvention.
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: Material(
        color: fill,
        borderRadius: BorderRadius.circular(18),
        elevation: 0,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: ConstrainedBox(
            // Abweichung von der Vorlage (SizedBox(height: 54)): bei
            // textScaler 2.0 waere die Beschriftung hoeher als der Knopf.
            constraints: BoxConstraints(minHeight: height),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  if (icon != null) ...<Widget>[
                    Icon(icon, size: 18, color: t.bg),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style:
                          AppType.ui(15, weight: FontWeight.w700, color: t.bg),
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

/// Ein Eintrag der [AppNavBar].
@immutable
class AppNavItem {
  const AppNavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    String? keyId,
  }) : keyId = keyId ?? label;

  final IconData icon;
  final IconData activeIcon;

  /// Das sichtbare Label — laeuft ueber die ARB und wird uebersetzt.
  final String label;

  /// Traegt den Testschluessel (`ValueKey('nav-$keyId')`). Bleibt DEUTSCH,
  /// auch wenn [label] uebersetzt wird — Keys sind API (DESIGN_REFACTOR §6).
  final String keyId;
}

/// Die untere Navigationsleiste — Lime-Kapsel um das aktive Icon.
class AppNavBar extends StatelessWidget {
  const AppNavBar({
    super.key,
    required this.index,
    required this.onChanged,
    required this.items,
  });

  final int index;
  final ValueChanged<int> onChanged;
  final List<AppNavItem> items;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final bottomInset = MediaQuery.of(context).padding.bottom;
    // Die Vorgaengerleiste (widgets/app_shell/eatova_bottom_nav.dart:74) lief
    // schon durch motionDuration — beim Umzug auf diese Leiste ging das
    // verloren.
    final motion = motionDuration(context, const Duration(milliseconds: 180));

    return Container(
      decoration: BoxDecoration(
        color: t.surf.withValues(alpha: 0.94),
        border: Border(top: BorderSide(color: t.line)),
      ),
      // Flacher als die Vorlage (Nutzer-Wunsch 2026-08-10): dort summierten
      // sich 10/10-Aussenpolsterung, 4er-Innenpolsterung, eine 30 px hohe
      // Icon-Kapsel und 5 px Abstand zur Beschriftung auf ~76 px. Die Leiste
      // liegt auf JEDEM Screen und nimmt diese Hoehe dem Inhalt weg. Die
      // Trefferflaeche bleibt dabei ueber 44 px — das ist die Untergrenze,
      // unter die diese Kuerzung nicht gehen darf.
      padding: EdgeInsets.fromLTRB(10, 6, 10, 6 + bottomInset),
      child: Row(
        children: List<Widget>.generate(items.length, (i) {
          final item = items[i];
          final active = i == index;
          return Expanded(
            child: Semantics(
              selected: active,
              button: true,
              label: item.label,
              child: InkWell(
                key: ValueKey<String>('nav-${item.keyId}'),
                onTap: () => onChanged(i),
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      AnimatedContainer(
                        duration: motion,
                        curve: Curves.easeOut,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: active ? t.lime : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          active ? item.activeIcon : item.icon,
                          size: 19,
                          color: active ? t.onLime : t.ink2,
                        ),
                      ),
                      const SizedBox(height: 3),
                      // Die Beschriftung steht schon als Semantics-Label am
                      // Item; ohne ExcludeSemantics liest der Screenreader
                      // „Rezepte Rezepte".
                      //
                      // Abweichung von der Vorlage: harte Einzeiligkeit. Bei
                      // textScaler 2.0 passt „Rezepte" sonst nicht mehr in
                      // ein Drittel der Leiste.
                      ExcludeSemantics(
                        child: Text(
                          item.label,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: AppType.ui(
                            10,
                            weight: active ? FontWeight.w700 : FontWeight.w500,
                            color: active ? t.ink : t.ink2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
