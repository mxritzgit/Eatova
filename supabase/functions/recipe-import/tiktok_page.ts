/** Read inert public page data for this exact post; never execute HTML/scripts. */
export function pageCaption(html: string, videoId: string): { title: string; author?: string } | null {
  for (const match of html.matchAll(/<script\b[^>]*\bid\s*=\s*["'](__UNIVERSAL_DATA_FOR_REHYDRATION__|SIGI_STATE)["'][^>]*>([\s\S]*?)<\/script\s*>/gi)) {
    try {
      const data = JSON.parse(match[2]);
      const item = match[1] === 'SIGI_STATE' ? data?.ItemModule?.[videoId]
        : data?.__DEFAULT_SCOPE__?.['webapp.video-detail']?.itemInfo?.itemStruct;
      if (!item || String(item.id) !== videoId || typeof item.desc !== 'string' || !item.desc.trim()) continue;
      const author = typeof item.author === 'string' ? item.author : item.author?.uniqueId;
      return { title: item.desc, ...(typeof author === 'string' ? { author } : {}) };
    } catch { /* A challenge or malformed script is not recipe evidence. */ }
  }
  return null;
}
