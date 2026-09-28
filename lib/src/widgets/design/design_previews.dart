/// Widget previews for the shared design library (`flutter widget-preview`).
///
/// Only design components are previewed: this library imports nothing but
/// Flutter, intl and the web-safe theme/l10n/design files, because the
/// previewer runs on the web and a transitive `dart:io` or plugin import would
/// break it. The app never imports this file; `design_previews_test.dart`
/// builds every preview so it stays compiling.
library;

import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_theme.dart';
import '../../theme/app_tokens.dart';
import 'design.dart';

/// Light Eatova theme, localizations and a surface around one preview.
///
/// Wrappers rather than `Preview.theme` (`PreviewThemeData` is marked as an
/// unstable interface in Flutter 3.47), and one per palette instead of a
/// branch on brightness: choosing a palette by brightness belongs to
/// lib/src/theme/ (repo rule).
Widget eatovaLightPreviewWrapper(Widget child) =>
    _wrap(buildEatovaTheme(Brightness.light), child);

/// Dark counterpart of [eatovaLightPreviewWrapper].
Widget eatovaDarkPreviewWrapper(Widget child) =>
    _wrap(buildEatovaTheme(Brightness.dark), child);

Widget _wrap(ThemeData theme, Widget child) => Theme(
  data: theme,
  child: Localizations(
    locale: const Locale('de'),
    delegates: AppLocalizations.localizationsDelegates,
    child: Builder(
      builder: (context) => Material(
        color: context.t.bg,
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    ),
  ),
);

/// Light and dark variants of one design component.
final class EatovaPreview extends MultiPreview {
  const EatovaPreview({required this.name, this.size});

  final String name;
  final Size? size;

  @override
  List<Preview> get previews => <Preview>[
    Preview(
      group: 'Eatova design',
      name: '$name · hell',
      size: size,
      brightness: Brightness.light,
      wrapper: eatovaLightPreviewWrapper,
    ),
    Preview(
      group: 'Eatova design',
      name: '$name · dunkel',
      size: size,
      brightness: Brightness.dark,
      wrapper: eatovaDarkPreviewWrapper,
    ),
  ];
}

@EatovaPreview(name: 'Makrobalken', size: Size(360, 150))
Widget macroBarsPreview() => Builder(
  builder: (context) {
    final t = context.t;
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MacroBar(
          label: l10n.todayMacroProtein,
          value: 96,
          goal: 140,
          unit: l10n.commonUnitG,
          color: t.proteinProgress,
        ),
        MacroBar(
          label: l10n.todayMacroCarbs,
          value: 180,
          goal: 230,
          unit: l10n.commonUnitG,
          color: t.carbsProgress,
        ),
        MacroBar(
          label: l10n.todayMacroFat,
          value: 70,
          goal: 65,
          unit: l10n.commonUnitG,
          color: t.fatProgress,
        ),
      ],
    );
  },
);

@EatovaPreview(name: 'Primäre Aktion', size: Size(360, 150))
Widget primaryActionPreview() => Builder(
  builder: (context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      PrimaryActionButton(
        label: context.l10n.commonSave,
        icon: Icons.check_rounded,
        onTap: () {},
      ),
      const SizedBox(height: 12),
      PrimaryActionButton(label: context.l10n.commonSave),
    ],
  ),
);

@EatovaPreview(name: 'Navigation', size: Size(390, 90))
Widget navBarPreview() => Builder(
  builder: (context) {
    final l10n = context.l10n;
    return AppNavBar(
      index: 1,
      onChanged: (_) {},
      items: <AppNavItem>[
        AppNavItem(icon: AppSymbol.today, label: l10n.navToday),
        AppNavItem(icon: AppSymbol.food, label: l10n.navFood),
        AppNavItem(icon: AppSymbol.recipes, label: l10n.navRecipes),
        AppNavItem(icon: AppSymbol.training, label: l10n.navTraining),
        AppNavItem(icon: AppSymbol.coach, label: l10n.navCoach),
      ],
    );
  },
);

@EatovaPreview(name: 'Lesbare Spalte (Tablet)', size: Size(1024, 200))
Widget readableWidthPreview() => Builder(
  builder: (context) => ReadableWidth(
    child: AppCard(
      child: Text(
        context.l10n.coachHeroSubtitle,
        style: AppType.ui(15, color: context.t.ink),
      ),
    ),
  ),
);
