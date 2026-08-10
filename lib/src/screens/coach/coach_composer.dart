part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Composer nach der Design-Vorlage: Kapsel auf `surf` mit 1-px-Rand, „+"
// links, Text, Mic und der Senden-Knopf als Forest-Kachel mit Lime-Pfeil.
// Fokus hellt die Flaeche auf `surf2` auf, statt einen Ring zu ziehen; bei
// knapper Quota sitzt ein tappbarer Hinweis darueber.
// ---------------------------------------------------------------------------
class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.focus,
    required this.enabled,
    required this.canSend,
    required this.remaining,
    required this.draft,
    required this.listening,
    required this.onSubmit,
    required this.onMic,
    required this.onAttach,
    required this.onQuotaTap,
  });

  final TextEditingController controller;
  final FocusNode focus;

  /// Tippen erlaubt (Session geladen, Quota uebrig).
  final bool enabled;

  /// Aktionen erlaubt (zusaetzlich: gerade kein Send unterwegs).
  final bool canSend;
  final int remaining;
  final String draft;
  final bool listening;
  final VoidCallback onSubmit;
  final VoidCallback onMic;
  final VoidCallback onAttach;
  final VoidCallback onQuotaTap;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  late bool _focused = widget.focus.hasFocus;

  @override
  void initState() {
    super.initState();
    widget.focus.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    widget.focus.removeListener(_handleFocusChange);
    super.dispose();
  }

  void _handleFocusChange() {
    if (_focused != widget.focus.hasFocus) {
      setState(() => _focused = widget.focus.hasFocus);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final hasText = widget.draft.trim().isNotEmpty;
    final showQuotaHint = widget.remaining > 0 && widget.remaining <= 2;
    // Kein viewInsets-Zuschlag wie in der Vorlage: der Home-Scaffold hat fuer
    // den Coach `resizeToAvoidBottomInset: true`, die Tastatur ist also schon
    // einmal ausgeglichen.
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (showQuotaHint)
            _QuotaHint(remaining: widget.remaining, onTap: widget.onQuotaTap),
          AnimatedContainer(
            duration: motionDuration(context, const Duration(milliseconds: 200)),
            curve: Curves.easeOutCubic,
            // Horizontal 0: der Seitenrand kommt aus der Schale.
            margin: const EdgeInsets.only(bottom: 4),
            constraints: const BoxConstraints(minHeight: 52, maxHeight: 160),
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
            decoration: BoxDecoration(
              color: _focused ? t.surf2 : t.surf,
              borderRadius: BorderRadius.circular(17),
              border: Border.all(color: t.line),
              // Die einzige erhabene Flaeche des Screens: der Composer liegt
              // ueber der scrollenden Liste.
              boxShadow: softShadow(t),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                _ComposerIcon(
                  key: const ValueKey('coach-attach'),
                  icon: Icons.add_rounded,
                  enabled: widget.canSend,
                  onTap: widget.onAttach,
                  semanticLabel: 'Foto anhängen',
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: TextField(
                    key: const ValueKey('coach-input'),
                    cursorOpacityAnimates: false,
                    controller: widget.controller,
                    focusNode: widget.focus,
                    enabled: widget.enabled,
                    maxLines: 5,
                    minLines: 1,
                    textInputAction: TextInputAction.newline,
                    textCapitalization: TextCapitalization.sentences,
                    style: AppType.ui(15.5, color: t.ink, height: 1.3),
                    cursorColor: t.accent,
                    decoration: InputDecoration(
                      // Alle vier Raender UND `filled` muessen hier stehen:
                      // der inputDecorationTheme der App fuellt Felder und
                      // umrandet sie. Nur `border` zu setzen liesse einen
                      // zweiten gefuellten, gerahmten Kasten in der Kapsel
                      // stehen (dasselbe Muster wie SheetField).
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      isCollapsed: true,
                      contentPadding: const EdgeInsets.symmetric(
                          vertical: 14, horizontal: 6),
                      // C8: der Platzhalter nennt die KI — im Leerzustand
                      // steht der Hinweis im Hero, im laufenden Chat ist der
                      // Composer die einzige Stelle, die immer sichtbar ist.
                      hintText: widget.remaining <= 0
                          ? 'Limit für heute erreicht'
                          : widget.listening
                              ? 'Ich höre zu…'
                              : 'Frag den KI-Coach…',
                      hintStyle: AppType.ui(15.5, color: t.ink2),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                _MicButton(
                  enabled: widget.canSend,
                  listening: widget.listening,
                  onTap: widget.onMic,
                ),
                const SizedBox(width: 2),
                _SendButton(
                  active: hasText,
                  enabled: widget.canSend && hasText,
                  onTap: widget.onSubmit,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Dezenter Status-Hinweis ueber dem Composer, sobald nur noch 1–2
/// Coach-Fragen uebrig sind. Tap oeffnet das Quota-Sheet.
class _QuotaHint extends StatelessWidget {
  const _QuotaHint({required this.remaining, required this.onTap});

  final int remaining;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final shape = StadiumBorder(side: BorderSide(color: t.line));
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Center(
        child: Material(
          key: const ValueKey('coach-quota-hint'),
          color: t.surf,
          shape: shape,
          child: InkWell(
            customBorder: shape,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    width: 6,
                    height: 6,
                    decoration:
                        BoxDecoration(shape: BoxShape.circle, color: t.lime),
                  ),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Text(
                      remaining == 1
                          ? 'Noch 1 Frage heute'
                          : 'Noch $remaining Fragen heute',
                      style: AppType.ui(
                        11.5,
                        weight: FontWeight.w600,
                        color: t.ink2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ComposerIcon extends StatelessWidget {
  const _ComposerIcon({
    super.key,
    required this.icon,
    required this.enabled,
    required this.onTap,
    required this.semanticLabel,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  /// Pflicht, nicht optional: der Knopf zeigt AUSSCHLIESSLICH ein Glyph.
  /// Ohne Namen kuendigt ein Screenreader ihn als „Schaltflaeche" an — der
  /// Nutzer erfaehrt nie, was sie tut.
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            onTap: enabled ? onTap : null,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: 38,
              height: 44,
              child: Center(
                // Schlichtes Glyph ohne Chip — die Kapsel selbst traegt die
                // Flaeche.
                child: Icon(
                  icon,
                  color: enabled ? t.ink2 : t.ink2.withValues(alpha: 0.5),
                  size: 20,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Mic-Button rechts im Composer. Waehrend [listening] pulsiert ein weicher
/// Akzent-Ring hinter dem Icon (unter „Bewegung reduzieren": statisch getoent).
///
/// Der Zuhoer-Zustand faerbt sich in [AppTokens.accent], NICHT in `lime`:
/// `lime` ist eine Flaechenfarbe und traegt nur mit `onLime` darauf. Als
/// Strich auf der hellen Composer-Kapsel (`surf` = #FFFDF8) kaeme es im
/// Hellmodus auf rund 1,2:1 — das Mikro saehe aus, als sei nichts passiert,
/// obwohl es zuhoert. `accent` ist genau dafuer da (hell: forest, dunkel:
/// lime) und traegt in beiden Modi.
class _MicButton extends StatefulWidget {
  const _MicButton({
    required this.enabled,
    required this.listening,
    required this.onTap,
  });

  final bool enabled;
  final bool listening;
  final VoidCallback onTap;

  @override
  State<_MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<_MicButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant _MicButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _syncPulse() {
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (widget.listening && !reduce) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      if (_pulse.isAnimating) _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final color = widget.listening
        ? t.accent
        : (widget.enabled ? t.ink2 : t.ink2.withValues(alpha: 0.5));
    return Semantics(
      key: const ValueKey('coach-mic'),
      button: true,
      enabled: widget.enabled,
      // Der Knopf ist ein Umschalter: der Zustand gehoert in den Namen, sonst
      // erfaehrt ein Screenreader-Nutzer nie, dass gerade aufgenommen wird.
      label: widget.listening ? 'Spracheingabe beenden' : 'Spracheingabe',
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Material(
        // Auch die Fuellung ueber `accent`: `forest` bei 18 % liegt im
        // Dunkelmodus praktisch auf `surf` und war dort unsichtbar.
          color: widget.listening
              ? t.accent.withValues(alpha: 0.16)
              : Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            onTap: widget.enabled ? widget.onTap : null,
            customBorder: const CircleBorder(),
            child: SizedBox(
              width: 42,
              height: 44,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  if (widget.listening && !reduce)
                    RepaintBoundary(
                      child: AnimatedBuilder(
                        animation: _pulse,
                        builder: (_, __) {
                          final v = _pulse.value;
                          return Container(
                            width: 24 + 14 * v,
                            height: 24 + 14 * v,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: t.accent.withValues(alpha: 0.5 * (1 - v)),
                                width: 1.5,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  Icon(Icons.mic_none_rounded, color: color, size: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Senden-Knopf nach der Vorlage: Forest-Kachel mit Lime-Pfeil, sobald ein
/// Entwurf im Feld steht; sonst ruhige Kachel.
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.active,
    required this.enabled,
    required this.onTap,
  });

  final bool active;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final scharf = active && enabled;
    // Ein blanker GestureDetector traegt gar keine Semantik: der Knopf war
    // fuer TalkBack/VoiceOver weder benannt NOCH als Schaltflaeche erkennbar —
    // der Coach liess sich mit Screenreader schlicht nicht abschicken.
    // `enabled` gehoert dazu, damit der gesperrte Zustand angesagt wird,
    // statt wie ein wirkungsloser Knopf zu klingen.
    return Semantics(
      button: true,
      enabled: enabled,
      label: 'Senden',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: GestureDetector(
          key: const ValueKey('coach-send'),
          onTap: enabled ? onTap : null,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration:
                motionDuration(context, const Duration(milliseconds: 200)),
            curve: Curves.easeOutCubic,
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
              color: scharf ? t.forest : t.tile,
            ),
            child: Icon(
              Icons.send_rounded,
              color: scharf ? t.lime : t.ink2,
              size: 16,
            ),
          ),
        ),
      ),
    );
  }
}

/// Zeile im Attach-Sheet („+"): Icon-Kachel + Label.
class _AttachTile extends StatelessWidget {
  const _AttachTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(rCard),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(rCard),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          child: Row(
            children: <Widget>[
              IconTile(icon: icon, size: 36),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  label,
                  style:
                      AppType.ui(15, weight: FontWeight.w600, color: t.ink),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
/// Sheet hinter dem (i) im Kopf und hinter dem Hinweis im Leerzustand.
///
/// C8: vorher stand hier NUR das Tageskontingent — dass jede Nachricht einen
/// Tages-Snapshot (Gewicht, Ziel, Kalorien, offene Makros, Namen der heute
/// geloggten Mahlzeiten) an einen Drittanbieter in den USA mitschickt, war nur
/// in der Datenschutzerklaerung nachlesbar. Jetzt steht die Offenlegung oben
/// und das Kontingent darunter.
class _CoachInfoSheet extends StatelessWidget {
  const _CoachInfoSheet({required this.remaining, required this.dailyLimit});

  final int remaining;
  final int dailyLimit;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          child: Column(
            key: const ValueKey('coach-info-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // Kein eigener Ziehgriff: showEatovaSheet setzt showDragHandle.
              Text(
                'KI-Coach',
                style:
                    AppType.display(20, weight: FontWeight.w700, color: t.ink),
              ),
              const SizedBox(height: 6),
              Text(
                'Hier antwortet eine KI, keine echte Person. Die Antworten '
                'sind eine Schätzung und ersetzen keinen ärztlichen Rat.',
                style: AppType.ui(13, color: t.ink2, height: 1.45),
              ),
              const SizedBox(height: 18),
              const _InfoLabel('Das schickt jede Frage mit'),
              const SizedBox(height: 8),
              const _InfoBullet('Dein Gewicht und dein Zielgewicht'),
              const _InfoBullet(
                  'Deine heutigen Kalorien und die offenen Makros'),
              const _InfoBullet(
                  'Die Namen der Mahlzeiten, die du heute geloggt hast'),
              const SizedBox(height: 12),
              Text(
                'Das geht zusammen mit deiner Frage an unseren KI-Anbieter '
                '(OpenRouter, Modell Grok von xAI) auf Servern in den USA — '
                'nur, um die Antwort zu erzeugen. Mehr dazu steht in der '
                'Datenschutzerklärung.',
                style: AppType.ui(13, color: t.ink2, height: 1.45),
              ),
              const SizedBox(height: 20),
              Container(height: 1, color: t.line),
              const SizedBox(height: 18),
              const _InfoLabel('Coach-Limit'),
              const SizedBox(height: 6),
              Text(
                '$remaining von $dailyLimit Fragen heute frei. '
                'Reset um Mitternacht (UTC).',
                style: AppType.ui(13, color: t.ink2, height: 1.45),
              ),
              const SizedBox(height: 14),
              _QuotaBar(remaining: remaining, total: dailyLimit),
            ],
          ),
        ),
      ),
    );
  }
}

/// Abschnitts-Ueberschrift im Info-Sheet.
class _InfoLabel extends StatelessWidget {
  const _InfoLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Text(
      text,
      style: AppType.ui(13.5, weight: FontWeight.w700, color: t.ink),
    );
  }
}

/// Aufzaehlungszeile im Info-Sheet (Lime-Punkt + Text).
class _InfoBullet extends StatelessWidget {
  const _InfoBullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 5,
            height: 5,
            margin: const EdgeInsets.only(top: 7, right: 9),
            decoration: BoxDecoration(color: t.lime, shape: BoxShape.circle),
          ),
          Expanded(
            child: Text(
              text,
              style: AppType.ui(13, color: t.ink, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
class _QuotaBar extends StatelessWidget {
  const _QuotaBar({required this.remaining, required this.total});

  final int remaining;
  final int total;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final pct = total == 0 ? 0.0 : remaining / total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(rPill),
          child: Stack(
            children: <Widget>[
              Container(height: 6, color: t.tile),
              FractionallySizedBox(
                widthFactor: pct.clamp(0.0, 1.0),
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(color: t.accent),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '$remaining / $total',
          style:
              AppType.display(12.5, weight: FontWeight.w600, color: t.ink),
        ),
      ],
    );
  }
}
