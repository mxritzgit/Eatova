import 'package:supabase_flutter/supabase_flutter.dart';

import 'coach_chat_service.dart';
import 'lifetime_stats_sync.dart';
import 'meals_sync.dart';
import 'profile_sync.dart';
import 'tracking_sync.dart';
import 'user_recipes_sync.dart';

/// Bundles alle Supabase-Sync-Services fuer einen einzelnen authentifizierten
/// User. Wird in ShiftFitApp pro User aufgebaut, an die HomePage uebergeben
/// und beim Dispose der Page wieder freigegeben.
///
/// Mit dem Entfernen der Heute-/Training-/Trends-Tabs sind dailyLog,
/// weeklyPlan und workoutLog aus dem Bundle geflogen (Rework spaeter);
/// die Server-Tabellen bleiben unangetastet.
class FitPilotSync {
  FitPilotSync._({
    required this.client,
    required this.profile,
    required this.meals,
    required this.tracking,
    required this.coachChat,
    required this.lifetimeStats,
    required this.userRecipes,
  });

  factory FitPilotSync.forUser(SupabaseClient client, String userId) {
    return FitPilotSync._(
      client: client,
      profile: ProfileSync(client, userId),
      meals: MealsSync(client, userId),
      tracking: TrackingSync(client, userId),
      coachChat: CoachChatService(client, userId),
      lifetimeStats: LifetimeStatsSync(client, userId),
      userRecipes: UserRecipesSync(client, userId),
    );
  }

  final SupabaseClient client;
  final ProfileSync profile;
  final MealsSync meals;
  final TrackingSync tracking;
  final CoachChatService coachChat;
  final LifetimeStatsSync lifetimeStats;
  final UserRecipesSync userRecipes;

  /// DSGVO Art. 17: löscht den auth.users-Eintrag des Users; alle App-Tabellen
  /// cascaden mit. Danach muss der Client ausloggen. Siehe Migration
  /// 20260602120200_delete_account_rpc.sql.
  Future<void> deleteAccount() async {
    await client.rpc('delete_account');
  }

  void dispose() {}
}
