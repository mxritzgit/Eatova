part of 'meal_widgets.dart';

class MealPreviewCard extends StatelessWidget {
  const MealPreviewCard({super.key, required this.imageBytes});

  final Uint8List? imageBytes;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return AppCard(
      radius: rCard,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: l10n.foodPhotoCardTitle,
            action: l10n.foodPhotoCardPreviewAction,
          ),
          const SizedBox(height: 10),
          Container(
            key: const ValueKey('analyse-image-preview'),
            height: 170,
            width: double.infinity,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: t.surf2,
              borderRadius: BorderRadius.circular(rCard),
            ),
            child: imageBytes == null
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.restaurant_menu_outlined,
                        color: t.ink2,
                        size: 32,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.foodNoImageSelected,
                        style: AppType.ui(
                          13,
                          weight: FontWeight.w500,
                          color: t.ink2,
                        ),
                      ),
                    ],
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      // Decode at card width (pattern of the coach recipe
                      // card): the bytes are the scrubbed UPLOAD image, up to
                      // 1600 px — full size is a multi-MB texture for a
                      // 170-px slot.
                      final dpr = MediaQuery.devicePixelRatioOf(context);
                      final w = constraints.maxWidth.isFinite
                          ? constraints.maxWidth
                          : 320.0;
                      return Image.memory(
                        imageBytes!,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        cacheWidth: (w * dpr).round().clamp(1, 1600),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class MealLoadingCard extends StatefulWidget {
  const MealLoadingCard({super.key});

  @override
  State<MealLoadingCard> createState() => _MealLoadingCardState();
}

class _MealLoadingCardState extends State<MealLoadingCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progress;
  int _stepIndex = 0;

  /// Roughly how long a vision-model analysis takes; the bar fills once and
  /// stops. DELIBERATELY NOT via `motionDuration`: this is feedback, not
  /// decoration, and `Duration.zero` would pin it at 95 % from frame one.
  static const Duration _estimatedDuration = Duration(seconds: 7);

  /// The stage list needs a runtime [AppLocalizations], so this keeps the
  /// fixed length reachable from [_handleTick], which runs outside `build`.
  static const int _stageCount = 4;

  List<(IconData, String)> _stages(AppLocalizations l10n) => [
        (Icons.image_search_rounded, l10n.foodLoadingStageDetect),
        (Icons.straighten_rounded, l10n.foodLoadingStageEstimate),
        (Icons.calculate_rounded, l10n.foodLoadingStageCalculate),
        (Icons.auto_awesome_rounded, l10n.foodLoadingStageFinal),
      ];

  @override
  void initState() {
    super.initState();
    _progress = AnimationController(
      vsync: this,
      duration: _estimatedDuration,
    )
      ..addListener(_handleTick)
      ..forward();
  }

  void _handleTick() {
    if (!mounted) return;
    final raw = (_progress.value * _stageCount).floor();
    final clamped = raw.clamp(0, _stageCount - 1);
    if (clamped != _stepIndex) {
      setState(() => _stepIndex = clamped);
    }
  }

  @override
  void dispose() {
    _progress
      ..removeListener(_handleTick)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final stages = _stages(l10n);
    final stage = stages[_stepIndex];
    final atFinalStage = _stepIndex == stages.length - 1;
    return AppCard(
      key: const ValueKey('analyse-loading'),
      radius: rCard,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconTile(icon: stage.$1, color: t.accent, size: 38),
              const SizedBox(width: 12),
              Expanded(
                child: AnimatedSwitcher(
                  duration:
                      motionDuration(context, const Duration(milliseconds: 220)),
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.25),
                        end: Offset.zero,
                      ).animate(anim),
                      child: child,
                    ),
                  ),
                  child: Column(
                    key: ValueKey(_stepIndex),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        stage.$2,
                        style: AppType.ui(
                          14,
                          weight: FontWeight.w600,
                          color: t.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        atFinalStage
                            ? l10n.foodLoadingAlmostDone
                            : l10n.foodLoadingStepOf(
                                _stepIndex + 1, stages.length),
                        style: AppType.ui(
                          11,
                          weight: FontWeight.w500,
                          color: t.ink2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(rPill),
            child: AnimatedBuilder(
              animation: _progress,
              builder: (context, _) => LinearProgressIndicator(
                // Cap visible progress at 95 % so a long call doesn't look
                // stuck at 100 %; the parent removes the card when it finishes.
                value: (_progress.value * 0.95).clamp(0.0, 0.95),
                minHeight: 3,
                backgroundColor: t.tile,
                color: t.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
