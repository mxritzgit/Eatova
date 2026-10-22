// App-icon shortcuts over the quick_actions plugin (review 2026-10-22): the
// four shortcuts in the app language, a launching pick that arrives before
// the shell listens, and Android's double report of that pick.

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quick_actions/quick_actions.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/services/app_entry.dart';
import 'package:eatova/src/services/app_shortcuts.dart';

class _FakeQuickActions implements QuickActions {
  QuickActionHandler? handler;
  int initializes = 0;
  int clears = 0;
  final List<List<ShortcutItem>> shown = <List<ShortcutItem>>[];

  @override
  Future<void> initialize(QuickActionHandler handler) async {
    initializes++;
    this.handler = handler;
  }

  @override
  Future<void> setShortcutItems(List<ShortcutItem> items) async =>
      shown.add(items);

  @override
  Future<void> clearShortcutItems() async => clears++;
}

void main() {
  test('Foto, Barcode, Beschreiben, Gewicht in der App-Sprache; das Plugin '
      'startet einmal', () async {
    final plugin = _FakeQuickActions();
    final shortcuts = PlatformAppShortcuts(plugin: plugin);

    for (final l10n in [deL10n, enL10n]) {
      await shortcuts.show(appShortcutsFor(l10n));
      final items = plugin.shown.last;
      expect(items.map((i) => i.type), [
        AppEntry.photo.id,
        AppEntry.barcode.id,
        AppEntry.describe.id,
        AppEntry.weighIn.id,
      ]);
      expect(items.map((i) => i.localizedTitle), [
        l10n.shortcutPhoto,
        l10n.shortcutBarcode,
        l10n.shortcutDescribe,
        l10n.shortcutWeighIn,
      ]);
    }
    await shortcuts.clear();

    expect(plugin.clears, 1);
    expect(plugin.initializes, 1);
  });

  test('der startende Kurzbefehl wartet auf die Shell und kommt einmal an, '
      'auch wenn Android ihn doppelt meldet', () async {
    var now = DateTime(2026, 10, 22, 8);
    await withClock(Clock(() => now), () async {
      final plugin = _FakeQuickActions();
      final shortcuts = PlatformAppShortcuts(plugin: plugin);
      expect(shortcuts.takePendingPick(), isNull);
      await pumpEventQueue();

      // Launch intent and buffered handler message, before anyone listens.
      plugin.handler!(AppEntry.photo.id);
      plugin.handler!(AppEntry.photo.id);
      plugin.handler!('unknown');
      expect(shortcuts.takePendingPick(), AppEntry.photo);
      expect(shortcuts.takePendingPick(), isNull);

      final picks = <AppEntry>[];
      final sub = shortcuts.picks.listen(picks.add);
      addTearDown(sub.cancel);
      plugin.handler!(AppEntry.photo.id);
      now = now.add(PlatformAppShortcuts.echoWindow);
      plugin.handler!(AppEntry.photo.id);
      plugin.handler!(AppEntry.weighIn.id);
      await pumpEventQueue();

      expect(picks, [AppEntry.photo, AppEntry.weighIn]);
    });
  });
}
