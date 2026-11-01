import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/cooking_timers.dart';

// The cooking mode offers a timer button per time a step names. German and
// English units are read in both languages; a range times its lower end.

const Duration _s = Duration(seconds: 1);
const Duration _m = Duration(minutes: 1);
const Duration _h = Duration(hours: 1);

void main() {
  test('Zeitangaben im Schritt werden zu Timern, Grenzfaelle zu keinem', () {
    final cases = <String, List<Duration>>{
      // German
      'Nudeln 10 Minuten kochen.': [_m * 10],
      'Bei 200 °C 25 Min. backen.': [_m * 25],
      '10 min ziehen lassen': [_m * 10],
      'Mindestens 1 Std. kühlen.': [_h],
      '1 Std. 30 Min. schmoren': [_h + _m * 30],
      '1 Stunde und 15 Minuten garen': [_h + _m * 15],
      '1,5 Stunden quellen lassen': [_m * 90],
      '1½ Stunden ruhen lassen': [_m * 90],
      '45 Sekunden pürieren': [_s * 45],
      'eine halbe Stunde marinieren': [_m * 30],
      '4–5 Minuten pro Seite braten, dann 3 Minuten ruhen lassen.': [
        _m * 4,
        _m * 3,
      ],
      'Wenden und nochmals 4 Minuten, dann weitere 4 Minuten.': [_m * 4],
      // English
      'Boil for 10 minutes.': [_m * 10],
      'Simmer 10 mins, then rest 5 min.': [_m * 10, _m * 5],
      'Bake for 1 hr.': [_h],
      'Chill for 2 hours.': [_h * 2],
      'Roast 1 hour 30 minutes.': [_h + _m * 30],
      'Blend for 30 sec.': [_s * 30],
      'Leave for half an hour.': [_m * 30],
      // Ranges: the lower end, never the upper alone
      '10–12 Minuten garen': [_m * 10],
      '10-12 Minuten garen': [_m * 10],
      '10 bis 12 Minuten garen': [_m * 10],
      'Cook 8 to 10 minutes.': [_m * 8],
      '1,5–2 Minuten anrösten': [_s * 90],
      // No timer
      'Über Nacht im Kühlschrank quellen lassen.': [],
      'Leave to soak overnight.': [],
      'Ein paar Minuten ruhen lassen.': [],
      'Cook for a few minutes.': [],
      '24 Stunden marinieren.': [],
      'Um 1:30 Uhr anbraten.': [],
      'Bei 180 °C mit 2 EL Öl.': [],
      'Add 2 mini peppers and 2 heads of garlic.': [],
      '': [],
    };
    for (final MapEntry(key: step, value: timers) in cases.entries) {
      expect(cookingTimersIn(step), timers, reason: step);
    }
  });
}
