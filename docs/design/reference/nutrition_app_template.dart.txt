// nutrition_app.dart
//
// Single-file Flutter implementation of the redesigned nutrition app.
//
// Two layers: Material 3 supplies behaviour, semantics and platform
// correctness; every visible surface is hand-built and reads its colours from
// the AppTokens ThemeExtension. Behaviour = Material, pixels = ours.
//
// pubspec.yaml:
//   dependencies:
//     flutter:
//       sdk: flutter
//     google_fonts: ^6.2.1
//
// If you prefer bundled fonts over google_fonts, replace the two helpers in
// _Type with TextStyle(fontFamily: 'BricolageGrotesque' / 'Archivo').

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

void main() => runApp(const NutritionApp());

// ═══════════════════════════════════════════════════════════════════════════
// TOKENS — the design layer's palette, carried on the M3 theme
// ═══════════════════════════════════════════════════════════════════════════

@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.bg,
    required this.surf,
    required this.surf2,
    required this.ink,
    required this.ink2,
    required this.line,
    required this.tile,
    required this.forest,
    required this.onForest,
    required this.lime,
    required this.accent,
    required this.protein,
    required this.carbs,
    required this.fat,
  });

  final Color bg, surf, surf2, ink, ink2, line, tile;
  final Color forest, onForest, lime;

  /// Stroke / fill colour for graphics that sit ON a light card.
  /// In dark mode `forest` is a *surface*, so it must not double as ink.
  final Color accent;
  final Color protein, carbs, fat;

  static const light = AppTokens(
    bg: Color(0xFFF2EFE6),
    surf: Color(0xFFFFFDF8),
    surf2: Color(0xFFEAE6DA),
    ink: Color(0xFF151E18),
    ink2: Color(0xFF6E7C73),
    line: Color(0x1A151E18),
    tile: Color(0x0D151E18),
    forest: Color(0xFF123322),
    onForest: Color(0xFFF4F2E6),
    lime: Color(0xFFC9F26E),
    accent: Color(0xFF123322),
    protein: Color(0xFF3C5CCC),
    carbs: Color(0xFFDE9426),
    fat: Color(0xFFCE6448),
  );

  static const dark = AppTokens(
    bg: Color(0xFF0B100D),
    surf: Color(0xFF141B17),
    surf2: Color(0xFF1F2823),
    ink: Color(0xFFEFEDE3),
    ink2: Color(0xFF8C9B91),
    line: Color(0x1AFFFFFF),
    tile: Color(0x12FFFFFF),
    forest: Color(0xFF16371F),
    onForest: Color(0xFFF1F3E4),
    lime: Color(0xFFCDF473),
    accent: Color(0xFFCDF473),
    protein: Color(0xFF7C95F5),
    carbs: Color(0xFFF0B458),
    fat: Color(0xFFE58366),
  );

  @override
  AppTokens copyWith({
    Color? bg,
    Color? surf,
    Color? surf2,
    Color? ink,
    Color? ink2,
    Color? line,
    Color? tile,
    Color? forest,
    Color? onForest,
    Color? lime,
    Color? accent,
    Color? protein,
    Color? carbs,
    Color? fat,
  }) {
    return AppTokens(
      bg: bg ?? this.bg,
      surf: surf ?? this.surf,
      surf2: surf2 ?? this.surf2,
      ink: ink ?? this.ink,
      ink2: ink2 ?? this.ink2,
      line: line ?? this.line,
      tile: tile ?? this.tile,
      forest: forest ?? this.forest,
      onForest: onForest ?? this.onForest,
      lime: lime ?? this.lime,
      accent: accent ?? this.accent,
      protein: protein ?? this.protein,
      carbs: carbs ?? this.carbs,
      fat: fat ?? this.fat,
    );
  }

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) {
    if (other is! AppTokens) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppTokens(
      bg: c(bg, other.bg),
      surf: c(surf, other.surf),
      surf2: c(surf2, other.surf2),
      ink: c(ink, other.ink),
      ink2: c(ink2, other.ink2),
      line: c(line, other.line),
      tile: c(tile, other.tile),
      forest: c(forest, other.forest),
      onForest: c(onForest, other.onForest),
      lime: c(lime, other.lime),
      accent: c(accent, other.accent),
      protein: c(protein, other.protein),
      carbs: c(carbs, other.carbs),
      fat: c(fat, other.fat),
    );
  }
}

extension TokensX on BuildContext {
  AppTokens get t => Theme.of(this).extension<AppTokens>()!;
}

// ═══════════════════════════════════════════════════════════════════════════
// TYPE — Bricolage Grotesque for display, Archivo for UI
// ═══════════════════════════════════════════════════════════════════════════

class _Type {
  static TextStyle display(
    double size, {
    FontWeight weight = FontWeight.w800,
    Color? color,
    double? letterSpacing,
    double? height,
  }) {
    return GoogleFonts.bricolageGrotesque(
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: letterSpacing ?? -size * 0.03,
      height: height,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
  }

  static TextStyle ui(
    double size, {
    FontWeight weight = FontWeight.w400,
    Color? color,
    double? letterSpacing,
    double? height,
  }) {
    return GoogleFonts.archivo(
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: letterSpacing,
      height: height,
    );
  }

  /// Small all-caps label used for section eyebrows.
  static TextStyle eyebrow(Color color, {double size = 10}) => GoogleFonts.archivo(
        fontSize: size,
        fontWeight: FontWeight.w600,
        color: color,
        letterSpacing: 1.5,
      );
}

// ═══════════════════════════════════════════════════════════════════════════
// THEME — Material 3 foundation
// ═══════════════════════════════════════════════════════════════════════════

ThemeData buildTheme(Brightness brightness) {
  final tk = brightness == Brightness.light ? AppTokens.light : AppTokens.dark;

  final scheme = ColorScheme.fromSeed(
    seedColor: tk.forest,
    brightness: brightness,
  ).copyWith(
    primary: tk.forest,
    onPrimary: tk.onForest,
    secondary: tk.lime,
    onSecondary: const Color(0xFF123322),
    surface: tk.bg,
    onSurface: tk.ink,
    outlineVariant: tk.line,
  );

  final base = ThemeData(useMaterial3: true, colorScheme: scheme);

  return base.copyWith(
    scaffoldBackgroundColor: tk.bg,
    splashFactory: InkSparkle.splashFactory,
    extensions: <ThemeExtension<dynamic>>[tk],
    textTheme: base.textTheme.apply(
      bodyColor: tk.ink,
      displayColor: tk.ink,
      fontFamily: GoogleFonts.archivo().fontFamily,
    ),
    iconTheme: IconThemeData(color: tk.ink2, size: 20),
    dividerTheme: DividerThemeData(color: tk.line, thickness: 1, space: 1),
    popupMenuTheme: PopupMenuThemeData(
      color: tk.surf,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: tk.line),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: tk.forest,
      contentTextStyle: _Type.ui(13, weight: FontWeight.w500, color: tk.onForest),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// APP STATE — swap for your own store / Riverpod / Bloc
// ═══════════════════════════════════════════════════════════════════════════

final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(ThemeMode.light);
final ValueNotifier<bool> demoFilledNotifier = ValueNotifier(true);

class NutritionApp extends StatelessWidget {
  const NutritionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'Nutrition',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: mode,
          home: const RootShell(),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// MODELS + DEMO DATA
// ═══════════════════════════════════════════════════════════════════════════

class FoodItem {
  const FoodItem(this.name, this.qty, this.kcal);
  final String name;
  final String qty;
  final int kcal;
}

enum MealSlot { breakfast, lunch, dinner, snack }

class Meal {
  const Meal({required this.slot, required this.items});
  final MealSlot slot;
  final List<FoodItem> items;

  String get name => switch (slot) {
        MealSlot.breakfast => 'Breakfast',
        MealSlot.lunch => 'Lunch',
        MealSlot.dinner => 'Dinner',
        MealSlot.snack => 'Snack',
      };

  String get letter => name.substring(0, 1);
  int get kcal => items.fold(0, (sum, i) => sum + i.kcal);
  bool get isEmpty => items.isEmpty;

  Color color(AppTokens t) => switch (slot) {
        MealSlot.breakfast => t.carbs,
        MealSlot.lunch => t.protein,
        MealSlot.dinner => t.fat,
        MealSlot.snack => t.ink2,
      };
}

class Recipe {
  const Recipe({
    required this.category,
    required this.title,
    required this.description,
    required this.kcal,
    required this.minutes,
    required this.serves,
    required this.slot,
  });
  final String category, title, description;
  final int kcal, minutes, serves;
  final MealSlot slot;
}

class ChatMessage {
  const ChatMessage({required this.text, required this.fromUser});
  final String text;
  final bool fromUser;
}

class DayLog {
  const DayLog({required this.meals, required this.burned, required this.streak});
  final List<Meal> meals;
  final int burned;
  final int streak;

  static const int goalKcal = 2000;
  static const int goalProtein = 150;
  static const int goalCarbs = 250;
  static const int goalFat = 65;

  int get eaten => meals.fold(0, (sum, m) => sum + m.kcal);
  int get left => (goalKcal - eaten).clamp(0, goalKcal);
  double get progress => (eaten / goalKcal).clamp(0.0, 1.0);
  bool get isEmpty => eaten == 0;

  // Demo macro split; replace with real per-item macros.
  int get protein => isEmpty ? 0 : 96;
  int get carbs => isEmpty ? 0 : 142;
  int get fat => isEmpty ? 0 : 34;

  static DayLog demo({required bool filled}) {
    if (!filled) {
      return const DayLog(
        meals: [
          Meal(slot: MealSlot.breakfast, items: []),
          Meal(slot: MealSlot.lunch, items: []),
          Meal(slot: MealSlot.dinner, items: []),
          Meal(slot: MealSlot.snack, items: []),
        ],
        burned: 0,
        streak: 0,
      );
    }
    return const DayLog(
      meals: [
        Meal(slot: MealSlot.breakfast, items: [
          FoodItem('Berry protein overnight oats', '1 jar · 320 g', 320),
          FoodItem('Greek yogurt 2%', '100 g', 100),
        ]),
        Meal(slot: MealSlot.lunch, items: [
          FoodItem('Mediterranean chicken bowl', '1 serving', 480),
          FoodItem('Hummus', '2 tbsp', 60),
        ]),
        Meal(slot: MealSlot.dinner, items: [
          FoodItem('Miso soup with tofu', '1 bowl', 200),
        ]),
        Meal(slot: MealSlot.snack, items: []),
      ],
      burned: 320,
      streak: 12,
    );
  }
}

const List<Recipe> kRecipes = [
  Recipe(
    category: 'BREAKFAST',
    title: 'Berry Protein Overnight Oats',
    description: 'Creamy oats with mixed berries, Greek yogurt and a scoop of protein.',
    kcal: 320,
    minutes: 10,
    serves: 1,
    slot: MealSlot.breakfast,
  ),
  Recipe(
    category: 'DINNER',
    title: 'Salmon & Sweet Potato',
    description: 'Baked salmon fillet with roasted sweet potato and steamed broccoli.',
    kcal: 540,
    minutes: 35,
    serves: 2,
    slot: MealSlot.dinner,
  ),
  Recipe(
    category: 'BREAKFAST',
    title: 'Avocado Egg Toast',
    description: 'Sourdough topped with smashed avocado, poached egg and chilli flakes.',
    kcal: 310,
    minutes: 12,
    serves: 1,
    slot: MealSlot.breakfast,
  ),
];

const List<String> kCoachPrompts = [
  'What should I eat for dinner to hit my protein goal?',
  'Suggest a low-calorie snack under 200 kcal',
  'How can I meal prep for the week?',
  'I went over my calorie goal — what now?',
];

String kcalStr(int v) {
  final s = v.toString();
  if (s.length <= 3) return s;
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write('\u2009');
    buf.write(s[i]);
  }
  return buf.toString();
}

// ═══════════════════════════════════════════════════════════════════════════
// SHELL + CUSTOM BOTTOM NAV
// ═══════════════════════════════════════════════════════════════════════════

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: demoFilledNotifier,
      builder: (context, filled, _) {
        final log = DayLog.demo(filled: filled);
        return Scaffold(
          body: IndexedStack(
            index: _index,
            children: [
              TodayScreen(log: log, onOpenCoach: () => setState(() => _index = 3)),
              DiaryScreen(log: log),
              const RecipesScreen(),
              CoachScreen(log: log),
            ],
          ),
          bottomNavigationBar: AppNavBar(
            index: _index,
            onChanged: (i) => setState(() => _index = i),
          ),
        );
      },
    );
  }
}

class AppNavBar extends StatelessWidget {
  const AppNavBar({super.key, required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  static const _items = [
    (Icons.home_outlined, Icons.home_rounded, 'Today'),
    (Icons.restaurant_outlined, Icons.restaurant_rounded, 'Food'),
    (Icons.menu_book_outlined, Icons.menu_book_rounded, 'Recipes'),
    (Icons.auto_awesome_outlined, Icons.auto_awesome_rounded, 'Coach'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: BoxDecoration(
        color: t.surf.withValues(alpha: 0.94),
        border: Border(top: BorderSide(color: t.line)),
      ),
      padding: EdgeInsets.fromLTRB(10, 10, 10, 10 + bottomInset),
      child: Row(
        children: List.generate(_items.length, (i) {
          final (iconOff, iconOn, label) = _items[i];
          final active = i == index;
          return Expanded(
            child: Semantics(
              selected: active,
              button: true,
              label: label,
              child: InkWell(
                onTap: () => onChanged(i),
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOut,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                        decoration: BoxDecoration(
                          color: active ? t.lime : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          active ? iconOn : iconOff,
                          size: 20,
                          color: active ? const Color(0xFF123322) : t.ink2,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        label,
                        style: _Type.ui(
                          10,
                          weight: active ? FontWeight.w700 : FontWeight.w500,
                          color: active ? t.ink : t.ink2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SHARED DESIGN-LAYER WIDGETS
// ═══════════════════════════════════════════════════════════════════════════

class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.radius = 24,
    this.color,
    this.clip = false,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final Color? color;
  final bool clip;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      clipBehavior: clip ? Clip.antiAlias : Clip.none,
      decoration: BoxDecoration(
        color: color ?? t.surf,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: t.line),
      ),
      padding: clip ? EdgeInsets.zero : padding,
      child: child,
    );
  }
}

class ScreenTitle extends StatelessWidget {
  const ScreenTitle({super.key, required this.title, this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: _Type.display(30, color: t.ink, height: 1.1)),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(subtitle!, style: _Type.ui(12, weight: FontWeight.w500, color: t.ink2)),
              ],
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

/// The signature calorie gauge: a row of ticks that fills with lime.
class TickGauge extends StatelessWidget {
  const TickGauge({super.key, required this.progress, this.height = 28});

  final double progress;
  final double height;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: progress.clamp(0.0, 1.0)),
      duration: const Duration(milliseconds: 550),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _TickGaugePainter(
            progress: value,
            trackColor: t.onForest.withValues(alpha: 0.20),
            fillColor: t.lime,
          ),
        ),
      ),
    );
  }
}

class _TickGaugePainter extends CustomPainter {
  _TickGaugePainter({
    required this.progress,
    required this.trackColor,
    required this.fillColor,
  });

  final double progress;
  final Color trackColor, fillColor;

  static const double tickWidth = 4;
  static const double gap = 5;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    final count = ((size.width + gap) / (tickWidth + gap)).floor();
    final filledUpTo = size.width * progress;

    for (var i = 0; i < count; i++) {
      final x = i * (tickWidth + gap);
      paint.color = (x + tickWidth) <= filledUpTo ? fillColor : trackColor;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 0, tickWidth, size.height),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_TickGaugePainter old) =>
      old.progress != progress || old.fillColor != fillColor || old.trackColor != trackColor;
}

class MacroBar extends StatelessWidget {
  const MacroBar({
    super.key,
    required this.label,
    required this.value,
    required this.goal,
    required this.unit,
    required this.color,
  });

  final String label;
  final int value, goal;
  final String unit;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final pct = goal == 0 ? 0.0 : (value / goal).clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Row(
        children: [
          SizedBox(width: 52, child: Text(label, style: _Type.ui(12, weight: FontWeight.w600, color: t.ink))),
          const SizedBox(width: 12),
          Expanded(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: pct),
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: LinearProgressIndicator(
                  value: v,
                  minHeight: 9,
                  backgroundColor: t.tile,
                  valueColor: AlwaysStoppedAnimation(color),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 68,
            child: Text.rich(
              TextSpan(
                text: '$value',
                style: _Type.ui(12, weight: FontWeight.w600, color: t.ink),
                children: [
                  TextSpan(
                    text: ' / $goal$unit',
                    style: _Type.ui(12, weight: FontWeight.w500, color: t.ink2),
                  ),
                ],
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class MealAvatar extends StatelessWidget {
  const MealAvatar({super.key, required this.letter, required this.color, this.size = 40});

  final String letter;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(size * 0.33),
      ),
      alignment: Alignment.center,
      child: Text(letter, style: _Type.display(size * 0.38, weight: FontWeight.w700, color: color)),
    );
  }
}

class SearchBarField extends StatelessWidget {
  const SearchBarField({super.key, required this.hint});

  final String hint;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.line),
      ),
      child: TextField(
        style: _Type.ui(14, color: t.ink),
        cursorColor: t.forest,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
          prefixIcon: Icon(Icons.search_rounded, size: 18, color: t.ink2),
          prefixIconConstraints: const BoxConstraints(minWidth: 44),
          hintText: hint,
          hintStyle: _Type.ui(14, color: t.ink2),
        ),
      ),
    );
  }
}

class FilterChipPill extends StatelessWidget {
  const FilterChipPill({super.key, required this.label, required this.selected, this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      color: selected ? t.forest : t.surf,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: selected ? Colors.transparent : t.line),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
          child: Text(
            label,
            style: _Type.ui(
              12,
              weight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? t.onForest : t.ink2,
            ),
          ),
        ),
      ),
    );
  }
}

/// Diagonal-stripe placeholder standing in for recipe photography.
class ImagePlaceholder extends StatelessWidget {
  const ImagePlaceholder({super.key, this.radius = 16, this.label = 'IMAGE'});

  final double radius;
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CustomPaint(
        painter: _StripePainter(base: t.surf2, stripe: t.tile),
        child: Center(
          child: Text(label, style: _Type.eyebrow(t.ink2, size: 9)),
        ),
      ),
    );
  }
}

class _StripePainter extends CustomPainter {
  _StripePainter({required this.base, required this.stripe});
  final Color base, stripe;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = base);
    final p = Paint()
      ..color = stripe
      ..strokeWidth = 10;
    for (double x = -size.height; x < size.width + size.height; x += 20) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), p);
    }
  }

  @override
  bool shouldRepaint(_StripePainter old) => old.base != base || old.stripe != stripe;
}

// ═══════════════════════════════════════════════════════════════════════════
// 1 · TODAY
// ═══════════════════════════════════════════════════════════════════════════

class TodayScreen extends StatelessWidget {
  const TodayScreen({super.key, required this.log, required this.onOpenCoach});

  final DayLog log;
  final VoidCallback onOpenCoach;

  @override
  Widget build(BuildContext context) {
    final t = context.t;

    return SafeArea(
      bottom: false,
      child: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 96),
            children: [
              _header(context),
              const SizedBox(height: 16),
              const DayStrip(),
              const SizedBox(height: 14),
              CalorieHero(log: log),
              const SizedBox(height: 14),
              AppCard(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(child: Text('Macros', style: _Type.display(17, weight: FontWeight.w700, color: t.ink))),
                        Text('Daily targets', style: _Type.ui(11.5, weight: FontWeight.w500, color: t.ink2)),
                      ],
                    ),
                    const SizedBox(height: 14),
                    MacroBar(label: 'Protein', value: log.protein, goal: DayLog.goalProtein, unit: 'g', color: t.protein),
                    MacroBar(label: 'Carbs', value: log.carbs, goal: DayLog.goalCarbs, unit: 'g', color: t.carbs),
                    MacroBar(label: 'Fat', value: log.fat, goal: DayLog.goalFat, unit: 'g', color: t.fat),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(child: Text("Today's meals", style: _Type.display(17, weight: FontWeight.w700, color: t.ink))),
                  Text('Manage', style: _Type.ui(11.5, weight: FontWeight.w600, color: t.ink2)),
                ],
              ),
              const SizedBox(height: 12),
              AppCard(
                clip: true,
                child: Column(
                  children: [
                    for (final meal in log.meals) MealRow(meal: meal, last: meal == log.meals.last),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              CoachBanner(log: log, onTap: onOpenCoach),
            ],
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 12,
            child: LogFoodButton(
              onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Open food search')),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final t = context.t;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('SUNDAY, AUG 9', style: _Type.eyebrow(t.ink2, size: 10.5)),
              const SizedBox(height: 3),
              Text('Good evening', style: _Type.display(30, color: t.ink, height: 1.1)),
            ],
          ),
        ),
        // Material 3 behaviour (ink, semantics, route push), custom-drawn trigger.
        Semantics(
          button: true,
          label: 'Open profile',
          child: Material(
            color: t.forest,
            borderRadius: BorderRadius.circular(14),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ProfileScreen()),
              ),
              child: SizedBox(
                width: 44,
                height: 44,
                child: Center(
                  child: Text('JS', style: _Type.ui(14, weight: FontWeight.w700, color: t.lime)),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class DayStrip extends StatelessWidget {
  const DayStrip({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.t;

    Widget arrow(IconData icon, {bool muted = false}) => Opacity(
          opacity: muted ? 0.45 : 1,
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: t.surf,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: t.line),
            ),
            child: Icon(icon, size: 15, color: t.ink2),
          ),
        );

    return Row(
      children: [
        arrow(Icons.chevron_left_rounded),
        const SizedBox(width: 8),
        Expanded(
          child: Container(
            height: 34,
            decoration: BoxDecoration(color: t.forest, borderRadius: BorderRadius.circular(11)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(width: 6, height: 6, decoration: BoxDecoration(color: t.lime, shape: BoxShape.circle)),
                const SizedBox(width: 7),
                Text('Today', style: _Type.ui(12.5, weight: FontWeight.w600, color: t.onForest)),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        arrow(Icons.chevron_right_rounded, muted: true),
      ],
    );
  }
}

class CalorieHero extends StatelessWidget {
  const CalorieHero({super.key, required this.log});

  final DayLog log;

  @override
  Widget build(BuildContext context) {
    final t = context.t;

    Widget stat(String value, String label, {Color? valueColor}) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: _Type.display(20, weight: FontWeight.w700, color: valueColor ?? t.onForest)),
              const SizedBox(height: 2),
              Text(label.toUpperCase(),
                  style: _Type.ui(10.5, weight: FontWeight.w500, color: t.onForest.withValues(alpha: 0.6), letterSpacing: 0.5)),
            ],
          ),
        );

    Widget divider() => Container(width: 1, height: 34, color: t.onForest.withValues(alpha: 0.18));

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: t.forest, borderRadius: BorderRadius.circular(28)),
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(painter: _DotGridPainter(color: t.lime.withValues(alpha: 0.16))),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('CALORIE BUDGET', style: _Type.eyebrow(t.lime))),
                    Text('Goal ${kcalStr(DayLog.goalKcal)} kcal',
                        style: _Type.ui(11, weight: FontWeight.w500, color: t.onForest.withValues(alpha: 0.65))),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(kcalStr(log.left),
                        style: _Type.display(66, color: t.onForest, height: 0.9, letterSpacing: -3)),
                    const SizedBox(width: 9),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text('kcal left',
                          style: _Type.ui(13, weight: FontWeight.w600, color: t.onForest.withValues(alpha: 0.7))),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                TickGauge(progress: log.progress),
                const SizedBox(height: 18),
                Row(
                  children: [
                    stat(kcalStr(log.eaten), 'Eaten'),
                    divider(),
                    const SizedBox(width: 16),
                    stat(kcalStr(log.burned), 'Burned'),
                    divider(),
                    const SizedBox(width: 16),
                    stat('${log.streak}', 'Day streak', valueColor: t.lime),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DotGridPainter extends CustomPainter {
  _DotGridPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    for (double y = 7; y < size.height; y += 14) {
      for (double x = 7; x < size.width; x += 14) {
        canvas.drawCircle(Offset(x, y), 1, p);
      }
    }
  }

  @override
  bool shouldRepaint(_DotGridPainter old) => old.color != color;
}

class MealRow extends StatelessWidget {
  const MealRow({super.key, required this.meal, this.last = false});

  final Meal meal;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final subtitle = meal.isEmpty
        ? 'Nothing logged yet'
        : meal.items.map((i) => i.name.split(' ').take(2).join(' ')).join(' · ');

    return InkWell(
      onTap: () {},
      child: Container(
        decoration: BoxDecoration(
          border: last ? null : Border(bottom: BorderSide(color: t.line)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            MealAvatar(letter: meal.letter, color: meal.color(t)),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(meal.name, style: _Type.ui(14, weight: FontWeight.w600, color: t.ink)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _Type.ui(11.5, color: t.ink2)),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${meal.kcal}', style: _Type.display(16, weight: FontWeight.w700, color: t.ink)),
                Text('KCAL', style: _Type.ui(9.5, weight: FontWeight.w500, color: t.ink2, letterSpacing: 0.5)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class CoachBanner extends StatelessWidget {
  const CoachBanner({super.key, required this.log, required this.onTap});

  final DayLog log;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final teaser = log.isEmpty
        ? 'Log your first meal and I will build your day around it.'
        : 'You are ${DayLog.goalProtein - log.protein} g protein short. Want a dinner idea?';

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: t.surf2,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: t.line),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -30,
            top: -30,
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: t.lime.withValues(alpha: 0.30),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('AI COACH', style: _Type.eyebrow(t.ink2)),
                const SizedBox(height: 6),
                SizedBox(
                  width: 230,
                  child: Text(teaser, style: _Type.display(19, weight: FontWeight.w700, color: t.ink, height: 1.2)),
                ),
                const SizedBox(height: 14),
                Material(
                  color: t.forest,
                  borderRadius: BorderRadius.circular(11),
                  child: InkWell(
                    onTap: onTap,
                    borderRadius: BorderRadius.circular(11),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Start chatting', style: _Type.ui(12, weight: FontWeight.w600, color: t.onForest)),
                          const SizedBox(width: 6),
                          Icon(Icons.chevron_right_rounded, size: 16, color: t.lime),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class LogFoodButton extends StatelessWidget {
  const LogFoodButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      color: t.ink,
      borderRadius: BorderRadius.circular(18),
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          height: 54,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_rounded, size: 18, color: t.bg),
              const SizedBox(width: 8),
              Text('Log food', style: _Type.ui(15, weight: FontWeight.w700, color: t.bg)),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 2 · FOOD DIARY
// ═══════════════════════════════════════════════════════════════════════════

class DiaryScreen extends StatelessWidget {
  const DiaryScreen({super.key, required this.log});

  final DayLog log;

  @override
  Widget build(BuildContext context) {
    final t = context.t;

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 24),
        children: [
          ScreenTitle(
            title: 'Food diary',
            subtitle: 'Sunday, August 9',
            trailing: Container(
              decoration: BoxDecoration(color: t.forest, borderRadius: BorderRadius.circular(14)),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(kcalStr(log.eaten),
                      style: _Type.display(20, weight: FontWeight.w700, color: t.onForest, height: 1)),
                  const SizedBox(height: 3),
                  Text('KCAL TODAY', style: _Type.ui(9.5, weight: FontWeight.w500, color: t.lime, letterSpacing: 0.6)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          const SearchBarField(hint: 'Search foods to log'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _quickChip(context, 'Recent', filled: true),
              _quickChip(context, 'Scan barcode'),
              _quickChip(context, 'My meals'),
            ],
          ),
          const SizedBox(height: 16),
          for (final meal in log.meals) ...[
            DiaryMealCard(meal: meal),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }

  Widget _quickChip(BuildContext context, String label, {bool filled = false}) {
    final t = context.t;
    return Container(
      decoration: BoxDecoration(
        color: filled ? t.surf2 : t.surf,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: filled ? Colors.transparent : t.line),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
      child: Text(label,
          style: _Type.ui(11.5,
              weight: filled ? FontWeight.w600 : FontWeight.w500, color: filled ? t.ink : t.ink2)),
    );
  }
}

class DiaryMealCard extends StatelessWidget {
  const DiaryMealCard({super.key, required this.meal});

  final Meal meal;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final color = meal.color(t);

    return AppCard(
      radius: 22,
      clip: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 14, 15, 14),
            child: Row(
              children: [
                MealAvatar(letter: meal.letter, color: color, size: 36),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(meal.name, style: _Type.ui(14.5, weight: FontWeight.w700, color: t.ink)),
                      const SizedBox(height: 2),
                      Text(
                        meal.isEmpty ? '0 kcal · nothing yet' : '${meal.kcal} kcal · ${meal.items.length} items',
                        style: _Type.ui(11.5, color: t.ink2),
                      ),
                    ],
                  ),
                ),
                Material(
                  color: t.forest,
                  borderRadius: BorderRadius.circular(11),
                  child: InkWell(
                    onTap: () {},
                    borderRadius: BorderRadius.circular(11),
                    child: SizedBox(
                      width: 32,
                      height: 32,
                      child: Icon(Icons.add_rounded, size: 17, color: t.lime),
                    ),
                  ),
                ),
              ],
            ),
          ),
          for (final item in meal.items)
            Container(
              decoration: BoxDecoration(border: Border(top: BorderSide(color: t.line))),
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
              child: Row(
                children: [
                  Container(
                    width: 3,
                    height: 26,
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _Type.ui(13, weight: FontWeight.w600, color: t.ink)),
                        const SizedBox(height: 1),
                        Text(item.qty, style: _Type.ui(11, color: t.ink2)),
                      ],
                    ),
                  ),
                  Text('${item.kcal}', style: _Type.ui(12.5, weight: FontWeight.w600, color: t.ink)),
                ],
              ),
            ),
          if (meal.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(15, 0, 15, 14),
              child: DottedAddSlot(label: 'Add food to ${meal.name.toLowerCase()}'),
            ),
        ],
      ),
    );
  }
}

class DottedAddSlot extends StatelessWidget {
  const DottedAddSlot({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return InkWell(
      onTap: () {},
      borderRadius: BorderRadius.circular(14),
      child: CustomPaint(
        painter: _DashedBorderPainter(color: t.line, radius: 14),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 13),
          alignment: Alignment.center,
          child: Text(label, style: _Type.ui(12, weight: FontWeight.w500, color: t.ink2)),
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color, required this.radius});
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.75, 0.75, size.width - 1.5, size.height - 1.5),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);

    for (final metric in path.computeMetrics()) {
      double d = 0;
      while (d < metric.length) {
        final next = (d + 5).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(d, next), paint);
        d += 9;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color;
}

// ═══════════════════════════════════════════════════════════════════════════
// 3 · RECIPES
// ═══════════════════════════════════════════════════════════════════════════

class RecipesScreen extends StatefulWidget {
  const RecipesScreen({super.key});

  @override
  State<RecipesScreen> createState() => _RecipesScreenState();
}

class _RecipesScreenState extends State<RecipesScreen> {
  static const _filters = ['All', 'Breakfast', 'Lunch', 'Dinner', 'Snack'];
  String _filter = 'All';

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final list = _filter == 'All'
        ? kRecipes
        : kRecipes.where((r) => r.category.toLowerCase() == _filter.toLowerCase()).toList();

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(0, 6, 0, 24),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: const ScreenTitle(
              title: 'Recipes',
              subtitle: 'Healthy meals with full nutrition',
            ),
          ),
          const SizedBox(height: 14),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: SearchBarField(hint: 'Search recipes'),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 38,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: _filters.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) => FilterChipPill(
                label: _filters[i],
                selected: _filters[i] == _filter,
                onTap: () => setState(() => _filter = _filters[i]),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: FeaturedRecipeCard(),
          ),
          const SizedBox(height: 18),
          for (final r in list)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: RecipeCard(recipe: r),
            ),
          if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text('No recipes in this category yet.',
                  style: _Type.ui(13, color: t.ink2)),
            ),
        ],
      ),
    );
  }
}

class FeaturedRecipeCard extends StatelessWidget {
  const FeaturedRecipeCard({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: SizedBox(
        height: 236,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ImagePlaceholder(radius: 0),
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Color(0xEB09140D), Color(0x8C09140D), Color(0x0009140D)],
                    stops: [0, 0.55, 1],
                  ),
                ),
                padding: const EdgeInsets.all(18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      decoration: BoxDecoration(color: t.lime, borderRadius: BorderRadius.circular(7)),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      child: Text('FEATURED',
                          style: _Type.ui(9.5,
                              weight: FontWeight.w700, color: const Color(0xFF123322), letterSpacing: 1)),
                    ),
                    const SizedBox(height: 9),
                    Text('Mediterranean Chicken Bowl',
                        style: _Type.display(24, color: const Color(0xFFF4F2E6), height: 1.15)),
                    const SizedBox(height: 9),
                    Row(
                      children: [
                        for (final s in ['480 kcal', '25 min', 'Serves 2'])
                          Padding(
                            padding: const EdgeInsets.only(right: 16),
                            child: Text(s,
                                style: _Type.ui(11.5,
                                    weight: FontWeight.w500, color: const Color(0xBFF4F2E6))),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RecipeCard extends StatelessWidget {
  const RecipeCard({super.key, required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final accent = switch (recipe.slot) {
      MealSlot.breakfast => t.carbs,
      MealSlot.lunch => t.protein,
      MealSlot.dinner => t.fat,
      MealSlot.snack => t.ink2,
    };

    return AppCard(
      radius: 22,
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(width: 96, height: 96, child: ImagePlaceholder()),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(recipe.category,
                    style: _Type.ui(9.5, weight: FontWeight.w700, color: accent, letterSpacing: 1.2)),
                const SizedBox(height: 4),
                Text(recipe.title, style: _Type.display(16.5, weight: FontWeight.w700, color: t.ink, height: 1.2)),
                const SizedBox(height: 4),
                Text(recipe.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: _Type.ui(11.5, color: t.ink2, height: 1.4)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text('${recipe.kcal} kcal', style: _Type.ui(11, weight: FontWeight.w600, color: t.ink)),
                    const SizedBox(width: 12),
                    Text('${recipe.minutes} min', style: _Type.ui(11, weight: FontWeight.w600, color: t.ink2)),
                    const SizedBox(width: 12),
                    Text('Serves ${recipe.serves}', style: _Type.ui(11, weight: FontWeight.w600, color: t.ink2)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 4 · AI COACH
// ═══════════════════════════════════════════════════════════════════════════

class CoachScreen extends StatefulWidget {
  const CoachScreen({super.key, required this.log});

  final DayLog log;

  @override
  State<CoachScreen> createState() => _CoachScreenState();
}

class _CoachScreenState extends State<CoachScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final List<ChatMessage> _messages = [];

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send(String text) {
    if (text.trim().isEmpty) return;
    setState(() {
      _messages.add(ChatMessage(text: text.trim(), fromUser: true));
      _messages.add(ChatMessage(text: _reply(), fromUser: false));
      _controller.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // Placeholder — wire to your assistant backend.
  String _reply() {
    final log = widget.log;
    if (log.isEmpty) {
      return 'Nothing logged yet today. Add a meal and I can give you concrete numbers.';
    }
    final proteinLeft = DayLog.goalProtein - log.protein;
    return 'You have $proteinLeft g protein and ${kcalStr(log.left)} kcal left. '
        'Salmon with sweet potato lands you at ${log.protein + 52} g protein for the day.';
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Container(
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.line))),
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(color: t.forest, borderRadius: BorderRadius.circular(14)),
                  child: Icon(Icons.auto_awesome_rounded, size: 19, color: t.lime),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('AI Coach', style: _Type.display(22, color: t.ink, height: 1.1)),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Container(width: 6, height: 6, decoration: BoxDecoration(color: t.lime, shape: BoxShape.circle)),
                          const SizedBox(width: 6),
                          Text("Sees today's log", style: _Type.ui(11.5, weight: FontWeight.w500, color: t.ink2)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
              children: [
                const ChatBubble(
                  text: "Hi! I'm your nutrition coach. Ask me about meals, macros, or staying on track — "
                      "I can see your logged intake for today.",
                  fromUser: false,
                ),
                for (final m in _messages) ChatBubble(text: m.text, fromUser: m.fromUser),
                const SizedBox(height: 10),
                Text('TRY ASKING', style: _Type.eyebrow(t.ink2)),
                const SizedBox(height: 12),
                for (final p in kCoachPrompts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: PromptRow(text: p, onTap: () => _send(p)),
                  ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(20, 10, 20, 14 + MediaQuery.of(context).viewInsets.bottom),
            child: Container(
              height: 52,
              decoration: BoxDecoration(
                color: t.surf,
                borderRadius: BorderRadius.circular(17),
                border: Border.all(color: t.line),
              ),
              padding: const EdgeInsets.only(left: 16, right: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      onSubmitted: _send,
                      textInputAction: TextInputAction.send,
                      cursorColor: t.forest,
                      style: _Type.ui(13.5, color: t.ink),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        isDense: true,
                        hintText: 'Message your coach…',
                        hintStyle: _Type.ui(13.5, color: t.ink2),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Material(
                    color: t.forest,
                    borderRadius: BorderRadius.circular(13),
                    child: InkWell(
                      onTap: () => _send(_controller.text),
                      borderRadius: BorderRadius.circular(13),
                      child: SizedBox(
                        width: 38,
                        height: 38,
                        child: Icon(Icons.send_rounded, size: 16, color: t.lime),
                      ),
                    ),
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

class ChatBubble extends StatelessWidget {
  const ChatBubble({super.key, required this.text, required this.fromUser});

  final String text;
  final bool fromUser;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 290),
          child: Container(
            decoration: BoxDecoration(
              color: fromUser ? t.forest : t.surf,
              border: Border.all(color: fromUser ? t.forest : t.line),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(20),
                topRight: const Radius.circular(20),
                bottomLeft: Radius.circular(fromUser ? 20 : 6),
                bottomRight: Radius.circular(fromUser ? 6 : 20),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Text(
              text,
              style: _Type.ui(13.5, color: fromUser ? t.onForest : t.ink, height: 1.5),
            ),
          ),
        ),
      ),
    );
  }
}

class PromptRow extends StatelessWidget {
  const PromptRow({super.key, required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      color: t.surf,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: t.line),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
          child: Row(
            children: [
              Container(width: 5, height: 5, decoration: BoxDecoration(color: t.lime, shape: BoxShape.circle)),
              const SizedBox(width: 10),
              Expanded(child: Text(text, style: _Type.ui(13, weight: FontWeight.w500, color: t.ink))),
              Icon(Icons.chevron_right_rounded, size: 16, color: t.ink2),
            ],
          ),
        ),
      ),
    );
  }
}


// ═══════════════════════════════════════════════════════════════════════════
// SHARED — page header, rows, toggles (design layer)
// ═══════════════════════════════════════════════════════════════════════════

class PageHeader extends StatelessWidget {
  const PageHeader({super.key, this.title, this.large, this.trailing});

  /// Centred small title (used on Profile).
  final String? title;

  /// Left-aligned display title (used on Settings).
  final String? large;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      children: [
        SquareIconButton(
          icon: Icons.chevron_left_rounded,
          onTap: () => Navigator.of(context).maybePop(),
          semanticLabel: 'Back',
        ),
        if (large != null) ...[
          const SizedBox(width: 12),
          Expanded(child: Text(large!, style: _Type.display(28, color: t.ink, height: 1.1))),
        ] else
          Expanded(
            child: Center(
              child: Text(title ?? '', style: _Type.ui(13, weight: FontWeight.w600, color: t.ink)),
            ),
          ),
        if (trailing != null) trailing! else if (large == null) const SizedBox(width: 34),
      ],
    );
  }
}

class SquareIconButton extends StatelessWidget {
  const SquareIconButton({super.key, required this.icon, this.onTap, this.semanticLabel});

  final IconData icon;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      button: true,
      label: semanticLabel,
      child: Material(
        color: t.surf,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(11),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: t.line),
            ),
            child: Icon(icon, size: 17, color: t.ink2),
          ),
        ),
      ),
    );
  }
}

class IconTile extends StatelessWidget {
  const IconTile({super.key, required this.icon, this.color, this.size = 34});

  final IconData icon;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color == null ? t.tile : color!.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Icon(icon, size: 16, color: color ?? t.ink),
    );
  }
}

/// Grouped card with an all-caps section label above it.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    required this.label,
    required this.children,
    this.labelColor,
    this.borderColor,
  });

  final String label;
  final List<Widget> children;
  final Color? labelColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          child: Text(label, style: _Type.eyebrow(labelColor ?? t.ink2)),
        ),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: t.surf,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: borderColor ?? t.line),
          ),
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) Divider(height: 1, thickness: 1, color: t.line),
                children[i],
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
      ],
    );
  }
}

class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.value,
    this.chevron = true,
    this.onTap,
    this.titleColor,
  });

  final String title;
  final String? subtitle, value;
  final Widget? leading, trailing;
  final bool chevron;
  final VoidCallback? onTap;
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 12)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: _Type.ui(13.5,
                          weight: titleColor == null ? FontWeight.w600 : FontWeight.w700,
                          color: titleColor ?? t.ink)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, style: _Type.ui(11.5, color: t.ink2)),
                  ],
                ],
              ),
            ),
            if (value != null)
              Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Text(value!, style: _Type.ui(12.5, weight: FontWeight.w500, color: t.ink2)),
              ),
            if (trailing != null) Padding(padding: const EdgeInsets.only(left: 10), child: trailing!),
            if (chevron)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(Icons.chevron_right_rounded, size: 17, color: t.ink2),
              ),
          ],
        ),
      ),
    );
  }
}

class AppToggle extends StatelessWidget {
  const AppToggle({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      toggled: value,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          width: 46,
          height: 27,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: value ? t.forest : t.tile,
            borderRadius: BorderRadius.circular(14),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 21,
              height: 21,
              decoration: BoxDecoration(
                color: value ? t.lime : t.surf,
                shape: BoxShape.circle,
                border: value ? null : Border.all(color: t.line),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SegmentedPill extends StatelessWidget {
  const SegmentedPill({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<String> options;
  final String selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: t.tile, borderRadius: BorderRadius.circular(9)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final o in options)
            GestureDetector(
              onTap: () => onChanged(o),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                decoration: BoxDecoration(
                  color: o == selected ? t.forest : Colors.transparent,
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(
                  o,
                  style: _Type.ui(11,
                      weight: FontWeight.w600, color: o == selected ? t.onForest : t.ink2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 5 · PROFILE
// ═══════════════════════════════════════════════════════════════════════════

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  static const String userName = 'Jonas Schmidt';
  static const String userEmail = 'jonas.schmidt@mail.com';

  @override
  Widget build(BuildContext context) {
    final t = context.t;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 32),
          children: [
            PageHeader(
              title: 'Profile',
              trailing: SquareIconButton(
                icon: Icons.settings_outlined,
                semanticLabel: 'Settings',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const IdentityCard(),
            const SizedBox(height: 14),
            const Row(
              children: [
                Expanded(child: StatTile(label: 'DAY STREAK', value: '12', unit: 'days')),
                SizedBox(width: 12),
                Expanded(child: StatTile(label: 'AVG INTAKE', value: '1 840', unit: 'kcal')),
              ],
            ),
            const SizedBox(height: 14),
            const WeightCard(),
            const SizedBox(height: 20),
            Text('Goals & targets', style: _Type.display(17, weight: FontWeight.w700, color: t.ink)),
            const SizedBox(height: 12),
            const GoalsCard(),
          ],
        ),
      ),
    );
  }
}

class IdentityCard extends StatelessWidget {
  const IdentityCard({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.t;

    Widget tag(String text, {bool solid = false}) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: solid ? t.lime : t.onForest.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            text,
            style: _Type.ui(10.5,
                weight: solid ? FontWeight.w700 : FontWeight.w600,
                color: solid ? const Color(0xFF123322) : t.onForest,
                letterSpacing: 0.4),
          ),
        );

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: t.forest, borderRadius: BorderRadius.circular(28)),
      child: Stack(
        children: [
          Positioned(
            right: -40,
            bottom: -50,
            child: Container(
              width: 150,
              height: 150,
              decoration: BoxDecoration(
                color: t.lime.withValues(alpha: 0.16),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(color: t.lime, borderRadius: BorderRadius.circular(22)),
                      alignment: Alignment.center,
                      child: Text('JS', style: _Type.display(24, color: const Color(0xFF123322))),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(ProfileScreen.userName,
                              style: _Type.display(23, color: t.onForest, height: 1.1)),
                          const SizedBox(height: 2),
                          Text(ProfileScreen.userEmail,
                              style: _Type.ui(12.5, color: t.onForest.withValues(alpha: 0.7))),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Material(
                      color: t.onForest.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(11),
                      child: InkWell(
                        onTap: () {},
                        borderRadius: BorderRadius.circular(11),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
                          child: Text('Edit',
                              style: _Type.ui(11.5, weight: FontWeight.w600, color: t.onForest)),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    tag('PREMIUM', solid: true),
                    const SizedBox(width: 8),
                    tag('MEMBER SINCE 2024'),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, required this.unit});

  final String label, value, unit;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AppCard(
      radius: 20,
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: _Type.eyebrow(t.ink2, size: 9.5)),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value, style: _Type.display(28, color: t.ink)),
              const SizedBox(width: 5),
              Text(unit, style: _Type.ui(11, weight: FontWeight.w500, color: t.ink2)),
            ],
          ),
        ],
      ),
    );
  }
}

class WeightCard extends StatelessWidget {
  const WeightCard({super.key});

  static const List<double> series = [78.6, 79.2, 78.9, 80.1, 80.6, 80.3, 81.4, 81.0];
  static const double current = 78.4;
  static const double goal = 75.0;
  static const double delta = -2.6;
  static const double goalProgress = 0.63;

  @override
  Widget build(BuildContext context) {
    final t = context.t;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: Text('Weight', style: _Type.display(17, weight: FontWeight.w700, color: t.ink))),
              Text('Last 8 weeks', style: _Type.ui(11.5, weight: FontWeight.w600, color: t.ink2)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(current.toStringAsFixed(1), style: _Type.display(34, color: t.ink)),
              const SizedBox(width: 8),
              Text('kg', style: _Type.ui(13, weight: FontWeight.w600, color: t.ink2)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: t.lime.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text('${delta.toStringAsFixed(1)} kg',
                    style: _Type.ui(11, weight: FontWeight.w700, color: t.ink)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 74,
            child: CustomPaint(
              size: Size.infinite,
              painter: _SparklinePainter(values: series, stroke: t.accent, dotFill: t.surf),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final s in ['JUN 15', 'JUL 13', 'AUG 9'])
                Text(s, style: _Type.ui(9.5, weight: FontWeight.w500, color: t.ink2, letterSpacing: 0.4)),
            ],
          ),
          const SizedBox(height: 14),
          Divider(height: 1, thickness: 1, color: t.line),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Goal ${goal.toStringAsFixed(1)} kg',
                        style: _Type.ui(11.5, weight: FontWeight.w600, color: t.ink)),
                    const SizedBox(height: 7),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: goalProgress,
                        minHeight: 7,
                        backgroundColor: t.tile,
                        valueColor: AlwaysStoppedAnimation(t.accent),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text('${(goalProgress * 100).round()}%',
                  style: _Type.ui(11.5, weight: FontWeight.w700, color: t.ink2)),
            ],
          ),
        ],
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({required this.values, required this.stroke, required this.dotFill});

  final List<double> values;
  final Color stroke, dotFill;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;

    final minV = values.reduce((a, b) => a < b ? a : b);
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final range = (maxV - minV).abs() < 0.001 ? 1.0 : maxV - minV;

    const pad = 6.0;
    final points = <Offset>[];
    for (var i = 0; i < values.length; i++) {
      final x = pad + (size.width - pad * 2) * (i / (values.length - 1));
      final y = pad + (size.height - pad * 2) * (1 - (values[i] - minV) / range);
      points.add(Offset(x, y));
    }

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = stroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    final last = points.last;
    canvas.drawCircle(last, 5, Paint()..color = dotFill);
    canvas.drawCircle(
      last,
      5,
      Paint()
        ..color = stroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.values != values || old.stroke != stroke || old.dotFill != dotFill;
}

class GoalsCard extends StatelessWidget {
  const GoalsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.t;

    Widget legendDot(Color c, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 7, height: 7, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
            const SizedBox(width: 5),
            Text(label, style: _Type.ui(11, weight: FontWeight.w600, color: t.ink2)),
          ],
        );

    return AppCard(
      clip: true,
      child: Column(
        children: [
          SettingsRow(
            leading: const IconTile(icon: Icons.local_fire_department_outlined),
            title: 'Daily calories',
            value: '${kcalStr(DayLog.goalKcal)} kcal',
            onTap: () {},
          ),
          Divider(height: 1, thickness: 1, color: t.line),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              children: [
                Row(
                  children: [
                    const IconTile(icon: Icons.bar_chart_rounded),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('Macro split', style: _Type.ui(13.5, weight: FontWeight.w600, color: t.ink)),
                    ),
                    Icon(Icons.chevron_right_rounded, size: 17, color: t.ink2),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: SizedBox(
                    height: 9,
                    child: Row(
                      children: [
                        Expanded(flex: 30, child: ColoredBox(color: t.protein)),
                        Expanded(flex: 50, child: ColoredBox(color: t.carbs)),
                        Expanded(flex: 20, child: ColoredBox(color: t.fat)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 9),
                Row(
                  children: [
                    legendDot(t.protein, '${DayLog.goalProtein}g protein'),
                    const SizedBox(width: 14),
                    legendDot(t.carbs, '${DayLog.goalCarbs}g carbs'),
                    const SizedBox(width: 14),
                    legendDot(t.fat, '${DayLog.goalFat}g fat'),
                  ],
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: t.line),
          SettingsRow(
            leading: const IconTile(icon: Icons.schedule_rounded),
            title: 'Activity level',
            value: 'Moderate',
            onTap: () {},
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 6 · SETTINGS
// ═══════════════════════════════════════════════════════════════════════════

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _units = 'Metric';
  bool _mealReminders = true;
  bool _weeklyEmail = false;
  bool _healthSync = true;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 32),
          children: [
            const PageHeader(large: 'Settings'),
            const SizedBox(height: 16),
            SettingsGroup(
              label: 'ACCOUNT',
              children: [
                SettingsRow(
                  leading: IconTile(icon: Icons.mail_outline_rounded, color: t.protein),
                  title: 'Email address',
                  subtitle: ProfileScreen.userEmail,
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: t.lime.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text('VERIFIED',
                        style: _Type.ui(9.5, weight: FontWeight.w700, color: t.ink, letterSpacing: 0.5)),
                  ),
                  onTap: () => _openSheet(context, const ChangeEmailSheet()),
                ),
                SettingsRow(
                  leading: const IconTile(icon: Icons.lock_outline_rounded),
                  title: 'Password',
                  subtitle: 'Last changed 4 months ago',
                  onTap: () => _openSheet(context, const ChangePasswordSheet()),
                ),
                SettingsRow(
                  leading: const IconTile(icon: Icons.link_rounded),
                  title: 'Connected accounts',
                  value: 'Apple',
                  onTap: () {},
                ),
              ],
            ),
            SettingsGroup(
              label: 'PREFERENCES',
              children: [
                SettingsRow(
                  title: 'Units',
                  chevron: false,
                  trailing: SegmentedPill(
                    options: const ['Metric', 'Imperial'],
                    selected: _units,
                    onChanged: (v) => setState(() => _units = v),
                  ),
                ),
                SettingsRow(title: 'Language', value: 'English', onTap: () {}),
                SettingsRow(
                  title: 'Meal reminders',
                  subtitle: 'Breakfast, lunch, dinner',
                  chevron: false,
                  trailing: AppToggle(
                    value: _mealReminders,
                    onChanged: (v) => setState(() => _mealReminders = v),
                  ),
                ),
                SettingsRow(
                  title: 'Weekly summary email',
                  chevron: false,
                  trailing: AppToggle(
                    value: _weeklyEmail,
                    onChanged: (v) => setState(() => _weeklyEmail = v),
                  ),
                ),
                SettingsRow(
                  title: 'Dark appearance',
                  chevron: false,
                  trailing: AppToggle(
                    value: isDark,
                    onChanged: (v) => themeModeNotifier.value = v ? ThemeMode.dark : ThemeMode.light,
                  ),
                ),
              ],
            ),
            SettingsGroup(
              label: 'DATA & PRIVACY',
              children: [
                SettingsRow(
                  title: 'Apple Health sync',
                  chevron: false,
                  trailing: AppToggle(
                    value: _healthSync,
                    onChanged: (v) => setState(() => _healthSync = v),
                  ),
                ),
                SettingsRow(title: 'Export my data', value: 'CSV', onTap: () {}),
                SettingsRow(title: 'Privacy policy', onTap: () {}),
                // Demo helper — remove in production.
                SettingsRow(
                  title: 'Demo: empty state',
                  chevron: false,
                  trailing: ValueListenableBuilder<bool>(
                    valueListenable: demoFilledNotifier,
                    builder: (context, filled, _) => AppToggle(
                      value: !filled,
                      onChanged: (v) => demoFilledNotifier.value = !v,
                    ),
                  ),
                ),
              ],
            ),
            SettingsGroup(
              label: 'DANGER ZONE',
              labelColor: t.fat,
              borderColor: t.fat.withValues(alpha: 0.35),
              children: [
                SettingsRow(title: 'Sign out', onTap: () {}),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          IconTile(icon: Icons.delete_outline_rounded, color: t.fat),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Delete account',
                                    style: _Type.ui(13.5, weight: FontWeight.w700, color: t.fat)),
                                const SizedBox(height: 2),
                                Text('Removes all logs permanently', style: _Type.ui(11.5, color: t.ink2)),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Material(
                        color: t.fat.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(13),
                        child: InkWell(
                          onTap: () => _openSheet(context, const DeleteAccountSheet()),
                          borderRadius: BorderRadius.circular(13),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
                            child: Text.rich(
                              TextSpan(
                                text: 'You will be asked to type ',
                                children: [
                                  TextSpan(
                                    text: 'DELETE',
                                    style: _Type.ui(11.5, weight: FontWeight.w700, color: t.ink, height: 1.45),
                                  ),
                                  const TextSpan(
                                      text: ' and confirm with your password. Data is erased after 30 days.'),
                                ],
                                style: _Type.ui(11.5, color: t.ink2, height: 1.45),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Center(
              child: Text('Version 2.4.0 · Build 318',
                  style: _Type.ui(10.5, weight: FontWeight.w500, color: t.ink2)),
            ),
          ],
        ),
      ),
    );
  }

  void _openSheet(BuildContext context, Widget sheet) {
    final t = context.t;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: t.bg,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
        child: sheet,
      ),
    );
  }
}

// ── Account sheets ────────────────────────────────────────────────────────

class SheetScaffold extends StatelessWidget {
  const SheetScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
    required this.actionLabel,
    this.destructive = false,
    this.onAction,
  });

  final String title, subtitle, actionLabel;
  final List<Widget> children;
  final bool destructive;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: _Type.display(24, color: t.ink, height: 1.15)),
          const SizedBox(height: 6),
          Text(subtitle, style: _Type.ui(12.5, color: t.ink2, height: 1.45)),
          const SizedBox(height: 18),
          ...children,
          const SizedBox(height: 20),
          Material(
            color: destructive ? t.fat : t.forest,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              onTap: onAction ?? () => Navigator.of(context).pop(),
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                height: 52,
                width: double.infinity,
                child: Center(
                  child: Text(actionLabel,
                      style: _Type.ui(14.5,
                          weight: FontWeight.w700,
                          color: destructive ? const Color(0xFFFFF6F2) : t.onForest)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SheetField extends StatelessWidget {
  const SheetField({super.key, required this.label, required this.hint, this.obscure = false});

  final String label, hint;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(), style: _Type.eyebrow(t.ink2, size: 9.5)),
          const SizedBox(height: 7),
          Container(
            decoration: BoxDecoration(
              color: t.surf,
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: t.line),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 15),
            child: TextField(
              obscureText: obscure,
              cursorColor: t.forest,
              style: _Type.ui(14, color: t.ink),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 15),
                hintText: hint,
                hintStyle: _Type.ui(14, color: t.ink2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ChangeEmailSheet extends StatelessWidget {
  const ChangeEmailSheet({super.key});

  @override
  Widget build(BuildContext context) {
    return const SheetScaffold(
      title: 'Change email',
      subtitle: 'We send a confirmation link to the new address. '
          'Your current address stays active until you confirm.',
      actionLabel: 'Send confirmation',
      children: [
        SheetField(label: 'New email', hint: 'you@example.com'),
        SheetField(label: 'Current password', hint: '••••••••', obscure: true),
      ],
    );
  }
}

class ChangePasswordSheet extends StatelessWidget {
  const ChangePasswordSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return SheetScaffold(
      title: 'Change password',
      subtitle: 'At least 10 characters, one number and one symbol.',
      actionLabel: 'Update password',
      children: [
        const SheetField(label: 'Current password', hint: '••••••••', obscure: true),
        const SheetField(label: 'New password', hint: '••••••••', obscure: true),
        Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: 0.66,
                  minHeight: 6,
                  backgroundColor: t.tile,
                  valueColor: AlwaysStoppedAnimation(t.carbs),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text('Medium', style: _Type.ui(11, weight: FontWeight.w700, color: t.ink2)),
          ],
        ),
      ],
    );
  }
}

class DeleteAccountSheet extends StatefulWidget {
  const DeleteAccountSheet({super.key});

  @override
  State<DeleteAccountSheet> createState() => _DeleteAccountSheetState();
}

class _DeleteAccountSheetState extends State<DeleteAccountSheet> {
  final _confirm = TextEditingController();

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final armed = _confirm.text.trim().toUpperCase() == 'DELETE';

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Delete account', style: _Type.display(24, color: t.fat, height: 1.15)),
          const SizedBox(height: 6),
          Text(
            'This removes your profile, all food logs and your weight history. '
            'Data is erased after 30 days and cannot be restored.',
            style: _Type.ui(12.5, color: t.ink2, height: 1.45),
          ),
          const SizedBox(height: 18),
          Text('TYPE DELETE TO CONFIRM', style: _Type.eyebrow(t.ink2, size: 9.5)),
          const SizedBox(height: 7),
          Container(
            decoration: BoxDecoration(
              color: t.surf,
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: armed ? t.fat : t.line),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 15),
            child: TextField(
              controller: _confirm,
              onChanged: (_) => setState(() {}),
              textCapitalization: TextCapitalization.characters,
              cursorColor: t.fat,
              style: _Type.ui(14, weight: FontWeight.w700, color: t.ink, letterSpacing: 1),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 15),
                hintText: 'DELETE',
                hintStyle: _Type.ui(14, color: t.ink2, letterSpacing: 1),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const SheetField(label: 'Password', hint: '••••••••', obscure: true),
          const SizedBox(height: 8),
          Opacity(
            opacity: armed ? 1 : 0.4,
            child: Material(
              color: t.fat,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                onTap: armed ? () => Navigator.of(context).pop() : null,
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  height: 52,
                  width: double.infinity,
                  child: Center(
                    child: Text('Delete my account',
                        style: _Type.ui(14.5, weight: FontWeight.w700, color: const Color(0xFFFFF6F2))),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
