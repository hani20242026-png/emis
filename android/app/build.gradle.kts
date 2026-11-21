plugins {
    id("com.android.application")
    // Kotlin is explicitly enabled because android.builtInKotlin=false in gradle.properties.
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val enableLocalAi = (System.getenv("ENABLE_LOCAL_AI") ?: "true").toBoolean()

android {
    namespace = "iq.moedu.emis.emis_app"
    compileSdk = 36
    // Keep the app and llamafu native module on the same NDK when Local AI is enabled.
    if (enableLocalAi) {
        ndkVersion = "28.2.13676358"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "iq.moedu.emis.emis_app"

        // llamafu/ggml uses pthread_atfork, which is available from Android API 23.
        // The native library is compiled for API 23, so the app must not install below it.
        minSdk = 23

        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            val keystorePath = System.getenv("ANDROID_KEYSTORE_PATH")
            val storePasswordValue = System.getenv("ANDROID_KEYSTORE_PASSWORD")
            val keyPasswordValue = System.getenv("ANDROID_KEY_PASSWORD")

            if (!keystorePath.isNullOrBlank()) {
                storeFile = file(keystorePath)
            }

            storePassword = storePasswordValue ?: ""
            keyPassword = keyPasswordValue ?: ""
            keyAlias = "emis-release"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")

            // Preserve the project's existing R8 setting.
            isMinifyEnabled = true

            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
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
