// Offline verification of App Store JWS (StoreKit 2 transactions, renewal
// info, App Store Server Notifications V2). Dependency-free: a minimal DER
// reader for the three x5c certificates plus WebCrypto ECDSA.
//
// Trust model as in Apple's app-store-server-library: exactly three
// certificates, the root pinned by the SHA-256 of its DER, Apple's marker
// OIDs on leaf and intermediate, every link signed by its issuer, every
// certificate valid at the payload's `signedDate`. Unlike that library the
// header `alg` is pinned to ES256. The payload is decoded only after the
// signature verified. Never log the JWS or the payload.

import { base64ToBytes, type Bytes, bytesToHex, decodeJwsPayload, parseCompactJws } from './jose.ts';

/** Apple Root CA - G3, https://www.apple.com/certificateauthority/AppleRootCA-G3.cer */
export const APPLE_ROOT_CA_G3_BASE64 = 'MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9v' +
  'dCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UE' +
  'CgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2' +
  'WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmlj' +
  'YXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqG' +
  'SM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxE' +
  'tX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNC' +
  'MEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0P' +
  'AQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3m' +
  'eoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkL' +
  'F1vLUagM6BgD56KyKA==';

/** SHA-256 of the DER above; the default pin for `x5c[2]`. */
export const APPLE_ROOT_CA_G3_SHA256 = '63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179';

/** Marker extension of the App Store receipt-signing leaf. */
export const APPLE_LEAF_OID = '1.2.840.113635.100.6.11.1';
/** Marker extension of the Apple Worldwide Developer Relations intermediate. */
export const APPLE_INTERMEDIATE_OID = '1.2.840.113635.100.6.2.1';

/** Notification bodies carry nested JWS; the store-notifications cap is 256 KiB. */
export const APPLE_JWS_MAX_LENGTH = 256 * 1024;
const CERT_MAX_BASE64_LENGTH = 16 * 1024;
/** Apple signs on its servers; a later signedDate is forged or broken. */
const SIGNED_DATE_MAX_FUTURE_MS = 5 * 60 * 1000;

export type AppleJwsFailure =
  | 'malformed' // not a compact JWS, bad base64, unsupported header
  | 'algorithm' // header alg is not ES256
  | 'chain_length' // x5c does not hold exactly three certificates
  | 'certificate' // a certificate is not parseable DER/X.509 v3
  | 'root' // x5c[2] is not the pinned root
  | 'oid' // Apple marker OID missing on leaf or intermediate
  | 'chain_signature' // a link is not signed by its issuer
  | 'signature' // the JWS signature does not verify with the leaf key
  | 'payload' // payload is not a JSON object with a numeric signedDate
  | 'validity'; // a certificate is not valid at signedDate, or signedDate is ahead

export type AppleJwsResult =
  | { ok: true; payload: Record<string, unknown>; signedDateMs: number }
  | { ok: false; reason: AppleJwsFailure };

export interface AppleJwsOptions {
  /** Defaults to Date.now(); tests pass a fixed instant. */
  nowMs?: number;
  /** Lowercase hex SHA-256 of the trusted root DER; defaults to Apple Root CA - G3. */
  rootSha256?: string;
}

export async function verifyAppleJws(jws: string, options: AppleJwsOptions = {}): Promise<AppleJwsResult> {
  const nowMs = options.nowMs ?? Date.now();
  const pin = (options.rootSha256 ?? APPLE_ROOT_CA_G3_SHA256).toLowerCase();
  const parsed = parseCompactJws(jws, APPLE_JWS_MAX_LENGTH);
  if (!parsed) return fail('malformed');
  const { header } = parsed;
  if (header.alg !== 'ES256') return fail('algorithm');
  if ('crit' in header) return fail('malformed');
  const x5c = header.x5c;
  if (!Array.isArray(x5c)) return fail('malformed');
  if (x5c.length !== 3) return fail('chain_length');

  const ders: Bytes[] = [];
  for (const entry of x5c) {
    const der = typeof entry === 'string' && entry.length <= CERT_MAX_BASE64_LENGTH ? base64ToBytes(entry) : null;
    if (!der) return fail('malformed');
    ders.push(der);
  }
  const certs: ParsedCertificate[] = [];
  for (const der of ders) {
    const cert = parseCertificate(der);
    if (!cert) return fail('certificate');
    certs.push(cert);
  }
  const [leaf, intermediate, root] = certs;

  if (!/^[0-9a-f]{64}$/.test(pin)) return fail('root');
  const rootHash = bytesToHex(new Uint8Array(await crypto.subtle.digest('SHA-256', root.der)));
  if (rootHash !== pin) return fail('root');
  if (!leaf.extensionOids.has(APPLE_LEAF_OID) || !intermediate.extensionOids.has(APPLE_INTERMEDIATE_OID)) {
    return fail('oid');
  }
  if (!(await verifyIssuedBy(intermediate, root)) || !(await verifyIssuedBy(leaf, intermediate))) {
    return fail('chain_signature');
  }

  // ES256 means P-256 and a raw 64-byte r||s signature (RFC 7518 3.4).
  if (leaf.publicKeyCurve !== CURVE_P256 || parsed.signature.length !== 64) return fail('signature');
  let signatureOk = false;
  try {
    const key = await crypto.subtle.importKey('spki', leaf.spki, { name: 'ECDSA', namedCurve: 'P-256' }, false, [
      'verify',
    ]);
    signatureOk = await crypto.subtle.verify(
      { name: 'ECDSA', hash: 'SHA-256' },
      key,
      parsed.signature,
      parsed.signingInput,
    );
  } catch {
    signatureOk = false;
  }
  if (!signatureOk) return fail('signature');

  const payload = decodeJwsPayload(parsed);
  if (!payload) return fail('payload');
  const signedDateMs = payload.signedDate;
  if (typeof signedDateMs !== 'number' || !Number.isSafeInteger(signedDateMs) || signedDateMs <= 0) {
    return fail('payload');
  }
  if (signedDateMs > nowMs + SIGNED_DATE_MAX_FUTURE_MS) return fail('validity');
  if (!certs.every((cert) => isValidAt(cert, signedDateMs))) return fail('validity');
  return { ok: true, payload, signedDateMs };
}

function fail(reason: AppleJwsFailure): AppleJwsResult {
  return { ok: false, reason };
}

// ---------------------------------------------------------------------------
// X.509 (RFC 5280), only what the chain check needs.

export interface ParsedCertificate {
  der: Bytes;
  /** DER of tbsCertificate, the signed bytes. */
  tbs: Bytes;
  signatureAlgorithm: string;
  /** signatureValue BIT STRING content (a DER ECDSA-Sig-Value). */
  signature: Bytes;
  /** DER of the issuer and subject Names, compared byte for byte. */
  issuer: Bytes;
  subject: Bytes;
  notBeforeMs: number;
  notAfterMs: number;
  /** DER of subjectPublicKeyInfo, importable as 'spki'. */
  spki: Bytes;
  /** Named-curve OID of an EC key, null for any other key type. */
  publicKeyCurve: string | null;
  extensionOids: ReadonlySet<string>;
  /** basicConstraints cA. */
  isCa: boolean;
}

const OID_EC_PUBLIC_KEY = '1.2.840.10045.2.1';
const CURVE_P256 = '1.2.840.10045.3.1.7';
const CURVE_P384 = '1.3.132.0.34';
const OID_BASIC_CONSTRAINTS = '2.5.29.19';

const CURVES: Record<string, { name: 'P-256' | 'P-384'; size: number }> = {
  [CURVE_P256]: { name: 'P-256', size: 32 },
  [CURVE_P384]: { name: 'P-384', size: 48 },
};
const ECDSA_HASHES: Record<string, 'SHA-256' | 'SHA-384' | 'SHA-512'> = {
  '1.2.840.10045.4.3.2': 'SHA-256',
  '1.2.840.10045.4.3.3': 'SHA-384',
  '1.2.840.10045.4.3.4': 'SHA-512',
};

/** Parses one DER certificate; null for anything that is not strict DER X.509 v3. */
export function parseCertificate(der: Bytes): ParsedCertificate | null {
  try {
    const top = readNode(der, 0);
    if (top.tag !== TAG_SEQUENCE || top.end !== der.length) return null;
    const [tbsNode, algNode, sigNode, ...rest] = childrenOf(der, top);
    if (!tbsNode || !algNode || !sigNode || rest.length > 0) return null;
    expectTag(tbsNode, TAG_SEQUENCE);
    const signatureAlgorithm = algorithmOid(der, algNode);
    const signature = bitStringContent(der, sigNode);

    const fields = childrenOf(der, tbsNode);
    let index = 0;
    const versionNode = fields[index++];
    if (!versionNode || versionNode.tag !== 0xa0) return null; // v1/v2 carry no extensions
    const [versionInt, ...versionRest] = childrenOf(der, versionNode);
    if (!versionInt || versionRest.length > 0) return null;
    expectTag(versionInt, TAG_INTEGER);
    const versionBytes = contentOf(der, versionInt);
    if (versionBytes.length !== 1 || versionBytes[0] !== 2) return null;
    expectTag(required(fields[index++]), TAG_INTEGER); // serialNumber
    const innerAlgorithm = algorithmOid(der, required(fields[index++]));
    if (innerAlgorithm !== signatureAlgorithm) return null;
    const issuerNode = required(fields[index++]);
    expectTag(issuerNode, TAG_SEQUENCE);
    const validityNode = required(fields[index++]);
    expectTag(validityNode, TAG_SEQUENCE);
    const subjectNode = required(fields[index++]);
    expectTag(subjectNode, TAG_SEQUENCE);
    const spkiNode = required(fields[index++]);
    expectTag(spkiNode, TAG_SEQUENCE);

    let extensionsNode: DerNode | undefined;
    for (; index < fields.length; index++) {
      const node = fields[index];
      if (node.tag === 0x81 || node.tag === 0x82) continue; // issuer/subject unique IDs
      if (node.tag !== 0xa3 || extensionsNode) return null;
      extensionsNode = node;
    }

    const [notBefore, notAfter, ...validityRest] = childrenOf(der, validityNode);
    if (!notBefore || !notAfter || validityRest.length > 0) return null;
    const { oids: extensionOids, isCa } = extensionsNode
      ? readExtensions(der, extensionsNode)
      : { oids: new Set<string>(), isCa: false };
    return {
      der,
      tbs: der.slice(tbsNode.start, tbsNode.end),
      signatureAlgorithm,
      signature,
      issuer: der.slice(issuerNode.start, issuerNode.end),
      subject: der.slice(subjectNode.start, subjectNode.end),
      notBeforeMs: readTime(der, notBefore),
      notAfterMs: readTime(der, notAfter),
      spki: der.slice(spkiNode.start, spkiNode.end),
      publicKeyCurve: readCurve(der, spkiNode),
      extensionOids,
      isCa,
    };
  } catch {
    return null;
  }
}

/** True when `issuer` names, is a CA for, and ECDSA-signed `child`. */
export async function verifyIssuedBy(child: ParsedCertificate, issuer: ParsedCertificate): Promise<boolean> {
  if (!issuer.isCa || !bytesEqual(child.issuer, issuer.subject)) return false;
  const hash = ECDSA_HASHES[child.signatureAlgorithm];
  const curve = issuer.publicKeyCurve ? CURVES[issuer.publicKeyCurve] : undefined;
  if (!hash || !curve) return false;
  const raw = ecdsaDerToRaw(child.signature, curve.size);
  if (!raw) return false;
  try {
    const key = await crypto.subtle.importKey('spki', issuer.spki, { name: 'ECDSA', namedCurve: curve.name }, false, [
      'verify',
    ]);
    return await crypto.subtle.verify({ name: 'ECDSA', hash }, key, raw, child.tbs);
  } catch {
    return false;
  }
}

export function isValidAt(cert: ParsedCertificate, instantMs: number): boolean {
  return cert.notBeforeMs <= instantMs && instantMs <= cert.notAfterMs;
}

/** DER ECDSA-Sig-Value to the fixed-size r||s WebCrypto expects. */
export function ecdsaDerToRaw(signature: Bytes, size: number): Bytes | null {
  try {
    const top = readNode(signature, 0);
    if (top.tag !== TAG_SEQUENCE || top.end !== signature.length) return null;
    const parts = childrenOf(signature, top);
    if (parts.length !== 2) return null;
    const raw = new Uint8Array(size * 2);
    for (const [i, node] of parts.entries()) {
      expectTag(node, TAG_INTEGER);
      let value = contentOf(signature, node);
      if (value.length === 0 || value[0] & 0x80) return null; // r and s are positive
      if (value.length > 1 && value[0] === 0 && !(value[1] & 0x80)) return null; // not minimal
      if (value[0] === 0 && value.length > 1) value = value.subarray(1);
      if (value.length > size) return null;
      raw.set(value, i * size + size - value.length);
    }
    return raw;
  } catch {
    return null;
  }
}

function readExtensions(der: Bytes, node: DerNode): { oids: Set<string>; isCa: boolean } {
  const [list, ...rest] = childrenOf(der, node);
  if (!list || rest.length > 0) throw new DerError();
  expectTag(list, TAG_SEQUENCE);
  const oids = new Set<string>();
  let isCa = false;
  for (const extension of childrenOf(der, list)) {
    expectTag(extension, TAG_SEQUENCE);
    const parts = childrenOf(der, extension);
    if (parts.length < 2 || parts.length > 3) throw new DerError();
    const oidNode = parts[0];
    expectTag(oidNode, TAG_OID);
    const oid = decodeOid(contentOf(der, oidNode));
    if (oids.has(oid)) throw new DerError(); // RFC 5280: one instance per extension
    oids.add(oid);
    if (parts.length === 3) expectTag(parts[1], TAG_BOOLEAN);
    const value = parts[parts.length - 1];
    expectTag(value, TAG_OCTET_STRING);
    if (oid === OID_BASIC_CONSTRAINTS) isCa = readBasicConstraintsCa(contentOf(der, value));
  }
  return { oids, isCa };
}

function readBasicConstraintsCa(value: Bytes): boolean {
  const top = readNode(value, 0);
  if (top.tag !== TAG_SEQUENCE || top.end !== value.length) throw new DerError();
  const [first] = childrenOf(value, top);
  if (!first || first.tag !== TAG_BOOLEAN) return false; // cA DEFAULT FALSE
  const flag = contentOf(value, first);
  if (flag.length !== 1) throw new DerError();
  return flag[0] === 0xff;
}

function readCurve(der: Bytes, spkiNode: DerNode): string | null {
  const [algorithm, key, ...rest] = childrenOf(der, spkiNode);
  if (!algorithm || !key || rest.length > 0) throw new DerError();
  expectTag(algorithm, TAG_SEQUENCE);
  bitStringContent(der, key);
  const [oidNode, params] = childrenOf(der, algorithm);
  if (!oidNode) throw new DerError();
  expectTag(oidNode, TAG_OID);
  if (decodeOid(contentOf(der, oidNode)) !== OID_EC_PUBLIC_KEY) return null;
  if (!params || params.tag !== TAG_OID) return null;
  return decodeOid(contentOf(der, params));
}

function algorithmOid(der: Bytes, node: DerNode): string {
  expectTag(node, TAG_SEQUENCE);
  const [oidNode, ...params] = childrenOf(der, node);
  if (!oidNode || params.length > 1) throw new DerError();
  expectTag(oidNode, TAG_OID);
  return decodeOid(contentOf(der, oidNode));
}

function bitStringContent(der: Bytes, node: DerNode): Bytes {
  expectTag(node, TAG_BIT_STRING);
  const content = contentOf(der, node);
  if (content.length < 1 || content[0] !== 0) throw new DerError(); // no unused bits
  return content.slice(1);
}

function readTime(der: Bytes, node: DerNode): number {
  const text = String.fromCharCode(...contentOf(der, node));
  let match: RegExpExecArray | null;
  let year: number;
  if (node.tag === TAG_UTC_TIME) {
    match = /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text);
    if (!match) throw new DerError();
    const yy = Number(match[1]);
    year = yy >= 50 ? 1900 + yy : 2000 + yy; // RFC 5280 4.1.2.5.1
  } else if (node.tag === TAG_GENERALIZED_TIME) {
    match = /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text);
    if (!match) throw new DerError();
    year = Number(match[1]);
  } else {
    throw new DerError();
  }
  const [month, day, hour, minute, second] = match.slice(2).map(Number);
  const ms = Date.UTC(year, month - 1, day, hour, minute, second);
  const check = new Date(ms);
  if (
    check.getUTCFullYear() !== year || check.getUTCMonth() !== month - 1 || check.getUTCDate() !== day ||
    hour > 23 || minute > 59 || second > 59
  ) {
    throw new DerError();
  }
  return ms;
}

function decodeOid(content: Bytes): string {
  if (content.length === 0 || content[content.length - 1] & 0x80) throw new DerError();
  const arcs: number[] = [];
  let value = 0;
  let fresh = true;
  for (const byte of content) {
    if (fresh && byte === 0x80) throw new DerError(); // non-minimal subidentifier
    if (value > Number.MAX_SAFE_INTEGER / 128) throw new DerError();
    value = value * 128 + (byte & 0x7f);
    fresh = !(byte & 0x80);
    if (fresh) {
      arcs.push(value);
      value = 0;
    }
  }
  const first = arcs[0];
  const head = first < 40 ? [0, first] : first < 80 ? [1, first - 40] : [2, first - 80];
  return [...head, ...arcs.slice(1)].join('.');
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

// ---------------------------------------------------------------------------
// DER TLV reader: single-byte tags, definite minimal lengths, no overruns.

const TAG_BOOLEAN = 0x01;
const TAG_INTEGER = 0x02;
const TAG_BIT_STRING = 0x03;
const TAG_OCTET_STRING = 0x04;
const TAG_OID = 0x06;
const TAG_UTC_TIME = 0x17;
const TAG_GENERALIZED_TIME = 0x18;
const TAG_SEQUENCE = 0x30;

class DerError extends Error {}

interface DerNode {
  tag: number;
  /** Offset of the tag byte. */
  start: number;
  /** Offset of the first content byte. */
  contentStart: number;
  /** Offset after the last content byte. */
  end: number;
}

function readNode(buffer: Bytes, offset: number): DerNode {
  if (offset + 2 > buffer.length) throw new DerError();
  const tag = buffer[offset];
  if ((tag & 0x1f) === 0x1f) throw new DerError(); // high-tag-number form
  let length = buffer[offset + 1];
  let cursor = offset + 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    if (count === 0 || count > 3 || cursor + count > buffer.length) throw new DerError(); // indefinite or huge
    if (buffer[cursor] === 0) throw new DerError();
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + buffer[cursor + i];
    if (length < 0x80) throw new DerError(); // long form where short form fits
    cursor += count;
  }
  const end = cursor + length;
  if (end > buffer.length) throw new DerError();
  return { tag, start: offset, contentStart: cursor, end };
}

function childrenOf(buffer: Bytes, node: DerNode): DerNode[] {
  if (!(node.tag & 0x20)) throw new DerError(); // primitive
  const children: DerNode[] = [];
  let offset = node.contentStart;
  while (offset < node.end) {
    const child = readNode(buffer, offset);
    if (child.end > node.end) throw new DerError();
    children.push(child);
    offset = child.end;
  }
  return children;
}

function contentOf(buffer: Bytes, node: DerNode): Bytes {
  return buffer.subarray(node.contentStart, node.end);
}

function expectTag(node: DerNode, tag: number): void {
  if (node.tag !== tag) throw new DerError();
}

function required(node: DerNode | undefined): DerNode {
  if (!node) throw new DerError();
  return node;
}
