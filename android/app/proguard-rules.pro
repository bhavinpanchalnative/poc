# ARCore: keep the SDK classes; it uses reflection and JNI.
-keep class com.google.ar.core.** { *; }
-dontwarn com.google.ar.core.**

# MediaPipe (furniture detection): JNI and protobuf use reflection.
-keep class com.google.mediapipe.** { *; }
-dontwarn com.google.mediapipe.**
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.protobuf.**
