import { loadSource, supportedTikTokUrl } from './source.ts';

// Synthetic stand-in for TikTok's observed photo-post (slideshow) behaviour: the
// share link redirects to /photo/<id> with tracking, oEmbed answers 400 for that
// URL and the photo page carries no post data. The same ID's /video/ form serves
// the full caption from oEmbed and from the public page.
const ID = '1234567890123456789';
const PHOTO = `https://www.tiktok.com/@cook/photo/${ID}`;
const LOOKUP = `https://www.tiktok.com/@cook/video/${ID}`;
const SHORT = 'https://vm.tiktok.com/ZGabcdefg/';
const TRACKED = `${PHOTO}?_r=1&_t=ZG-tracking`;
const CAPTION = 'Protein Bowl\n200 g Skyr\n50 g Haferflocken\nAlles verrühren.';

function check(value: unknown, message: string): asserts value {
  if (!value) throw new Error(message);
}
function rehydration(scope: Record<string, unknown>): string {
  return '<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">' +
    JSON.stringify({ __DEFAULT_SCOPE__: { 'webapp.app-context': { language: 'de' }, ...scope } }) + '</script>';
}
type Call = { url: string; redirect?: RequestRedirect };
function tiktok(calls: Call[], metadata: unknown = { title: CAPTION, author_name: 'Cook' }, location = TRACKED) {
  return ((input: string | URL | Request, init?: RequestInit) => {
    const url = new URL(String(input));
    calls.push({ url: url.href, redirect: init?.redirect });
    if (url.href === SHORT) return Promise.resolve(new Response(null, { status: 301, headers: { location } }));
    if (url.origin + url.pathname === 'https://www.tiktok.com/oembed') {
      return Promise.resolve(url.searchParams.get('url') === LOOKUP ? Response.json(metadata)
        : Response.json({ message: 'Something went wrong', code: 400 }, { status: 400 }));
    }
    if (url.href === PHOTO) return Promise.resolve(new Response(rehydration({})));
    if (url.href === LOOKUP) return Promise.resolve(new Response(rehydration({ 'webapp.video-detail': { itemInfo: {
      itemStruct: { id: ID, desc: CAPTION, author: { uniqueId: 'cook' }, imagePost: { images: [{}, {}] } },
    } } })));
    return Promise.reject(new Error('Unexpected outbound request'));
  }) as typeof fetch;
}
const lookupOf = (call: Call | undefined) => call && new URL(call.url).searchParams.get('url');

Deno.test('import source accepts TikTok photo posts with the video URL safety rules', () => {
  check(supportedTikTokUrl(`${TRACKED}#slide`)?.href === PHOTO, 'Tracking stripped from photo posts');
  check(supportedTikTokUrl(`${PHOTO}/`)?.href === PHOTO, 'Photo slash spelling has one identity');
  check(supportedTikTokUrl(`https://m.tiktok.com/@cook/photo/${ID}`)?.href === PHOTO, 'Mobile host canonical');
  check(supportedTikTokUrl(`https://tiktok.com/@cook/photo/${ID}`)?.href === PHOTO, 'Bare host canonical');
  const invalid = [
    `http://www.tiktok.com/@cook/photo/${ID}`,
    `https://www.tiktok.com.evil.invalid/@cook/photo/${ID}`,
    `https://user:password@www.tiktok.com/@cook/photo/${ID}`,
    `https://www.tiktok.com:8443/@cook/photo/${ID}`,
    `https://vm.tiktok.com/@cook/photo/${ID}`,
    'https://www.tiktok.com/@cook/photo/123456789',
    `https://www.tiktok.com/@cook/photo/${ID}0000000`,
    `https://www.tiktok.com/@cook/photo/${ID}/extra`,
    `https://www.tiktok.com/@cook/photos/${ID}`,
    `https://www.tiktok.com/@cook/photo/../video/${ID}`,
    `https://www.tiktok.com/@cook/photo/%2e%2e/${ID}`,
    `https://www.tiktok.com/@co%2Fok/photo/${ID}`,
    `https://www.tiktok.com/photo/${ID}`,
    `https://www.tiktok.com/music/original-sound-${ID}`,
    'https://www.tiktok.com/tag/pasta', 'https://www.tiktok.com/discover/protein-bowl',
    'https://www.tiktok.com/@cook', 'https://www.tiktok.com/@cook/live',
    `https://www.tiktok.com/@cook/collection/bowls-${ID}`,
  ];
  for (const url of invalid) check(supportedTikTokUrl(url) === null, `Reject ${url}`);
});

Deno.test('import source short link to a photo post imports the caption via the video lookup', async () => {
  const original = globalThis.fetch;
  const calls: Call[] = [];
  globalThis.fetch = tiktok(calls);
  try {
    const result = await loadSource(SHORT, AbortSignal.timeout(1000));
    check(calls.length === 2 && calls[0].url === SHORT && calls[0].redirect === 'manual', 'Manual short-link redirect');
    check(lookupOf(calls[1]) === LOOKUP && calls[1].redirect === 'error', 'oEmbed asked for the video form');
    check(!calls.some((call) => call.url.includes('tracking')), 'Tracking not forwarded');
    check(result.source.url === PHOTO && result.source.unavailable === false, 'Canonical photo attribution');
    check(result.source.author === 'Cook' && result.text === CAPTION, 'Caption imported');
    check(!result.incomplete && !result.truncated, 'Complete source');
  } finally { globalThis.fetch = original; }
});

Deno.test('import source direct photo and video links look up the same video form', async () => {
  const original = globalThis.fetch;
  try {
    for (const [input, attribution] of [[TRACKED, PHOTO], [LOOKUP, LOOKUP]]) {
      const calls: Call[] = [];
      globalThis.fetch = tiktok(calls);
      const result = await loadSource(`Mein Rezept ${input}`, AbortSignal.timeout(1000));
      check(calls.length === 1 && lookupOf(calls[0]) === LOOKUP, 'Single oEmbed lookup');
      check(result.source.url === attribution && result.source.unavailable === false, 'Attribution kept');
      check(result.text === `Mein Rezept\n\n${CAPTION}` && !result.incomplete, 'Caption imported');
    }
  } finally { globalThis.fetch = original; }
});

Deno.test('import source photo page fallback reads the caption from the video page', async () => {
  const original = globalThis.fetch;
  try {
    for (const metadata of [{ title: 'Protein Bowl\n200 g Skyr…' }, { title: '' }, { message: 'missing' }]) {
      const calls: Call[] = [];
      globalThis.fetch = tiktok(calls, metadata);
      const result = await loadSource(TRACKED, AbortSignal.timeout(1000));
      check(calls.length === 2 && lookupOf(calls[0]) === LOOKUP, 'oEmbed asked for the video form');
      check(calls[1].url === LOOKUP && calls[1].redirect === 'manual', 'Video page fetched without redirects');
      check(result.text === CAPTION && result.source.author === 'cook', 'Full caption from page data');
      check(result.source.url === PHOTO && !result.incomplete && !result.truncated, 'Complete photo source');
    }
  } finally { globalThis.fetch = original; }
});

Deno.test('import source short link to an unsupported or unsafe target stops before a second fetch', async () => {
  const original = globalThis.fetch;
  try {
    for (const location of [
      'https://www.tiktok.com/tag/pasta', `https://www.tiktok.com/music/original-sound-${ID}`,
      `https://www.tiktok.com.evil.invalid/@cook/photo/${ID}`, `http://www.tiktok.com/@cook/photo/${ID}`,
    ]) {
      const calls: Call[] = [];
      globalThis.fetch = tiktok(calls, undefined, location);
      const result = await loadSource(`${SHORT}\n200 g Skyr`, AbortSignal.timeout(1000));
      check(calls.length === 1 && result.incomplete && result.source.unavailable, 'Redirect target never fetched');
      check(result.text === '200 g Skyr', 'Pasted fallback retained');
    }
  } finally { globalThis.fetch = original; }
});
