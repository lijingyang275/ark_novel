import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 正式签名：android/key.properties（已在 android/.gitignore 里，不入库）写 storeFile（相对 android/ 目录）、storePassword、keyAlias、keyPassword 四项。
// 没有这个文件就照旧用 debug 签名，和以前装在手机上的包一致。
// 注意：换签名后不能覆盖安装，要先卸载（会清空 App 数据），已经装着 debug 签名包的手机不要随便加这个文件。
val releaseKeys = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "io.github.chenshi221.ark_novel"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    androidResources {
        noCompress += "tflite"
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "io.github.chenshi221.ark_novel"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        getByName("debug") {
            val customKeystore = file("${System.getProperty("user.home")}/.android/hikari-debug.keystore")
            if (customKeystore.exists()) {
                storeFile = customKeystore
            }
        }
        if (!releaseKeys.isEmpty()) {
            create("release") {
                storeFile = rootProject.file(releaseKeys.getProperty("storeFile"))
                storePassword = releaseKeys.getProperty("storePassword")
                keyAlias = releaseKeys.getProperty("keyAlias")
                keyPassword = releaseKeys.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (releaseKeys.isEmpty()) "debug" else "release")
        }
    }
}

// 按 --target-platform 过滤第三方 AAR 自带的原生库（--target-platform 本身只管 Flutter .so）；
// 不传时默认保留 arm64-v8a / armeabi-v7a / x86_64 全架构通用打包。
val targets = project.findProperty("target-platform")?.toString()
val isSplit = project.findProperty("split-per-abi")?.toString()?.toBoolean() == true
if (!isSplit) {
    val keepAbis = targets
        ?.split(",")
        ?.mapNotNull {
            when (it.trim()) {
                "android-arm" -> "armeabi-v7a"
                "android-arm64" -> "arm64-v8a"
                "android-x64" -> "x86_64"
                "android-x86" -> "x86"
                else -> null
            }
        }
        ?.toSet()
        ?.takeIf { it.isNotEmpty() }
        ?: setOf("arm64-v8a", "armeabi-v7a", "x86_64")
    val excludedAbis = listOf("armeabi-v7a", "arm64-v8a", "x86_64", "x86")
        .filter { it !in keepAbis }
        .map { "lib/$it/**" }
    if (excludedAbis.isNotEmpty()) {
        androidComponents {
            onVariants(selector().withBuildType("release")) { variant ->
                variant.packaging.jniLibs.excludes.addAll(excludedAbis)
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // 封面超分辨率的推理库（原 TensorFlow Lite），见 Upscaler.kt
    implementation("com.google.ai.edge.litert:litert:1.4.2")
}
