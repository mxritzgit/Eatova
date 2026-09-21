# Native recipe sharing

Eatova receives recipe links and plain text through the operating system share
sheet. A share is an untrusted source for a draft; it never creates a recipe by
itself. The Flutter import flow reviews extracted recipes before saving.

## Platform behavior

- **Android:** Eatova appears for `ACTION_SEND` / `text/plain`. Selecting it
  opens Eatova and the import sheet. Initial and subsequent intents use the same
  receiver, with at most eight pending items. Sources remain in process memory;
  unfinished imports do not survive a process termination. The existing OAuth
  `ACTION_VIEW` intent filter and native plugin registration are preserved.
- **iOS:** the `RecipeShareExtension` target receives the source, writes it once
  to the protected local inbox and automatically attempts to open Eatova.
  There is no source-review/prepare step. Eatova displays the recipe review
  sheet after authentication/onboarding. A denied or timed-out app launch shows
  a retry action; retry reuses the queued source instead of creating duplicates.

The intended journey on both platforms is TikTok -> Share -> Eatova -> main app
opens -> recipe sheet inside Eatova. A recipe overlay in TikTok is not a product
requirement. iOS may display its transient extension presentation while handing
off; no extraction or recipe confirmation runs there.

The iOS wake URL is exactly `eatova-share://import`, with no query, fragment,
source text, credentials or account identifier. Runner consumes only the dedicated
wake signal and reads the protected inbox through the authenticated receiver.
Unrelated URL callbacks, including OAuth, retain the existing Flutter handling.

The launcher uses the typed modern `UIApplication.open(_:options:completionHandler:)`
API on the responder chain, after the extension has appeared. This API is public
but unavailable in Apple's supported Share Extension API set. Only the extension
sets `APPLICATION_EXTENSION_API_ONLY = NO` to compile this explicit compatibility
path. No `UIApplication.shared`, deprecated `openURL:`, dynamic selector or private
API is used. Apple explicitly warns that opening the containing app this way is
unsupported; Telegram's current implementation is precedent, not an Apple guarantee.
Simulator unit tests and a successful build do not prove real TikTok app switching
or future App Store acceptance.

Both entry points accept up to 20,000 UTF-16 code units of plain text. Images and
video attachments are not imported. A social platform may supply only a URL;
receiving a share does not establish that the caption, video, or recipe can be
retrieved.

## iOS setup and storage

The Runner and extension entitlements name
`group.com.eatova.app.recipe-share`. Register this App Group and enable it for
both `com.eatova.app` and `com.eatova.app.RecipeShareExtension` in the Apple
Developer account. Refresh provisioning profiles for both targets, using the
same development team. A previously provisioned Runner profile without the new
App Group is insufficient. App Group availability and signing require a Mac
and the appropriate developer account; they cannot be established from the
Windows source checkout.

The inbox holds at most eight sources for 24 hours. `NSFileCoordinator`
serializes access from the two processes. Each write is atomic, uses complete
iOS file protection, and is excluded from backups. No session tokens, account
credentials, extracted recipes, or health data are shared with the extension.
An account change clears the inbox and rotates its generation; an extension
already open for an earlier generation cannot write a delayed share afterward.
The inbox also persists a nonsecret SHA-256 owner/session scope. Every consume
compares it with the current authenticated scope before returning any source;
a mismatch discards earlier account content even after a process restart or a
failed locked-file clear. An explicitly unowned source can survive its first
login. No token or raw account/session identifier enters the App Group.
Unreadable protected files produce a sanitized channel error and can be retried
when the device is unlocked.

## Channel contract

`eatova/recipe_share` exposes:

- `consumePending({owner: String?})`: returns up to eight `{id: String, text: String}` values and
  removes those native pending sources.
- `clearPending({owner: String?})`: discards pending sources; iOS also invalidates open extension
  sessions.
- `sharesAvailable`: Android share or iOS wake callback asking Flutter to drain the inbox.

`RecipeShareReceiver` polls on startup and foregrounding, suppresses duplicate
IDs, bounds incoming payloads, and invalidates in-flight delivery on clear or
dispose. Subscribe to `shares` and call `bindOwner` before `start`; explicit null
binds the signed-out state, while an omitted owner cannot consume native sources.
The app coordinator owns login gating, pending sheets, and clearing on account switches. Native `clearPending`
failures must not be treated as a successful account-isolation cleanup.

## Verification before release

The Dart receiver tests exercise cold/warm delivery, foreground polling,
validation, duplicate delivery, concurrent drain requests, account changes,
disposal, and protected-inbox retry. `RecipeShareInboxTests` exercises persistence,
consume-once behavior, expiry with a fixed clock, account-generation invalidation,
input bounds, overflow without evicting older entries, and changed/same/signed-out
owner behavior across restarts. Run the latter in
Xcode with the Runner test target on a Mac.

On a physical Android and iPhone, verify:

1. Share a link from TikTok and plain recipe text from another app with Eatova
   closed, then repeat with Eatova backgrounded.
2. On Android, check that the import sheet opens exactly once and Back returns
   through the normal app stack. On iOS, selecting Eatova must automatically
   open the main app and offer the import exactly once, without a prepare button
   or manual app switch. Repeat with a denied launch and the retry action.
3. Cancel the import and confirm that no recipe was saved. Share again and
   explicitly add a chosen draft.
4. Share before login, then log in. Switch accounts during an open import and
   during an open iOS extension; earlier content must not appear for the new
   account.
5. Check invalid/oversized input, eight pending sources, offline opening,
   locked/unlocked iPhone behavior, Dynamic Type, VoiceOver/TalkBack, and the
   native extension keyboard on a small iPhone.
6. Recheck Google sign-in, OAuth callbacks, and background synchronization. Build
   and archive the iOS app with its embedded extension and verify provisioning.

Sources: [Android receiving shared data](https://developer.android.com/develop/ui/compose/sharing/receive),
[Apple extension lifecycle and communication](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html),
[Apple Share Extensions](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Share.html),
[Apple shared containers](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html),
[Apple file encryption](https://developer.apple.com/documentation/uikit/encrypting-your-app-s-files).

App-start compatibility:
[Apple's extension limitation](https://developer.apple.com/forums/thread/764570),
[Telegram's current share launcher](https://github.com/TelegramMessenger/Telegram-iOS/blob/master/Telegram/Share/ShareRootController.swift).
