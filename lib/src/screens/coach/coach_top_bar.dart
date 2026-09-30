part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Header (dark redesign): "Coach" title, the "Sees today's log" status and
// two round buttons — past chats and the data info.
// ---------------------------------------------------------------------------
class _CoachTopBar extends StatelessWidget {
  const _CoachTopBar({
    super.key,
    required this.contextShared,
    required this.onInfoTap,
    required this.onSessionsTap,
    this.compact = false,
  });

  /// Whether chat questions carry today's diary as context. Only then does
  /// the header claim that the coach sees the log.
  final bool contextShared;
  final VoidCallback onInfoTap;
  final VoidCallback onSessionsTap;
  final bool compact;

  static bool needsCompactLayout(BuildContext context, BoxConstraints size) {
    if (size.maxHeight < 360) return true;
    if (size.maxHeight >= 560) return false;
    final title = TextPainter(
      text: TextSpan(
        text: context.l10n.navCoach,
        style: AppType.pageTitle(context.t.ink),
      ),
      textDirection: Directionality.of(context),
      textScaler: AppType.pageTitleScaler(context),
      maxLines: 1,
    )..layout(maxWidth: size.maxWidth);
    final wraps = title.didExceedMaxLines;
    title.dispose();
    // A wrapped title plus status and controls can leave no usable chat area.
    return wraps;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    // The tab's rank-1 mark (P9-06c). It sits here and not on the hero
    // because this header is on screen in EVERY state. Visible "Coach" like
    // the design and the tab bar; screen readers hear the full "AI Coach".
    final title = HeadingSemantics(
      level: 1,
      child: Text(
        l10n.navCoach,
        semanticsLabel: l10n.coachTitle,
        style: AppType.pageTitle(t.ink),
        textScaler: AppType.pageTitleScaler(context),
      ),
    );
    final buttons = <Widget>[
      HeaderIconButton(
        key: const ValueKey('coach-sessions-open'),
        icon: Icons.history_rounded,
        onTap: onSessionsTap,
        semanticLabel: l10n.coachSessionsSemanticLabel,
      ),
      const SizedBox(width: 8),
      HeaderIconButton(
        key: const ValueKey('coach-info'),
        icon: Icons.info_outline_rounded,
        onTap: onInfoTap,
        semanticLabel: l10n.coachInfoSemanticLabel,
      ),
    ];
    // The title line is the shell's, shared by every tab (see
    // page_chrome_test: "tab titles share scale and origin").
    return compact
        ? Row(
            key: const ValueKey('coach-header-compact'),
            children: <Widget>[
              Expanded(child: title),
              ...buttons,
            ],
          )
        // Wrap instead of Row: at large text sizes title and buttons no
        // longer fit on one line; the buttons move down.
        : Wrap(
            key: const ValueKey('coach-header-full'),
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              // At least button height: the buttons centre on the title
              // block like the design, but a short block (no status line)
              // keeps its title at the top instead of sliding down.
              ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: HeaderIconButton.size,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    title,
                    if (contextShared) ...<Widget>[
                      const SizedBox(height: 4),
                      const _ContextStatus(),
                    ],
                  ],
                ),
              ),
              Row(mainAxisSize: MainAxisSize.min, children: buttons),
            ],
          );
  }
}

/// Green live dot plus "Sees today's log".
class _ContextStatus extends StatelessWidget {
  const _ContextStatus();

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // The design's live-status green is the protein hue (#1DB071); its 3 px
    // ring (the same green at 20 %) is a spread shadow, so it takes no room.
    final green = t.protein;
    return Row(
      key: const ValueKey('coach-context-status'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: green,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(color: green.withValues(alpha: 0.2), spreadRadius: 3),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            context.l10n.coachStatusLine,
            style: AppType.ui(
              13,
              weight: FontWeight.w600,
              color: t.ink2,
              height: 1.2,
            ),
          ),
        ),
      ],
    );
  }
}
