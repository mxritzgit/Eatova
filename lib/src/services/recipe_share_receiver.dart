import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Untrusted text handed to Eatova by the system share sheet.
class SharedRecipeSource {
  const SharedRecipeSource({required this.id, required this.text});

  final String id;
  final String text;
}

/// Consumes native shares once, including shares received before Flutter starts.
/// Callers subscribe before [start] and clear their own UI state on account change.
class RecipeShareReceiver with WidgetsBindingObserver {
  RecipeShareReceiver({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('eatova/recipe_share');

  static const maxTextLength = 20000;
  final MethodChannel _channel;
  final _shares = StreamController<SharedRecipeSource>.broadcast(sync: true);
  final _seenIds = <String>{};
  Future<void>? _refreshing;
  bool _refreshAgain = false;
  bool _started = false;
  bool _disposed = false;
  bool _ownerBound = false;
  String? _owner;
  int _generation = 0;

  Stream<SharedRecipeSource> get shares => _shares.stream;

  /// Binds a nonsecret hash of the current user/session before native delivery.
  /// Explicit null means signed out; it is different from not bound yet.
  void bindOwner(String? ownerKey) {
    if (ownerKey != null && !RegExp(r'^[0-9a-f]{64}$').hasMatch(ownerKey)) {
      throw ArgumentError('Invalid share owner');
    }
    if (_disposed || (_ownerBound && _owner == ownerKey)) return;
    _ownerBound = true;
    _owner = ownerKey;
    _generation++;
    _seenIds.clear();
  }

  Future<void> start() async {
    if (_disposed || _started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'sharesAvailable') await refresh();
    });
    await refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  Future<void> refresh() {
    if (_disposed || !_ownerBound || !_shares.hasListener) {
      return Future<void>.value();
    }
    final active = _refreshing;
    if (active != null) {
      _refreshAgain = true;
      return active;
    }
    final completer = Completer<void>();
    _refreshing = completer.future;
    unawaited(_drain(completer));
    return completer.future;
  }

  Future<void> _drain(Completer<void> completer) async {
    try {
      do {
        _refreshAgain = false;
        final generation = _generation;
        final values = await _channel.invokeMethod<Object?>('consumePending', {
          'owner': _owner,
        });
        if (_disposed) break;
        if (generation != _generation || values is! List) continue;
        for (final value in values.take(8)) {
          if (_disposed || generation != _generation) break;
          if (value is! Map) continue;
          final id = value['id'];
          final rawText = value['text'];
          if (id is! String ||
              id.isEmpty ||
              id.length > 128 ||
              rawText is! String ||
              rawText.length > maxTextLength ||
              rawText.contains('\u0000')) {
            continue;
          }
          final text = rawText.trim();
          if (text.isEmpty || !_seenIds.add(id)) continue;
          if (_seenIds.length > 128) _seenIds.remove(_seenIds.first);
          _shares.add(SharedRecipeSource(id: id, text: text));
        }
      } while (_refreshAgain && !_disposed);
    } on MissingPluginException {
      // Desktop tests and older native builds do not expose this channel.
    } on PlatformException {
      // Protected iOS files can be unavailable while the device is locked.
      // Keep them native-side and retry on the next foreground transition.
    } finally {
      _refreshing = null;
      completer.complete();
    }
  }

  /// Invalidates in-flight results before clearing native pending content.
  Future<void> clearPending() async {
    if (!_ownerBound) throw StateError('Share owner has not been bound');
    _generation++;
    _seenIds.clear();
    try {
      await _channel.invokeMethod<void>('clearPending', {'owner': _owner});
    } on MissingPluginException {
      // No native inbox exists on unsupported platforms.
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    if (_started) {
      WidgetsBinding.instance.removeObserver(this);
      _channel.setMethodCallHandler(null);
    }
    await _shares.close();
  }
}
