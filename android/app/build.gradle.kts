plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.nikhilraj.tethr"
    compileSdk {
        version = release(36) {
            minorApiLevel = 1
        }
    }

    defaultConfig {
        applicationId = "com.nikhilraj.tethr"
        minSdk = 26
        targetSdk = 36
        // Taken from the tag being released, so the APK cannot claim to be a
        // version it is not. v1.1.0 shipped the Messages build still calling
        // itself 1.0 with versionCode 1 — identical to the release before it,
        // which meant Android saw no upgrade at all and nobody could tell from
        // the phone which build they were running. The fallbacks are for a
        // local build, where the number does not matter.
        //
        // versionCode counts releases rather than encoding the name: it only
        // has to increase, and deriving it from the tag would break the first
        // time a version has two digits in a part.
        versionCode = System.getenv("TETHR_VERSION_CODE")?.toIntOrNull() ?: 1
        versionName = System.getenv("TETHR_VERSION")?.takeIf { it.isNotBlank() } ?: "dev"
    }

    // Driven by environment variables rather than a checked-in keystore: a
    // signing key must never live in the repository. CI supplies these from
    // secrets; locally they are simply absent and release builds stay unsigned.
    val keystorePath: String? = System.getenv("TETHR_KEYSTORE")?.takeIf { it.isNotBlank() }

    signingConfigs {
        if (keystorePath != null) {
            create("release") {
                storeFile = file(keystorePath)
                storePassword = System.getenv("TETHR_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("TETHR_KEY_ALIAS")
                keyPassword = System.getenv("TETHR_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            if (keystorePath != null) {
                signingConfig = signingConfigs.getByName("release")
            }
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    buildFeatures {
        compose = true
    }
}

dependencies {
    // Wire-format tests for SessionCrypto, which has to stay byte-compatible
    // with the Mac's Swift implementation.
    testImplementation("junit:junit:4.13.2")
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.material3)
    implementation(libs.okhttp)
    implementation(libs.zxing.embedded)
}
