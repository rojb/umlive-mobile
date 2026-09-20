plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Lowest API the app supports.
//
// The floor comes from the product and from storage, not from the speech
// engine: PRD-MOBILE.md §7 puts the product floor at Android 10 (API 29) — the
// demo handset is API 33 — and `flutter_secure_storage` v11 declares minSdk 24,
// which the manifest merger enforces. sherpa_onnx only asks for 23, so it is
// not the binding constraint.
//
// Deliberately not `flutter.minSdkVersion`: Flutter 3.47 defaults it to 24, and
// its MinSdkVersionMigration rewrites a bare literal back to the default on
// every build. Carrying the value in a named constant keeps it intact across
// builds.
val umliveMinSdk = 24

android {
    namespace = "com.umlive.voice"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.umlive.voice"
        // The product floor is Android 10 (PRD §7); secure storage raises it to
        // API 24. The demo handset is API 33.
        minSdk = umliveMinSdk
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // The demo handset is arm64-v8a, and the sherpa_onnx native libraries
        // are large enough that shipping extra ABIs is not free.
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
