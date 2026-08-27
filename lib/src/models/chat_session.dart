/// Eine Chat-Session = ein Konversations-Thread im Coach-Tab.
class ChatSession {
  const ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.lastMessageAt,
    required this.messageCount,
  });

  final String id;

  /// Stored title, trimmed; empty when the row carries none. Language-free on
  /// purpose: the display maps [isDefaultTitle] to the localized default.
  final String title;
  final DateTime createdAt;
  final DateTime lastMessageAt;
  final int messageCount;

  bool get isEmpty => messageCount == 0;

  /// Titles the schema default, the client and older builds wrote before the
  /// server derived one from the first question. Known strings only — a user
  /// rename that happens to match is indistinguishable and also fine to map.
  static const Set<String> defaultTitles = <String>{
    '',
    'Neue Unterhaltung',
    'New conversation',
    'Allgemein',
  };

  /// True when the title is a placeholder, not a real conversation name.
  bool get isDefaultTitle => defaultTitles.contains(title.trim());

  factory ChatSession.fromRow(Map<String, dynamic> row) {
    return ChatSession(
      id: row['id']?.toString() ?? '',
      title: row['title']?.toString().trim() ?? '',
      createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
      lastMessageAt:
          DateTime.parse(row['last_message_at'] as String).toLocal(),
      messageCount: (row['message_count'] as num?)?.toInt() ?? 0,
    );
  }

  ChatSession copyWith({
    String? title,
    DateTime? lastMessageAt,
    int? messageCount,
  }) {
    return ChatSession(
      id: id,
      title: title ?? this.title,
      createdAt: createdAt,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      messageCount: messageCount ?? this.messageCount,
    );
  }
}
