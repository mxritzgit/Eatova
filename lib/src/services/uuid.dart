import 'dart:math';

/// Generates a UUID v4 without an external dependency. Enough for client-side
/// IDs that end up as Supabase primary keys.
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

/// XOR mask of the stats request-id derivation: ASCII of 'eatova-stats-rid'
/// (exactly 16 bytes). WIRE FORMAT — never change: the same source UUID must
/// yield the same id across builds and replays, or server dedup breaks and
/// double counting returns. Any future derivation gets its own mask.
const List<int> _statsRequestIdMask = <int>[
  0x65, 0x61, 0x74, 0x6f, 0x76, 0x61, 0x2d, 0x73, // 'eatova-s'
  0x74, 0x61, 0x74, 0x73, 0x2d, 0x72, 0x69, 0x64, // 'tats-rid'
];

/// Derives the request id of a client UUID's lifetime-stats increment
/// (Fix 3, replay double counting).
///
/// Bijective on the 128-bit space, and the result is a valid Postgres uuid
/// literal (the uuid type ignores version bits). `null` if [sourceUuid] is not
/// UUID-shaped — only reachable via a tampered/corrupt blob.
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

/// Whether [s] is UUID-shaped (8-4-4-4-12 hex). No version check on purpose:
/// Postgres accepts any hex UUID, only the shape has to match.
bool isUuidShape(String s) => _uuidShape.hasMatch(s);

final RegExp _uuidShape = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// The 32 lowercase hex chars of a UUID without dashes. Hoisted to a constant
/// because the derivation runs per counting op during replay.
final RegExp _hex32 = RegExp(r'^[0-9a-f]{32}$');

bool _istHex32(String s) => s.length == 32 && _hex32.hasMatch(s);
