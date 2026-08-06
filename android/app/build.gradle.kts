import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release-Signing: android/key.properties haelt Keystore-Pfad und Passwoerter
// und ist bewusst NICHT im Repo (siehe android/.gitignore). Fehlt die Datei
// (z. B. im CI, das nur Debug baut), faellt der Release-Buildtype unten auf
// Debug-Signing zurueck, statt den Build zu brechen.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}

android {
    namespace = "com.eatova.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications (PROD-1) nutzt java.time-APIs, die auf
        // aelteren Android-Versionen erst durch Core-Library-Desugaring
        // verfuegbar werden. Pflicht laut Plugin-Setup ab v6+.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.eatova.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // minSdk 26 (Android 8.0) statt Flutter-Default: package:health verlangt
        // mindestens 26, sonst bricht der Manifest-Merge ab.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                // Relativer storeFile-Pfad wird gegen android/app/ aufgeloest.
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "WARNUNG: android/key.properties fehlt - Release wird mit dem " +
                        "DEBUG-Key signiert und ist NICHT fuer den Play Store geeignet."
                )
                signingConfigs.getByName("debug")
            }

            // R8: Code-Shrinking/Obfuskation + Ressourcen-Shrinking.
            // Keep-Rules fuer Plugins liegen in proguard-rules.pro.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Core-Library-Desugaring fuer flutter_local_notifications (java.time auf
    // aelteren Android-Versionen). Version >= 2.1.4 wird vom Plugin gefordert.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
