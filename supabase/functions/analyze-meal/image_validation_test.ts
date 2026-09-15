import { userToken } from "../_shared/auth_test_fixtures.ts";
import { handleRequest } from './handler.ts';
import { JPEG_BASE64, PNG_BASE64, WEBP_ALPHA_BASE64, WEBP_BASE64, WEBP_LOSSLESS_BASE64 } from './image_fixtures.ts';

Deno.env.set('SUPABASE_URL', 'https://supabase.test.invalid');
Deno.env.set('SUPABASE_ANON_KEY', 'test-anon-key');
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'test-service-key');
Deno.env.set('OPENROUTER_API_KEY', 'test-provider-key');

const ATTEMPT_GATES = 'analyze-meal:ip,analyze-meal:user';
const ALL_GATES = `${ATTEMPT_GATES},analyze-meal:user-day,analyze-meal:global`;

function assertEquals(actual: unknown, expected: unknown): void {
  if (actual !== expected) throw new Error(`Expected ${expected}, got ${actual}`);
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status });
}

async function probe(imageBase64: string) {
  const original = globalThis.fetch;
  const gates: string[] = [];
  const providerImages: string[] = [];
  globalThis.fetch = ((input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = String(input);
    if (url.endsWith("/rest/v1/rpc/reserve_ai_provider_call")) return Promise.resolve(json({ allowed: true, reason: "allowed" }));
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
    if (url === 'https://openrouter.ai/api/v1/chat/completions') {
      const body = JSON.parse(String(init?.body));
      providerImages.push(body.messages[1].content[1].image_url.url);
      return Promise.resolve(json({ choices: [{ message: { content: JSON.stringify({
        mealName: 'Test meal', caloriesKcal: 200, estimatedGrams: 100,
        kcalPer100G: 200, proteinG: 10, carbsG: 20, fatG: 9,
        confidence: 'low', explanation: 'Synthetic fixture.', items: [],
      }) } }] }));
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
    return { status: response.status, body: await response.json(), gates, providerImages };
  } finally {
    globalThis.fetch = original;
  }
}

function changeByte(base64: string, offset: number, value: number): string {
  const bytes = atob(base64);
  return btoa(bytes.slice(0, offset) + String.fromCharCode(value) + bytes.slice(offset + 1));
}

const INVALID_IMAGES = [
  ['non-image bytes', btoa('NOT_AN_IMAGE_'.repeat(20))],
  ['truncated JPEG', btoa(atob(JPEG_BASE64).slice(0, 180))],
  ['truncated PNG', btoa(atob(PNG_BASE64).slice(0, -1))],
  ['truncated WebP', btoa(atob(WEBP_BASE64).slice(0, -1))],
  ['wrong PNG header length', changeByte(PNG_BASE64, 11, 12)],
  ['wrong WebP container length', changeByte(WEBP_BASE64, 4, 0)],
  ['unknown WebP image chunk', changeByte(WEBP_BASE64, 12, 0)],
  ['incomplete base64 padding', PNG_BASE64.slice(0, -1)],
  ['excess base64 padding', `${PNG_BASE64}====`],
  ['noncanonical base64 padding bits', `${PNG_BASE64.slice(0, -3)}h==`],
] as const;

for (const [name, input] of INVALID_IMAGES) {
  Deno.test(`image validation: ${name} stops before day quotas and provider`, async () => {
    const result = await probe(input);
    assertEquals(result.status, 400);
    assertEquals(result.body.error, 'invalid_image_base64');
    assertEquals(result.gates.join(','), ATTEMPT_GATES);
    assertEquals(result.providerImages.length, 0);
  });
}

for (const [mime, base64] of [
  ['image/jpeg', JPEG_BASE64], ['image/png', PNG_BASE64], ['image/webp', WEBP_BASE64],
] as const) {
  for (const labeled of [false, true]) {
    Deno.test(`image validation: real ${mime}, ${labeled ? 'mislabeled' : 'raw'}, uses measured type`, async () => {
      const result = await probe(labeled ? `data:image/${mime === 'image/jpeg' ? 'png' : 'jpeg'};base64,${base64}` : base64);
      assertEquals(result.status, 200);
      assertEquals(result.gates.join(','), ALL_GATES);
      assertEquals(result.providerImages.length, 1);
      assertEquals(result.providerImages[0], `data:${mime};base64,${base64}`);
    });
  }
}

Deno.test('image validation: MIME line breaks preserve a real image', async () => {
  const result = await probe(`data:image/jpg;base64,${JPEG_BASE64.match(/.{1,64}/g)!.join('\r\n')}`);
  assertEquals(result.status, 200);
  assertEquals(result.providerImages[0], `data:image/jpeg;base64,${JPEG_BASE64}`);
});

for (const [name, base64] of [['lossless', WEBP_LOSSLESS_BASE64], ['alpha', WEBP_ALPHA_BASE64]]) {
  Deno.test(`image validation: real WebP with ${name} remains supported`, async () => {
    const result = await probe(base64);
    assertEquals(result.status, 200);
    assertEquals(result.gates.join(','), ALL_GATES);
    assertEquals(result.providerImages[0], `data:image/webp;base64,${base64}`);
  });
}

// Tiny header mutations only: no raster allocations or decompression bombs.
for (const [name, input] of [
  ['JPEG framing without pixels', btoa('\xff\xd8\xffnot a jpeg\xff\xd9')],
  ['PNG over raster budget', changeByte(PNG_BASE64, 16, 1)],
  ['WebP lossy over raster budget', changeByte(changeByte(changeByte(changeByte(WEBP_BASE64, 26, 0xff), 27, 0x3f), 28, 0xff), 29, 0x3f)],
] as const) {
  Deno.test(`raster boundary: ${name} stops before paid quotas`, async () => {
    const result = await probe(input);
    assertEquals(result.status, 400);
    assertEquals(result.gates.join(','), ATTEMPT_GATES);
    assertEquals(result.providerImages.length, 0);
  });
}
