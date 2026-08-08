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
    backgroundColor: surface,
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
  final verwerfen = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('discard-changes-dialog'),
      backgroundColor: surface,
      title: const Text(
        'Änderungen verwerfen?',
        style: TextStyle(color: textPrimary, fontWeight: FontWeight.w700),
      ),
      content: Text(text, style: const TextStyle(color: textMuted)),
      actions: [
        TextButton(
          key: const ValueKey('discard-changes-cancel'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Weiter bearbeiten'),
        ),
        TextButton(
          key: const ValueKey('discard-changes-confirm'),
          style: TextButton.styleFrom(foregroundColor: danger),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Verwerfen'),
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
      child: const SizedBox(
        width: double.infinity,
        height: 26,
        child: Center(
          child: SizedBox(
            width: 32,
            height: 4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: textMuted,
                borderRadius: BorderRadius.all(Radius.circular(rPill)),
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

  String _statusLine(int addedCount) {
    final parts = <String>[];
    if (_removed.isNotEmpty) parts.add('${_removed.length} entfernt');
    if (addedCount > 0) parts.add('$addedCount manuell ergänzt');
    if (parts.isEmpty) {
      return 'Pro Lebensmittel das Gewicht anpassen oder mit X entfernen.';
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
      'Deine Anpassungen an den Bestandteilen sind noch nicht übernommen.',
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
                      const Text(
                        'Bestandteile anpassen',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.4,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _statusLine(addedCount),
                        style: const TextStyle(
                          color: textMuted,
                          fontSize: 13,
                          height: 1.4,
                          fontWeight: FontWeight.w500,
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
                        label: const Text(
                          'Bestandteil hinzufügen',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: cyan,
                          side: BorderSide(color: cyan.withValues(alpha: 0.45)),
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
                      Container(
                        key: const ValueKey('analyse-adjusted-kcal-preview'),
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: surfaceSoft,
                          borderRadius: BorderRadius.circular(rControl),
                          border: Border.all(
                            color: orange.withValues(alpha: 0.18),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.calculate_outlined,
                              color: orange,
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '$totalGrams g ≈ $totalKcal kcal',
                                style: const TextStyle(
                                  color: orange,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                            if (adjustedItems.isNotEmpty)
                              Text(
                                '${adjustedItems.length} Posten',
                                style: const TextStyle(
                                  color: textMuted,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (adjustedItems.isEmpty) ...[
                        const SizedBox(height: 8),
                        const Text(
                          'Mindestens ein Bestandteil muss übrig bleiben.',
                          style: TextStyle(
                            color: warning,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
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
                          label: const Text(
                            'Übernehmen',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: orange,
                            foregroundColor: bg,
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

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('analyse-item-card-$index'),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: surfaceSoft,
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              IconButton(
                key: ValueKey('analyse-item-remove-$index'),
                onPressed: onRemove,
                tooltip: 'Entfernen',
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: textMuted,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            // Kein `onChanged`: das getippte Gewicht liest der Listener aus
            // `_neuerPosten` vom Controller. Eine zweite Quelle koennte
            // auseinanderlaufen — und `onChanged` feuert bei programmatisch
            // gesetztem Text gar nicht.
            child: TextField(
              key: ValueKey('analyse-item-weight-input-$index'),
              cursorOpacityAnimates: false,
              controller: controller,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: 'Gewicht',
                suffixText: 'g',
                helperText:
                    'Ursprünglich ${item.gramsLabel} · ${item.caloriesLabel}',
                helperStyle: const TextStyle(
                  color: textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Row(
              children: [
                const Icon(
                  Icons.local_fire_department_outlined,
                  size: 14,
                  color: orange,
                ),
                const SizedBox(width: 6),
                Text(
                  '$liveGrams g · $liveKcal kcal',
                  style: const TextStyle(
                    color: orange,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                if (item.kcalPer100G != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    '· ${item.kcalPer100G!.round()} kcal/100g',
                    style: const TextStyle(
                      color: textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      fontFeatures: [FontFeature.tabularFigures()],
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

class _RemovedItemCard extends StatelessWidget {
  const _RemovedItemCard({required this.name, required this.onUndo});

  final String name;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: surfaceSoft.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: hairline),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: textMuted,
                decoration: TextDecoration.lineThrough,
              ),
            ),
          ),
          TextButton.icon(
            onPressed: onUndo,
            style: TextButton.styleFrom(
              foregroundColor: cyan,
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 4,
              ),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.undo_rounded, size: 14),
            label: const Text(
              'Wiederherstellen',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
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
    if (!_alleMakrosGesetzt) {
      return 'Ohne alle drei Angaben werden Protein, Kohlenhydrate und Fett '
          'für die ganze Mahlzeit als „–" ausgewiesen.';
    }
    if (!widget.restTraegtMakros) {
      return 'Andere Bestandteile tragen keine Makros — die Mahlzeit weist '
          'Protein, Kohlenhydrate und Fett weiterhin als „–" aus.';
    }
    return 'Protein, Kohlenhydrate und Fett werden für die Mahlzeit exakt '
        'aufsummiert.';
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
      'Der neue Bestandteil ist noch nicht hinzugefügt.',
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
    return PopScope<MealComponent?>(
      // Nur solange wirklich etwas drinsteht. Ein leerer Dialog schliesst wie
      // bisher sofort.
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _askDiscard();
      },
      child: AlertDialog(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rSheet),
        ),
        title: const Text(
          'Bestandteil hinzufügen',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Manuell — wenn die KI etwas übersehen hat.',
                style: TextStyle(
                  color: textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const ValueKey('analyse-add-item-name'),
                cursorOpacityAnimates: false,
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'z. B. Tomate',
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
                      decoration: const InputDecoration(
                        labelText: 'Gewicht',
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
                      decoration: const InputDecoration(
                        labelText: 'Kalorien',
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
                    foregroundColor: cyan,
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
                  label: const Text(
                    'Makros ergänzen (optional)',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
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
                        label: 'Protein',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MacroField(
                        fieldKey: const ValueKey('analyse-add-item-carbs'),
                        controller: _carbs,
                        label: 'Carbs',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _MacroField(
                        fieldKey: const ValueKey('analyse-add-item-fat'),
                        controller: _fat,
                        label: 'Fett',
                      ),
                    ),
                  ],
                ),
                if (!_makrosGueltig) ...[
                  const SizedBox(height: 6),
                  const Text(
                    'Makros in Gramm, jeweils zwischen 0 und 1000.',
                    style: TextStyle(
                      color: warning,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 10),
              Text(
                _makroHinweis,
                key: const ValueKey('analyse-add-item-macro-hint'),
                style: const TextStyle(
                  color: textMuted,
                  fontSize: 11,
                  height: 1.4,
                  fontWeight: FontWeight.w500,
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
            style: TextButton.styleFrom(foregroundColor: textMuted),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            key: const ValueKey('analyse-add-item-save'),
            onPressed: _isValid ? _submit : null,
            style: FilledButton.styleFrom(
              backgroundColor: cyan,
              foregroundColor: bg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(rControl),
              ),
            ),
            child: const Text(
              'Hinzufügen',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
