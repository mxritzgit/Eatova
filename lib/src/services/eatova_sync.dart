import 'package:supabase_flutter/supabase_flutter.dart';

import 'coach_chat_service.dart';
import 'lifetime_stats_sync.dart';
import 'meals_sync.dart';
import 'profile_sync.dart';
import 'tracking_sync.dart';
import 'user_recipes_sync.dart';

/// Bundles alle Supabase-Sync-Services fuer einen einzelnen authentifizierten
/// User. Wird in EatovaApp pro User aufgebaut, an die HomePage uebergeben
/// und beim Dispose der Page wieder freigegeben.
///
/// Mit dem Entfernen der Heute-/Training-/Trends-Tabs sind dailyLog,
/// weeklyPlan und workoutLog aus dem Bundle geflogen (Rework spaeter);
/// die Server-Tabellen bleiben unangetastet.
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

  factory EatovaSync.forUser(SupabaseClient client, String userId) {
    return EatovaSync._(
      client: client,
      userId: userId,
      profile: ProfileSync(client, userId),
      meals: MealsSync(client, userId),
      tracking: TrackingSync(client, userId),
      coachChat: CoachChatService(client, userId),
      lifetimeStats: LifetimeStatsSync(client, userId),
      userRecipes: UserRecipesSync(client, userId),
    );
  }

  final SupabaseClient client;

  /// Der User, fuer den dieses Bundle gebaut wurde — dieselbe Kennung, die
  /// alle Sub-Services als RLS-Filter verwenden (u.a. fuer DataExportService).
  final String userId;
  final ProfileSync profile;
  final MealsSync meals;
  final TrackingSync tracking;
  final CoachChatService coachChat;
  final LifetimeStatsSync lifetimeStats;
  final UserRecipesSync userRecipes;

  /// DSGVO Art. 17: löscht den auth.users-Eintrag des Users; alle App-Tabellen
  /// cascaden mit. Danach muss der Client ausloggen. Siehe Migrationen
  /// 20260602120200_delete_account_rpc.sql (Erstfassung),
  /// 20260603100000_security_hardening_followup.sql (auth.uid()-Guard) und
  /// 20260815120000_delete_account_reauth.sql.
  ///
  /// Die letzte ist der Grund, warum dieser Aufruf NICHT beliebig verschiebbar
  /// ist: der RPC verlangt ein JWT mit einem 'otp'/'recovery'-Eintrag im
  /// `amr`-Claim, der juenger als 5 Minuten ist, und antwortet sonst mit
  /// `EX_REAUTH_REQUIRED` (SQLSTATE 28000, HTTP 403). Genau so eine Sitzung
  /// legt `verifyRecoveryCode` unmittelbar vor dem Aufruf an; den Fehlerfall
  /// uebersetzt `deleteAccountErrorMessage` (sync_error_messages.dart).
  Future<void> deleteAccount() async {
    await client.rpc('delete_account');
  }

  void dispose() {}
}
