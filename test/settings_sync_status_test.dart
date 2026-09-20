import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/services/sync_outbox.dart';
import 'support/harness.dart';

void main() {
  for (final language in ['de', 'en']) {
    testWidgets('training conflict directs the user to review ($language)', (
      tester,
    ) async {
      await pumpLocalized(
        tester,
          SettingsScreen(
            pendingSyncCount: 1,
            syncBlockedReason: SyncBlockedReason.trainingHeadConflict,
            onSyncNow: () async {},
        ),
        locale: Locale(language),
      );
      final status = find.byKey(const ValueKey('settings-sync-status'));
      await tester.ensureVisible(status);
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          language == 'de' ? 'Übernahme prüfen' : 'Review adoption',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          language == 'de'
              ? 'Entwurf bleibt gespeichert'
              : 'draft remains saved',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'unreadable queue shows unknown status and permits retry ($language)',
      (tester) async {
        var retries = 0;
        await pumpLocalized(
          tester,
          SettingsScreen(
            syncStatusReadable: false,
            onSyncNow: () async {
              retries++;
            },
          ),
          locale: Locale(language),
        );
        final button = find.byKey(const ValueKey('settings-sync-retry'));
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        expect(
          find.text(
            language == 'de'
                ? 'Synchronisierungsstatus unbekannt'
                : 'Sync status unknown',
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            language == 'de'
                ? 'Keine offenen lokalen Änderungen.'
                : 'No pending local changes.',
          ),
          findsNothing,
        );
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(retries, 1);
      },
    );
  }

  testWidgets('blocked changes remain visible while an explicit retry runs', (
    tester,
  ) async {
    final commit = Completer<void>();
    var attempts = 0;
    await pumpLocalized(
      tester,
      SettingsScreen(
        pendingSyncCount: 2,
        syncBlockedReason: SyncBlockedReason.capacity,
        onSyncNow: () {
          attempts++;
          return commit.future;
        },
      ),
    );
    final status = find.byKey(const ValueKey('settings-sync-status'));
    await tester.ensureVisible(status);
    await tester.pumpAndSettle();
    expect(find.text('2 ausstehende Änderungen'), findsOneWidget);
    expect(find.textContaining('keine weiteren Änderungen'), findsOneWidget);
    final button = find.byKey(const ValueKey('settings-sync-retry'));
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    await tester.tap(button);
    expect(attempts, 1);
    expect(find.text('2 ausstehende Änderungen'), findsOneWidget);
    commit.completeError(StateError('synthetic failure'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(button).onPressed, isNotNull);
    expect(
      find.textContaining('Deine lokalen Änderungen bleiben gespeichert'),
      findsOneWidget,
    );
  });

  testWidgets('no pending changes never claims remote freshness', (
    tester,
  ) async {
    await pumpLocalized(tester, SettingsScreen(onSyncNow: () async {}));
    final button = find.byKey(const ValueKey('settings-sync-retry'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    expect(find.text('Keine offenen lokalen Änderungen.'), findsOneWidget);
    expect(tester.widget<TextButton>(button).onPressed, isNull);
  });
}
