pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // sherpa-onnx is published as an AAR on GitHub releases, not on Maven Central.
        // scripts/fetch-sherpa-aar.sh places the pinned, checksum-verified AAR here.
        maven {
            name = "vendored"
            url = uri(File(settingsDir, "third_party/maven"))
            content { includeGroup("com.k2fsa.sherpa.onnx") }
        }
    }
}

rootProject.name = "VoiceType"

include(":app")
include(":engine")     // audio capture, VAD, speech-to-text (sherpa-onnx)
include(":cleanup")    // pure-Kotlin Stage 1 rules + Stage 2 orchestration (unit tested on the JVM)
include(":polish")     // on-device LLM polish (LiteRT-LM)
include(":insertion")  // accessibility-based text insertion for the floating bubble
