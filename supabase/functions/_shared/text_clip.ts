// Length caps that never split a surrogate pair.
//
// `text.slice(0, max)` counts UTF-16 units, so a cap can land between the two
// halves of an emoji. The lone surrogate then breaks every consumer: PostgREST
// rejects the insert or PATCH body, and Flutter draws U+FFFD in place of the
// whole text (SEC-1).

/** At most `max` UTF-16 units of `text`; a dangling high surrogate is dropped. */
export function clipUtf16(text: string, max: number): string {
  const cut = text.slice(0, max);
  const last = cut.charCodeAt(cut.length - 1);
  return last >= 0xd800 && last <= 0xdbff ? cut.slice(0, -1) : cut;
}
