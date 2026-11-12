# sherpa-onnx's JNI code reads config fields and constructs result objects by name
# (GetFieldID / NewObject), so R8 must not rename or strip anything in its package.
-keep class com.k2fsa.sherpa.onnx.** { *; }
