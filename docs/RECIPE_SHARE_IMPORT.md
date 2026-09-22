# Recipe share import

## Product decisions

The required journey is **TikTok -> Share -> Eatova -> Eatova opens -> in-app
recipe review sheet**. TikTok provides the source link/text; extraction, recipe
selection and saving happen in Eatova. No recipe overlay inside TikTok is wanted.
Nothing enters the user's recipe library until the user confirms a specific recipe.

| Source content | Behavior |
| --- | --- |
| One recipe with a usable ingredient list | Open its preview directly; allow edits and explicit saving. |
| Multiple recipes | Show separate choices in source order, with no preselected recipe. |
| Explicit vegan substitution | Offer a separate source-backed variant; do not silently replace the original. |
| Several wanted recipes | Save each deliberately from the same result; mark saved choices and finish when ready. |
| Missing/private/unavailable caption | Ask for pasted recipe text in the same sheet. |
| Ingredients in the caption, steps only in the video | Preview the ingredients and explicitly mark missing steps; never invent instructions. |
| Partial nutrition | Keep and display every known value, including zero. Only missing values are blank; block food logging until complete. |
| Nutrition without a serving basis | Preserve the caption values, show the unclear basis, and require confirmation/correction in the recipe editor before food logging. |
| Repeated share | Content-based recipe identity prevents overwriting an existing saved import. |

The existing Recipes header also has an Import action for pasting a link or text.
No clipboard is read automatically. Imported photos are not fetched or generated.

## Platform behavior

Android receives bounded `ACTION_SEND` text on cold and warm starts and opens the
Flutter review sheet after authentication/onboarding. It does not request permission
to draw over other apps.

iOS uses a Share Extension only to receive and protect the source, then attempts
to open Eatova automatically with a dedicated, payload-free wake URL. It does not
ask the user to prepare or review the source first. A failed start keeps the source
and offers retry without enqueuing it again. Recipe extraction and confirmation
remain in Eatova, after authentication/onboarding.

Automatic opening uses the modern public UIApplication URL API through the
responder chain. This is a compatibility technique used by other apps, **not an
Apple-supported Share Extension contract**. The extension keeps
`APPLICATION_EXTENSION_API_ONLY=YES`; the typed instance method does not require
`UIApplication.shared`, private APIs or dynamic selectors. Future iOS compatibility
and App Store acceptance are
not established by passing mocked tests or a native build. The earlier manual-open
handoff does not satisfy the clarified product requirement.

No credentials or recipe text enter the wake URL. App Group provisioning and
Apple-device verification remain required; see [native integration](NATIVE_RECIPE_SHARE.md).

## Extraction and persistence

`recipe-import` accepts authenticated POST `{text, locale, version: 2}`. Older callers may omit `version` and retain the earlier complete-recipe/per-serving contract. Source text is limited
to 20,000 UTF-16 code units. The service returns up to six candidates, source
attribution and machine-readable missing/truncated-source warnings.

Only exact HTTPS TikTok video/short-link hosts and paths are fetched. Every redirect
is validated and bounded. Public oEmbed metadata is retried once for transient errors.
If unavailable or apparently truncated, a bounded public video page can provide
inert hydration JSON. Its post ID must match the shared video exactly; HTML/scripts
are never executed, and no login/challenge is bypassed. Unsupported recipe
sites, Instagram and YouTube currently require pasted text. Multiple distinct links
are ambiguous and are not resolved by choosing one automatically.

The provider separates recipes and returns verbatim ingredient/preparation evidence.
The server verifies those quotes against the supplied source and discards ungrounded
candidates. This prevents invented recipe text from entering a preview, but does not
prove that a model associated every quote with the correct dish. Human review remains
part of the workflow. Whitespace differences are normalized without rewriting source
content; repeated quantities in different recipe parts are preserved. Nutrition
recognizes German/English labels, abbreviations, decimals, approximate caption values
and per-piece wording. Explicit whole-recipe totals are divided only by a proven
yield. Missing values are never estimated; ambiguous serving bases stay pending.

No extraction request writes recipe rows. Explicit saves use `HomeStore.saveUserRecipe`
and the existing encrypted cache, transactional outbox, server revisions and ownership
checks. Source attribution is retained in the persisted description. Missing nutrition
uses the persisted `Nutrition pending` category, localized at display time, so existing
row/snapshot/history formats remain compatible without a migration. Neutral numeric
storage fields are not treated as measured zero while this marker is present.
Additional `Nutrition known: <field>` markers preserve individual known values,
and `Nutrition basis pending` records an unclear serving basis. These internal
markers are hidden from category chips and survive cache/outbox/history round trips.
Older pending recipes without known-field markers remain entirely unknown.

The model uses a strict structured-output schema and completed-response/JSON/source
validation. A transient failure or invalid response permits one retry, each with a
fresh provider reservation, within the same request deadline. The server enforces
array limits: nested schema `maxItems` was rejected by the live Gemini provider.

Incoming native sources and extraction responses are bounded. Account/session changes
clear pending imports, close old routes and reject late responses and saves. Native
delivery waits for the first explicit authentication binding. iOS persists only a
nonsecret hash of the user/session scope and checks it on every consume, so failed
protected-file cleanup cannot expose an earlier account's source after a restart.
Unowned sources can wait for their first login. Backend
authentication, rate gates and provider reservations fail closed. Imports share the
existing `coach_recipe` paid-call budget and also have separate import rate limits;
closing a paid request does not refund it. Error responses contain no source text,
provider response, token or database diagnostics.

## Delivery requirements

- Deploy the reviewed `recipe-import` Edge Function with JWT verification and the
  existing Supabase/OpenRouter secret bindings; no secrets belong in the app.
- Review the new source-processing behavior in the product privacy notice before
  public release. TikTok receives metadata requests for supported public links;
  recipe text is processed by the configured AI provider.
- Provision the iOS app and extension App Group and verify a signed build on device.
- Verify real TikTok shares, public/private captions, cold/warm starts and account
  transitions on physical Android/iOS devices. Stubbed provider tests do not establish
  live TikTok availability or real-model extraction quality.

Implementation and local verification do not imply deployment, store release or
installation on the user's normal app.

## Primary platform references

- [TikTok public video embeds and oEmbed](https://developers.tiktok.com/doc/embed-videos/)
- [TikTok video query: authorized user's videos](https://developers.tiktok.com/doc/tiktok-api-v2-video-query/)
- [Android: receiving simple data from other apps](https://developer.android.com/training/sharing/receive)
- [Apple: sharing data with your containing app](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html)

See the dated entry in [PROJECT_HANDOFF.md](PROJECT_HANDOFF.md) for verification
results and remaining platform checks.
