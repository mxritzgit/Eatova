part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Hero: animated orb plus time-of-day greeting with the real first name.
// ---------------------------------------------------------------------------
class _CoachHero extends StatelessWidget {
  const _CoachHero({
    required this.name,
    required this.onDisclosureTap,
  });
  final String name;

  /// Opens the (i) sheet detailing which data goes where.
  final VoidCallback onDisclosureTap;

  /// Delegates to `greetingForHour` (today_texts.dart) so the two cannot
  /// drift; that file is Flutter-free and owns the ARB lookup.
  /// Drift test lives in `today_texts_test.dart`.
  String _timeGreeting(AppLocalizations l10n) =>
      greetingForHour(DateTime.now().hour, l10n);

  String _firstName(AppLocalizations l10n) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return l10n.coachFallbackName;
    return trimmed.split(RegExp(r'\s+')).first;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    return Center(
      key: const ValueKey('coach-empty'),
      // Scrollable, not rigid: on short screens or large system fonts the
      // column would overflow and clip the orb. It stays centred if it fits.
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CoachOrb(size: 92),
            const SizedBox(height: 22),
            Text(
              '${_timeGreeting(l10n)}, ${_firstName(l10n)}',
              textAlign: TextAlign.center,
              style: AppType.display(26, color: t.ink, height: 1.15),
            ),
            const SizedBox(height: 6),
            Text(
              l10n.coachHeroSubtitle,
              textAlign: TextAlign.center,
              style: AppType.ui(15, color: t.ink2),
            ),
            const SizedBox(height: 18),
            _CoachAiNote(onTap: onDisclosureTap),
          ],
        ),
      ),
    );
  }
}

/// AI disclosure in the empty state (C8); tapping opens the (i) sheet.
/// Shown up front, not only behind the (i), so the user reads it before
/// typing.
class _CoachAiNote extends StatelessWidget {
  const _CoachAiNote({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      key: const ValueKey('coach-ai-note'),
      color: t.surf,
      borderRadius: BorderRadius.circular(rCard),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(rCard),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(rCard),
            border: Border.all(color: t.line),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      Icons.auto_awesome_rounded,
                      size: 13,
                      color: t.accent,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      context.l10n.coachAiNoteBody,
                      style: AppType.ui(12.5, color: t.ink, height: 1.4),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Flexible(
                    child: Text(
                      context.l10n.coachAiNoteCta,
                      style: AppType.ui(
                        12,
                        weight: FontWeight.w600,
                        color: t.accent,
                      ),
                    ),
                  ),
                  const SizedBox(width: 3),
                  Icon(Icons.chevron_right_rounded, size: 15, color: t.accent),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
