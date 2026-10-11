# Shopping list prices (Open Prices)

Contract of the price estimate on the shopping receipt, added 2026-10-11.
It covers what the receipt shows, where the prices come from, which rules
turn community prices into an estimate, and how to maintain the dictionary.
Code: [models](../lib/src/models/shopping_price.dart),
[dictionary](../lib/src/models/shopping_price_dictionary.dart),
[amount parser](../lib/src/models/shopping_price_amount.dart),
[client](../lib/src/services/open_prices_api.dart),
[aggregation](../lib/src/services/shopping_price_aggregation.dart),
[service](../lib/src/services/shopping_price_service.dart),
[view state](../lib/src/services/shopping_price_controller.dart),
[receipt](../lib/src/screens/recipes/meal_plan_shopping.dart).

## What the receipt shows

With prices active, every checkable row gets one price line under its name:

| Outcome | Left | Right | Screen reader |
| --- | --- | --- | --- |
| Loading | – | `–,–– €` (ink3) | "Preis wird geladen" |
| Share of the amount | `4,76 €/kg` (or `/l`, `/Stk.`) | `≈ 1,19 €` | "etwa 1,19 €" |
| No amount printed, pack known | `4,61 €/kg · 1 Pck.` | `≈ 2,31 €` | "etwa 2,31 € für 1 Packung" |
| No amount, priced per piece | `0,89 €/Stk. · 1 Stk.` | `≈ 0,89 €` | "etwa 0,89 € für 1 Stück" |
| No match, too few prices, unconvertible amount, failure | – | `k. A.` (en: `n/a`) | "kein aktueller Preis" |
| Salt, pepper, water, a pinch | – | `–` | "nicht geschätzt" |

The right column only ever holds a plain sum, so its decimals line up like a
till's; what a line without an amount was priced for goes to the left. The
unit price carries no "Ø": in DM Mono it reads like the slashed zero. The line
is always one line while prices are shown, so rows keep their height when
prices arrive. Where the left side does not fit beside the value (large text
on a narrow phone) it shortens to `1 Pck.`, then steps back; a value wider
than the row shrinks in the line's own height instead of clipping. When a
long name pushes the amount below it, the amount moves to the right edge,
above its price. A checked row strikes its price through.

Under the counts a dashed rule separates the money: **SUMME**, or
**TEILSUMME** while any row has no price, with the sum of the shown values in
17 pt (`–,–– €` while loading, `k. A.` when nothing is priced, `–` when every
line is seasoning). It covers every line, bought or not. The done stamp sits
on the counts, never on the sum. A note under it reads "Preise werden geladen
…", "Preise gerade nicht abrufbar", "N Positionen ohne Preis", "Alle
Positionen geschätzt" or "Keine Position zu schätzen". The sum line and the
note are laid out for the longest text they can show, so nothing below them
moves between loading, loaded and failed, at any width and text size. The
fine print above the footer names the basis ("Mittlere Preise der letzten 6
Wochen in DE, anteilig. Ohne Gewähr.") and links the source: "Quelle: Open
Prices · ODbL", with the name and the licence each kept on one line, opening
`https://prices.openfoodfacts.org`.

Without a price service (tests, preview) or outside Germany the receipt looks
and behaves exactly as before and nothing is requested. Check ids, sync,
schema and the outbox are unchanged; `ShoppingItem.productCode` is display and
pricing only, never part of an id.

## Source and licence

[Open Prices](https://prices.openfoodfacts.org) is the Open Food Facts
community price database (base URL `https://prices.openfoodfacts.org/api/v1`,
OpenAPI at `/api/schema`). Reads need no account. The data is under the
**ODbL**; the receipt names the source and licence. Only aggregates are shown,
nothing is stored or served. A server-side snapshot would be a derived
database and would have to be offered under ODbL.

The server has no SLA and no published rate limit. It silently drops unknown
query parameters, has no country filter, caps `size` at 100 and pages
unstably with `order_by=-date`. Every filter is therefore checked again on
each row, and `test/services/open_prices_wire_test.dart` pins every parameter
name against the spec.

## Region

Prices are shown when **any** device locale (`PlatformDispatcher.locales`)
has the country code `DE`. When no device locale carries a country, Germany
applies when the app language is German. Anything else (for example `en_US`
or `de_AT` alone) shows no price UI and sends no request. No location
permission is involved. Prices are never borrowed from another market or
converted between currencies: France makes up about two thirds of the rows
in the geo circle and is a different market.

## Window

A hard **42 days** (6 weeks): a row counts when its purchase `date` lies
between `today − 42` and `today` (local calendar days; on 2026-10-11 that is
2026-08-30 to 2026-10-11). There is no fallback to older prices. The footnote
derives its week count from the same constant (`kPriceWindowDays`).

## Requests and budgets

One run per change of the shown lines, on the device:

1. **Local:** every line is read against the dictionary and its amount
   parsed. Seasoning, unknown foods, false friends and amounts that cannot be
   converted are settled without a request, as are cache hits.
2. **In parallel:** the exact barcodes of weighed Open Food Facts ingredients
   (`type=PRODUCT&product_code__in=…`, at most 40 per request, one page) and,
   when a missing entry uses loose-goods prices, the category snapshot
   (`type=CATEGORY`, at most 2 pages).
3. **Product records** (`/products/code/{code}`) for barcodes without a price
   of their own and without a name match: at most 6 per run, heaviest first;
   their `categories_tags` choose an entry, walking from the most specific tag.
4. **One overlap request** for every missing entry
   (`type=PRODUCT&product__categories_tags__overlap=…`, at most 30 tags per
   chunk), pages one after another, at most 8 pages per run. A truncated
   answer is still aggregated for the run, but never cached.

Every request carries `currency=EUR&lat=51.1657&lon=10.4515&radius_km=470`
`&date__gte=<window start>&duplicate_of__isnull=true&order_by=-id&size=100`.
A typical list costs 3 to 5 requests, a repeated one none.

Budgets: 2 requests in flight, 16 per run, 48 per rolling 10 minutes per
session, 30 s per run, and per request the `HttpTimeoutPolicy.openPrices`
(5 s connect, 8 s response, 10 s body, 15 s total) with a 2 MB page limit.
One retry after 2 s on 5xx, 429, timeout or connection errors; none on other
4xx or a changed answer shape; once the run budget is spent nothing more is
sent. An entry is aggregated only when every request it depends on
succeeded; otherwise its lines show `k. A.` and are asked again on the next
visit, at most once a minute. Leaving the shopping tab, changing the week or
closing the planner cancels the run and closes its socket. A run the service
refuses (a planner outliving its session) shows its lines as unavailable
instead of loading forever.

Requests send the User-Agent `Eatova/1.0 (Open Prices shopping estimate;
mxritzgit/eatova)`, no credentials and no cookies.

## Filters on every row

A row counts only when its shop location is `OSM` in `DE`, the currency is
`EUR`, the date lies in the window, `duplicate_of` is empty and the effective
price is above 0.05 and at most 500 EUR. A product row must carry one of the
entry's product tags, all of its required tags and none of its excluded
ones; a category row must carry one of its category tags. A discounted row
counts with `price_without_discount` when that is higher, otherwise it is
dropped.

## Normalisation and aggregation

- **Per kilogram:** product price / pack grams × 1000 (a pack in ml through
  the entry's density); loose goods only with `price_per=KILOGRAM`.
- **Per litre:** product price / pack ml × 1000 (a pack in g through the
  density).
- **Per piece:** loose goods with `price_per=UNIT`, or a product whose piece
  count can be read from its printed size ("10 Stück", "10er", "6 x 50 g",
  "M 10", "10"). Bases are never mixed.
- Duplicates (same product or tag, shop, date and price) count once. Each
  **(product or tag, shop)** is one independent price, at the median of its
  own reports, so a shop reporting the same product again does not weigh
  twice. Take the median of these, keep values within a third and three
  times of it, take the median again. At least **3** such prices are
  required; an exact barcode needs **1**. `samples` counts them.

## Cost of a line

The **share of the printed amount**: grams, millilitres, spoons (the entry's
spoon weight, else 15 or 5 ml), counts through the entry's piece, clove,
slice, can, pack, tub, jar or bunch weight ("2 Knoblauchzehen" are two
cloves), ranges at their upper bound and "2 x 150 g" as 300 g. A weighed item
uses its grams. Without an amount: one pack where the entry knows its size,
one piece on a piece basis, otherwise `k. A.`. Money is in whole cents, at
least one cent per priced line; the sum is the sum of the shown values.

## Dictionary

[`shopping_price_dictionary.dart`](../lib/src/models/shopping_price_dictionary.dart)
holds about 30 entries (salami, mozzarella, pizza dough, passata, tomatoes,
onions, garlic, milk, eggs, butter, flour, rice, spaghetti, chicken breast,
mince, bell pepper, cucumber, bananas, apples, oats, yogurt, gouda, olive
oil, potatoes, salmon, bread, hazelnut spread, bread rolls, zucchini), German
and English keys, blocked false friends and the matching rules:

1. Fold decomposed and composed umlauts and ß, lower case, drop parentheses,
   cut at the first `,`, `;`, `/`, "oder", "or", "bzw." or "z. B.", and
   before a trailing phrase ("mit", "ohne", "in", "im", "with", "without"):
   "Hähnchenbrust mit Paprika" is chicken breast.
2. Seasoning phrases ("nach Geschmack", "to taste"), a pinch, and a spice
   entry with a spoon or pinch ("1 TL Paprika") are skipped.
3. Exact n-grams first (so "gehackte Tomaten" is blocked before "gehackte"
   goes), then again without descriptor words (frisch, gerieben, rot, …),
   then for single German words a compound head ("Kirschtomaten" → tomatoes)
   or a cut ("Hähnchenbrustfilet" → chicken breast, "Knoblauchzehe" → garlic,
   one clove). English keys never match inside a word.
4. A key followed by a noun that names another food ("rice vinegar",
   "milk chocolate", "butter beans", "potato chips") prices nothing; a later
   key still can ("garlic bread" is bread).
5. The longest key wins, a tie goes to the rightmost word. A blocked winner
   ("Kokosmilch", "Pflanzenmilch", "Tomatenmark", "Paprikapulver",
   "Süßkartoffel") means no price.
6. An entry's excluded words anywhere in the label, also after the comma or
   in parentheses, mean no price: "Tomaten, passiert", "Tomaten (Dose)",
   "Knoblauch, granuliert".

Garlic counts fresh bulbs only (`en:fresh-vegetables`, no pickles or cans):
granulated garlic and garlic in oil share its tags. A banana weighs 170 g
unpeeled, as it is sold by the kilogram. "Skyr" reads as yogurt, whose rows
include it.

The name is read before a barcode's categories: Nutella's record carries
`en:sweet-spreads`, not `en:hazelnut-spreads`.

**Adding or changing an entry:** verify the tag live first, then add keys,
units and tests, and bump `kPriceDictionaryVersion`:

```sh
# German prices for a tag in the window (count only)
curl -s "https://prices.openfoodfacts.org/api/v1/prices?currency=EUR&lat=51.1657&lon=10.4515&radius_km=470&date__gte=2026-08-30&duplicate_of__isnull=true&product__categories_tags__contains=en:butters&size=100" \
  | jq '[.items[] | select(.location.osm_address_country_code=="DE")] | length'
# The categories of a barcode
curl -s "https://prices.openfoodfacts.org/api/v1/products/code/4002971840209" | jq .categories_tags
```

Piece, pack and spoon weights are starting values for review.

## Cache and privacy

The cache lives in memory in the signed-in home page (keyed by account and
session): aggregates per entry and per barcode for the local day and under
12 hours, "no data" included, failures never; barcode categories for the
session; at most 500 entries. Nothing is written to disk, so sign-out or an
account switch drops it. The requests carry category identifiers from the
built-in dictionary, barcodes of products in the list, the fixed Germany-wide
circle and the window, and the device's IP address; never the user's wording,
amounts, servings, recipe titles, an account identifier or a location.
Diagnostics are counts only (`requests=4 pages=3 priced=5`); a changed answer
shape is reported once per session without content. See
[PRIVACY.md](../PRIVACY.md).

## Tests

| Suite | Covers |
| --- | --- |
| `test/shopping_prices/price_label_test.dart` | Catalog lines, English, umlauts, compounds and cuts, false friends, modifier nouns, excluded words, trailing phrases, seasoning, tie rules, dictionary integrity |
| `test/shopping_prices/price_amount_test.dart` | Every display unit (read from `shopping_list.dart`) through the parser; fractions, ranges, multiples, ambiguous numbers |
| `test/shopping_prices/price_aggregation_test.dart` | Window cutoff (day 42 in, day 43 and future out), client filters, fresh garlic, discounts, normalisation, sample rule, one price per shop, 3x band, exact barcode, line cost, totals, region rule |
| `test/services/open_prices_wire_test.dart` | Loopback server with recorded answers: end to end, spec parameter allowlist and values, headers, paging, retry, timeout, 404, broken envelope, byte limit |
| `test/services/shopping_price_service_test.dart` | Concurrency, lookup cap, budgets, nothing sent past the run budget, cache and expiry, truncated and failed results not cached, cancel, dispose, session limit, diagnostics |
| `test/services/shopping_price_controller_test.dart` | One run per change, no synchronous notify, pause, late results, retry cooldown, midnight, a refused run |
| `test/meal_plan/shopping_prices_receipt_test.dart` | Receipt states, sum and note, no layout jump at 390 px and at 320 px with 2x text, stamp clear of the sum, seasoning only, checks, English, region, cancellation, link, semantics |
| `test/design/meal_plan_capture_test.dart` | Receipt shots with prices: loading (rows and totals), loaded, ticks, every line priced, done with stamp, failed, and 320 px at 2x text (rows and totals) |

Fixtures in `test/services/open_prices_fixtures/` are trimmed from a live
capture of 2026-10-11 (see the wire test's header).

## Expected coverage and limits

German data is thin and lumpy: 816 German prices in 42 days, a few
contributors supply most of them. With the 3-price rule about 11 of 27 staple
ingredients were priceable at the research date; on real lists expect about
**25–40 % of lines priced**, mostly milk, butter, bread, yogurt, bananas.
Meat, fish, fresh vegetables and cheese are often `k. A.`. Categories are
coarse (`en:yogurts` includes fruit yogurts, `en:salami` Kabanos). The
pro-rata share differs from what the till charges for a whole pack. Region
detection follows the device locales, so a German user whose phone names no
German region sees no prices.

A later server snapshot (one daily paged fetch, the same aggregation in an
Edge Function) would make every list cost one request and work offline, at
the price of a deployment and the ODbL obligations for the derived table.
