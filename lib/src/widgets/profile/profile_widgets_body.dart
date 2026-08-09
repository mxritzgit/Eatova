part of 'profile_widgets.dart';

/// Die Gewichts-Karte: grosse aktuelle Zahl, Delta-Pille, Verlaufslinie ueber
/// die echte Historie, darunter der Fortschritt Richtung Wunschgewicht — und
/// als Abschluss die Aktion „Gewicht loggen".
class WeightCard extends StatelessWidget {
  const WeightCard({
    super.key,
    required this.profile,
    required this.log,
    required this.onLogWeight,
  });

  final UserProfile profile;
  final WeightLog log;
  final ValueChanged<double> onLogWeight;

  double get _current => log.latest?.weightKg ?? profile.weightKg.toDouble();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final entries = log.entries;
    final hatVerlauf = entries.length >= 2;
    final delta = log.trendDelta;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Gewicht',
                      style: AppType.display(
                        17,
                        weight: FontWeight.w700,
                        color: t.ink,
                      ),
                    ),
                  ),
                  Flexible(
                    child: Text(
                      hatVerlauf ? '${entries.length} Messungen' : '–',
                      textAlign: TextAlign.right,
                      style: AppType.ui(
                        11.5,
                        weight: FontWeight.w600,
                        color: t.ink2,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: <Widget>[
                          Text(
                            formatKgDe(_current),
                            style: AppType.display(34, color: t.ink),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'kg',
                            style: AppType.ui(
                              13,
                              weight: FontWeight.w600,
                              color: t.ink2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (delta != null) ...<Widget>[
                    const SizedBox(width: 10),
                    _DeltaPill(delta: delta),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              // A11y: Verlaufslinie ist nur gezeichnet -> Spanne als Sprachwert.
              Semantics(
                label: 'Gewichtsverlauf',
                value: hatVerlauf
                    ? '${entries.length} Messungen, '
                        'zuletzt ${formatKgDe(entries.last.weightKg)} kg'
                    : 'Noch keine Verlaufslinie',
                child: hatVerlauf
                    ? RepaintBoundary(
                        child: Sparkline(
                          values: <double>[
                            for (final e in entries) e.weightKg,
                          ],
                        ),
                      )
                    // Unter zwei Messungen zeichnet die Sparkline nichts —
                    // eine leere 74-px-Flaeche saehe wie ein Ladefehler aus.
                    : Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: Text(
                          'Logge dein Gewicht regelmäßig für eine '
                          'Verlaufslinie.',
                          style: AppType.ui(12, color: t.ink2, height: 1.4),
                        ),
                      ),
              ),
              if (hatVerlauf) ...<Widget>[
                const SizedBox(height: 6),
                Row(
                  children: <Widget>[
                    _Caption(_formatShort(entries.first.timestamp)),
                    const Spacer(),
                    _Caption(_formatShort(entries.last.timestamp)),
                  ],
                ),
              ],
              ..._buildGoalProgress(context),
            ],
          ),
        ),
        const SizedBox(height: 12),
        PrimaryActionButton(
          key: const ValueKey('profile-log-weight'),
          label: 'Gewicht loggen',
          icon: Icons.add_rounded,
          height: 48,
          onTap: () => _promptWeight(context),
        ),
      ],
    );
  }

  /// Fortschritt vom ERSTEN gemessenen Gewicht zum Wunschgewicht.
  ///
  /// Liegt das Ziel praktisch auf dem Startwert („halten"), faellt die Zeile
  /// ganz weg: ein 100-%-Balken fuer ein Ziel, das keines ist, waere eine
  /// erfundene Erfolgsmeldung — und (start − ziel) waere zugleich der Nenner
  /// einer Division durch Null.
  List<Widget> _buildGoalProgress(BuildContext context) {
    final t = context.t;
    final start = log.entries.isNotEmpty
        ? log.entries.first.weightKg
        : profile.weightKg.toDouble();
    final ziel = profile.targetWeightKg.toDouble();
    final spanne = (start - ziel).abs();
    if (spanne < 0.1) return const <Widget>[];

    // Laeuft das Gewicht in die falsche Richtung, klemmt der Wert auf 0 —
    // gewollt, ein negativer Balken hilft niemandem.
    final fortschritt = ((start - _current) / (start - ziel)).clamp(0.0, 1.0);
    final prozent = (fortschritt * 100).round();

    return <Widget>[
      const SizedBox(height: 14),
      Divider(height: 1, thickness: 1, color: t.line),
      const SizedBox(height: 14),
      Semantics(
        label: 'Ziel Fortschritt',
        value: '$prozent %',
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Ziel ${formatKgDe(ziel)} kg',
                    style: AppType.ui(
                      11.5,
                      weight: FontWeight.w600,
                      color: t.ink,
                    ),
                  ),
                  const SizedBox(height: 7),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: fortschritt,
                      minHeight: 7,
                      backgroundColor: t.tile,
                      valueColor: AlwaysStoppedAnimation<Color>(t.accent),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '$prozent %',
              style: AppType.ui(11.5, weight: FontWeight.w700, color: t.ink2),
            ),
          ],
        ),
      ),
    ];
  }

  /// **D5, bewusst OHNE Verwerf-Rueckfrage.**
  ///
  /// Das Sheet haelt genau ein Feld, und das ist beim Oeffnen bereits mit dem
  /// zuletzt geloggten Gewicht gefuellt — derselbe Wert steht gross auf der
  /// Karte dahinter. Wer versehentlich schliesst, verliert das Eintippen von
  /// zwei, drei Ziffern, deren Ausgangswert er direkt vor sich sieht. Eine
  /// Rueckfrage kostet hier bei JEDEM Schliessen einen Extra-Tap und schuetzt
  /// dafuer fast nichts; sie waere mehr Stoerung als Schutz. Die Sheets mit
  /// Rueckfrage (Bestandteile, Bearbeiten, Rezept anlegen, Einstellungen)
  /// halten dagegen vielteilige Formulare, deren Inhalt nirgends sonst steht.
  ///
  /// Was hier trotzdem faellt, ist `showDragHandle: true`: `app_theme.dart`
  /// setzt global `false`, und der Griff der Route liegt als Stack-Geschwister
  /// NEBEN dem builder-Kind (`bottom_sheet.dart:397-410`) — ein Ort, an dem
  /// kein Sheet ihn je erreichen kann. Gezeichnet wird er jetzt wie ueberall
  /// sonst IM Sheet, siehe [_ProfileSheetGrabber].
  Future<void> _promptWeight(BuildContext context) async {
    final result = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: context.t.bg,
      isScrollControlled: true,
      builder: (_) => _ProfileWeightInputSheet(initial: _current),
    );
    if (result != null) onLogWeight(result);
  }

  static String _formatShort(DateTime d) {
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      return 'heute';
    }
    return '${d.day.toString().padLeft(2, '0')}.'
        '${d.month.toString().padLeft(2, '0')}.';
  }
}

/// Die BMI-Karte: Halbkreis-Skala, Zonen-Chip und die uebrigen Koerperdaten.
class BmiCard extends StatelessWidget {
  const BmiCard({super.key, required this.profile, required this.log});

  final UserProfile profile;
  final WeightLog log;

  double get _bmi {
    final m = profile.heightCm / 100.0;
    if (m <= 0) return 0;
    final w = log.latest?.weightKg ?? profile.weightKg.toDouble();
    return w / (m * m);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final bmi = _bmi;
    final bmiLabel = BMIGaugePainter.labelFor(bmi);
    final bmiColor = BMIGaugePainter.colorFor(t, bmi);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Körper',
                  style: AppType.display(
                    17,
                    weight: FontWeight.w700,
                    color: t.ink,
                  ),
                ),
              ),
              _InfoButton(
                onTap: () => _showBmiInfoSheet(context),
                tooltip: 'BMI-Erklärung',
              ),
            ],
          ),
          const SizedBox(height: 4),
          Center(
            child: SizedBox(
              width: 190,
              height: 108,
              // A11y: Gauge ist reines CustomPaint -> Wert + Zone ansagen.
              child: Semantics(
                label: 'BMI',
                value: '${formatBmiDe(bmi)} · $bmiLabel',
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: BMIGaugePainter.fromTokens(t, bmi),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: bmiColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(rControl),
              border: Border.all(color: bmiColor.withValues(alpha: 0.32)),
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(color: bmiColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'BMI $bmiLabel',
                    style: AppType.ui(
                      12,
                      weight: FontWeight.w600,
                      color: bmiColor,
                    ),
                  ),
                ),
                Text(
                  formatBmiDe(bmi),
                  style: AppType.ui(
                    12,
                    weight: FontWeight.w700,
                    color: bmiColor,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Wrap statt Row: bei grosser Systemschrift brechen die beiden
          // Angaben untereinander, statt die Zeile zu sprengen.
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: <Widget>[
              _BodyMetric(
                icon: Icons.height_rounded,
                label: '${profile.heightCm} cm',
              ),
              _BodyMetric(
                icon: Icons.cake_outlined,
                label: '${profile.ageYears} J. · ${profile.sex.label}',
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// `isScrollControlled`, weil die vier Zonen-Zeilen plus Erklaerungsabsatz
  /// bei doppelter Systemschrift deutlich hoeher werden als die 9/16
  /// Bildschirmhoehe, die ein ungesteuertes Sheet maximal bekommt (gemessen:
  /// 1087 px Ueberlauf). Der Inhalt scrollt zusaetzlich, siehe [_BmiInfoSheet].
  static void _showBmiInfoSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.t.bg,
      isScrollControlled: true,
      builder: (_) => const _BmiInfoSheet(),
    );
  }
}

/// Der Griff der Profil-Sheets — im Sheet gezeichnet statt an der Route.
///
/// Die Dismiss-Semantik muss dabei mitwandern: der Route-Griff bot
/// TalkBack/VoiceOver eine Tap-Aktion an (`bottom_sheet.dart:368`), und beide
/// Sheets hier haben keinen Schliessen-Knopf. Auf Android bietet auch die
/// Barriere keine Dismiss-Semantik an (`modal_barrier.dart`,
/// `platformSupportsDismissingBarrier`) — ohne diese Aktion saesse ein
/// Screenreader-Nutzer fest.
class _ProfileSheetGrabber extends StatelessWidget {
  const _ProfileSheetGrabber();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      button: true,
      label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      onTap: () => Navigator.of(context).maybePop(),
      child: SizedBox(
        width: double.infinity,
        height: 26,
        child: Center(
          child: SizedBox(
            width: 32,
            height: 4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: t.ink2.withValues(alpha: 0.5),
                borderRadius: const BorderRadius.all(Radius.circular(rPill)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BmiInfoSheet extends StatelessWidget {
  const _BmiInfoSheet();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // Name UND Farbe kommen aus [BMIGaugePainter] — eine zweite, hier
    // abgeschriebene Zuordnung waere genau die Stelle, an der die Legende
    // spaeter still von Skala und Zonen-Chip abweicht. Die Stuetzwerte liegen
    // jeweils mitten in ihrer Zone.
    final zones = <(String, String, Color)>[
      for (final z in <(double, String)>[
        (17.0, '< 18.5'),
        (22.0, '18.5 – 24.9'),
        (27.0, '25.0 – 29.9'),
        (32.0, '≥ 30.0'),
      ])
        (
          BMIGaugePainter.labelFor(z.$1),
          z.$2,
          BMIGaugePainter.colorFor(t, z.$1),
        ),
    ];
    // Griff bleibt oben stehen, der Rest scrollt: bei doppelter Systemschrift
    // ist die Zonen-Liste hoeher als der Bildschirm, und ein Erklaer-Sheet, das
    // seine unterste Zone abschneidet, erklaert nichts.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Center(child: _ProfileSheetGrabber()),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'BMI Orientierung',
                  style: AppType.display(20, color: t.ink),
                ),
                const SizedBox(height: 6),
                Text(
                  'Body Mass Index ist eine grobe Heuristik. Für Athleten und '
                  'athletische Körper ist die Tendenz interessanter als der '
                  'absolute Wert.',
                  style: AppType.ui(13, color: t.ink2, height: 1.45),
                ),
                const SizedBox(height: 16),
                for (final z in zones)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: z.$3.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(rControl),
                      border: Border.all(color: z.$3.withValues(alpha: 0.32)),
                    ),
                    child: Row(
                      children: <Widget>[
                        Container(
                          width: 8,
                          height: 8,
                          decoration:
                              BoxDecoration(color: z.$3, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            z.$1,
                            style: AppType.ui(
                              13,
                              weight: FontWeight.w600,
                              color: z.$3,
                            ),
                          ),
                        ),
                        // Flexible: die Bereichsangabe („18.5 – 24.9") ist bei
                        // 200 % Systemschrift breiter als der Rest der Zeile.
                        Flexible(
                          child: Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              z.$2,
                              textAlign: TextAlign.right,
                              style: AppType.ui(
                                12,
                                weight: FontWeight.w500,
                                color: t.ink2,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ProfileWeightInputSheet extends StatefulWidget {
  const _ProfileWeightInputSheet({required this.initial});

  final double initial;

  @override
  State<_ProfileWeightInputSheet> createState() =>
      _ProfileWeightInputSheetState();
}

class _ProfileWeightInputSheetState extends State<_ProfileWeightInputSheet> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.initial.toStringAsFixed(1),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Center(child: _ProfileSheetGrabber()),
          Text('Gewicht loggen', style: AppType.display(20, color: t.ink)),
          const SizedBox(height: 16),
          // Bewusst ein lokales TextField statt SheetField: der Fokus muss
          // beim Oeffnen im Feld stehen (`autofocus`), und SheetField kennt
          // diesen Parameter nicht. Die InputDecoration kommt trotzdem aus dem
          // Theme, ist also bereits tokenbasiert.
          TextField(
            key: const ValueKey('profile-weight-input'),
            cursorOpacityAnimates: false,
            controller: _controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Aktuelles Gewicht',
              suffixText: 'kg',
            ),
          ),
          const SizedBox(height: 16),
          PrimaryActionButton(
            key: const ValueKey('profile-weight-save'),
            label: 'Speichern',
            icon: Icons.check_rounded,
            height: 50,
            onTap: () {
              final raw = _controller.text.trim().replaceAll(',', '.');
              final value = double.tryParse(raw);
              if (value != null && value > 0) Navigator.pop(context, value);
            },
          ),
        ],
      ),
    );
  }
}

/// Die Veraenderung seit der ersten Messung.
///
/// Abweichung von der Vorlage: dort steht die Pille in `lime` bei 45 %
/// Deckkraft mit `ink`-Text — im Dunkelmodus waere das heller Text auf heller
/// Flaeche. Hier traegt sie die volle Lime-Flaeche mit `onLime` (das
/// dokumentierte Paar, in beiden Modi dunkel auf hell); „stabil" bleibt ruhig
/// auf `tile`.
class _DeltaPill extends StatelessWidget {
  const _DeltaPill({required this.delta});

  final double delta;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final isFlat = delta.abs() < 0.05;
    final icon = isFlat
        ? Icons.remove_rounded
        : (delta > 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded);
    // U+2212 als Minus, wie ueberall sonst in der App (paceLabel).
    final label = isFlat
        ? 'stabil'
        : '${delta > 0 ? '+' : '−'}${formatKgDe(delta.abs())} kg';
    final fg = isFlat ? t.ink2 : t.onLime;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isFlat ? t.tile : t.lime,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, color: fg, size: 12),
          const SizedBox(width: 4),
          Text(
            label,
            style: AppType.ui(11, weight: FontWeight.w700, color: fg),
          ),
        ],
      ),
    );
  }
}

class _BodyMetric extends StatelessWidget {
  const _BodyMetric({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, color: t.ink2, size: 13),
        const SizedBox(width: 6),
        // Flexible + Ellipsis: als starres Row-Kind mass der Text seine volle
        // Einzeilenbreite und sprengte bei grosser Systemschrift die Zeile —
        // auch innerhalb eines Wrap, der nur den UMBRUCH regelt, nicht die
        // Breite eines einzelnen Kindes.
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.ui(12, weight: FontWeight.w500, color: t.ink2),
          ),
        ),
      ],
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppType.ui(
        11,
        weight: FontWeight.w500,
        color: context.t.ink2,
        letterSpacing: 0.2,
      ),
    );
  }
}

class _InfoButton extends StatelessWidget {
  const _InfoButton({required this.onTap, required this.tooltip});

  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // A11y: 44x44 Hit-Target, Chip + Glyph bleiben optisch 28/15.
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 44,
        height: 44,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(rControl),
          child: Center(
            child: Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: t.tile,
                borderRadius: BorderRadius.circular(rControl),
              ),
              child: Icon(
                Icons.info_outline_rounded,
                color: t.ink2,
                size: 15,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
