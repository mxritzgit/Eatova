import 'dart:convert';

import 'package:eatova/main.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/services/eatova_sync.dart';
import 'package:eatova/src/services/notification_service.dart';
import 'package:eatova/src/services/secure_cache_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase/supabase.dart';

class _ConfirmationAuth extends InMemoryAuthRepository {
  final registrations = <({String email, String password, String name})>[];

  @override
  Future<SignUpOutcome> signUp({
    required String email,
    required String password,
    required String displayName,
  }) async {
    registrations.add((email: email, password: password, name: displayName));
    return SignUpOutcome.created;
  }

  @override
  Future<void> verifySignupCode({
    required String email,
    required String code,
  }) async {
    verifiedCodes.add('$email:$code');
    await super.signIn(email: email, password: 'synthetic-confirmation');
  }
}

class _NotificationSpy extends NoopNotificationService {
  int permissionRequests = 0;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return false;
  }
}

Future<void> _drain(WidgetTester tester, [int frames = 30]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await _drain(tester);
}

void main() {
  setUpAll(() async {
    for (final family in {
      'Archivo': [
        'Archivo-Regular.ttf',
        'Archivo-Medium.ttf',
        'Archivo-SemiBold.ttf',
        'Archivo-Bold.ttf',
      ],
      'BricolageGrotesque': [
        'BricolageGrotesque-Bold.ttf',
        'BricolageGrotesque-ExtraBold.ttf',
      ],
      'MaterialIcons': ['MaterialIcons-Regular.otf'],
    }.entries) {
      final loader = FontLoader(family.key);
      for (final file in family.value) {
        loader.addFont(
          rootBundle.load(
            family.key == 'MaterialIcons'
                ? 'fonts/$file'
                : 'assets/fonts/$file',
          ),
        );
      }
      await loader.load();
    }
  });

  testWidgets(
    'signup confirmation, onboarding save and returning login share one account',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      // Exercise server persistence with explicitly unavailable native storage.
      // Unmocked keystore I/O never resolves in a widget's fake-async zone.
      CacheKeyProvider.debugReset();
      addTearDown(CacheKeyProvider.debugReset);
      const secureStorage = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        secureStorage,
        (_) async => throw PlatformException(code: 'keystore-unavailable'),
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          secureStorage,
          null,
        ),
      );
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );

      final auth = _ConfirmationAuth();
      final notifications = _NotificationSpy();
      Map<String, dynamic>? savedProfile;
      var profileWrites = 0;
      final transport = MockClient((request) async {
        Object response = <dynamic>[];
        if (request.url.path.endsWith('/profiles')) {
          if (request.method == 'POST') {
            final decoded = jsonDecode(request.body);
            savedProfile = Map<String, dynamic>.from(
              decoded is List ? decoded.single as Map : decoded as Map,
            );
            profileWrites++;
            response = savedProfile!;
          } else if (savedProfile != null) {
            expect(request.url.queryParameters['id'], 'eq.test-user');
            response = [savedProfile!];
          }
        }
        return http.Response(
          jsonEncode(response),
          200,
          headers: const {'Content-Type': 'application/json'},
          request: request,
        );
      });
      final client = SupabaseClient(
        'https://ci.invalid',
        'ci-dummy-key',
        httpClient: transport,
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await _drain(tester);
        auth.dispose();
        // Supabase's isolate disposal hangs across the widget fake-async zone.
        // Auto-refresh is disabled and the injected transport owns no sockets.
        transport.close();
      });

      await tester.pumpWidget(
        EatovaApp(
          authRepository: auth,
          notificationService: notifications,
          syncBuilder: (userId) => EatovaSync.forUser(client, userId),
        ),
      );
      await _drain(tester);
      await _tap(tester, 'auth-toggle-register');
      await tester.enterText(
        find.byKey(const ValueKey('auth-name-field')),
        'Alex',
      );
      await tester.enterText(
        find.byKey(const ValueKey('auth-email-field')),
        'alex@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('auth-password-field')),
        'synthetic-password-123',
      );
      await _tap(tester, 'auth-submit');
      expect(auth.registrations, [
        (
          email: 'alex@example.com',
          password: 'synthetic-password-123',
          name: 'Alex',
        ),
      ]);
      expect(auth.currentUser, isNull);
      expect(find.byKey(const ValueKey('auth-code-screen')), findsOneWidget);
      expect(find.byKey(const ValueKey('screen-onboarding')), findsNothing);
      expect(profileWrites, 0);

      await tester.enterText(
        find.byKey(const ValueKey('code-field')),
        '12345678',
      );
      await _tap(tester, 'code-primary');
      await _drain(tester, 90);
      expect(auth.verifiedCodes, ['alex@example.com:12345678']);
      expect(find.byKey(const ValueKey('screen-onboarding')), findsOneWidget);
      expect(find.byKey(const ValueKey('screen-today')), findsNothing);

      await _tap(tester, 'onboarding-sex-female');
      await _tap(tester, 'onboarding-next');
      await _tap(tester, 'onboarding-weight-inc');
      await _tap(tester, 'onboarding-next');
      await _tap(tester, 'onboarding-activity-moderate');
      await _tap(tester, 'onboarding-next');
      await _tap(tester, 'onboarding-goal-lose');
      await _tap(tester, 'onboarding-next');
      await _tap(tester, 'onboarding-diet-vegetarian');
      await _tap(tester, 'onboarding-next');
      expect(
        find.byKey(const ValueKey('onboarding-step-summary')),
        findsOneWidget,
      );
      expect(profileWrites, 0, reason: 'A draft cannot complete the account.');
      await _tap(tester, 'onboarding-finish');
      await _drain(tester, 90);
      expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);
      expect(profileWrites, 1);
      expect(savedProfile!['id'], 'test-user');
      expect(savedProfile!['onboarding_completed'], isTrue);
      expect(savedProfile!['sex'], 'female');
      expect(savedProfile!['activity_level'], 'moderate');
      expect(savedProfile!['diet_preference'], 'vegetarian');
      expect(savedProfile!['daily_kcal_goal'], greaterThan(0));
      expect(notifications.permissionRequests, 0);

      await auth.signOut();
      await _drain(tester, 60);
      expect(find.byKey(const ValueKey('screen-auth')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('auth-email-field')),
        'alex@example.com',
      );
      await tester.enterText(
        find.byKey(const ValueKey('auth-password-field')),
        'synthetic-password-123',
      );
      await _tap(tester, 'auth-submit');
      await _drain(tester, 90);
      expect(find.byKey(const ValueKey('screen-today')), findsOneWidget);
      expect(find.byKey(const ValueKey('screen-onboarding')), findsNothing);
      expect(auth.registrations, hasLength(1));
      expect(profileWrites, 1);
      expect(notifications.permissionRequests, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
