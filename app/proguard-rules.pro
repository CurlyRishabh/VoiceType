# Library keep rules come from :engine (sherpa-onnx) and :polish (LiteRT-LM) consumer rules.

# LiteRT-LM depends on kotlin-reflect and Gson; these are referenced optionally.
-dontwarn kotlin.reflect.jvm.internal.**
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
-dontwarn org.jetbrains.annotations.**
