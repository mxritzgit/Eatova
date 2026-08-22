import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: android/key.properties holds keystore path and passwords and
// is deliberately not in the repo (see android/.gitignore). If it is missing
// (e.g. CI, which only builds debug), the release buildType below falls back to
// debug signing so debug builds keep working; the task-graph guard at the
// end of this file (E5) aborts any actual release artifact.
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
        // flutter_local_notifications (PROD-1) needs java.time, which older
        // Android versions only get via core library desugaring. Required by
        // the plugin since v6.
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
        // minSdk 26 instead of the Flutter default: package:health requires 26,
        // otherwise the manifest merge fails.
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
                // A relative storeFile path resolves against android/app/.
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

            // R8 code/resource shrinking; plugin keep rules live in
            // proguard-rules.pro.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

// --- E5: never sign release artifacts with the debug key --------------------
// Without key.properties the release buildType falls back to debug signing, and
// logger.warn alone is swallowed by the `flutter build` wrapper: the build
// succeeds and ships a debug-signed artifact whose SHA-1 breaks Google Sign-In.
//
// whenReady, not afterEvaluate: afterEvaluate only knows which variants are
// configured, not which the user requested, so aborting there would also kill
// debug builds and `flutter analyze`. The task graph is the first point where
// an actual release assemble is decidable, and whenReady runs before task one.
//
// Deliberately unaffected: `flutter test`/`flutter analyze` (no Gradle at all),
// `flutter build apk --debug`, and assembleRelease*Test tasks (end in ...Test,
// not matched by the regex).
// Matching on task.path avoids touching a Project object at execution time.
// The Action type is explicit because whenReady is overloaded with a Groovy
// Closure that cannot be built from a lambda; the Kotlin DSL Action helper
// takes a receiver lambda, so `this` is the TaskExecutionGraph.
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
    // Core library desugaring for flutter_local_notifications (java.time on
    // older Android). The plugin requires >= 2.1.4.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
