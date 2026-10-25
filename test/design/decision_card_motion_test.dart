// The decision card's motion (polish 2026-10-25). With motion the card lands
// on its spring, the sign-out arrow acts once and everything settles (no
// loop, so pumpAndSettle terminates) in exactly the resting picture. Under
// reduced motion card, content and medallion are at rest on the first frame.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/widgets/design/design.dart';

import '../support/harness.dart';

const _cancel = ValueKey<String>('card-cancel');

late BuildContext _context;

Future<void> _mount(WidgetTester tester, {required bool reduce}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    localizedApp(
      const SizedBox.expand(),
      reducedMotion: reduce,
      onContext: (c) => _context = c,
    ),
  );
}

/// Opens the sign-out card and pumps its first frame.
Future<void> _open(WidgetTester tester) async {
  final l = _context.l10n;
  showEatovaDialog<bool>(
    context: _context,
    builder: (dialogContext) => EatovaConfirmDialog(
      title: l.settingsSignOutConfirmTitle,
      body: l.settingsSignOutSafe,
      icon: Icons.logout_rounded,
      cancelKey: _cancel,
      confirmLabel: l.settingsSignOutTitle,
      cancelLabel: l.commonCancel,
      onConfirm: () => Navigator.of(dialogContext).pop(true),
      onCancel: () => Navigator.of(dialogContext).pop(false),
    ),
  );
  await tester.pump();
}

Rect _card(WidgetTester tester) => tester.getRect(
  find
      .descendant(of: find.byType(Dialog), matching: find.byType(Material))
      .first,
);

/// The exit glyph's painter inside the medallion.
CustomPainter _glyph(WidgetTester tester) => tester
    .widget<CustomPaint>(
      find.descendant(
        of: find.byType(DecisionMedallion),
        matching: find.byType(CustomPaint),
      ),
    )
    .painter!;

/// The medallion's pop: the x scale of its transform.
double _medallionScale(WidgetTester tester) => tester
    .widget<Transform>(
      find
          .descendant(
            of: find.byType(DecisionMedallion),
            matching: find.byType(Transform),
          )
          .first,
    )
    .transform
    .storage[0];

double _titleOpacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find
          .ancestor(
            of: find.text(_context.l10n.settingsSignOutConfirmTitle),
            matching: find.byType(Opacity),
          )
          .first,
    )
    .opacity;

/// The route's own fade around the card.
double _routeOpacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find
          .ancestor(
            of: find.byType(Dialog),
            matching: find.byType(FadeTransition),
          )
          .first,
    )
    .opacity
    .value;

void main() {
  testWidgets('reduced motion: card, content and medallion rest in frame 1', (
    tester,
  ) async {
    await _mount(tester, reduce: true);
    await _open(tester);
    final card = _card(tester);
    final glyph = _glyph(tester);
    expect(_routeOpacity(tester), 1);
    expect(_titleOpacity(tester), 1);
    expect(_medallionScale(tester), 1);

    await tester.pumpAndSettle();
    expect(_card(tester), card);
    expect(_glyph(tester).shouldRepaint(glyph), isFalse);
  });

  testWidgets('with motion the card settles and the arrow ends at rest', (
    tester,
  ) async {
    // The resting picture, as reduced motion shows it at once.
    await _mount(tester, reduce: true);
    await _open(tester);
    final restCard = _card(tester);
    final restGlyph = _glyph(tester);
    await tester.tap(find.byKey(_cancel));
    await tester.pumpAndSettle();

    await _mount(tester, reduce: false);
    await _open(tester);
    await tester.pump(const Duration(milliseconds: 60));
    // Mid-entrance: the card is still rising, the title not yet in, the
    // medallion still growing, the arrow still inside its door.
    expect(_card(tester).top, greaterThan(restCard.top + 4));
    expect(_titleOpacity(tester), lessThan(1));
    expect(_medallionScale(tester), lessThan(1));
    expect(_glyph(tester).shouldRepaint(restGlyph), isTrue);

    // Springs settle at t = 1: nothing loops.
    await tester.pumpAndSettle();
    expect(_card(tester), restCard);
    expect(_titleOpacity(tester), 1);
    expect(_medallionScale(tester), 1);
    expect(_glyph(tester).shouldRepaint(restGlyph), isFalse);
  });
}
