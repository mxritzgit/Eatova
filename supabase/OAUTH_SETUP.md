# Google sign-in setup

Checked against the app source on **2026-09-14**. The login UI offers
email/password and Google. Apple remains in the repository's OAuth enum but
has no exposed login button; enabling it in Supabase alone does not add a flow.

## Current flow

The app first opens native Google sign-in and exchanges the returned ID token
with Supabase. Native initialization/authentication failures can fall back to
web OAuth; user cancellation does not silently launch another login flow.
The web path uses an external auth session with PKCE.

Sources: [AuthRepository](../lib/src/auth/auth_repository.dart),
[Google token provider](../lib/src/auth/google_id_token_provider.dart),
[client configuration](../lib/src/config/supabase_config.dart).

## One account per mailbox

Supabase links a Google sign-in to an existing account only when the
addresses are the same; manual linking is off
(`security_manual_linking_enabled` false). Without the
[alias guard](../docs/BACKEND.md#one-account-per-mailbox), a Google address
that is another spelling of an existing account's address (Gmail dots,
`googlemail.com`, a `+` tag) gets a second, empty account. With it (live
since 2026-10-25), the Before User Created hook rejects that first sign-in with 422
and creates nothing. New builds then say that an account exists for this
address in another spelling and to sign in the way the user registered
(`authErrorOAuthAccountExists`, on the OAuth path only); older builds show
the generic error. This reveals nothing to a stranger, because Google has
proven the mailbox, and a stranger's unconfirmed alias signup never blocks
the Google sign-in. Linking Google to the existing account is a follow-up.
The web fallback (no native sign-in, and Apple) shows nothing: GoTrue
redirects to `eatova://login-callback/?error=server_error&error_description=...`,
which [`isOAuthCallbackDeeplink`](../lib/src/config/supabase_config.dart)
drops because it carries no `code`, so the user closes the browser sheet and
is back on the sign-in screen without a message. Rendering that error is a
follow-up that has to keep the predicate as strict as it is.

## Configure your own project

1. Set up the Google consent screen and OAuth clients for your actual app.
   The app package is `com.eatova.app`; register the Android signing identities
   used for development and release. iOS needs its own client and matching
   reversed-client-ID URL scheme.
2. Enable Google in Supabase Auth. Configure the web client and its secret
   there, with the accepted client audiences needed by your native clients.
3. Set public `GOOGLE_WEB_CLIENT_ID` and `GOOGLE_IOS_CLIENT_ID` Dart defines for
   your build. The web ID is used as `serverClientId`; the iOS ID is also passed
   as `clientId` on iOS. Client secrets stay in Supabase.
4. Configure the Google-to-Supabase callback using the URL shown in Supabase's
   Google provider panel. This is distinct from the mobile return URL below.

See the official [Supabase Google setup](https://supabase.com/docs/guides/auth/social-login/auth-google)
for current provider-console fields and audience configuration.

## Mobile return URL

Add this exact URL to Supabase Auth's redirect allow-list for the web fallback:

```text
eatova://login-callback/
```

The app handles the scheme in [iOS Info.plist](../ios/Runner/Info.plist) and
[AndroidManifest.xml](../android/app/src/main/AndroidManifest.xml). The callback
validator accepts the intended PKCE code flow and rejects token fragments.
Do not replace the email OTP templates with magic links to this custom scheme.
See [mobile deep linking](https://supabase.com/docs/guides/auth/native-mobile-deep-linking)
and the project's [email OTP contract](AUTH_EMAIL_OTP.md).

## Validate the installed build

Verify successful native login, cancellation, web fallback and a cold-start
callback on the intended platforms/signing identities; once the alias guard
is live, also a Google sign-in in another spelling of an email account. A
dummy-signed CI build proves compilation, not working Google console
configuration. Changing a Dart client ID does not update an already
installed binary or its native URL scheme.
