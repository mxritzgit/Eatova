import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/app/home_store.dart';
import 'package:eatova/src/services/health_service.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/widgets/common/app_snack.dart';

// The avatar on the Today header shows `profileInitial`. It cut the first
// UTF-16 unit, so a display name starting with an emoji (a common Google
// profile name) left half a surrogate pair, which renders as a replacement
// glyph.

void _noopSnack(
  String message, {
  IconData icon = Icons.info_outline,
  SnackTone tone = SnackTone.positive,
  Duration? duration,
  SnackBarAction? action,
}) {}

HomeStore _store(String name) {
  final store = HomeStore(
    sync: null,
    health: const NoopHealthService(),
    notificationService: const NoopNotificationService(),
    initialUserName: name,
    emitSnack: _noopSnack,
  );
  addTearDown(store.dispose);
  return store;
}

void main() {
  test('ein Emoji am Namensanfang bleibt ein ganzes Zeichen', () {
    expect(_store('😀 Max').profileInitial, '😀');
  });

  test('ein zusammengesetztes Emoji wird nicht zerschnitten', () {
    expect(_store('👨‍👩‍👧 Familie').profileInitial, '👨‍👩‍👧');
  });

  test('Buchstaben werden weiter gross geschrieben', () {
    expect(_store('  moritz gietl').profileInitial, 'M');
    expect(_store('ömer').profileInitial, 'Ö');
  });

  test('ohne Namen bleibt das neutrale S', () {
    expect(_store('   ').profileInitial, 'S');
  });
}
