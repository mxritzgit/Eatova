import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/app/shiftfit_app.dart';
import 'src/config/supabase_config.dart';
import 'src/services/apple_health_service.dart';
import 'src/services/notification_service.dart';

export 'src/app/shiftfit_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Die Layouts sind nur fuer Hochformat ausgelegt — Rotation ist deshalb
  // app-weit deaktiviert (Handy UND Tablet). Auf iOS greift zusaetzlich das
  // Portrait-only-Set in ios/Runner/Info.plist; Desktop/Web ignorieren
  // setPreferredOrientations ohnehin (No-Op).
  SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
  try {
    await FitPilotSupabaseConfig.initialize();
  } catch (error, stack) {
    // Ohne den Catch wuerde ein Boot-Fehler (fehlende --dart-define-Werte,
    // unerreichbares Supabase, …) vor runApp landen und iOS bliebe auf dem
    // weissen Launch-Screen haengen. Lieber sichtbar fehlschlagen.
    debugPrint('FitPilot boot failed: $error\n$stack');
    runApp(_BootErrorApp(error: error));
    return;
  }
  // PROD-1: echte on-device-Notification-Schicht nur in Production injizieren.
  // LocalNotificationService ist plattform-gegated (Noop ausserhalb iOS/Android),
  // ein Konstruktor-Aufruf hier ist also auch auf Desktop/Web gefahrlos. Tests
  // konstruieren ShiftFitApp ohne diesen Parameter -> NoopNotificationService.
  runApp(ShiftFitApp(
    healthService: AppleHealthService(),
    notificationService: LocalNotificationService(),
  ));
}

class _BootErrorApp extends StatelessWidget {
  const _BootErrorApp({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'FitPilot',
      home: Scaffold(
        backgroundColor: const Color(0xFF111114),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.error_outline,
                  color: Color(0xFFFF5C5C),
                  size: 56,
                ),
                const SizedBox(height: 16),
                const Text(
                  'FitPilot konnte nicht starten',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  '$error',
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Build braucht SUPABASE_URL + SUPABASE_ANON_KEY via\n'
                  '--dart-define-from-file=dart_defines.json.\n'
                  'Vorlage: dart_defines.example.json, Details: README.md.',
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
