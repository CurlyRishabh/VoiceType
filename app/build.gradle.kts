import com.android.build.api.artifact.SingleArtifact

plugins {
    alias(libs.plugins.android.application)
}

android {
    namespace = "dev.offline.voicetype"
    compileSdk = 37

    defaultConfig {
        applicationId = "dev.offline.voicetype"
        minSdk = 31
        targetSdk = 37
        versionCode = 1
        versionName = "1.0"
        // OnePlus 10R (Dimensity 8100) is arm64; ship nothing else.
        ndk { abiFilters += "arm64-v8a" }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Personal sideload build: sign with the local debug key so `assembleRelease` installs directly.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
    }

    // Don't embed the Google-signed dependency metadata block in the APK.
    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    packaging {
        resources.excludes += setOf("META-INF/*.kotlin_module", "META-INF/versions/**", "DebugProbesKt.bin")
    }
}

dependencies {
    implementation(project(":engine"))
    implementation(project(":cleanup"))
    implementation(project(":polish"))
    implementation(project(":insertion"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.appcompat)
    implementation(libs.androidx.preference)
    implementation(libs.androidx.recyclerview)
    implementation(libs.material)
    implementation(libs.kotlinx.coroutines.android)
}

// ---------------------------------------------------------------------------------------------
// Privacy gate: every build fails if the MERGED manifest (including all libraries) requests any
// network permission or enables backup, or if a tracking/Play-services dependency sneaks in.
// ---------------------------------------------------------------------------------------------
abstract class VerifyPrivacyTask : DefaultTask() {
    @get:InputFile abstract val mergedManifest: RegularFileProperty
    @get:Input abstract val runtimeDependencies: ListProperty<String>

    @TaskAction
    fun verify() {
        val manifest = mergedManifest.get().asFile.readText()
        val forbiddenPermissions = setOf(
            "android.permission.INTERNET",
            "android.permission.ACCESS_NETWORK_STATE",
            "android.permission.ACCESS_WIFI_STATE",
            "android.permission.CHANGE_NETWORK_STATE",
            "android.permission.CHANGE_WIFI_STATE",
            "android.permission.NEARBY_WIFI_DEVICES",
        )
        val requested = Regex("<uses-permission(?:-sdk-\\d+)?[^>]*android:name=\"([^\"]+)\"")
            .findAll(manifest).map { it.groupValues[1] }.toSet()
        val bad = requested intersect forbiddenPermissions
        if (bad.isNotEmpty()) throw GradleException("PRIVACY: merged manifest requests network permission(s): $bad")
        if (!manifest.contains("android:allowBackup=\"false\"")) throw GradleException("PRIVACY: android:allowBackup must be false")

        val forbiddenGroups = listOf("com.google.firebase", "com.google.android.gms", "com.google.android.play", "io.sentry", "com.crashlytics", "com.google.android.datatransport")
        val badDeps = runtimeDependencies.get().filter { dep -> forbiddenGroups.any { dep.startsWith(it) } }
        if (badDeps.isNotEmpty()) throw GradleException("PRIVACY: forbidden dependencies on runtime classpath: $badDeps")

        logger.lifecycle("Privacy check passed. Permissions requested: ${requested.sorted()}")
    }
}

androidComponents {
    onVariants { variant ->
        val cap = variant.name.replaceFirstChar { it.uppercase() }
        val verify = tasks.register<VerifyPrivacyTask>("verify${cap}Privacy") {
            mergedManifest.set(variant.artifacts.get(SingleArtifact.MERGED_MANIFEST))
            runtimeDependencies.set(
                provider {
                    variant.runtimeConfiguration.incoming.resolutionResult.allComponents.map { it.id.displayName }
                },
            )
        }
        tasks.matching { it.name == "assemble$cap" || it.name == "install$cap" }.configureEach { dependsOn(verify) }
    }
}
