import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pointycastle/digests/sha256.dart';

import '../auth/auth_repository.dart';
import 'recipe_share_receiver.dart';

/// Small in-memory handoff. Signed-out shares can wait for login; a transition
/// away from an existing session retires all of that session's drafts.
class RecipeImportInbox extends ChangeNotifier {
  RecipeImportInbox(this.receiver);

  final RecipeShareReceiver receiver;
  final _pending = Queue<SharedRecipeSource>();
  StreamSubscription<SharedRecipeSource>? _subscription;
  (String, String?)? _owner;
  bool _disposed = false;
  bool _clearing = false;
  int _generation = 0;
  int _clearGeneration = 0;
  bool _blocked = false;
  bool _userBound = false;
  bool _receiverStarted = false;

  bool get hasPending =>
      _pending.isNotEmpty && _owner != null && !_clearing && !_blocked;
  int get generation => _generation;

  Future<void> start() async {
    if (_disposed || _subscription != null) return;
    _subscription = receiver.shares.listen((source) {
      if (_disposed || !_userBound || _clearing || _blocked) return;
      if (_pending.length == 8) return;
      _pending.add(source);
      notifyListeners();
    });
    if (_userBound) await _startReceiver();
  }

  Future<void> _startReceiver() async {
    if (_disposed || _receiverStarted || _subscription == null) return;
    _receiverStarted = true;
    await receiver.start();
  }

  void bindUser(EatovaUser? user) {
    final next = user == null ? null : (user.id, user.sessionId);
    if (_disposed || (_userBound && next == _owner)) return;
    final previous = _owner;
    _userBound = true;
    _owner = next;
    _generation++;
    final ownerKey = next == null
        ? null
        : SHA256Digest()
              .process(
                Uint8List.fromList(utf8.encode(jsonEncode([next.$1, next.$2]))),
              )
              .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
              .join();
    receiver.bindOwner(ownerKey);
    if (previous != null) {
      _pending.clear();
      _clearing = true;
      final clearGeneration = ++_clearGeneration;
      _blocked = false;
      unawaited(
        receiver
            .clearPending()
            .catchError((Object _) {
              // A failed protected-store clear leaves this inbox closed for the run.
              if (!_disposed && clearGeneration == _clearGeneration) {
                _blocked = true;
              }
            })
            .whenComplete(() {
              if (_disposed || clearGeneration != _clearGeneration) return;
              _clearing = false;
              if (!_blocked && _receiverStarted) unawaited(receiver.refresh());
              notifyListeners();
            }),
      );
    }
    if (!_receiverStarted) {
      unawaited(_startReceiver());
    } else if (!_clearing && !_blocked) {
      unawaited(receiver.refresh());
    }
    // The AuthGate calls this while building its initial child. Consumers
    // schedule their actual route push after the current frame.
    notifyListeners();
  }

  SharedRecipeSource? take() => hasPending ? _pending.removeFirst() : null;

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _pending.clear();
    unawaited(_subscription?.cancel());
    unawaited(receiver.dispose());
    super.dispose();
  }
}
