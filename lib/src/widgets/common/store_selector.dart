import 'package:flutter/widgets.dart';

/// Builds [builder] and rebuilds it ONLY when the value returned by [selector]
/// changes by `==`, no matter how often [store] notifies.
///
/// Lets a card subtree subscribe to exactly its slice of a [ChangeNotifier]
/// store (PERF-2).
///
/// Return a **record** as the slice (`() => (store.a, store.b)`) to get
/// structural equality; object slices without `==` compare by identity, which
/// is correct as long as the store reassigns them on change.
///
/// **Rule (G11):** put INPUTS in the selector, not derived values. A getter
/// like `mealsForFoodDate(date)` filters into a NEW list on every call, so as a
/// slice it would always look "changed" and allocate on every notify. The store
/// list itself (`loggedMeals`) is reassigned on every mutation, making its
/// identity an exact O(1) fingerprint. The selector must allocate nothing but
/// the record.
class StoreSelector extends StatefulWidget {
  const StoreSelector({
    super.key,
    required this.store,
    required this.selector,
    required this.builder,
  });

  /// The observed [Listenable], usually a `ChangeNotifier` store.
  final Listenable store;

  /// Computes the slice relevant to this subtree. Evaluated on every store
  /// notify; only a `!=` change triggers a rebuild.
  final Object? Function() selector;

  /// Builds the subtree, reading the store directly — the selector value only
  /// drives change detection.
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
    // Re-capture the selector value after a parent rebuild, so change detection
    // runs against the freshly built state.
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
