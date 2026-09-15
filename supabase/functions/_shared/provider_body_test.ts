import { readProviderBody } from './provider_body.ts';

function assert(value: boolean, message: string): void { if (!value) throw new Error(message); }

Deno.test('provider body respects byte boundaries and decodes split Unicode', async () => {
  const text = 'A😀B';
  const bytes = new TextEncoder().encode(text);
  const stream = () => new Response(new ReadableStream({
    start(controller) {
      for (const byte of bytes) controller.enqueue(new Uint8Array([byte]));
      controller.close();
    },
  }));
  assert(await readProviderBody(stream(), bytes.length, AbortSignal.timeout(1000)) === text, 'complete Unicode');
  assert(await readProviderBody(stream(), bytes.length - 1, AbortSignal.timeout(1000)) === null, 'bytes, not characters');
});

Deno.test('provider body deadline cancels a stalled body after headers', async () => {
  let cancelled = false;
  const response = new Response(new ReadableStream({ cancel() { cancelled = true; } }));
  let error: unknown;
  try { await readProviderBody(response, 100, AbortSignal.timeout(10)); } catch (caught) { error = caught; }
  assert(error instanceof DOMException && error.name === 'TimeoutError', 'same deadline error');
  assert(cancelled, 'stalled reader closed');
});
