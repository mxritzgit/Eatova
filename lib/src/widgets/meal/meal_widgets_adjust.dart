part of 'meal_widgets.dart';

/// Oeffnet das Bestandteil-Anpassen-Sheet.
///
/// **D5, bewusst OHNE `showDragHandle`.** Frueher stand hier
/// `showDragHandle: true` — das einzige Sheet der App, das den Griff der
/// *Route* zeichnen liess (`app_theme.dart:95` setzt global `false`). Dieser
/// Griff liegt als Stack-Geschwister NEBEN dem `builder`-Kind
/// (`bottom_sheet.dart:397-410`) und damit ausserhalb von allem, was das Sheet
/// selbst an Schutz aufbaut: ein Zug genau am Griff und der
/// Semantics-Dismiss darauf (`bottom_sheet.dart:368`,
/// `onSemanticsTap: widget.onClosing` → `Navigator.pop`) liefen an der
/// Rueckfrage vorbei. Den Griff zeichnet deshalb [_SheetGrabber] innerhalb des
/// Guards — inklusive eigener Dismiss-Semantik ueber `maybePop`, damit
/// TalkBack/VoiceOver den Weg aus dem Sheet behaelt (einen Schliessen-Knopf
/// gibt es hier nicht).
Future<Object?> showWeightAdjustmentSheet(
  BuildContext context,
  MealAnalysisResult result,
) {
  return showModalBottomSheet<Object>(
    context: context,
    backgroundColor: context.t.bg,
    isScrollControlled: true,
    builder: (context) => _MealItemAdjustmentSheet(result: result),
  );
}

// ---------------------------------------------------------------------------
// D5: Verwerf-Rueckfrage, Drag-Guard und der eigene Griff
// ---------------------------------------------------------------------------

/// „Aenderungen verwerfen?" — die gemeinsame Bestaetigung fuer JEDEN Weg, ein
/// ausgefuelltes Formular zu schliessen. [text] benennt, was genau auf dem
/// Spiel steht; das Sheet und der Hinzufuegen-Dialog teilen sich den Dialog.
///
/// `barrierDismissible` bleibt auf dem Default `true`: ein Tap neben den
/// Dialog ist „Abbrechen", also die harmlose Antwort. Der Dialog liegt auf dem
/// Root-Navigator und damit UEBER der Route, die er schuetzt — sein eigener
/// Barrier schluckt den Tap, die Ebene darunter bekommt ihn nie zu sehen. Der
/// Dialog kann sich also nicht selbst mitsamt seinem Schuetzling wegklicken.
///
/// Vierte Kopie desselben Musters (Zwillinge in
/// `lib/src/widgets/kcal/edit_meal_sheet.dart`,
/// `lib/src/widgets/shared/settings_sheet.dart` und
/// `lib/src/screens/recipes/recipe_create_sheet.dart`). Die Dopplung ist der
/// Preis dafuer, dass diese Datei ein `part` ohne eigene Imports ist; alle vier
/// gehoeren nach `lib/src/widgets/common/`, sobald jemand den Import in
/// `meal_widgets.dart` setzen darf.
///
/// Rueckgabe: `true` = verwerfen, `false`/abgebrochen = offen lassen.
Future<bool> _confirmDiscardChanges(BuildContext context, String text) async {
  final t = context.t;
  final l10n = context.l10n;
  final verwerfen = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('discard-changes-dialog'),
      backgroundColor: t.surf,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(rSheet),
      ),
      title: Text(
        l10n.foodDiscardChangesTitle,
        style: AppType.display(19, color: t.ink),
      ),
      content: Text(text, style: AppType.ui(13, color: t.ink2, height: 1.4)),
      actions: [
        TextButton(
          key: const ValueKey('discard-changes-cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.foodDiscardChangesKeepEditing),
        ),
        TextButton(
          key: const ValueKey('discard-changes-confirm'),
          style: TextButton.styleFrom(foregroundColor: t.danger),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.foodDiscardChangesConfirm),
        ),
      ],
    ),
  );
  return verwerfen ?? false;
}

/// Der Griff des Sheets — bewusst hier statt an der Route gezeichnet (siehe
/// [showWeightAdjustmentSheet]).
///
/// Zwei Dinge muss er koennen, die der Route-Griff mitbrachte:
///
///  * **Ziehen.** Er liegt im Kind und damit INNERHALB von
///    [_DiscardDragGuard]; ist der Guard inaktiv, greift wie bisher der
///    Drag-Detector der Route und das Sheet laesst sich normal wegziehen.
///  * **Dismiss fuer Screenreader.** Der Route-Griff bot TalkBack/VoiceOver
///    eine Tap-Aktion an, die geradewegs `Navigator.pop` rief. Hier ruft
///    dieselbe Aktion [onDismiss] und damit `maybePop` — derselbe Weg wie der
///    Barriere-Tap, also mit Rueckfrage. Ohne diese Aktion kaeme ein
///    Screenreader-Nutzer aus dem Sheet gar nicht mehr heraus: einen
///    Schliessen-Knopf hat es nicht, und die Barriere selbst bietet auf
///    Android keine Dismiss-Semantik an (`modal_barrier.dart`,
///    `platformSupportsDismissingBarrier`).
class _SheetGrabber extends StatelessWidget {
  const _SheetGrabber({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      onTap: onDismiss,
      child: SizedBox(
        width: double.infinity,
        height: 26,
        child: Center(
          child: SizedBox(
            width: 32,
            height: 4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: context.t.ink2,
                borderRadius: const BorderRadius.all(Radius.circular(rPill)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// D5: faengt das Nach-unten-Ziehen eines modalen Bottom-Sheets ab.
///
/// **Warum das noetig ist:** ein `PopScope` deckt nur die halbe Miete ab. Die
/// Dismiss-Wege laufen im Framework verschieden:
///
///  * Barriere-Tap → `ModalBarrier.handleDismiss` → `Navigator.maybePop`
///    (`modal_barrier.dart:225-230`) — fragt die Pop-Disposition, also
///    `PopScope`.
///  * Ziehen → `BottomSheet._handleDragEnd` → `onClosing` → **`Navigator.pop`**
///    (`bottom_sheet.dart:769-771`) — fragt sie **nicht**. Ein `PopScope` sieht
///    diesen Weg nie.
///
/// Von innerhalb des Sheets gibt es dafuer genau einen Hebel: die
/// Gesten-Arena. Der `_BottomSheetGestureDetector` sitzt ueber dem
/// `builder`-Kind; ein eigener Vertikal-Drag-Erkenner IM Kind liegt tiefer und
/// gewinnt die Arena — dasselbe Prinzip, aus dem eine ScrollView im Sheet das
/// Ziehen schluckt. Scrollbare Bereiche liegen wiederum tiefer als dieser
/// Guard und bleiben unberuehrt.
///
/// Ist [active] false (nichts geaendert), wird gar kein Erkenner registriert —
/// das Sheet laesst sich dann wie gewohnt wegziehen. Ein Sheet, das man ohne
/// Dialog nicht mehr zubekommt, waere schlimmer als der Bug.
///
/// Zwilling von `_DiscardDragGuard` in
/// `lib/src/widgets/kcal/edit_meal_sheet.dart`.
class _DiscardDragGuard extends StatefulWidget {
  const _DiscardDragGuard({
    required this.active,
    required this.onDismissAttempt,
    required this.child,
  });

  final bool active;
  final VoidCallback onDismissAttempt;
  final Widget child;

  @override
  State<_DiscardDragGuard> createState() => _DiscardDragGuardState();
}

class _DiscardDragGuardState extends State<_DiscardDragGuard> {
  /// Mindeststrecke nach unten, ab der ein Zug als „zumachen" gilt. Bewusst
  /// klein: der Guard schluckt die Geste ohnehin, die Frage ist nur, ob der
  /// Nutzer dazu eine Antwort bekommt.
  static const double _closeIntentPx = 32;

  /// Flick-Schwelle, gespiegelt an `_kMinFlingVelocity` aus bottom_sheet.dart.
  static const double _flingVelocity = 700;

  double _dy = 0;

  void _onStart(DragStartDetails details) => _dy = 0;

  void _onUpdate(DragUpdateDetails details) => _dy += details.primaryDelta ?? 0;

  void _onEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (_dy > _closeIntentPx || velocity > _flingVelocity) {
      widget.onDismissAttempt();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    return GestureDetector(
      // Ohne translucent bleiben Luecken zwischen den Kindern unbedeckt.
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _onStart,
      onVerticalDragUpdate: _onUpdate,
      onVerticalDragEnd: _onEnd,
      child: widget.child,
    );
  }
}

// ---------------------------------------------------------------------------
// Das Sheet
// ---------------------------------------------------------------------------

/// Ein Bestandteil im Sheet: das Modell, sein Eingabefeld, sein Ausgangs- und
/// sein aktuelles Gewicht.
///
/// Das Buendel entsteht ausschliesslich in
/// [_MealItemAdjustmentSheetState._neuerPosten] — siehe die Begruendung dort.
class _Posten {
  _Posten({required this.item, required this.controller})
    : startGramm = item.grams,
      gramm = item.grams;

  final MealComponent item;
  final TextEditingController controller;

  /// Das Gewicht beim Oeffnen — Bezugspunkt fuer
  /// [_MealItemAdjustmentSheetState._dirty], nicht „wurde mal getippt".
  final int startGramm;

  /// Das gerade eingetippte Gewicht (0 = ungueltiger Zwischenstand).
  int gramm;

  bool get gewichtVeraendert => gramm != startGramm;

  /// Dieser Posten, umgerechnet auf das aktuell eingetippte Gewicht.
  ///
  /// **Eine** Rechnung fuer Vorschau, Gesamtzeile und Speicherpfad. Genau die
  /// Doppelung war B1: `_itemKcalFor` bevorzugte `kcalPer100G`, waehrend
  /// [MealComponent.adjustedToGrams] seit Welle 2 `caloriesKcal` als
  /// autoritativ behandelt und die Dichte nur als Rueckfallebene nimmt. Bei
  /// einem Posten, dessen Dichte nicht zu Gramm und Kalorien passt
  /// ({100 g, 521 kcal, 2180 kcal/100 g}), zeigte die Zeile auf 30 g deshalb
  /// 654 kcal, gespeichert wurden 156.
  ///
  /// Delegieren statt die Formel abzuschreiben: eine Kopie kann wieder
  /// auseinanderlaufen, und `adjustedToGrams` bringt zusaetzlich die Clamps
  /// (1..10000 g, 0..10000 kcal) mit — ohne sie zeigte die Zeile bei einer
  /// abwegigen Eingabe erneut etwas anderes als die Summe darunter.
  MealComponent get angepasst => item.adjustedToGrams(gramm);
}

class _MealItemAdjustmentSheet extends StatefulWidget {
  const _MealItemAdjustmentSheet({required this.result});

  final MealAnalysisResult result;

  @override
  State<_MealItemAdjustmentSheet> createState() => _MealItemAdjustmentSheetState();
}

class _MealItemAdjustmentSheetState extends State<_MealItemAdjustmentSheet> {
  /// Registry ALLER Posten — die einzige Liste, die es hier gibt.
  final List<_Posten> _posten = <_Posten>[];

  /// Wie viele Posten beim Oeffnen dastanden. Bezugspunkt fuer [_dirty] und
  /// fuer die Zaehlung in [_statusLine] — frueher stand dort
  /// `_items.length - widget.result.items.length`, was bei einem Ergebnis ohne
  /// Bestandteil-Aufschluesselung (Barcode-Treffer) den synthetisierten
  /// Ersatzposten mitzaehlte und sofort „1 manuell ergänzt" behauptete.
  late final int _startAnzahl;

  Set<int> _removed = const <int>{};

  @override
  void initState() {
    super.initState();
    // Fall back to a single synthesized item when the AI didn't return any
    // itemized breakdown (or for OpenFoodFacts barcode lookups). The user can
    // then still edit the weight, remove it, or split it into multiple items
    // via "Bestandteil hinzufügen".
    final quelle = widget.result.items.isNotEmpty
        ? widget.result.items
        : <MealComponent>[
            MealComponent(
              name: widget.result.mealName,
              grams: widget.result.estimatedGrams,
              caloriesKcal: widget.result.caloriesKcal,
              kcalPer100G: widget.result.kcalPer100G,
            ),
          ];
    for (final item in quelle) {
      _neuerPosten(item);
    }
    _startAnzahl = _posten.length;
  }

  /// Die EINZIGE Stelle, an der ein Posten entsteht.
  ///
  /// D5 verlangt ein `_dirty`, das keinen Zustand vergisst. Anders als im
  /// Rezept-Sheet ist die Zahl der Felder hier variabel, deshalb gibt es keine
  /// Handliste von Controllern, sondern diese Fabrik. Wer sie benutzt, bekommt
  /// automatisch alle drei Dinge, die man sonst einzeln vergisst —
  ///
  ///   1. den Ausgangswert fuer den [_dirty]-Vergleich ([_Posten.startGramm]),
  ///   2. den Listener, der das getippte Gewicht UND `PopScope.canPop`
  ///      nachfuehrt (frueher haing das an `TextField.onChanged`, das bei
  ///      programmatisch gesetztem Text gar nicht feuert),
  ///   3. das `dispose()` ueber [_posten].
  ///
  /// Ein direkt gebauter `TextEditingController` haette keins davon und faellt
  /// sofort auf.
  void _neuerPosten(MealComponent item) {
    final controller = TextEditingController(text: item.grams.toString());
    final posten = _Posten(item: item, controller: controller);
    controller.addListener(() {
      final getippt = int.tryParse(controller.text.trim()) ?? 0;
      // Der Listener feuert auch bei reiner Cursorbewegung — dann ist nichts
      // zu tun.
      if (getippt == posten.gramm) return;
      posten.gramm = getippt;
      if (mounted) setState(() {});
    });
    _posten.add(posten);
  }

  @override
  void dispose() {
    for (final posten in _posten) {
      // Der Listener haengt an genau diesem Controller und stirbt mit ihm.
      posten.controller.dispose();
    }
    super.dispose();
  }

  void _remove(int index) {
    setState(() => _removed = {..._removed, index});
  }

  void _undoRemove(int index) {
    setState(() => _removed = {..._removed}..remove(index));
  }

  void _appendItem(MealComponent item) {
    setState(() => _neuerPosten(item));
  }

  /// Die Posten, die uebrig bleiben — in ihrer urspruenglichen Reihenfolge.
  List<int> get _uebrigeIndizes => [
    for (var index = 0; index < _posten.length; index++)
      if (!_removed.contains(index)) index,
  ];

  /// D5: weicht das, was „Übernehmen" JETZT liefern wuerde, vom Stand beim
  /// Oeffnen ab?
  ///
  /// Bei fester Feldzahl reicht ein Feld-fuer-Feld-Vergleich (so macht es das
  /// Rezept-Sheet). Hier ist die Zahl der Eingabefelder variabel, und es gibt
  /// zwei weitere Zustandsarten: das [_removed]-Set und die manuell ergaenzten
  /// Posten. Deshalb vergleicht `_dirty` nicht Felder, sondern das ERGEBNIS —
  /// die Folge der uebrig bleibenden Posten samt ihrer Gewichte gegen genau
  /// diese Folge beim Oeffnen.
  ///
  /// Das ist zugleich die Antwort auf „was heisst geaendert?": nicht „wurde
  /// angefasst", sondern „kommt etwas anderes heraus". Wer einen Posten
  /// hinzufuegt und wieder entfernt, wer ein Gewicht zurueckttippt oder ein
  /// Entfernen widerruft, steht damit wieder auf unveraendert — und eine
  /// spaeter ergaenzte Zustandsart faellt automatisch unter den Vergleich,
  /// sobald sie das Ergebnis beeinflusst.
  bool get _dirty {
    final uebrig = _uebrigeIndizes;
    if (uebrig.length != _startAnzahl) return true;
    for (var n = 0; n < uebrig.length; n++) {
      // Stelle n traegt nicht mehr den urspruenglichen Posten n — also wurde
      // einer entfernt und ein manuell ergaenzter rueckte nach.
      if (uebrig[n] != n) return true;
      if (_posten[n].gewichtVeraendert) return true;
    }
    return false;
  }

  /// Tragen ALLE Posten, die uebrig bleiben, vollstaendige Makros?
  ///
  /// Genau diese Bedingung entscheidet in
  /// [MealAnalysisResult.adjustedToItems], ob die Makros der Mahlzeit exakt
  /// aufsummiert werden oder als "unbekannt" gelten. Der Dialog braucht sie,
  /// um dem Nutzer die Folge seiner Eingabe **vorher** sagen zu koennen.
  /// Leere Auswahl ergibt bewusst `true` — genau wie `every` auf einer leeren
  /// Liste. Wer alle Posten entfernt und einen neuen mit Makros anlegt, hat
  /// danach eine Mahlzeit, deren einziger Posten Makros traegt; die Summe
  /// greift dann sehr wohl.
  bool get _restTraegtMakros {
    for (final index in _uebrigeIndizes) {
      if (!_posten[index].item.hasMacros) return false;
    }
    return true;
  }

  Future<void> _addItemDialog() async {
    final newItem = await showDialog<MealComponent>(
      context: context,
      builder: (context) =>
          _AddItemDialog(restTraegtMakros: _restTraegtMakros),
    );
    if (newItem != null) {
      _appendItem(newItem);
    }
  }

  int _itemKcalFor(int index) {
    // 0 g ist ein ungueltiger Zwischenstand (das Uebernehmen ist dann
    // gesperrt). `adjustedToGrams` wuerde auf die Mindestportion 1 g klemmen
    // und damit neben der getippten 0 eine Kalorienzahl zeigen.
    if (_posten[index].gramm <= 0) return 0;
    return _posten[index].angepasst.caloriesKcal;
  }

  String _statusLine(int addedCount, AppLocalizations l10n) {
    final parts = <String>[];
    if (_removed.isNotEmpty) {
      parts.add(l10n.foodItemsRemovedCount(_removed.length));
    }
    if (addedCount > 0) parts.add(l10n.foodItemsAddedCount(addedCount));
    if (parts.isEmpty) {
      return l10n.foodAdjustItemsHint;
    }
    return parts.join(' · ');
  }

  /// D5: laeuft fuer jeden abgefangenen Dismiss-Versuch — Barriere-Tap,
  /// System-Zurueck und der Semantics-Dismiss am Griff kommen ueber
  /// [PopScope], das Ziehen ueber [_DiscardDragGuard]. Mehrfach-Versuche
  /// stapeln keine Dialoge.
  bool _discardDialogOpen = false;

  Future<void> _askDiscard() async {
    if (_discardDialogOpen) return;
    _discardDialogOpen = true;
    final verwerfen = await _confirmDiscardChanges(
      context,
      context.l10n.foodDiscardItemsBody,
    );
    _discardDialogOpen = false;
    if (!mounted || !verwerfen) return;
    // Der Dialog ist hier bereits gepoppt — oberste Route ist wieder das
    // Sheet. Bewusst OHNE Ergebnis: verworfen liefert `null`, also exakt das,
    // was auch ein Abbruch liefert. Die aufrufenden Sheets
    // (edit_meal_sheet.dart:257, meal_analysis_sheet.dart:212) behandeln
    // `null` als „nichts uebernehmen" — beides bleibt ununterscheidbar und
    // damit gleich behandelt.
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final uebrig = _uebrigeIndizes;
    final adjustedItems = <MealComponent>[
      for (final index in uebrig) _posten[index].angepasst,
    ];
    final totalGrams = adjustedItems.fold<int>(
      0,
      (sum, item) => sum + item.grams,
    );
    final totalKcal = adjustedItems.fold<int>(
      0,
      (sum, item) => sum + item.caloriesKcal,
    );
    final invalidGrams = [
      for (final index in uebrig)
        if (_posten[index].gramm <= 0) index,
    ];
    final canSave = adjustedItems.isNotEmpty && invalidGrams.isEmpty;
    final addedCount = _posten.length - _startAnzahl;

    return PopScope<Object?>(
      // Nur solange wirklich etwas offen ist. Ohne Aenderung schliesst das
      // Sheet wie bisher sofort. `Navigator.pop` — also „Übernehmen" — laeuft
      // an `canPop` vorbei und bleibt davon unberuehrt.
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _askDiscard();
      },
      child: _DiscardDragGuard(
        active: _dirty,
        onDismissAttempt: _askDiscard,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: 24 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Bewusst AUSSERHALB der Scroll-Flaeche: ein Zug auf einer
              // scrollbaren Flaeche gehoert dem Scrollable, nicht dem Guard.
              _SheetGrabber(
                onDismiss: () => Navigator.of(context).maybePop(),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.foodAdjustItemsTitle,
                        style: AppType.display(20, color: t.ink),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _statusLine(addedCount, l10n),
                        style: AppType.ui(
                          13,
                          weight: FontWeight.w500,
                          color: t.ink2,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 18),
                      for (var index = 0; index < _posten.length; index++) ...[
                        if (_removed.contains(index))
                          _RemovedItemCard(
                            name: _posten[index].item.name,
                            onUndo: () => _undoRemove(index),
                          )
                        else
                          _ItemEditCard(
                            index: index,
                            item: _posten[index].item,
                            controller: _posten[index].controller,
                            liveKcal: _itemKcalFor(index),
                            liveGrams: _posten[index].gramm,
                            onRemove: () => _remove(index),
                          ),
                        const SizedBox(height: 10),
                      ],
                      OutlinedButton.icon(
                        key: const ValueKey('analyse-item-add-button'),
                        onPressed: _addItemDialog,
                        icon: const Icon(Icons.add_rounded, size: 17),
                        label: Text(
                          l10n.foodAddItemTitle,
                          style: AppType.ui(13.5, weight: FontWeight.w600),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: t.ink,
                          side: BorderSide(color: t.line),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(rControl),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      AppCard(
                        key: const ValueKey('analyse-adjusted-kcal-preview'),
                        radius: rCard,
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Icon(
                              Icons.calculate_outlined,
                              color: t.accent,
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                l10n.foodAdjustedTotalApprox(
                                    totalGrams, totalKcal),
                                style: AppType.display(18, color: t.ink),
                              ),
                            ),
                            if (adjustedItems.isNotEmpty)
                              Text(
                                l10n.foodItemsCountLabel(adjustedItems.length),
                                style: AppType.display(
                                  11,
                                  weight: FontWeight.w500,
                                  color: t.ink2,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (adjustedItems.isEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          l10n.foodAtLeastOneItemRequired,
                          style: AppType.ui(
                            11,
                            weight: FontWeight.w600,
                            color: t.warning,
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          key: const ValueKey('analyse-save-weight-button'),
                          onPressed: canSave
                              ? () => Navigator.pop(context, adjustedItems)
                              : null,
                          icon: const Icon(Icons.check_rounded, size: 17),
                          label: Text(
                            l10n.foodApplyButton,
                            style: AppType.ui(14, weight: FontWeight.w600),
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: t.forest,
                            foregroundColor: t.onForest,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(rControl),
                            ),
                          ),
                        ),
                      ),
                    ],
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

class _ItemEditCard extends StatelessWidget {
  const _ItemEditCard({
    required this.index,
    required this.item,
    required this.controller,
    required this.liveKcal,
    required this.liveGrams,
    required this.onRemove,
  });

  final int index;
  final MealComponent item;
  final TextEditingController controller;
  final int liveKcal;
  final int liveGrams;
  final VoidCallback onRemove;

  /// Stepper-Aenderung laeuft ueber DENSELBEN Kanal wie Tippen: der
  /// Controller-Setter benachrichtigt den `_neuerPosten`-Listener — eine
  /// Quelle, kein zweiter Zustand.
  void _bump(int delta) {
    final aktuell = int.tryParse(controller.text) ?? item.grams;
    final neu = (aktuell + delta).clamp(1, 10000);
    controller.text = '$neu';
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    // Soft-Kapsel statt Hairline-Rahmen + Formular-Label (Design-Vorgabe):
    // die Gramm-Zeile bekommt dieselbe Bedienflaeche wie die
    // Vorschlagskarten im Food-Tab — runde -/+ Kapseln um eine rahmenlose
    // Wert-Kapsel, die Zahl als Held.
    return AppCard(
      key: ValueKey('analyse-item-card-$index'),
      radius: rCard,
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.name,
                  style: AppType.ui(14, weight: FontWeight.w700, color: t.ink),
                ),
              ),
              IconButton(
                key: ValueKey('analyse-item-remove-$index'),
                onPressed: onRemove,
                tooltip: l10n.foodRemoveTooltip,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: t.ink2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Row(
              children: [
                _ItemStepperButton(
                  icon: Icons.remove_rounded,
                  semanticLabel: l10n.foodDecreaseItemSemantics(item.name),
                  onTap: () => _bump(-10),
                  onLongPress: () => _bump(-50),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Container(
                    height: 46,
                    decoration: BoxDecoration(
                      color: t.surf2,
                      borderRadius: BorderRadius.circular(rPill),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 64,
                          // Kein `onChanged`: das getippte Gewicht liest der
                          // Listener aus `_neuerPosten` vom Controller. Eine
                          // zweite Quelle koennte auseinanderlaufen — und
                          // `onChanged` feuert bei programmatisch gesetztem
                          // Text gar nicht.
                          child: TextField(
                            key: ValueKey('analyse-item-weight-input-$index'),
                            cursorOpacityAnimates: false,
                            controller: controller,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            textAlign: TextAlign.center,
                            style: AppType.display(18, color: t.ink),
                            decoration: const InputDecoration(
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
                          style: AppType.ui(
                            13,
                            weight: FontWeight.w600,
                            color: t.ink2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _ItemStepperButton(
                  icon: Icons.add_rounded,
                  semanticLabel: l10n.foodIncreaseItemSemantics(item.name),
                  onTap: () => _bump(10),
                  onLongPress: () => _bump(50),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(
              l10n.foodOriginallyLabel(item.gramsLabel, item.caloriesLabel),
              style: AppType.display(
                11,
                weight: FontWeight.w500,
                color: t.ink2,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Row(
              children: [
                Icon(
                  Icons.local_fire_department_outlined,
                  size: 14,
                  color: t.accent,
                ),
                const SizedBox(width: 6),
                Text(
                  '$liveGrams g · $liveKcal kcal',
                  style: AppType.display(
                    12,
                    weight: FontWeight.w600,
                    color: t.ink,
                  ),
                ),
                if (item.kcalPer100G != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    '· ${item.kcalPer100G!.round()} kcal/100g',
                    style: AppType.display(
                      11,
                      weight: FontWeight.w500,
                      color: t.ink2,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Runde -/+ Soft-Kapsel der Posten-Zeile (Muster der Vorschlagskarten im
/// Food-Tab; der Akzent kommt jetzt aus [AppTokens.accent] statt aus einer
/// Makro-Farbe).
class _ItemStepperButton extends StatelessWidget {
  const _ItemStepperButton({
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
    required this.onLongPress,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: t.surf2,
            borderRadius: BorderRadius.circular(rPill),
          ),
          child: Icon(icon, size: 20, color: t.accent),
        ),
      ),
    );
  }
}

class _RemovedItemCard extends StatelessWidget {
  const _RemovedItemCard({required this.name, required this.onUndo});

  final String name;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AppCard(
      radius: rCard,
      color: t.surf2,
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              style: AppType.ui(
                13,
                weight: FontWeight.w600,
                color: t.ink2,
              ).copyWith(decoration: TextDecoration.lineThrough),
            ),
          ),
          TextButton.icon(
            onPressed: onUndo,
            style: TextButton.styleFrom(
              foregroundColor: t.ink,
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 4,
              ),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.undo_rounded, size: 14),
            label: Text(
              context.l10n.foodUndoRemoveButton,
              style: AppType.ui(11, weight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// Obergrenze fuer ein Makro eines einzelnen Postens, in Gramm.
///
/// Spiegelt `LoggedMealLimits.macroGMax` aus `models/model_limits.dart`.
/// Bewusst als lokale Konstante: diese Datei ist ein `part of
/// 'meal_widgets.dart'` und kann selbst nichts importieren, und die
/// Bibliotheks-Datei mit den Importen gehoert einem anderen Arbeitsstrang.
/// Getippte Werte werden hier **abgelehnt statt geklemmt** — so will es die
/// Doku in `model_limits.dart` fuer alles, was der Nutzer selbst eingibt.
const double _makroMaxG = 1000;

/// Ein Makro-Eingabefeld: optional, Gramm, Dezimaltrennung per Komma ODER
/// Punkt. Bewusst nicht `digitsOnly` — 0,5 g Fett muss eingebbar sein.
class _MacroField extends StatelessWidget {
  const _MacroField({
    required this.fieldKey,
    required this.controller,
    required this.label,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) {
    // Kein `onChanged`: die Freigabe des Knopfes und `PopScope.canPop` haengen
    // am Listener aus `_AddItemDialogState._feld`.
    return TextField(
      key: fieldKey,
      cursorOpacityAnimates: false,
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
      ],
      decoration: InputDecoration(labelText: label, suffixText: 'g'),
    );
  }
}

class _AddItemDialog extends StatefulWidget {
  const _AddItemDialog({required this.restTraegtMakros});

  /// Tragen die uebrigen Posten der Mahlzeit bereits vollstaendige Makros?
  /// Nur dann kann die Mahlzeit ihre Makros ueberhaupt behalten, wenn dieser
  /// Posten welche mitbringt — sonst waere jedes Versprechen hier gelogen.
  final bool restTraegtMakros;

  @override
  State<_AddItemDialog> createState() => _AddItemDialogState();
}

class _AddItemDialogState extends State<_AddItemDialog> {
  /// Registry ALLER Eingabefelder — die einzige Liste, die es hier gibt.
  ///
  /// [_feld] ist die einzige Quelle eines Controllers; wer sie benutzt,
  /// bekommt den Listener (Freigabe von „Hinzufügen" UND `PopScope.canPop`)
  /// und das `dispose()` automatisch. Ein siebtes Feld kann damit weder das
  /// eine noch das andere vergessen.
  final List<TextEditingController> _felder = <TextEditingController>[];

  late final TextEditingController _name;
  late final TextEditingController _grams;
  late final TextEditingController _kcal;
  late final TextEditingController _protein;
  late final TextEditingController _carbs;
  late final TextEditingController _fat;

  /// Die Makro-Felder sind eingeklappt. Der haeufige Fall ("ich hab noch Brot
  /// dazu") bleibt damit drei Felder lang; wer genauer sein will, klappt auf.
  bool _makrosOffen = false;

  @override
  void initState() {
    super.initState();
    _name = _feld();
    _grams = _feld();
    _kcal = _feld();
    _protein = _feld();
    _carbs = _feld();
    _fat = _feld();
  }

  TextEditingController _feld() {
    final controller = TextEditingController();
    controller.addListener(_onFeldChanged);
    _felder.add(controller);
    return controller;
  }

  void _onFeldChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final controller in _felder) {
      controller
        ..removeListener(_onFeldChanged)
        ..dispose();
    }
    super.dispose();
  }

  /// D5: irgendein Feld traegt Text. Alle sechs starten leer, „nicht leer" ist
  /// hier also gleichbedeutend mit „vom Ausgangszustand abgewichen". Das reine
  /// Aufklappen der Makro-Sektion zaehlt bewusst nicht — dabei geht nichts
  /// verloren.
  bool get _dirty => _felder.any((controller) => controller.text.isNotEmpty);

  /// Liest ein Makro-Feld: leer -> `null` ("unbekannt"), sonst die Zahl.
  ///
  /// `null` und `0` sind ausdruecklich **nicht** dasselbe. Wer das Feld leer
  /// laesst, sagt "weiss ich nicht"; wer 0 eintippt, sagt "davon ist nichts
  /// drin". [MealComponent.hasMacros] unterscheidet genau daran.
  static double? _makro(TextEditingController controller) {
    final text = controller.text.trim();
    if (text.isEmpty) return null;
    return double.tryParse(text.replaceAll(',', '.'));
  }

  /// `true`, wenn das Feld leer ist ODER eine Zahl im erlaubten Bereich traegt.
  static bool _makroFeldOk(TextEditingController controller) {
    if (controller.text.trim().isEmpty) return true;
    final wert = _makro(controller);
    return wert != null && wert.isFinite && wert >= 0 && wert <= _makroMaxG;
  }

  bool get _alleMakrosGesetzt =>
      _makro(_protein) != null &&
      _makro(_carbs) != null &&
      _makro(_fat) != null;

  bool get _makrosGueltig =>
      _makroFeldOk(_protein) && _makroFeldOk(_carbs) && _makroFeldOk(_fat);

  /// Was die Eingabe fuer die Makros der GANZEN Mahlzeit bedeutet — sichtbar,
  /// bevor der Nutzer auf "Hinzufügen" tippt (B8). Der Wortlaut deckt sich mit
  /// dem, was danach in `portionNotes` steht.
  String get _makroHinweis {
    final l10n = context.l10n;
    if (!_alleMakrosGesetzt) {
      return l10n.foodMacroHintIncomplete;
    }
    if (!widget.restTraegtMakros) {
      return l10n.foodMacroHintOthersIncomplete;
    }
    return l10n.foodMacroHintComplete;
  }

  bool get _isValid {
    if (_name.text.trim().isEmpty) return false;
    final g = int.tryParse(_grams.text.trim());
    final k = int.tryParse(_kcal.text.trim());
    return g != null && g > 0 && k != null && k >= 0 && _makrosGueltig;
  }

  void _submit() {
    final name = _name.text.trim();
    final grams = int.tryParse(_grams.text.trim()) ?? 0;
    final kcal = int.tryParse(_kcal.text.trim()) ?? 0;
    if (name.isEmpty || grams <= 0 || !_makrosGueltig) return;
    final per100 = grams > 0 ? kcal * 100 / grams : null;
    Navigator.pop(
      context,
      MealComponent(
        name: name,
        grams: grams,
        caloriesKcal: kcal,
        kcalPer100G: per100,
        proteinG: _makro(_protein),
        carbsG: _makro(_carbs),
        fatG: _makro(_fat),
      ),
    );
  }

  /// D5: laeuft fuer jeden abgefangenen Dismiss-Versuch dieses Dialogs —
  /// Tap neben den Dialog, System-Zurueck und „Abbrechen" kommen ueber
  /// [PopScope]. Ein Drag-Guard braucht es hier nicht: ein Dialog laesst sich
  /// nicht wegziehen.
  bool _discardDialogOpen = false;

  Future<void> _askDiscard() async {
    if (_discardDialogOpen) return;
    _discardDialogOpen = true;
    final verwerfen = await _confirmDiscardChanges(
      context,
      context.l10n.foodDiscardNewItemBody,
    );
    _discardDialogOpen = false;
    if (!mounted || !verwerfen) return;
    // Genau EINE Ebene geht zu: dieser Dialog. Das Sheet darunter behaelt
    // seine Gewichte, und `_addItemDialog` sieht `null` — es wird also auch
    // kein halbfertiger Posten angehaengt.
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return PopScope<MealComponent?>(
      // Nur solange wirklich etwas drinsteht. Ein leerer Dialog schliesst wie
      // bisher sofort.
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _askDiscard();
      },
      child: AlertDialog(
        backgroundColor: t.surf,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rSheet),
        ),
        title: Text(
          l10n.foodAddItemTitle,
          style: AppType.display(18, color: t.ink),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.foodAddItemManualHint,
                style: AppType.ui(
                  12,
                  weight: FontWeight.w500,
                  color: t.ink2,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const ValueKey('analyse-add-item-name'),
                cursorOpacityAnimates: false,
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: l10n.foodAddItemNameLabel,
                  hintText: l10n.foodAddItemNameHint,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('analyse-add-item-grams'),
                      cursorOpacityAnimates: false,
                      controller: _grams,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      decoration: InputDecoration(
                        labelText: l10n.foodAddItemWeightLabel,
                        suffixText: 'g',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('analyse-add-item-kcal'),
                      cursorOpacityAnimates: false,
                      controller: _kcal,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      decoration: InputDecoration(
                        labelText: l10n.foodAddItemCaloriesLabel,
                        suffixText: 'kcal',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Aufklappbar statt drei weiterer Pflichtfelder: der schnelle Pfad
              // bleibt Name + Gramm + Kalorien.
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const ValueKey('analyse-add-item-macros-toggle'),
                  onPressed: () =>
                      setState(() => _makrosOffen = !_makrosOffen),
                  style: TextButton.styleFrom(
                    foregroundColor: t.ink,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: Icon(
                    _makrosOffen
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 16,
                  ),
                  label: Text(
                    l10n.foodAddItemMacrosToggle,
                    style: AppType.ui(12, weight: FontWeight.w600),
                  ),
                ),
              ),
              if (_makrosOffen) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: _MacroField(
                        fieldKey: const ValueKey('analyse-add-item-protein'),
                        controller: _protein,
                        label: l10n.todayMacroProtein,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MacroField(
                        fieldKey: const ValueKey('analyse-add-item-carbs'),
                        controller: _carbs,
                        label: l10n.foodMacroTileCarbsLabel,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MacroField(
                        fieldKey: const ValueKey('analyse-add-item-fat'),
                        controller: _fat,
                        label: l10n.todayMacroFat,
                      ),
                    ),
                  ],
                ),
                if (!_makrosGueltig) ...[
                  const SizedBox(height: 6),
                  Text(
                    l10n.foodMacroRangeHint,
                    style: AppType.ui(
                      11,
                      weight: FontWeight.w600,
                      color: t.warning,
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 10),
              Text(
                _makroHinweis,
                key: const ValueKey('analyse-add-item-macro-hint'),
                style: AppType.ui(
                  11,
                  weight: FontWeight.w500,
                  color: t.ink2,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            // maybePop statt pop: auch der ausdrueckliche Abbruch laeuft ueber
            // die Rueckfrage, sobald etwas drinsteht — genau wie das
            // Schliessen-Kreuz im Bearbeiten-Sheet (edit_meal_sheet.dart:367).
            onPressed: () => Navigator.of(context).maybePop(),
            style: TextButton.styleFrom(foregroundColor: t.ink2),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            key: const ValueKey('analyse-add-item-save'),
            onPressed: _isValid ? _submit : null,
            style: FilledButton.styleFrom(
              backgroundColor: t.forest,
              foregroundColor: t.onForest,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(rControl),
              ),
            ),
            child: Text(
              l10n.commonAdd,
              style: AppType.ui(14, weight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
