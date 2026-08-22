import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/design.dart';

import 'design_harness.dart';

// The barrel is the contract: screens import exactly this one file, so this
// test fails as soon as an export goes missing.
void main() {
  testWidgets('das Fass liefert je ein Widget aus allen fuenf Dateien',
      (tester) async {
    pinPhoneViewport(tester);
    await tester.pumpWidget(
      designHarness(
        SingleChildScrollView(
          child: Column(
            children: <Widget>[
              // surfaces.dart
              const AppCard(child: Text('Karte')),
              const ScreenTitle(title: 'Titel'),
              const SectionHeading(title: 'Abschnitt'),
              const SizedBox(height: 60, child: ImagePlaceholder()),
              const DottedAddSlot(label: 'Hinzufuegen'),
              // controls.dart
              SquareIconButton(icon: Icons.chevron_left_rounded, onTap: () {}),
              const IconTile(icon: Icons.bolt_rounded),
              AppToggle(value: true, onChanged: (_) {}),
              SegmentedPill(
                options: const <String>['kg', 'lb'],
                selected: 'kg',
                onChanged: (_) {},
              ),
              const FilterChipPill(label: 'Alle', selected: false),
              const PrimaryActionButton(label: 'Weiter'),
              AppNavBar(
                index: 0,
                onChanged: (_) {},
                items: const <AppNavItem>[
                  AppNavItem(
                    icon: Icons.restaurant_outlined,
                    activeIcon: Icons.restaurant_rounded,
                    label: 'Food',
                  ),
                ],
              ),
              // rows.dart
              const PageHeader(title: 'Profil'),
              const SettingsGroup(
                label: 'KONTO',
                children: <Widget>[SettingsRow(title: 'E-Mail')],
              ),
              // sheets.dart
              const SheetScaffold(
                title: 'Sheet',
                subtitle: 'Untertitel',
                actionLabel: 'Fertig',
                children: <Widget>[
                  SheetField(label: 'Feld', hint: 'Hinweis'),
                ],
              ),
              // meters.dart
              const TickGauge(progress: 0.5),
              MacroBar(
                label: 'Protein',
                value: 96,
                goal: 150,
                unit: 'g',
                color: AppTokens.light.protein,
              ),
              MealAvatar(letter: 'F', color: AppTokens.light.carbs),
              const Sparkline(values: <double>[1, 2, 3]),
              SizedBox(
                height: 40,
                child: DotGridBackground(color: AppTokens.light.lime),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('showEatovaSheet kommt ebenfalls aus dem Fass', (tester) async {
    await tester.pumpWidget(
      designHarness(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showEatovaSheet<void>(
              context,
              const SizedBox(height: 80, child: Text('Sheet-Inhalt')),
            ),
            child: const Text('oeffnen'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('oeffnen'));
    await tester.pumpAndSettle();
    expect(find.text('Sheet-Inhalt'), findsOneWidget);
  });
}
