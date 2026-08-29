// ---------------------------------------------------------------------------
// P9-05 — the tap target of the appearance and language pill.
//
// The segment was a bare GestureDetector around an 11 px label with 5 px of
// padding: ~22 px tall, and that WAS the whole target. The pill's own 3 px
// padding belongs to the [Container], not to the detector, so a tap on it hit
// nothing. Project floor: 44 pt (AppToggle, pinned in
// review0819_controls_toggle_target_test.dart).
//
// Three halves are tested here:
//   1. the target reaches 44 px WITHOUT the painted capsule growing,
//   2. the transparent margin really switches (opaque hit test) and the
//      semantics node covers it too,
//   3. the row DELIBERATELY has no `onTap`. A two-state switch can toggle on
//      a row tap; a three-way segment cannot — cycling System -> Hell ->
//      Dunkel on a stray tap would be mystery meat, and on the language row
//      it would silently reset the app language. The dead zone is closed from
//      the other side instead: the pill now fills the row's content height.
// ---------------------------------------------------------------------------

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/app/locale_controller.dart';
import 'package:eatova/src/screens/settings/settings_controls.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/theme/theme_mode_controller.dart';
import 'package:eatova/src/widgets/design/design.dart';

import 'support/harness.dart';

const ValueKey<String> _pilleKey = ValueKey<String>('pille-unter-test');

/// The pill on its own, left-aligned so it keeps its INTRINSIC size: pumped
/// straight into the body it would inherit the screen's tight constraints and
/// every measurement would read 800x600.
Future<void> _pumpePille(WidgetTester tester, Widget pille) => pumpLocalized(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: KeyedSubtree(key: _pilleKey, child: pille),
      ),
      brightness: Brightness.light,
    );

/// The painted pill: first [DecoratedBox] of the subtree, i.e. the background
/// layer of the Stack — the segments come after it.
Finder _gemalteFlaeche() => find
    .descendant(of: find.byKey(_pilleKey), matching: find.byType(DecoratedBox))
    .first;

/// The painted capsule of one segment.
Finder _kapsel(Finder segment) =>
    find.descendant(of: segment, matching: find.byType(AnimatedContainer));

/// Settings page with BOTH scopes above the MaterialApp — the page is pushed
/// as a route, so a scope inside `home` would not be an ancestor of it.
({ThemeModeController modus, LocaleController sprache}) _controllers() {
  final modus = ThemeModeController();
  addTearDown(modus.dispose);
  final sprache = LocaleController();
  addTearDown(sprache.dispose);
  return (modus: modus, sprache: sprache);
}

Future<void> _oeffneEinstellungen(
  WidgetTester tester,
  ({ThemeModeController modus, LocaleController sprache}) c,
) async {
  final app = localizedApp(
    Builder(
      builder: (context) => Center(
        child: FilledButton(
          key: const ValueKey('open-settings'),
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => const SettingsScreen(email: 'jonas@example.com'),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
    brightness: Brightness.light,
  );

  await tester.pumpWidget(
    ThemeModeScope(
      controller: c.modus,
      child: LocaleScope(controller: c.sprache, child: app),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-settings')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('Die Segmente der Einstellungs-Pillen', () {
    for (final fall in <({String zeile, String segment, Object? wert})>[
      (
        zeile: 'Erscheinungsbild',
        segment: 'settings-theme-mode-dark',
        wert: ThemeMode.dark,
      ),
      (
        zeile: 'Sprache',
        segment: 'settings-language-en',
        wert: const Locale('en'),
      ),
    ]) {
      Widget bauen(List<Object?> senke) => fall.wert is Locale
          ? SettingsLanguagePill(value: null, onChanged: senke.add)
          : SettingsThemeModePill(
              mode: ThemeMode.system,
              onChanged: senke.add,
            );

      testWidgets('${fall.zeile}: 44 px Ziel, ohne dass die Kapsel waechst',
          (tester) async {
        await _pumpePille(tester, bauen(<Object?>[]));

        final segment = find.byKey(ValueKey<String>(fall.segment));
        expect(
          tester.getSize(segment).height,
          greaterThanOrEqualTo(44.0),
          reason: '22 px sind kein Fingerziel',
        );

        // The optics stay compact: the drawn capsule keeps its ~22 px, and
        // the pill keeps exactly the 3 px gutter it had around it.
        final kapselHoehe = tester.getSize(_kapsel(segment)).height;
        expect(kapselHoehe, lessThan(28.0),
            reason: 'die gemalte Kapsel darf NICHT mitwachsen');
        expect(
          tester.getSize(_gemalteFlaeche()).height,
          closeTo(kapselHoehe + 6, 0.01),
          reason: 'die Pille bleibt Kapsel + 2x3 px Saum hoch',
        );
      });

      testWidgets('${fall.zeile}: der durchsichtige Saum schaltet mit',
          (tester) async {
        final senke = <Object?>[];
        await _pumpePille(tester, bauen(senke));

        final segment = find.byKey(ValueKey<String>(fall.segment));
        final ziel = tester.getRect(segment);
        final kapsel = tester.getRect(_kapsel(segment));
        final punkt = Offset(ziel.center.dx, ziel.top + 2);
        expect(kapsel.contains(punkt), isFalse,
            reason: 'der Tippunkt muss AUSSERHALB der gemalten Kapsel liegen, '
                'sonst misst der Test nur die Kapsel');

        await tester.tapAt(punkt);
        await tester.pumpAndSettle();

        expect(senke, <Object?>[fall.wert]);
      });

      testWidgets('${fall.zeile}: auch der Semantik-Knoten ist 44 px hoch',
          (tester) async {
        // Screen readers and switch access aim at the NODE, not at the hit
        // test — a 44 px target with a 22 px node is only half a fix.
        // `dispose` inline, not via addTearDown: the framework checks for
        // leaked handles BEFORE the tear-downs run.
        final handle = tester.ensureSemantics();

        await _pumpePille(tester, bauen(<Object?>[]));

        final knoten =
            tester.getSemantics(find.byKey(ValueKey<String>(fall.segment)));
        expect(knoten.rect.height, greaterThanOrEqualTo(44.0));
        handle.dispose();
      });
    }
  });

  group('Die Zeilen Erscheinungsbild und Sprache', () {
    testWidgetsRobust('haben bewusst kein onTap — ein Dreier schaltet nicht',
        (tester) async {
      final c = _controllers();
      await _oeffneEinstellungen(tester, c);

      for (final key in const <String>[
        'settings-theme-mode',
        'settings-language',
      ]) {
        final pille = find.byKey(ValueKey<String>(key));
        await tester.ensureVisible(pille);
        await tester.pumpAndSettle();

        final zeile = find.ancestor(of: pille, matching: find.byType(SettingsRow));
        expect(zeile, findsOneWidget, reason: key);
        expect(
          tester.widget<SettingsRow>(zeile).onTap,
          isNull,
          reason: 'ein Dreier-Segment hat keinen definierten Ein-Tipp-Zustand: '
              'blindes Durchschalten der Sprache waere schlimmer als nichts',
        );

        // Tapping the label really changes nothing.
        final rect = tester.getRect(zeile);
        await tester.tapAt(Offset(rect.left + 24, rect.center.dy));
        await tester.pumpAndSettle();
      }

      expect(c.modus.mode, ThemeMode.system);
      expect(c.sprache.override, isNull);
    });

    testWidgetsRobust('ueber der Kapsel liegt jetzt das Segment, nicht Leere',
        (tester) async {
      // That is the answer to "tapping beside it does nothing": the segment
      // now spans the row's whole content height, so the vertical dead zone
      // between capsule and row edge is gone.
      final c = _controllers();
      await _oeffneEinstellungen(tester, c);

      final segment = find.byKey(const ValueKey('settings-theme-mode-dark'));
      await tester.ensureVisible(segment);
      await tester.pumpAndSettle();

      final ziel = tester.getRect(segment);
      final kapsel = tester.getRect(_kapsel(segment));
      expect(ziel.height, greaterThanOrEqualTo(44.0));
      expect(ziel.top, lessThan(kapsel.top - 1));

      await tester.tapAt(Offset(ziel.center.dx, ziel.top + 2));
      await tester.pumpAndSettle();

      expect(c.modus.mode, ThemeMode.dark);
    });
  });
}
