plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    // AGP 9 compiles Kotlin itself ("built-in Kotlin"); declaring the Kotlin plugin here only
    // pins the Kotlin compiler version it uses (LiteRT-LM needs Kotlin >= 2.3 metadata support).
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.jvm) apply false
}
