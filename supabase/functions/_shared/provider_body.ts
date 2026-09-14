/** Read a provider body within byte and fetch-deadline bounds; null means oversized. */
export async function readProviderBody(response: Response, maxBytes: number, signal: AbortSignal): Promise<string | null> {
  signal.throwIfAborted();
  if (!response.body) return '';
  const reader = response.body.getReader();
  const abort = () => { void reader.cancel().catch(() => {}); };
  signal.addEventListener('abort', abort, { once: true });
  const decoder = new TextDecoder();
  let bytes = 0;
  let text = '';
  try {
    while (true) {
      signal.throwIfAborted();
      const { done, value } = await reader.read();
      signal.throwIfAborted();
      if (done) return text + decoder.decode();
      bytes += value.byteLength;
      if (bytes > maxBytes) return null;
      text += decoder.decode(value, { stream: true });
    }
  } finally {
    signal.removeEventListener('abort', abort);
    void reader.cancel().catch(() => {});
  }
}
