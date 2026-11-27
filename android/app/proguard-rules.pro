# Ark Novel Android R8 / ProGuard 规则

# 应用原生入口（MainActivity / ReadingWidget 已由 AndroidManifest 保留，这里显式兜底）
-keep class io.github.chenshi221.ark_novel.MainActivity { *; }
-keep class io.github.chenshi221.ark_novel.ReadingWidget { *; }

# LiteRT / Cronet / androidx.media / flutter_inappwebview 的保留规则已由上游 AAR consumer-rules 提供
-dontwarn org.tensorflow.lite.**
-dontwarn org.chromium.net.**
-dontwarn com.google.android.gms.**

# audio_service / MediaBrowserService / MediaButtonReceiver
-keep class com.ryanheise.audioservice.** { *; }
-dontwarn com.ryanheise.audioservice.**

# flutter_inappwebview WebView JS 桥与回调
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
-dontwarn com.pichillilorenzo.flutter_inappwebview_android.**

# 常见可选反射依赖消除误报警告
-dontwarn javax.annotation.**
-dontwarn org.checkerframework.**
-dontwarn com.google.errorprone.annotations.**
