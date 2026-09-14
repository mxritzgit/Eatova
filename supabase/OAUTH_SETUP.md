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
callback on the intended platforms/signing identities. A dummy-signed CI build
proves compilation, not working Google console configuration. Changing a Dart
client ID does not update an already installed binary or its native URL scheme.
