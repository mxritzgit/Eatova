part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Composer (AI Coach v2): rahmenlose Soft-Pill (surfaceSoft + cardShadow),
// "+"-Attach links, Text, Mic + runder Send-Kreis rechts (faerbt sich mit
// Draft in coachAccent). Fokus hellt die Flaeche dezent auf; bei knapper
// Quota sitzt ein tappbarer Hinweis-Pill darueber.
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
    final hasText = widget.draft.trim().isNotEmpty;
    final showQuotaHint = widget.remaining > 0 && widget.remaining <= 2;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showQuotaHint)
            _QuotaHint(remaining: widget.remaining, onTap: widget.onQuotaTap),
          AnimatedContainer(
            duration: motionDuration(context, const Duration(milliseconds: 200)),
            curve: Curves.easeOutCubic,
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            constraints: const BoxConstraints(minHeight: 52, maxHeight: 160),
            padding: const EdgeInsets.fromLTRB(8, 4, 6, 4),
            decoration: BoxDecoration(
              // Rahmenlos: weiche, erhabene Kapsel im Premium-Dark-Stil
              // (cardShadow statt Stroke). Fokus hellt die Flaeche dezent auf,
              // statt einen Ring zu ziehen.
              color: _focused
                  ? Color.alphaBlend(
                      Colors.white.withValues(alpha: 0.045),
                      surfaceSoft,
                    )
                  : surfaceSoft,
              borderRadius: BorderRadius.circular(26),
              boxShadow: cardShadow,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _ComposerIcon(
                  key: const ValueKey('coach-attach'),
                  icon: Icons.add_rounded,
                  enabled: widget.canSend,
                  onTap: widget.onAttach,
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
                    style: const TextStyle(
                      color: textPrimary,
                      fontSize: 15.5,
                      height: 1.3,
                      letterSpacing: -0.1,
                    ),
                    cursorColor: coachAccent,
                    decoration: InputDecoration(
                      isCollapsed: true,
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
                      // C8: der Platzhalter nennt die KI — im Leerzustand
                      // steht der Hinweis im Hero, im laufenden Chat ist der
                      // Composer die einzige Stelle, die immer sichtbar ist.
                      hintText: widget.remaining <= 0
                          ? 'Limit für heute erreicht'
                          : widget.listening
                              ? 'Ich höre zu…'
                              : 'Frag den KI-Coach…',
                      hintStyle: const TextStyle(
                        color: textMuted,
                        fontSize: 15.5,
                        letterSpacing: -0.1,
                      ),
                      border: InputBorder.none,
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

/// Dezenter Status-Pill ueber dem Composer, sobald nur noch 1–2 Coach-Fragen
/// uebrig sind. Tap oeffnet das Quota-Sheet.
class _QuotaHint extends StatelessWidget {
  const _QuotaHint({required this.remaining, required this.onTap});

  final int remaining;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Center(
        child: Material(
          key: const ValueKey('coach-quota-hint'),
          color: surfaceSoft,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: coachAccent,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(
                    remaining == 1
                        ? 'Noch 1 Frage heute'
                        : 'Noch $remaining Fragen heute',
                    style: const TextStyle(
                      color: textMuted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.1,
                      fontFeatures: [FontFeature.tabularFigures()],
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
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
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
              // Schlichtes Glyph ohne Chip (AI Coach v2) — die Pill selbst
              // traegt die Flaeche.
              child: Icon(
                icon,
                color: enabled ? textMuted : textMuted.withValues(alpha: 0.5),
                size: 20,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Mic-Button rechts im Composer. Waehrend [listening] pulsiert ein weicher
/// Akzent-Ring hinter dem Icon (unter "Bewegung reduzieren": statisch getoent).
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
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final color = widget.listening
        ? coachAccent
        : (widget.enabled ? textMuted : textMuted.withValues(alpha: 0.5));
    return Padding(
      key: const ValueKey('coach-mic'),
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: widget.listening
            ? coachAccent.withValues(alpha: 0.14)
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
              children: [
                if (widget.listening && !reduce)
                  RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: _pulse,
                      builder: (_, __) {
                        final t = _pulse.value;
                        return Container(
                          width: 24 + 14 * t,
                          height: 24 + 14 * t,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: coachAccent.withValues(alpha: 0.5 * (1 - t)),
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
    );
  }
}

/// Runder Send-Kreis (AI Coach v2): faerbt sich mit vorhandenem Draft in
/// coachAccent, sonst dezente Ruhe-Flaeche.
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
      child: GestureDetector(
        key: const ValueKey('coach-send'),
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: motionDuration(context, const Duration(milliseconds: 200)),
          curve: Curves.easeOutCubic,
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active && enabled
                ? coachAccent
                : textPrimary.withValues(alpha: 0.08),
          ),
          child: Icon(
            Icons.arrow_upward_rounded,
            color: active && enabled ? Colors.white : textMuted,
            size: 18,
          ),
        ),
      ),
    );
  }
}

/// Zeile im Attach-Sheet ("+"): Icon-Kachel + Label, Sheet-Pattern der App.
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
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(rCard),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(rCard),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: surfaceSoft,
                  borderRadius: BorderRadius.circular(rControl),
                ),
                child: Icon(icon, size: 18, color: textPrimary),
              ),
              const SizedBox(width: 12),
              Text(
                label,
                style: const TextStyle(
                  color: textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
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
/// Sheet hinter dem (i) in der Top-Bar und hinter dem Hinweis im Leerzustand.
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
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            key: const ValueKey('coach-info-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    color: hairline,
                    borderRadius: BorderRadius.circular(rPill),
                  ),
                ),
              ),
              const Text(
                'KI-Coach',
                style: TextStyle(
                  color: textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Hier antwortet eine KI, keine echte Person. Die Antworten '
                'sind eine Schätzung und ersetzen keinen ärztlichen Rat.',
                style: TextStyle(color: textMuted, fontSize: 13, height: 1.45),
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
              const Text(
                'Das geht zusammen mit deiner Frage an unseren KI-Anbieter '
                '(OpenRouter, Modell Grok von xAI) auf Servern in den USA — '
                'nur, um die Antwort zu erzeugen. Mehr dazu steht in der '
                'Datenschutzerklärung.',
                style: TextStyle(color: textMuted, fontSize: 13, height: 1.45),
              ),
              const SizedBox(height: 20),
              Container(height: 1, color: hairline),
              const SizedBox(height: 18),
              const _InfoLabel('Coach-Limit'),
              const SizedBox(height: 6),
              Text(
                '$remaining von $dailyLimit Fragen heute frei. '
                'Reset um Mitternacht (UTC).',
                style: const TextStyle(
                  color: textMuted,
                  fontSize: 13,
                  height: 1.45,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
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
    return Text(
      text,
      style: const TextStyle(
        color: textPrimary,
        fontSize: 13.5,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
    );
  }
}

/// Aufzaehlungszeile im Info-Sheet (Akzent-Punkt + Text).
class _InfoBullet extends StatelessWidget {
  const _InfoBullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 5,
            height: 5,
            margin: const EdgeInsets.only(top: 7, right: 9),
            decoration: const BoxDecoration(
              color: coachAccent,
              shape: BoxShape.circle,
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: textPrimary,
                fontSize: 13,
                height: 1.45,
              ),
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
    final pct = total == 0 ? 0.0 : remaining / total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(rPill),
          child: Stack(
            children: [
              Container(height: 6, color: surfaceSoft),
              FractionallySizedBox(
                widthFactor: pct.clamp(0.0, 1.0),
                child: Container(
                  height: 6,
                  decoration: const BoxDecoration(color: coachAccent),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '$remaining / $total',
          style: const TextStyle(
            color: textPrimary,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
