part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Hero (AI Coach v2): animierter Orb + Zeit-Begruessung mit echtem Vornamen.
// ---------------------------------------------------------------------------
class _CoachHero extends StatelessWidget {
  const _CoachHero({required this.name, required this.onDisclosureTap});
  final String name;

  /// Oeffnet das (i)-Sheet mit den Details (welche Daten, wohin).
  final VoidCallback onDisclosureTap;

  String get _timeGreeting {
    final h = DateTime.now().hour;
    if (h < 5) return 'Gute Nacht';
    if (h < 11) return 'Guten Morgen';
    if (h < 17) return 'Hallo';
    return 'Guten Abend';
  }

  String get _firstName {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Champion';
    return trimmed.split(RegExp(r'\s+')).first;
  }

  @override
  Widget build(BuildContext context) {
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
          children: [
            const CoachOrb(size: 92),
            const SizedBox(height: 22),
            Text(
              '$_timeGreeting, $_firstName',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
                color: textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Wie kann ich dir helfen?',
              style: TextStyle(fontSize: 15, color: textMuted),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Material(
        key: const ValueKey('coach-ai-note'),
        color: surfaceSoft.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(rCard),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(rCard),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 1),
                      child: Icon(
                        Icons.auto_awesome_rounded,
                        size: 13,
                        color: coachAccent,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Hier antwortet eine KI. Die Tipps sind eine '
                        'KI-Schätzung, kein ärztlicher Rat.',
                        textAlign: TextAlign.start,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: textPrimary.withValues(alpha: 0.85),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Welche Daten mitgehen',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: coachAccent,
                      ),
                    ),
                    SizedBox(width: 3),
                    Icon(Icons.chevron_right_rounded,
                        size: 15, color: coachAccent),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Vorschlags-Zeilen (nur im Hero-State, ueber dem Composer): volle Breite mit
// Pfeil. Legen den Text ins Feld statt direkt zu senden — die Quota ist knapp,
// der User behaelt die Kontrolle vor dem Abschicken.
// ---------------------------------------------------------------------------
class _SuggestionList extends StatelessWidget {
  const _SuggestionList({required this.onSuggestion});

  final ValueChanged<String> onSuggestion;

  static const List<String> _suggestions = [
    'Was soll ich heute noch essen?',
    'Wie komme ich auf meine restlichen Proteine?',
    'Wann sollte ich heute schlafen gehen?',
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Column(
        children: [
          for (var i = 0; i < _suggestions.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: surfaceSoft.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(rCard),
                child: InkWell(
                  key: ValueKey('coach-suggestion-$i'),
                  onTap: () => onSuggestion(_suggestions[i]),
                  borderRadius: BorderRadius.circular(rCard),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 15, vertical: 13),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _suggestions[i],
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: textPrimary,
                              letterSpacing: -0.1,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.arrow_forward_rounded,
                          size: 14,
                          color: textPrimary.withValues(alpha: 0.4),
                        ),
                      ],
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
