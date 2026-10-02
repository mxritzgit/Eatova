// ---------------------------------------------------------------------------
// P9-05 — the tap target of the appearance and language pill.
//
// The segment was a bare GestureDetector around an 11 px label with 5 px of
// padding: ~22 px tall, and that WAS the whole target. The pill's own 3 px
// padding belongs to the [Container], not to the detector, so a tap on it hit
// nothing. Project floor: 44 pt (AppToggle, pinned in
// review0819_controls_toggle_target_test.dart).
//
// Since the 2026-10-02 polish the settings page renders the pills
// `expanded: true`: a recessed track with full-width segments, each at least
// 48 px tall, stacking one per line at large text. Tested here:
//   1. every segment of that shipped pill is a 48 px target, at 1.0 on a
//      phone row and at 2.0 on a narrow one,
//   2. a tap at the segment's top edge switches, and the semantics node
//      (button, selected) covers the whole target,
//   3. the row DELIBERATELY has no `onTap`. A two-state switch can toggle on
//      a row tap; a three-way segment cannot — cycling System -> Hell ->
//      Dunkel on a stray tap would be mystery meat, and on the language row
//      it would silently reset the app language.
// ---------------------------------------------------------------------------

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/app/locale_controller.dart';
import 'package:eatova/src/screens/settings/settings_controls.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/theme/theme_mode_controller.dart';
import 'package:eatova/src/screens/settings/settings_studio_widgets.dart';

import 'support/harness.dart';

const ValueKey<String> _pilleKey = ValueKey<String>('pille-unter-test');

/// The pill on its own at the width the settings row gives it ([breite]),
/// top-left so it keeps its own height.
Future<void> _pumpePille(
  WidgetTester tester,
  Widget pille, {
  required double breite,
  required double textScale,
}) =>
    pumpLocalized(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: breite,
          child: KeyedSubtree(key: _pilleKey, child: pille),
        ),
      ),
      brightness: Brightness.light,
      textScale: textScale,
    );

/// Row widths: a 390 pt phone at 1.0, and 236 px of a 320 pt phone at 2.0.
const List<({double breite, double scale})> _groessen =
    <({double breite, double scale})>[
  (breite: 335, scale: 1.0),
  (breite: 236, scale: 2.0),
];

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
    for (final fall in <({String zeile, List<String> segmente, Object? wert})>[
      (
        zeile: 'Erscheinungsbild',
        segmente: <String>[
          'settings-theme-mode-system',
          'settings-theme-mode-light',
          'settings-theme-mode-dark',
        ],
        wert: ThemeMode.dark,
      ),
      (
        zeile: 'Sprache',
        segmente: <String>[
          'settings-language-system',
          'settings-language-de',
          'settings-language-en',
        ],
        wert: const Locale('en'),
      ),
    ]) {
      // As the settings screen builds them: `expanded: true`.
      Widget bauen(List<Object?> senke) => fall.wert is Locale
          ? SettingsLanguagePill(
              value: null,
              expanded: true,
              onChanged: senke.add,
            )
          : SettingsThemeModePill(
              mode: ThemeMode.system,
              expanded: true,
              onChanged: senke.add,
            );

      for (final g in _groessen) {
        final groesse = '${g.breite.toInt()} px, ${g.scale}x';

        testWidgets('${fall.zeile} ($groesse): jedes Segment ist ein '
            '48-px-Ziel', (tester) async {
          await _pumpePille(tester, bauen(<Object?>[]),
              breite: g.breite, textScale: g.scale);

          for (final key in fall.segmente) {
            final segment = tester.getRect(find.byKey(ValueKey<String>(key)));
            expect(segment.height,
                greaterThanOrEqualTo(kMinInteractiveDimension),
                reason: '$key: kein Fingerziel unter 48 px');
            expect(segment.width,
                greaterThanOrEqualTo(kMinInteractiveDimension),
                reason: '$key: kein Fingerziel unter 48 px');
          }
          expect(tester.takeException(), isNull);
        });

        testWidgets('${fall.zeile} ($groesse): die Oberkante schaltet mit',
            (tester) async {
          final senke = <Object?>[];
          await _pumpePille(tester, bauen(senke),
              breite: g.breite, textScale: g.scale);

          final ziel = tester.getRect(
            find.byKey(ValueKey<String>(fall.segmente.last)),
          );
          await tester.tapAt(Offset(ziel.center.dx, ziel.top + 2));
          await tester.pumpAndSettle();

          expect(senke, <Object?>[fall.wert]);
        });

        testWidgets('${fall.zeile} ($groesse): der Semantik-Knoten deckt das '
            'Ziel', (tester) async {
          // Screen readers and switch access aim at the NODE, not at the hit
          // test. `dispose` inline, not via addTearDown: the framework checks
          // for leaked handles BEFORE the tear-downs run.
          final handle = tester.ensureSemantics();

          await _pumpePille(tester, bauen(<Object?>[]),
              breite: g.breite, textScale: g.scale);

          for (final (i, key) in fall.segmente.indexed) {
            final knoten = tester.getSemantics(find.byKey(ValueKey<String>(key)));
            expect(
              knoten,
              isSemantics(
                isButton: true,
                isSelected: i == 0,
                hasTapAction: true,
              ),
              reason: key,
            );
            expect(knoten.rect.height,
                greaterThanOrEqualTo(kMinInteractiveDimension),
                reason: key);
          }
          handle.dispose();
        });
      }
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

        final zeile = find.ancestor(of: pille, matching: find.byType(SettingsStudioRow));
        expect(zeile, findsOneWidget, reason: key);
        expect(
          tester.widget<SettingsStudioRow>(zeile).onTap,
          isNull,
          reason: 'ein Dreier-Segment hat keinen definierten Ein-Tipp-Zustand: '
              'blindes Durchschalten der Sprache waere schlimmer als nichts',
        );

        // Tapping the row's title really changes nothing.
        final titel =
            find.descendant(of: zeile, matching: find.byType(Text)).first;
        await tester.ensureVisible(titel);
        await tester.pumpAndSettle();
        await tester.tap(titel);
        await tester.pumpAndSettle();
      }

      expect(c.modus.mode, ThemeMode.system);
      expect(c.sprache.override, isNull);
    });

    testWidgetsRobust('das Segment schaltet bis an seine Oberkante',
        (tester) async {
      // On the real page: the shipped segment is 48 px tall and a tap at its
      // top edge, not only on the label, switches the mode.
      final c = _controllers();
      await _oeffneEinstellungen(tester, c);

      final segment = find.byKey(const ValueKey('settings-theme-mode-dark'));
      await tester.ensureVisible(segment);
      await tester.pumpAndSettle();

      final ziel = tester.getRect(segment);
      expect(ziel.height, greaterThanOrEqualTo(48.0));

      await tester.tapAt(Offset(ziel.center.dx, ziel.top + 2));
      await tester.pumpAndSettle();

      expect(c.modus.mode, ThemeMode.dark);
    });
  });
}
