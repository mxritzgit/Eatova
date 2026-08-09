import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../models/logged_meal.dart';
import '../../models/meal_analysis_result.dart';
import '../../models/meal_component.dart';
import '../../services/open_food_facts_product_service.dart';
import '../../theme/app_tokens.dart';
import '../../theme/meal_slot_style.dart';
import '../common/app_snack.dart';
import '../design/design.dart';
import '../meal/meal_widgets.dart';

/// Meldung, wenn eine Mahlzeit ohne Kalorienangabe geloggt werden soll.
/// Als Konstante, damit Tests denselben Wortlaut pruefen wie die Oberflaeche.
const String kMealWithoutCaloriesMessage =
    'Ohne Kalorienangabe lässt sich nichts loggen. Trag die Bestandteile über '
    '„Anpassen" ein.';

/// Mappt einen Analyse-/Lookup-Fehler auf die Snack-Meldung fuer den Nutzer.
///
/// Zwei Faelle sind praeziser als die generische [fallback]-Meldung des
/// jeweiligen Flows:
///
///  * [TimeoutException] — Analyzer und Produkt-Lookups werfen den, seit alle
///    HTTP-Phasen explizite `.timeout(...)` tragen. "Prüfe Internet, Supabase
///    und OpenRouter" waere hier irrefuehrend: die Verbindung stand, nur die
///    Antwort blieb aus.
///  * [ProductWithoutNutritionException] — der Service hat das Produkt
///    gefunden, es traegt nur keine loggbare Energieangabe. Die
///    Barcode-Fallback-Meldung ("nicht gefunden oder OpenFoodFacts nicht
///    erreichbar") waere schlicht falsch: der Nutzer haelt das Produkt in der
///    Hand. Der Fehler bringt seine Meldung inklusive Produktname und
///    gemessenem Wert bereits mit.
String mealAnalysisErrorMessage(Object error, String fallback) {
  if (error is TimeoutException) {
    return 'Das dauert gerade zu lange. Bitte versuch es gleich nochmal.';
  }
  if (error is ProductWithoutNutritionException) {
    return error.userMessage;
  }
  return fallback;
}

/// Sub-Sheet fuer die Foto-/Barcode-Analyse. Wird vom AddMealSheet
/// gestartet sobald ein Bild aufgenommen oder ein Barcode gescannt wurde.
/// Zeigt das Loading-Card, danach die `MealResultCard` mit Anpassen +
/// Hinzufuegen — der Bestaetigen-Schritt entfaellt.
Future<void> showMealAnalysisSheet(
  BuildContext context, {
  required MealSlot slot,
  required Future<MealAnalysisResult> resultFuture,
  required Uint8List? previewImage,
  required String Function(MealAnalysisResult, MealSlot) onAdd,
  required void Function(String id, MealAnalysisResult scaled) onUpdateMeal,
  required String failureMessage,
  bool Function(MealAnalysisResult)? isFavorite,
  ValueChanged<MealAnalysisResult>? onToggleFavorite,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (sheetContext) {
      return MealAnalysisSheet(
        slot: slot,
        resultFuture: resultFuture,
        previewImage: previewImage,
        onAdd: onAdd,
        onUpdateMeal: onUpdateMeal,
        failureMessage: failureMessage,
        isFavorite: isFavorite,
        onToggleFavorite: onToggleFavorite,
      );
    },
  );
}

class MealAnalysisSheet extends StatefulWidget {
  const MealAnalysisSheet({
    super.key,
    required this.slot,
    required this.resultFuture,
    required this.previewImage,
    required this.onAdd,
    required this.onUpdateMeal,
    required this.failureMessage,
    this.isFavorite,
    this.onToggleFavorite,
  });

  final MealSlot slot;
  final Future<MealAnalysisResult> resultFuture;
  final Uint8List? previewImage;

  /// Loggt das Ergebnis in die Tagesbilanz und liefert die Client-UUID der
  /// neu geloggten Zeile zurueck. Das Sheet merkt sich diese id, um eine
  /// spaetere Um-Portionierung GEZIELT auf genau diese Zeile anzuwenden.
  final String Function(MealAnalysisResult, MealSlot) onAdd;

  /// Ersetzt das Ergebnis der bereits geloggten Zeile [id] durch das neu
  /// skalierte [scaled] (korrekte kcal UND Makros). Loest den frueheren
  /// Bug, bei dem nur ein kcal-Delta floss (Makros eingefroren) und zudem
  /// die falsche Mahlzeit getroffen wurde.
  final void Function(String id, MealAnalysisResult scaled) onUpdateMeal;
  final String failureMessage;

  /// Ob die aktuelle Mahlzeit als Favorit angeheftet ist (Herz gefuellt).
  final bool Function(MealAnalysisResult)? isFavorite;

  /// Favoriten-Toggle. Null -> kein Herz-Button.
  final ValueChanged<MealAnalysisResult>? onToggleFavorite;

  @override
  State<MealAnalysisSheet> createState() => _MealAnalysisSheetState();
}

class _MealAnalysisSheetState extends State<MealAnalysisSheet> {
  MealAnalysisResult? _result;
  bool _isLoading = true;
  bool _addedToDailyTotal = false;
  // Client-UUID der geloggten Zeile (gesetzt beim Hinzufuegen). Eine spaetere
  // Um-Portionierung wird genau auf diese id angewandt.
  String? _addedMealId;
  // Lokaler optimistischer Favoriten-Zustand: das Sheet liegt in einer eigenen
  // modalen Route, ein setState der HomePage rebuildet es NICHT. Der Toggle
  // spiegelt sich daher hier lokal, damit das Herz sofort umschaltet.
  bool? _favoriteOverride;

  @override
  void initState() {
    super.initState();
    _loadResult();
  }

  bool get _isFavoriteNow {
    final result = _result;
    if (result == null) return false;
    return _favoriteOverride ?? widget.isFavorite?.call(result) ?? false;
  }

  void _handleToggleFavorite(MealAnalysisResult result) {
    final next = !_isFavoriteNow;
    widget.onToggleFavorite?.call(result);
    setState(() => _favoriteOverride = next);
  }

  Future<void> _loadResult() async {
    try {
      final value = await widget.resultFuture;
      if (!mounted) return;
      setState(() {
        _result = value;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      showAppSnack(
          context, mealAnalysisErrorMessage(error, widget.failureMessage),
          icon: Icons.error_outline_rounded,
          tone: SnackTone.error,
          duration: kSnackError);
      Navigator.of(context).maybePop();
    }
  }

  void _addToDaily() {
    final result = _result;
    if (result == null || _addedToDailyTotal) return;

    // Letzte Bremse vor dem Tagebuch (B7). Suche und Barcode liefern seit
    // Welle 2 nichts Unloggbares mehr — dort wirft
    // [ProductWithoutNutritionException] schon im Service. Der Foto-KI-Pfad
    // laeuft an diesem Filter vorbei, und ein 0-kcal-Eintrag ist im Tagebuch
    // nicht als "unbekannt" erkennbar: er sieht aus wie eine Mahlzeit ohne
    // Kalorien und verfaelscht die Tagesbilanz still.
    //
    // Bewusst KEIN stiller Abbruch und kein deaktivierter Knopf: der Nutzer
    // erfaehrt den Grund und den Weg heraus ("Anpassen" -> Bestandteile
    // eintragen), und der Knopf wirkt danach ganz normal.
    //
    // explicitZeroKcal: eine GEMESSENE 0 (Wasser, Zero) traegt ihren Marker
    // aus der Produktdatenbank und darf ins Tagebuch — die Bremse gilt dem
    // Sentinel „0 = unbekannt", nicht dem Produkt.
    if (result.caloriesKcal <= 0 && !result.explicitZeroKcal) {
      showAppSnack(
        context,
        kMealWithoutCaloriesMessage,
        icon: Icons.error_outline_rounded,
        tone: SnackTone.error,
        duration: kSnackError,
      );
      return;
    }

    final id = widget.onAdd(result, widget.slot);
    setState(() {
      _addedToDailyTotal = true;
      _addedMealId = id;
    });
    showAppSnack(
      context,
      '${result.caloriesKcal} kcal zu ${widget.slot.label} hinzugefügt.',
      icon: Icons.check_circle_rounded,
    );
  }

  Future<void> _adjustPortion() async {
    final current = _result;
    if (current == null) return;

    final adjustment = await showWeightAdjustmentSheet(context, current);
    if (!mounted || adjustment == null) return;

    MealAnalysisResult? candidate;
    if (adjustment is int && adjustment > 0) {
      candidate = current.adjustedToGrams(adjustment);
    } else if (adjustment is List<MealComponent>) {
      candidate = current.adjustedToItems(adjustment);
    }
    if (candidate == null) return;
    final updated = candidate;

    final wasAdded = _addedToDailyTotal;
    final loggedId = _addedMealId;

    setState(() {
      _result = updated;
    });

    // War die Mahlzeit bereits geloggt: das KOMPLETTE skalierte Ergebnis
    // (kcal UND Makros) auf genau diese Zeile uebergeben. Frueher floss nur
    // ein kcal-Delta -> Makros eingefroren + falsche Mahlzeit getroffen.
    if (wasAdded && loggedId != null) {
      widget.onUpdateMeal(loggedId, updated);
    }

    if (adjustment is int && adjustment > 0) {
      final message = wasAdded
          ? '$adjustment g angepasst. Tageswert aktualisiert.'
          : '$adjustment g angepasst.';
      showAppSnack(context, message, icon: Icons.tune_rounded);
    } else if (adjustment is List<MealComponent>) {
      final message = wasAdded
          ? '${updated.estimatedGrams} g über Einzelposten angepasst. Tageswert aktualisiert.'
          : '${updated.estimatedGrams} g über Einzelposten angepasst.';
      showAppSnack(context, message, icon: Icons.tune_rounded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final mediaQuery = MediaQuery.of(context);
    final maxHeight = mediaQuery.size.height * 0.92;
    final keyboardInset = mediaQuery.viewInsets.bottom;

    // Bewusst kein SheetScaffold: das braucht einen fixen Titel plus genau
    // eine Fussaktion. Hier sitzt ueber einem gedeckelten Scrollbereich ein
    // fixer Kopf, und die Aktionen liegen auf der Ergebniskarte.
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Container(
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: BoxDecoration(
          color: t.bg,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(rSheet),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SheetHandle(),
            _Header(slot: widget.slot, onClose: () => Navigator.of(context).pop()),
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  20,
                  0,
                  20,
                  28 + mediaQuery.viewPadding.bottom,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.previewImage != null) ...[
                      MealPreviewCard(imageBytes: widget.previewImage),
                      const SizedBox(height: 14),
                    ],
                    if (_isLoading)
                      const MealLoadingCard()
                    else if (_result != null)
                      MealResultCard(
                        result: _result!,
                        addedToDailyTotal: _addedToDailyTotal,
                        onAdjustRequested: _adjustPortion,
                        onAddToDailyRequested: _addToDaily,
                        isFavorite: _isFavoriteNow,
                        onToggleFavorite: widget.onToggleFavorite == null
                            ? null
                            : _handleToggleFavorite,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 6),
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: context.t.line,
          borderRadius: BorderRadius.circular(rPill),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.slot, required this.onClose});

  final MealSlot slot;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final color = slot.accentIn(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 8, 12),
      child: Row(
        children: [
          MealAvatar(letter: slot.initial, color: color, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  slot.label,
                  style: AppType.display(18, color: t.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  'Analyse prüfen',
                  style: AppType.ui(
                    12,
                    weight: FontWeight.w500,
                    color: t.ink2,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('analyse-sheet-close'),
            onPressed: onClose,
            tooltip: 'Schließen',
            icon: Icon(Icons.close_rounded, color: t.ink2),
          ),
        ],
      ),
    );
  }
}
