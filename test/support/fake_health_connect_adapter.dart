import 'package:eatova/src/services/android_health_service.dart';
import 'package:health/health.dart';

class FakeHealthConnectAdapter implements HealthConnectAdapter {
  HealthConnectSdkStatus? status = HealthConnectSdkStatus.sdkAvailable;
  bool? permission = true;
  int? steps = 8400;
  int requests = 0;
  int installs = 0;
  int settings = 0;
  int permissionReads = 0;
  final intervals = <({DateTime start, DateTime end})>[];
  Future<void> Function()? onRequest;
  Future<int?> Function()? onAggregate;
  Future<bool?> Function()? onPermission;
  Future<void> Function()? onSettings;

  @override
  Future<HealthConnectSdkStatus?> availability() async => status;

  @override
  Future<bool?> hasStepsPermission() async {
    permissionReads++;
    return onPermission == null ? permission : onPermission!();
  }

  @override
  Future<void> requestStepsPermission() async {
    requests++;
    await onRequest?.call();
  }

  @override
  Future<int?> aggregateSteps(DateTime start, DateTime end) async {
    intervals.add((start: start, end: end));
    return onAggregate == null ? steps : onAggregate!();
  }

  @override
  Future<void> installOrUpdate() async {
    installs++;
  }

  @override
  Future<void> openSettings() async {
    settings++;
    await onSettings?.call();
  }
}
