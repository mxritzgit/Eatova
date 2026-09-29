part of 'coach_chat_screen.dart';

/// The coach tab's side inset. The shell hands the tab its full width
/// (eatova_home_page.dart), like Food and Training, so the chip row can run
/// to the screen edges and still take taps there; the rest sits inside this.
const double _kShellInset = 20;

// ---------------------------------------------------------------------------
// Start state (dark redesign): orb and greeting, the "From today's log" card,
// "Try asking" chips and the AI disclaimer. Everything here only prepares or
// sends a question through the screen's normal send path.
// ---------------------------------------------------------------------------
class _CoachHero extends StatelessWidget {
  const _CoachHero({
    required this.name,
    required this.dayBrief,
    required this.canAsk,
    required this.onAsk,
    required this.onCommand,
    required this.onDisclosureTap,
  });

  final String name;

  /// Today's numbers for the card; null hides it (no store, e.g. previews).
  final CoachDayBrief? dayBrief;

  /// Whether a prepared question can go out now (session loaded, quota left,
  /// nothing in flight). Pills and chips are disabled otherwise.
  final bool canAsk;

  /// Sends a prepared question as the user's message.
  final ValueChanged<String> onAsk;

  /// Starts a slash command (`/recipe`, `/plan`) the way the command menu does.
  final ValueChanged<String> onCommand;

  /// Opens the (i) sheet detailing which data goes where.
  final VoidCallback onDisclosureTap;

  /// Delegates to `greetingForHour` (today_texts.dart) so the two cannot
  /// drift; that file is Flutter-free and owns the ARB lookup.
  /// Drift test lives in `today_texts_test.dart`.
  String _timeGreeting(AppLocalizations l10n) =>
      greetingForHour(clock.now().hour, l10n);

  String _firstName(AppLocalizations l10n) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return l10n.coachFallbackName;
    return trimmed.split(RegExp(r'\s+')).first;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final brief = dayBrief;
    // Top-aligned like the design; the switcher around it would centre
    // a start state that is shorter than the screen.
    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        key: const ValueKey('coach-empty'),
        // Top 14: the design's gap under the header. Bottom: room above the
        // content area's fade.
        padding: const EdgeInsets.only(top: 14, bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                _kShellInset,
                14,
                _kShellInset,
                6,
              ),
              child: Column(
                children: <Widget>[
                  const CoachOrb(),
                  const SizedBox(height: 16),
                  // Rank 2, not 1 (P9-06c): _CoachTopBar above already names
                  // the screen; this greets the empty state, a section inside
                  // the coach.
                  HeadingSemantics(
                    level: 2,
                    child: Text(
                      l10n.coachHeroGreeting(
                        _timeGreeting(l10n),
                        _firstName(l10n),
                      ),
                      textAlign: TextAlign.center,
                      style: AppType.display(28, color: t.ink, height: 1.2),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    brief == null
                        ? l10n.coachHeroSubtitle
                        : l10n.coachHeroDayStands,
                    textAlign: TextAlign.center,
                    style: AppType.ui(15, color: t.ink2, height: 1.2),
                  ),
                ],
              ),
            ),
            if (brief != null) ...<Widget>[
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: _kShellInset),
                child: _DayLogCard(brief: brief, enabled: canAsk, onAsk: onAsk),
              ),
            ],
            const SizedBox(height: 14),
            _TryAsking(enabled: canAsk, onCommand: onCommand),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: _kShellInset),
              child: _CoachDisclaimer(onTap: onDisclosureTap),
            ),
          ],
        ),
      ),
    );
  }
}

/// "From today's log": today's kcal and protein left, read on the client from
/// the same numbers as the Today tab, with two prepared questions.
class _DayLogCard extends StatelessWidget {
  const _DayLogCard({
    required this.brief,
    required this.enabled,
    required this.onAsk,
  });

  final CoachDayBrief brief;
  final bool enabled;
  final ValueChanged<String> onAsk;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final eyebrow = l10n.coachLogEyebrow;
    final secondary = brief.secondaryAction;
    return Container(
      key: const ValueKey('coach-log-card'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.surf,
        borderRadius: BorderRadius.circular(rCard),
        // The design's accent outline at 16 %.
        border: Border.all(color: t.accentTintStrong),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              SizedBox.square(
                dimension: 15,
                child: CustomPaint(painter: _SparklePainter(t.accentText)),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  eyebrow.toUpperCase(),
                  semanticsLabel: eyebrow,
                  style: AppType.sectionEyebrow(t.accentText).copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: 12 * 0.08,
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text.rich(
            key: const ValueKey('coach-log-summary'),
            _summary(context),
            style: AppType.ui(16, color: t.inkSoft, height: 1.45),
          ),
          const SizedBox(height: 12),
          // Wrap: two pills do not fit side by side in German or at large
          // text sizes; the second one moves to its own line.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _CardPill(
                key: const ValueKey('coach-log-primary'),
                label: _label(brief.primaryAction, l10n),
                primary: true,
                onTap: enabled
                    ? () => onAsk(_prompt(brief.primaryAction, l10n))
                    : null,
              ),
              if (secondary != null)
                _CardPill(
                  key: const ValueKey('coach-log-secondary'),
                  label: _label(secondary, l10n),
                  primary: false,
                  onTap: enabled ? () => onAsk(_prompt(secondary, l10n)) : null,
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _label(CoachDayAction action, AppLocalizations l10n) =>
      switch (action) {
        CoachDayAction.suggestMeal => l10n.coachLogSuggestMeal(
          brief.mealSlot.name,
        ),
        CoachDayAction.planDay => l10n.coachLogPlanDay,
        CoachDayAction.planTomorrow => l10n.coachLogPlanTomorrow,
      };

  String _prompt(CoachDayAction action, AppLocalizations l10n) =>
      switch (action) {
        CoachDayAction.suggestMeal => l10n.coachLogPromptSuggestMeal(
          brief.mealSlot.name,
        ),
        CoachDayAction.planDay => l10n.coachLogPromptPlanDay,
        CoachDayAction.planTomorrow => l10n.coachLogPromptPlanTomorrow,
      };

  /// The summary sentence(s), with the amounts set bold like the design.
  TextSpan _summary(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final locale = l10n.localeName;
    final kcal = l10n.coachLogKcal(
      formatThousands(
        brief.state == CoachDayState.nothingLogged
            ? brief.budgetKcal
            : brief.state == CoachDayState.overBudget
            ? brief.overKcal
            : brief.remainingKcal,
        locale,
      ),
    );
    final protein = l10n.coachLogProtein(
      formatThousands(
        brief.state == CoachDayState.nothingLogged
            ? brief.proteinGoalG
            : brief.proteinLeftG,
        locale,
      ),
    );
    final sentences = <String>[
      switch (brief.state) {
        CoachDayState.nothingLogged => l10n.coachLogNothingLogged(
          kcal,
          protein,
        ),
        CoachDayState.underBudget =>
          brief.proteinLeftG > 0
              ? l10n.coachLogLeft(kcal, protein)
              : l10n.coachLogLeftProteinMet(kcal),
        CoachDayState.atBudget => l10n.coachLogAtBudget,
        CoachDayState.overBudget => l10n.coachLogOver(kcal),
      },
      if (brief.proteinGapClosable)
        l10n.coachLogProteinHint(brief.mealSlot.name),
      if ((brief.state == CoachDayState.atBudget ||
              brief.state == CoachDayState.overBudget) &&
          brief.proteinLeftG > 0)
        l10n.coachLogProteinOpen(protein),
    ];
    return _emphasized(sentences.join(' '), <String>[
      kcal,
      protein,
    ], AppType.ui(16, weight: FontWeight.w700, color: t.ink, height: 1.45));
  }
}

/// Splits [text] into spans and sets every occurrence of [strong] in
/// [strongStyle]; the rest inherits the paragraph style.
TextSpan _emphasized(String text, List<String> strong, TextStyle strongStyle) {
  final parts = <InlineSpan>[];
  var rest = text;
  while (rest.isNotEmpty) {
    var at = -1;
    var match = '';
    for (final candidate in strong) {
      final i = rest.indexOf(candidate);
      if (i >= 0 && (at < 0 || i < at)) {
        at = i;
        match = candidate;
      }
    }
    if (at < 0) {
      parts.add(TextSpan(text: rest));
      break;
    }
    if (at > 0) parts.add(TextSpan(text: rest.substring(0, at)));
    parts.add(TextSpan(text: match, style: strongStyle));
    rest = rest.substring(at + match.length);
  }
  return TextSpan(children: parts);
}

/// The card's pill: accent fill for the main question, a tonal pill for the
/// other one. 44 px tall like the design; disabled pills fade out.
class _CardPill extends StatelessWidget {
  const _CardPill({
    super.key,
    required this.label,
    required this.primary,
    required this.onTap,
  });

  final String label;
  final bool primary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(rPill),
    );
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: Material(
          color: primary ? t.accentFill : t.surf2,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            customBorder: shape,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              // Shrink-wrapped, but centred in the 44 px minimum.
              child: Align(
                widthFactor: 1,
                heightFactor: 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: AppType.ui(
                      14,
                      weight: primary ? FontWeight.w800 : FontWeight.w700,
                      color: primary ? t.onAccentFill : t.ink,
                      height: 1.2,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Try asking": the coach's two commands as chips, so they are discoverable
/// without typing "/". `/recipe` prepares the composer, `/plan` opens the
/// training brief — exactly what the command menu does.
class _TryAsking extends StatelessWidget {
  const _TryAsking({required this.enabled, required this.onCommand});

  final bool enabled;
  final ValueChanged<String> onCommand;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: _kShellInset + 4),
          child: HeadingSemantics(
            level: 2,
            child: Text(
              l10n.coachTryTitle,
              style: AppType.ui(
                13,
                weight: FontWeight.w700,
                color: t.ink3,
                height: 1.2,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        // The row owns the full screen width like the design: every visible
        // part of a chip takes taps and the row drags from edge to edge; its
        // padding keeps the first chip on the content line.
        SingleChildScrollView(
          key: const ValueKey('coach-try-row'),
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: _kShellInset),
          child: Row(
            children: <Widget>[
              _TryChip(
                key: const ValueKey('coach-try-recipe'),
                label: l10n.coachTryRecipe,
                onTap: enabled ? () => onCommand('/recipe') : null,
              ),
              const SizedBox(width: 8),
              _TryChip(
                key: const ValueKey('coach-try-plan'),
                label: l10n.coachTryPlan,
                onTap: enabled ? () => onCommand('/plan') : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TryChip extends StatelessWidget {
  const _TryChip({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final shape = StadiumBorder(side: BorderSide(color: t.lineStrong));
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: Material(
          color: t.surf,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            customBorder: shape,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      label,
                      style: AppType.ui(
                        13,
                        weight: FontWeight.w600,
                        color: t.inkSoft,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.north_east_rounded, size: 14, color: t.ink3),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// AI disclosure in the start state (C8): shown up front so the user reads it
/// before typing. The whole line opens the (i) sheet, so the target is 44 px
/// tall even though the design only colors "What's shared"; the extra height
/// hangs below the text, which keeps the design's position.
class _CoachDisclaimer extends StatelessWidget {
  const _CoachDisclaimer({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Semantics(
      link: true,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(rChip),
        child: InkWell(
          key: const ValueKey('coach-ai-note'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(rChip),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text.rich(
                  TextSpan(
                    children: <InlineSpan>[
                      TextSpan(text: '${l10n.coachDisclaimer} '),
                      TextSpan(
                        text: l10n.coachDisclaimerLink,
                        style: AppType.ui(
                          12,
                          weight: FontWeight.w700,
                          color: t.accentText,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                  style: AppType.ui(12, color: t.ink3, height: 1.5),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The design's single four-point sparkle (the eyebrow of the day card), on
/// a 24-unit grid with a 2-unit stroke.
class _SparklePainter extends CustomPainter {
  const _SparklePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 24;
    final path = Path()
      ..moveTo(11 * unit, 4.5 * unit)
      ..lineTo(12.6 * unit, 8.9 * unit)
      ..lineTo(17 * unit, 10.5 * unit)
      ..lineTo(12.6 * unit, 12.1 * unit)
      ..lineTo(11 * unit, 16.5 * unit)
      ..lineTo(9.4 * unit, 12.1 * unit)
      ..lineTo(5 * unit, 10.5 * unit)
      ..lineTo(9.4 * unit, 8.9 * unit)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * unit
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparklePainter old) => old.color != color;
}
