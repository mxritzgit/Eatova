// Visual evidence for the decision cards and buttons (polish 2026-10-25).
//
// Every scene renders the real widgets in German at the design's 390 px
// reference and is written as `<scene>-dark` / `<scene>-light`; the suffix
// follows the run's brightness, so one file yields both sets:
//   dlg-signout           Settings > "Abmelden": the app's own confirmation
//   dlg-signout-photos    the same with unsent changes and recipe photos
//                         (destructive, every consequence line)
//   dlg-signout-motion-N  the entrance at 90 / 200 / 330 / 900 ms
//   dlg-delete-account    Settings > "Konto löschen": step 1 of the sheet
//   dlg-discard           confirmDiscardChanges with the food copy
//   dlg-three-actions     the meal plan's "planned day or today?" card
//   buttons-gallery       PrimaryActionButton, SoftPillButton,
//                         EatovaTextAction and EatovaDialogAction in all
//                         their variants
//   buttons-focus         the gallery in the keyboard (traditional) mode,
//                         focus on the lit primary, an accent pill and the
//                         quiet dialog action (three frames, one picture)
//   sheet-header          the weekly-check explainer: SheetHeader with the
//                         SheetCloseButton and two SoftPillButtons
//
//   flutter test test/design/dialogs_capture_test.dart \
//     --dart-define=DARK_REDESIGN_CAPTURE=true          (build/dark-redesign)
//   flutter test test/design/dialogs_capture_test.dart \
//     --dart-define=DESIGN_CAPTURE_BRIGHTNESS=light     (build/light-redesign)
//
// Without a define the suite still pins that every scene opens without an
// exception.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/screens/settings/settings_screen.dart';
import 'package:eatova/src/screens/today/today_weekly_check.dart';
import 'package:eatova/src/theme/app_tokens.dart';
import 'package:eatova/src/widgets/design/design.dart';

import '../support/design_capture.dart';
import '../support/harness.dart';

String get _mode =>
    designCaptureBrightness == Brightness.light ? 'light' : 'dark';

Future<void> _shoot(WidgetTester tester, String scene) =>
    captureDesignShot(tester, '$scene-$_mode');

Finder _key(String value) => find.byKey(ValueKey(value));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// The settings page as the ground every card opens over: it is where the
/// sign-out and delete cards really appear, and it puts real content under
/// the scrim of the others. Returns a context below the navigator.
Future<BuildContext> _mountSettings(
  WidgetTester tester, {
  AuthRepository? authRepository,
  int photos = 0,
  int pending = 0,
  bool reducedMotion = true,
}) async {
  pinDesignViewport(tester);
  late BuildContext context;
  await tester.pumpWidget(
    designCaptureBoundary(
      localizedApp(
        SettingsScreen(
          email: 'alex@example.com',
          authRepository: authRepository,
          onSignOut: () async {},
          localRecipePhotoCount: () => photos,
          pendingSyncCount: pending,
          onDeleteAccount: authRepository == null
              ? null
              : (deleteRemote, _) async {},
        ),
        safeArea: false,
        scaffold: false,
        reducedMotion: reducedMotion,
        onContext: (c) => context = c,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return context;
}

/// The current frame with real shadows, as [captureDesignShot] paints it.
Future<ui.Image> _frame(WidgetTester tester) async {
  final boundary =
      designCaptureKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
  void repaint(RenderObject node) {
    node.markNeedsPaint();
    node.visitChildren(repaint);
  }

  debugDisableShadows = false;
  try {
    repaint(boundary);
    await tester.pump();
    return (await tester.runAsync(
      () => boundary.toImage(pixelRatio: kDesignPixelRatio),
    ))!;
  } finally {
    debugDisableShadows = true;
    repaint(boundary);
    await tester.pump();
  }
}

void main() {
  setUpAll(loadDesignFonts);
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('dlg-signout', (tester) async {
    await _mountSettings(tester);
    await _tap(tester, _key('settings-sign-out'));
    expect(_key('settings-sign-out-confirm'), findsOneWidget);
    await _shoot(tester, 'dlg-signout');
  });

  testWidgets('dlg-signout-photos', (tester) async {
    await _mountSettings(tester, photos: 3, pending: 2);
    await _tap(tester, _key('settings-sign-out'));
    expect(_key('settings-sign-out-confirm'), findsOneWidget);
    await _shoot(tester, 'dlg-signout-photos');
  });

  testWidgets('dlg-signout-motion', (tester) async {
    await _mountSettings(tester, reducedMotion: false);
    final open = _key('settings-sign-out');
    await tester.ensureVisible(open);
    await tester.pumpAndSettle();
    await tester.tap(open);
    await tester.pump();
    var at = 0;
    var frame = 0;
    for (final ms in <int>[90, 200, 330, 900]) {
      await tester.pump(Duration(milliseconds: ms - at));
      at = ms;
      frame++;
      await _shoot(tester, 'dlg-signout-motion-$frame');
    }
    // Nothing loops: the card settles.
    await tester.pumpAndSettle();
    expect(_key('settings-sign-out-confirm'), findsOneWidget);
  });

  testWidgets('dlg-delete-account', (tester) async {
    final repo = InMemoryAuthRepository(
      initialUser: const EatovaUser(id: 'u1', email: 'alex@example.com'),
    );
    addTearDown(repo.dispose);
    await _mountSettings(tester, authRepository: repo);
    await _tap(tester, _key('settings-delete-account'));
    expect(_key('delete-account-sheet'), findsOneWidget);
    await _shoot(tester, 'dlg-delete-account');
  });

  testWidgets('dlg-discard', (tester) async {
    final context = await _mountSettings(tester);
    unawaited(
      confirmDiscardChanges(context, body: context.l10n.foodDiscardChangesBody),
    );
    await tester.pumpAndSettle();
    expect(_key('discard-changes-dialog'), findsOneWidget);
    await _shoot(tester, 'dlg-discard');
  });

  testWidgets('dlg-three-actions', (tester) async {
    final context = await _mountSettings(tester);
    final l = context.l10n;
    final planned = DateTime(2026, 10, 20);
    // The meal plan's card for ticking a past day's plan, with its cancel
    // as the quiet way out.
    unawaited(
      showEatovaDialog<DateTime>(
        context: context,
        builder: (dialogContext) => EatovaDialog(
          key: const ValueKey('meal-plan-eat-day-dialog'),
          title: l.mealPlanEatDayTitle,
          icon: Icons.event_available_outlined,
          content: Text(
            l.mealPlanEatDayBody(
              'Linsen-Curry mit Reis',
              DateFormat.MMMMEEEEd(l.localeName).format(planned),
            ),
          ),
          actions: [
            EatovaDialogAction(
              buttonKey: const ValueKey('meal-plan-eat-planned-day'),
              label: l.mealPlanEatOnPlannedDay(
                DateFormat.MMMEd(
                  l.localeName,
                ).format(planned).replaceAll(' ', ' '),
              ),
              onPressed: () => Navigator.of(dialogContext).pop(planned),
            ),
            EatovaDialogAction(
              buttonKey: const ValueKey('meal-plan-eat-today'),
              label: l.mealPlanEatOnToday,
              secondary: true,
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            EatovaDialogAction(
              buttonKey: const ValueKey('meal-plan-eat-cancel'),
              label: l.commonCancel,
              secondary: true,
              quiet: true,
              autofocus: true,
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_key('meal-plan-eat-day-dialog'), findsOneWidget);
    await _shoot(tester, 'dlg-three-actions');
  });

  testWidgets('buttons-gallery', (tester) async {
    pinDesignViewport(tester);
    await tester.pumpWidget(
      designCaptureBoundary(localizedApp(const _ButtonsGallery())),
    );
    // The busy spinners never settle.
    await tester.pump(const Duration(milliseconds: 400));
    await _shoot(tester, 'buttons-gallery');
  });

  testWidgets('buttons-focus', (tester) async {
    final strategy = FocusManager.instance.highlightStrategy;
    addTearDown(() => FocusManager.instance.highlightStrategy = strategy);
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    pinDesignViewport(tester);
    await tester.pumpWidget(
      designCaptureBoundary(localizedApp(const _ButtonsGallery())),
    );
    await tester.pump(const Duration(milliseconds: 400));
    // One focus at a time: a frame per focused control, then each control's
    // band of its own frame laid over the first.
    final focused = <Finder>[
      find.byKey(_ButtonsGallery.litKey),
      find.byKey(_ButtonsGallery.pillKey),
      find.byKey(_ButtonsGallery.quietKey),
    ];
    final frames = <(ui.Image, Rect)>[];
    for (final target in focused) {
      final label = find.descendant(of: target, matching: find.byType(Text));
      Focus.of(tester.element(label.first)).requestFocus();
      // One frame starts the highlight's fade, the next shows it in full.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(Focus.of(tester.element(label.first)).hasFocus, isTrue);
      final band = tester.getRect(target).inflate(18);
      if (!kDesignCapture) continue;
      frames.add((await _frame(tester), band));
    }
    if (!kDesignCapture) return;
    await tester.runAsync(() async {
      final (base, _) = frames.first;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..drawImage(base, Offset.zero, Paint());
      for (final (image, band) in frames.skip(1)) {
        final source = Rect.fromLTRB(
          0,
          band.top * kDesignPixelRatio,
          image.width.toDouble(),
          band.bottom * kDesignPixelRatio,
        );
        canvas.drawImageRect(image, source, source, Paint());
      }
      final picture = recorder.endRecording();
      final composite = await picture.toImage(base.width, base.height);
      final bytes = await composite.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$kDesignCaptureDir/buttons-focus-$_mode.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      composite.dispose();
      picture.dispose();
      for (final (image, _) in frames) {
        image.dispose();
      }
    });
  });

  testWidgets('sheet-header', (tester) async {
    final context = await _mountSettings(tester);
    unawaited(
      showWeeklyCheckExplainer(
        context,
        onOpenFoodLog: () {},
        onLogWeight: () {},
      ),
    );
    await tester.pumpAndSettle();
    expect(_key('weekly-check-explainer-close'), findsOneWidget);
    await _shoot(tester, 'sheet-header');
  });
}

/// Every button variant on its real ground: the screen-foot and sheet
/// buttons and the text actions on the page, the dialog actions on the
/// decision card's lit surface.
class _ButtonsGallery extends StatelessWidget {
  const _ButtonsGallery();

  static const litKey = ValueKey('gallery-lit');
  static const pillKey = ValueKey('gallery-pill');
  static const quietKey = ValueKey('gallery-quiet');

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l = context.l10n;
    Widget caption(String text) => Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 8),
      child: Text(
        text,
        style: AppType.ui(11.5, weight: FontWeight.w700, color: t.ink3),
      ),
    );
    const gap = SizedBox(height: 10);
    const across = SizedBox(width: 10);
    return SingleChildScrollView(
      // The card's ambient shadow reaches past the last row.
      clipBehavior: Clip.none,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          caption('PrimaryActionButton: lit, busy | locked, destructive'),
          KeyedSubtree(
            key: litKey,
            child: PrimaryActionButton(
              label: l.commonSave,
              icon: Icons.check_rounded,
              onTap: () {},
            ),
          ),
          gap,
          Row(
            children: [
              Expanded(
                child: PrimaryActionButton(
                  label: l.settingsDeleteAccountCheckingCta,
                  busy: true,
                  onTap: () {},
                ),
              ),
              across,
              Expanded(child: PrimaryActionButton(label: l.commonSave)),
            ],
          ),
          gap,
          PrimaryActionButton(
            label: l.settingsDeleteAccountActionLabel,
            destructive: true,
            onTap: () {},
          ),
          caption('SoftPillButton: accent, danger | neutral, quiet'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              SoftPillButton(
                key: pillKey,
                label: l.todayWeighChipLog,
                icon: Icons.monitor_weight_outlined,
                onTap: () {},
              ),
              SoftPillButton(
                label: l.commonDelete,
                icon: Icons.delete_outline_rounded,
                tone: SoftPillTone.danger,
                onTap: () {},
              ),
              SoftPillButton(
                label: l.todayOpenFoodLog,
                icon: Icons.restaurant_rounded,
                tone: SoftPillTone.neutral,
                onTap: () {},
              ),
              SoftPillButton(
                label: l.commonCancel,
                tone: SoftPillTone.quiet,
                onTap: () {},
              ),
            ],
          ),
          caption(
            'EatovaTextAction: accent, neutral | capsule accent, neutral',
          ),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              EatovaTextAction(
                label: l.premiumTermsLink,
                icon: Icons.open_in_new_rounded,
                iconSize: 16,
                onTap: () {},
              ),
              EatovaTextAction(
                label: l.settingsLegalImprint,
                tone: EatovaTextTone.neutral,
                onTap: () {},
              ),
              EatovaTextAction(
                label: l.settingsSyncRetry,
                icon: Icons.refresh_rounded,
                capsule: true,
                onTap: () {},
              ),
              EatovaTextAction(
                label: l.settingsAiDataWithdrawAction,
                tone: EatovaTextTone.neutral,
                capsule: true,
                onTap: () {},
              ),
            ],
          ),
          caption(
            'EatovaDialogAction on the card: lit | lit destructive, '
            'secondary | secondary destructive, quiet | locked',
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: litSurface(t),
              borderRadius: BorderRadius.circular(rSheet),
              boxShadow: decisionShadow(t),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: EatovaDialogAction(
                          label: l.settingsSignOutTitle,
                          onPressed: () {},
                        ),
                      ),
                      across,
                      Expanded(
                        child: EatovaDialogAction(
                          label: l.foodDiscardChangesConfirm,
                          destructive: true,
                          onPressed: () {},
                        ),
                      ),
                    ],
                  ),
                  gap,
                  Row(
                    children: [
                      Expanded(
                        child: EatovaDialogAction(
                          label: l.mealPlanEatOnToday,
                          secondary: true,
                          onPressed: () {},
                        ),
                      ),
                      across,
                      Expanded(
                        child: EatovaDialogAction(
                          label: l.commonDelete,
                          secondary: true,
                          destructive: true,
                          onPressed: () {},
                        ),
                      ),
                    ],
                  ),
                  gap,
                  Row(
                    children: [
                      Expanded(
                        child: KeyedSubtree(
                          key: quietKey,
                          child: EatovaDialogAction(
                            label: l.commonCancel,
                            secondary: true,
                            quiet: true,
                            onPressed: () {},
                          ),
                        ),
                      ),
                      across,
                      Expanded(
                        child: EatovaDialogAction(
                          label: l.commonSave,
                          onPressed: null,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
