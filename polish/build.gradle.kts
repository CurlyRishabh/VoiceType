plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "dev.offline.voicetype.polish"
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
    implementation(project(":cleanup"))
    implementation(libs.litertlm)
}
