# Favorites keep their product photo; a lively favorites list

Owner request, 2026-10-03. Design approved in chat the same day (option
"lebendige Liste").

## Goal

1. A product favorited with a photo (search hit or barcode scan) shows that
   photo in the favorites, not the first letter of its name. The photo
   survives a restart and reaches the account's other devices.
2. The favorites menu becomes livelier in the dark Eatova design: photo
   tiles, one-tap add, macros at a glance, sorting.

## Data: `MealAnalysisResult.imageUrl`

- New optional field. `fromOpenFoodFacts` sets it from the product map in the
  order the search hit used so far: `image_front_small_url`,
  `image_front_url`, `image_small_url`, `image_url`.
  `ProductSearchResult.imageUrl` reads it from its result, so there is one
  source.
- Accepted only as `https` on `images.openfoodfacts.org` or
  `static.openfoodfacts.org`, without user info or port, at most 512
  characters (`sanitizeProductImageUrl`). Anything else is null, never an
  error: a synced payload must not make the app load arbitrary addresses.
- `mealResultToJson` writes `imageUrl` only when set (old rows stay
  byte-identical); `mealResultFromJson` reads it through the same check. It
  lives in the existing jsonb payloads of `favorite_meals` and
  `logged_meals`. No migration, no function deploy: neither payload has a
  server validator, and older builds ignore the key (one that rewrites a
  favorite drops it).
- `adjustedToGrams` and `adjustedToItems` keep it. AI scans, recipes and
  manual entries have none.
- A favorite never loses a photo it has: when the store or the add sheet
  rewrites an entry (heart, log, recents bump) with a result that has no
  photo, the stored one stays (`FavoriteMeal.keepImage`). A heart or an add
  from a search hit gives an old photo-less favorite its photo.
- `PRIVACY.md` says that product photos load from the Open Food Facts image
  server, which sees the device's IP address. The website text lives in
  another repository and stays an open item.

## UI: the lively list

Applies to pinned favorites in the favorites sheet and to the three inline
favorites of the add-meal sheet (`SavedMealHeader`).

- Row: a 48 px tile (product photo, else the letter tile), the name in up to
  two lines, below it "Brand · 60 g · **212 kcal**" and the macro dots
  P/C/F in Today's macro colors. On the right the heart on top and a round
  accent "+" below.
- "+" logs the saved portion into the sheet's slot at once, through the same
  add path as the panel (guards, toast "Added 212 kcal to Lunch", the tile's
  check). While the row is expanded, the panel's "+" is the only add.
- Recents show their photo (no "+"). Search hits are unchanged.
- Favorites sheet header: title and close, search, then sort chips
  "Recent" (default), "Frequent" (logs in the last 35 days, recency breaks
  ties) and "A–Z", then one compact line with the slot tile saying where adds
  go. The subtitle sentence goes.
- Motion: the list cross-fades when the sort changes; "+" has the press
  scale. Both are off under reduced motion.
- Accessibility: "+" is a button "Add Protein bar, 212 kcal, to Lunch"; the
  chips are selectable buttons; every target is at least 44 px; 320 px and
  2x text without overflow; de and en.

## Verification

Model round trip, host check, portion scaling; a search hit hearted keeps
its photo through restart and in the sync payload; "+" logs exactly once
into the right slot; sort orders; no overflow; mutation checks on the
guarantees; real-font renders; full suite, then PR and merge after green CI.
