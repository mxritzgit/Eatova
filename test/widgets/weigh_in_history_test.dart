// The weigh-in history and the dated weigh-in sheet (review 2026-10-19): the
// profile's weight card opens all weigh-ins newest first, a row opens the
// edit sheet (value, day, time, delete), a row cached without its id waits
// for the next sync, and a new weigh-in is "now" unless a day or time is
// picked.

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/user_profile.dart';
import 'package:eatova/src/models/weight_log.dart';
import 'package:eatova/src/services/local_day.dart';
import 'package:eatova/src/widgets/profile/profile_widgets.dart';

import '../support/harness.dart';
import '../support/pinned_clock.dart';

final DateTime _noon = DateTime(2026, 10, 19, 12);

const _older = 'w-older', _newer = 'w-newer';

/// Records what the sheets ask for and serves a live log.
class _Weighins {
  _Weighins(this.log);

  WeightLog log;
  final changes = ValueNotifier<int>(0);
  final logged = <(double, DateTime?)>[];
  final updated = <(String, double, DateTime)>[];
  final deleted = <String>[];

  WeighInActions get actions => WeighInActions(
    changes: changes,
    log: () => log,
    logAt: (kg, at) async => logged.add((kg, at)),
    update: (id, kg, at) async => updated.add((id, kg, at)),
    delete: (id) async {
      deleted.add(id);
      log = log.removeEntry(id);
      changes.value++;
    },
  );
}

WeightLog _log() => WeightLog(
  entries: <WeightLogEntry>[
    // Cached by an older build: no id yet.
    WeightLogEntry(timestamp: DateTime(2026, 10, 14, 7, 5), weightKg: 81.0),
    WeightLogEntry(
      timestamp: DateTime(2026, 10, 16, 7, 10),
      weightKg: 80.0,
      id: _older,
    ),
    WeightLogEntry(
      timestamp: DateTime(2026, 10, 18, 6, 45, 12),
      weightKg: 79.5,
      id: _newer,
    ),
  ],
);

Finder _day(int back) {
  final today = DateUtils.dateOnly(clock.now());
  return find.byKey(
    ValueKey<String>(
      'today-day-${localDayKey(DateTime(today.year, today.month, today.day - back))}',
    ),
  );
}

Future<void> _pumpCard(WidgetTester tester, _Weighins weighins) async {
  pinPhoneViewport(tester);
  await pumpLocalized(
    tester,
    WeightCard(
      profile: const UserProfile(weightKg: 80),
      log: weighins.log,
      onLogWeight: (_) {},
      weighIns: weighins.actions,
    ),
    padding: const EdgeInsets.all(20),
    scrollable: true,
    settle: true,
  );
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgetsRobust('the history lists all weigh-ins, newest first', (tester) => withClockAt(_noon, () async {
    final weighins = _Weighins(_log());
    await _pumpCard(tester, weighins);

    await _tapVisible(tester, find.byKey(const ValueKey('weigh-in-history-open')));

    expect(find.byKey(const ValueKey('weigh-in-history')), findsOneWidget);
    expect(find.text('Wiegungen'), findsOneWidget);
    final newer = tester.getTopLeft(find.byKey(const ValueKey('weigh-in-row-$_newer')));
    final older = tester.getTopLeft(find.byKey(const ValueKey('weigh-in-row-$_older')));
    expect(newer.dy, lessThan(older.dy));
    expect(find.text('Gestern · 06:45'), findsOneWidget);
    expect(find.text('79,5 kg'), findsOneWidget);

    // The row without an id says why it cannot be edited yet.
    expect(find.text('Nach dem nächsten Abgleich bearbeitbar'), findsOneWidget);
    await _tapVisible(tester, find.text('81 kg'));
    expect(find.text('Wiegung bearbeiten'), findsNothing);
  }));

  testWidgetsRobust('an edit keeps the exact moment unless day or time change', (tester) => withClockAt(_noon, () async {
    final weighins = _Weighins(_log());
    await _pumpCard(tester, weighins);
    await _tapVisible(tester, find.byKey(const ValueKey('weigh-in-history-open')));

    await _tapVisible(tester, find.byKey(const ValueKey('weigh-in-row-$_newer')));
    expect(find.text('Wiegung bearbeiten'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('profile-weight-input')))
          .controller!
          .text,
      '79,5',
    );

    await tester.enterText(find.byKey(const ValueKey('profile-weight-input')), '79,1');
    await _tapVisible(tester, find.byKey(const ValueKey('profile-weight-save')));

    expect(weighins.updated, [(_newer, 79.1, DateTime(2026, 10, 18, 6, 45, 12))]);
    expect(find.text('Wiegung bearbeiten'), findsNothing);

    // Another day keeps the time of day.
    await _tapVisible(tester, find.byKey(const ValueKey('weigh-in-row-$_newer')));
    await _tapVisible(tester, _day(3));
    await _tapVisible(tester, find.byKey(const ValueKey('profile-weight-save')));
    expect(weighins.updated.last, (_newer, 79.5, DateTime(2026, 10, 16, 6, 45)));
  }));

  testWidgetsRobust('delete removes the row from the open history', (tester) => withClockAt(_noon, () async {
    final weighins = _Weighins(_log());
    await _pumpCard(tester, weighins);
    await _tapVisible(tester, find.byKey(const ValueKey('weigh-in-history-open')));
    await _tapVisible(tester, find.byKey(const ValueKey('weigh-in-row-$_older')));

    await _tapVisible(tester, find.byKey(const ValueKey('weigh-in-delete')));

    expect(weighins.deleted, [_older]);
    expect(find.text('Wiegung bearbeiten'), findsNothing);
    expect(find.byKey(const ValueKey('weigh-in-row-$_older')), findsNothing);
    expect(find.byKey(const ValueKey('weigh-in-row-$_newer')), findsOneWidget);
  }));

  testWidgetsRobust('a new weigh-in is now unless a day is picked', (tester) => withClockAt(_noon, () async {
    final weighins = _Weighins(_log());
    await _pumpCard(tester, weighins);

    await _tapVisible(tester, find.byKey(const ValueKey('profile-log-weight')));
    expect(find.text('Zeitpunkt'), findsOneWidget);
    expect(find.text('Jetzt'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('profile-weight-input')), '79,8');
    await _tapVisible(tester, find.byKey(const ValueKey('profile-weight-save')));
    expect(weighins.logged, [(79.8, null)]);

    await _tapVisible(tester, find.byKey(const ValueKey('profile-log-weight')));
    await _tapVisible(tester, _day(1));
    await _tapVisible(tester, find.byKey(const ValueKey('profile-weight-save')));
    final now = clock.now();
    final (kg, at) = weighins.logged.last;
    expect(kg, 79.5, reason: 'prefilled with the latest weigh-in');
    expect(at, DateTime(now.year, now.month, now.day - 1, now.hour, now.minute));
  }));

  testWidgetsRobust('the sheet links the history', (tester) => withClockAt(_noon, () async {
    final weighins = _Weighins(_log());
    await _pumpCard(tester, weighins);
    await _tapVisible(tester, find.byKey(const ValueKey('profile-log-weight')));

    await _tapVisible(tester, find.byKey(const ValueKey('weigh-in-history-link')));

    expect(find.byKey(const ValueKey('profile-weight-input')), findsNothing);
    expect(find.byKey(const ValueKey('weigh-in-history')), findsOneWidget);
  }));

  testWidgetsRobust('without actions the card keeps the plain sheet', (tester) => withClockAt(_noon, () async {
    pinPhoneViewport(tester);
    await pumpLocalized(
      tester,
      WeightCard(
        profile: const UserProfile(weightKg: 80),
        log: _log(),
        onLogWeight: (_) {},
      ),
      padding: const EdgeInsets.all(20),
      scrollable: true,
      settle: true,
    );

    expect(find.byKey(const ValueKey('weigh-in-history-open')), findsNothing);
    await _tapVisible(tester, find.byKey(const ValueKey('profile-log-weight')));
    expect(find.text('Zeitpunkt'), findsNothing);
  }));
}
