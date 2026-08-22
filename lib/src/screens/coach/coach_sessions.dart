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
    final t = context.t;
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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        l10n.coachSessionsTitle,
                        style: AppType.display(
                          19,
                          weight: FontWeight.w700,
                          color: t.ink,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Material(
                      color: t.forest,
                      borderRadius: BorderRadius.circular(rPill),
                      child: InkWell(
                        key: const ValueKey('coach-sessions-new'),
                        onTap: onNew,
                        borderRadius: BorderRadius.circular(rPill),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(Icons.add_rounded, size: 18, color: t.lime),
                              const SizedBox(width: 6),
                              Text(
                                l10n.coachSessionsNewLabel,
                                style: AppType.ui(
                                  13.5,
                                  weight: FontWeight.w700,
                                  color: t.onForest,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Flexible(
                child: sessions.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
                        child: Text(
                          l10n.coachSessionsEmpty,
                          style: AppType.ui(13.5, color: t.ink2, height: 1.4),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
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
    final t = context.t;
    final l10n = context.l10n;
    showDialog<void>(
      context: context,
      // Surface, radius, border and text styles come from dialogTheme.
      builder: (ctx) => AlertDialog(
        title: Text(l10n.coachSessionDeleteTitle),
        content: Text(l10n.coachSessionDeleteBody(s.title)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l10n.commonCancel, style: TextStyle(color: t.ink2)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              onDelete(s.id);
            },
            child: Text(l10n.commonDelete, style: TextStyle(color: t.danger)),
          ),
        ],
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
    return Material(
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
                      session.title,
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
              IconButton(
                tooltip: l10n.commonDelete,
                onPressed: onDelete,
                icon: Icon(Icons.delete_outline_rounded,
                    size: 18, color: t.ink2),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One-time init of the `intl` date symbols; own guard because this file and
/// `today_texts.dart` are separate libraries.
bool _coachDateSymbolsReady = false;
void _ensureCoachDateSymbols() {
  if (_coachDateSymbolsReady) return;
  initializeDateFormatting();
  _coachDateSymbolsReady = true;
}

String _humanizeTimestamp(DateTime ts, AppLocalizations l10n) {
  final diff = DateTime.now().difference(ts);
  if (diff.inMinutes < 1) return l10n.coachTimeJustNow;
  if (diff.inMinutes < 60) return l10n.coachTimeMinutesAgo(diff.inMinutes);
  if (diff.inHours < 24) return l10n.coachTimeHoursAgo(diff.inHours);
  if (diff.inDays < 7) return l10n.coachTimeDaysAgo(diff.inDays);
  // The SAME numeric pattern on purpose for 'en': day.month.year stays
  // unambiguous, whereas 'MM/dd' reads differently to US and GB/DE readers.
  _ensureCoachDateSymbols();
  return DateFormat('dd.MM.yyyy', l10n.localeName).format(ts);
}
