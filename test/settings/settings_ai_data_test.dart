// Settings after the 2026-10-19 review: "AI & data" shows the consent and
// changes it (withdraw / give), "Feedback & support" opens a mail with only
// version and build in the subject, and the export can leave as a file.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:eatova/src/app/ai_trust.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/settings/settings_ai_data.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';

import '../support/ai_trust_fakes.dart';
import '../support/harness.dart';

const MethodChannel _urlLauncher = MethodChannel(
  'plugins.flutter.io/url_launcher',
);

Future<void> _openSettings(
  WidgetTester tester, {
  AiTrustController? controller,
  bool bindScope = true,
  Future<String> Function()? onExportData,
  Future<void> Function(String, String)? shareExportFile,
}) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final app = localizedApp(
    Builder(
      builder: (context) => TextButton(
        onPressed: () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => SettingsScreen(
              onExportData: onExportData,
              shareExportFile: shareExportFile,
            ),
          ),
        ),
        child: const Text('open'),
      ),
    ),
  );
  await tester.pumpWidget(bindScope ? withAiTrust(controller, app) : app);
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _show(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

final Finder _row = find.byKey(const ValueKey('settings-ai-consent'));

void main() {
  group('KI & Daten', () {
    testWidgets('ohne Konto-Controller faellt die Gruppe weg', (tester) async {
      await _openSettings(tester, bindScope: false);
      expect(_row, findsNothing);
      expect(find.text(deL10n.settingsAiDataTitle), findsNothing);
    });

    testWidgets('erteilt: Datum und Widerruf; danach fragen die KI-Funktionen '
        'wieder', (tester) async {
      final log = FakeAiTrustLog(rows: [grantedRecord()]);
      final controller = await aiTrustController(log: log);
      await _openSettings(tester, controller: controller);
      await _show(tester, _row);

      expect(find.text(deL10n.settingsAiDataTitle), findsOneWidget);
      final date = MaterialLocalizations.of(
        tester.element(_row),
      ).formatMediumDate(kLoggedAt.toLocal());
      expect(
        find.descendant(
          of: _row,
          matching: find.text(deL10n.settingsAiDataConsentGiven(date)),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('settings-ai-withdraw')));
      await tester.pumpAndSettle();
      // The confirmation's safe way out changes nothing.
      await tester.tap(
        find.byKey(const ValueKey('settings-ai-withdraw-cancel')),
      );
      await tester.pumpAndSettle();
      expect(controller.allowsAi, isTrue);

      await tester.tap(find.byKey(const ValueKey('settings-ai-withdraw')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('settings-ai-withdraw-confirm')),
      );
      await tester.pumpAndSettle();

      expect(controller.allowsAi, isFalse);
      expect(log.rows.last.granted, isFalse);
      expect(find.text(deL10n.settingsAiDataWithdrawnSnack), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-ai-grant')), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('offline widerrufen: wirkt sofort und sagt, dass er noch '
        'uebertragen wird', (tester) async {
      final log = FakeAiTrustLog(rows: [grantedRecord()]);
      final controller = await aiTrustController(log: log);
      await _openSettings(tester, controller: controller);
      await _show(tester, _row);
      log.failWrites = true;

      await tester.tap(find.byKey(const ValueKey('settings-ai-withdraw')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('settings-ai-withdraw-confirm')),
      );
      await tester.pumpAndSettle();

      expect(controller.allowsAi, isFalse);
      expect(
        find.text(deL10n.settingsAiDataWithdrawnPendingSnack),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _row,
          matching: find.text(deL10n.settingsAiDataConsentPending),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('nicht erteilt: Einwilligen oeffnet dasselbe Blatt', (
      tester,
    ) async {
      final log = FakeAiTrustLog();
      final controller = await aiTrustController(log: log);
      await _openSettings(tester, controller: controller);
      await _show(tester, _row);

      expect(
        find.descendant(
          of: _row,
          matching: find.text(deL10n.settingsAiDataConsentNotGiven),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('settings-ai-grant')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-consent-sheet')), findsOneWidget);

      final check = find.byKey(const ValueKey('ai-consent-health-check'));
      await tester.ensureVisible(check);
      await tester.tap(check);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-consent-accept')));
      await tester.pumpAndSettle();

      expect(controller.allowsAi, isTrue);
      expect(log.rows.single.granted, isTrue);
      expect(find.text(deL10n.settingsAiDataGrantedSnack), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  group('Feedback & Support', () {
    test('mailto mit Version und Build im Betreff, sonst nichts', () {
      final uri = supportMailUri(
        deL10n.settingsSupportMailSubject('1.1.0', '412'),
      );
      expect(uri.scheme, 'mailto');
      expect(uri.path, 'support@eatova.de');
      expect(uri.queryParameters.keys, <String>['subject']);
      expect(
        uri.queryParameters['subject'],
        'Eatova Feedback – Version 1.1.0 (412)',
      );
      // Spaces as %20: mail apps show a `+` literally.
      expect(uri.toString(), isNot(contains('+')));
    });

    testWidgets('die Zeile oeffnet die Mail-App; ohne Mail-App nennt ein '
        'Hinweis die Adresse', (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'Eatova',
        packageName: 'com.eatova.app',
        version: '1.1.0',
        buildNumber: '412',
        buildSignature: '',
      );
      final launched = <String>[];
      var answer = true;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_urlLauncher, (call) async {
        if (call.method != 'launch') return null;
        launched.add(
          (call.arguments as Map<Object?, Object?>)['url']! as String,
        );
        return answer;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(_urlLauncher, null));

      await _openSettings(tester, bindScope: false);
      final row = find.byKey(const ValueKey('settings-support'));
      await _show(tester, row);
      await tester.tap(row);
      await tester.pumpAndSettle();

      expect(launched, hasLength(1));
      final uri = Uri.parse(launched.single);
      expect(uri.path, 'support@eatova.de');
      expect(uri.queryParameters['subject'], contains('1.1.0'));
      expect(uri.queryParameters['subject'], contains('412'));
      expect(find.text(deL10n.settingsSupportMailFailed), findsNothing);

      answer = false;
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.text(deL10n.settingsSupportMailFailed), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  // Wiring only: that the file holds the FULL export, not the preview, is
  // pinned in test/widgets/export_paket_export_sheet_test.dart.
  testWidgets('Export: "Als Datei teilen" nutzt den Teilen-Weg der '
      'Einstellungen', (tester) async {
    final shared = <(String, String)>[];
    await _openSettings(
      tester,
      bindScope: false,
      onExportData: () async => '{"format":"eatova-export/1"}',
      shareExportFile: (inhalt, name) async => shared.add((inhalt, name)),
    );
    final row = find.byKey(const ValueKey('settings-export'));
    await _show(tester, row);
    await tester.tap(row);
    await tester.pumpAndSettle();

    final share = find.byKey(const ValueKey('profile-export-share'));
    await tester.ensureVisible(share);
    await tester.pumpAndSettle();
    await tester.tap(share);
    await tester.pumpAndSettle();

    expect(shared, hasLength(1));
    expect(shared.single.$2, startsWith('eatova-export-'));
  });

  testWidgets('Export: ein gescheitertes Teilen sagt es', (tester) async {
    await _openSettings(
      tester,
      bindScope: false,
      onExportData: () async => '{"format":"eatova-export/1"}',
      shareExportFile: (_, _) async => throw StateError('no share sheet'),
    );
    final row = find.byKey(const ValueKey('settings-export'));
    await _show(tester, row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    final share = find.byKey(const ValueKey('profile-export-share'));
    await tester.ensureVisible(share);
    await tester.pumpAndSettle();
    await tester.tap(share);
    await tester.pumpAndSettle();

    expect(find.text(deL10n.exportShareFailed), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
