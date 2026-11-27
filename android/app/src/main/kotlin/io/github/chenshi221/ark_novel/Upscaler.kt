package io.github.chenshi221.ark_novel

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import org.tensorflow.lite.Interpreter
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * 封面超分辨率：Real-ESRGAN 的 realesr-animevideov3（动漫图专用的小模型，放大 4 倍），模型在 assets/sr_x4.tflite。
 * 一次只跑一张（后台单线程）。长边超过 [MAX_INPUT] 的先缩到这么大再放大：中间结果按输入像素数涨，大图会占几百 MB 内存。
 * 每次用完就关掉解释器，不让它一直占着内存。
 */
class Upscaler private constructor(private val context: Context) {
    private val worker = Executors.newSingleThreadExecutor()

    private val modelBuffer: ByteBuffer by lazy {
        try {
            context.assets.openFd("sr_x4.tflite").use { fileDescriptor ->
                java.io.FileInputStream(fileDescriptor.fileDescriptor).use { inputStream ->
                    inputStream.channel.map(
                        java.nio.channels.FileChannel.MapMode.READ_ONLY,
                        fileDescriptor.startOffset,
                        fileDescriptor.declaredLength
                    )
                }
            }
        } catch (_: Exception) {
            val bytes = context.assets.open("sr_x4.tflite").use { it.readBytes() }
            ByteBuffer.allocateDirect(bytes.size).order(ByteOrder.nativeOrder()).apply {
                put(bytes)
                rewind()
            }
        }
    }

    fun upscale(input: ByteArray, done: (ByteArray?, String?) -> Unit) = worker.execute {
        try {
            done(run(input), null)
        } catch (e: Throwable) {
            done(null, e.message ?: e.javaClass.simpleName)
        }
    }

    // 一张图要分配几十 MB（输出 4 倍大小的浮点缓冲、Bitmap），像素按行读写避免整图 IntArray 峰值，用完的 Bitmap 马上 recycle，不等 GC
    private fun run(input: ByteArray): ByteArray {
        var bmp = BitmapFactory.decodeByteArray(input, 0, input.size) ?: throw IllegalArgumentException("图片解码失败")
        val long = max(bmp.width, bmp.height)
        if (long > MAX_INPUT) {
            val s = MAX_INPUT.toFloat() / long
            val scaled = Bitmap.createScaledBitmap(bmp, (bmp.width * s).roundToInt(), (bmp.height * s).roundToInt(), true)
            if (scaled !== bmp) bmp.recycle()
            bmp = scaled
        }
        val w = bmp.width
        val h = bmp.height
        val inBuf = ByteBuffer.allocateDirect(w * h * 3 * 4).order(ByteOrder.nativeOrder())
        try {
            val inRow = IntArray(w)
            for (y in 0 until h) {
                bmp.getPixels(inRow, 0, w, 0, y, w, 1)
                for (p in inRow) {
                    inBuf.putFloat(((p shr 16) and 0xff) / 255f)
                    inBuf.putFloat(((p shr 8) and 0xff) / 255f)
                    inBuf.putFloat((p and 0xff) / 255f)
                }
            }
        } finally {
            bmp.recycle()
        }
        inBuf.rewind()
        val ow = w * SCALE
        val oh = h * SCALE
        val outBuf = ByteBuffer.allocateDirect(ow * oh * 3 * 4).order(ByteOrder.nativeOrder())
        Interpreter(modelBuffer, Interpreter.Options().setNumThreads(4)).use { interp ->
            interp.resizeInput(0, intArrayOf(1, h, w, 3))
            interp.allocateTensors()
            interp.run(inBuf, outBuf)
        }
        outBuf.rewind()
        fun c(v: Float) = (v * 255f + 0.5f).toInt().coerceIn(0, 255)
        val result = Bitmap.createBitmap(ow, oh, Bitmap.Config.ARGB_8888)
        try {
            val outRow = IntArray(ow)
            for (y in 0 until oh) {
                for (x in 0 until ow) {
                    outRow[x] = (0xff shl 24) or (c(outBuf.float) shl 16) or (c(outBuf.float) shl 8) or c(outBuf.float)
                }
                result.setPixels(outRow, 0, ow, 0, y, ow, 1)
            }
            return ByteArrayOutputStream().use {
                result.compress(Bitmap.CompressFormat.JPEG, 92, it)
                it.toByteArray()
            }
        } finally {
            result.recycle()
        }
    }

    companion object {
        const val SCALE = 4
        const val MAX_INPUT = 600

        @Volatile
        private var instance: Upscaler? = null

        fun get(context: Context): Upscaler = instance ?: synchronized(this) {
            instance ?: Upscaler(context.applicationContext).also { instance = it }
        }
    }
}
