part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Hero: animierter Orb + Zeit-Begruessung mit echtem Vornamen.
// ---------------------------------------------------------------------------
class _CoachHero extends StatelessWidget {
  const _CoachHero({
    required this.name,
    required this.onDisclosureTap,
    required this.onSuggestion,
  });
  final String name;

  /// Oeffnet das (i)-Sheet mit den Details (welche Daten, wohin).
  final VoidCallback onDisclosureTap;

  /// Legt einen Vorschlag ins Eingabefeld (sendet nicht).
  final ValueChanged<String> onSuggestion;

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
    final t = context.t;
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
              '$_timeGreeting, $_firstName',
              textAlign: TextAlign.center,
              style: AppType.display(26, color: t.ink, height: 1.15),
            ),
            const SizedBox(height: 6),
            Text(
              'Wie kann ich dir helfen?',
              textAlign: TextAlign.center,
              style: AppType.ui(15, color: t.ink2),
            ),
            const SizedBox(height: 18),
            _CoachAiNote(onTap: onDisclosureTap),
            _SuggestionList(onSuggestion: onSuggestion),
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
                      'Hier antwortet eine KI. Die Tipps sind eine '
                      'KI-Schätzung, kein ärztlicher Rat.',
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
                      'Welche Daten mitgehen',
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

// ---------------------------------------------------------------------------
// Vorschlags-Zeilen: Lime-Punkt, Text, Chevron. Legen den Text ins Feld statt
// direkt zu senden — die Quota ist knapp, der User behaelt die Kontrolle vor
// dem Abschicken.
//
// Sie haengen am Hero und damit an `isHero`, stehen aber INNERHALB seines
// SingleChildScrollView. Zwei Gruende: als Geschwister der Nachrichtenliste
// (so lagen sie bisher) sprengten drei zweizeilige Zeilen bei textScaler 2.0
// die Screen-Column um 225 px — dort kann nichts scrollen. Und in der
// Nachrichtenliste selbst (so macht es die Vorlage) erschienen sie auch bei
// _historyUnavailable, also „Frag doch mal…" ueber einem Banner, das sagt,
// der Verlauf sei nicht ladbar.
// ---------------------------------------------------------------------------
class _SuggestionList extends StatelessWidget {
  const _SuggestionList({required this.onSuggestion});

  final ValueChanged<String> onSuggestion;

  static const List<String> _suggestions = <String>[
    'Was soll ich heute noch essen?',
    'Wie komme ich auf meine restlichen Proteine?',
    'Wann sollte ich heute schlafen gehen?',
  ];

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      // Horizontal 0: der Seitenrand kommt aus der Schale.
      padding: const EdgeInsets.fromLTRB(0, 18, 0, 0),
      child: Column(
        // min + stretch ist Pflicht: die Liste steht in einem
        // SingleChildScrollView (unbegrenzte Hoehe), und die Zeilen sollen
        // die volle Breite nehmen.
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (var i = 0; i < _suggestions.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: t.surf,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  key: ValueKey<String>('coach-suggestion-$i'),
                  onTap: () => onSuggestion(_suggestions[i]),
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: t.line),
                    ),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 15, vertical: 13),
                    child: Row(
                      children: <Widget>[
                        Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            color: t.lime,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _suggestions[i],
                            style: AppType.ui(
                              13,
                              weight: FontWeight.w500,
                              color: t.ink,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.chevron_right_rounded,
                          size: 16,
                          color: t.ink2,
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
