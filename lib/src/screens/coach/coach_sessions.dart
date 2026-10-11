part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Sessions sheet: all conversations, with "new" on top.
// ---------------------------------------------------------------------------
class _SessionsSheet extends StatelessWidget {
  const _SessionsSheet({
    required this.sessions,
    required this.activeSessionId,
    required this.onNew,
    required this.onSelect,
    required this.onDelete,
  });

  final List<ChatSession> sessions;
  final String? activeSessionId;
  final VoidCallback onNew;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.75;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SafeArea(
        top: false,
        child: Padding(
          // No own drag handle: showEatovaSheet sets showDragHandle.
          padding: const EdgeInsets.fromLTRB(0, 4, 0, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // On the 20 px gutter with the 24 px level-1 title of every
              // sheet; "New" is the app's accent soft pill.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: <Widget>[
                    Expanded(child: SheetTitle(l10n.coachSessionsTitle)),
                    const SizedBox(width: 10),
                    SoftPillButton(
                      key: const ValueKey('coach-sessions-new'),
                      icon: Icons.add_rounded,
                      label: l10n.coachSessionsNewLabel,
                      onTap: onNew,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Flexible(
                child: sessions.isEmpty
                    ? SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                        child: CalmState(
                          key: const ValueKey('coach-sessions-empty'),
                          icon: Icons.chat_bubble_outline_rounded,
                          text: l10n.coachSessionsEmpty,
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                        shrinkWrap: true,
                        itemCount: sessions.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 6),
                        itemBuilder: (context, i) {
                          final s = sessions[i];
                          return _SessionTile(
                            session: s,
                            isActive: s.id == activeSessionId,
                            onTap: () => onSelect(s.id),
                            onDelete: () => _confirmDelete(context, s),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, ChatSession s) {
    final l10n = context.l10n;
    showEatovaDialog<void>(
      context: context,
      builder: (ctx) => EatovaConfirmDialog(
        title: l10n.coachSessionDeleteTitle,
        body: l10n.coachSessionDeleteBody(_sessionTitle(s, l10n)),
        icon: Icons.delete_outline_rounded,
        destructive: true,
        cancelLabel: l10n.commonCancel,
        onCancel: () => Navigator.of(ctx).pop(),
        confirmLabel: l10n.commonDelete,
        onConfirm: () {
          Navigator.of(ctx).pop();
          onDelete(s.id);
        },
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.isActive,
    required this.onTap,
    required this.onDelete,
  });

  final ChatSession session;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final l10n = context.l10n;
    // The open conversation is marked by fill and icon colour only; a screen
    // reader learns it from the selected state.
    return Semantics(
      key: ValueKey('coach-session-${session.id}'),
      container: true,
      selected: isActive,
      child: Material(
        color: isActive ? t.surf : Colors.transparent,
        borderRadius: BorderRadius.circular(rCard),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(rCard),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            child: Row(
              children: <Widget>[
                IconTile(
                  icon: Icons.chat_bubble_outline_rounded,
                  color: isActive ? t.accent : null,
                  size: 32,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        _sessionTitle(session, l10n),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.ui(
                          14,
                          weight: FontWeight.w600,
                          color: t.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _humanizeTimestamp(session.lastMessageAt, l10n),
                        style: AppType.ui(11.5, color: t.ink2),
                      ),
                    ],
                  ),
                ),
                // Default density: compact shrank the target to 40 dp, below
                // the 48 dp minimum for a destructive action.
                IconButton(
                  tooltip: l10n.commonDelete,
                  onPressed: onDelete,
                  icon: Icon(Icons.delete_outline_rounded,
                      size: 18, color: t.ink2),
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Display title: stored placeholders (schema default, older builds, the
/// other language) show as the localized default; real titles pass through.
String _sessionTitle(ChatSession session, AppLocalizations l10n) =>
    session.isDefaultTitle ? l10n.coachSessionDefaultTitle : session.title;

/// One-time init of the `intl` date symbols; own guard because this file and
/// `today_texts.dart` are separate libraries.
bool _coachDateSymbolsReady = false;
void _ensureCoachDateSymbols() {
  if (_coachDateSymbolsReady) return;
  initializeDateFormatting();
  _coachDateSymbolsReady = true;
}

String _humanizeTimestamp(DateTime ts, AppLocalizations l10n) {
  final diff = clock.now().difference(ts);
  if (diff.inMinutes < 1) return l10n.coachTimeJustNow;
  if (diff.inMinutes < 60) return l10n.coachTimeMinutesAgo(diff.inMinutes);
  if (diff.inHours < 24) return l10n.coachTimeHoursAgo(diff.inHours);
  if (diff.inDays < 7) return l10n.coachTimeDaysAgo(diff.inDays);
  // The month as a word ("Sep 28, 2026", "28. Sept. 2026"): unambiguous in
  // both languages, unlike '09/28' vs '28.09', and the date style of the
  // rest of the app.
  _ensureCoachDateSymbols();
  return DateFormat.yMMMd(l10n.localeName).format(ts);
}
