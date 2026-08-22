# R8/ProGuard rules for the release build (isMinifyEnabled = true).
# The Flutter Gradle plugin ships the engine base rules; only plugin
# additions belong here. When in doubt, stay conservative.

# --- Flutter basics -----------------------------------------------------------
-keep class io.flutter.plugin.editing.** { *; }
# Flutter references Play Core classes for deferred components we do not
# bundle; those warnings are harmless.
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.**

# --- flutter_local_notifications (GSON serialization) -------------------------
# GSON needs generic signatures plus the ScheduledNotification models,
# otherwise scheduled notifications break after R8.
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod,InnerClasses
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep public class * implements java.lang.reflect.Type
-dontwarn com.google.gson.**

# --- mobile_scanner (ML Kit barcode) ------------------------------------------
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.vision.** { *; }
-dontwarn com.google.mlkit.**
# (E2) mobile_scanner uses the BUNDLED ML Kit model here: without
# dev.steenbakker.mobile_scanner.useUnbundled=true it pulls
# com.google.mlkit:barcode-scanning:17.3.0 into the artifact.
# See android/gradle.properties for the switch condition.
-dontwarn com.google.mlkit.vision.barcode.bundled.**

# --- google_sign_in (Credential Manager / Google Identity) --------------------
-keep class com.google.android.libraries.identity.googleid.** { *; }
-keep class androidx.credentials.** { *; }
-dontwarn androidx.credentials.**
-dontwarn com.google.android.gms.**

# --- health (Health Connect) --------------------------------------------------
-keep class androidx.health.connect.** { *; }
-keep class androidx.health.platform.** { *; }
-dontwarn androidx.health.**

# --- sentry_flutter -----------------------------------------------------------
# Sentry ships its own consumer rules; dontwarn covers optional
# integrations (OkHttp/Timber) we do not bundle.
-dontwarn io.sentry.**

# --- General annotation warnings (Tink/Guava transitive deps) -----------------
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
-dontwarn org.checkerframework.**
