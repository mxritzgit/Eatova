import 'package:flutter/widgets.dart';

/// Baut [builder] und rebuildet ihn NUR dann erneut, wenn sich der von
/// [selector] zurueckgegebene Wert (per `==`) gegenueber dem letzten Build
/// aendert — selbst wenn [store] oefter `notifyListeners()` feuert.
///
/// Damit lassen sich einzelne Karten-Subtrees an genau ihre Slice eines
/// [ChangeNotifier]-Stores haengen (PERF-2): ein Wasser-Quick-Log, der den Store
/// notifyt, rebuildet nur die Selektoren, deren Slice sich wirklich aenderte —
/// nicht den ganzen Today-Baum.
///
/// Tipp: einen **Record** als Slice zurueckgeben (`() => (store.a, store.b)`)
/// nutzt dessen strukturelle Gleichheit; Objekt-Slices ohne `==` vergleichen per
/// Identitaet, was korrekt ist, solange der Store sie bei Aenderung neu zuweist.
///
/// **Regel (aus G11):** in den Selektor gehoeren die EINGANGSgroessen, nicht die
/// abgeleiteten Werte. Ein Getter wie `mealsForFoodDate(date)` filtert bei jedem
/// Aufruf in eine NEUE Liste — als Slice waere er per Identitaet immer
/// „geaendert" (der Selektor liefe also leer) und allokierte obendrein bei jedem
/// Notify. Die Store-Liste selbst (`loggedMeals`) wird dagegen bei jeder
/// Mutation neu zugewiesen: ihre Identitaet ist ein exakter, O(1)-billiger
/// Fingerabdruck derselben Information. Faustregel: der Selektor darf nichts
/// allokieren ausser dem Record.
class StoreSelector extends StatefulWidget {
  const StoreSelector({
    super.key,
    required this.store,
    required this.selector,
    required this.builder,
  });

  /// Der zu beobachtende [Listenable] (i.d.R. ein `ChangeNotifier`-Store).
  final Listenable store;

  /// Berechnet die fuer diesen Subtree relevante Slice. Wird bei jedem
  /// Store-Notify ausgewertet; nur eine `!=`-Aenderung loest einen Rebuild aus.
  final Object? Function() selector;

  /// Baut den Subtree. Liest den aktuellen Store-Stand direkt (der Selektor-Wert
  /// dient nur der Aenderungserkennung).
  final WidgetBuilder builder;

  @override
  State<StoreSelector> createState() => _StoreSelectorState();
}

class _StoreSelectorState extends State<StoreSelector> {
  late Object? _value;

  @override
  void initState() {
    super.initState();
    _value = widget.selector();
    widget.store.addListener(_onStoreChanged);
  }

  @override
  void didUpdateWidget(StoreSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.store, widget.store)) {
      oldWidget.store.removeListener(_onStoreChanged);
      widget.store.addListener(_onStoreChanged);
    }
    // Selektor-Wert nach einem Parent-Rebuild neu festhalten, damit die
    // Aenderungserkennung gegen den frisch gebauten Stand laeuft.
    _value = widget.selector();
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    final next = widget.selector();
    if (next != _value) {
      setState(() => _value = next);
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
