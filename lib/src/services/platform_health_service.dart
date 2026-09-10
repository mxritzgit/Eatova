import 'package:flutter/foundation.dart';

import 'android_health_service.dart';
import 'apple_health_service.dart';
import 'health_service.dart';

HealthService createPlatformHealthService({TargetPlatform? platform}) {
  if (kIsWeb) return const NoopHealthService();
  return switch (platform ?? defaultTargetPlatform) {
    TargetPlatform.android => AndroidHealthService(),
    TargetPlatform.iOS => AppleHealthService(),
    _ => const NoopHealthService(),
  };
}
