plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Lowest API the on-device speech engine supports (PRD-MOBILE.md §10.2).
//
// Deliberately not `flutter.minSdkVersion`: Flutter 3.47 defaults it to 24, and
// its MinSdkVersionMigration rewrites a literal `minSdk = 23` back to the
// default on every build. Carrying the value in a named constant keeps the
// requirement (23) intact across builds.
val umliveMinSdk = 23

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
        // sherpa_onnx requires API 23; the product targets Android 10+ (PRD §7).
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
