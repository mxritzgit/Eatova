part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Hero (AI Coach v2): animierter Orb + Zeit-Begruessung mit echtem Vornamen.
// ---------------------------------------------------------------------------
class _CoachHero extends StatelessWidget {
  const _CoachHero({required this.name});
  final String name;

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
        ],
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
