import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/widgets/common/motion.dart';

// Perf round 2026-08-31, finding 2: `reducedMotion`/`motionDuration` used
// `MediaQuery.maybeOf(...)?.disableAnimations`, which registers a dependency
// on the WHOLE MediaQueryData. Every frame of the keyboard-inset animation
// then rebuilt all ~42 call sites (MealSuggestionItem, FieldCapsule, date
// chips, ...) for no reason. The aspect lookup
// `MediaQuery.maybeDisableAnimationsOf` is semantically identical and rebuilds
// only when the one flag flips.

void main() {
  testWidgets('motionDuration rebuildet nicht mit den Keyboard-Insets',
      (tester) async {
    final durations = <Duration>[];
    // ONE widget instance across all pumps: only a changed dependency may
    // rebuild it, never a new widget identity.
    final probe = Builder(builder: (context) {
      durations.add(motionDuration(context, const Duration(milliseconds: 200)));
      return const SizedBox.shrink();
    });

    await tester.pumpWidget(
      MediaQuery(data: const MediaQueryData(), child: probe),
    );
    expect(durations, hasLength(1));
    expect(durations.single, const Duration(milliseconds: 200));

    // Keyboard slide: viewInsets change on every animation frame.
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(viewInsets: EdgeInsets.only(bottom: 120)),
        child: probe,
      ),
    );
    expect(durations, hasLength(1),
        reason: 'Ein Inset-Frame darf keinen Rebuild ausloesen — sonst '
            'rebuildet jede Tastatur-Einblendung Dutzende statische Widgets.');

    // The one aspect that matters still triggers a rebuild and collapses the
    // duration.
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          viewInsets: EdgeInsets.only(bottom: 120),
          disableAnimations: true,
        ),
        child: probe,
      ),
    );
    expect(durations, hasLength(2),
        reason: 'Reduce-Motion muss weiterhin durchschlagen.');
    expect(durations.last, Duration.zero);
  });

  test('kein Vollzugriff auf MediaQuery fuer disableAnimations in lib/', () {
    // Direct call sites outside motion.dart get the same one-line change;
    // this pin keeps new full-MediaQuery lookups out.
    final offenders = <String>[];
    final accessor = RegExp(r'\.disableAnimations\b');
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final source = file.readAsStringSync();
      if (accessor.hasMatch(source)) offenders.add(file.path);
    }
    expect(offenders, isEmpty,
        reason: 'disableAnimations nur ueber '
            'MediaQuery.maybeDisableAnimationsOf lesen (Aspekt-Lookup), nie '
            'als Zugriff auf die ganze MediaQueryData: $offenders');
  });
}
