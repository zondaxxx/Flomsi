plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.zonda.mail_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.zonda.mail_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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

// Rust bridge: cargo-ndk builds libmail_bridge.so for each ABI into jniLibs before the APK is assembled.
val cargoNdk by tasks.registering(Exec::class) {
    val crateDir = file("../../rust")
    val outDir = file("src/main/jniLibs")
    val cargo = System.getenv("CARGO") ?: (System.getenv("HOME") + "/.cargo/bin/cargo")
    workingDir = crateDir
    inputs.dir(file("../../rust/src"))
    outputs.dir(outDir)
    commandLine(
        cargo, "ndk",
        "-t", "arm64-v8a", "-t", "x86_64",
        "-o", outDir.absolutePath,
        "build", "--release",
    )
}

tasks.matching { it.name.startsWith("merge") && it.name.endsWith("JniLibFolders") }.configureEach {
    dependsOn(cargoNdk)
}
tasks.matching { it.name == "preBuild" }.configureEach { dependsOn(cargoNdk) }
