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
// Debug-Signing zurueck, damit Debug-Builds weiterlaufen. Ein Release-Artefakt
// darf daraus aber nicht entstehen - der Task-Graph-Guard am Dateiende (E5)
// bricht genau diesen Fall ab.
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

// --- E5: Release-Artefakte nie mit dem Debug-Key signieren -------------------
// Fehlt key.properties, faellt buildTypes.release oben auf Debug-Signing
// zurueck. Bisher blieb es bei logger.warn, das der `flutter build`-Wrapper
// faktisch verschluckt: `flutter build appbundle` lief durch und lieferte ein
// debug-signiertes Artefakt. Play weist den Upload ab - oder, schlimmer, ein
// sideloadetes APK traegt den universellen Android-Debug-Key, der
// Google-Sign-In-SHA-1 passt nicht und der native Login scheitert still.
//
// Warum taskGraph.whenReady und nicht afterEvaluate:
// afterEvaluate feuert am Ende der Projekt-Evaluierung. Dort ist nur bekannt,
// WELCHE Varianten konfiguriert sind - nicht, welche der Nutzer angefordert
// hat. Ein Abbruch dort wuerde jeden Debug-Build und jedes `flutter analyze`
// mitreissen, obwohl beide Release nie anfassen. Erst wenn der Task-Graph
// steht, ist entscheidbar, ob wirklich ein Release-Assemble ausgefuehrt wird.
// whenReady laeuft davor und bricht ab, bevor der erste Task startet.
//
// Bewusst NICHT betroffen:
//  - `flutter test` und `flutter analyze` starten gar kein Gradle.
//  - `flutter build apk --debug` (so baut .github/workflows/security.yml:119
//    ohne Signing-Secrets) erzeugt keinen Task, der auf ...Release endet.
//  - assembleReleaseUnitTest / assembleReleaseAndroidTest enden auf ...Test
//    und werden von der Regex absichtlich nicht erfasst.
// Der Abgleich laeuft ueber task.path statt task.project, damit zur
// Ausfuehrungszeit kein Project-Objekt angefasst wird.
// Der Action-Typ steht explizit da: whenReady ist mit Action UND mit Groovy-
// Closure ueberladen, und Kotlin waehlt sonst die Closure-Variante, die sich
// nicht aus einem Lambda bauen laesst. Der Action-Helfer des Kotlin-DSL nimmt
// ein Receiver-Lambda, `this` ist hier also der TaskExecutionGraph.
val releaseAssemblePattern = Regex("^(assemble|bundle|package)[A-Za-z0-9]*Release$")
gradle.taskGraph.whenReady(Action<org.gradle.api.execution.TaskExecutionGraph> {
    if (!keystorePropertiesFile.exists()) {
        val releaseTasks = allTasks
            .map { task -> task.path }
            .filter { path ->
                path.startsWith(":app:") &&
                    releaseAssemblePattern.matches(path.removePrefix(":app:"))
            }

        if (releaseTasks.isNotEmpty()) {
            throw GradleException(
                "Release-Build abgebrochen: android/key.properties fehlt.\n" +
                    "Betroffene Tasks: ${releaseTasks.joinToString(", ")}\n" +
                    "Ohne diese Datei wuerde das Artefakt mit dem universellen " +
                    "Android-DEBUG-Key signiert. Play lehnt den Upload ab, und " +
                    "ein sideloadetes Build laesst Google Sign-In still " +
                    "fehlschlagen, weil der SHA-1-Fingerabdruck nicht passt.\n" +
                    "Abhilfe: android/key.properties mit keyAlias, keyPassword, " +
                    "storeFile und storePassword anlegen (Vorlage und Ablage des " +
                    "Keystores siehe Release-Dokumentation). Fuer reine " +
                    "Kompilier-Checks stattdessen --debug bauen."
            )
        }
    }
})

flutter {
    source = "../.."
}

dependencies {
    // Core-Library-Desugaring fuer flutter_local_notifications (java.time auf
    // aelteren Android-Versionen). Version >= 2.1.4 wird vom Plugin gefordert.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
