import 'dart:io';
import 'dart:ui' as ui;

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/screens/auth_screen.dart';
import 'package:eatova/src/screens/auth_code_screen.dart';
import 'package:eatova/src/services/local_cache.dart';
import 'package:eatova/src/widgets/auth/welcome_screen.dart';
import 'package:eatova/src/widgets/auth/auth_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'account_studio_layout_test.dart' show loadAccountFonts;
import 'support/harness.dart';

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  const directory = String.fromEnvironment('AUTH_PREVIEW_DIR');
  if (directory.isEmpty) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$directory/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void _expectWholeHeadlineWords(WidgetTester tester) {
  final headline = find.descendant(
    of: find.byType(AuthHeadline),
    matching: find.byType(Text),
  );
  final text = tester.widget<Text>(headline).data!;
  final paragraph = tester.renderObject<RenderParagraph>(headline);
  for (final word in RegExp(r'\S+').allMatches(text)) {
    expect(
      paragraph.getBoxesForSelection(
        TextSelection(baseOffset: word.start, extentOffset: word.end),
      ),
      hasLength(1),
      reason:
          'The headline word "${word.group(0)}" should not split across lines.',
    );
  }
}

void main() {
  setUpAll(loadAccountFonts);
  for (final brightness in Brightness.values) {
    testWidgets('recovery sequence real fonts ${brightness.name}', (
      tester,
    ) async {
      final capture = GlobalKey();
      final repository = InMemoryAuthRepository();
      addTearDown(repository.dispose);
      await pumpLocalized(
        tester,
        RepaintBoundary(
          key: capture,
          child: AuthCodeScreen(
            authRepository: repository,
            flow: AuthCodeFlow.recovery,
            initialEmail: 'mira@example.com',
            throttleStore: InMemoryKeyValueStore(),
          ),
        ),
        brightness: brightness,
        surfaceSize: const Size(390, 844),
        scaffold: false,
        safeArea: false,
        settle: true,
      );
      await _capture(tester, capture, 'recovery-email-${brightness.name}');
      await tester.tap(find.byKey(const ValueKey('code-primary')));
      await tester.pumpAndSettle();
      await _capture(tester, capture, 'recovery-code-${brightness.name}');
      await tester.enterText(
        find.byKey(const ValueKey('code-field')),
        '48291357',
      );
      await tester.tap(find.byKey(const ValueKey('code-primary')));
      await tester.pumpAndSettle();
      await _capture(tester, capture, 'recovery-password-${brightness.name}');
      final password = tester.widget<TextField>(
        find.byKey(const ValueKey('code-password-field')),
      );
      expect(password.autocorrect, isFalse);
      expect(password.enableSuggestions, isFalse);
      expect(tester.takeException(), isNull);
    });
  }
  for (final brightness in Brightness.values) {
    for (final locale in const ['de', 'en']) {
      testWidgets(
        'small phone keyboard and large text ${brightness.name} $locale',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(320, 640);
          addTearDown(tester.view.reset);
          final capture = GlobalKey();
          final repository = InMemoryAuthRepository();
          addTearDown(repository.dispose);
          await pumpLocalized(
            tester,
            RepaintBoundary(
              key: capture,
              child: AuthScreen(authRepository: repository),
            ),
            locale: Locale(locale),
            brightness: brightness,
            textScale: 2,
            scaffold: false,
            safeArea: false,
            settle: true,
          );
          for (final mode in ['login', 'signup']) {
            if (mode == 'signup') {
              tester.view.viewInsets = FakeViewPadding.zero;
              await tester.pumpAndSettle();
              final toggle = find.byKey(const ValueKey('auth-toggle-register'));
              await tester.ensureVisible(toggle);
              await tester.tap(toggle);
              await tester.pumpAndSettle();
            }
            await tester.enterText(
              find.byKey(const ValueKey('auth-email-field')),
              'mira@example.com',
            );
            tester.view.viewInsets = const FakeViewPadding(bottom: 300);
            await tester.pumpAndSettle();
            expect(
              find.byType(AuthHeadline),
              findsNothing,
              reason: 'The keyboard collapses the intro above the form.',
            );
            for (final field in [
              if (mode == 'signup') 'name',
              'email',
              'password',
            ]) {
              final finder = find.byKey(ValueKey('auth-$field-field'));
              await tester.ensureVisible(finder);
              await tester.pumpAndSettle();
              expect(finder.hitTestable(), findsOneWidget);
              final rect = tester.getRect(finder);
              expect(rect.left, greaterThanOrEqualTo(0));
              expect(rect.right, lessThanOrEqualTo(320));
              expect(rect.bottom, lessThanOrEqualTo(340));
            }
            final submit = find.byKey(const ValueKey('auth-submit'));
            await tester.ensureVisible(submit);
            await tester.pumpAndSettle();
            expect(submit.hitTestable(), findsOneWidget);
            expect(tester.getRect(submit).bottom, lessThanOrEqualTo(340));
            await _capture(
              tester,
              capture,
              '$mode-keyboard-${brightness.name}-$locale-2.0',
            );
            expect(tester.takeException(), isNull);
            tester.view.viewInsets = FakeViewPadding.zero;
            await tester.pumpAndSettle();
            expect(
              find.byType(AuthHeadline),
              findsOneWidget,
              reason: 'The intro returns when the keyboard is dismissed.',
            );
          }
        },
      );
      for (final scale in [1.0, 2.0]) {
        testWidgets('entry real fonts ${brightness.name} $locale $scale', (
          tester,
        ) async {
          final capture = GlobalKey();
          final repository = InMemoryAuthRepository();
          addTearDown(repository.dispose);
          await pumpLocalized(
            tester,
            RepaintBoundary(
              key: capture,
              child: AuthScreen(authRepository: repository),
            ),
            locale: Locale(locale),
            brightness: brightness,
            surfaceSize: scale == 1
                ? const Size(390, 844)
                : const Size(320, 640),
            textScale: scale,
            scaffold: false,
            safeArea: false,
            settle: true,
          );
          final suffix = '${brightness.name}-$locale-$scale';
          _expectWholeHeadlineWords(tester);
          await _capture(tester, capture, 'login-$suffix');
          await tester.ensureVisible(find.byKey(const ValueKey('auth-submit')));
          expect(
            find.byKey(const ValueKey('auth-submit')).hitTestable(),
            findsOneWidget,
          );
          await tester.ensureVisible(
            find.byKey(const ValueKey('auth-toggle-register')),
          );
          await tester.tap(find.byKey(const ValueKey('auth-toggle-register')));
          await tester.pumpAndSettle();
          tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .jumpTo(0);
          await tester.pumpAndSettle();
          await _capture(tester, capture, 'signup-$suffix');
          _expectWholeHeadlineWords(tester);
          await tester.ensureVisible(find.byKey(const ValueKey('auth-submit')));
          expect(
            find.byKey(const ValueKey('auth-submit')).hitTestable(),
            findsOneWidget,
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await pumpLocalized(
            tester,
            RepaintBoundary(
              key: capture,
              child: AuthCodeScreen(
                authRepository: repository,
                flow: AuthCodeFlow.signup,
                initialEmail: 'mira@example.com',
                throttleStore: InMemoryKeyValueStore(),
              ),
            ),
            locale: Locale(locale),
            brightness: brightness,
            textScale: scale,
            surfaceSize: scale == 1
                ? const Size(390, 844)
                : const Size(320, 640),
            scaffold: false,
            safeArea: false,
            settle: true,
          );
          await tester.enterText(
            find.byKey(const ValueKey('code-field')),
            '48291357',
          );
          await tester.pumpAndSettle();
          final editable = tester
              .state<EditableTextState>(find.byType(EditableText))
              .renderEditable;
          expect(
            editable.maxScrollExtent,
            0,
            reason: 'All eight digits stay visible at large text sizes.',
          );
          await _capture(tester, capture, 'code-$suffix');
          _expectWholeHeadlineWords(tester);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
  testWidgets('tablet form stays bounded and keyboard keeps submit reachable', (
    tester,
  ) async {
    final repository = InMemoryAuthRepository();
    addTearDown(repository.dispose);
    await pumpLocalized(
      tester,
      AuthScreen(authRepository: repository),
      surfaceSize: const Size(1024, 768),
      scaffold: false,
      safeArea: false,
      settle: true,
    );
    expect(tester.getSize(find.byKey(const ValueKey('auth-hero'))).width, 520);
    await tester.pumpWidget(const SizedBox.shrink());
    pinIphone14Pro(tester, keyboard: true);
    await pumpLocalized(
      tester,
      AuthScreen(authRepository: repository),
      scaffold: false,
      safeArea: false,
      settle: true,
    );
    await tester.enterText(
      find.byKey(const ValueKey('auth-email-field')),
      'mira@example.com',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('auth-submit')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('auth-submit')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('welcome fits a short landscape window with large type', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      WelcomeScreen(
        firstName: 'Alexandria',
        profileReady: Future<void>.value(),
        celebrateLogin: true,
        onComplete: () {},
      ),
      surfaceSize: const Size(568, 320),
      textScale: 2,
      scaffold: false,
      safeArea: false,
      settle: true,
    );
    expect(tester.takeException(), isNull);
  });
}
