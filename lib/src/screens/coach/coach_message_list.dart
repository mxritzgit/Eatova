part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Conversation: message bubbles — user right on the brand fill, coach left on
// `surf`; the corner on the speaker's side is clipped.
// ---------------------------------------------------------------------------
class _Conversation extends StatelessWidget {
  const _Conversation({
    required this.controller,
    required this.focus,
    required this.messages,
    required this.sending,
    required this.recipeAddedFor,
    required this.recipeAddEnabled,
    required this.onAddRecipe,
  });

  final ScrollController controller;
  final FocusNode focus;
  final List<ChatMessage> messages;
  final bool sending;

  /// Whether a /recipe card is already added; derived from the live recipe
  /// slugs, since the slug is built deterministically from the message id.
  final bool Function(ChatMessage message) recipeAddedFor;
  final bool recipeAddEnabled;
  final ValueChanged<ChatMessage> onAddRecipe;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('coach-message-list'),
      onTap: () => focus.unfocus(),
      behavior: HitTestBehavior.translucent,
      child: ListView.builder(
        controller: controller,
        // Horizontal 0: the side inset comes from the shell.
        padding: const EdgeInsets.fromLTRB(0, 18, 0, 10),
        itemCount: messages.length + (sending ? 1 : 0),
        itemBuilder: (context, i) {
          if (sending && i == messages.length) {
            return const _ThinkingRow();
          }
          final message = messages[i];
          return _MessageView(
            message: message,
            recipeAdded: recipeAddedFor(message),
            recipeAddEnabled: recipeAddEnabled,
            onAddRecipe: () => onAddRecipe(message),
          );
        },
      ),
    );
  }
}

class _MessageView extends StatelessWidget {
  const _MessageView({
    required this.message,
    this.recipeAdded = false,
    this.recipeAddEnabled = false,
    this.onAddRecipe,
  });
  final ChatMessage message;
  final bool recipeAdded;
  final bool recipeAddEnabled;
  final VoidCallback? onAddRecipe;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final fromUser = message.role == ChatRole.user;
    final imageBytes = message.imageBytes;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Cap 290, else 82 % so the opposite side stays a visible indent.
          // Sized from constraints, not MediaQuery: a fraction of the list.
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (message.refusal) ...<Widget>[
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            Icons.info_outline_rounded,
                            size: 12,
                            color: t.warning,
                          ),
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
                    // Images only on own messages: the Supabase history
                    // stores no image data.
                    if (imageBytes != null && fromUser) ...<Widget>[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(rCard),
                        child: LayoutBuilder(
                          builder: (context, bildConstraints) {
                            // Picked images are up to 1600px wide; decode at
                            // bubble width instead of full size.
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
                    // /rezept proposal: the card replaces the bubble text,
                    // which would only say the same thing twice.
                    if (message.recipeProposal != null)
                      _RecipeProposalCard(
                        proposal: message.recipeProposal!,
                        added: recipeAdded,
                        enabled: recipeAddEnabled,
                        onAdd: onAddRecipe,
                      )
                    else if (fromUser)
                      // Selectable like the coach bubble (P5-03): once the
                      // composer clears the field, this bubble is the only
                      // copy of what the user wrote. If the send failed, plain
                      // `Text` left retyping as the only way back.
                      SelectionArea(
                        child: Text(
                          message.content,
                          style: AppType.ui(
                            13.5,
                            color: t.onForest,
                            height: 1.5,
                          ),
                        ),
                      )
                    else
                      // Coach answers are plain text (the prompt forbids
                      // Markdown) and copyable via long press.
                      SelectionArea(
                        child: Text(
                          message.content,
                          style: AppType.ui(13.5, color: t.ink, height: 1.5),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
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
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  /// Like [_MicButton] and [CoachOrb]: the animation holds still under reduced
  /// motion — an unconditional `..repeat()` hangs `pumpAndSettle` in tests.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
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
      key: const ValueKey('coach-thinking'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: <Widget>[
          // RepaintBoundary keeps the loop repaint out of the chat list layer.
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
                          color: t.ink2.withValues(alpha: 0.28 + 0.55 * wert),
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
