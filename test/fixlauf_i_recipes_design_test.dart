// Fix-Lauf 2026-08-27, Paket I (F6-09/F8-03/F8-07/F8-10): Design des
// Rezepte-Pakets.
//
//   * Suchfeld und Sheet-Felder sind RAHMENLOS: weiche Kapsel mit Schatten,
//     Fokus = Flächen-Aufhellung, Fehler = Danger-Tönung plus Textzeile.
//   * Der „EMPFOHLEN"-Badge ist Forest + onForest (Lime bleibt der
//     Nav-Kapsel vorbehalten), Radius rChip.
//   * Keine lokalen Farbkopien mehr auf Buttons (Theme entscheidet); nur das
//     destruktive Rot bleibt.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/models/logged_meal.dart';
import 'package:eatova/src/models/meal_analysis_result.dart';
import 'package:eatova/src/screens/recipes/recipes_screen.dart';
import 'package:eatova/src/theme/app_theme.dart';
import 'package:eatova/src/theme/app_tokens.dart';

Widget _app(Brightness brightness) {
  return MaterialApp(
    theme: buildEatovaTheme(brightness),
    locale: const Locale('de'),
    supportedLocales: const [Locale('de'), Locale('en')],
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    home: Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: RecipesScreen(
            onAddMeal: (MealAnalysisResult _, MealSlot __) {},
          ),
        ),
      ),
    ),
  );
}

void _pinViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1179, 2556);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('overflowed')) return;
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);
}

/// Die Kapsel eines Feldes: der nächste [AnimatedContainer] über dem
/// [TextField] mit [key].
BoxDecoration _kapsel(WidgetTester tester, String key) {
  final container = find
      .ancestor(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(AnimatedContainer),
      )
      .first;
  return tester.widget<AnimatedContainer>(container).decoration!
      as BoxDecoration;
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('recipe-create-button')));
  await tester.pumpAndSettle();
}

void main() {
  for (final (modus, brightness, t) in <(String, Brightness, AppTokens)>[
    ('Dark', Brightness.dark, AppTokens.dark),
    ('Light', Brightness.light, AppTokens.light),
  ]) {
    group('$modus-Modus', () {
      testWidgets('Suchfeld: kein Rahmen, weicher Schatten, Fokus hellt auf',
          (tester) async {
        _pinViewport(tester);
        await tester.pumpWidget(_app(brightness));
        await tester.pumpAndSettle();

        final ruhe = _kapsel(tester, 'recipes-search-input');
        expect(ruhe.border, isNull, reason: 'Hairline-Rahmen sind verboten.');
        expect(ruhe.boxShadow, isNotEmpty);
        expect(ruhe.color, t.field);

        await tester.tap(find.byKey(const ValueKey('recipes-search-input')));
        await tester.pump();
        await tester.pump();

        expect(_kapsel(tester, 'recipes-search-input').color, t.fieldFocus,
            reason: 'Fokus = Flächen-Aufhellung, kein Fokusring.');
        expect(_kapsel(tester, 'recipes-search-input').border, isNull);
      });

      testWidgets('Sheet-Felder: rahmenlos, Fehler = Danger-Tönung + Text',
          (tester) async {
        _pinViewport(tester);
        await tester.pumpWidget(_app(brightness));
        await tester.pumpAndSettle();
        await _openSheet(tester);

        for (final key in const <String>[
          'recipe-create-name',
          'recipe-create-portion',
          'recipe-create-kcal',
          'recipe-create-grams',
          'recipe-create-protein',
          'recipe-create-carbs',
          'recipe-create-fat',
          'recipe-create-ingredients',
        ]) {
          final kapsel = _kapsel(tester, key);
          expect(kapsel.border, isNull, reason: key);
          expect(kapsel.boxShadow, isNotEmpty, reason: key);
          expect(kapsel.color, t.field, reason: key);
        }

        await tester.enterText(
          find.byKey(const ValueKey('recipe-create-kcal')),
          '50000',
        );
        await tester.pumpAndSettle();

        final fehler = _kapsel(tester, 'recipe-create-kcal');
        expect(fehler.border, isNull);
        expect(
          fehler.color,
          t.fieldError,
          reason: 'Fehler als Tönung der Fläche, nicht als roter Rand.',
        );
        expect(find.text('1–10000 kcal'), findsOneWidget);
      });

      testWidgets('„EMPFOHLEN"-Badge ist Forest + onForest mit rChip',
          (tester) async {
        _pinViewport(tester);
        await tester.pumpWidget(_app(brightness));
        await tester.pumpAndSettle();

        final badgeText = find.text('EMPFOHLEN').first;
        final container = find
            .ancestor(of: badgeText, matching: find.byType(Container))
            .first;
        final deko =
            tester.widget<Container>(container).decoration! as BoxDecoration;
        expect(deko.color, t.forest);
        expect(deko.borderRadius, BorderRadius.circular(rChip));
        expect(tester.widget<Text>(badgeText).style?.color, t.onForest);
        expect(deko.color, isNot(t.lime),
            reason: 'Lime ist der Nav-Kapsel vorbehalten.');
      });

      testWidgets('Buttons tragen keine lokalen Farbkopien mehr',
          (tester) async {
        _pinViewport(tester);
        await tester.pumpWidget(_app(brightness));
        await tester.pumpAndSettle();
        await _openSheet(tester);

        final save = tester.widget<FilledButton>(
          find.byKey(const ValueKey('recipe-create-save')),
        );
        expect(save.style, isNull,
            reason: 'Primärfarbe und Form kommen aus dem Button-Theme.');
        // Die Stature bleibt: mindestens 52 px hoch, volle Breite.
        final groesse =
            tester.getSize(find.byKey(const ValueKey('recipe-create-save')));
        expect(groesse.height, greaterThanOrEqualTo(52));
        expect(groesse.width, greaterThan(300));

        // Verwerfen-Dialog: nur das destruktive Rot ist lokal.
        await tester.enterText(
          find.byKey(const ValueKey('recipe-create-name')),
          'x',
        );
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        final cancel = tester.widget<TextButton>(
          find.byKey(const ValueKey('discard-changes-cancel')),
        );
        expect(cancel.style, isNull);
        final confirm = tester.widget<TextButton>(
          find.byKey(const ValueKey('discard-changes-confirm')),
        );
        expect(
          confirm.style?.foregroundColor?.resolve(<WidgetState>{}),
          t.danger,
        );
      });
    });
  }
}
