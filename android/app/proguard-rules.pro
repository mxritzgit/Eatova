# R8/ProGuard-Regeln fuer den Release-Build (isMinifyEnabled = true).
# Die Flutter-Engine-Basisregeln liefert das Flutter-Gradle-Plugin selbst;
# hier stehen nur Ergaenzungen fuer unsere Plugins. Im Zweifel konservativ.

# --- Flutter-Basics -----------------------------------------------------------
-keep class io.flutter.plugin.editing.** { *; }
# Flutter referenziert Play-Core-Klassen fuer Deferred Components, die wir
# nicht einbinden - Warnungen dazu sind harmlos.
-dontwarn com.google.android.play.core.**
-dontwarn io.flutter.embedding.engine.deferredcomponents.**

# --- flutter_local_notifications (GSON-Serialisierung) ------------------------
# GSON braucht generische Signaturen + die ScheduledNotification-Modelle,
# sonst schlagen geplante Notifications nach R8 fehl.
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod,InnerClasses
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep public class * implements java.lang.reflect.Type
-dontwarn com.google.gson.**

# --- mobile_scanner (ML Kit Barcode) ------------------------------------------
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.vision.** { *; }
-dontwarn com.google.mlkit.**
# Korrektur (E2): mobile_scanner nutzt hier das GEBUENDELTE ML-Kit-Modell.
# Ohne dev.steenbakker.mobile_scanner.useUnbundled=true zieht
# mobile_scanner-7.4.0/android/build.gradle:63-69 com.google.mlkit:barcode-
# scanning:17.3.0 samt libbarhopper_v3.so und den .tflite-Assets ins Artefakt.
# Der frueher hier stehende Satz ("nutzt das unbundled Modell") war falsch.
# Begruendung und Umschaltbedingung stehen in android/gradle.properties.
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
# Sentry liefert eigene Consumer-Rules mit; dontwarn deckt optionale
# Integrationen (z. B. OkHttp/Timber) ab, die wir nicht einbinden.
-dontwarn io.sentry.**

# --- Allgemeine Annotation-Warnungen (Tink/Guava-Transitivabhaengigkeiten) ----
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
-dontwarn org.checkerframework.**
