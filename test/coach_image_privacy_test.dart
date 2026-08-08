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
import 'package:eatova/src/theme/app_theme.dart';

// C4 (Coach-Haelfte, Nachtrag von W3-03) — das Coach-Foto verliess das Geraet
// ungescrubbt.
//
// coach_chat_screen.dart:320-333 waehlt das Bild, :267 base64-kodiert es fuer
// die Edge Function, die es an OpenRouter (USA) weiterreicht. `image_picker`
// skaliert zwar, kopiert danach aber ueber ImageResizer.copyExif() die
// Metadaten inklusive GPS-Sub-IFD zurueck — Breitengrad, Laengengrad, Hoehe,
// Aufnahmezeit, Geraetemodell und Seriennummer gingen also mit. Der Meal-Scan
// leitet seine Bytes laengst durch compressMealPhoto; der Coach-Pfad nicht.
//
// Geprueft wird auf der einzigen belastbaren Ebene: den Bytes, die tatsaechlich
// in `imageBase64` landen. Ein Test, der nur den Aufruf abfragt, wuerde einen
// falsch sortierten oder wirkungslosen Fix nicht bemerken.

/// GPS-Tag-IDs im `gps`-Sub-IFD (EXIF-Spezifikation).
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

/// Handy-JPEG mit genau dem Container, den eine OEM-Kamera mit aktiviertem
/// Standort-Tagging schreibt (Berlin, Brandenburger Tor).
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

/// Sucht die APP1-Exif-Signatur ("Exif\x00\x00") im rohen Byte-Strom — das ist
/// die Ebene, die das Geraet verlaesst.
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

/// Fake-Picker, der ein Bild aus dem Speicher liefert und mitschreibt, mit
/// welchen Optionen er gerufen wurde. `imageQuality`/`maxWidth` sind nicht
/// kosmetisch: ohne sie reicht iOS die HEIC-Originaldatei durch, die
/// package:image nicht dekodieren kann — der Scrubber liefe dann ins Leere.
class _RecordingPicker extends ImagePicker {
  _RecordingPicker(this.bytes);

  final Uint8List bytes;
  ImageSource? source;
  int? imageQuality;
  double? maxWidth;

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
    return XFile.fromData(
      bytes,
      mimeType: 'image/jpeg',
      name: 'foto.jpg',
      path: 'foto.jpg',
    );
  }
}

/// CoachChatService ohne Netz: alle Methoden ueberschrieben, der Client wird
/// nie benutzt. `stopAutoRefresh()` ist Pflicht — GoTrue startet im
/// Konstruktor einen periodischen Timer, an dem jeder Widget-Test scheitert.
class _CapturingService extends CoachChatService {
  _CapturingService(super.client, super.userId);

  String? sentImageBase64;
  String? sentMimeType;
  int sendCalls = 0;

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
  }) async {
    sendCalls++;
    sentImageBase64 = imageBase64;
    sentMimeType = imageMimeType;
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

  await tester.pumpWidget(
    MaterialApp(
      theme: buildEatovaTheme(),
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Scaffold(
          body: CoachChatScreen(
            service: service,
            userName: 'Moritz',
            imagePicker: picker,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Loest den Galerie-Pfad aus und wartet ECHTE Zeit ab: die Kompression laeuft
/// ueber `compute()` in einem echten Isolate, das die Fake-Async-Uhr des
/// Widget-Tests nie erreichen wuerde.
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

    // Die Byte-Ebene: kein APP1-Exif-Container mehr.
    expect(_hasExifSegment(sent), isFalse);

    // Und dekodiert: kein einziger GPS-Tag, keine Geraete-Identitaet.
    final decoded = img.decodeImage(sent);
    expect(decoded, isNotNull);
    expect(decoded!.exif.gpsIfd.keys, isEmpty);
    expect(decoded.exif.isEmpty, isTrue);

    // Das Motiv ist noch da (der Scrub darf das Bild nicht zerstoeren).
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
}
