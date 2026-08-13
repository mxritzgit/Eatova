part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// /rezept-Vorschlag (Spec 2026-08-12): Karte in der Coach-Blase plus das
// Bestaetigungs-Sheet. Beides ist REINE Anzeige — gespeichert wird erst in
// `_CoachChatScreenState._addProposalToRecipes`, nachdem der Nutzer im Sheet
// bestaetigt hat (der Coach hat keinerlei eigene Rechte).
// ---------------------------------------------------------------------------

/// Vorschlagskarte im Chat: Eyebrow, Foto (oder Platzhalter), Titel,
/// kcal/Protein-Zeile und der Hinzufuegen-Knopf. Nach dem Uebernehmen wird
/// der Knopf zum stillen „Hinzugefuegt"-Zustand — kein Doppel-Add.
class _RecipeProposalCard extends StatelessWidget {
  const _RecipeProposalCard({
    required this.proposal,
    required this.added,
    required this.enabled,
    required this.onAdd,
  });

  final CoachRecipeProposal proposal;
  final bool added;
  final bool enabled;
  final VoidCallback? onAdd;

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
        Text(l10n.coachRecipeCardEyebrow, style: AppType.eyebrow(t.accent)),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(rCard),
          child: SizedBox(
            height: 150,
            width: double.infinity,
            child: bytes == null
                ? ImagePlaceholder(
                    radius: 0,
                    label: l10n.recipesImagePlaceholderLabel,
                  )
                : LayoutBuilder(
                    builder: (context, constraints) {
                      // Decode auf Kartenbreite begrenzen (Muster der
                      // User-Foto-Blase weiter oben in _MessageView).
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
          ),
        ),
        const SizedBox(height: 10),
        Text(
          proposal.title,
          style: AppType.display(18, color: t.ink, height: 1.15),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.recipesKcalProteinSummary(
            proposal.caloriesKcal,
            proposal.proteinG,
          ),
          style: AppType.ui(12.5, color: t.ink2),
        ),
        const SizedBox(height: 12),
        if (added)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.check_rounded, size: 16, color: t.accent),
              const SizedBox(width: 6),
              Text(
                l10n.coachRecipeAddedLabel,
                style: AppType.ui(13, weight: FontWeight.w600, color: t.accent),
              ),
            ],
          )
        else
          PrimaryActionButton(
            key: const ValueKey('coach-recipe-add'),
            label: l10n.coachRecipeAddButton,
            icon: Icons.bookmark_add_outlined,
            height: 46,
            onTap: enabled ? onAdd : null,
          ),
      ],
    );
  }
}

/// Bestaetigungs-Sheet („Rezept hinzufügen"): volle Vorschau — Bild, Titel,
/// Makro-Zeile, Beschreibung, Portion/Zutaten/Zubereitung — und erst der
/// Hinzufuegen-Knopf poppt mit `true`. Wegwischen/Abbrechen = nichts.
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
          // Deckel, damit lange Zubereitungen scrollen statt das Sheet ueber
          // den Screen zu druecken (Muster der Session-/Info-Sheets).
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.78,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                l10n.coachRecipeSheetTitle,
                textAlign: TextAlign.center,
                style: AppType.display(20, color: t.ink),
              ),
              const SizedBox(height: 14),
              Flexible(
                child: SingleChildScrollView(
                  key: const ValueKey('coach-recipe-sheet'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (bytes != null) ...<Widget>[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(rCard),
                          child: Image.memory(
                            bytes,
                            height: 170,
                            width: double.infinity,
                            fit: BoxFit.cover,
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
                          style: AppType.ui(13, color: t.ink, height: 1.5),
                        ),
                      ],
                      _SheetSection(
                        title: l10n.recipesSectionPortion,
                        body: proposal.portion,
                      ),
                      _SheetSection(
                        title: l10n.recipesSectionIngredients,
                        body: proposal.ingredients,
                      ),
                      _SheetSection(
                        title: l10n.recipesSectionPreparation,
                        body: proposal.preparation,
                      ),
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
              const SizedBox(height: 6),
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(l10n.commonCancel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Befehls-Menue ueber dem Composer (Nachtrag 2026-08-13): erscheint,
/// sobald der Entwurf wie ein angefangener Befehl aussieht ("/", "/r", …),
/// und vervollstaendigt per Tap. Aktuell EIN Befehl (/recipe) — die Liste
/// waechst mit, sollte je ein zweiter dazukommen.
class _CommandSuggestions extends StatelessWidget {
  const _CommandSuggestions({required this.onPick});

  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
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
        child: InkWell(
          key: const ValueKey('coach-command-recipe'),
          // Der Befehl selbst ist bewusst NICHT lokalisiert — nur seine
          // Beschreibung folgt der App-Sprache.
          onTap: () => onPick('/recipe'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '/recipe',
                  style: AppType.ui(
                    13.5,
                    weight: FontWeight.w700,
                    color: t.accent,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  l10n.coachCommandRecipeDescription,
                  style: AppType.ui(12, color: t.ink2, height: 1.35),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Sektion der Sheet-Vorschau; leere Inhalte fallen komplett weg (kein
/// Platzhalter-Rauschen — anders als die Detail-Ansicht, die fuer
/// Bestandsrezepte immer alle Sektionen traegt).
class _SheetSection extends StatelessWidget {
  const _SheetSection({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    if (body.trim().isEmpty) return const SizedBox.shrink();
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: AppType.eyebrow(t.ink2)),
          const SizedBox(height: 5),
          Text(body, style: AppType.ui(13, color: t.ink, height: 1.55)),
        ],
      ),
    );
  }
}
