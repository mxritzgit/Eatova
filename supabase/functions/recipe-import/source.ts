import { readProviderBody } from '../_shared/provider_body.ts';

export interface RecipeSource {
  url: string | null;
  title?: string;
  author?: string;
}

export interface SourceContent {
  source: RecipeSource;
  text: string;
  incomplete: boolean;
  truncated: boolean;
}

const VIDEO_HOSTS = new Set(['www.tiktok.com', 'tiktok.com', 'm.tiktok.com']);
const SHORT_HOSTS = new Set(['vm.tiktok.com', 'vt.tiktok.com']);
const MAX_SOURCE_CHARS = 20_000;

/** Exact hosts and paths only; no credentials, custom ports, or URL schemes. */
export function supportedTikTokUrl(raw: string): URL | null {
  if (raw.length > 2048 || /[\\\s]/u.test(raw) || /\/(?:\.|%2e){1,2}(?:\/|[?#]|$)/i.test(raw)) return null;
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  if (url.protocol !== 'https:' || url.username || url.password || url.port) return null;
  const video = VIDEO_HOSTS.has(url.hostname) && /^\/@[\w.-]{1,64}\/video\/\d{10,25}\/?$/.test(url.pathname);
  const short = (SHORT_HOSTS.has(url.hostname) && /^\/[A-Za-z0-9]{5,40}\/?$/.test(url.pathname)) ||
    (VIDEO_HOSTS.has(url.hostname) && /^\/t\/[A-Za-z0-9]{5,40}\/?$/.test(url.pathname));
  if (!video && !short) return null;
  // Tracking parameters never enter model input, attribution, or subsequent fetches.
  url.search = '';
  url.hash = '';
  if (VIDEO_HOSTS.has(url.hostname)) url.hostname = 'www.tiktok.com';
  const path = url.pathname.replace(/\/$/, '');
  url.pathname = video ? path : `${path}/`;
  return url;
}

function isVideo(url: URL): boolean {
  return url.hostname === 'www.tiktok.com' && url.pathname.startsWith('/@');
}

async function resolveVideo(initial: URL, signal: AbortSignal): Promise<URL | null> {
  let current = initial;
  for (let redirects = 0; redirects < 4; redirects++) {
    if (isVideo(current)) return current;
    const response = await fetch(current, {
      method: 'GET', redirect: 'manual', signal,
      headers: { accept: 'text/html' },
    });
    await response.body?.cancel();
    if (![301, 302, 303, 307, 308].includes(response.status)) return null;
    const location = response.headers.get('location');
    if (!location) return null;
    const next = supportedTikTokUrl(new URL(location, current).href);
    if (!next) return null;
    current = next;
  }
  return isVideo(current) ? current : null;
}

/** Fetch only TikTok's public oEmbed metadata. HTML and media are never loaded. */
export async function loadSource(text: string, signal: AbortSignal): Promise<SourceContent> {
  const links = text.match(/https?:\/\/[^\s<>"']+/giu) ?? [];
  const cleaned = links.map((link) => link.replace(/[),.!?;]+$/u, ''));
  const allTargets = new Set(cleaned.map((link) => {
    const supported = supportedTikTokUrl(link);
    if (supported) return supported.href;
    try { return new URL(link).href; } catch { return link; }
  }));
  const urls = cleaned.map(supportedTikTokUrl).filter((url) => url !== null);
  const unique = [...new Map(urls.map((url) => [url.href, url])).values()];
  const sharedText = text.replace(/https?:\/\/[^\s<>"']+/giu, '').trim();
  const result: SourceContent = {
    source: { url: unique.length === 1 && allTargets.size === 1 ? unique[0].href : null },
    text: sharedText,
    incomplete: links.length > 0,
    truncated: false,
  };
  // Multiple links require user-supplied text; choosing a video would be arbitrary.
  if (unique.length !== 1 || allTargets.size !== 1) return result;
  try {
    const video = await resolveVideo(unique[0], signal);
    if (!video) return result;
    result.source.url = video.href;
    const endpoint = new URL('https://www.tiktok.com/oembed');
    endpoint.searchParams.set('url', video.href);
    const response = await fetch(endpoint, {
      method: 'GET', redirect: 'error', signal,
      headers: { accept: 'application/json' },
    });
    if (!response.ok) {
      await response.body?.cancel();
      return result;
    }
    const raw = await readProviderBody(response, 96_000, signal);
    if (raw === null) return result;
    const metadata = JSON.parse(raw);
    if (typeof metadata?.title !== 'string' || !metadata.title.trim()) return result;
    const caption = metadata.title.trim();
    result.source.title = caption.slice(0, 160);
    if (typeof metadata.author_name === 'string' && metadata.author_name.trim()) {
      result.source.author = metadata.author_name.trim().slice(0, 160);
    }
    const combined = sharedText ? `${sharedText}\n\n${caption}` : caption;
    result.text = combined.slice(0, MAX_SOURCE_CHARS);
    result.truncated = combined.length > MAX_SOURCE_CHARS;
    result.incomplete = false;
  } catch {
    // Private/deleted posts, platform restrictions, redirects and metadata outages
    // all preserve pasted text as the fallback, without leaking upstream bodies.
  }
  return result;
}
