import 'dart:math';

/// Erzeugt eine UUID v4 ohne externe Dependency. Reicht voellig fuer
/// Client-seitige IDs die als Primary Key in Supabase wandern.
String uuidV4() {
  final rand = Random.secure();
  final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
  // Version 4 + RFC 4122 Variant.
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int b) => b.toRadixString(16).padLeft(2, '0');
  final h = bytes.map(hex).toList();
  return '${h.sublist(0, 4).join()}-'
      '${h.sublist(4, 6).join()}-'
      '${h.sublist(6, 8).join()}-'
      '${h.sublist(8, 10).join()}-'
      '${h.sublist(10, 16).join()}';
}

/// XOR-Maske der Stats-Request-Id-Ableitung: ASCII von 'eatova-stats-rid'
/// (exakt 16 Byte). WIRE-FORMAT — NIEMALS aendern: dieselbe Quell-UUID muss
/// ueber Builds und Replays hinweg dieselbe Id ergeben, sonst faellt der
/// Server-Dedup aus und die Doppelzaehlung ist zurueck. Eine KUENFTIGE andere
/// Ableitung (anderer Zweck) bekommt ihre eigene Maske — das ist der
/// Namensraum.
const List<int> _statsRequestIdMask = <int>[
  0x65, 0x61, 0x74, 0x6f, 0x76, 0x61, 0x2d, 0x73, // 'eatova-s'
  0x74, 0x61, 0x74, 0x73, 0x2d, 0x72, 0x69, 0x64, // 'tats-rid'
];

/// Leitet aus einer Client-UUID deterministisch die Request-Id des
/// zugehoerigen Lifetime-Stats-Increments ab (Fix 3, Replay-Doppelzaehlung).
///
/// Bijektiv auf dem 128-Bit-Raum: verschiedene Quellen ergeben verschiedene
/// Ids, dieselbe Quelle immer dieselbe. Das Ergebnis ist ein gueltiges
/// Postgres-uuid-Literal (der uuid-Typ prueft keine Versions-Bits).
/// `null`, wenn [sourceUuid] keine UUID-Form hat — unsere Factories erzeugen
/// ausschliesslich [uuidV4], der Fall ist also nur ueber einen manipulierten/
/// korrupten Blob erreichbar (Behandlung: home_store_sync, kein Follow-up).
String? deriveStatsRequestId(String sourceUuid) {
  final hex = sourceUuid.replaceAll('-', '').toLowerCase();
  if (!_istHex32(hex)) return null;
  final b = StringBuffer();
  for (var i = 0; i < 16; i++) {
    final byte = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16) ^
        _statsRequestIdMask[i];
    b.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  final h = b.toString();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
      '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// Hat [s] UUID-Form (8-4-4-4-12 Hex)? Bewusst OHNE Versions-Pruefung —
/// Postgres akzeptiert jede Hex-UUID, und genau die Form muss stimmen.
bool isUuidShape(String s) => _uuidShape.hasMatch(s);

final RegExp _uuidShape = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// Die 32 Hexzeichen einer UUID ohne Bindestriche, klein geschrieben.
/// Bewusst als Konstante statt als RegExp-Literal in der Funktion: die
/// Ableitung laeuft im Replay pro zaehlender Op.
final RegExp _hex32 = RegExp(r'^[0-9a-f]{32}$');

bool _istHex32(String s) => s.length == 32 && _hex32.hasMatch(s);
