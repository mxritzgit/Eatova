// Structural/raster preflight, not a pixel decoder. 64 MiB of RGBA raster admits
// ordinary 12 MP camera JPEGs; decoder working memory is additional. 16-bit PNG
// channels count twice. Keep photo_container.dart aligned.
export const MAX_IMAGE_RASTER_BYTES = 64 * 1024 * 1024;
const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
export type ImageContainer = { mime: string; width: number; height: number };

export function imageContainerFromBase64(base64: string): ImageContainer | null {
  if (!base64 || base64.length > Math.ceil(MAX_IMAGE_BYTES / 3) * 4 || base64.length % 4 !== 0 ||
    !/^[A-Za-z0-9+/]*={0,2}$/.test(base64)) return null;
  try {
    if (btoa(atob(base64.slice(-4))) !== base64.slice(-4)) return null;
    const bytes = atob(base64);
    return bytes.length <= MAX_IMAGE_BYTES ? inspect(bytes) : null;
  } catch { return null; }
}

function inspect(bytes: string): ImageContainer | null {
  const u8 = (o: number) => bytes.charCodeAt(o);
  const u16 = (o: number, le = false) => le ? u8(o) | u8(o + 1) << 8 : u8(o) << 8 | u8(o + 1);
  const u24 = (o: number) => u16(o, true) | u8(o + 2) << 16;
  const u32 = (o: number, le = false) => (le ? u16(o, true) | u16(o + 2, true) << 16 : u16(o) << 16 | u16(o + 2)) >>> 0;
  const fits = (w: number, h: number, bytesPerPixel = 4) => w > 0 && h > 0 && w * h <= MAX_IMAGE_RASTER_BYTES / bytesPerPixel;
  if (bytes.startsWith('\xff\xd8')) {
    let offset = 2, width = 0, height = 0, hasScan = false;
    while (offset < bytes.length) {
      if (u8(offset++) !== 0xff) return null;
      while (u8(offset) === 0xff) offset++;
      if (offset >= bytes.length) return null;
      const marker = u8(offset++);
      if (marker === 0xd9) return offset === bytes.length && width > 0 && hasScan ? { mime: 'image/jpeg', width, height } : null;
      if ([0, 1, 0xd8].includes(marker) || marker >= 0xd0 && marker <= 0xd7 || offset + 2 > bytes.length) return null;
      const length = u16(offset), start = offset + 2;
      if (length < 2 || offset + length > bytes.length) return null;
      if ([0xc0, 0xc1, 0xc2].includes(marker)) {
        if (width !== 0 || length < 11 || u8(start) !== 8) return null;
        height = u16(start + 1); width = u16(start + 3);
        if (!fits(width, height)) return null;
        const components = u8(start + 5);
        if (![1, 3, 4].includes(components) || length !== 8 + 3 * components) return null;
        for (let c = 0; c < components; c++) {
          const s = u8(start + 7 + c * 3);
          if ((s >> 4) < 1 || (s >> 4) > 4 || (s & 15) < 1 || (s & 15) > 4) return null;
        }
      } else if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) return null;
      offset += length;
      if (marker === 0xda) {
        if (width === 0 || length < 8 || length !== 6 + 2 * u8(start)) return null;
        hasScan = true;
        while (offset < bytes.length) {
          if (u8(offset) !== 0xff) { offset++; continue; }
          let nextOffset = offset + 1;
          while (u8(nextOffset) === 0xff) nextOffset++;
          if (nextOffset >= bytes.length) return null;
          const next = u8(nextOffset);
          if (next === 0 || next >= 0xd0 && next <= 0xd7) { offset = nextOffset + 1; continue; }
          break;
        }
      }
    }
    return null;
  }
  if (bytes.startsWith('\x89PNG\r\n\x1a\n')) {
    let offset = 8, width = 0, height = 0, hasPixels = false;
    while (offset + 12 <= bytes.length) {
      const length = u32(offset), start = offset + 8, tag = bytes.slice(offset + 4, offset + 8);
      if (length > bytes.length - offset - 12) return null;
      if (offset === 8) {
        if (tag !== 'IHDR' || length !== 13) return null;
        width = u32(start); height = u32(start + 4);
        const depth = u8(start + 8), color = u8(start + 9);
        const depths: Record<number, number[]> = { 0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16] };
        if (!depths[color]?.includes(depth) || u8(start + 10) !== 0 || u8(start + 11) !== 0 || u8(start + 12) > 1 || !fits(width, height, depth === 16 ? 8 : 4)) return null;
      } else if (tag === 'IHDR' || tag === 'acTL') return null;
      else if (tag === 'IDAT') hasPixels ||= length > 0;
      else if (tag === 'IEND') return length === 0 && hasPixels && offset + 12 === bytes.length ? { mime: 'image/png', width, height } : null;
      offset += length + 12;
    }
    return null;
  }
  if (bytes.length >= 20 && bytes.startsWith('RIFF') && bytes.slice(8, 12) === 'WEBP') {
    if (u32(4, true) !== bytes.length - 8) return null;
    let offset = 12, width = 0, height = 0, canvasWidth = 0, canvasHeight = 0;
    while (offset + 8 <= bytes.length) {
      const tag = bytes.slice(offset, offset + 4), length = u32(offset + 4, true), start = offset + 8;
      if (length + (length & 1) > bytes.length - start) return null;
      if (tag === 'VP8X') {
        if (offset !== 12 || length !== 10 || (u8(start) & 2) !== 0) return null;
        canvasWidth = u24(start + 4) + 1; canvasHeight = u24(start + 7) + 1;
        if (!fits(canvasWidth, canvasHeight)) return null;
      } else if (tag === 'ANIM' || tag === 'ANMF') return null;
      else if (tag === 'VP8 ' || tag === 'VP8L') {
        if (width !== 0) return null;
        if (tag === 'VP8 ') {
          if (length < 10 || (u8(start) & 1) !== 0 || bytes.slice(start + 3, start + 6) !== '\x9d\x01\x2a') return null;
          width = u16(start + 6, true) & 0x3fff; height = u16(start + 8, true) & 0x3fff;
        } else {
          if (length < 5 || u8(start) !== 0x2f || (u8(start + 4) >> 5) !== 0) return null;
          const bits = u32(start + 1, true);
          width = (bits & 0x3fff) + 1; height = (bits >>> 14 & 0x3fff) + 1;
        }
        if (!fits(width, height)) return null;
      }
      offset = start + length + (length & 1);
    }
    return offset === bytes.length && width > 0 && (canvasWidth === 0 || width === canvasWidth && height === canvasHeight)
      ? { mime: 'image/webp', width, height } : null;
  }
  return null;
}
