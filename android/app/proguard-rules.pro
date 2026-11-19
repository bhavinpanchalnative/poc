# ARCore: keep the SDK classes; it uses reflection and JNI.
-keep class com.google.ar.core.** { *; }
-dontwarn com.google.ar.core.**
