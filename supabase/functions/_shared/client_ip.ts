// Derives the rate-limit subject from a request's proxy headers.
//
// Verified 2026-08-07, undocumented and free to change: the endpoints sit
// behind Cloudflare, which sets `cf-connecting-ip` from the TCP source address
// and APPENDS to `x-forwarded-for` — so a client-set value ends up leftmost,
// which is why the old `.split(",")[0]` read the attacker-controlled entry.
//
// The IP gate is a DAMPER against script floods, NOT a security boundary.
// Headers are normalised, not passed through: the RPC guards the subject at
// 512 chars, and without canonicalisation one sender gets several buckets.

/** Cap for the raw value; the longest IPv6 form with zone/port stays well
 *  below, and anything longer is not an IP. */
const MAX_RAW_IP_CHARS = 64;

const IPV4_RE = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
const IPV6_GROUP_RE = /^[0-9a-f]{1,4}$/;

function normalizeIpv4(value: string): string | null {
  const match = IPV4_RE.exec(value);
  if (!match) return null;
  const octets: number[] = [];
  for (let i = 1; i <= 4; i++) {
    const part = match[i];
    // Reject leading zeros: "01.2.3.4" and "1.2.3.4" would otherwise be two
    // buckets for one sender, and "010" is octal to some parsers.
    if (part.length > 1 && part.startsWith("0")) return null;
    const octet = Number(part);
    if (octet > 255) return null;
    octets.push(octet);
  }
  return octets.join(".");
}

/**
 * Validates an IPv6 address and truncates it to its /64 prefix: providers hand
 * out a whole /64 per customer and the lower bits rotate, so a /128 bucket is
 * no limit. Exception: IPv4-in-IPv6 comes back as the full IPv4, see below.
 */
function normalizeIpv6(value: string): string | null {
  let text = value.toLowerCase();

  // Strip the zone id ("fe80::1%eth0"); irrelevant for the bucket.
  const zoneAt = text.indexOf("%");
  if (zoneAt >= 0) text = text.slice(0, zoneAt);
  if (text.length === 0) return null;

  // At least two colons, otherwise it is not IPv6 notation.
  if (text.split(":").length < 3) return null;

  // "::" may appear at most once.
  const shorthandCount = text.split("::").length - 1;
  if (shorthandCount > 1) return null;

  let head: string[];
  let tail: string[];
  if (shorthandCount === 1) {
    const [rawHead, rawTail] = text.split("::");
    head = rawHead.length > 0 ? rawHead.split(":") : [];
    tail = rawTail.length > 0 ? rawTail.split(":") : [];
  } else {
    head = text.split(":");
    tail = [];
  }

  // Convert embedded IPv4 notation into two hex groups so the group
  // validation below applies.
  const combined = [...head, ...tail];
  const last = combined[combined.length - 1];
  if (last !== undefined && last.includes(".")) {
    const embedded = normalizeIpv4(last);
    if (!embedded) return null;
    const parts = embedded.split(".").map(Number);
    const high = ((parts[0] << 8) | parts[1]).toString(16);
    const low = ((parts[2] << 8) | parts[3]).toString(16);
    if (tail.length > 0) {
      tail.pop();
      tail.push(high, low);
    } else {
      head.pop();
      head.push(high, low);
    }
  }

  const present = head.length + tail.length;
  if (shorthandCount === 1) {
    // "::" has to replace at least one group.
    if (present > 7) return null;
  } else if (present !== 8) {
    return null;
  }

  const groups = [
    ...head,
    ...new Array<string>(8 - present).fill("0"),
    ...tail,
  ];
  for (const group of groups) {
    if (!IPV6_GROUP_RE.test(group)) return null;
  }

  const words = groups.map((group) => Number.parseInt(group, 16));

  // IPv4-in-IPv6 is an IPv4 client on a dual-stack socket, and the /64
  // truncation would cut off exactly the groups holding the IPv4, collapsing
  // all such clients into one bucket. Only the mapped form — the obsolete
  // "::a.b.c.d" stays on the IPv6 path, or "::1" would become an address.
  if (words[5] === 0xffff && words.slice(0, 5).every((word) => word === 0)) {
    return [
      words[6] >> 8,
      words[6] & 0xff,
      words[7] >> 8,
      words[7] & 0xff,
    ].join(".");
  }

  // Truncate to /64 and write the first four groups without leading zeros, so
  // "2001:0db8:..." and "2001:db8:..." hit the same bucket.
  const prefix = groups
    .slice(0, 4)
    .map((group) => Number.parseInt(group, 16).toString(16))
    .join(":");
  return `${prefix}::/64`;
}

/**
 * Accepts only real IP literals and returns them canonically (IPv4 dotted,
 * IPv6 as `<prefix>::/64`, IPv4-in-IPv6 as the embedded IPv4); else null.
 *
 * Accepted forms: "1.2.3.4", "1.2.3.4:51234", "2001:db8::1",
 * "[2001:db8::1]:443", "::ffff:1.2.3.4", "fe80::1%eth0".
 */
export function normalizeIp(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  let value = raw.trim();
  if (value.length === 0 || value.length > MAX_RAW_IP_CHARS) return null;

  // Bracket form "[2001:db8::1]" with optional ":port".
  if (value.startsWith("[")) {
    const close = value.indexOf("]");
    if (close < 0) return null;
    const rest = value.slice(close + 1);
    if (rest.length > 0 && !/^:\d{1,5}$/.test(rest)) return null;
    return normalizeIpv6(value.slice(1, close));
  }

  const colons = value.split(":").length - 1;
  if (colons >= 2) return normalizeIpv6(value);
  if (colons === 1) {
    // Exactly one colon -> IPv4 with port.
    const [host, port] = value.split(":");
    if (!/^\d{1,5}$/.test(port)) return null;
    value = host;
  }
  return normalizeIpv4(value);
}

/**
 * Returns the subject for the IP rate limit.
 *
 * Order: `cf-connecting-ip`, then `x-forwarded-for` RIGHT to left (reading
 * from the left picks the client-injected value), then the verified user id.
 * That fallback beats a shared literal like "unknown", which one abuser could
 * drain to lock out everyone. The `ip:` / `uid:` prefixes separate the
 * namespaces, or a crafted header could land in another user's bucket.
 */
export function clientIpSubject(req: Request, verifiedUserId: string): string {
  const connecting = normalizeIp(req.headers.get("cf-connecting-ip"));
  if (connecting) return `ip:${connecting}`;

  const forwarded = req.headers.get("x-forwarded-for");
  if (forwarded) {
    const parts = forwarded.split(",");
    for (let i = parts.length - 1; i >= 0; i--) {
      const candidate = normalizeIp(parts[i]);
      if (candidate) return `ip:${candidate}`;
    }
  }

  // Unreachable behind Cloudflare. If this shows up in function_logs, the
  // platform setup changed and the assumptions at the top need rechecking.
  console.warn("clientIpSubject: kein verwertbarer Client-IP-Header, Fallback auf uid");
  return `uid:${verifiedUserId}`;
}
