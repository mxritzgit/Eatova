part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Hero: animierter Orb + Zeit-Begruessung mit echtem Vornamen.
// ---------------------------------------------------------------------------
class _CoachHero extends StatelessWidget {
  const _CoachHero({
    required this.name,
    required this.onDisclosureTap,
  });
  final String name;

  /// Oeffnet das (i)-Sheet mit den Details (welche Daten, wohin).
  final VoidCallback onDisclosureTap;

  /// Byte-gleich zu `greetingForHour` (today_texts.dart) — beide lasen bis
  /// zur Coach-Migration (Paket 4) unabhaengige Texte (die Kopie schon aus
  /// der ARB, das Original hier hartkodiert deutsch). Jetzt ruft das
  /// Original die Kopie: `today_texts.dart` ist Flutter-frei und oeffentlich,
  /// eine zweite ARB-Anbindung derselben vier Werte waere dieselbe Aussage
  /// ein zweites Mal. Der Drift-Test bleibt in `today_texts_test.dart`.
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
      // Scrollbar statt starr: der Leerzustand traegt seit C8 eine Zeile mehr,
      // und auf kurzen Geraeten (bzw. bei grosser Systemschrift) wuerde die
      // Column sonst ueberlaufen und den Orb abschneiden. Passt der Inhalt,
      // bleibt er wie bisher mittig.
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

/// C8 — die Offenlegung im Leerzustand: hier antwortet eine KI, und ein Tap
/// fuehrt zum Detail (welche Daten mitgehen, wohin) im (i)-Sheet. Bewusst hier
/// und nicht nur hinter dem (i): der Nutzer soll es lesen koennen, BEVOR er
/// tippt. Ton wie beim Meal-Scanner ("KI-Schaetzung") statt Juristendeutsch.
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
