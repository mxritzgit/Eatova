part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Recipe proposal: card in the coach bubble plus the confirmation sheet. Both
// are DISPLAY ONLY — saving happens in `CoachChatController.adoptRecipe`
// after the user confirms; the coach has no write rights of its own.
// ---------------------------------------------------------------------------

/// Proposal card in the chat: eyebrow, photo (or placeholder), title,
/// kcal/protein line and the add button. Once added, the button becomes a
/// quiet "added" state — no double add.
class _RecipeProposalCard extends StatelessWidget {
  const _RecipeProposalCard({
    required this.proposal,
    required this.added,
    required this.enabled,
    required this.onAdd,
    this.onReportImage,
  });

  final CoachRecipeProposal proposal;
  final bool added;
  final bool enabled;
  final VoidCallback? onAdd;

  /// Reports the generated picture (long press on it, or the screen-reader
  /// action); null without a picture or a report path.
  final VoidCallback? onReportImage;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final bytes = proposal.imageBytes;
    return Column(
      key: const ValueKey('coach-recipe-card'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _ProposalEyebrow(
          icon: _CoachCommand.recipe.icon,
          label: l10n.coachRecipeCardEyebrow,
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(rCard),
          child: SizedBox(
            height: 150,
            width: double.infinity,
            // Without a generated photo (failed or still to come): the
            // recipes' glowing bowl, never a wireframe stripe. A proposal has
            // no categories, so the bowl is the motif.
            child: bytes == null
                ? const RecipeArt()
                : _ImageReport(
                    onReport: onReportImage,
                    child: Stack(
                    // expand, not the default loose fit: the image below has
                    // no intrinsic box of its own here, it fills the 150 px
                    // slot. Loosening would collapse it to the decoded size.
                    fit: StackFit.expand,
                    children: <Widget>[
                      LayoutBuilder(
                        builder: (context, constraints) {
                          // Limit decode to card width (same pattern as the
                          // user photo bubble in _MessageView).
                          final dpr = MediaQuery.devicePixelRatioOf(context);
                          final w = constraints.maxWidth.isFinite
                              ? constraints.maxWidth
                              : 320.0;
                          return Image.memory(
                            bytes,
                            fit: BoxFit.cover,
                            cacheWidth: (w * dpr).round().clamp(1, 1600),
                          );
                        },
                      ),
                      const _AiImageBadgeOverlay(),
                    ],
                  ),
                  ),
          ),
        ),
        const SizedBox(height: 12),
        Text(proposal.title, style: _proposalTitleStyle(t)),
        const SizedBox(height: 6),
        Text(
          l10n.recipesKcalProteinSummary(
            proposal.caloriesKcal,
            proposal.proteinG,
          ),
          style: AppType.ui(14, color: t.ink2, height: 1.4),
        ),
        const SizedBox(height: 16),
        if (added)
          // Live region like the plan card's: the button turns into this
          // state after the sheet closes, without focus moving to it.
          Semantics(
            container: true,
            liveRegion: true,
            child: _ProposalDone(label: l10n.coachRecipeAddedLabel),
          )
        else
          PrimaryActionButton(
            key: const ValueKey('coach-recipe-add'),
            label: l10n.coachRecipeAddButton,
            icon: Icons.bookmark_add_outlined,
            onTap: enabled ? onAdd : null,
          ),
      ],
    );
  }
}

/// The generated recipe picture's report path: a long press on it and a
/// screen-reader action, both "Report picture".
class _ImageReport extends StatelessWidget {
  const _ImageReport({required this.onReport, required this.child});

  final VoidCallback? onReport;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final report = onReport;
    if (report == null) return child;
    return Semantics(
      customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
        CustomSemanticsAction(label: context.l10n.coachReportImageAction):
            report,
      },
      child: GestureDetector(
        key: const ValueKey('coach-recipe-image-report'),
        onLongPress: report,
        child: child,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The shared language of the proposal cards (recipe, training plan, workout
// log): one eyebrow, one title size, the default primary button and one
// done state, so three cards in one chat read as one family.
// ---------------------------------------------------------------------------

/// Title of a proposal card.
TextStyle _proposalTitleStyle(AppTokens t) =>
    AppType.display(20, color: t.ink, height: 1.15);

/// A proposal card's eyebrow: the command's glyph and the tracked uppercase
/// label in `accentText`; screen readers hear the label as written. The glyph
/// stays on the first line when large text wraps the label.
class _ProposalEyebrow extends StatelessWidget {
  const _ProposalEyebrow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  static const double _glyph = 16;
  static const double _lineHeight = 1.25;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final style = AppType.sectionEyebrow(
      t.accentText,
    ).copyWith(height: _lineHeight);
    // Glyph and first line share one centre at any text scale.
    final line =
        MediaQuery.textScalerOf(context).scale(style.fontSize!) * _lineHeight;
    final glyphTop = line > _glyph ? (line - _glyph) / 2 : 0.0;
    final textTop = line < _glyph ? (_glyph - line) / 2 : 0.0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.only(top: glyphTop),
          child: ExcludeSemantics(
            child: Icon(icon, size: _glyph, color: t.accentText),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(top: textTop),
            child: Text(
              label.toUpperCase(),
              semanticsLabel: label,
              style: style,
            ),
          ),
        ),
      ],
    );
  }
}

/// The done state of a proposal without a way onward: a check and the label
/// in `accentText` on the card itself. No fill and no capsule, so it reads as
/// a status next to the cards' tappable pills, not as a button.
class _ProposalDone extends StatelessWidget {
  const _ProposalDone({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 40),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.check_circle_rounded, size: 20, color: t.accentText),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              style: AppType.ui(
                14,
                weight: FontWeight.w700,
                color: t.accentText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// AI marker for a coach-generated recipe photo, laid OVER the image.
///
/// The catalog photos in `assets/recipes/` carry a burnt-in "AI Generated"
/// badge; the coach generates its images at runtime and the image prompt asks
/// for no watermark, so nothing in the pixels says where they come from. The
/// app has to say it instead — the imprint on eatova.de declares every recipe
/// image as AI-generated, and an unmarked one would contradict it.
///
/// Positioned rather than stacked into the column on purpose: an overlay
/// cannot resize the image box, so nothing shifts or gets cropped.
class _AiImageBadgeOverlay extends StatelessWidget {
  const _AiImageBadgeOverlay();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Positioned(
      // Bottom right mirrors where the catalog's burnt-in badge sits, so both
      // kinds of recipe image carry their mark in the same corner. Pinned on
      // BOTH sides so the pill wraps inside the photo at textScaler 2.0
      // instead of running off it.
      left: 10,
      right: 10,
      bottom: 10,
      child: Align(
        alignment: Alignment.bottomRight,
        child: Container(
          key: const ValueKey('coach-recipe-ai-badge'),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            // Same filled pill as the catalog card badge (`_RecipeBadge`).
            // Opaque forest/onForest: the contrast is a theme pair, not a bet
            // on how bright the photo underneath happens to be — which is why
            // it survives both display modes over an arbitrary image.
            color: t.forest,
            borderRadius: BorderRadius.circular(rChip),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.image_outlined,
                size: 12,
                color: t.onForest,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  context.l10n.coachRecipeAiImageBadge,
                  style: AppType.ui(
                    11,
                    weight: FontWeight.w700,
                    color: t.onForest,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Confirmation sheet: full preview (image, title, macro line, description,
/// portion/ingredients/preparation). Only the add button pops `true`;
/// dismissing or cancelling does nothing.
class _RecipeAddSheet extends StatelessWidget {
  const _RecipeAddSheet({required this.proposal});

  final CoachRecipeProposal proposal;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    final bytes = proposal.imageBytes;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
        child: ConstrainedBox(
          // Cap so long preparations scroll instead of pushing the sheet past
          // the screen (same pattern as the session/info sheets).
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.78,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // Left-aligned 24 px level-1 title, like every other sheet.
              SheetTitle(l10n.coachRecipeSheetTitle),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  key: const ValueKey('coach-recipe-sheet'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (bytes != null) ...<Widget>[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(rCard),
                          // Loose fit here (unlike the card): the image brings
                          // its own 170 px box, so the stack takes its size
                          // from it and the badge only overlays.
                          child: Stack(
                            children: <Widget>[
                              LayoutBuilder(
                                builder: (context, constraints) {
                                  // Same decode budget as the card above: the
                                  // sheet shows the SAME bytes, and without
                                  // cacheWidth they were decoded a second time
                                  // at full size into a second cache entry.
                                  final dpr =
                                      MediaQuery.devicePixelRatioOf(context);
                                  final w = constraints.maxWidth.isFinite
                                      ? constraints.maxWidth
                                      : 320.0;
                                  return Image.memory(
                                    bytes,
                                    height: 170,
                                    width: double.infinity,
                                    fit: BoxFit.cover,
                                    cacheWidth:
                                        (w * dpr).round().clamp(1, 1600),
                                  );
                                },
                              ),
                              const _AiImageBadgeOverlay(),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      Text(
                        proposal.title,
                        style: AppType.display(22, color: t.ink, height: 1.15),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l10n.recipesKcalProteinSummary(
                          proposal.caloriesKcal,
                          proposal.proteinG,
                        ),
                        style: AppType.ui(13, color: t.ink2),
                      ),
                      if (proposal.description.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 8),
                        Text(
                          proposal.description,
                          style: AppType.ui(14, color: t.ink, height: 1.5),
                        ),
                      ],
                      // The recipe's own section cards (as in the import
                      // preview and the detail view). The model's "- " and
                      // "1." markers give way to the dots and step badges.
                      // Empty sections are dropped entirely, unlike the
                      // detail view which always shows every section.
                      if (proposal.portion.trim().isNotEmpty) ...<Widget>[
                        const SizedBox(height: 12),
                        RecipeSectionCard(
                          icon: Icons.restaurant_rounded,
                          title: l10n.recipesSectionPortion,
                          child: RecipeParagraph(
                            text: proposal.portion,
                            empty: l10n.recipesNoDataProvided,
                          ),
                        ),
                      ],
                      if (proposal.ingredients.trim().isNotEmpty) ...<Widget>[
                        const SizedBox(height: 12),
                        RecipeSectionCard(
                          icon: Icons.shopping_basket_outlined,
                          title: l10n.recipesSectionIngredients,
                          child: RecipeIngredientLines(
                            text: proposal.ingredients,
                          ),
                        ),
                      ],
                      if (proposal.preparation.trim().isNotEmpty) ...<Widget>[
                        const SizedBox(height: 12),
                        RecipeSectionCard(
                          icon: Icons.soup_kitchen_outlined,
                          title: l10n.recipesSectionPreparation,
                          child: RecipePreparationSteps(
                            text: proposal.preparation,
                            empty: l10n.recipesNoDataProvided,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              PrimaryActionButton(
                key: const ValueKey('coach-recipe-sheet-confirm'),
                label: l10n.coachRecipeSheetConfirm,
                icon: Icons.bookmark_add_outlined,
                onTap: () => Navigator.of(context).pop(true),
              ),
              const SizedBox(height: 10),
              SoftPillButton(
                label: l10n.commonCancel,
                onTap: () => Navigator.of(context).pop(false),
                tone: SoftPillTone.neutral,
                expand: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Below this many open kcal a budget would only squeeze the recipe; the
/// target line then names the slot alone.
const int _minTargetKcal = 200;

/// Open protein worth aiming a recipe at.
const int _minTargetProteinG = 10;

/// The /recipe target line for today's [brief] (2026-10-22): the meal slot
/// the recipe is for and, while the day still has room, the calories and
/// protein still open. It travels inside the wish and shows in the chat
/// history, so it is localized like any visible text.
String coachRecipeTargetLine(CoachDayBrief brief, AppLocalizations l10n) {
  final slot = brief.mealSlot.label(l10n);
  final kcal = brief.remainingKcal;
  if (kcal < _minTargetKcal) return l10n.coachRecipeTargetSlot(slot);
  final protein = brief.proteinLeftG;
  return protein >= _minTargetProteinG
      ? l10n.coachRecipeTargetBudgetProtein(slot, kcal, protein)
      : l10n.coachRecipeTargetBudget(slot, kcal);
}

/// Every slash command, in menu and chip order: the one list the command
/// menu, its visibility check and the hero chips read. The tokens are English
/// in both app languages.
enum _CoachCommand {
  recipe('/recipe', Icons.restaurant_rounded),
  plan('/plan', Icons.fitness_center_rounded),
  log('/log', Icons.playlist_add_check_rounded),

  /// Opens the describe sheet instead of asking the coach (2026-10-22).
  meal('/meal', Icons.edit_note_rounded);

  const _CoachCommand(this.token, this.icon);

  final String token;
  final IconData icon;

  String description(AppLocalizations l10n) => switch (this) {
    _CoachCommand.recipe => l10n.coachCommandRecipeDescription,
    _CoachCommand.plan => l10n.coachPlanCommandDescription,
    _CoachCommand.log => l10n.coachWorkoutLogCommandDescription,
    _CoachCommand.meal => l10n.coachMealCommandDescription,
  };

  /// What the command costs of today's questions, said in the menu.
  String cost(AppLocalizations l10n) => this == _CoachCommand.meal
      ? l10n.coachCommandCostNone
      : l10n.coachCommandCostOne;

  /// The start state's "Try asking" chip.
  String tryLabel(AppLocalizations l10n) => switch (this) {
    _CoachCommand.recipe => l10n.coachTryRecipe,
    _CoachCommand.plan => l10n.coachTryPlan,
    _CoachCommand.log => l10n.coachWorkoutLogTry,
    _CoachCommand.meal => l10n.coachMealTry,
  };

  /// Whether the menu offers this command for a started [draft] ("/l").
  bool offeredFor(String draft) =>
      token.startsWith(draft.trimLeft().toLowerCase());
}

/// Command menu above the composer: appears once the draft looks like a
/// started command ("/", "/r", …) and completes the matching command on tap.
class _CommandSuggestions extends StatelessWidget {
  const _CommandSuggestions({required this.draft, required this.onPick});

  final String draft;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 240;
        return Container(
          key: const ValueKey('coach-command-menu'),
          margin: const EdgeInsets.only(top: 8),
          decoration: BoxDecoration(
            color: t.surf,
            borderRadius: BorderRadius.circular(rCard),
            border: Border.all(color: t.line),
            boxShadow: softShadow(t),
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            color: Colors.transparent,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (final command in _CoachCommand.values)
                    if (command.offeredFor(draft))
                      _CommandSuggestion(
                        command: command.token,
                        compact: compact,
                        description:
                            '${command.description(l10n)} · '
                            '${command.cost(l10n)}',
                        icon: command.icon,
                        onPick: onPick,
                      ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CommandSuggestion extends StatelessWidget {
  const _CommandSuggestion({
    required this.command,
    required this.description,
    required this.icon,
    required this.onPick,
    required this.compact,
  });

  final String command;
  final String description;
  final IconData icon;
  final ValueChanged<String> onPick;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      button: true,
      child: InkWell(
        key: ValueKey('coach-command-${command.substring(1)}'),
        onTap: () => onPick(command),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 15,
              vertical: compact ? 8 : 12,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(icon, size: 20, color: t.accentText),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        command,
                        semanticsLabel: compact
                            ? '$command, $description'
                            : null,
                        style: AppType.ui(
                          13.5,
                          weight: FontWeight.w700,
                          color: t.accentText,
                        ),
                      ),
                      if (!compact) ...<Widget>[
                        const SizedBox(height: 3),
                        Text(
                          description,
                          style: AppType.ui(12, color: t.ink2, height: 1.35),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
