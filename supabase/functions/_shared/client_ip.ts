// Ermittlung des Rate-Limit-Subjects aus den Proxy-Headern eines Requests.
//
// ---------------------------------------------------------------------------
// VERIFIZIERTES PLATTFORM-VERHALTEN (geprueft am 2026-08-07 gegen den
// Projekt-Ref ftoozzvmduptrvrrrshb):
//
//  * Die Function-Endpunkte unter *.supabase.co liegen hinter Cloudflare
//    (`Server: cloudflare`, `CF-Ray`- und `__cf_bm`-Header sind beobachtbar).
//  * `cf-connecting-ip` wird von Cloudflare aus der TCP-Quelladresse gesetzt.
//    Ein vom Client mitgeschickter Wert hat nachweislich keinerlei Wirkung
//    (gegengeprueft ueber /cdn-cgi/trace derselben Zone mit gespooften
//    Headern) -> das ist der einzige halbwegs vertrauenswuerdige Header.
//  * `x-forwarded-for` wird von Cloudflare ANGEHAENGT, nicht ersetzt. Ein vom
//    Client gesetzter Wert steht danach GANZ LINKS, die real beobachtete
//    Adresse GANZ RECHTS. Der frueher benutzte `.split(",")[0]` griff damit
//    exakt den vom Angreifer kontrollierten Eintrag ab -> jeder Request
//    konnte sich ein frisches IP-Bucket aussuchen und das IP-Limit war
//    faktisch wirkungslos.
//  * Supabase dokumentiert nichts davon. Das Verhalten kann sich mit einer
//    Plattform-Aenderung verschieben.
//
// DESHALB AUSDRUECKLICH: Das IP-Gate ist ein DAEMPFER (Kostenbremse gegen
// Skript-Fluten), KEINE Sicherheitsgrenze. Die tatsaechliche Durchsetzung
// haengt am User-Gate und an claim_chat_quota, deren Subject aus einem
// serverseitig verifizierten JWT (/auth/v1/user) stammt und nicht umgangen
// werden kann. Diese Datei darf niemals als Auth-Ersatz gelesen werden.
// ---------------------------------------------------------------------------
//
// Warum ueberhaupt normalisiert wird (statt den Header-Wert durchzureichen):
//  1. Die RPC consume_edge_rate_limit hat einen 512-Zeichen-Guard auf dem
//     Subject. Ein langer Header-Wert laesst den Guard werfen -> aus einem
//     sauberen 429 wird ein 500.
//  2. Unbegrenzt viele verschiedene Subjects blaehen public.edge_rate_limits
//     auf (jeder Fantasiewert = eine Zeile).
//  3. Ohne Kanonisierung sind "1.2.3.4", "01.2.3.4" und "1.2.3.4:51234" drei
//     verschiedene Buckets fuer denselben Absender.

/** Obergrenze fuer den Rohwert. Laengste denkbare IPv6-Form inkl. Zone/Port
 *  bleibt deutlich darunter; alles Laengere ist ohnehin keine IP. */
const MAX_RAW_IP_CHARS = 64;

const IPV4_RE = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
const IPV6_GROUP_RE = /^[0-9a-f]{1,4}$/;

function normalizeIpv4(value: string): string | null {
  const match = IPV4_RE.exec(value);
  if (!match) return null;
  const octets: number[] = [];
  for (let i = 1; i <= 4; i++) {
    const part = match[i];
    // Fuehrende Nullen ablehnen: sonst waeren "01.2.3.4" und "1.2.3.4" zwei
    // getrennte Buckets fuer denselben Absender (und "010" ist je nach Parser
    // auch noch oktal).
    if (part.length > 1 && part.startsWith("0")) return null;
    const octet = Number(part);
    if (octet > 255) return null;
    octets.push(octet);
  }
  return octets.join(".");
}

/**
 * Validiert eine IPv6-Adresse und kuerzt sie auf ihr /64-Praefix.
 *
 * Warum /64 und nicht die volle Adresse: ein /128-Bucket ist trivial zu
 * umgehen, weil Provider Endkunden regulaer ein ganzes /64 zuteilen und die
 * unteren 64 Bit pro Verbindung rotieren duerfen. Ein Limit auf der vollen
 * Adresse waere damit gar kein Limit.
 *
 * Ausnahme: IPv4-in-IPv6 ("::ffff:1.2.3.4") kommt als volle IPv4 zurueck,
 * siehe Begruendung unten.
 */
function normalizeIpv6(value: string): string | null {
  let text = value.toLowerCase();

  // Zone-Id ("fe80::1%eth0") abschneiden - fuer das Bucket irrelevant.
  const zoneAt = text.indexOf("%");
  if (zoneAt >= 0) text = text.slice(0, zoneAt);
  if (text.length === 0) return null;

  // Mindestens zwei Doppelpunkte, sonst ist es keine IPv6-Notation.
  if (text.split(":").length < 3) return null;

  // "::" darf genau einmal vorkommen.
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

  // Eingebettete IPv4-Notation ("::ffff:203.0.113.7") in zwei Hex-Gruppen
  // umrechnen, damit die Gruppen-Validierung unten greift.
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
    // "::" muss mindestens eine Gruppe ersetzen.
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

  // IPv4-in-IPv6 ("::ffff:203.0.113.7", gleichwertig "::ffff:cb00:7107") ist
  // kein eigenes IPv6-Netz, sondern ein IPv4-Client auf einem Dual-Stack-
  // Socket. Die /64-Kuerzung unten schneidet genau die zwei Gruppen ab, in
  // denen die IPv4 steckt - ALLE so ankommenden Clients laegen damit in EINEM
  // Bucket ("0:0:0:0::/64") und ein einzelner Absender koennte jeden anderen
  // aussperren. Deshalb auf die volle IPv4 aufloesen: das ist zugleich genau
  // das Subject, das derselbe Client ueber einen reinen IPv4-Header bekaeme.
  //
  // Bewusst nur die gemappte Form (0:0:0:0:0:ffff:x:x). Die veraltete
  // IPv4-kompatible Form "::a.b.c.d" bleibt im IPv6-Pfad, sonst wuerden "::"
  // und "::1" als 0.0.0.0 bzw. 0.0.0.1 gebucht - beides keine Absender.
  if (words[5] === 0xffff && words.slice(0, 5).every((word) => word === 0)) {
    return [
      words[6] >> 8,
      words[6] & 0xff,
      words[7] >> 8,
      words[7] & 0xff,
    ].join(".");
  }

  // Auf /64 kuerzen und die ersten vier Gruppen kanonisch (ohne fuehrende
  // Nullen) schreiben, damit "2001:0db8:..." und "2001:db8:..." dasselbe
  // Bucket treffen.
  const prefix = groups
    .slice(0, 4)
    .map((group) => Number.parseInt(group, 16).toString(16))
    .join(":");
  return `${prefix}::/64`;
}

/**
 * Akzeptiert ausschliesslich echte IP-Literale und gibt sie kanonisch zurueck
 * (IPv4 als Punktnotation, IPv6 als `<praefix>::/64`, IPv4-in-IPv6 als die
 * eingebettete IPv4 in Punktnotation). Alles andere -> null.
 *
 * Erlaubte Schreibweisen: "1.2.3.4", "1.2.3.4:51234", "2001:db8::1",
 * "[2001:db8::1]:443", "::ffff:1.2.3.4", "fe80::1%eth0".
 */
export function normalizeIp(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  let value = raw.trim();
  if (value.length === 0 || value.length > MAX_RAW_IP_CHARS) return null;

  // Klammer-Form "[2001:db8::1]" mit optionalem ":port".
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
    // Genau ein Doppelpunkt -> IPv4 mit Port.
    const [host, port] = value.split(":");
    if (!/^\d{1,5}$/.test(port)) return null;
    value = host;
  }
  return normalizeIpv4(value);
}

/**
 * Liefert das Subject fuer das IP-Rate-Limit.
 *
 * Reihenfolge:
 *  1. `cf-connecting-ip` - von Cloudflare gesetzt, client-seitig nicht
 *     beeinflussbar (siehe Kopf).
 *  2. `x-forwarded-for` VON RECHTS nach links. Cloudflare haengt an, also ist
 *     der rechteste verwertbare Eintrag der vertrauenswuerdigste. Von links zu
 *     lesen greift genau den vom Client eingeschleusten Wert ab.
 *  3. Fallback auf die verifizierte User-Id.
 *
 * Zum Fallback (bewusste Entscheidung, nicht Faulheit):
 *  - Ein gemeinsames Literal wie "unknown" waere ein GETEILTES Bucket: ein
 *    einzelner Missbraucher koennte es leerlaufen lassen und damit global
 *    jeden legitimen Nutzer aussperren.
 *  - Gar kein Limit waere ein Freifahrtschein.
 *  - Die aus dem JWT verifizierte User-Id ist nie schwaecher als das direkt
 *    daneben stehende User-Gate: sie aufzublaehen kostet den Angreifer pro
 *    Bucket einen weiteren Account - genau die Sybil-Kosten, die er ohnehin
 *    schon traegt - und kann niemanden sonst aussperren.
 *
 * Die Praefixe `ip:` / `uid:` trennen die beiden Namensraeume. Ohne sie
 * koennte ein praeparierter Header (z. B. "uid:<opfer-uuid>") im Bucket eines
 * fremden Nutzers landen und diesen aussperren.
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

  // Hinter Cloudflare unerreichbar. Taucht das in function_logs auf, hat sich
  // das Plattform-Setup geaendert und die Annahmen im Kopf dieser Datei
  // muessen neu geprueft werden.
  console.warn("clientIpSubject: kein verwertbarer Client-IP-Header, Fallback auf uid");
  return `uid:${verifiedUserId}`;
}
