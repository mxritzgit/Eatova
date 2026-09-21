import 'package:eatova/src/app/eatova_app.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/models/recipe_import_result.dart';
import 'package:eatova/src/screens/recipes/recipe_import_sheet.dart';
import 'package:eatova/src/services/recipe_import_service.dart';
import 'package:eatova/src/services/recipe_share_receiver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'flow_test_helpers.dart' show settleFrames;

class _Service implements RecipeImportService {
  final texts = <String>[];

  @override
  Future<RecipeImportResult> extract(
    String text, {
    required String locale,
  }) async {
    texts.add(text);
    return const RecipeImportResult(
      status: RecipeImportStatus.ready,
      candidates: [
        RecipeImportCandidate(
          id: 'tofu',
          title: 'Tofu-Pasta',
          ingredients: '200 g Pasta\n150 g Tofu',
          preparation: 'Pasta kochen. Tofu braten.',
        ),
      ],
    );
  }
}

void main() {
  for (final cold in [true, false]) {
    testWidgets(
      '${cold ? 'cold' : 'active'} iOS wake uses the bound inbox without a navigation route',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(430, 960);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        const channel = MethodChannel('eatova/recipe_share');
        final messenger = tester.binding.defaultBinaryMessenger;
        final receiver = RecipeShareReceiver(channel: channel);
        final service = _Service();
        final auth = InMemoryAuthRepository(
          initialUser: const EatovaUser(id: 'a', sessionId: 'session-a'),
        );
        addTearDown(auth.dispose);
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final source = {'id': 'wake-source', 'text': 'Shared recipe text'};
        final pending = <Map<String, String>>[if (cold) source];
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect((call.arguments as Map)['owner'], isA<String>());
          if (call.method == 'consumePending') {
            final result = pending.toList();
            pending.clear();
            return result;
          }
          return null;
        });

        await tester.pumpWidget(
          EatovaApp(
            authRepository: auth,
            syncBuilder: (_) => null,
            recipeShareReceiver: receiver,
            recipeImportService: service,
          ),
        );
        await settleFrames(tester);

        Future<void> notifyWake() async {
          await messenger.handlePlatformMessage(
            channel.name,
            channel.codec.encodeMethodCall(const MethodCall('sharesAvailable')),
            null,
          );
          await settleFrames(tester);
        }

        if (!cold) {
          expect(find.byType(RecipeImportSheet), findsNothing);
          pending.add(source);
          // An already active scene may receive the URL without a resume event.
          await notifyWake();
        }
        expect(find.byType(RecipeImportSheet), findsOneWidget);
        expect(service.texts, ['Shared recipe text']);

        // iOS scene connection sends this echo after Flutter's first frame.
        // It must not push a named route or disturb the pending preview.
        for (final location in [
          'eatova-share://import',
          'eatova-share://import?source=not-accepted',
        ]) {
          final reply = await messenger.handlePlatformMessage(
            SystemChannels.navigation.name,
            SystemChannels.navigation.codec.encodeMethodCall(
              MethodCall('pushRouteInformation', {'location': location}),
            ),
            null,
          );
          await settleFrames(tester);
          expect(
            SystemChannels.navigation.codec.decodeEnvelope(reply!),
            isTrue,
          );
          expect(tester.takeException(), isNull);
          expect(find.byType(RecipeImportSheet), findsOneWidget);
        }

        pending.add(source);
        await notifyWake();
        receiver.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await receiver.refresh();
        await settleFrames(tester);
        expect(service.texts, ['Shared recipe text']);
        expect(find.byType(RecipeImportSheet), findsOneWidget);

        await tester.pumpWidget(const SizedBox.shrink());
        await settleFrames(tester);
      },
    );
  }
}
