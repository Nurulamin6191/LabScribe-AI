# Flutter Proguard Rules for Release Binary Optimization
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# Keep AudioRecordingService
-keep class dev.labscribe.app.AudioRecordingService { *; }

# Keep SQLite FFI & SQLite native components
-keep class com.tekartik.sqflite.** { *; }

# Keep OkHttp / Dio networking classes
-dontwarn okhttp3.**
-dontwarn okio.**
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod

# Strip debug log calls in release
-assumenosideeffects class android.util.Log {
    public static boolean isLoggable(java.lang.String, int);
    public static int v(...);
    public static int d(...);
}
