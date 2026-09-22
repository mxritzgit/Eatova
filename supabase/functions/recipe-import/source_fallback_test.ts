import { loadSource } from './source.ts';
import { pageCaption } from './tiktok_page.ts';

const ID = '1234567890123456789';
const VIDEO = 'https://www.tiktok.com/@cook/video/' + ID;
function check(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}
function page(id = ID) {
  return '<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">' +
    JSON.stringify({ __DEFAULT_SCOPE__: { 'webapp.video-detail': { itemInfo: {
      itemStruct: { id, desc: '200 g Pasta\nPasta kochen.\n450 kcal pro Portion', author: { uniqueId: 'cook' } },
    } } } }) + '</script>';
}

Deno.test('public page fallback binds caption to exact video ID and ignores markup', () => {
  check(pageCaption(page(), ID)?.title.includes('200 g Pasta'), 'Caption from requested post');
  check(pageCaption(page('9999999999999999999'), ID) === null, 'Recommendation is not requested post');
  check(pageCaption('<script>alert("recipe")</script><meta name="description" content="fake">', ID) === null, 'No execution or generic metadata');
  check(pageCaption('<script id="SIGI_STATE">broken</script>', ID) === null, 'Malformed data ignored');
  check(pageCaption('<script id="SIGI_STATE">' + JSON.stringify({ ItemModule: { [ID]: { id: ID, desc: 'Caption', author: 'cook' } } }) + '</script>', ID)?.author === 'cook', 'Legacy public page data');
});

Deno.test('source retries a transient oEmbed outage and never sends app credentials', async () => {
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = ((_url: unknown, init?: RequestInit) => {
    check(!new Headers(init?.headers).has('authorization'), 'No credentials forwarded');
    return Promise.resolve(++calls === 1 ? new Response(null, { status: 503 }) : Response.json({ title: '200 g Pasta\nPasta kochen.' }));
  }) as typeof fetch;
  try {
    const result = await loadSource(VIDEO, AbortSignal.timeout(1000));
    check(calls === 2 && !result.incomplete && result.source.unavailable === false, 'Metadata recovered');
  } finally { globalThis.fetch = original; }
});

Deno.test('source falls back from inaccessible oEmbed to exact public page data', async () => {
  const original = globalThis.fetch;
  const calls: string[] = [];
  globalThis.fetch = ((url: unknown, init?: RequestInit) => {
    calls.push(String(url));
    if (String(url).includes('/oembed?')) return Promise.resolve(new Response(null, { status: 403 }));
    check(String(url) === VIDEO && init?.redirect === 'manual', 'Only requested page, no arbitrary redirects');
    return Promise.resolve(new Response(page()));
  }) as typeof fetch;
  try {
    const result = await loadSource(VIDEO, AbortSignal.timeout(1000));
    check(calls.length === 2 && !result.incomplete && result.text.includes('450 kcal'), 'Fallback preserved full caption');
  } finally { globalThis.fetch = original; }
});

Deno.test('source blocked page never follows a login or private-host redirect', async () => {
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = ((url: unknown) => {
    calls++;
    return Promise.resolve(String(url).includes('/oembed?') ? new Response(null, { status: 403 })
      : new Response(null, { status: 302, headers: { location: 'https://127.0.0.1/private' } }));
  }) as typeof fetch;
  try {
    const result = await loadSource(VIDEO, AbortSignal.timeout(1000));
    check(calls === 2 && result.source.unavailable && !result.text, 'No hidden redirect or invented caption');
  } finally { globalThis.fetch = original; }
});
