// Android may kill Eatova while the system camera or gallery is in front.
// image_picker then finishes the pick in the next process with nobody
// waiting: it keeps the full-size photo, EXIF and GPS included, in the app
// cache and only stores its path for retrieveLostData. Nothing in the app
// asked for it or swept the cache, so the photo outlived sign-out and
// account deletion.
//
// Pinned: the lost photo, its resized copy and older picker leftovers go;
// other files in the cache stay; nothing happens off Android; and the auth
// gate runs the cleanup at cold start and on every session end.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:eatova/src/app/auth_gate.dart';
import 'package:eatova/src/auth/auth_repository.dart';
import 'package:eatova/src/l10n/l10n.dart';
import 'package:eatova/src/services/meal_photo_temp_file.dart';
import 'package:eatova/src/services/recipe_image_store.dart';
import 'package:eatova/src/theme/app_theme.dart';

/// Answers getLostData like the plugin after a process death.
class _LostPicker extends ImagePickerPlatform with MockPlatformInterfaceMixin {
  _LostPicker(this.answer);

  final Future<LostDataResponse> Function() answer;
  int lostCalls = 0;

  @override
  Future<LostDataResponse> getLostData() {
    lostCalls++;
    return answer();
  }
}

class _ScriptedAuthRepository implements AuthRepository {
  _ScriptedAuthRepository(this._user);

  EatovaUser? _user;
  final _controller = StreamController<EatovaUser?>.broadcast();

  void emit(EatovaUser? user) {
    _user = user;
    _controller.add(user);
  }

  void dispose() => _controller.close();

  @override
  EatovaUser? get currentUser => _user;

  @override
  Stream<EatovaUser?> get authStateChanges => _controller.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoPhotos extends RecipeImageStore {
  @override
  Future<void> setActiveUser(String? userId, {String? sessionId}) async {}
}

const _uuid = '1c9e2f4a-7b3d-4e5f-8a6c-0d2e4f6a8b1c';
const _olderUuid = '7a2b4c6d-8e0f-4a1b-9c3d-5e7f9a1b3c5d';
const _galleryUuid = '0f6c2a5e-3b1d-4c8e-9a7f-2d4b6e8a1c3f';
const _otherUuid = '8a1c3f0f-6c2a-4e3b-9d4c-8e9a7f2d4b6e';

void main() {
  late Directory cache;

  String inCache(String name) => '${cache.path}${Platform.pathSeparator}$name';

  File write(String name) => File(inCache(name))
    ..createSync(recursive: true)
    ..writeAsBytesSync(const <int>[0xFF, 0xD8, 0xFF]);

  setUp(() {
    cache = Directory.systemTemp.createTempSync('eatova_lost_picker');
  });

  tearDown(() {
    if (cache.existsSync()) cache.deleteSync(recursive: true);
  });

  group('discardLostPickerMedia', () {
    test(
      'die verlorene Aufnahme, ihre Kopie und alte Reste sind weg',
      () async {
        // The lost camera capture and the copy reading it just wrote.
        final capture = write('${_uuid}4471893001.jpg');
        final scaled = write('scaled_${_uuid}4471893001.jpg');
        // Left by an earlier loss whose stored path a later pick cleared.
        final olderCapture = write('$_olderUuid-822.jpg');
        final olderScaled = write('scaled_IMG_0412.jpg');
        final galleryCopy = write('$_galleryUuid/IMG_0412.heic');
        // Not the picker's.
        final recording = write('describe_voice.m4a');
        final ownName = write('IMG_0999.jpg');
        final cameraPlugin = write('CAP2387612.jpg');
        final foreignInUuid = write('$_otherUuid/notes.txt');
        final picker = _LostPicker(
          () async => LostDataResponse(
            file: XFile(scaled.path),
            files: [XFile(scaled.path)],
            type: RetrieveType.image,
          ),
        );
        ImagePickerPlatform.instance = picker;

        await discardLostPickerMedia(
          onAndroid: true,
          cacheDirectory: () async => cache,
        );

        expect(picker.lostCalls, 1);
        for (final gone in [capture, scaled, olderCapture, olderScaled]) {
          expect(gone.existsSync(), isFalse, reason: gone.path);
        }
        expect(galleryCopy.existsSync(), isFalse);
        expect(Directory(inCache(_galleryUuid)).existsSync(), isFalse);
        for (final kept in [recording, ownName, cameraPlugin, foreignInUuid]) {
          expect(kept.existsSync(), isTrue, reason: kept.path);
        }
      },
    );

    test('ohne verlorene Auswahl fegt sie trotzdem', () async {
      final orphan = write('scaled_${_uuid}4471893001.jpg');
      ImagePickerPlatform.instance = _LostPicker(
        () async => LostDataResponse.empty(),
      );

      await discardLostPickerMedia(
        onAndroid: true,
        cacheDirectory: () async => cache,
      );

      expect(orphan.existsSync(), isFalse);
    });

    test('ausserhalb von Android passiert nichts', () async {
      final capture = write('${_uuid}4471893001.jpg');
      final picker = _LostPicker(() async => LostDataResponse.empty());
      ImagePickerPlatform.instance = picker;

      await discardLostPickerMedia(
        onAndroid: false,
        cacheDirectory: () async => cache,
      );

      expect(picker.lostCalls, 0);
      expect(capture.existsSync(), isTrue);
    });

    test('ohne Plugin und ohne Cache-Ordner wirft sie nicht', () async {
      ImagePickerPlatform.instance = _LostPicker(
        () => Future<LostDataResponse>.error(StateError('no plugin')),
      );

      await expectLater(
        discardLostPickerMedia(
          onAndroid: true,
          cacheDirectory: () => Future<Directory>.error(StateError('no dir')),
        ),
        completes,
      );
    });
  });

  group('AuthGate', () {
    setUp(() => RecipeImageStore.instance = _NoPhotos());
    tearDown(RecipeImageStore.resetInstance);

    testWidgets('raeumt beim Kaltstart und bei jedem Sitzungsende auf', (
      tester,
    ) async {
      var runs = 0;
      const user = EatovaUser(
        id: 'user-a',
        email: 'a@example.com',
        sessionId: 's1',
      );
      final repository = _ScriptedAuthRepository(user);
      addTearDown(repository.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildEatovaTheme(Brightness.dark),
          locale: const Locale('de'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: AuthGate(
            authRepository: repository,
            debugPurgeCache: (_) async {},
            discardPickerMedia: () async => runs++,
            builder: (context, user, _) =>
                Scaffold(body: Text('home ${user.id}')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(runs, 1, reason: 'cold start, before any pick');

      // A token refresh is no session end.
      repository.emit(user);
      await tester.pumpAndSettle();
      expect(runs, 1);

      repository.emit(null);
      await tester.pumpAndSettle();
      expect(runs, 2, reason: 'sign-out, session loss, account deletion');
    });
  });
}
