// Tests for the offline App Store JWS verifier (jws_apple.ts). Generated
// P-384 root/intermediate and P-256 leaf with an injected root pin, plus
// one check against Apple's real root and WWDR G6 intermediate. No network.

import {
  APPLE_INTERMEDIATE_OID,
  APPLE_ROOT_CA_G3_BASE64,
  APPLE_ROOT_CA_G3_SHA256,
  type AppleJwsFailure,
  isValidAt,
  parseCertificate,
  verifyAppleJws,
  verifyIssuedBy,
} from './jws_apple.ts';
import { base64ToBytes, base64UrlToBytes, bytesToBase64Url } from './jose.ts';
import {
  APPLE_WWDR_G6_BASE64,
  assert,
  assertEquals,
  buildAppleChain,
  type ChainKeys,
  ecKeyPair,
  generateChainKeys,
  rawToDerSignature,
  sha256Hex,
  signEs256Jws,
  type TestChain,
  toBase64,
} from './store_test_fixtures.ts';

const NOW = Date.parse('2026-10-25T08:00:00.000Z');
const PAYLOAD = {
  transactionId: '2000000812345678',
  originalTransactionId: '2000000812345678',
  bundleId: 'com.eatova.app',
  productId: 'eatova_premium_yearly',
  type: 'Auto-Renewable Subscription',
  inAppOwnershipType: 'PURCHASED',
  environment: 'Sandbox',
  appAccountToken: '00000000-0000-4000-8000-0000000000a1',
  purchaseDate: NOW - 60_000,
  expiresDate: NOW + 7 * 86_400_000,
  signedDate: NOW - 1_000,
};

let keysPromise: Promise<ChainKeys> | undefined;
const chainKeys = () => keysPromise ??= generateChainKeys();

function jws(
  chain: TestChain,
  overrides: { header?: Record<string, unknown>; payload?: Record<string, unknown> } = {},
) {
  return signEs256Jws(
    { alg: 'ES256', x5c: chain.x5c, ...overrides.header },
    overrides.payload ?? PAYLOAD,
    chain.leafKey,
  );
}

Deno.test("jws_apple: the embedded root is Apple Root CA - G3 and verifies Apple's real WWDR G6 intermediate", async () => {
  const rootDer = base64ToBytes(APPLE_ROOT_CA_G3_BASE64)!;
  assertEquals(await sha256Hex(rootDer), APPLE_ROOT_CA_G3_SHA256, 'Fingerabdruck der eingebetteten Wurzel');
  const root = parseCertificate(rootDer);
  const wwdrDer = base64ToBytes(APPLE_WWDR_G6_BASE64)!;
  const wwdr = parseCertificate(wwdrDer);
  assert(root && wwdr, 'beide echten Zertifikate werden gelesen');
  assert(root.isCa && wwdr.isCa, 'basicConstraints cA');
  assert(wwdr.extensionOids.has(APPLE_INTERMEDIATE_OID), 'WWDR G6 traegt die Intermediate-OID');
  assert(isValidAt(root, NOW) && isValidAt(wwdr, NOW), 'beide heute gueltig');
  assert(!isValidAt(wwdr, Date.parse('2036-03-19T00:00:01Z')), 'notAfter 2036-03-19 gelesen');
  assert(await verifyIssuedBy(wwdr, root), 'echte P-384/SHA-384-Signatur der Apple-Wurzel');

  // One flipped byte in the signed subject breaks the real signature.
  const tampered = wwdrDer.slice();
  const at = String.fromCharCode(...tampered).indexOf('Worldwide');
  assert(at > 0, 'Subject gefunden');
  tampered[at] ^= 0x01;
  const tamperedCert = parseCertificate(tampered);
  assert(tamperedCert && !(await verifyIssuedBy(tamperedCert, root)), 'veraenderte TBS wird abgelehnt');
  assert(!(await verifyIssuedBy(root, wwdr)), 'falsche Richtung wird abgelehnt');
});

Deno.test('jws_apple: a valid chain and ES256 signature return the payload and signedDate', async () => {
  const chain = await buildAppleChain(await chainKeys());
  const result = await verifyAppleJws(await jws(chain), { nowMs: NOW, rootSha256: chain.rootSha256 });
  assert(result.ok, `ok erwartet, war ${JSON.stringify(result)}`);
  assertEquals(result.payload, PAYLOAD, 'Payload');
  assertEquals(result.signedDateMs, PAYLOAD.signedDate, 'signedDate');
});

Deno.test('jws_apple: every broken link is rejected with its reason', async () => {
  const keys = await chainKeys();
  const chain = await buildAppleChain(keys);
  const foreign = await ecKeyPair('P-384');
  const valid = await jws(chain);
  const [headerSegment, , signatureSegment] = valid.split('.');
  const otherPayload = bytesToBase64Url(new TextEncoder().encode(JSON.stringify({ ...PAYLOAD, productId: 'x' })));
  const truncated = toBase64(chain.ders[1].subarray(0, chain.ders[1].length - 1));
  const trailing = toBase64(new Uint8Array([...chain.ders[1], 0]));
  const rawSignature = base64UrlToBytes(signatureSegment)!;
  const derSigned = `${valid.slice(0, valid.lastIndexOf('.'))}.${bytesToBase64Url(rawToDerSignature(rawSignature))}`;
  const rebuilt = (overrides: Parameters<typeof buildAppleChain>[1]) => buildAppleChain(keys, overrides);
  const p384Leaf = await ecKeyPair('P-384');
  const p384Chain = await rebuilt({ leaf: { publicKey: p384Leaf.publicKey } });

  const cases: { was: string; token: string | Promise<string>; reason: AppleJwsFailure; pin?: string }[] = [
    { was: 'veraenderter Payload', token: `${headerSegment}.${otherPayload}.${signatureSegment}`, reason: 'signature' },
    { was: 'DER- statt r||s-Signatur', token: derSigned, reason: 'signature' },
    {
      was: 'Leaf-Schluessel P-384 statt P-256',
      token: signEs256Jws({ alg: 'ES256', x5c: p384Chain.x5c }, PAYLOAD, p384Leaf.privateKey),
      reason: 'signature',
    },
    // Each alg row carries a valid ES256 signature: only the pin can reject it.
    { was: "alg 'none'", token: jws(chain, { header: { alg: 'none' } }), reason: 'algorithm' },
    { was: 'alg HS256', token: jws(chain, { header: { alg: 'HS256' } }), reason: 'algorithm' },
    { was: 'alg RS256', token: jws(chain, { header: { alg: 'RS256' } }), reason: 'algorithm' },
    { was: 'alg ES384', token: jws(chain, { header: { alg: 'ES384' } }), reason: 'algorithm' },
    { was: 'alg fehlt', token: jws(chain, { header: { alg: undefined } }), reason: 'algorithm' },
    { was: 'Standard-Pin (Apple) gegen Testwurzel', token: valid, reason: 'root', pin: APPLE_ROOT_CA_G3_SHA256 },
    {
      was: 'fremde Wurzel mit gleichem Namen',
      token: rebuilt({ root: { publicKey: foreign.publicKey, signingKey: foreign.privateKey } }).then((c) => jws(c)),
      reason: 'root',
    },
    { was: '2 Zertifikate', token: jws(chain, { header: { x5c: chain.x5c.slice(0, 2) } }), reason: 'chain_length' },
    {
      was: '4 Zertifikate',
      token: jws(chain, { header: { x5c: [...chain.x5c, chain.x5c[2]] } }),
      reason: 'chain_length',
    },
    {
      was: 'Leaf ohne Apple-OID',
      token: rebuilt({ leaf: { extensionOids: [] } }).then((c) => jws(c)),
      reason: 'oid',
    },
    {
      was: 'Intermediate ohne Apple-OID',
      token: rebuilt({ intermediate: { extensionOids: [] } }).then((c) => jws(c)),
      reason: 'oid',
    },
    {
      was: 'Leaf von fremdem Schluessel signiert',
      token: rebuilt({ leaf: { signingKey: foreign.privateKey } }).then((c) => jws(c)),
      reason: 'chain_signature',
    },
    {
      was: 'Intermediate von fremdem Schluessel signiert',
      token: rebuilt({ intermediate: { signingKey: foreign.privateKey } }).then((c) => jws(c)),
      reason: 'chain_signature',
    },
    {
      was: 'Intermediate ist keine CA',
      token: rebuilt({ intermediate: { ca: false } }).then((c) => jws(c)),
      reason: 'chain_signature',
    },
    {
      was: 'Leaf nennt einen anderen Aussteller',
      token: rebuilt({ leaf: { issuer: 'Someone Else' } }).then((c) => jws(c)),
      reason: 'chain_signature',
    },
    {
      was: 'Leaf bei signedDate abgelaufen',
      token: rebuilt({ leaf: { notAfterMs: NOW - 60_000 } }).then((c) => jws(c)),
      reason: 'validity',
    },
    {
      was: 'Intermediate bei signedDate noch nicht gueltig',
      token: rebuilt({ intermediate: { notBeforeMs: NOW } }).then((c) => jws(c)),
      reason: 'validity',
    },
    {
      was: 'signedDate in der Zukunft',
      token: jws(chain, { payload: { ...PAYLOAD, signedDate: NOW + 3_600_000 } }),
      reason: 'validity',
    },
    {
      was: 'signedDate fehlt',
      token: jws(chain, { payload: { ...PAYLOAD, signedDate: undefined } }),
      reason: 'payload',
    },
    {
      was: 'x5c-Eintrag kein Base64',
      token: jws(chain, { header: { x5c: ['@@@@', ...chain.x5c.slice(1)] } }),
      reason: 'malformed',
    },
    {
      was: 'x5c-DER abgeschnitten',
      token: jws(chain, { header: { x5c: [chain.x5c[0], truncated, chain.x5c[2]] } }),
      reason: 'certificate',
    },
    {
      was: 'x5c-DER mit Restbyte',
      token: jws(chain, { header: { x5c: [chain.x5c[0], trailing, chain.x5c[2]] } }),
      reason: 'certificate',
    },
    { was: 'crit-Header', token: jws(chain, { header: { crit: ['b64'] } }), reason: 'malformed' },
    { was: 'zwei Segmente', token: `${headerSegment}.${signatureSegment}`, reason: 'malformed' },
    { was: 'Payload kein Base64url', token: `${headerSegment}.e30=.${signatureSegment}`, reason: 'malformed' },
  ];
  for (const row of cases) {
    const result = await verifyAppleJws(await row.token, { nowMs: NOW, rootSha256: row.pin ?? chain.rootSha256 });
    assertEquals(result, { ok: false, reason: row.reason }, row.was);
  }
});
