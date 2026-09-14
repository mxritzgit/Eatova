import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Checks output length without retaining inflated data. package:image's PNG
/// and ICC paths inflate into growing buffers; their dimensions do not limit
/// a malformed zlib stream. The public Inflate API accepts our 32 KiB window.
void validateZlibOutput(
  Uint8List bytes, {
  required int maxBytes,
  int? expectedBytes,
}) {
  try {
    if (bytes.length < 6 ||
        bytes[0] & 15 != 8 ||
        bytes[0] >> 4 > 7 ||
        bytes[1] & 32 != 0 ||
        (bytes[0] * 256 + bytes[1]) % 31 != 0) {
      throw const FormatException();
    }
    final output = _BoundedWindow(maxBytes);
    final input = InputMemoryStream(
      Uint8List.sublistView(bytes, 2, bytes.length - 4),
    );
    Inflate.stream(input, output: output);
    final checksum = ByteData.sublistView(bytes).getUint32(bytes.length - 4);
    if (!input.isEOS ||
        expectedBytes != null && output.length != expectedBytes ||
        checksum != output.adler32) {
      throw const FormatException();
    }
  } catch (_) {
    throw const FormatException('Invalid or oversized compressed photo data.');
  }
}

class _BoundedWindow extends OutputStream {
  _BoundedWindow(this.limit) : super(byteOrder: ByteOrder.bigEndian);
  final int limit;
  final Uint8List _window = Uint8List(32768);
  int _length = 0;
  int _a = 1;
  int _b = 0;
  @override
  int get length => _length;
  int get adler32 => (_b << 16) | _a;

  @override
  void writeByte(int value) {
    if (_length >= limit) throw const FormatException();
    _window[_length++ & 32767] = value;
    _a = (_a + value) % 65521;
    _b = (_b + _a) % 65521;
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    if (count > limit - _length) throw const FormatException();
    for (var i = 0; i < count; i++) {
      writeByte(bytes[i]);
    }
  }

  @override
  void writeStream(InputStream stream) {
    if (stream.length > limit - _length) throw const FormatException();
    while (!stream.isEOS) {
      writeByte(stream.readByte());
    }
  }

  @override
  Uint8List subset(int start, [int? end]) {
    final first = start < 0 ? _length + start : start;
    final last = end == null
        ? _length
        : end < 0
        ? _length + end
        : end;
    if (first < 0 ||
        first < _length - 32768 ||
        last > _length ||
        last < first) {
      throw const FormatException();
    }
    return Uint8List.fromList(
      List.generate(last - first, (i) => _window[(first + i) & 32767]),
    );
  }

  @override
  void clear() {
    _length = 0;
    _a = 1;
    _b = 0;
  }

  @override
  void flush() {}
}
