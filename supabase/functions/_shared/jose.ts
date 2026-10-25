// Strict base64 and compact-JWS codecs shared by the store verifiers
// (jws_apple.ts, google_auth.ts). WebCrypto and the platform codecs only.

export type Bytes = Uint8Array<ArrayBuffer>;

const BASE64URL = /^[A-Za-z0-9_-]+$/;
const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/;

function binaryToBytes(binary: string): Bytes {
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/** Unpadded base64url (RFC 7515); null for any other alphabet or length. */
export function base64UrlToBytes(text: string): Bytes | null {
  if (!BASE64URL.test(text) || text.length % 4 === 1) return null;
  const standard = text.replace(/-/g, '+').replace(/_/g, '/');
  try {
    return binaryToBytes(atob(standard + '='.repeat((4 - standard.length % 4) % 4)));
  } catch {
    return null;
  }
}

/** Padded standard base64, as in the JWS `x5c` header; null otherwise. */
export function base64ToBytes(text: string): Bytes | null {
  if (!BASE64.test(text) || text.length % 4 !== 0) return null;
  try {
    return binaryToBytes(atob(text));
  } catch {
    return null;
  }
}

export function bytesToBase64Url(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('');
}

/** A JSON object from strict UTF-8, or null (arrays and primitives too). */
export function jsonObjectFromBytes(bytes: Uint8Array): Record<string, unknown> | null {
  try {
    const value: unknown = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
    return value !== null && typeof value === 'object' && !Array.isArray(value)
      ? value as Record<string, unknown>
      : null;
  } catch {
    return null;
  }
}

export interface CompactJws {
  header: Record<string, unknown>;
  /** Still encoded: callers decode it only after the signature verified. */
  payloadSegment: string;
  signature: Bytes;
  signingInput: Bytes;
}

/** Splits `header.payload.signature` and decodes the header only. */
export function parseCompactJws(token: string, maxLength: number): CompactJws | null {
  if (typeof token !== 'string' || token.length === 0 || token.length > maxLength) return null;
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  const [headerSegment, payloadSegment, signatureSegment] = parts;
  const headerBytes = base64UrlToBytes(headerSegment);
  const signature = base64UrlToBytes(signatureSegment);
  if (!headerBytes || !signature || !BASE64URL.test(payloadSegment) || payloadSegment.length % 4 === 1) {
    return null;
  }
  const header = jsonObjectFromBytes(headerBytes);
  if (!header) return null;
  return {
    header,
    payloadSegment,
    signature,
    signingInput: new TextEncoder().encode(`${headerSegment}.${payloadSegment}`),
  };
}

export function decodeJwsPayload(jws: CompactJws): Record<string, unknown> | null {
  const bytes = base64UrlToBytes(jws.payloadSegment);
  return bytes ? jsonObjectFromBytes(bytes) : null;
}
