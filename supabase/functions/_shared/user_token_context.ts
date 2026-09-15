// Context binding, not signature verification. Call only AFTER the project's
// Auth /user endpoint has authenticated this exact bearer token.
const USER_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function hasExpectedUserTokenContext(token: string, verifiedUserId: string): boolean {
  if (!USER_ID.test(verifiedUserId) || token.length > 16_384) return false;
  const parts = token.split(".");
  if (parts.length !== 3 || !parts[0] || !parts[2] || !/^[A-Za-z0-9_-]+$/.test(parts[1])) return false;
  try {
    const encoded = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const bytes = Uint8Array.from(atob(encoded + "=".repeat((4 - encoded.length % 4) % 4)), (c) => c.charCodeAt(0));
    const claims = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    const audience = claims?.aud;
    const appAudience = audience === "authenticated" ||
      (Array.isArray(audience) && audience.length === 1 && audience[0] === "authenticated");
    // GoTrue checks expiry/nbf using its own clock. Require an expiration claim,
    // but do not introduce a second clock or a different skew tolerance here.
    return claims?.sub === verifiedUserId && appAudience &&
      typeof claims.exp === "number" && Number.isFinite(claims.exp) && claims.exp > 0;
  } catch {
    return false;
  }
}
