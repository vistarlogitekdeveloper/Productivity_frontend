plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.productivity_tracker"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.productivity_tracker"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // NOTE: no `ndk.abiFilters` here on purpose — it conflicts with
            // `flutter build apk --split-per-abi` (AGP forbids abiFilters +
            // abi splits together). Use `--split-per-abi` (per-ABI APKs) or
            // `--target-platform android-arm64` (single arm64 APK) to slim
            // the build instead.
        }
    }
}

// Point Mobile EmKit SDK. Ships as an .aar under android/app/libs and is
// consumed as a local file dependency — Point Mobile publish no Maven
// coordinate for it.
//
// Rugged Point Mobile handhelds (PM75, RS35 and family) deliver scan results
// ONLY through this SDK's Kotlin/AIDL surface. A plain BroadcastReceiver on
// `device.scanner.RESULT` — the action their public docs name — hears nothing
// at all; see the long note in MainActivity.kt for what actually fires.
//
// The .aar is absent on every other device, and MainActivity catches that, so
// this dependency does not stop the app building or running on a phone.
dependencies {
    implementation(fileTree(mapOf(
        "dir" to "libs",
        "include" to listOf("*.aar"),
    )))
}

flutter {
    source = "../.."
}
