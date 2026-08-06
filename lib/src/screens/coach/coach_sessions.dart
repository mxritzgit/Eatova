part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Sessions-Sheet: Liste aller Konversationen + "Neue Unterhaltung" oben.
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
    final maxHeight = MediaQuery.of(context).size.height * 0.75;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 10, 0, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: hairline,
                    borderRadius: BorderRadius.circular(rPill),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Coach-Sessions',
                        style: TextStyle(
                          color: textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      key: const ValueKey('coach-sessions-new'),
                      onPressed: onNew,
                      icon: const Icon(Icons.add_rounded,
                          size: 18, color: coachAccent),
                      label: const Text(
                        'Neu',
                        style: TextStyle(
                          color: coachAccent,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        backgroundColor: coachAccent.withValues(alpha: 0.10),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(rPill),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: sessions.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
                        child: Text(
                          'Noch keine Unterhaltungen. Stell deinem Coach die erste Frage.',
                          style: TextStyle(
                            color: textMuted.withValues(alpha: 0.9),
                            fontSize: 13.5,
                            height: 1.4,
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        shrinkWrap: true,
                        itemCount: sessions.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 6),
                        itemBuilder: (context, i) {
                          final s = sessions[i];
                          final isActive = s.id == activeSessionId;
                          return _SessionTile(
                            session: s,
                            isActive: isActive,
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
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: surface,
        title: const Text('Session löschen?',
            style: TextStyle(color: textPrimary, fontSize: 16)),
        content: Text(
          '"${s.title}" und alle Nachrichten darin werden entfernt.',
          style: const TextStyle(color: textMuted, fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Abbrechen', style: TextStyle(color: textMuted)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              onDelete(s.id);
            },
            child: const Text('Löschen', style: TextStyle(color: danger)),
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
    return Material(
      color: isActive ? surfaceSoft : Colors.transparent,
      borderRadius: BorderRadius.circular(rCard),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(rCard),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: isActive
                      ? coachAccent.withValues(alpha: 0.16)
                      : surfaceSoft,
                  borderRadius: BorderRadius.circular(rControl),
                ),
                child: Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 16,
                  color: isActive ? coachAccent : textMuted,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      session.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _humanizeTimestamp(session.lastMessageAt),
                      style: const TextStyle(color: textMuted, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Löschen',
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline_rounded,
                    size: 18, color: textMuted),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _humanizeTimestamp(DateTime ts) {
  final diff = DateTime.now().difference(ts);
  if (diff.inMinutes < 1) return 'gerade eben';
  if (diff.inMinutes < 60) return 'vor ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'vor ${diff.inHours} h';
  if (diff.inDays < 7) return 'vor ${diff.inDays} Tagen';
  return '${ts.day.toString().padLeft(2, '0')}.${ts.month.toString().padLeft(2, '0')}.${ts.year}';
}
