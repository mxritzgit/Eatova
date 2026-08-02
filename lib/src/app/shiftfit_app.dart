import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_repository.dart';
import '../services/fitpilot_sync.dart';
import '../services/health_service.dart';
import '../services/meal_analyzer.dart';
import '../services/meal_camera_launcher.dart';
import '../services/meal_photo_input.dart';
import '../services/notification_service.dart';
import '../services/open_food_facts_product_service.dart';
import '../theme/app_theme.dart';
import 'auth_gate.dart';
import 'shiftfit_home_page.dart';

class ShiftFitApp extends StatelessWidget {
  const ShiftFitApp({
    super.key,
    this.mealAnalyzer,
    this.productService,
    this.photoInput,
    this.mealCameraLauncher,
    this.healthService,
    this.authRepository,
    this.notificationService,
  });

  final MealAnalyzer? mealAnalyzer;
  final ProductLookupService? productService;
  final MealPhotoInput? photoInput;
  final MealCameraLauncher? mealCameraLauncher;
  final HealthService? healthService;
  final AuthRepository? authRepository;

  /// On-device-Notification-Schicht (PROD-1). In Production die echte
  /// [LocalNotificationService] (s. main.dart); in Tests/Preview null ->
  /// ShiftFitHomePage faellt auf NoopNotificationService zurueck.
  final NotificationService? notificationService;

  @override
  Widget build(BuildContext context) {
    final repository = authRepository ?? defaultAuthRepository();

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'FitPilot',
      theme: buildShiftFitTheme(),
      // A11y: System-Großschrift respektieren, aber deckeln. Die App nutzt
      // viele feste fontSize in fixen Containern (Kalorienring, Bottom-Nav);
      // ungebremste Skalierung (iOS bis 235%) würde sie zerbrechen. 1.3x ist
      // ein verträglicher Kompromiss zwischen Lesbarkeit und Layout-Stabilität.
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(
            textScaler: mq.textScaler.clamp(maxScaleFactor: 1.3),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: AuthGate(
        authRepository: repository,
        builder: (context, user, freshLogin) => ShiftFitHomePage(
          // Key auf user.id pinnen: bei Sign-Out und neuem Login wird die
          // Page komplett neu erstellt (frischer State, eigene Sync-Instanz).
          key: ValueKey('home-${user.id}'),
          mealAnalyzer: mealAnalyzer,
          productService: productService,
          photoInput: photoInput,
          mealCameraLauncher: mealCameraLauncher,
          healthService: healthService,
          notificationService:
              notificationService ?? const NoopNotificationService(),
          initialUserName: user.firstName,
          onSignOut: repository.signOut,
          sync: _syncFor(user.id),
          showWelcome: freshLogin,
        ),
      ),
    );
  }

  FitPilotSync? _syncFor(String userId) {
    // Im Test/Preview (kein Supabase.initialize) wirft instance.client - dann
    // bleibt der Sync null und die Home-Page laeuft mit Defaults weiter.
    try {
      return FitPilotSync.forUser(Supabase.instance.client, userId);
    } catch (_) {
      return null;
    }
  }
}
