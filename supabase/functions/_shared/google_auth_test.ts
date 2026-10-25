// Tests for google_auth.ts: the service-account access token (RS256 JWT
// bearer grant, per-isolate cache) and Pub/Sub OIDC verification against a
// cached JWKS. Generated RSA keys, stubbed fetch, fixed clock. No network.

import {
  ANDROID_PUBLISHER_SCOPE,
  clearGoogleAuthCaches,
  GOOGLE_OIDC_CERTS_URL,
  GOOGLE_TOKEN_URI,
  googleAccessToken,
  type GoogleOidcFailure,
  verifyGoogleOidcToken,
} from './google_auth.ts';
import { bytesToBase64Url, decodeJwsPayload, parseCompactJws } from './jose.ts';
import {
  assert,
  assertEquals,
  pkcs8Pem,
  publicJwk,
  rsaKeyPair,
  signRs256Jwt,
  withFetchStub,
} from './store_test_fixtures.ts';

const NOW = Date.parse('2026-10-25T08:00:00.000Z');
const NOW_S = NOW / 1000;
const SA_EMAIL = 'play-verify@eatova-test.iam.gserviceaccount.com';
const ACCESS_TOKEN = 'ya29.c.test-access-token';
const AUDIENCE = 'https://eatova-test.supabase.co/functions/v1/store-notifications';
const PUSH_EMAIL = 'pubsub-push@eatova-test.iam.gserviceaccount.com';

let rsaPromise: Promise<{ signer: CryptoKeyPair; other: CryptoKeyPair }> | undefined;
const rsa = () =>
  rsaPromise ??= Promise.all([rsaKeyPair(), rsaKeyPair()]).then(([signer, other]) => ({ signer, other }));

async function keyJson(fields: Record<string, unknown> = {}): Promise<string> {
  const { signer } = await rsa();
  return JSON.stringify({
    type: 'service_account',
    project_id: 'eatova-test',
    private_key_id: 'abc123',
    private_key: await pkcs8Pem(signer.privateKey),
    client_email: SA_EMAIL,
    ...fields,
  });
}

const tokenReply = (
  body: Record<string, unknown> = { access_token: ACCESS_TOKEN, expires_in: 3599, token_type: 'Bearer' },
) => Response.json(body);

async function accessTokenAt(json: string, nowMs: number) {
  return await googleAccessToken(json, { signal: AbortSignal.timeout(5_000), nowMs });
}

Deno.test('google_auth: service-account RS256 grant is posted as a form and cached until 60 s before expiry', async () => {
  clearGoogleAuthCaches();
  const { signer } = await rsa();
  const json = await keyJson(); // no token_uri: the default applies
  await withFetchStub(() => tokenReply(), async (calls, logs) => {
    assertEquals(await accessTokenAt(json, NOW), { ok: true, accessToken: ACCESS_TOKEN }, 'Token');
    assertEquals(calls.length, 1, 'ein Abruf');
    const call = calls[0];
    assertEquals([call.url, call.method, call.redirect], [GOOGLE_TOKEN_URI, 'POST', 'error'], 'Endpunkt');
    assertEquals(call.headers.get('content-type'), 'application/x-www-form-urlencoded', 'Formular');
    const form = new URLSearchParams(call.body);
    assertEquals(form.get('grant_type'), 'urn:ietf:params:oauth:grant-type:jwt-bearer', 'grant_type');
    const assertion = parseCompactJws(form.get('assertion') ?? '', 8192);
    assert(assertion, 'Assertion ist ein kompaktes JWS');
    assertEquals(assertion.header, { alg: 'RS256', typ: 'JWT', kid: 'abc123' }, 'JWT-Header');
    assert(
      await crypto.subtle.verify('RSASSA-PKCS1-v1_5', signer.publicKey, assertion.signature, assertion.signingInput),
      'mit dem Service-Account-Schluessel signiert',
    );
    assertEquals(decodeJwsPayload(assertion), {
      iss: SA_EMAIL,
      scope: ANDROID_PUBLISHER_SCOPE,
      aud: GOOGLE_TOKEN_URI,
      iat: NOW_S,
      exp: NOW_S + 3600,
    }, 'Claims');

    await accessTokenAt(json, NOW + (3599 - 61) * 1000);
    assertEquals(calls.length, 1, 'bis 60 s vor Ablauf aus dem Cache');
    assertEquals(await accessTokenAt(json, NOW + (3599 - 59) * 1000), { ok: true, accessToken: ACCESS_TOKEN }, 'neu');
    assertEquals(calls.length, 2, 'danach neu geholt');
    assert(
      !logs.some((line) => line.includes(ACCESS_TOKEN) || line.includes('PRIVATE KEY')),
      'nichts Geheimes geloggt',
    );
  });
});

Deno.test('google_auth: unusable keys and token-endpoint failures are typed, never thrown', async () => {
  const { signer } = await rsa();
  const pkcs1 = (await pkcs8Pem(signer.privateKey)).replace(/PRIVATE KEY/g, 'RSA PRIVATE KEY');
  const cases: { was: string; json: string; reply?: () => Response; reason: string }[] = [
    { was: 'kein JSON', json: '{"client_email":', reason: 'invalid_key' },
    { was: 'client_email fehlt', json: await keyJson({ client_email: undefined }), reason: 'invalid_key' },
    { was: 'PKCS#1 statt PKCS#8', json: await keyJson({ private_key: pkcs1 }), reason: 'invalid_key' },
    {
      was: 'PEM-Rumpf kaputt',
      json: await keyJson({ private_key: '-----BEGIN PRIVATE KEY-----\n@@\n-----END PRIVATE KEY-----' }),
      reason: 'invalid_key',
    },
    {
      was: 'token_uri ohne https',
      json: await keyJson({ token_uri: 'http://oauth2.googleapis.com/token' }),
      reason: 'invalid_key',
    },
    {
      was: 'token_uri fremder Host',
      json: await keyJson({ token_uri: 'https://example.com/token' }),
      reason: 'invalid_key',
    },
    {
      was: 'invalid_grant 400',
      json: await keyJson(),
      reply: () => Response.json({ error: 'invalid_grant' }, { status: 400 }),
      reason: 'rejected',
    },
    {
      was: 'HTTP 503',
      json: await keyJson(),
      reply: () => new Response('busy', { status: 503 }),
      reason: 'unavailable',
    },
    {
      was: 'HTTP 429',
      json: await keyJson(),
      reply: () => new Response('slow', { status: 429 }),
      reason: 'unavailable',
    },
    {
      was: 'ohne access_token',
      json: await keyJson(),
      reply: () => tokenReply({ expires_in: 3599 }),
      reason: 'unavailable',
    },
    {
      was: 'expires_in 0',
      json: await keyJson(),
      reply: () => tokenReply({ access_token: ACCESS_TOKEN, expires_in: 0 }),
      reason: 'unavailable',
    },
    {
      was: 'token_type MAC',
      json: await keyJson(),
      reply: () => tokenReply({ access_token: ACCESS_TOKEN, expires_in: 60, token_type: 'MAC' }),
      reason: 'unavailable',
    },
    { was: 'kein JSON-Objekt', json: await keyJson(), reply: () => new Response('[1]'), reason: 'unavailable' },
    {
      was: 'uebergross',
      json: await keyJson(),
      reply: () => new Response('x'.repeat(17 * 1024)),
      reason: 'unavailable',
    },
    {
      was: 'Netzfehler/Redirect verweigert',
      json: await keyJson(),
      reply: () => {
        throw new TypeError('redirect refused');
      },
      reason: 'unavailable',
    },
  ];
  for (const row of cases) {
    clearGoogleAuthCaches();
    await withFetchStub(row.reply ?? (() => tokenReply()), async (calls) => {
      assertEquals(await accessTokenAt(row.json, NOW), { ok: false, reason: row.reason }, row.was);
      assertEquals(calls.length, row.reply ? 1 : 0, `${row.was}: Abrufe`);
    });
  }
  clearGoogleAuthCaches();
});

// ---------------------------------------------------------------------------
// OIDC

function claims(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    aud: AUDIENCE,
    azp: '102938475610293847561',
    email: PUSH_EMAIL,
    email_verified: true,
    exp: NOW_S + 3000,
    iat: NOW_S - 600,
    iss: 'https://accounts.google.com',
    sub: '102938475610293847561',
    ...overrides,
  };
}

async function jwksReply(kids: string[], cacheControl = 'public, max-age=19876, must-revalidate, no-transform') {
  const { signer } = await rsa();
  const keys = await Promise.all(kids.map((kid) => publicJwk(signer.publicKey, kid)));
  return () => Response.json({ keys }, { headers: { 'cache-control': cacheControl } });
}

async function oidcToken(
  overrides: Record<string, unknown> = {},
  header: Record<string, unknown> = {},
  key?: CryptoKey,
) {
  const { signer } = await rsa();
  return signRs256Jwt(
    { alg: 'RS256', kid: 'kid-1', typ: 'JWT', ...header },
    claims(overrides),
    key ?? signer.privateKey,
  );
}

function verifyAt(token: string, nowMs: number, expect: { audience?: string; email?: string } = {}) {
  return verifyGoogleOidcToken(token, {
    audience: expect.audience ?? AUDIENCE,
    email: expect.email ?? PUSH_EMAIL,
    signal: AbortSignal.timeout(5_000),
    nowMs,
  });
}

Deno.test('google_auth: a Google push token verifies; the JWKS is cached per max-age and refetched for a new kid', async () => {
  clearGoogleAuthCaches();
  const reply = await jwksReply(['kid-1'], 'public, max-age=3600');
  const rotated = await jwksReply(['kid-1', 'kid-2'], 'public, max-age=3600');
  let current = reply;
  await withFetchStub(() => current(), async (calls) => {
    for (const iss of ['https://accounts.google.com', 'accounts.google.com']) {
      const result = await verifyAt(await oidcToken({ iss }), NOW);
      assert(result.ok && result.claims.email === PUSH_EMAIL, `${iss}: ok`);
    }
    const lateButInSkew = await verifyAt(await oidcToken({ exp: NOW_S - 30 }), NOW);
    assert(lateButInSkew.ok, 'exp innerhalb der Toleranz');
    assertEquals(calls.length, 1, 'JWKS einmal geholt');
    assertEquals(
      [calls[0].url, calls[0].method, calls[0].redirect],
      [GOOGLE_OIDC_CERTS_URL, 'GET', 'error'],
      'JWKS-Abruf',
    );

    current = rotated;
    const newKid = await oidcToken({}, { kid: 'kid-2' });
    assertEquals(
      await verifyAt(newKid, NOW + 30_000),
      { ok: false, reason: 'key' },
      'neuer kid, Cache juenger als 60 s',
    );
    assertEquals(calls.length, 1, 'kein Hammern bei unbekanntem kid');
    assert((await verifyAt(newKid, NOW + 61_000)).ok, 'neuer kid nach 60 s: einmal neu geholt');
    assertEquals(calls.length, 2, 'Rotation holt neu');

    const fresh = await oidcToken({ exp: NOW_S + 7000, iat: NOW_S + 3000 });
    assert((await verifyAt(fresh, NOW + 61_000 + 3_599_000)).ok, 'innerhalb max-age');
    assertEquals(calls.length, 2, 'max-age respektiert');
    assert((await verifyAt(fresh, NOW + 61_000 + 3_600_000)).ok, 'nach max-age');
    assertEquals(calls.length, 3, 'nach max-age neu geholt');
  });
  clearGoogleAuthCaches();
});

Deno.test('google_auth: OIDC tokens with a wrong claim, key or algorithm are rejected with their reason', async () => {
  const { other } = await rsa();
  const valid = await oidcToken();
  const [header, , signature] = valid.split('.');
  const forged = claims({ email: 'attacker@example.com' });
  const forgedPayload = bytesToBase64Url(new TextEncoder().encode(JSON.stringify(forged)));
  const cases: {
    was: string;
    token: string | Promise<string>;
    reason: GoogleOidcFailure;
    jwks?: () => Response;
    expect?: { audience?: string; email?: string };
  }[] = [
    {
      was: 'falsche Audience',
      token: oidcToken({ aud: 'https://evil.example/functions/v1/store-notifications' }),
      reason: 'audience',
    },
    { was: 'Audience als Liste', token: oidcToken({ aud: [AUDIENCE, 'other'] }), reason: 'audience' },
    { was: 'falscher Issuer', token: oidcToken({ iss: 'https://accounts.example.com' }), reason: 'issuer' },
    {
      was: 'falsche E-Mail',
      token: oidcToken({ email: 'someone@eatova-test.iam.gserviceaccount.com' }),
      reason: 'email',
    },
    { was: 'email_verified false', token: oidcToken({ email_verified: false }), reason: 'email' },
    { was: 'email_verified fehlt', token: oidcToken({ email_verified: undefined }), reason: 'email' },
    { was: 'abgelaufen', token: oidcToken({ exp: NOW_S - 61 }), reason: 'expired' },
    {
      was: 'iat in der Zukunft',
      token: oidcToken({ iat: NOW_S + 120, exp: NOW_S + 3720 }),
      reason: 'issued_in_future',
    },
    { was: 'exp fehlt', token: oidcToken({ exp: undefined }), reason: 'malformed' },
    // Algorithm rows carry a valid RS256 signature: only the pin rejects them.
    { was: "alg 'none'", token: oidcToken({}, { alg: 'none' }), reason: 'algorithm' },
    { was: 'alg HS256', token: oidcToken({}, { alg: 'HS256' }), reason: 'algorithm' },
    { was: 'unbekannter kid', token: oidcToken({}, { kid: 'kid-unknown' }), reason: 'key' },
    { was: 'kid fehlt', token: oidcToken({}, { kid: undefined }), reason: 'malformed' },
    { was: 'veraenderter Payload', token: `${header}.${forgedPayload}.${signature}`, reason: 'signature' },
    { was: 'fremder Schluessel, gleicher kid', token: oidcToken({}, {}, other.privateKey), reason: 'signature' },
    { was: 'kein JWT', token: 'not-a-jwt', reason: 'malformed' },
    { was: 'JWKS 503', token: valid, reason: 'jwks_unavailable', jwks: () => new Response('down', { status: 503 }) },
    {
      was: 'JWKS ohne RSA-Schluessel',
      token: valid,
      reason: 'jwks_unavailable',
      jwks: () => Response.json({ keys: [{ kty: 'EC' }] }),
    },
    { was: 'keine Audience konfiguriert', token: valid, reason: 'not_configured', expect: { audience: '' } },
  ];
  const jwks = await jwksReply(['kid-1']);
  for (const row of cases) {
    clearGoogleAuthCaches();
    await withFetchStub(row.jwks ?? jwks, async () => {
      assertEquals(await verifyAt(await row.token, NOW, row.expect), { ok: false, reason: row.reason }, row.was);
    });
  }
  clearGoogleAuthCaches();
});
