import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:supabase/supabase.dart';

import 'package:eatova/src/models/chat_message.dart';
import 'package:eatova/src/models/chat_session.dart';
import 'package:eatova/src/screens/coach/coach_chat_screen.dart';
import 'package:eatova/src/services/coach_chat_service.dart';

import 'support/harness.dart';

// C4 (coach half) — the coach photo left the device unscrubbed:
// `image_picker` scales but copies the metadata back, GPS sub-IFD included,
// and the coach path did not run compressMealPhoto.
//
// Asserted on the only reliable level: the bytes that actually land in
// `imageBase64`. A test that only checks the call would miss a wrongly
// ordered or ineffective fix.

/// GPS tag ids in the `gps` sub-IFD (EXIF spec).
const int _tagGpsLatitude = 0x0002;
const int _tagGpsLongitude = 0x0004;
const int _tagGpsAltitude = 0x0006;

img.IfdValueRational _rationals(List<List<int>> parts) {
  final value = img.IfdValueRational(parts.first[0], parts.first[1]);
  for (final part in parts.skip(1)) {
    value.value.add(img.IfdValueRational(part[0], part[1]).value.first);
  }
  return value;
}

/// Phone JPEG with exactly the container an OEM camera writes with location
/// tagging on (Berlin, Brandenburger Tor).
Uint8List _geotaggedJpeg({int width = 320, int height = 240}) {
  final image = img.Image(width: width, height: height);
  img.fillRect(image,
      x1: 0,
      y1: 0,
      x2: width ~/ 2 - 1,
      y2: height - 1,
      color: img.ColorRgb8(220, 30, 30));
  img.fillRect(image,
      x1: width ~/ 2,
      y1: 0,
      x2: width - 1,
      y2: height - 1,
      color: img.ColorRgb8(30, 30, 220));

  final exif = image.exif;
  exif.imageIfd['Make'] = 'ACME';
  exif.imageIfd['Model'] = 'ACME Phone 12 Pro';
  exif.exifIfd['DateTimeOriginal'] = '2026:08:08 12:34:56';
  exif.exifIfd['BodySerialNumber'] = 'SN-4711-ABCDEF';

  final gps = exif.gpsIfd;
  gps[0x0001] = img.IfdValueAscii('N');
  gps[_tagGpsLatitude] = _rationals(<List<int>>[
    <int>[52, 1],
    <int>[30, 1],
    <int>[5868, 100],
  ]);
  gps[0x0003] = img.IfdValueAscii('E');
  gps[_tagGpsLongitude] = _rationals(<List<int>>[
    <int>[13, 1],
    <int>[22, 1],
    <int>[4032, 100],
  ]);
  gps[_tagGpsAltitude] = img.IfdValueRational(3417, 100);

  return Uint8List.fromList(img.encodeJpg(image, quality: 92));
}

/// Finds the APP1 Exif signature in the raw byte stream — the level that
/// actually leaves the device.
bool _hasExifSegment(Uint8List bytes) {
  const signature = <int>[0x45, 0x78, 0x69, 0x66, 0x00, 0x00];
  for (var i = 0; i + signature.length <= bytes.length; i++) {
    var match = true;
    for (var j = 0; j < signature.length; j++) {
      if (bytes[i + j] != signature[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

/// Fake picker serving an in-memory image and recording the options it was
/// called with. `imageQuality`/`maxWidth` are not cosmetic: without them iOS
/// passes through HEIC, which package:image cannot decode.
class _RecordingPicker extends ImagePicker {
  _RecordingPicker(this.bytes);

  final Uint8List bytes;
  ImageSource? source;
  int? imageQuality;
  double? maxWidth;

  /// Set = the picker HANGS until the test resolves it. Models the seconds the
  /// gallery/camera app spends in the foreground — the window in which the
  /// composer is still free.
  Completer<void>? tor;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    this.source = source;
    this.imageQuality = imageQuality;
    this.maxWidth = maxWidth;
    await tor?.future;
    return XFile.fromData(
      bytes,
      mimeType: 'image/jpeg',
      name: 'foto.jpg',
      path: 'foto.jpg',
    );
  }
}

/// CoachChatService without network: every method overridden, the client is
/// never used. `stopAutoRefresh()` is mandatory — GoTrue starts a periodic
/// timer in its constructor that fails every widget test.
class _CapturingService extends CoachChatService {
  _CapturingService(super.client, super.userId);

  String? sentImageBase64;
  String? sentMimeType;
  int sendCalls = 0;

  /// Set = `send()` HANGS, so a request stays in flight while the test does
  /// something else.
  Completer<CoachChatReply>? tor;

  /// Set = `send()` throws this instead of answering.
  Object? fehler;

  static _CapturingService create() {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-anon-key',
      httpClient: MockClient((req) async => http.Response('[]', 200)),
    );
    client.auth.stopAutoRefresh();
    return _CapturingService(client, 'user-123');
  }

  @override
  Future<List<ChatSession>> loadSessions() async => const <ChatSession>[];

  @override
  Future<String?> ensureDefaultSession() async => 's1';

  @override
  Future<List<ChatMessage>> loadHistory(String sessionId, {int limit = 100}) async =>
      const <ChatMessage>[];

  @override
  Future<ChatQuotaSnapshot> loadQuotaToday() async =>
      const ChatQuotaSnapshot(used: 0, remaining: 5, dailyLimit: 5);

  @override
  Future<CoachChatReply> send(
    String message, {
    required String sessionId,
    String? imageBase64,
    String? imageMimeType,
    String? userContext,
    void Function(String text)? onPartialReply,
  }) async {
    sendCalls++;
    sentImageBase64 = imageBase64;
    sentMimeType = imageMimeType;
    final abbruch = fehler;
    if (abbruch != null) throw abbruch;
    final gate = tor;
    if (gate != null) return gate.future;
    return CoachChatReply(
      reply: 'Sieht nach einer soliden Mahlzeit aus.',
      refusal: false,
      remaining: 4,
      sessionId: sessionId,
    );
  }
}

Future<void> _pumpCoach(
  WidgetTester tester, {
  required CoachChatService service,
  required ImagePicker picker,
}) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = const Size(402, 781) * 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await pumpLocalized(
    tester,
    CoachChatScreen(
      service: service,
      userName: 'Moritz',
      imagePicker: picker,
    ),
    safeArea: false,
    settle: true,
  );
}

/// Triggers the gallery path and waits REAL time: compression runs via
/// `compute()` in a real isolate, which the widget test's fake clock never
/// reaches.
Future<void> _sendFromGallery(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('coach-attach')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('coach-gallery')));
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(seconds: 2)),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('Fixture-Vorbedingung: das Test-JPEG traegt die Koordinaten wirklich',
      () {
    final original = _geotaggedJpeg();
    expect(_hasExifSegment(original), isTrue);
    final decoded = img.decodeImage(original)!;
    expect(decoded.exif.gpsIfd[_tagGpsLatitude]!.toDouble(), closeTo(52, 0.01));
    expect(decoded.exif.gpsIfd[_tagGpsLongitude]!.toDouble(), closeTo(13, 0.01));
  });

  testWidgets('Coach-Bild verlaesst das Geraet ohne EXIF-Segment',
      (tester) async {
    final service = _CapturingService.create();
    final picker = _RecordingPicker(_geotaggedJpeg());
    await _pumpCoach(tester, service: service, picker: picker);

    await _sendFromGallery(tester);

    expect(service.sendCalls, 1);
    expect(service.sentImageBase64, isNotNull);
    final sent = Uint8List.fromList(base64Decode(service.sentImageBase64!));

    // Byte level: no APP1 Exif container left.
    expect(_hasExifSegment(sent), isFalse);

    // Decoded: not a single GPS tag, no device identity.
    final decoded = img.decodeImage(sent);
    expect(decoded, isNotNull);
    expect(decoded!.exif.gpsIfd.keys, isEmpty);
    expect(decoded.exif.isEmpty, isTrue);

    // The subject survives — the scrub must not destroy the image.
    expect(decoded.width, 320);
    expect(decoded.height, 240);
  });

  testWidgets('mitgeschickter MIME-Typ passt zu den gescrubbten Bytes',
      (tester) async {
    final service = _CapturingService.create();
    final picker = _RecordingPicker(_geotaggedJpeg());
    await _pumpCoach(tester, service: service, picker: picker);

    await _sendFromGallery(tester);

    expect(service.sentMimeType, 'image/jpeg');
  });

  testWidgets('Picker behaelt imageQuality/maxWidth — sonst laeuft der Scrubber '
      'auf HEIC ins Leere', (tester) async {
    final service = _CapturingService.create();
    final picker = _RecordingPicker(_geotaggedJpeg());
    await _pumpCoach(tester, service: service, picker: picker);

    await _sendFromGallery(tester);

    expect(picker.source, ImageSource.gallery);
    expect(picker.imageQuality, isNotNull);
    expect(picker.maxWidth, isNotNull);
  });

  testWidgets(
      'das zurueckkehrende Foto draengelt sich nicht neben eine laufende '
      'Anfrage — sonst kostet eine Geste zwei Tagesslots', (tester) async {
    // Der einzige Weg, auf dem ein zweiter Request ueberhaupt losgehen kann:
    // `_pickAndSendImage` prueft `_canInteract` VOR dem Picker, und der steht
    // sekundenlang im Vordergrund. Der Composer bleibt derweil frei (nichts
    // laeuft), also kann die getippte Frage vorher rausgehen — der Schutz
    // dagegen sitzt allein in `_send` selbst. Der Sendeknopf ist danach
    // gesperrt und deckt genau diesen Weg NICHT ab.
    final service = _CapturingService.create()
      ..tor = Completer<CoachChatReply>();
    final picker = _RecordingPicker(_geotaggedJpeg())..tor = Completer<void>();
    await _pumpCoach(tester, service: service, picker: picker);

    // 1. Der Bildweg startet und wartet auf die Galerie.
    await tester.tap(find.byKey(const ValueKey('coach-attach')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('coach-gallery')));
    await tester.pumpAndSettle();
    expect(service.sendCalls, 0);

    // 2. Waehrenddessen geht eine getippte Frage raus — erlaubt, es laeuft ja
    //    noch nichts.
    await tester.enterText(
        find.byKey(const ValueKey('coach-input')), 'Kurz vorher gefragt');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('coach-send')));
    await tester.pumpAndSettle();
    expect(service.sendCalls, 1, reason: 'die getippte Frage ist unterwegs');
    expect(service.sentImageBase64, isNull);

    // 3. Erst jetzt kommt das Foto zurueck. Der Scrubber laeuft ueber
    //    `compute()` in einem echten Isolate, das die Fake-Uhr nie erreicht.
    picker.tor!.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pumpAndSettle();

    expect(service.sendCalls, 1,
        reason: 'zwei parallele Anfragen sind zwei der fuenf Tagesslots fuer '
            'eine einzige Nutzergeste');
    expect(service.sentImageBase64, isNull,
        reason: 'nicht nur die Zahl: der Bild-Request darf gar nicht erst '
            'aufgesetzt worden sein');

    // Aufraeumen: das offene Future darf nicht ins Test-Ende haengen.
    service.tor!.complete(
      const CoachChatReply(reply: 'Alles klar.', refusal: false, sessionId: 's1'),
    );
    await tester.pumpAndSettle();
  });

  testWidgets(
      'ist das Kontingent waehrend des Pickers verbraucht, geht das Foto nicht '
      'mehr raus', (tester) async {
    // Zweite Sperre auf demselben Weg: `_pickAndSendImage` hat seinen
    // Kontingent-Check schon hinter sich, und der gesperrte Composer haelt nur
    // NEUE Gesten auf. Ein Request in ein leeres Kontingent kostet die
    // Burst-Bremse und raeumt nebenbei das Feld ab.
    final service = _CapturingService.create()
      ..fehler = const CoachQuotaExceeded(
        message: 'Tageslimit erreicht. Morgen geht es weiter.',
        dailyLimit: 5,
      );
    final picker = _RecordingPicker(_geotaggedJpeg())..tor = Completer<void>();
    await _pumpCoach(tester, service: service, picker: picker);

    await tester.tap(find.byKey(const ValueKey('coach-attach')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('coach-gallery')));
    await tester.pumpAndSettle();

    // Die getippte Frage verbraucht den letzten Slot: der Server antwortet 429
    // und nennt sein Limit, der Composer ist ab hier gesperrt.
    await tester.enterText(
        find.byKey(const ValueKey('coach-input')), 'Die letzte Frage');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('coach-send')));
    await tester.pumpAndSettle();
    expect(service.sendCalls, 1);
    expect(find.text('Limit für heute erreicht'), findsOneWidget,
        reason: 'Vorbedingung: das Kontingent ist jetzt nachweislich leer');

    picker.tor!.complete();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pumpAndSettle();

    expect(service.sendCalls, 1,
        reason: 'der Server wuerde das Bild mit 429 abweisen — der Upload und '
            'die Burst-Bremse waeren trotzdem verbraucht');
    expect(service.sentImageBase64, isNull);
  });
}
