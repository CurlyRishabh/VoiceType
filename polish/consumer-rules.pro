# LiteRT-LM's JNI layer and its Gson/reflection-based JSON conversion look classes and members up
# by name; keep them intact under R8.
-keep class com.google.ai.edge.litertlm.** { *; }
-keepclassmembers class * {
    @com.google.gson.annotations.SerializedName <fields>;
}
-dontwarn com.google.ai.edge.litertlm.**
