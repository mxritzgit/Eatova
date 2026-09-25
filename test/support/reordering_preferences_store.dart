import 'dart:async';

import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// Holds the first native write so a later preference choice can overtake it.
class ReorderingPreferencesStore extends InMemorySharedPreferencesStore {
  ReorderingPreferencesStore() : super.empty();

  final firstWriteStarted = Completer<void>();
  final _releaseFirstWrite = Completer<void>();
  int _writes = 0;

  void releaseFirstWrite() => _releaseFirstWrite.complete();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (_writes++ == 0) {
      firstWriteStarted.complete();
      await _releaseFirstWrite.future;
    }
    return super.setValue(valueType, key, value);
  }
}
