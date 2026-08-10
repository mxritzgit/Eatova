part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Konversation: Nachrichten als Blasen der Design-Vorlage — Nutzer rechts auf
// der Marken-Flaeche, Coach links auf `surf` mit 1-px-Rand, die Ecke an der
// Sprecherseite angeschnitten.
// ---------------------------------------------------------------------------
class _Conversation extends StatelessWidget {
  const _Conversation({
    required this.controller,
    required this.focus,
    required this.messages,
    required this.sending,
  });

  final ScrollController controller;
  final FocusNode focus;
  final List<ChatMessage> messages;
  final bool sending;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('coach-message-list'),
      onTap: () => focus.unfocus(),
      behavior: HitTestBehavior.translucent,
      child: ListView.builder(
        controller: controller,
        // Horizontal 0: der Seitenrand kommt aus der Schale.
        padding: const EdgeInsets.fromLTRB(0, 18, 0, 10),
        itemCount: messages.length + (sending ? 1 : 0),
        itemBuilder: (context, i) {
          if (sending && i == messages.length) {
            return const _ThinkingRow();
          }
          return _MessageView(message: messages[i]);
        },
      ),
    );
  }
}

class _MessageView extends StatelessWidget {
  const _MessageView({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final fromUser = message.role == ChatRole.user;
    final imageBytes = message.imageBytes;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: LayoutBuilder(builder: (context, constraints) {
        // Der Deckel stammt aus der Vorlage (290), der Anteil aus der
        // bisherigen Blase — auf schmalen Geraeten gewinnt er, damit die
        // Gegenseite als Einzug sichtbar bleibt und man sieht, wer spricht.
        // Bewusst aus den Layout-Constraints statt aus MediaQuery: die Blase
        // ist ein Anteil der LISTE, nicht des Bildschirms (die Schale setzt
        // links und rechts 20 px).
        final maxBubble = constraints.maxWidth.isFinite
            ? math.min(290.0, constraints.maxWidth * 0.82)
            : 290.0;
        return Align(
          alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxBubble),
            child: Container(
              decoration: BoxDecoration(
                color: fromUser ? t.forest : t.surf,
                border: Border.all(color: fromUser ? t.forest : t.line),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(20),
                  topRight: const Radius.circular(20),
                  bottomLeft: Radius.circular(fromUser ? 20 : 6),
                  bottomRight: Radius.circular(fromUser ? 6 : 20),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (message.refusal) ...<Widget>[
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(Icons.info_outline_rounded,
                            size: 12, color: t.warning),
                        const SizedBox(width: 5),
                        Text(
                          context.l10n.coachRefusalLabel,
                          style: AppType.ui(
                            10.5,
                            weight: FontWeight.w700,
                            color: t.warning,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                  ],
                  // Bilder gibt es nur an der eigenen Nachricht: die Historie
                  // aus Supabase speichert bewusst keine Bilddaten.
                  if (imageBytes != null && fromUser) ...<Widget>[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(rCard),
                      child: LayoutBuilder(
                        builder: (context, bildConstraints) {
                          // Gepickte Bilder sind bis 1600px breit — Decode auf
                          // die Bubble-Breite begrenzen statt voll im Speicher.
                          final dpr = MediaQuery.devicePixelRatioOf(context);
                          final w = bildConstraints.maxWidth.isFinite
                              ? bildConstraints.maxWidth
                              : 320.0;
                          return Image.memory(
                            imageBytes,
                            height: 160,
                            width: double.infinity,
                            fit: BoxFit.cover,
                            cacheWidth: (w * dpr).round().clamp(1, 1600),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  Text(
                    message.content,
                    style: AppType.ui(
                      13.5,
                      color: fromUser ? t.onForest : t.ink,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _ThinkingRow extends StatefulWidget {
  const _ThinkingRow();
  @override
  State<_ThinkingRow> createState() => _ThinkingRowState();
}

class _ThinkingRowState extends State<_ThinkingRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  /// Wie [_MicButton] und [CoachOrb]: unter „Bewegung reduzieren" steht die
  /// Animation still. Vorher lief der Controller unbedingt mit `..repeat()` —
  /// jeder Test, der den Sende-Zustand zeigt, blieb damit in `pumpAndSettle`
  /// haengen, auch mit `disableAnimations: true`.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduce) {
      if (_c.isAnimating) _c.stop();
      _c.value = 0;
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: <Widget>[
          // RepaintBoundary: die Dauer-Animation (1,2s ..repeat()) haelt ihren
          // Re-Paint in einem eigenen Layer und invalidiert nicht die Chat-Liste.
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _c,
              builder: (_, __) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List<Widget>.generate(3, (i) {
                    final phase = (_c.value + i * 0.18) % 1.0;
                    final wert = math.sin(phase * math.pi).abs();
                    return Padding(
                      padding: EdgeInsets.only(right: i == 2 ? 0 : 5),
                      child: Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          color:
                              t.ink2.withValues(alpha: 0.28 + 0.55 * wert),
                          shape: BoxShape.circle,
                        ),
                      ),
                    );
                  }),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 8, 0, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: t.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: t.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.info_outline_rounded, size: 16, color: t.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: AppType.ui(12.5, color: t.ink, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}
