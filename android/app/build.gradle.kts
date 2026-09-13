import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing.
//
// Android installs an APK over an existing one only when both are signed by
// the same key. Without a real release key a build silently falls back to the
// *debug* keystore, and that one is generated per machine — so an APK built on
// the dev laptop and one built by a GitHub Actions runner are, as far as
// Android is concerned, two unrelated apps claiming the same package name.
// Installing either over the other fails with
// INSTALL_FAILED_UPDATE_INCOMPATIBLE, and the only way through is an uninstall,
// which wipes the player's save.
//
// Neither of these files is in git (see .gitignore) — the key is a secret. CI
// writes them from repository secrets before building; see
// docs/RELEASE_SIGNING.md. When they are absent the build still works, it just
// falls back to debug signing, so a fresh clone needs no setup to run.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("app/key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
}

android {
    namespace = "com.raftrumble.raft_rumble"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    defaultConfig {
        applicationId = "com.raftrumble.raft_rumble"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = rootProject.file("app/release-key.jks")
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

// Kotlin 2.3 removed the `kotlinOptions { jvmTarget }` DSL — setting it there
// is now a hard error rather than a deprecation, so the target is declared
// here instead.
kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.fromTarget("11")
    }
}

flutter {
    source = "../.."
}
