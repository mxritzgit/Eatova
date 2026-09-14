import { imageContainerFromBase64 } from '../_shared/image_validation.ts';

/** Syntax, framing and raster budget; compressed pixels are not decoded here. */
export function imageMimeFromBytes(base64: string, byteLength: number): string | null {
  const padding = base64.endsWith('==') ? 2 : base64.endsWith('=') ? 1 : 0;
  if (base64.length / 4 * 3 - padding !== byteLength) return null;
  return imageContainerFromBase64(base64)?.mime ?? null;
}
