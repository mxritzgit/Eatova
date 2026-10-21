// The consent and report sheets on the smallest phone at double text, in
// both languages: no overflow, and the two ways out of the consent stay
// reachable. The display mode changes colours only, not the layout.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/models/ai_consent.dart';
import 'package:eatova/src/widgets/design/design.dart';
import 'package:eatova/src/widgets/shared/ai_consent_sheet.dart';
import 'package:eatova/src/widgets/shared/ai_report_sheet.dart';

import '../support/ai_trust_fakes.dart';
import '../support/harness.dart';

Future<void> _openSheet(
  WidgetTester tester,
  Widget sheet, {
  required Locale locale,
}) async {
  tester.view.devicePixelRatio = 2.0;
  tester.view.physicalSize = const Size(320, 568) * 2.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    localizedApp(
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showEatovaSheet<void>(context, sheet),
          child: const Text('open'),
        ),
      ),
      locale: locale,
      textScale: 2.0,
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  for (final locale in const [Locale('de'), Locale('en')]) {
    final label = locale.languageCode;

    testWidgets('Einwilligung $label: kein Ueberlauf, beide Auswege sichtbar',
        (tester) async {
      final controller = await aiTrustController();
      final overflows = await collectOverflows(() async {
        await _openSheet(
          tester,
          AiConsentSheet(controller: controller),
          locale: locale,
        );
      });
      expect(overflows, isEmpty, reason: describeOverflows(overflows));
      for (final key in ['ai-consent-accept', 'ai-consent-not-now']) {
        final rect = tester.getRect(find.byKey(ValueKey(key)));
        expect(rect.bottom, lessThanOrEqualTo(568), reason: key);
        expect(rect.height, greaterThanOrEqualTo(48), reason: key);
      }
      final check = find.byKey(const ValueKey('ai-consent-health-check'));
      await tester.ensureVisible(check);
      await tester.pumpAndSettle();
      expect(tester.getSize(check).height, greaterThanOrEqualTo(48));
    });

    testWidgets('Melden $label: kein Ueberlauf', (tester) async {
      final overflows = await collectOverflows(() async {
        await _openSheet(
          tester,
          AiReportSheet(
            target: AiReportTarget.answer,
            onSubmit: (_) async {},
          ),
          locale: locale,
        );
      });
      expect(overflows, isEmpty, reason: describeOverflows(overflows));
      final submit = tester.getRect(
        find.byKey(const ValueKey('ai-report-submit')),
      );
      expect(submit.bottom, lessThanOrEqualTo(568));
    });
  }
}
