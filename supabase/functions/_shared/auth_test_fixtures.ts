// Deliberately unsigned fixture. Unit tests stub the Auth server separately;
// this payload only exercises the context checks after that stub authenticates.
export function userToken(
  userId: string,
  overrides: Record<string, unknown> = {},
): string {
  const encode = (value: unknown) => btoa(JSON.stringify(value))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  return `${encode({ alg: "HS256", typ: "JWT" })}.${encode({
    sub: userId, aud: "authenticated", exp: Math.floor(Date.now() / 1000) + 3600,
    ...overrides,
  })}.synthetic-signature-not-valid`;
}
