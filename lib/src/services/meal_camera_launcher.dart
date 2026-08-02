import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/logged_meal.dart' show MealSlot;
import '../models/meal_analysis_request.dart';
import '../screens/meal_camera_screen.dart';

/// Ergebnis der In-App-Kamera: das Analyse-Request-Objekt (Bild), eine
/// Vorschau fuer das Ergebnis-Sheet und der vom Nutzer im Kamera-Screen
/// gewaehlte Slot (Fruehstueck/Mittag/…).
class MealCameraCapture {
  const MealCameraCapture({
    required this.request,
    required this.previewBytes,
    required this.slot,
  });

  final MealAnalysisRequest request;
  final Uint8List? previewBytes;
  final MealSlot slot;
}

/// Startet den Foto-Erfassungs-Flow fuer den KI-Scan. Als Abstraktion, damit
/// Widget-Tests den (nicht test-baren) Kamera-Screen durch einen Fake ersetzen
/// koennen — analog zu [MealPhotoInput], aber inklusive Slot-Auswahl.
abstract class MealCameraLauncher {
  Future<MealCameraCapture?> launch(
    BuildContext context, {
    required MealSlot initialSlot,
  });
}

/// Produktions-Implementierung: schiebt den In-App-Kamera-Screen als
/// Vollbild-Route und liefert dessen [MealCameraCapture] zurueck (null bei
/// Abbruch).
class InAppMealCameraLauncher implements MealCameraLauncher {
  const InAppMealCameraLauncher();

  @override
  Future<MealCameraCapture?> launch(
    BuildContext context, {
    required MealSlot initialSlot,
  }) {
    return Navigator.of(context).push<MealCameraCapture>(
      MaterialPageRoute<MealCameraCapture>(
        fullscreenDialog: true,
        builder: (_) => MealCameraScreen(initialSlot: initialSlot),
      ),
    );
  }
}
