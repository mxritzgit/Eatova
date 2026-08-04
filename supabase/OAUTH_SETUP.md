# Eatova Supabase OAuth setup

The Flutter app opens Supabase OAuth for Apple and Google and expects this mobile callback URL:

```text
eatova://login-callback/
```

Add this URL in Supabase Dashboard:

Authentication -> URL Configuration -> Redirect URLs

Then enable the providers:

Authentication -> Providers -> Google
Authentication -> Providers -> Apple

Provider credentials stay in Supabase. Do not put Google or Apple client secrets into the Flutter app.

Notes:

- iOS handles the `eatova` URL scheme via `ios/Runner/Info.plist`.
- Android handles the same callback via `android/app/src/main/AndroidManifest.xml`.
- Supabase also needs the provider-specific redirect/callback URL shown in each provider's dashboard panel when creating Google/Apple OAuth credentials.
