// Tests for the rate-limit subject derivation (client_ip.ts), free of external
// test dependencies. The core regression: reading x-forwarded-for from the
// right, since the old `.split(",")[0]` took the client-set entry.

import { clientIpSubject, normalizeIp } from "./client_ip.ts";

const USER_A = "11111111-1111-4111-8111-111111111111";
const USER_B = "22222222-2222-4222-8222-222222222222";

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) {
    throw new Error(`${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`);
  }
}

function reqWith(headers: Record<string, string>): Request {
  return new Request("https://example.invalid/", { method: "POST", headers });
}

function subject(headers: Record<string, string>, userId = USER_A): string {
  return clientIpSubject(reqWith(headers), userId);
}

Deno.test("cf-connecting-ip gewinnt gegen ein widersprechendes x-forwarded-for", () => {
  assertEquals(
    subject({
      "cf-connecting-ip": "203.0.113.7",
      "x-forwarded-for": "9.9.9.9, 8.8.8.8",
    }),
    "ip:203.0.113.7",
    "cf-connecting-ip muss Vorrang haben",
  );
});

Deno.test("REGRESSION: x-forwarded-for wird von RECHTS gelesen", () => {
  // Cloudflare appends, so the client-set value is left and the observed
  // address right; the old .split(",")[0] returned the attacker's value.
  const result = subject({ "x-forwarded-for": "9.9.9.9, 203.0.113.7" });
  assertEquals(result, "ip:203.0.113.7", "rechtester Eintrag muss gewinnen");
  assert(
    result !== "ip:9.9.9.9",
    "der linkeste (client-kontrollierte) Eintrag darf NIE das Subject bestimmen",
  );
});

Deno.test("laengere x-forwarded-for-Ketten: immer der rechteste gueltige Eintrag", () => {
  assertEquals(
    subject({ "x-forwarded-for": "1.1.1.1, 2.2.2.2, 3.3.3.3, 198.51.100.42" }),
    "ip:198.51.100.42",
    "4er-Kette",
  );
  assertEquals(
    subject({ "x-forwarded-for": "  10.0.0.1 ,  172.16.0.1 ,  203.0.113.9  " }),
    "ip:203.0.113.9",
    "Whitespace um die Eintraege",
  );
});

Deno.test("nicht normalisierbare Eintraege am rechten Rand werden uebersprungen", () => {
  assertEquals(
    subject({ "x-forwarded-for": "203.0.113.7, not-an-ip" }),
    "ip:203.0.113.7",
    "Muell rechts ueberspringen",
  );
  assertEquals(
    subject({ "x-forwarded-for": "203.0.113.7, unknown, , 999.1.1.1" }),
    "ip:203.0.113.7",
    "mehrere unbrauchbare Eintraege rechts ueberspringen",
  );
});

Deno.test("nicht-IP-Werte und Ueberlaenge werden abgelehnt", () => {
  assertEquals(normalizeIp("unknown"), null, "'unknown' ist keine IP");
  assertEquals(normalizeIp("localhost"), null, "Hostnamen sind keine IPs");
  assertEquals(normalizeIp(""), null, "leerer String");
  assertEquals(normalizeIp("   "), null, "nur Whitespace");
  assertEquals(normalizeIp(null), null, "null");
  assertEquals(normalizeIp(undefined), null, "undefined");
  assertEquals(normalizeIp(12345), null, "Nicht-String");
  // Without the cap these would blow the RPC's 512-char subject check (429
  // becomes 500) and inflate the table.
  assertEquals(normalizeIp("a".repeat(600)), null, "600 Zeichen Muell");
  assertEquals(normalizeIp("1.2.3.4" + "0".repeat(600)), null, "600 Zeichen Ziffern-Anhang");
  assertEquals(normalizeIp("2001:db8::" + "1".repeat(600)), null, "600 Zeichen Pseudo-IPv6");
  // The length check runs AFTER the trim: padding is normal in an
  // x-forwarded-for chain and must not form its own bucket.
  assertEquals(
    normalizeIp(" ".repeat(600) + "1.2.3.4" + " ".repeat(600)),
    "1.2.3.4",
    "reines Whitespace-Padding wird getrimmt, nicht abgelehnt",
  );
});

Deno.test("ungueltige IPv4-Formen werden abgelehnt", () => {
  assertEquals(normalizeIp("999.1.1.1"), null, "Oktett > 255");
  assertEquals(normalizeIp("1.2.3.256"), null, "Oktett > 255");
  // Leading zeros would give one sender two buckets.
  assertEquals(normalizeIp("01.2.3.4"), null, "fuehrende Null");
  assertEquals(normalizeIp("1.02.3.4"), null, "fuehrende Null im 2. Oktett");
  assertEquals(normalizeIp("1.2.3"), null, "zu wenige Oktette");
  assertEquals(normalizeIp("1.2.3.4.5"), null, "zu viele Oktette");
  assertEquals(normalizeIp("1.2.3.4a"), null, "Buchstabe angehaengt");
  assertEquals(normalizeIp("-1.2.3.4"), null, "negatives Oktett");
});

Deno.test("Port- und Whitespace-Formen normalisieren auf dieselbe IP", () => {
  assertEquals(normalizeIp("203.0.113.7"), "203.0.113.7", "blank");
  assertEquals(normalizeIp("203.0.113.7:51234"), "203.0.113.7", "mit Port");
  assertEquals(normalizeIp("  203.0.113.7  "), "203.0.113.7", "mit Whitespace");
  assertEquals(normalizeIp("\t203.0.113.7:443\n"), "203.0.113.7", "Whitespace + Port");
  assertEquals(normalizeIp("203.0.113.7:"), null, "leerer Port");
  assertEquals(normalizeIp("203.0.113.7:abc"), null, "nicht-numerischer Port");
  assertEquals(
    subject({ "cf-connecting-ip": "203.0.113.7:51234" }),
    subject({ "cf-connecting-ip": " 203.0.113.7 " }),
    "Port- und Whitespace-Form muessen dasselbe Subject ergeben",
  );
});

Deno.test("IPv6 wird auf das /64-Praefix gekuerzt", () => {
  assertEquals(
    normalizeIp("2001:db8:85a3:1:0:0:0:1"),
    "2001:db8:85a3:1::/64",
    "voll ausgeschrieben",
  );
  assertEquals(normalizeIp("2001:db8:85a3:1::1"), "2001:db8:85a3:1::/64", "mit ::");
  assertEquals(
    normalizeIp("2001:0db8:85a3:0001::1"),
    "2001:db8:85a3:1::/64",
    "fuehrende Nullen kanonisiert",
  );
  assertEquals(
    normalizeIp("[2001:db8:85a3:1::1]:443"),
    "2001:db8:85a3:1::/64",
    "Klammer-Form mit Port",
  );
  assertEquals(
    normalizeIp("2001:db8:85a3:1::1%eth0"),
    "2001:db8:85a3:1::/64",
    "Zone-Id abgeschnitten",
  );
  assertEquals(normalizeIp("2001:db8::1:2:3:4:5:6:7:8"), null, "zu viele Gruppen");
  assertEquals(normalizeIp("2001:db8::1::2"), null, "zwei :: sind ungueltig");
  assertEquals(normalizeIp("2001:xyz::1"), null, "keine Hex-Gruppe");
});

Deno.test("zwei Adressen im selben /64 fallen in dasselbe Bucket", () => {
  // Providers hand out a whole /64 per customer, so a /128 bucket is trivially
  // bypassed by rotating the lower 64 bits.
  const a = subject({ "cf-connecting-ip": "2001:db8:85a3:1::1" });
  const b = subject({ "cf-connecting-ip": "2001:db8:85a3:1:ffff:ffff:ffff:ffff" });
  assertEquals(a, b, "gleiches /64 muss dasselbe Subject ergeben");
  assertEquals(a, "ip:2001:db8:85a3:1::/64", "erwartetes /64-Subject");
});

Deno.test("REGRESSION: IPv4-in-IPv6 bekommt ein Bucket PRO Adresse", () => {
  // The old version put the embedded IPv4 into the groups the /64 truncation
  // cuts off, collapsing every dual-stack client into one bucket.
  assertEquals(normalizeIp("::ffff:203.0.113.7"), "203.0.113.7", "gemappte IPv4");
  assertEquals(normalizeIp("::ffff:198.51.100.42"), "198.51.100.42", "andere gemappte IPv4");

  const a = subject({ "cf-connecting-ip": "::ffff:203.0.113.7" });
  const b = subject({ "cf-connecting-ip": "::ffff:198.51.100.42" });
  assert(a !== b, "zwei gemappte IPv4 duerfen nicht ins selbe Bucket kollabieren");
  assert(
    a !== "ip:0:0:0:0::/64" && b !== "ip:0:0:0:0::/64",
    "das gemeinsame Sammel-Bucket der alten Fassung darf nicht mehr entstehen",
  );

  // The same address via a plain IPv4 header must give the same subject, or a
  // client would own two buckets.
  assertEquals(
    a,
    subject({ "cf-connecting-ip": "203.0.113.7" }),
    "gemappte und blanke Form muessen dasselbe Subject ergeben",
  );
});

Deno.test("IPv4-in-IPv6: alle Schreibweisen treffen dasselbe Bucket", () => {
  // Hex spelling of the same address (203.0.113.7 = cb00:7107).
  assertEquals(normalizeIp("::ffff:cb00:7107"), "203.0.113.7", "gemappt in Hex-Notation");
  assertEquals(
    normalizeIp("0:0:0:0:0:ffff:203.0.113.7"),
    "203.0.113.7",
    "voll ausgeschrieben",
  );
  assertEquals(normalizeIp("::FFFF:203.0.113.7"), "203.0.113.7", "Grossschreibung");
  assertEquals(normalizeIp("[::ffff:203.0.113.7]:443"), "203.0.113.7", "Klammer-Form mit Port");
  // An invalid embedded IPv4 stays invalid — no loophole for junk values.
  assertEquals(normalizeIp("::ffff:999.1.1.1"), null, "Oktett > 255");
  assertEquals(normalizeIp("::ffff:01.2.3.4"), null, "fuehrende Null");
  assertEquals(normalizeIp("::ffff:1.2.3"), null, "zu wenige Oktette");
});

Deno.test("echte IPv6 bleibt bei der /64-Kuerzung", () => {
  // The special case applies ONLY to the mapped prefix 0:0:0:0:0:ffff;
  // everything else stays on the IPv6 path.
  assertEquals(normalizeIp("2001:db8:85a3:1::ffff:cb00:7107"), "2001:db8:85a3:1::/64", "echte IPv6");
  assertEquals(normalizeIp("::ffff:0:203.0.113.7"), "0:0:0:0::/64", "IPv4-translated bleibt IPv6");
  assertEquals(normalizeIp("::1"), "0:0:0:0::/64", "Loopback wird nicht zu 0.0.0.1");
});

Deno.test("verschiedene /64-Praefixe bleiben verschiedene Buckets", () => {
  const a = subject({ "cf-connecting-ip": "2001:db8:85a3:1::1" });
  const b = subject({ "cf-connecting-ip": "2001:db8:85a3:2::1" });
  assert(a !== b, "verschiedene /64 duerfen nicht kollabieren");
});

Deno.test("ohne verwertbare Header: Fallback auf die verifizierte User-Id", () => {
  assertEquals(subject({}, USER_A), `uid:${USER_A}`, "kein Header -> uid-Fallback");
  assertEquals(
    subject({ "x-forwarded-for": "unknown" }, USER_A),
    `uid:${USER_A}`,
    "nur Muell im Header -> uid-Fallback",
  );
});

Deno.test("Anti-Lockout: zwei User ohne Header bekommen VERSCHIEDENE Buckets", () => {
  // Why the fallback is the user id and not a shared literal like "unknown":
  // one abuser could drain a shared bucket and lock out everyone.
  const a = subject({}, USER_A);
  const b = subject({}, USER_B);
  assert(a !== b, "beide User landen im selben Bucket - globaler Lockout moeglich");
  assertEquals(a, `uid:${USER_A}`, "User A");
  assertEquals(b, `uid:${USER_B}`, "User B");
});

Deno.test("praeparierte uid:-Header koennen kein fremdes Bucket treffen", () => {
  const victim = USER_B;
  // The namespace prefix is the protection: a "uid:..." header is not an IP,
  // gets rejected and can never reach the victim's bucket.
  assertEquals(normalizeIp(`uid:${victim}`), null, "uid:<uuid> ist keine IP");
  const crafted: Record<string, string>[] = [
    { "cf-connecting-ip": `uid:${victim}` },
    { "x-forwarded-for": `uid:${victim}` },
    { "x-forwarded-for": `uid:${victim}, uid:${victim}` },
    { "cf-connecting-ip": victim },
    { "x-forwarded-for": victim },
  ];
  for (const headers of crafted) {
    const result = subject(headers, USER_A);
    assert(
      result !== `uid:${victim}`,
      `praeparierter Header ${JSON.stringify(headers)} landete im Opfer-Bucket`,
    );
    assertEquals(
      result,
      `uid:${USER_A}`,
      `praeparierter Header ${JSON.stringify(headers)} muss auf den eigenen uid-Fallback zeigen`,
    );
  }
});

Deno.test("ip:- und uid:-Namensraeume ueberschneiden sich nie", () => {
  const ipSubject = subject({ "cf-connecting-ip": "203.0.113.7" });
  const uidSubject = subject({}, USER_A);
  assert(ipSubject.startsWith("ip:"), "IP-Subject muss ip:-praefixiert sein");
  assert(uidSubject.startsWith("uid:"), "Fallback muss uid:-praefixiert sein");
  assert(ipSubject !== uidSubject, "Namensraeume duerfen nicht kollidieren");
});

Deno.test("Subjects bleiben deutlich unter dem 512-Zeichen-Guard der RPC", () => {
  const longest = [
    subject({ "cf-connecting-ip": "2001:0db8:85a3:0001:0000:8a2e:0370:7334" }),
    subject({ "x-forwarded-for": "1.1.1.1, ".repeat(40) + "203.0.113.7" }),
    subject({}, USER_A),
  ];
  for (const value of longest) {
    assert(value.length <= 512, `Subject zu lang (${value.length}): ${value}`);
  }
});
