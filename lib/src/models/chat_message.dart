import 'dart:typed_data';

import 'coach_recipe_proposal.dart';

/// A single coach-chat message. Role is user|assistant; the system role stays
/// server-side and is not modelled here.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
    this.refusal = false,
    this.imageBytes,
    this.recipeProposal,
  });

  final String id;
  final ChatRole role;
  final String content;
  final DateTime createdAt;
  final bool refusal;

  /// Locally sent messages only; Supabase history stores no image data, to keep
  /// the table small and private.
  final Uint8List? imageBytes;

  /// Recipe proposal from /recipe. Unlike [imageBytes] it survives a reload:
  /// [fromRow] rebuilds it from `chat_messages.recipe`, but without bytes. The
  /// screen then loads the image from the device-local RecipeImageStore.
  final CoachRecipeProposal? recipeProposal;

  factory ChatMessage.fromRow(Map<String, dynamic> row) {
    final roleRaw = row['role']?.toString() ?? 'assistant';
    final rawRecipe = row['recipe'];
    return ChatMessage(
      id: row['id']?.toString() ?? '',
      role: roleRaw == 'user' ? ChatRole.user : ChatRole.assistant,
      content: row['content']?.toString() ?? '',
      createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
      refusal: row['refusal'] == true,
      recipeProposal:
          rawRecipe is Map ? CoachRecipeProposal.fromJson(rawRecipe) : null,
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
      recipeProposal: recipeProposal,
    );
  }
}

enum ChatRole { user, assistant }

/// Quota snapshot for the UI counter: numbers the server actually reported.
///
/// There is deliberately no `unknown` value — a fallback snapshot would read as
/// "full quota" and unlock an exhausted composer. Unknown is the *absence* of a
/// snapshot: the service throws `CoachDataUnavailable` and the screen keeps its
/// last known `ChatQuotaSnapshot?`.
class ChatQuotaSnapshot {
  const ChatQuotaSnapshot({
    required this.used,
    required this.remaining,
    required this.dailyLimit,
    this.limitAssumed = false,
  });

  final int used;
  final int remaining;
  final int dailyLimit;

  /// True when [dailyLimit] is the client's own assumption, not a number the
  /// server named.
  ///
  /// `get_chat_quota_today` derives `remaining` from the limit the CALLER
  /// passes in and echoes it back, so its answer is display arithmetic, not a
  /// statement about `COACH_DAILY_LIMIT`. With a server limit of 10 it reports
  /// `remaining = 0` after five slots and would lock a composer the server
  /// still accepts. An assumed limit therefore never blocks — the server
  /// answers 429 if the quota really is gone, and that path locks properly.
  final bool limitAssumed;

  /// Daily limit assumed until the server names one, and the value requested
  /// via RPC. Display-only fallback for widgets that need a number; whether the
  /// composer locks depends solely on the snapshot, never on this constant.
  static const int standardTageslimit = 5;

  ChatQuotaSnapshot copyWith({
    int? used,
    int? remaining,
    int? dailyLimit,
    bool? limitAssumed,
  }) {
    return ChatQuotaSnapshot(
      used: used ?? this.used,
      remaining: remaining ?? this.remaining,
      dailyLimit: dailyLimit ?? this.dailyLimit,
      limitAssumed: limitAssumed ?? this.limitAssumed,
    );
  }
}
