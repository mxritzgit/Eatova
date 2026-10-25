// Test fixtures for the store verifiers (jws_apple, google_auth,
// play_subscriptions): a tiny DER writer, generated ECDSA/RSA keys, an
// Apple-shaped x5c chain, JWS/JWT signers and a fetch stub. No network.

import { APPLE_INTERMEDIATE_OID, APPLE_LEAF_OID } from './jws_apple.ts';
import { type Bytes, bytesToBase64Url, bytesToHex } from './jose.ts';

export function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

export function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`);
  }
}

/** Apple Worldwide Developer Relations Certification Authority G6, from
 *  https://www.apple.com/certificateauthority/AppleWWDRCAG6.cer
 *  (SHA-256 bdd4ed6e74691f0c2bfd01be0296197af1379e0418e2d300efa9c3bef642ca30). */
export const APPLE_WWDR_G6_BASE64 = 'MIIDFjCCApygAwIBAgIUIsGhRwp0c2nvU4YSycafPTjzbNcwCgYIKoZIzj0EAwMwZzEbMBkGA1UE' +
  'AwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhv' +
  'cml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMjEwMzE3MjAzNzEwWhcN' +
  'MzYwMzE5MDAwMDAwWjB1MUQwQgYDVQQDDDtBcHBsZSBXb3JsZHdpZGUgRGV2ZWxvcGVyIFJlbGF0' +
  'aW9ucyBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTELMAkGA1UECwwCRzYxEzARBgNVBAoMCkFwcGxl' +
  'IEluYy4xCzAJBgNVBAYTAlVTMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEbsQKC94PrlWmZXnXgtxz' +
  'dVJL8T0SGYngDRGpngn3N6PT8JMEb7FDi4bBmPhCnZ3/sq6PF/cGcKXWsL5vOteRhyJ45x3ASP7c' +
  'OB+aao90fcpxSv/EZFbniAbNgZGhIhpIo4H6MIH3MBIGA1UdEwEB/wQIMAYBAf8CAQAwHwYDVR0j' +
  'BBgwFoAUu7DeoVgziJqkipnevr3rr9rLJKswRgYIKwYBBQUHAQEEOjA4MDYGCCsGAQUFBzABhipo' +
  'dHRwOi8vb2NzcC5hcHBsZS5jb20vb2NzcDAzLWFwcGxlcm9vdGNhZzMwNwYDVR0fBDAwLjAsoCqg' +
  'KIYmaHR0cDovL2NybC5hcHBsZS5jb20vYXBwbGVyb290Y2FnMy5jcmwwHQYDVR0OBBYEFD8vlCNR' +
  '01DJmig97bB85c+lkGKZMA4GA1UdDwEB/wQEAwIBBjAQBgoqhkiG92NkBgIBBAIFADAKBggqhkjO' +
  'PQQDAwNoADBlAjBAXhSq5IyKogMCPtw490BaB677CaEGJXufQB/EqZGd6CSjiCtOnuMTbXVXmxxc' +
  'xfkCMQDTSPxarZXvNrkxU3TkUMI33yzvFVVRT4wxWJC994OsdcZ4+RGNsYDyR5gmdr0nDGg=';

export async function sha256Hex(bytes: Bytes): Promise<string> {
  return bytesToHex(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)));
}

export function toBase64(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

// ---------------------------------------------------------------------------
// DER writer

function concat(parts: Uint8Array[]): Bytes {
  const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

export function tlv(tag: number, ...parts: Uint8Array[]): Bytes {
  const content = concat(parts);
  const n = content.length;
  const length = n < 0x80 ? [n] : n < 0x100 ? [0x81, n] : [0x82, n >> 8, n & 0xff];
  return concat([new Uint8Array([tag, ...length]), content]);
}

export const der = {
  seq: (...parts: Uint8Array[]) => tlv(0x30, ...parts),
  set: (...parts: Uint8Array[]) => tlv(0x31, ...parts),
  explicit: (n: number, ...parts: Uint8Array[]) => tlv(0xa0 + n, ...parts),
  bool: (value: boolean) => tlv(0x01, new Uint8Array([value ? 0xff : 0])),
  nul: () => tlv(0x05),
  octets: (bytes: Uint8Array) => tlv(0x04, bytes),
  bitString: (bytes: Uint8Array) => tlv(0x03, new Uint8Array([0]), bytes),
  utf8: (text: string) => tlv(0x0c, new TextEncoder().encode(text)),
  /** Unsigned big-endian magnitude, minimal, positive. */
  int(magnitude: Uint8Array | number): Bytes {
    let bytes = typeof magnitude === 'number' ? new Uint8Array([magnitude]) : magnitude;
    let start = 0;
    while (start < bytes.length - 1 && bytes[start] === 0) start++;
    bytes = bytes.subarray(start);
    return tlv(0x02, bytes[0] & 0x80 ? concat([new Uint8Array([0]), bytes]) : bytes);
  },
  oid(dotted: string): Bytes {
    const arcs = dotted.split('.').map(Number);
    const body: number[] = [];
    for (const arc of [arcs[0] * 40 + arcs[1], ...arcs.slice(2)]) {
      const chunk = [arc & 0x7f];
      for (let rest = Math.floor(arc / 128); rest > 0; rest = Math.floor(rest / 128)) {
        chunk.unshift((rest & 0x7f) | 0x80);
      }
      body.push(...chunk);
    }
    return tlv(0x06, new Uint8Array(body));
  },
  /** UTCTime before 2050, GeneralizedTime from 2050 (RFC 5280 4.1.2.5). */
  time(ms: number): Bytes {
    const iso = new Date(ms).toISOString();
    const digits = iso.slice(0, 19).replace(/[-:T]/g, '');
    return iso < '2050'
      ? tlv(0x17, new TextEncoder().encode(digits.slice(2) + 'Z'))
      : tlv(0x18, new TextEncoder().encode(digits + 'Z'));
  },
};

/** WebCrypto's raw r||s to a DER ECDSA-Sig-Value. */
export function rawToDerSignature(raw: Uint8Array): Bytes {
  const half = raw.length / 2;
  return der.seq(der.int(raw.subarray(0, half)), der.int(raw.subarray(half)));
}

// ---------------------------------------------------------------------------
// Certificates and an Apple-shaped chain

const SIGNATURE_OIDS = { 'SHA-256': '1.2.840.10045.4.3.2', 'SHA-384': '1.2.840.10045.4.3.3' } as const;
const OID_COMMON_NAME = '2.5.4.3';
const OID_BASIC_CONSTRAINTS = '2.5.29.19';

export function ecKeyPair(namedCurve: 'P-256' | 'P-384'): Promise<CryptoKeyPair> {
  return crypto.subtle.generateKey({ name: 'ECDSA', namedCurve }, true, ['sign', 'verify']) as Promise<CryptoKeyPair>;
}

export interface CertSpec {
  subject: string;
  issuer: string;
  publicKey: CryptoKey;
  /** The issuer's private key (the subject's own for a root). */
  signingKey: CryptoKey;
  notBeforeMs: number;
  notAfterMs: number;
  /** Marker extensions, each with a NULL value as Apple writes them. */
  extensionOids: string[];
  ca: boolean;
  hash: 'SHA-256' | 'SHA-384';
  serial: number;
}

function name(commonName: string): Bytes {
  return der.seq(der.set(der.seq(der.oid(OID_COMMON_NAME), der.utf8(commonName))));
}

export async function buildCertificate(spec: CertSpec): Promise<Bytes> {
  const algorithm = der.seq(der.oid(SIGNATURE_OIDS[spec.hash]));
  const extensions = [
    der.seq(der.oid(OID_BASIC_CONSTRAINTS), der.bool(true), der.octets(spec.ca ? der.seq(der.bool(true)) : der.seq())),
    ...spec.extensionOids.map((oid) => der.seq(der.oid(oid), der.octets(der.nul()))),
  ];
  const tbs = der.seq(
    der.explicit(0, der.int(2)),
    der.int(spec.serial),
    algorithm,
    name(spec.issuer),
    der.seq(der.time(spec.notBeforeMs), der.time(spec.notAfterMs)),
    name(spec.subject),
    new Uint8Array(await crypto.subtle.exportKey('spki', spec.publicKey)),
    der.explicit(3, der.seq(...extensions)),
  );
  const raw = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: spec.hash }, spec.signingKey, tbs));
  return der.seq(tbs, algorithm, der.bitString(rawToDerSignature(raw)));
}

export interface ChainKeys {
  root: CryptoKeyPair;
  intermediate: CryptoKeyPair;
  leaf: CryptoKeyPair;
}

export async function generateChainKeys(): Promise<ChainKeys> {
  return { root: await ecKeyPair('P-384'), intermediate: await ecKeyPair('P-384'), leaf: await ecKeyPair('P-256') };
}

export interface TestChain {
  ders: Bytes[];
  /** Standard base64 DER, leaf first, as in the JWS x5c header. */
  x5c: string[];
  rootSha256: string;
  leafKey: CryptoKey;
}

const Y = (year: number) => Date.UTC(year, 0, 1);

/** Leaf P-256, intermediate and root P-384 with SHA-384, Apple marker OIDs. */
export async function buildAppleChain(
  keys: ChainKeys,
  overrides: { root?: Partial<CertSpec>; intermediate?: Partial<CertSpec>; leaf?: Partial<CertSpec> } = {},
): Promise<TestChain> {
  const root = await buildCertificate({
    subject: 'Eatova Test Root CA - G3',
    issuer: 'Eatova Test Root CA - G3',
    publicKey: keys.root.publicKey,
    signingKey: keys.root.privateKey,
    notBeforeMs: Y(2014),
    notAfterMs: Y(2055),
    extensionOids: [],
    ca: true,
    hash: 'SHA-384',
    serial: 1,
    ...overrides.root,
  });
  const intermediate = await buildCertificate({
    subject: 'Eatova Test WWDR G6',
    issuer: 'Eatova Test Root CA - G3',
    publicKey: keys.intermediate.publicKey,
    signingKey: keys.root.privateKey,
    notBeforeMs: Y(2021),
    notAfterMs: Y(2036),
    extensionOids: [APPLE_INTERMEDIATE_OID],
    ca: true,
    hash: 'SHA-384',
    serial: 2,
    ...overrides.intermediate,
  });
  const leaf = await buildCertificate({
    subject: 'Eatova Test Store Receipt Signing',
    issuer: 'Eatova Test WWDR G6',
    publicKey: keys.leaf.publicKey,
    signingKey: keys.intermediate.privateKey,
    notBeforeMs: Y(2025),
    notAfterMs: Y(2028),
    extensionOids: [APPLE_LEAF_OID],
    ca: false,
    hash: 'SHA-384',
    serial: 3,
    ...overrides.leaf,
  });
  const ders = [leaf, intermediate, root];
  return { ders, x5c: ders.map(toBase64), rootSha256: await sha256Hex(root), leafKey: keys.leaf.privateKey };
}

function encodeSegment(value: Record<string, unknown> | string): string {
  return bytesToBase64Url(new TextEncoder().encode(typeof value === 'string' ? value : JSON.stringify(value)));
}

/** Compact JWS signed ES256 (raw r||s), whatever the header claims. */
export async function signEs256Jws(
  header: Record<string, unknown>,
  payload: Record<string, unknown> | string,
  privateKey: CryptoKey,
): Promise<string> {
  const signingInput = `${encodeSegment(header)}.${encodeSegment(payload)}`;
  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    privateKey,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${bytesToBase64Url(new Uint8Array(signature))}`;
}

// ---------------------------------------------------------------------------
// RSA for the Google tests

export function rsaKeyPair(): Promise<CryptoKeyPair> {
  return crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
    true,
    ['sign', 'verify'],
  ) as Promise<CryptoKeyPair>;
}

export async function pkcs8Pem(privateKey: CryptoKey): Promise<string> {
  const body = toBase64(new Uint8Array(await crypto.subtle.exportKey('pkcs8', privateKey)));
  return `-----BEGIN PRIVATE KEY-----\n${body.match(/.{1,64}/g)!.join('\n')}\n-----END PRIVATE KEY-----\n`;
}

/** Compact JWT signed RS256, whatever the header claims. */
export async function signRs256Jwt(
  header: Record<string, unknown>,
  claims: Record<string, unknown>,
  privateKey: CryptoKey,
): Promise<string> {
  const signingInput = `${encodeSegment(header)}.${encodeSegment(claims)}`;
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', privateKey, new TextEncoder().encode(signingInput));
  return `${signingInput}.${bytesToBase64Url(new Uint8Array(signature))}`;
}

export async function publicJwk(publicKey: CryptoKey, kid: string): Promise<Record<string, unknown>> {
  const { n, e } = await crypto.subtle.exportKey('jwk', publicKey);
  return { kty: 'RSA', alg: 'RS256', use: 'sig', kid, n, e };
}

// ---------------------------------------------------------------------------
// fetch stub

export interface StubCall {
  url: string;
  method: string;
  headers: Headers;
  body: string;
  redirect: RequestRedirect | undefined;
}

/** Replaces fetch and console for `run`, restores both afterwards. */
export async function withFetchStub(
  reply: (call: StubCall) => Response | Promise<Response>,
  run: (calls: StubCall[], logs: string[]) => Promise<void>,
): Promise<void> {
  const originalFetch = globalThis.fetch;
  const originals = { log: console.log, info: console.info, warn: console.warn, error: console.error };
  const calls: StubCall[] = [];
  const logs: string[] = [];
  const capture = (...args: unknown[]) => logs.push(args.map(String).join(' '));
  console.log =
    console.info =
    console.warn =
    console.error =
      capture;
  globalThis.fetch = (async (input: string | URL | Request, init: RequestInit = {}) => {
    const call: StubCall = {
      url: String(input),
      method: init.method ?? 'GET',
      headers: new Headers(init.headers),
      body: init.body === undefined || init.body === null ? '' : String(init.body),
      redirect: init.redirect,
    };
    calls.push(call);
    return await reply(call);
  }) as typeof fetch;
  try {
    await run(calls, logs);
  } finally {
    globalThis.fetch = originalFetch;
    Object.assign(console, originals);
  }
}
