import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/model_limits.dart';
import '../../theme/app_tokens.dart';
import '../common/motion.dart';

/// Gemeinsames Item-Widget fuer Suchtreffer, Favoriten und letzte
/// Mahlzeiten im AddMealSheet.
///
/// Collapsed = schlanke Zeile (Avatar + Titel + Subtitle + Chevron).
/// Tap → expandiert in einen Stepper-Body mit Gramm-Anpassung und einem
/// einzigen "Hinzufuegen"-Button. Nach dem Hinzufuegen collapsed das Item
/// und zeigt einen gruenen Check als Trailing.
class MealSuggestionItem extends StatefulWidget {
  const MealSuggestionItem({
    super.key,
    required this.result,
    required this.expanded,
    required this.onTap,
    required this.onAdd,
    this.imageUrl,
    this.fallbackIcon = Icons.fastfood_outlined,
    this.accent,
    this.justAdded = false,
    this.onRemove,
    this.addButtonKey,
    this.isFavorite = false,
    this.onToggleFavorite,
    this.favoriteButtonKey,
  });

  final MealAnalysisResult result;
  final bool expanded;
  final VoidCallback onTap;
  final ValueChanged<MealAnalysisResult> onAdd;
  final String? imageUrl;
  final IconData fallbackIcon;

  /// Akzent des Kaertchens. Null -> [AppTokens.accent]; eine Konstante als
  /// Default ginge nicht mehr, seit die Farbe vom Anzeige-Modus abhaengt.
  final Color? accent;

  final bool justAdded;
  final VoidCallback? onRemove;
  final Key? addButtonKey;

  /// Ob dieses Item aktuell favorisiert ist (Herz gefüllt, lime).
  final bool isFavorite;

  /// Optionaler Favoriten-Toggle im Header. Null → kein Herz-Button
  /// (bestehende Aufrufer bleiben unverändert).
  final ValueChanged<MealAnalysisResult>? onToggleFavorite;
  final Key? favoriteButtonKey;

  @override
  State<MealSuggestionItem> createState() => _MealSuggestionItemState();
}

class _MealSuggestionItemState extends State<MealSuggestionItem> {
  static const int _step = 10;

  /// Obergrenze des **Reglers** — eine reine Anzeigegrenze, kein Wertelimit.
  ///
  /// Ein Slider muss Enden haben; 1..10000 g darauf abzubilden macht ihn
  /// unbedienbar (ein Pixel waere ~30 g). Die Zahl begrenzt deshalb nur, wie
  /// weit der Daumen kommt. Groessere Portionen bleiben ueber Tippfeld und
  /// Stepper erreichbar, und sobald der Wert darueber liegt, waechst das
  /// Fenster mit (siehe [_sliderMaxGrams]) — der Regler zeigt dann eine
  /// gueltige Position statt still zurueckzuklemmen.
  static const int _sliderWindowGrams = 1000;

  /// Der zuletzt **gueltige** Wert. Eine unplausible Tippeingabe aendert ihn
  /// nicht (siehe [_onGramsTextChanged]).
  late int _grams;
  late TextEditingController _gramsController;

  /// Im Feld steht etwas, das keine plausible Portion ist. Dann ist
  /// "Hinzufuegen" gesperrt und ein Hinweis sichtbar — abgelehnt, nicht
  /// stillschweigend verbogen.
  bool _gramsInvalid = false;

  @override
  void initState() {
    super.initState();
    _grams = _fromForeignSource(widget.result.estimatedGrams);
    _gramsController = TextEditingController(text: _grams.toString());
  }

  @override
  void didUpdateWidget(covariant MealSuggestionItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.result.estimatedGrams != widget.result.estimatedGrams) {
      _grams = _fromForeignSource(widget.result.estimatedGrams);
      _gramsInvalid = false;
      _syncControllerText();
    }
  }

  @override
  void dispose() {
    _gramsController.dispose();
    super.dispose();
  }

  /// Die Startportion kommt aus Modellantwort, OFF oder Favoriten-Cache —
  /// eine Fremdquelle, die niemand nachfragen kann. Dafuer ist Klemmen
  /// richtig (`model_limits.dart`, Abschnitt "Clamp oder Ablehnung?"), und
  /// zwar mit **derselben** Funktion, die auch `adjustedToGrams` benutzt.
  static int _fromForeignSource(int grams) => clampPortionGrams(grams);

  /// Rechtes Ende des Reglers. Waechst mit, wenn die aktuelle Portion ueber
  /// dem Anzeigefenster liegt — sonst zeigte der Daumen bei 1200 g auf 1000.
  int get _sliderMaxGrams =>
      _grams > _sliderWindowGrams ? _grams : _sliderWindowGrams;

  void _syncControllerText() {
    final next = _grams.toString();
    if (_gramsController.text != next) {
      _gramsController.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    }
  }

  /// Stepper und Regler sind Flaechen mit Enden: wer dagegen zieht, hat keine
  /// Zahl behauptet, sondern an die Kante gefasst. Klemmen ist hier also
  /// keine stille Verfaelschung — im Gegensatz zur Tippeingabe.
  void _setGrams(int value) {
    final geklemmt = clampPortionGrams(value);
    if (geklemmt == _grams && !_gramsInvalid) return;
    setState(() {
      _grams = geklemmt;
      _gramsInvalid = false;
    });
    _syncControllerText();
  }

  void _bumpGrams(int delta) => _setGrams(_grams + delta);

  /// Getippte Portionen werden **abgelehnt statt geklemmt**.
  ///
  /// `FilteringTextInputFormatter.digitsOnly` ist ein Typ-, kein
  /// Wertebereichs-Guard. Wer 12000 tippt, bekam bisher lautlos 1000 geloggt
  /// — genau die stille Verfaelschung, vor der der Kopf von
  /// `model_limits.dart` warnt. Der zuletzt gueltige Wert bleibt stehen, der
  /// Knopf wird gesperrt, und der Nutzer sieht warum.
  void _onGramsTextChanged(String value) {
    final parsed = int.tryParse(value.trim());
    final gueltig = parsed != null && isPlausiblePortionGrams(parsed);
    setState(() {
      _gramsInvalid = !gueltig;
      if (gueltig) _grams = parsed;
    });
  }

  /// Die Mahlzeit auf der aktuell eingestellten Portion — **eine** Instanz
  /// fuer Vorschau und Speicherpfad.
  ///
  /// Genau hier sass B1: die Vorschau rechnete dichte-zuerst
  /// (`kcalPer100G * g / 100`), waehrend [MealAnalysisResult.adjustedToGrams]
  /// seit Welle 2 `caloriesKcal` als autoritativ behandelt. Bei einem
  /// Apfelkuchen mit {420 kcal, 150 g, 52 kcal/100 g} zeigte die Zeile ueber
  /// dem Knopf 78 kcal, geloggt wurden 420 — Faktor 5,4 zwischen Anzeige und
  /// Tagebuch.
  ///
  /// Delegieren statt die Formel abzuschreiben (wie in
  /// `meal_widgets_adjust.dart`): eine Kopie kann wieder auseinanderlaufen,
  /// und `adjustedToGrams` bringt die Clamps (1..10000 g, 0..10000 kcal) und
  /// die Makro-Skalierung gleich mit.
  ///
  /// Bei unveraenderter Portion bleibt das Original stehen — dank der
  /// Invariante `adjustedToGrams(estimatedGrams).caloriesKcal == caloriesKcal`
  /// ist das derselbe Zahlenwert, nur ohne `isAdjusted` und ohne
  /// umgeschriebene `portionNotes`.
  MealAnalysisResult get _adjusted => _grams == widget.result.estimatedGrams
      ? widget.result
      : widget.result.adjustedToGrams(_grams);

  @override
  Widget build(BuildContext context) {
    // EINE Instanz pro Build: die Vorschau zeigt sie an, der Knopf reicht
    // genau dieses Objekt weiter. Nicht zwei Aufrufe desselben Getters —
    // dann waere "dieselbe Zahl" wieder nur eine Zusicherung statt einer
    // Tatsache. Jede Portionsaenderung laeuft ueber setState, der Knopf
    // haelt also nie ein veraltetes Ergebnis.
    final angepasst = _adjusted;
    final t = context.t;
    final accent = widget.accent ?? t.accent;

    // Ruhige Karte der neuen Sprache: 1-px-Rand statt Schatten. Aufgeklappt
    // hebt sie sich ueber die hellere Flaeche ab, nicht ueber eine Erhebung.
    return AnimatedContainer(
      duration: motionDuration(context, const Duration(milliseconds: 180)),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: widget.expanded ? t.surf : t.surf2,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: widget.expanded ? accent : t.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(
            result: widget.result,
            imageUrl: widget.imageUrl,
            fallbackIcon: widget.fallbackIcon,
            accent: accent,
            expanded: widget.expanded,
            justAdded: widget.justAdded,
            onTap: widget.onTap,
            onRemove: widget.onRemove,
            isFavorite: widget.isFavorite,
            onToggleFavorite: widget.onToggleFavorite,
            favoriteButtonKey: widget.favoriteButtonKey,
          ),
          AnimatedSize(
            duration: motionDuration(context, const Duration(milliseconds: 180)),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: widget.expanded
                ? _ExpandedBody(
                    accent: accent,
                    grams: _grams,
                    gramsController: _gramsController,
                    preview: angepasst,
                    gramsInvalid: _gramsInvalid,
                    minGrams: PlausibilityLimits.portionGramsMin,
                    maxGrams: _sliderMaxGrams,
                    step: _step,
                    addButtonKey: widget.addButtonKey,
                    onBump: _bumpGrams,
                    onTextChanged: _onGramsTextChanged,
                    onSliderChanged: (v) => _setGrams(v.round()),
                    onAdd: _gramsInvalid
                        ? null
                        : () => widget.onAdd(angepasst),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.result,
    required this.imageUrl,
    required this.fallbackIcon,
    required this.accent,
    required this.expanded,
    required this.justAdded,
    required this.onTap,
    required this.onRemove,
    required this.isFavorite,
    required this.onToggleFavorite,
    required this.favoriteButtonKey,
  });

  final MealAnalysisResult result;
  final String? imageUrl;
  final IconData fallbackIcon;
  final Color accent;
  final bool expanded;
  final bool justAdded;
  final VoidCallback onTap;
  final VoidCallback? onRemove;
  final bool isFavorite;
  final ValueChanged<MealAnalysisResult>? onToggleFavorite;
  final Key? favoriteButtonKey;

  @override
  Widget build(BuildContext context) {
    // Der Untertitel muss dieselbe Autoritaet nennen wie die Vorschau im
    // aufgeklappten Koerper, sonst widerspricht sich EINE Karte: beim
    // Apfelkuchen {420 kcal, 150 g, 52 kcal/100 g} stand hier "52 kcal /
    // 100 g", waehrend die Karte darunter 420 kcal auf 150 g auswies.
    // `adjustedToGrams(100).caloriesKcal` ist genau die Dichte, die aus
    // caloriesKcal und estimatedGrams folgt — dieselbe Rechnung, die auch
    // geloggt wird, statt des rohen Nebenfelds `kcalPer100G`.
    final t = context.t;
    final per100 = result.adjustedToGrams(100).caloriesKcal;
    final subtitle = per100 > 0
        ? '$per100 kcal / 100 g'
        : '${result.caloriesKcal} kcal · ${result.estimatedGrams} g';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(rCard),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
        child: Row(
          children: [
            _Avatar(
              imageUrl: imageUrl,
              fallbackIcon: fallbackIcon,
              accent: accent,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.mealName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.ui(
                      13.5,
                      weight: FontWeight.w700,
                      color: t.ink,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.display(
                      11.5,
                      weight: FontWeight.w500,
                      color: t.ink2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            if (onToggleFavorite != null)
              IconButton(
                key: favoriteButtonKey,
                onPressed: () => onToggleFavorite!(result),
                tooltip: isFavorite
                    ? context.l10n.foodRemoveFavoriteTooltip
                    : context.l10n.foodAddFavoriteTooltip,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  isFavorite
                      ? Icons.favorite_rounded
                      : Icons.favorite_outline_rounded,
                  // Der Marken-Akzent ist die reservierte Aktionsfarbe —
                  // bewusst NICHT der (kategorische) Item-Akzent.
                  color: isFavorite ? t.accent : t.ink2,
                  size: 18,
                ),
              ),
            _Trailing(
              expanded: expanded,
              justAdded: justAdded,
              accent: accent,
              onRemove: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.imageUrl,
    required this.fallbackIcon,
    required this.accent,
  });

  final String? imageUrl;
  final IconData fallbackIcon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    // 42px-Avatar: Remote-Produktbilder kommen voll aufgelöst von OpenFoodFacts
    // — Decode auf die Avatar-Größe begrenzen (spart Speicher pro Suchtreffer).
    final cachePx = (42 * MediaQuery.devicePixelRatioOf(context)).round();
    return Container(
      width: 42,
      height: 42,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(rControl),
      ),
      child: imageUrl == null
          ? Icon(fallbackIcon, color: accent, size: 19)
          : Image.network(
              imageUrl!,
              fit: BoxFit.cover,
              cacheWidth: cachePx,
              cacheHeight: cachePx,
              errorBuilder: (_, __, ___) =>
                  Icon(fallbackIcon, color: accent, size: 19),
            ),
    );
  }
}

class _Trailing extends StatelessWidget {
  const _Trailing({
    required this.expanded,
    required this.justAdded,
    required this.accent,
    required this.onRemove,
  });

  final bool expanded;
  final bool justAdded;
  final Color accent;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    if (justAdded) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Icon(Icons.check_circle_rounded, color: accent, size: 22),
      );
    }
    final t = context.t;
    final chevron = AnimatedRotation(
      duration: motionDuration(context, const Duration(milliseconds: 180)),
      turns: expanded ? 0.5 : 0,
      child: Icon(
        Icons.keyboard_arrow_down_rounded,
        color: t.ink2,
        size: 22,
      ),
    );
    if (onRemove == null) {
      return Padding(padding: const EdgeInsets.only(right: 8), child: chevron);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          onPressed: onRemove,
          tooltip: context.l10n.foodRemoveTooltip,
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.close_rounded, color: t.ink2, size: 15),
        ),
        chevron,
        const SizedBox(width: 4),
      ],
    );
  }
}

class _ExpandedBody extends StatelessWidget {
  const _ExpandedBody({
    required this.accent,
    required this.grams,
    required this.gramsController,
    required this.preview,
    required this.gramsInvalid,
    required this.minGrams,
    required this.maxGrams,
    required this.step,
    required this.addButtonKey,
    required this.onBump,
    required this.onTextChanged,
    required this.onSliderChanged,
    required this.onAdd,
  });

  final Color accent;
  final int grams;
  final TextEditingController gramsController;

  /// Genau die Instanz, die [onAdd] weiterreicht. Kalorien und Makros der
  /// Vorschau kommen daraus — nicht aus einer zweiten Rechnung.
  final MealAnalysisResult preview;

  final bool gramsInvalid;
  final int minGrams;
  final int maxGrams;
  final int step;
  final Key? addButtonKey;
  final ValueChanged<int> onBump;
  final ValueChanged<String> onTextChanged;
  final ValueChanged<double> onSliderChanged;

  /// `null` sperrt den Knopf — die getippte Portion ist unplausibel.
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Row(
            children: [
              _StepperButton(
                icon: Icons.remove_rounded,
                semanticLabel: l10n.foodDecreaseAmountSemantics,
                accent: accent,
                onTap: () => onBump(-step),
                onLongPress: () => onBump(-step * 5),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _GramsField(
                  controller: gramsController,
                  onChanged: onTextChanged,
                ),
              ),
              const SizedBox(width: 10),
              _StepperButton(
                icon: Icons.add_rounded,
                semanticLabel: l10n.foodIncreaseAmountSemantics,
                accent: accent,
                onTap: () => onBump(step),
                onLongPress: () => onBump(step * 5),
              ),
            ],
          ),
          if (gramsInvalid) ...[
            const SizedBox(height: 6),
            Text(
              l10n.foodPortionRangeHint(
                PlausibilityLimits.portionGramsMin,
                PlausibilityLimits.portionGramsMax,
              ),
              key: const ValueKey('kcal-suggestion-grams-hint'),
              style: AppType.ui(
                11,
                weight: FontWeight.w600,
                color: t.warning,
              ),
            ),
          ],
          const SizedBox(height: 10),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: accent,
              inactiveTrackColor: t.tile,
              thumbColor: accent,
              overlayColor: accent.withValues(alpha: 0.15),
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            ),
            child: Slider(
              min: minGrams.toDouble(),
              max: maxGrams.toDouble(),
              value: grams.clamp(minGrams, maxGrams).toDouble(),
              onChanged: onSliderChanged,
            ),
          ),
          const SizedBox(height: 6),
          _LivePreview(
            kcal: preview.caloriesKcal,
            protein: preview.protein,
            carbs: preview.carbs,
            fat: preview.fat,
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: addButtonKey,
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(
                l10n.commonAdd,
                style: AppType.ui(14, weight: FontWeight.w700),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: t.forest,
                foregroundColor: t.onForest,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(rControl),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Runde Soft-Kapsel statt Hairline-Quadrat: die Flaeche traegt den Knopf,
/// das Icon traegt den Akzent. Kein Rahmen (Design-Vorgabe).
class _StepperButton extends StatelessWidget {
  const _StepperButton({
    required this.icon,
    required this.semanticLabel,
    required this.accent,
    required this.onTap,
    required this.onLongPress,
  });

  final IconData icon;

  /// A11y: das +/-Icon allein sagt einem Screenreader nichts.
  final String semanticLabel;

  final Color accent;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: context.t.tile,
            borderRadius: BorderRadius.circular(rPill),
          ),
          child: Icon(icon, size: 21, color: accent),
        ),
      ),
    );
  }
}

/// Rahmenlose Gramm-Kapsel nach dem Coach-Composer-Muster: kein Hairline,
/// kein Fokusring — Fokus ist eine Flaechen-Aufhellung, die Zahl ist der
/// Held (18 pt, tabular).
class _GramsField extends StatefulWidget {
  const _GramsField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  State<_GramsField> createState() => _GramsFieldState();
}

class _GramsFieldState extends State<_GramsField> {
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
    final t = context.t;
    return AnimatedContainer(
      duration: motionDuration(context, const Duration(milliseconds: 160)),
      curve: Curves.easeOutCubic,
      height: 48,
      decoration: BoxDecoration(
        // Fokus = Flaechen-Aufhellung, kein Ring: `surf` liegt in beiden Modi
        // eine Stufe ueber `tile` und uebernimmt genau diese Rolle.
        color: _focused ? t.surf : t.tile,
        borderRadius: BorderRadius.circular(rPill),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 64,
            child: TextField(
              cursorOpacityAnimates: false,
              controller: widget.controller,
              focusNode: _focus,
              onChanged: widget.onChanged,
              keyboardType: const TextInputType.numberWithOptions(
                signed: false,
                decimal: false,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                // Fuenf Stellen, weil die Obergrenze
                // (PlausibilityLimits.portionGramsMax = 10000 g) fuenf hat.
                // Mit vier war der obere Teil des gueltigen Bereichs
                // ueberhaupt nicht eingebbar — eine unsichtbare zweite
                // Grenze neben der eigentlichen.
                LengthLimitingTextInputFormatter(5),
              ],
              textAlign: TextAlign.center,
              style: AppType.display(18, color: t.ink),
              decoration: const InputDecoration(
                // Theme-Borders explizit ausnullen: das globale
                // inputDecorationTheme traegt Hairline + Lime-Fokusring.
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                isCollapsed: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          const SizedBox(width: 3),
          Text(
            'g',
            style: AppType.ui(13, weight: FontWeight.w600, color: t.ink2),
          ),
        ],
      ),
    );
  }
}

class _LivePreview extends StatelessWidget {
  const _LivePreview({
    required this.kcal,
    required this.protein,
    required this.carbs,
    required this.fat,
  });

  final int kcal;
  final String protein;
  final String carbs;
  final String fat;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          '=',
          style: AppType.ui(
            14,
            weight: FontWeight.w500,
            color: t.ink2,
            height: 1.0,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$kcal kcal',
          style: AppType.display(20, color: t.ink, height: 1.0),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _macroLine(context.l10n),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: AppType.display(
              11.5,
              weight: FontWeight.w600,
              color: t.ink2,
            ),
          ),
        ),
      ],
    );
  }

  String _macroLine(AppLocalizations l10n) {
    final parts = <String>[];
    if (protein != '-') parts.add(l10n.foodMacroProteinShort(protein));
    if (carbs != '-') parts.add(l10n.foodMacroCarbsShort(carbs));
    if (fat != '-') parts.add(l10n.foodMacroFatShort(fat));
    return parts.join(' · ');
  }
}
