import { readProviderBody } from '../_shared/provider_body.ts';
import { pageCaption } from './tiktok_page.ts';

export interface RecipeSource {
  url: string | null;
  title?: string;
  author?: string;
  unavailable?: boolean;
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
      method: 'GET', redirect: 'manual', signal: childSignal(signal),
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

const childSignal = (signal: AbortSignal) => AbortSignal.any([signal, AbortSignal.timeout(2500)]);

/** Public metadata first; bounded, inert page data is a fallback. No media fetches. */
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
  result.source.unavailable = true;
  try {
    const video = await resolveVideo(unique[0], signal);
    if (!video) return result;
    result.source.url = video.href;
    const endpoint = new URL('https://www.tiktok.com/oembed');
    endpoint.searchParams.set('url', video.href);
    let caption = '';
    let author = '';
    for (let attempt = 0; attempt < 2 && !signal.aborted; attempt++) {
      try {
        const requestSignal = childSignal(signal);
        const response = await fetch(endpoint, {
          method: 'GET', redirect: 'error', signal: requestSignal,
          headers: { accept: 'application/json' },
        });
        if (!response.ok) {
          await response.body?.cancel();
          if (response.status === 429 || response.status >= 500) continue;
          break;
        }
        const raw = await readProviderBody(response, 96_000, requestSignal);
        const metadata = raw === null ? null : JSON.parse(raw);
        if (typeof metadata?.title === 'string') caption = metadata.title.trim();
        if (typeof metadata?.author_name === 'string') author = metadata.author_name.trim();
        break;
      } catch { /* Retry transient metadata failures within the source deadline. */ }
    }
    if (!caption || /(?:\u2026|\.\.\.)$/.test(caption)) {
      try {
        const requestSignal = childSignal(signal);
        const response = await fetch(video, {
          method: 'GET', redirect: 'manual', signal: requestSignal,
          headers: { accept: 'text/html' },
        });
        if (response.ok) {
          const html = await readProviderBody(response, 2_000_000, requestSignal);
          const page = html === null ? null : pageCaption(html, video.pathname.split('/').at(-1)!);
          if (page && page.title.length > caption.length) {
            caption = page.title.trim();
            author = page.author ?? author;
          }
        } else await response.body?.cancel();
      } catch { /* Login pages, challenges and unavailable public pages stay unavailable. */ }
    }
    if (!caption) return result;
    caption = [...caption].filter((char) => {
      const code = char.charCodeAt(0);
      return code !== 127 && (code >= 32 || code === 9 || code === 10 || code === 13);
    }).join('');
    result.source.title = caption.slice(0, 160);
    if (author) result.source.author = author.slice(0, 160);
    result.source.unavailable = false;
    const combined = sharedText ? `${sharedText}\n\n${caption}` : caption;
    result.text = combined.slice(0, MAX_SOURCE_CHARS);
    result.truncated = combined.length > MAX_SOURCE_CHARS || /(?:\u2026|\.\.\.)$/.test(caption);
    result.incomplete = false;
  } catch {
    // Private/deleted posts, platform restrictions, redirects and metadata outages
    // all preserve pasted text as the fallback, without leaking upstream bodies.
  }
  return result;
}
