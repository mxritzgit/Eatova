part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Konversation (AI Coach v2): User = coachAccent-Bubble rechts, Coach =
// Plain-Text links ohne Label.
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
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
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
    final isUser = message.role == ChatRole.user;
    final imageBytes = message.imageBytes;
    if (isUser) {
      return Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Flexible(
              child: Container(
                padding: EdgeInsets.fromLTRB(
                  15,
                  imageBytes == null ? 10 : 8,
                  15,
                  10,
                ),
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.78,
                ),
                decoration: BoxDecoration(
                  color: coachAccent,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (imageBytes != null) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(rCard),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            // Gepickte Bilder sind bis 1600px breit — Decode auf
                            // die Bubble-Breite begrenzen statt voll im Speicher.
                            final dpr = MediaQuery.devicePixelRatioOf(context);
                            final w = constraints.maxWidth.isFinite
                                ? constraints.maxWidth
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
                      const SizedBox(height: 8),
                    ],
                    Text(
                      message.content,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        height: 1.5,
                        letterSpacing: -0.1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    // Coach: Plain-Text ohne Bubble/Label (AI Coach v2); nur ein Refusal
    // bekommt eine kleine Hinweis-Zeile darueber.
    return Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.refusal) ...[
            const Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 12, color: warning),
                SizedBox(width: 5),
                Text(
                  'Hinweis',
                  style: TextStyle(
                    color: warning,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
          ],
          Text(
            message.content,
            style: const TextStyle(
              color: textPrimary,
              fontSize: 15,
              height: 1.5,
              letterSpacing: -0.1,
            ),
          ),
        ],
      ),
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
  late final AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 4),
      child: Row(
        children: [
          // RepaintBoundary: die Dauer-Animation (1,2s ..repeat()) haelt ihren
          // Re-Paint in einem eigenen Layer und invalidiert nicht die Chat-Liste.
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _c,
              builder: (_, __) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(3, (i) {
                    final phase = (_c.value + i * 0.18) % 1.0;
                    final t = math.sin(phase * math.pi).abs();
                    return Padding(
                      padding: EdgeInsets.only(right: i == 2 ? 0 : 5),
                      child: Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          color: textMuted.withValues(alpha: 0.28 + 0.55 * t),
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
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(rCard),
        border: Border.all(color: warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, size: 16, color: warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: textPrimary,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
