import 'package:flutter_test/flutter_test.dart';

import 'package:eatova/src/services/health_service.dart';

void main() {
  group('NoopHealthService (off-iOS + Test-Default ist sicher)', () {
    const noop = NoopHealthService();

    test('reports unsupported + readSnapshot null', () async {
      expect(noop.authState, HealthAuthState.unsupported);
      expect(await noop.requestAuthorization(), HealthAuthState.unsupported);
      expect(await noop.readSnapshot(), isNull);
    });

    test('writeWeight no-ops to false', () async {
      expect(await noop.writeWeight(80.5, DateTime(2026, 6, 4)), isFalse);
    });

    test('readWeightSamples no-ops to empty', () async {
      expect(
        await noop.readWeightSamples(
          from: DateTime(2026, 1, 1),
          to: DateTime(2026, 6, 4),
        ),
        isEmpty,
      );
    });
  });
}
