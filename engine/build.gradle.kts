plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "dev.offline.voicetype.engine"
    compileSdk = 37

    defaultConfig {
        minSdk = 31
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(libs.sherpa.onnx)
    testImplementation(libs.junit)
}
