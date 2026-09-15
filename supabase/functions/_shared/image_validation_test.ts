import { imageContainerFromBase64 } from './image_validation.ts';
import { JPEG_BASE64, JPEG_PROGRESSIVE_BASE64, PNG_BASE64, WEBP_BASE64, WEBP_LOSSLESS_BASE64, WEBP_ALPHA_BASE64 } from '../analyze-meal/image_fixtures.ts';

function assert(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}
function changed(base64: string, offset: number, values: number[]): string {
  const bytes = atob(base64);
  return btoa(bytes.slice(0, offset) + String.fromCharCode(...values) + bytes.slice(offset + values.length));
}

for (const tag of ['acTL', 'fcTL', 'fdAT']) {
  Deno.test(`still-photo boundary rejects PNG ${tag} even without other animation chunks`, () => {
    const bytes = atob(PNG_BASE64);
    const payload = new Uint8Array(tag === 'fcTL' ? 26 : 8);
    if (tag === 'fcTL') {
      const fields = new DataView(payload.buffer);
      fields.setUint32(4, 8);
      fields.setUint32(8, 8);
    }
    const typeAndData = new TextEncoder().encode(tag + String.fromCharCode(...payload));
    let crc = 0xffffffff;
    for (const value of typeAndData) {
      crc ^= value;
      for (let bit = 0; bit < 8; bit++) crc = crc >>> 1 ^ ((crc & 1) ? 0xedb88320 : 0);
    }
    const trailer = new Uint8Array(4);
    new DataView(trailer.buffer).setUint32(0, (crc ^ 0xffffffff) >>> 0);
    const chunk = String.fromCharCode(0, 0, 0, payload.length) +
      String.fromCharCode(...typeAndData, ...trailer);
    const input = btoa(bytes.slice(0, -12) + chunk + bytes.slice(-12));
    assert(imageContainerFromBase64(input) === null, `reject ${tag} before provider decoding`);
  });
}

for (const [mime, input] of [
  ['image/jpeg', JPEG_BASE64], ['image/jpeg', JPEG_PROGRESSIVE_BASE64], ['image/png', PNG_BASE64],
  ['image/webp', WEBP_BASE64], ['image/webp', WEBP_LOSSLESS_BASE64], ['image/webp', WEBP_ALPHA_BASE64],
]) {
  Deno.test(`raster preflight preserves real ${mime} ${input.length} chars`, () => {
    const result = imageContainerFromBase64(input);
    assert(result?.mime === mime && result.width === 8 && result.height === 8, 'valid 8x8 image');
  });
}

const sof = atob(JPEG_BASE64).indexOf('\xff\xc0');
const malformed = [
  ['oversized JPEG SOF', changed(JPEG_BASE64, sof + 5, [0x10, 0x00, 0x10, 0x01])],
  ['zero JPEG width', changed(JPEG_BASE64, sof + 7, [0, 0])],
  ['unbounded JPEG sampling', changed(JPEG_BASE64, sof + 11, [0xff])],
  ['oversized PNG IHDR', changed(PNG_BASE64, 16, [1, 0, 0, 0])],
  ['PNG without IDAT', btoa(atob(PNG_BASE64).slice(0, 33) + atob(PNG_BASE64).slice(-12))],
  ['PNG chunk past EOF', changed(PNG_BASE64, 33, [0xff, 0xff, 0xff, 0xff])],
  ['invalid PNG color-depth pairing', changed(PNG_BASE64, 24, [4, 2])],
  ['oversized VP8 dimensions', changed(WEBP_BASE64, 26, [0xff, 0x3f, 0xff, 0x3f])],
  ['oversized VP8L dimensions', changed(WEBP_LOSSLESS_BASE64, 21, [0xff, 0xff, 0xff, 0x0f])],
  ['oversized VP8X canvas', changed(WEBP_ALPHA_BASE64, 24, [0xff, 0xff, 0xff, 0xff, 0xff, 0xff])],
  ['VP8X canvas disagrees with pixels', changed(WEBP_ALPHA_BASE64, 24, [8, 0, 0])],
  ['animation flag', changed(WEBP_ALPHA_BASE64, 20, [0x12])],
  ['noncanonical padding', `${PNG_BASE64.slice(0, -3)}h==`],
  ['extra base64 padding', `${JPEG_BASE64}====`],
  ['trailing bytes after JPEG', btoa(atob(JPEG_BASE64) + 'extra')],
] as const;
for (const [name, input] of malformed) {
  Deno.test(`raster preflight rejects ${name}`, () => {
    assert(imageContainerFromBase64(input) === null, name);
  });
}

Deno.test('raster boundary admits a camera header and exact budget without decoding', () => {
  // Mutate only headers. Never allocate or decode these claimed rasters.
  const camera = imageContainerFromBase64(changed(JPEG_BASE64, sof + 5, [0x0b, 0xb8, 0x0f, 0xa0]));
  assert(camera?.width === 4000 && camera.height === 3000, '12 MP camera');
  assert(imageContainerFromBase64(changed(JPEG_BASE64, sof + 5, [0x10, 0x00, 0x10, 0x00])) !== null, '64 MiB boundary');
});

Deno.test('bounded malformed-byte corpus returns null instead of throwing', () => {
  let seed = 19;
  for (let count = 0; count < 1000; count++) {
    let value = '';
    for (let i = 0; i < count % 127; i++) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      value += String.fromCharCode(seed >>> 24);
    }
    assert(imageContainerFromBase64(btoa(value)) === null, 'non-image bytes');
  }
});
