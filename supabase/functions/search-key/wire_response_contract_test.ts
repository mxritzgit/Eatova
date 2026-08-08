// Wire-Test fuer den Antwort-Umschlag von `search-key`
// (docs/REVIEW-2026-08-08.md, G2, Schalter 3).
//
// DER SCHALTER
//
// `index.ts` liefert dem Client `{ mirrorBaseUrl, searchKey, ttlSeconds }`.
// Benennt jemand ein Feld um (z. B. `mirrorBaseUrl` -> `mirror_base_url`),
// laeuft der Client in `lib/src/services/search_credentials.dart` auf
//
//     final baseUrl = decoded['mirrorBaseUrl'];
//     final searchKey = decoded['searchKey'];
//     if (baseUrl is! String || searchKey is! String) return null;
//
// und liefert `null`. Und `null` heisst per dokumentiertem Vertrag des
// Fetchers ausdruecklich NICHT "abschalten", sondern "behalte, was du hast".
// Die Key-Rotation ist damit DAUERHAFT und STILL tot: der 403-Pfad wirft den
// abgelehnten Key weg, bekommt keinen Ersatz, faellt auf den
// Compile-Time-Default zurueck — und `FallbackProductService` liefert
// weiterhin plausible OpenFoodFacts-Treffer. Nichts wird rot, nichts wird
// sichtbar.
//
// WARUM DIESER TEST DIE FALLE NICHT WIEDERHOLT
//
// `test/services/search_credentials_test.dart` steckt seinen eigenen
// `SearchKeyFetcher` ein und baut `FetchedSearchCredentials` direkt als
// Dart-Objekt. Die JSON-Grenze — also genau die Stelle, an der der Feldname
// steht — wird dort nie betreten. Sein Fake-Umschlag benutzt sogar
// snake_case (`'ttl_seconds'`), weil er das PERSISTENZ-Format nachbaut und
// nicht das Antwort-Format; die beiden sind verschieden und niemand haelt sie
// auseinander.
//
// Dieser Test dagegen:
//   * laedt `index.ts` UNVERAENDERT (Deno.serve wird abgefangen, der echte
//     Handler wird herausgezogen — kein Nachbau der Response-Logik),
//   * schickt einen echten `Request` hinein und liest den echten Response-
//     Body als Text,
//   * gibt diesen Text durch eine ZEICHENGETREUE Nachbildung des
//     Dart-Client-Parsers und behauptet, dass dabei KEIN `null` herauskommt.
//
// Die drei Feldnamen stehen unten in KLIENT_FELDER an genau einer Stelle und
// werden — wo Lese-Rechte vorhanden sind — zusaetzlich gegen den echten
// Dart-Quelltext gehalten, damit sie nicht aus demselben Denkmodell stammen
// wie die Function.
//
// Laeuft mit `deno test --allow-env` (wie die CI). Kein Netz, kein Socket:
// `Deno.serve` wird nie ausgefuehrt.

const BASE_URL = "https://supabase.test.invalid";
const USER_ID = "11111111-1111-4111-8111-111111111111";
const USER_TOKEN = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.test.token";
const MIRROR_URL = "https://eatova.test.invalid/meili";
const MIRROR_KEY = "test-search-only-key-0123456789";
const TTL = "43200";

/** Die Felder, die der Dart-Client aus dem Body liest. Quelle:
 *  lib/src/services/search_credentials.dart, `_fetch()`. */
const KLIENT_FELDER = {
  baseUrl: "mirrorBaseUrl",
  searchKey: "searchKey",
  ttl: "ttlSeconds",
} as const;

Deno.env.set("SUPABASE_URL", BASE_URL);
Deno.env.set("SUPABASE_ANON_KEY", "test-anon-key");
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "test-service-key");
Deno.env.set("EATOVA_MIRROR_SEARCH_KEY", MIRROR_KEY);
Deno.env.set("EATOVA_MIRROR_BASE_URL", MIRROR_URL);
Deno.env.set("EATOVA_SEARCH_KEY_TTL_SECONDS", TTL);

type Handler = (request: Request) => Response | Promise<Response>;

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) {
    throw new Error(
      `${message}: erwartet ${JSON.stringify(expected)}, war ${JSON.stringify(actual)}`,
    );
  }
}

/** Antwortet auf die drei Supabase-Aufrufe, die `search-key` intern macht. */
function installFetch(): () => void {
  const original = globalThis.fetch;
  globalThis.fetch = ((input: string | URL | Request): Promise<Response> => {
    const url = typeof input === "string"
      ? input
      : input instanceof URL
      ? input.href
      : input.url;

    if (url.includes("/auth/v1/user")) {
      return Promise.resolve(
        new Response(JSON.stringify({ id: USER_ID }), {
          status: 200,
          headers: { "content-type": "application/json" },
        }),
      );
    }
    if (url.includes("/rest/v1/rpc/consume_edge_rate_limit")) {
      return Promise.resolve(
        new Response(
          JSON.stringify({
            allowed: true,
            limit: 120,
            remaining: 119,
            resetAt: new Date(Date.now() + 600_000).toISOString(),
            windowSeconds: 600,
          }),
          { status: 200, headers: { "content-type": "application/json" } },
        ),
      );
    }
    if (url.includes("/rest/v1/rpc/prune_edge_rate_limits")) {
      return Promise.resolve(new Response(null, { status: 204 }));
    }
    return Promise.reject(new Error(`Unerwarteter fetch auf ${url}`));
  }) as typeof globalThis.fetch;

  return () => {
    globalThis.fetch = original;
  };
}

/** Faengt den an `Deno.serve` uebergebenen Handler ab, statt einen Port zu
 *  binden — so laeuft der Test ohne `--allow-net`, aber gegen den ECHTEN
 *  Handler aus index.ts. */
let handler: Handler | null = null;

async function ladeHandler(): Promise<Handler> {
  if (handler) return handler;

  // `Deno.serve` ist ein Getter ohne Setter, aber configurable — deshalb
  // defineProperty statt Zuweisung. Der Deskriptor wird danach exakt so
  // zurueckgelegt, wie er war.
  const original = Object.getOwnPropertyDescriptor(Deno, "serve");
  assert(original !== undefined, "Deno.serve existiert nicht");

  Object.defineProperty(Deno, "serve", {
    configurable: true,
    value: (...args: unknown[]) => {
      const kandidat = args.find((a) => typeof a === "function");
      assert(
        typeof kandidat === "function",
        "Deno.serve wurde ohne Handler-Funktion aufgerufen",
      );
      handler = kandidat as Handler;
      // Ein Objekt in der Form eines HttpServer, damit nichts stolpert.
      return {
        finished: Promise.resolve(),
        shutdown: () => Promise.resolve(),
        ref: () => {},
        unref: () => {},
        addr: { transport: "tcp", hostname: "127.0.0.1", port: 0 },
      };
    },
  });

  try {
    await import("./index.ts");
  } finally {
    Object.defineProperty(Deno, "serve", original!);
  }

  assert(handler !== null, "index.ts hat Deno.serve nie aufgerufen");
  return handler!;
}

function anfrage(): Request {
  return new Request(`${BASE_URL}/functions/v1/search-key`, {
    method: "GET",
    headers: {
      authorization: `Bearer ${USER_TOKEN}`,
      apikey: "test-anon-key",
      "cf-connecting-ip": "203.0.113.7",
    },
  });
}

/**
 * Zeichengetreue Nachbildung von `EdgeFunctionSearchKeyFetcher._fetch()`
 * (search_credentials.dart). Liefert `null` in exakt denselben Faellen wie
 * der Client — und `null` heisst dort "behalte, was du hast", also: keine
 * Rotation, fuer immer.
 */
function clientParse(
  status: number,
  body: string,
): { baseUrl: string; searchKey: string; ttlSeconds: number } | null {
  if (status < 200 || status >= 300) return null;
  let decoded: unknown;
  try {
    decoded = JSON.parse(body);
  } catch {
    return null;
  }
  if (typeof decoded !== "object" || decoded === null) return null;
  const map = decoded as Record<string, unknown>;
  const baseUrl = map[KLIENT_FELDER.baseUrl];
  const searchKey = map[KLIENT_FELDER.searchKey];
  if (typeof baseUrl !== "string" || typeof searchKey !== "string") return null;
  const ttlRaw = map[KLIENT_FELDER.ttl];
  return {
    baseUrl: baseUrl.trim(),
    searchKey: searchKey.trim(),
    // Der Client faellt bei fehlender/falsch getypter TTL auf 12 h zurueck.
    ttlSeconds: typeof ttlRaw === "number" ? Math.round(ttlRaw) : 43200,
  };
}

Deno.test("search-key: der Client kann die echte Antwort ueberhaupt lesen", async () => {
  const wiederherstellen = installFetch();
  try {
    const serve = await ladeHandler();
    const antwort = await serve(anfrage());
    const koerper = await antwort.text();

    assertEquals(antwort.status, 200, "Status");

    const gelesen = clientParse(antwort.status, koerper);
    assert(
      gelesen !== null,
      "Der Dart-Client haette hier `null` bekommen — und `null` heisst " +
        "'behalte, was du hast'. Die Key-Rotation waere damit still und " +
        "dauerhaft tot. Body war: " + koerper,
    );
    assertEquals(gelesen!.baseUrl, MIRROR_URL, "mirrorBaseUrl");
    assertEquals(gelesen!.searchKey, MIRROR_KEY, "searchKey");
    assertEquals(gelesen!.ttlSeconds, Number(TTL), "ttlSeconds");
  } finally {
    wiederherstellen();
  }
});

Deno.test("search-key: kein Feld traegt eine zweite Schreibweise", async () => {
  const wiederherstellen = installFetch();
  try {
    const serve = await ladeHandler();
    const antwort = await serve(anfrage());
    const map = JSON.parse(await antwort.text()) as Record<string, unknown>;
    const schluessel = Object.keys(map);

    for (const feld of Object.values(KLIENT_FELDER)) {
      assert(
        schluessel.includes(feld),
        `Der Body traegt "${feld}" nicht. Vorhanden: ${schluessel.join(", ")}. ` +
          "Ein umbenanntes Feld macht die Rotation still und dauerhaft tot.",
      );
    }
    // Umbenennungen in snake_case sind die naheliegende Variante (die
    // uebrigen Supabase-Nutzlasten in diesem Projekt sind snake_case).
    for (const verboten of ["mirror_base_url", "search_key", "ttl_seconds"]) {
      assert(
        !schluessel.includes(verboten),
        `Der Body traegt "${verboten}". Der Client liest camelCase — eine ` +
          "zweite Schreibweise bedeutet, dass eine der beiden Seiten falsch ist.",
      );
    }
  } finally {
    wiederherstellen();
  }
});

Deno.test("search-key: ttlSeconds und cache-control laufen nicht auseinander", async () => {
  const wiederherstellen = installFetch();
  try {
    const serve = await ladeHandler();
    const antwort = await serve(anfrage());
    const map = JSON.parse(await antwort.text()) as Record<string, unknown>;

    const cacheControl = antwort.headers.get("cache-control") ?? "";
    assertEquals(
      cacheControl,
      `private, max-age=${map[KLIENT_FELDER.ttl]}`,
      "cache-control muss der ausgelieferten TTL folgen",
    );
    assert(
      !cacheControl.includes("public"),
      "Der Body traegt einen Credential — er darf nie in einen geteilten Cache",
    );
  } finally {
    wiederherstellen();
  }
});

Deno.test("search-key: der Key steht nie im Log", async () => {
  const wiederherstellen = installFetch();
  const gesammelt: string[] = [];
  const echtesLog = console.log;
  console.log = (...args: unknown[]) => {
    gesammelt.push(args.map((a) => JSON.stringify(a)).join(" "));
  };
  try {
    const serve = await ladeHandler();
    await serve(anfrage());
    const zeilen = gesammelt.join("\n");
    assert(
      !zeilen.includes(MIRROR_KEY),
      `Der Search-Key ist im Log gelandet: ${zeilen}`,
    );
  } finally {
    console.log = echtesLog;
    wiederherstellen();
  }
});

Deno.test(
  "search-key: die Feldnamen stimmen mit dem Dart-Client ueberein",
  async () => {
    // Die eigentliche Absicherung gegen "Fake aus demselben Denkmodell":
    // KLIENT_FELDER wird gegen den echten Client-Quelltext gehalten, nicht
    // gegen die Function. Ohne Lese-Recht (die CI faehrt `deno test
    // --allow-env`) bleibt die Behauptung oben stehen — sie faengt die
    // Umbenennung auch allein.
    const pfad = "../../../lib/src/services/search_credentials.dart";
    const url = new URL(pfad, import.meta.url);
    const erlaubt = await Deno.permissions.query({ name: "read", path: url });
    if (erlaubt.state !== "granted") {
      console.log(
        "uebersprungen: kein --allow-read (Quervergleich mit " +
          "search_credentials.dart entfaellt)",
      );
      return;
    }

    const quelle = await Deno.readTextFile(url);
    for (const feld of Object.values(KLIENT_FELDER)) {
      assert(
        quelle.includes(`decoded['${feld}']`),
        `search_credentials.dart liest "${feld}" nicht mehr — Function und ` +
          "Client sind auseinandergelaufen.",
      );
    }
  },
);
