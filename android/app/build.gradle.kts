plugins {
    id("com.android.application")
}

android {
    namespace = "com.timeato.app"
    compileSdk = 35
    buildToolsVersion = "35.0.0"

    defaultConfig {
        applicationId = "com.timeato.app"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
