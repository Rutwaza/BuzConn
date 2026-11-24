import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

// ---------------------------------------------------------------------------
// Duhuze release setup (see docs/RELEASE.md)
//
// App id: the final id is rw.duhuze.app. It needs its own Android app in
// Firebase and a matching android/app/google-services.json
// (tools/register-android-app.ps1 does both). Until that file contains
// rw.duhuze.app, builds keep the old development id so nothing breaks.
//
// Signing: release builds are signed with the upload key described in
// android/key.properties (made by tools/create-upload-key.ps1, never in Git).
// Without that file, release builds fall back to the debug key (fine for
// testing, NOT accepted by Google Play).
// ---------------------------------------------------------------------------
val duhuzeAppId = "rw.duhuze.app"
val devAppId = "com.example.bussinessfinder"
val googleServicesFile = file("google-services.json")
val useDuhuzeId = googleServicesFile.exists() &&
    googleServicesFile.readText().contains("\"$duhuzeAppId\"")
if (!useDuhuzeId) {
    logger.warn("Duhuze: google-services.json has no $duhuzeAppId yet, building as $devAppId. Run tools/register-android-app.ps1.")
}

val keyProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasUploadKey = keyProperties.getProperty("storeFile") != null

android {
    // Kotlin package of MainActivity; it does not have to match the app id.
    namespace = "com.example.bussinessfinder"
    // Google Play requires target API 36 (Android 16) for new apps and updates
    // since 31 Aug 2026, so never go below it.
    compileSdk = maxOf(flutter.compileSdkVersion, 36)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = if (useDuhuzeId) duhuzeAppId else devAppId
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = maxOf(flutter.targetSdkVersion, 36)
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasUploadKey) {
            create("release") {
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasUploadKey) {
                signingConfigs.getByName("release")
            } else {
                logger.warn("Duhuze: android/key.properties missing, release build uses the DEBUG key (not for Google Play).")
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
