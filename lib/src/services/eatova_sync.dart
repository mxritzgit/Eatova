import 'package:supabase_flutter/supabase_flutter.dart';

import 'coach_chat_service.dart';
import 'lifetime_stats_sync.dart';
import 'meals_sync.dart';
import 'profile_sync.dart';
import 'tracking_sync.dart';
import 'user_recipes_sync.dart';

/// Bundles all Supabase sync services for one authenticated user; built per
/// user in EatovaApp and released when the home page disposes. dailyLog,
/// weeklyPlan and workoutLog left with the removed tabs, server tables stay.
class EatovaSync {
  EatovaSync._({
    required this.client,
    required this.userId,
    required this.profile,
    required this.meals,
    required this.tracking,
    required this.coachChat,
    required this.lifetimeStats,
    required this.userRecipes,
  });

  /// [coachChat] is a test seam: [CoachChatService] talks to an edge function,
  /// not to PostgREST, so a fake PostgREST client cannot stand in for it.
  /// Null (production) builds the real service.
  factory EatovaSync.forUser(
    SupabaseClient client,
    String userId, {
    CoachChatService? coachChat,
  }) {
    return EatovaSync._(
      client: client,
      userId: userId,
      profile: ProfileSync(client, userId),
      meals: MealsSync(client, userId),
      tracking: TrackingSync(client, userId),
      coachChat: coachChat ?? CoachChatService(client, userId),
      lifetimeStats: LifetimeStatsSync(client, userId),
      userRecipes: UserRecipesSync(client, userId),
    );
  }

  final SupabaseClient client;

  /// The user this bundle was built for; the same id every sub-service uses
  /// as its RLS filter.
  final String userId;
  final ProfileSync profile;
  final MealsSync meals;
  final TrackingSync tracking;
  final CoachChatService coachChat;
  final LifetimeStatsSync lifetimeStats;
  final UserRecipesSync userRecipes;

  /// GDPR Art. 17: deletes the user's auth.users row, app tables cascade, and
  /// the client must log out afterwards. Not freely movable — the RPC needs a
  /// JWT whose `amr` claim holds an 'otp'/'recovery' entry younger than five
  /// minutes, which `verifyRecoveryCode` creates right before this call.
  Future<void> deleteAccount() async {
    await client.rpc('delete_account');
  }

  void dispose() {}
}
