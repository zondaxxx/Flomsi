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
        // flutter_local_notifications needs the newer Java APIs on older Android.
        isCoreLibraryDesugaringEnabled = true
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
        // Where the sign-in sheet comes back to: the reversed Google Android client ID and
        // Microsoft's msal<id> scheme, from the same build variables the Rust side reads.
        // Without them a placeholder keeps the manifest valid (and the buttons stay hidden).
        val google = System.getenv("FLOMSI_GOOGLE_ANDROID_CLIENT_ID")?.trim().orEmpty()
            .removeSuffix(".apps.googleusercontent.com")
        val microsoft = System.getenv("FLOMSI_MICROSOFT_CLIENT_ID")?.trim().orEmpty()
        manifestPlaceholders += mapOf(
            "appAuthRedirectScheme" to
                if (google.isEmpty()) "dev.zonda.flomsi.google" else "com.googleusercontent.apps.$google",
            "msAuthRedirectScheme" to
                if (microsoft.isEmpty()) "dev.zonda.flomsi.microsoft" else "msal$microsoft",
        )
    }

    // One key for every release, so an update installs over the last version and Google
    // recognises the app (its Android client is tied to this key's SHA-1). CI decodes it
    // from a repository secret; a local build without it falls back to the debug key.
    val keystore = System.getenv("FLOMSI_KEYSTORE_PATH")?.takeIf { file(it).exists() }
    signingConfigs {
        if (keystore != null) {
            create("release") {
                storeFile = file(keystore)
                storePassword = System.getenv("FLOMSI_KEYSTORE_PASSWORD")
                keyAlias = "flomsi"
                keyPassword = System.getenv("FLOMSI_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystore != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
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
