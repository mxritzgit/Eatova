import { loadSource, supportedTikTokUrl } from './source.ts';

function check(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}
const VIDEO = 'https://www.tiktok.com/@cook/video/1234567890123456789';
const SHORT = 'https://vm.tiktok.com/ZMabcdef/';

Deno.test('import source accepts canonical TikTok videos and strips tracking', () => {
  check(supportedTikTokUrl(`${VIDEO}?tracking=secret#section`)?.href === VIDEO, 'Canonical attribution');
  check(supportedTikTokUrl(SHORT)?.href === SHORT, 'Short share links');
  check(supportedTikTokUrl(SHORT.slice(0, -1))?.href === SHORT, 'Short slash spelling has one identity');
  check(supportedTikTokUrl(`${VIDEO}/`)?.href === VIDEO, 'Canonical video slash spelling has one identity');
  check(supportedTikTokUrl('https://www.tiktok.com/t/ZMabcdef/') !== null, 'TikTok /t share links');
  check(supportedTikTokUrl('https://m.tiktok.com/t/ZMabcdef/')?.href === 'https://www.tiktok.com/t/ZMabcdef/', 'Mobile short links use the wire canonical host');
});

Deno.test('import source repeated equivalent video links with tracking load one source', async () => {
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = (() => { calls++; return Promise.resolve(Response.json({ title: 'Caption' })); }) as typeof fetch;
  try {
    const result = await loadSource(`${VIDEO}?tracking=one ${VIDEO}/?tracking=two ${VIDEO}#fragment`, AbortSignal.timeout(1000));
    check(calls === 1 && result.source.url === VIDEO && !result.incomplete, 'Equivalent share spellings are not multiple sources');
  } finally { globalThis.fetch = original; }
});

Deno.test('import source failed mobile short link stays compatible with client source validation', async () => {
  const original = globalThis.fetch;
  const calls: string[] = [];
  globalThis.fetch = ((url: string | URL | Request) => {
    calls.push(String(url));
    return Promise.resolve(new Response(null, { status: 403 }));
  }) as typeof fetch;
  try {
    const result = await loadSource('https://m.tiktok.com/t/ZMabcdef/ https://www.tiktok.com/t/ZMabcdef/', AbortSignal.timeout(1000));
    check(calls.length === 1 && calls[0] === 'https://www.tiktok.com/t/ZMabcdef/', 'Equivalent hosts deduplicate before fetching');
    check(result.incomplete && result.source.url === 'https://www.tiktok.com/t/ZMabcdef/', 'Fallback has supported canonical source');
  } finally { globalThis.fetch = original; }
});

Deno.test('import source blocks arbitrary URLs, credentials, schemes, ports and fake TikTok hosts', () => {
  const invalid = [
    'http://www.tiktok.com/@cook/video/1234567890123456789',
    'https://www.tiktok.com.evil.invalid/@cook/video/1234567890123456789',
    'https://www.tiktok.com@127.0.0.1/@cook/video/1234567890123456789',
    'https://user:password@www.tiktok.com/@cook/video/1234567890123456789',
    'https://www.tiktok.com:8443/@cook/video/1234567890123456789',
    'https://127.0.0.1/', 'https://169.254.169.254/latest/meta-data/',
    'https://www.tiktok.com/oembed', 'file:///etc/passwd',
    'https://vm.tiktok.com/../../secret', 'https://vm.tiktok.com/ZMabc\\evil',
  ];
  for (const url of invalid) check(supportedTikTokUrl(url) === null, 'Reject unsafe target');
});

Deno.test('import source fetches oEmbed metadata only, never HTML or video URLs', async () => {
  const original = globalThis.fetch;
  const calls: Array<{ url: string; init?: RequestInit }> = [];
  globalThis.fetch = ((url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init });
    return Promise.resolve(Response.json({ title: '200 g Pasta\nPasta kochen.', author_name: 'Cook', html: '<script>evil()</script>', thumbnail_url: 'https://evil.invalid/private' }));
  }) as typeof fetch;
  try {
    const result = await loadSource(`${VIDEO}?secret=tracking`, AbortSignal.timeout(1000));
    check(calls.length === 1 && calls[0].url.startsWith('https://www.tiktok.com/oembed?url='), 'Only fixed public metadata endpoint');
    check(calls[0].init?.redirect === 'error', 'No oEmbed redirects');
    check(result.source.url === VIDEO && result.source.author === 'Cook', 'Attribution retained');
    check(!result.text.includes('evil') && !result.incomplete, 'HTML ignored');
  } finally { globalThis.fetch = original; }
});

Deno.test('import source resolves short links manually before metadata request', async () => {
  const original = globalThis.fetch;
  const calls: string[] = [];
  globalThis.fetch = ((url: string | URL | Request, init?: RequestInit) => {
    calls.push(String(url));
    if (calls.length === 1) {
      check(init?.redirect === 'manual', 'Manual short-link redirects');
      return Promise.resolve(new Response(null, { status: 302, headers: { location: `${VIDEO}?tracking=private` } }));
    }
    return Promise.resolve(Response.json({ title: 'Caption' }));
  }) as typeof fetch;
  try {
    const result = await loadSource(SHORT, AbortSignal.timeout(1000));
    check(calls.length === 2 && result.source.url === VIDEO, 'Resolved canonical URL');
    check(!calls[1].includes('tracking'), 'Tracking not forwarded');
  } finally { globalThis.fetch = original; }
});

Deno.test('import source redirects and failed metadata do not wait for stalled body cancellation', async () => {
  const original = globalThis.fetch;
  const stalled = (status: number, headers?: HeadersInit) => new Response(new ReadableStream<Uint8Array>({
    cancel() { return new Promise<void>(() => {}); },
  }), { status, headers });
  try {
    for (const scenario of ['redirect', 'metadata', 'page'] as const) {
      const calls: string[] = [];
      globalThis.fetch = ((url: string | URL | Request) => {
        const target = String(url);
        calls.push(target);
        if (scenario === 'redirect') return Promise.resolve(calls.length === 1
          ? stalled(302, { location: VIDEO }) : Response.json({ title: 'Caption' }));
        if (target.includes('/oembed?')) return Promise.resolve(scenario === 'metadata'
          ? stalled(403) : Response.json({ title: '' }));
        return Promise.resolve(stalled(403));
      }) as typeof fetch;
      let timer: ReturnType<typeof setTimeout> | undefined;
      try {
        const result = await Promise.race([
          loadSource(scenario === 'redirect' ? SHORT : VIDEO, AbortSignal.timeout(1000)),
          new Promise<never>((_resolve, reject) => {
            timer = setTimeout(() => reject(new Error(`${scenario} waited for stalled body.cancel()`)), 1000);
          }),
        ]);
        check(scenario === 'redirect' ? result.source.url === VIDEO && !result.incomplete : result.incomplete,
          'source outcome preserved');
        check(calls.length === 2, 'bounded source requests');
      } finally { clearTimeout(timer); }
    }
  } finally { globalThis.fetch = original; }
});

Deno.test('import source blocks redirect SSRF before second fetch and preserves pasted text', async () => {
  for (const location of ['http://127.0.0.1/private', 'https://169.254.169.254/', 'https://www.tiktok.com.evil.invalid/secret', 'https://user:secret@www.tiktok.com/@cook/video/1234567890123456789']) {
    const original = globalThis.fetch;
    let calls = 0;
    globalThis.fetch = (() => { calls++; return Promise.resolve(new Response(null, { status: 302, headers: { location } })); }) as typeof fetch;
    try {
      const result = await loadSource(`${SHORT}\n200 g Pasta\nPasta kochen.`, AbortSignal.timeout(1000));
      check(calls === 1 && result.incomplete, 'Forbidden redirect never fetched');
      check(result.text.includes('200 g Pasta'), 'Pasted fallback retained');
    } finally { globalThis.fetch = original; }
  }
});

Deno.test('import source bounds redirect chains and metadata body size', async () => {
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = (() => { calls++; return Promise.resolve(new Response(null, { status: 302, headers: { location: SHORT } })); }) as typeof fetch;
  try {
    const result = await loadSource(SHORT, AbortSignal.timeout(1000));
    check(calls === 4 && result.incomplete, 'Bounded redirects');
    globalThis.fetch = (() => Promise.resolve(Response.json({ title: 'A'.repeat(100_000) }))) as typeof fetch;
    const oversized = await loadSource(VIDEO, AbortSignal.timeout(1000));
    check(!oversized.text && oversized.incomplete, 'Oversized metadata rejected');
  } finally { globalThis.fetch = original; }
});

Deno.test('import source never fetches unsupported, multiple or absent links', async () => {
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = (() => { calls++; throw new Error('Unexpected fetch'); }) as typeof fetch;
  try {
    for (const text of ['https://example.invalid/recipe', `${VIDEO} ${SHORT}`, `${VIDEO} https://example.invalid/other-recipe`, '200 g Pasta\nPasta kochen.']) {
      const result = await loadSource(text, AbortSignal.timeout(1000));
      check(result.source.url === null, 'No arbitrary attribution');
    }
    check(calls === 0, 'Unsupported sources never fetched');
  } finally { globalThis.fetch = original; }
});

Deno.test('import source treats private posts and malformed metadata as text-needed', async () => {
  const original = globalThis.fetch;
  try {
    for (const response of [new Response('private token secret', { status: 403 }), new Response('broken'), Response.json({ title: '' })]) {
      globalThis.fetch = (() => Promise.resolve(response)) as typeof fetch;
      const result = await loadSource(VIDEO, AbortSignal.timeout(1000));
      check(result.incomplete && result.text === '', 'Unavailable source');
      check(!JSON.stringify(result).includes('secret'), 'No upstream diagnostic exposure');
    }
  } finally { globalThis.fetch = original; }
});
