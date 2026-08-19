// Tests fuer die Ermittlung des Rate-Limit-Subjects (client_ip.ts).
//
// Der eigentliche Regressionstest steht unter "x-forwarded-for wird von
// RECHTS gelesen": die alte Implementierung nahm `.split(",")[0]` und griff
// damit hinter Cloudflare exakt den vom Client selbst gesetzten Eintrag ab -
// das IP-Limit war frei umgehbar.
//
// Bewusst ohne externe Test-Dependencies (gleicher Stil wie prefilter_test.ts).

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
  // Cloudflare HAENGT an -> der vom Client gesetzte Wert steht links, die
  // real beobachtete Adresse rechts. Die alte Implementierung (.split(",")[0])
  // haette hier "ip:9.9.9.9" geliefert, also den Angreifer-Wert.
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
  // 600 Zeichen: wuerde ohne Guard den 512-Zeichen-Subject-Check der RPC
  // sprengen (aus einem 429 wuerde ein 500) und die Tabelle aufblaehen.
  assertEquals(normalizeIp("a".repeat(600)), null, "600 Zeichen Muell");
  assertEquals(normalizeIp("1.2.3.4" + "0".repeat(600)), null, "600 Zeichen Ziffern-Anhang");
  assertEquals(normalizeIp("2001:db8::" + "1".repeat(600)), null, "600 Zeichen Pseudo-IPv6");
  // Die Laengenpruefung greift NACH dem Trim - Whitespace-Padding ist in einer
  // x-forwarded-for-Kette normal ("a, b") und darf kein eigenes Bucket bilden.
  assertEquals(
    normalizeIp(" ".repeat(600) + "1.2.3.4" + " ".repeat(600)),
    "1.2.3.4",
    "reines Whitespace-Padding wird getrimmt, nicht abgelehnt",
  );
});

Deno.test("ungueltige IPv4-Formen werden abgelehnt", () => {
  assertEquals(normalizeIp("999.1.1.1"), null, "Oktett > 255");
  assertEquals(normalizeIp("1.2.3.256"), null, "Oktett > 255");
  // Fuehrende Nullen: sonst waeren "01.2.3.4" und "1.2.3.4" zwei Buckets
  // fuer denselben Absender.
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
  // Alle Schreibweisen muessen dasselbe Bucket treffen.
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
  // Provider geben Endkunden regulaer ein ganzes /64; ein /128-Bucket waere
  // durch Rotation der unteren 64 Bit trivial zu umgehen.
  const a = subject({ "cf-connecting-ip": "2001:db8:85a3:1::1" });
  const b = subject({ "cf-connecting-ip": "2001:db8:85a3:1:ffff:ffff:ffff:ffff" });
  assertEquals(a, b, "gleiches /64 muss dasselbe Subject ergeben");
  assertEquals(a, "ip:2001:db8:85a3:1::/64", "erwartetes /64-Subject");
});

Deno.test("REGRESSION: IPv4-in-IPv6 bekommt ein Bucket PRO Adresse", () => {
  // Die alte Fassung rechnete die eingebettete IPv4 in die letzten beiden
  // Hex-Gruppen um - genau die, die die /64-Kuerzung abschneidet. Jede
  // "::ffff:..."-Adresse landete damit in "ip:0:0:0:0::/64", also alle
  // Dual-Stack-Clients in EINEM Bucket: ein einzelner Absender konnte alle
  // anderen aussperren.
  assertEquals(normalizeIp("::ffff:203.0.113.7"), "203.0.113.7", "gemappte IPv4");
  assertEquals(normalizeIp("::ffff:198.51.100.42"), "198.51.100.42", "andere gemappte IPv4");

  const a = subject({ "cf-connecting-ip": "::ffff:203.0.113.7" });
  const b = subject({ "cf-connecting-ip": "::ffff:198.51.100.42" });
  assert(a !== b, "zwei gemappte IPv4 duerfen nicht ins selbe Bucket kollabieren");
  assert(
    a !== "ip:0:0:0:0::/64" && b !== "ip:0:0:0:0::/64",
    "das gemeinsame Sammel-Bucket der alten Fassung darf nicht mehr entstehen",
  );

  // Dieselbe Adresse ueber einen reinen IPv4-Header muss dasselbe Subject
  // ergeben - sonst haette ein Client zwei Buckets.
  assertEquals(
    a,
    subject({ "cf-connecting-ip": "203.0.113.7" }),
    "gemappte und blanke Form muessen dasselbe Subject ergeben",
  );
});

Deno.test("IPv4-in-IPv6: alle Schreibweisen treffen dasselbe Bucket", () => {
  // Hex-Schreibweise derselben Adresse (203.0.113.7 = cb00:7107).
  assertEquals(normalizeIp("::ffff:cb00:7107"), "203.0.113.7", "gemappt in Hex-Notation");
  assertEquals(
    normalizeIp("0:0:0:0:0:ffff:203.0.113.7"),
    "203.0.113.7",
    "voll ausgeschrieben",
  );
  assertEquals(normalizeIp("::FFFF:203.0.113.7"), "203.0.113.7", "Grossschreibung");
  assertEquals(normalizeIp("[::ffff:203.0.113.7]:443"), "203.0.113.7", "Klammer-Form mit Port");
  // Ungueltige eingebettete IPv4 bleibt ungueltig - kein Schlupfloch fuer
  // Fantasiewerte, die die Tabelle aufblaehen.
  assertEquals(normalizeIp("::ffff:999.1.1.1"), null, "Oktett > 255");
  assertEquals(normalizeIp("::ffff:01.2.3.4"), null, "fuehrende Null");
  assertEquals(normalizeIp("::ffff:1.2.3"), null, "zu wenige Oktette");
});

Deno.test("echte IPv6 bleibt bei der /64-Kuerzung", () => {
  // Die Sonderbehandlung greift NUR fuer das gemappte Praefix
  // 0:0:0:0:0:ffff. Alles andere - insbesondere ff-Gruppen an anderer Stelle
  // und die Kurzformen "::"/"::1" - laeuft weiter ueber den IPv6-Pfad.
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
  // Genau deswegen ist der Fallback die User-Id und kein geteiltes Literal
  // wie "unknown": ein einzelner Missbraucher koennte ein geteiltes Bucket
  // leerlaufen lassen und damit global jeden legitimen Nutzer aussperren.
  const a = subject({}, USER_A);
  const b = subject({}, USER_B);
  assert(a !== b, "beide User landen im selben Bucket - globaler Lockout moeglich");
  assertEquals(a, `uid:${USER_A}`, "User A");
  assertEquals(b, `uid:${USER_B}`, "User B");
});

Deno.test("praeparierte uid:-Header koennen kein fremdes Bucket treffen", () => {
  const victim = USER_B;
  // Der Namensraum-Praefix ist der Schutz: ein "uid:..."-Header ist keine IP,
  // wird abgelehnt und kann daher nie im Bucket des Opfers landen.
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
