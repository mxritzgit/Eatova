part of 'coach_chat_screen.dart';

// ---------------------------------------------------------------------------
// Sessions-Sheet: Liste aller Konversationen + „Neu" oben.
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
    final maxHeight = MediaQuery.sizeOf(context).height * 0.75;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SafeArea(
        top: false,
        child: Padding(
          // Kein eigener Ziehgriff: showEatovaSheet setzt showDragHandle.
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
                        'Coach-Sessions',
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
                                'Neu',
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
                          'Noch keine Unterhaltungen. Stell deinem Coach die erste Frage.',
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
    showDialog<void>(
      context: context,
      // Flaeche, Radius, Rand und die Textstile kommen aus dem dialogTheme.
      builder: (ctx) => AlertDialog(
        title: const Text('Session löschen?'),
        content: Text('"${s.title}" und alle Nachrichten darin werden entfernt.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Abbrechen', style: TextStyle(color: t.ink2)),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              onDelete(s.id);
            },
            child: Text('Löschen', style: TextStyle(color: t.danger)),
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
                      _humanizeTimestamp(session.lastMessageAt),
                      style: AppType.ui(11.5, color: t.ink2),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Löschen',
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

String _humanizeTimestamp(DateTime ts) {
  final diff = DateTime.now().difference(ts);
  if (diff.inMinutes < 1) return 'gerade eben';
  if (diff.inMinutes < 60) return 'vor ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'vor ${diff.inHours} h';
  if (diff.inDays < 7) return 'vor ${diff.inDays} Tagen';
  return '${ts.day.toString().padLeft(2, '0')}.${ts.month.toString().padLeft(2, '0')}.${ts.year}';
}
