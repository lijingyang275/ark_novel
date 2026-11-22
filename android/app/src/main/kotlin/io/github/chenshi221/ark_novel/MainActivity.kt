package io.github.chenshi221.ark_novel

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.view.KeyEvent
import android.view.WindowManager
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// 生物识别锁（local_auth）要求 Activity 是 FragmentActivity；朗读通知（audio_service）要求用它的 Activity 共享引擎
class MainActivity : AudioServiceFragmentActivity() {
    private val intentChannelName = "ark/system_intents"
    private val readerVolumeChannelName = "ark/reader_volume_keys"
    private var readerVolumeChannel: MethodChannel? = null
    private var readerVolumeKeyHandlingEnabled = false

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        readerVolumeChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, readerVolumeChannelName)
        readerVolumeChannel?.setMethodCallHandler { call, result ->
            if (call.method == "setEnabled") {
                readerVolumeKeyHandlingEnabled = call.argument<Boolean>("enabled") ?: false
                result.success(null)
            } else {
                result.notImplemented()
            }
        }

        // 阅读器自定义亮度：value 在 0~1 之间设窗口亮度，负数交还给系统
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ark/screen").setMethodCallHandler { call, result ->
            if (call.method == "setBrightness") {
                val v = call.argument<Number>("value")?.toFloat() ?: -1f // Dart 传整数时是 Integer，不能按 Double 取
                val lp = window.attributes
                lp.screenBrightness = if (v < 0f) WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE else v.coerceIn(0.01f, 1f)
                window.attributes = lp
                result.success(null)
            } else {
                result.notImplemented()
            }
        }

        // 停止朗读时删掉朗读通知（audio_service 的通知 id 固定是 1124；服务被 App 绑着，它自己删不掉）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ark/tts").setMethodCallHandler { call, result ->
            when (call.method) {
                "cancelNotice" -> {
                    NotificationManagerCompat.from(this).cancel(1124)
                    result.success(null)
                }
                "requestNotificationPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    ) {
                        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1125)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // 封面超分辨率（见 Upscaler）：传进来原图字节，传回放大 4 倍的 JPEG
        // 进程里只有一个：Activity 每次重建都会走到这里，以前每次新建一个带线程的实例、从不释放
        val upscaler = Upscaler.get(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ark/upscale").setMethodCallHandler { call, result ->
            if (call.method != "upscale") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val bytes = call.argument<ByteArray>("bytes")
            if (bytes == null) {
                result.error("ARG_ERROR", "bytes is null", null)
                return@setMethodCallHandler
            }
            upscaler.upscale(bytes) { out, err ->
                runOnUiThread { if (out != null) result.success(out) else result.error("UPSCALE_FAILED", err, null) }
            }
        }

        // 防截屏、隐藏最近任务里的预览
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ark/secure").setMethodCallHandler { call, result ->
            if (call.method == "setSecure") {
                if (call.argument<Boolean>("secure") == true) {
                    window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, intentChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openTtsSettings" -> {
                        try {
                            val candidates = arrayListOf(
                                Intent("android.speech.tts.engine.TTS_SETTINGS"),
                                Intent("com.android.settings.TTS_SETTINGS"),
                                Intent(android.provider.Settings.ACTION_SETTINGS)
                            )
                            var launched = false
                            var lastErr: Exception? = null
                            for (it in candidates) {
                                try {
                                    it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    startActivity(it)
                                    launched = true
                                    break
                                } catch (e: Exception) {
                                    lastErr = e
                                }
                            }
                            if (launched) {
                                result.success(true)
                            } else {
                                result.error(
                                    "INTENT_FAILED",
                                    lastErr?.message ?: "no activity found",
                                    null
                                )
                            }
                        } catch (e: Exception) {
                            result.error("INTENT_FAILED", e.message, null)
                        }
                    }

                    "openApp" -> {
                        val pkg = call.argument<String>("package")
                        if (pkg.isNullOrBlank()) {
                            result.error("ARG_ERROR", "package is null/blank", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val pm: PackageManager = applicationContext.packageManager
                            val launchIntent = pm.getLaunchIntentForPackage(pkg)
                            if (launchIntent != null) {
                                launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                startActivity(launchIntent)
                                result.success(true)
                            } else {
                                result.error("NOT_FOUND", "app not found: $pkg", null)
                            }
                        } catch (e: Exception) {
                            result.error("INTENT_FAILED", e.message, null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    // 点桌面小组件时 App 可能刚被系统重建，Dart 那边还没开始监听，home_widget 会把这次的 intent 丢掉；
    // 换成当前 intent，App 启动后用 initiallyLaunchedFromHomeWidget 自己来取
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (readerVolumeKeyHandlingEnabled && (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)) {
            // The argument marks long-press repeats; the reader paces them.
            val method = if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) "volumeUp" else "volumeDown"
            readerVolumeChannel?.invokeMethod(method, (event?.repeatCount ?: 0) > 0)
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    // 按下时拦了，抬起也拦掉，系统不会再处理这次按键
    override fun onKeyUp(keyCode: Int, event: KeyEvent?): Boolean {
        if (readerVolumeKeyHandlingEnabled && (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)) return true
        return super.onKeyUp(keyCode, event)
    }
}
