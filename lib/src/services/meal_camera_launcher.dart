import 'dart:typed_data';

import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';

import '../models/logged_meal.dart' show MealSlot;
import '../models/meal_analysis_request.dart';
import '../screens/meal_camera_sheet.dart';
import '../theme/app_tokens.dart';

/// Sends the user to the app's system settings page after a denied camera
/// permission (F4-04). Never throws: without the plugin (tests, desktop) the
/// tap is a no-op.
Future<void> openAppSettingsForCamera() async {
  try {
    await AppSettings.openAppSettings();
  } catch (_) {
    // MissingPluginException / PlatformException: nothing to open here.
  }
}

/// Result of the in-app camera: the analysis request (image), a preview for
/// the result sheet, and the slot chosen in the camera screen.
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

/// Starts the photo capture flow for the AI scan. Abstracted so widget tests
/// can swap the untestable camera screen for a fake; like [MealPhotoInput],
/// but including slot selection.
abstract class MealCameraLauncher {
  Future<MealCameraCapture?> launch(
    BuildContext context, {
    required MealSlot initialSlot,
  });
}

/// Production implementation: shows the in-app camera as a bottom panel
/// (~60% height, no full-screen transition) and returns its
/// [MealCameraCapture], or null when cancelled.
class InAppMealCameraLauncher implements MealCameraLauncher {
  const InAppMealCameraLauncher();

  @override
  Future<MealCameraCapture?> launch(
    BuildContext context, {
    required MealSlot initialSlot,
  }) {
    return showModalBottomSheet<MealCameraCapture>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: context.t.scrim,
      builder: (_) => MealCameraSheet(initialSlot: initialSlot),
    );
  }
}
