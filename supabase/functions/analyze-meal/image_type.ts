/** Bounded container checks, not a full image decoder or decompression-bomb guard. */
export function imageMimeFromBytes(base64: string, byteLength: number): string | null {
  // Base64 syntax and size are checked by the caller; decode only the framing.
  const head = atob(base64.slice(0, 48));
  const tail = atob(base64.slice(-24));
  if (head.startsWith('\xff\xd8\xff') && tail.endsWith('\xff\xd9')) {
    return 'image/jpeg';
  }
  if (
    head.startsWith('\x89PNG\r\n\x1a\n\0\0\0\rIHDR') &&
    uint32(head, 16, false) > 0 && uint32(head, 20, false) > 0 &&
    tail.endsWith('\0\0\0\0IEND\xae\x42\x60\x82')
  ) {
    return 'image/png';
  }
  if (
    head.startsWith('RIFF') && head.slice(8, 12) === 'WEBP' &&
    uint32(head, 4, true) === byteLength - 8 &&
    ['VP8 ', 'VP8L', 'VP8X'].includes(head.slice(12, 16)) &&
    uint32(head, 16, true) > 0 && uint32(head, 16, true) <= byteLength - 20
  ) {
    return 'image/webp';
  }
  return null;
}

function uint32(bytes: string, offset: number, littleEndian: boolean): number {
  const a = bytes.charCodeAt(offset);
  const b = bytes.charCodeAt(offset + 1);
  const c = bytes.charCodeAt(offset + 2);
  const d = bytes.charCodeAt(offset + 3);
  return (littleEndian ? a | b << 8 | c << 16 | d << 24 : a << 24 | b << 16 | c << 8 | d) >>> 0;
}
