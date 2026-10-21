import { userToken } from "../_shared/auth_test_fixtures.ts";
import { handleRequest } from './handler.ts';
import { JPEG_BASE64, PNG_BASE64, WEBP_ALPHA_BASE64, WEBP_BASE64, WEBP_LOSSLESS_BASE64 } from './image_fixtures.ts';
import { claudeResponse, isClaudeCall } from '../_shared/claude_test_fixtures.ts';

Deno.env.set('SUPABASE_URL', 'https://supabase.test.invalid');
Deno.env.set('SUPABASE_ANON_KEY', 'test-anon-key');
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'test-service-key');
Deno.env.set('ANTHROPIC_API_KEY', 'test-provider-key');

const ATTEMPT_GATES = 'analyze-meal:ip,analyze-meal:user';
const ALL_GATES = `${ATTEMPT_GATES},analyze-meal:user-day,analyze-meal:global`;

function assertEquals(actual: unknown, expected: unknown, message = ''): void {
  if (actual !== expected) throw new Error(`${message}: expected ${expected}, got ${actual}`);
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status });
}

/** The image block the provider received: first content block of the only message. */
type ProviderImage = { first: boolean; type: string; mediaType: string; data: string };

async function probe(imageBase64: string) {
  const original = globalThis.fetch;
  const gates: string[] = [];
  const providerImages: ProviderImage[] = [];
  let reservations = 0;
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = String(input);
    if (url.endsWith("/rest/v1/rpc/reserve_ai_provider_call")) {
      reservations++;
      return Promise.resolve(json({ allowed: true, reason: "allowed" }));
    }
    if (url.endsWith('/auth/v1/user')) {
      return Promise.resolve(json({ id: '11111111-1111-4111-8111-111111111111' }));
    }
    if (url.endsWith('/rpc/consume_edge_rate_limits')) {
      const requested = JSON.parse(String(init?.body)).p_gates as {
        scope: string; limit: number; window_seconds: number;
      }[];
      gates.push(...requested.map((gate) => gate.scope));
      return Promise.resolve(json(requested.map((gate) => ({
        allowed: true, limit: gate.limit, remaining: gate.limit - 1,
        resetAt: '2026-09-15T00:00:00Z', windowSeconds: gate.window_seconds,
      }))));
    }
    if (url.endsWith('/rpc/prune_edge_rate_limits')) {
      return Promise.resolve(new Response(null, { status: 204 }));
    }
    if (isClaudeCall(url)) {
      const content = JSON.parse(String(init?.body)).messages[0].content as {
        type: string; source?: { media_type: string; data: string };
      }[];
      const index = content.findIndex((block) => block.type === 'image');
      const image = content[index];
      providerImages.push({ first: index === 0, type: image?.type, mediaType: image?.source?.media_type ?? '', data: image?.source?.data ?? '' });
      return Promise.resolve(json(claudeResponse(JSON.stringify({
        mealName: 'Test meal', caloriesKcal: 200, estimatedGrams: 100,
        kcalPer100G: 200, proteinG: 10, carbsG: 20, fatG: 9,
        confidence: 'low', explanation: 'Synthetic fixture.', items: [],
      }))));
    }
    throw new Error('Unexpected outbound route');
  }) as typeof fetch;
  try {
    const response = await handleRequest(new Request('https://function.test.invalid/analyze-meal', {
      method: 'POST',
      headers: {
        authorization: `Bearer ${userToken("11111111-1111-4111-8111-111111111111")}`, 'content-type': 'application/json',
        'cf-connecting-ip': '203.0.113.7',
      },
      body: JSON.stringify({ imageBase64 }),
    }));
    return { status: response.status, body: await response.json(), gates, providerImages, reservations };
  } finally {
    globalThis.fetch = original;
  }
}

/** The measured type and the bytes went out unchanged, as the first block. */
function assertProviderImage(image: ProviderImage | undefined, mime: string, base64: string, name: string): void {
  assertEquals(image?.first, true, `${name}: image block first`);
  assertEquals(image?.type, 'image', `${name}: image block`);
  assertEquals(image?.mediaType, mime, `${name}: measured type`);
  assertEquals(image?.data, base64, `${name}: bytes unchanged`);
}

// The handler's own base64 checks, plus one container the shared parser
// rejects. Every container, raster and animation case of the parser is pinned
// once, without a handler, in ../_shared/image_validation_test.ts.
const INVALID_IMAGES = [
  ['non-image bytes', btoa('NOT_AN_IMAGE_'.repeat(20))],
  ['incomplete base64 padding', PNG_BASE64.slice(0, -1)],
  ['excess base64 padding', `${PNG_BASE64}====`],
  ['noncanonical base64 padding bits', `${PNG_BASE64.slice(0, -3)}h==`],
] as const;

Deno.test('image validation: invalid image data stops before day quotas and provider', async () => {
  for (const [name, input] of INVALID_IMAGES) {
    const result = await probe(input);
    assertEquals(result.status, 400, `${name}: status`);
    assertEquals(result.body.error, 'invalid_image_base64', `${name}: code`);
    assertEquals(result.gates.join(','), ATTEMPT_GATES, `${name}: only the attempt gates`);
    assertEquals(result.providerImages.length, 0, `${name}: no provider call`);
  }
});

Deno.test('image validation: the measured type reaches the provider, never the label', async () => {
  for (const [mime, base64, label] of [
    ['image/jpeg', JPEG_BASE64, 'png'], ['image/png', PNG_BASE64, 'jpeg'], ['image/webp', WEBP_BASE64, 'jpeg'],
    ['image/webp', WEBP_LOSSLESS_BASE64, null], ['image/webp', WEBP_ALPHA_BASE64, null],
  ] as const) {
    for (const input of [base64, ...(label ? [`data:image/${label};base64,${base64}`] : [])]) {
      const result = await probe(input);
      const name = `${mime} ${input === base64 ? 'raw' : `labeled ${label}`}`;
      assertEquals(result.status, 200, `${name}: status`);
      assertEquals(result.gates.join(','), ALL_GATES, `${name}: gates`);
      assertEquals(result.providerImages.length, 1, `${name}: one provider call`);
      assertProviderImage(result.providerImages[0], mime, base64, name);
    }
  }
});

Deno.test('image validation: MIME line breaks preserve a real image', async () => {
  const result = await probe(`data:image/jpg;base64,${JPEG_BASE64.match(/.{1,64}/g)!.join('\r\n')}`);
  assertEquals(result.status, 200, 'status');
  assertProviderImage(result.providerImages[0], 'image/jpeg', JPEG_BASE64, 'line breaks');
});

// Claude rejects an image whose width or height exceeds 8000 px. Such a photo
// must end as 413 before the day quotas, the paid-call reservation and the
// provider; 8000 itself still goes through. Header-only fixtures: the preflight
// reads the declared size and never decodes pixels, so a thin 8001 x 8 image
// stays far inside the raster budget.

function crc32(bytes: string): number {
  let crc = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) {
    crc ^= bytes.charCodeAt(i);
    for (let bit = 0; bit < 8; bit++) crc = crc & 1 ? (crc >>> 1) ^ 0xedb88320 : crc >>> 1;
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function uint32(value: number): string {
  return String.fromCharCode(value >>> 24 & 0xff, value >>> 16 & 0xff, value >>> 8 & 0xff, value & 0xff);
}

/** The PNG fixture with another IHDR size and a valid IHDR CRC. */
function pngWithSize(width: number, height: number): string {
  const bytes = atob(PNG_BASE64);
  const ihdr = 'IHDR' + uint32(width) + uint32(height) + bytes.slice(24, 29);
  return btoa(bytes.slice(0, 12) + ihdr + uint32(crc32(ihdr)) + bytes.slice(33));
}

/** The baseline JPEG fixture with another SOF0 size. */
function jpegWithSize(width: number, height: number): string {
  const bytes = atob(JPEG_BASE64);
  const sof = bytes.indexOf('\xff\xc0') + 5;
  const u16 = (value: number) => String.fromCharCode(value >>> 8 & 0xff, value & 0xff);
  return btoa(bytes.slice(0, sof) + u16(height) + u16(width) + bytes.slice(sof + 4));
}

// The fixtures prove themselves: an 8000 px image that did not parse would not
// reach the provider below, and a broken 8001 px one would answer 400, not 413.
Deno.test('edge limit: over 8000 px -> 413 image_too_large before day quotas, reservation and provider', async () => {
  for (const [name, input] of [
    ['PNG 8001 px wide', pngWithSize(8001, 8)],
    ['PNG 8001 px high', pngWithSize(8, 8001)],
    ['JPEG 8001 px wide', jpegWithSize(8001, 8)],
    ['JPEG 8001 px high', jpegWithSize(8, 8001)],
  ] as const) {
    const result = await probe(input);
    assertEquals(result.status, 413, `${name}: status`);
    assertEquals(result.body.error, 'image_too_large', `${name}: code`);
    assertEquals(result.gates.join(','), ATTEMPT_GATES, `${name}: only the attempt gates`);
    assertEquals(result.reservations, 0, `${name}: no reservation`);
    assertEquals(result.providerImages.length, 0, `${name}: no provider call`);
  }
});

Deno.test('edge limit: exactly 8000 px still reaches the provider', async () => {
  for (const [name, mime, input] of [
    ['PNG 8000 px wide', 'image/png', pngWithSize(8000, 8)],
    ['PNG 8000 px high', 'image/png', pngWithSize(8, 8000)],
    ['JPEG 8000 px wide', 'image/jpeg', jpegWithSize(8000, 8)],
  ] as const) {
    const result = await probe(input);
    assertEquals(result.status, 200, `${name}: status`);
    assertEquals(result.gates.join(','), ALL_GATES, `${name}: gates`);
    assertEquals(result.reservations, 1, `${name}: one reservation`);
    assertProviderImage(result.providerImages[0], mime, input, name);
  }
});
