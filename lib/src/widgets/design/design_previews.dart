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

@EatovaPreview(name: 'Primäre Aktion', size: Size(360, 150))
Widget primaryActionPreview() => Builder(
  builder: (context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      PrimaryActionButton(
        label: context.l10n.commonSave,
        icon: AppIcons.check,
        onTap: () {},
      ),
      const SizedBox(height: 12),
      SoftPillButton(
        label: context.l10n.commonCancel,
        onTap: () {},
        tone: SoftPillTone.neutral,
        size: SoftPillSize.regular,
        expand: true,
      ),
    ],
  ),
);

@EatovaPreview(name: 'Icon-Buttons und Stepper', size: Size(360, 170))
Widget iconButtonsPreview() => Builder(
  builder: (context) {
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: kSpace12,
          runSpacing: kSpace12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final tone in IconButtonTone.values)
              AppIconButton(
                icon: AppIcons.edit,
                semanticLabel: tone.name,
                tone: tone,
                onTap: () {},
              ),
            AppIconButton(
              icon: AppIcons.favorite,
              semanticLabel: l10n.commonSave,
              selected: true,
              onTap: () {},
            ),
            AppIconButton(
              icon: AppIcons.check,
              semanticLabel: l10n.commonSave,
              tone: IconButtonTone.primary,
              size: IconButtonSize.large,
              onTap: () {},
            ),
          ],
        ),
        const SizedBox(height: kSpace16),
        AppStepper(
          value: '250',
          unit: 'g',
          increasedValue: '260 g',
          decreasedValue: '240 g',
          semanticLabel: l10n.commonSave,
          onDecrement: () {},
          onIncrement: () {},
        ),
      ],
    );
  },
);

@EatovaPreview(name: 'Liste', size: Size(360, 330))
Widget listSectionPreview() => Builder(
  builder: (context) {
    final l10n = context.l10n;
    return ListSection(
      title: l10n.settingsLanguageTitle,
      footnote: l10n.settingsLanguageSubtitle,
      spacing: 0,
      children: [
        ListRow(
          icon: AppIcons.translate,
          title: l10n.settingsLanguageTitle,
          value: 'Deutsch',
          trailing: ListTrailing.chevron,
          onTap: () {},
        ),
        ListRow(
          icon: AppIcons.notifications,
          title: l10n.commonSave,
          trailing: ListTrailing.toggle,
          toggled: true,
          onToggle: (_) {},
        ),
        ListRow(
          icon: AppIcons.logout,
          title: l10n.commonDelete,
          destructive: true,
          onTap: () {},
        ),
      ],
    );
  },
);

@EatovaPreview(name: 'Aufzaehlungen', size: Size(360, 260))
Widget enumerationsPreview() => Builder(
  builder: (context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const BulletList(items: <String>['200 g Haferflocken', '1 Banane']),
      const SizedBox(height: kSpace16),
      const NumberedSteps(
        steps: <String>[
          'Haferflocken mit Milch aufkochen.',
          'Banane in Scheiben schneiden und unterheben.',
        ],
      ),
      const SizedBox(height: kSpace16),
      BulletList.icons(
        entries: <IconBullet>[
          (
            icon: AppIcons.checkCircle,
            color: context.t.success,
            text: context.l10n.commonSave,
          ),
        ],
      ),
    ],
  ),
);

@EatovaPreview(name: 'Status, Badges, Leerzustand', size: Size(360, 330))
Widget statesPreview() => Builder(
  builder: (context) {
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: kSpace8,
          runSpacing: kSpace8,
          children: [
            StatusPill(label: l10n.commonSave, dot: true, tone: StatusTone.success),
            StatusPill(
              label: l10n.commonSave,
              icon: AppIcons.aiMark,
              tone: StatusTone.accent,
            ),
            for (final size in IconBadgeSize.values)
              IconBadge(icon: AppIcons.flame, size: size),
          ],
        ),
        const SizedBox(height: kSpace16),
        CalmState(
          card: true,
          icon: AppIcons.shoppingBasket,
          title: l10n.commonSave,
          text: l10n.settingsLanguageSubtitle,
        ),
      ],
    );
  },
);

@EatovaPreview(name: 'Navigation', size: Size(390, 112))
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
