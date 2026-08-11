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
                : Image.memory(
                    imageBytes!,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
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

  /// Roughly how long a vision-model analysis takes in practice. The progress
  /// bar fills linearly over this duration once and then stops — if the
  /// network call is still pending after that we just stay on the last stage
  /// (no looping back to 1/4).
  ///
  /// BEWUSST NICHT ueber `motionDuration`: das hier ist die Rueckmeldung
  /// waehrend der Analyse, keine Deko. Auf `Duration.zero` gesetzt saesse der
  /// Balken ab dem ersten Frame bei 95 % und die Stufe stuende dauerhaft auf
  /// „Letzter Feinschliff...", waehrend das Netz noch laeuft — der Nutzer
  /// haette dann GAR keine Rueckmeldung mehr. Nur die Text-Ueberblendung der
  /// Stufen (AnimatedSwitcher unten) ist Deko und kollabiert.
  static const Duration _estimatedDuration = Duration(seconds: 7);

  /// Seit der i18n-Migration (Paket 2, 2026-08-10) keine `static const`
  /// Liste mehr — die ARB-Texte brauchen ein [AppLocalizations], das erst zur
  /// Laufzeit vorliegt. `_stageCount` haelt die feste Laenge weiterhin ohne
  /// `context`-Zugriff verfuegbar (fuer [_handleTick], das ausserhalb von
  /// `build` laeuft).
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
                // Cap the visible progress at 95 % so a long-running call
                // doesn't sit at "100 %" and feel stuck. Once it actually
                // finishes the parent removes the card.
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
