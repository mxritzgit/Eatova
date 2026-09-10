import 'dart:developer' as dev;

import 'package:clock/clock.dart';
import 'package:flutter/services.dart';
import 'package:health/health.dart';

import 'health_service.dart';

/// Plugin boundary: tests exercise the real service with controlled I/O.
abstract interface class HealthConnectAdapter {
  Future<HealthConnectSdkStatus?> availability();
  Future<bool?> hasStepsPermission();
  Future<void> requestStepsPermission();
  Future<int?> aggregateSteps(DateTime start, DateTime end);
  Future<void> installOrUpdate();
  Future<void> openSettings();
}

class PluginHealthConnectAdapter implements HealthConnectAdapter {
  PluginHealthConnectAdapter({Health? health, MethodChannel? channel})
    : _health = health ?? Health(),
      _channel = channel ?? const MethodChannel('eatova/health_connect');

  final Health _health;
  final MethodChannel _channel;
  static const _types = [HealthDataType.STEPS];
  static const _permissions = [HealthDataAccess.READ];

  @override
  Future<HealthConnectSdkStatus?> availability() =>
      _health.getHealthConnectSdkStatus();

  @override
  Future<bool?> hasStepsPermission() =>
      _channel.invokeMethod<bool>('hasStepsPermission');

  @override
  Future<void> requestStepsPermission() async {
    await _health.requestAuthorization(_types, permissions: _permissions);
  }

  @override
  Future<int?> aggregateSteps(DateTime start, DateTime end) =>
      _channel.invokeMethod<int>('aggregateSteps', {
        'startTime': start.millisecondsSinceEpoch,
        'endTime': end.millisecondsSinceEpoch,
      });

  @override
  Future<void> installOrUpdate() =>
      _channel.invokeMethod<void>('installOrUpdate');

  @override
  Future<void> openSettings() => _channel.invokeMethod<void>('openSettings');
}

/// Foreground, read-only steps. No weight scopes or weight writes on Android.
class AndroidHealthService implements HealthService, HealthConnectAccess {
  AndroidHealthService({HealthConnectAdapter? adapter})
    : _adapter = adapter ?? PluginHealthConnectAdapter();

  final HealthConnectAdapter _adapter;
  HealthAuthState _state = HealthAuthState.unknown;
  int _generation = 0;
  bool _connectedForSession = false;
  // The OS prompt survives account changes. Share its in-flight result so a
  // second session cannot overwrite the plugin's single permission callback.
  Future<void>? _permissionRequest;

  @override
  HealthAuthState get authState => _state;

  @override
  void restoreConnection() => _connectedForSession = true;

  @override
  void reset() {
    _generation++;
    _connectedForSession = false;
    _state = HealthAuthState.unknown;
  }

  bool _current(int generation) => generation == _generation;

  Future<bool> _available(int generation) async {
    final status = await _adapter.availability();
    if (!_current(generation)) return false;
    switch (status) {
      case HealthConnectSdkStatus.sdkAvailable:
        return true;
      case HealthConnectSdkStatus.sdkUnavailable:
        _state = HealthAuthState.unavailable;
      case HealthConnectSdkStatus.sdkUnavailableProviderUpdateRequired:
        _state = HealthAuthState.updateRequired;
      case null:
        _state = HealthAuthState.error;
    }
    return false;
  }

  Future<bool> _authorized(int generation) async {
    if (!await _available(generation)) return false;
    final granted = await _adapter.hasStepsPermission();
    if (!_current(generation)) return false;
    if (granted != true) {
      _state = granted == false
          ? HealthAuthState.denied
          : HealthAuthState.error;
      return false;
    }
    return true;
  }

  void _failed(int generation, Object error) {
    if (!_current(generation)) return;
    _state = error is PlatformException && error.code == 'permission_denied'
        ? HealthAuthState.denied
        : HealthAuthState.error;
    // Plugin/platform messages can contain sensitive records. Never log them.
    dev.log('Health Connect operation failed', name: 'health_connect');
  }

  @override
  Future<HealthAuthState> requestAuthorization() async {
    final generation = _generation;
    try {
      if (!await _available(generation)) {
        if (_current(generation) && _state == HealthAuthState.updateRequired) {
          await _adapter.installOrUpdate();
        }
        return _current(generation) ? _state : HealthAuthState.unknown;
      }
      final granted = await _adapter.hasStepsPermission();
      if (!_current(generation)) return HealthAuthState.unknown;
      _connectedForSession = true;
      if (granted != true) {
        final request = _permissionRequest ??= _adapter
            .requestStepsPermission();
        try {
          await request;
        } finally {
          if (identical(_permissionRequest, request)) _permissionRequest = null;
        }
      }
      if (!_current(generation)) return HealthAuthState.unknown;
      if (await _authorized(generation)) {
        _state = HealthAuthState.granted;
      }
    } catch (error) {
      _failed(generation, error);
    }
    return _current(generation) ? _state : HealthAuthState.unknown;
  }

  @override
  Future<HealthSnapshot?> readSnapshot() async {
    final generation = _generation;
    try {
      // Each account explicitly connects. OS permission belongs to the app,
      // so it alone cannot carry the previous account's connection forward.
      if (!_connectedForSession) {
        await _available(generation);
        return null;
      }
      if (!await _authorized(generation)) return null;
      final now = clock.now();
      final start = DateTime(now.year, now.month, now.day);
      final steps = now.isAfter(start)
          ? await _adapter.aggregateSteps(start, now)
          : null;
      if (!_current(generation)) return null;
      // Re-check after reading: a revocation can race the aggregate response.
      if (!await _authorized(generation)) return null;
      if (steps != null && steps < 0) throw StateError('Invalid step count');
      _state = steps == null ? HealthAuthState.noData : HealthAuthState.granted;
      return steps == null
          ? null
          : HealthSnapshot(stepsToday: steps, fetchedAt: now);
    } catch (error) {
      _failed(generation, error);
      return null;
    }
  }

  @override
  Future<int?> readStepsOnDay(DateTime day) async {
    final generation = _generation;
    if (!_connectedForSession) return null;
    final now = clock.now();
    final start = DateTime(day.year, day.month, day.day);
    var end = DateTime(day.year, day.month, day.day + 1);
    if (!start.isBefore(now)) return null;
    if (end.isAfter(now)) end = now;
    try {
      if (!await _authorized(generation)) return null;
      final steps = await _adapter.aggregateSteps(start, end);
      if (!_current(generation) || !await _authorized(generation)) return null;
      return steps != null && steps >= 0 ? steps : null;
    } catch (error) {
      // Default history access is limited to 30 days before the initial grant.
      // A history/read failure must not turn an earlier stored day into zero.
      if (error is PlatformException && error.code == 'permission_denied') {
        // An old date may require the unrequested HISTORY permission while
        // today's READ_STEPS permission is still intact.
        try {
          await _authorized(generation);
        } catch (verificationError) {
          _failed(generation, verificationError);
        }
      }
      return null;
    }
  }

  @override
  Future<bool> openSettings() async {
    final generation = _generation;
    try {
      await _adapter.openSettings();
      return _current(generation);
    } catch (error) {
      _failed(generation, error);
      return false;
    }
  }

  @override
  Future<bool> writeWeight(double kg, DateTime when) async => false;

  @override
  Future<List<WeightSample>> readWeightSamples({
    required DateTime from,
    required DateTime to,
  }) async => const [];
}
