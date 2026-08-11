import 'dart:typed_data';

/// Eine einzelne Nachricht im Coach-Chat. role ist user|assistant - die
/// system-Rolle bleibt serverseitig und wird hier nicht modelliert.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
    this.refusal = false,
    this.imageBytes,
  });

  final String id;
  final ChatRole role;
  final String content;
  final DateTime createdAt;
  final bool refusal;

  /// Nur fuer frisch gesendete lokale Nachrichten. Historie aus Supabase
  /// speichert aktuell bewusst keine Bilddaten, damit die Tabelle schlank und
  /// privat bleibt.
  final Uint8List? imageBytes;

  factory ChatMessage.fromRow(Map<String, dynamic> row) {
    final roleRaw = row['role']?.toString() ?? 'assistant';
    return ChatMessage(
      id: row['id']?.toString() ?? '',
      role: roleRaw == 'user' ? ChatRole.user : ChatRole.assistant,
      content: row['content']?.toString() ?? '',
      createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
      refusal: row['refusal'] == true,
    );
  }

  ChatMessage copyWith({String? content, bool? refusal}) {
    return ChatMessage(
      id: id,
      role: role,
      content: content ?? this.content,
      createdAt: createdAt,
      refusal: refusal ?? this.refusal,
      imageBytes: imageBytes,
    );
  }
}

enum ChatRole { user, assistant }

/// Snapshot der Quota fuer den Counter im UI.
///
/// Ein Snapshot bedeutet: *der Server hat diese Zahlen genannt*. Es gibt hier
/// bewusst KEINEN `unknown`-Wert mehr. Der frueher an dieser Stelle stehende
/// `ChatQuotaSnapshot.unknown` war mit `used: 0, remaining: 5, dailyLimit: 5`
/// belegt und hiess damit nicht „unbekannt", sondern „volles Kontingent":
/// `CoachChatService.loadQuotaToday()` lieferte ihn bei JEDEM Fehler, der
/// Coach-Screen schrieb ihn ungeprueft in seinen Zustand. Eine Netzstoerung
/// fuellte so ein erschoepftes Kontingent wieder auf — die Sperre fiel, und
/// der naechste Versuch lief in den 429 des Servers.
///
/// „Unbekannt" ist jetzt die *Abwesenheit* eines Snapshots: der Service wirft
/// `CoachDataUnavailable`, der Screen haelt ein `ChatQuotaSnapshot?` und
/// behaelt bei einem Fehlschlag seinen letzten bekannten Stand.
class ChatQuotaSnapshot {
  const ChatQuotaSnapshot({
    required this.used,
    required this.remaining,
    required this.dailyLimit,
  });

  final int used;
  final int remaining;
  final int dailyLimit;

  /// Tageslimit, mit dem die App rechnet, solange der Server keines genannt
  /// hat — und zugleich der Wert, den sie beim RPC anfragt.
  ///
  /// Reiner ANZEIGE-Ersatz fuer Widgets, die zwingend eine Zahl brauchen
  /// (Composer-Hinweis, Info-Sheet). Ausdruecklich KEINE Zustandsangabe: ob
  /// der Composer sperrt, haengt allein daran, ob ueberhaupt ein Snapshot
  /// vorliegt und was darin steht — nie an dieser Konstante.
  static const int standardTageslimit = 5;

  ChatQuotaSnapshot copyWith({int? used, int? remaining, int? dailyLimit}) {
    return ChatQuotaSnapshot(
      used: used ?? this.used,
      remaining: remaining ?? this.remaining,
      dailyLimit: dailyLimit ?? this.dailyLimit,
    );
  }
}
