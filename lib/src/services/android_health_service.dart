import 'dart:developer' as dev;

import 'package:clock/clock.dart';
import 'package:flutter/services.dart';
import 'package:health/health.dart';

import 'health_service.dart';

/// Plugin boundary: tests exercise the real service with controlled I/O.
abstract interface class HealthConnectAdapter {
  Future<HealthConnectSdkStatus?> availability();
  Future<bool?> hasStepsPermission();
  Future<bool?> hasWeightPermission();

  /// Health Connect's screen for steps and weight READ; each can be granted
  /// on its own there.
  Future<void> requestPermissions();

  /// Health Connect's screen for weight READ alone (the scale import).
  Future<void> requestWeightPermission();
  Future<int?> aggregateSteps(DateTime start, DateTime end);

  /// Weight records between [start] and [end]; empty without the grant.
  Future<List<WeightSample>> readWeights(DateTime start, DateTime end);
  Future<void> installOrUpdate();
  Future<void> openSettings();
}

class PluginHealthConnectAdapter implements HealthConnectAdapter {
  PluginHealthConnectAdapter({Health? health, MethodChannel? channel})
    : _health = health ?? Health(),
      _channel = channel ?? const MethodChannel('eatova/health_connect');

  final Health _health;
  final MethodChannel _channel;
  static const _types = [HealthDataType.STEPS, HealthDataType.WEIGHT];
  static const _permissions = [HealthDataAccess.READ, HealthDataAccess.READ];

  @override
  Future<HealthConnectSdkStatus?> availability() =>
      _health.getHealthConnectSdkStatus();

  @override
  Future<bool?> hasStepsPermission() =>
      _channel.invokeMethod<bool>('hasStepsPermission');

  @override
  Future<bool?> hasWeightPermission() =>
      _channel.invokeMethod<bool>('hasWeightPermission');

  @override
  Future<void> requestPermissions() async {
    await _health.requestAuthorization(_types, permissions: _permissions);
  }

  @override
  Future<void> requestWeightPermission() async {
    await _health.requestAuthorization(
      const [HealthDataType.WEIGHT],
      permissions: const [HealthDataAccess.READ],
    );
  }

  @override
  Future<int?> aggregateSteps(DateTime start, DateTime end) =>
      _channel.invokeMethod<int>('aggregateSteps', {
        'startTime': start.millisecondsSinceEpoch,
        'endTime': end.millisecondsSinceEpoch,
      });

  @override
  Future<List<WeightSample>> readWeights(DateTime start, DateTime end) async {
    final points = await _health.getHealthDataFromTypes(
      types: const [HealthDataType.WEIGHT],
      startTime: start,
      endTime: end,
    );
    return <WeightSample>[
      for (final p in points)
        if (p.value is NumericHealthValue)
          WeightSample(
            kg: (p.value as NumericHealthValue).numericValue.toDouble(),
            measuredAt: p.dateFrom,
          ),
    ]..sort((a, b) => a.measuredAt.compareTo(b.measuredAt));
  }

  @override
  Future<void> installOrUpdate() =>
      _channel.invokeMethod<void>('installOrUpdate');

  @override
  Future<void> openSettings() => _channel.invokeMethod<void>('openSettings');
}

/// Foreground, read-only steps, and weight for the scale import. Nothing is
/// written to Health Connect.
class AndroidHealthService
    implements HealthService, HealthConnectAccess, HealthWeightSource {
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
        // Installed or updated meanwhile: the card must not ask for it again.
        if (_state == HealthAuthState.updateRequired ||
            _state == HealthAuthState.unavailable) {
          _state = HealthAuthState.unknown;
        }
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
        final request = _permissionRequest ??= _adapter.requestPermissions();
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

  /// Weigh-ins for the scale import, only for an account connected in this
  /// session. Without the weight grant there is nothing to read (an empty
  /// answer); a failure is null and leaves the steps state alone.
  @override
  Future<List<WeightSample>?> readWeightSamples(
    DateTime from,
    DateTime to,
  ) async {
    final generation = _generation;
    if (!_connectedForSession) return null;
    try {
      if (!await _available(generation)) return null;
      final granted = await _adapter.hasWeightPermission();
      if (!_current(generation)) return null;
      if (granted != true) return granted == false ? const [] : null;
      final samples = await _adapter.readWeights(from, to);
      return _current(generation) ? samples : null;
    } catch (_) {
      // Plugin/platform messages can contain sensitive records. Never log them.
      dev.log('Health Connect weight read failed', name: 'health_connect');
      return null;
    }
  }

  /// Weight has its own grant in Health Connect: an account that connected
  /// steps before the scale import asks for it once here.
  @override
  Future<bool> ensureWeightAccess() async {
    final generation = _generation;
    if (!_connectedForSession || _permissionRequest != null) return false;
    try {
      if (!await _available(generation)) return false;
      if (await _adapter.hasWeightPermission() == true) {
        return _current(generation);
      }
      if (!_current(generation)) return false;
      final request = _permissionRequest = _adapter.requestWeightPermission();
      try {
        await request;
      } finally {
        if (identical(_permissionRequest, request)) _permissionRequest = null;
      }
      return _current(generation) &&
          await _adapter.hasWeightPermission() == true &&
          _current(generation);
    } catch (_) {
      dev.log('Health Connect weight access failed', name: 'health_connect');
      return false;
    }
  }

  @override
  Future<bool> writeWeight(double kg, DateTime when) async => false;
}
