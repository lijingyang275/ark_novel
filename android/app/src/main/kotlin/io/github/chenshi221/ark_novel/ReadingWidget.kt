package io.github.chenshi221.ark_novel

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.net.Uri
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import org.json.JSONArray

// 桌面小组件「继续阅读」：最近读的 4 本封面，颜色跟着 App 的配色。数据由 App 写进 SharedPreferences（见 lib/next/reading_widget.dart）
class ReadingWidget : AppWidgetProvider() {
    companion object {
        const val PREFS_NAME = "HomeWidgetPreferences"
    }

    private val covers = intArrayOf(R.id.widget_cover0, R.id.widget_cover1, R.id.widget_cover2, R.id.widget_cover3)

    // 解码、裁切封面放到后台线程：onUpdate 在主线程上跑，图大、设备慢时会拖慢桌面，超过 10 秒还会 ANR
    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        val pending = try {
            goAsync()
        } catch (e: Exception) {
            null
        }
        Thread {
            try {
                val widgetData = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                render(context, appWidgetManager, appWidgetIds, widgetData)
            } catch (e: Exception) {
                // 数据格式不对（例如旧版本留下的）：这次不更新，不能让 App 进程崩溃
            } finally {
                pending?.finish()
            }
        }.start()
    }

    private fun render(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray, widgetData: SharedPreferences) {
        val parsed = try {
            JSONArray(widgetData.getString("books", "[]"))
        } catch (e: Exception) {
            JSONArray()
        }
        // 格式不对的条目跳过
        val books = (0 until parsed.length()).mapNotNull { parsed.optJSONObject(it) }.take(covers.size)
        val bitmaps = books.map { b ->
            b.optString("cover").takeIf { it.isNotEmpty() }?.let { roundedCover(it, b.optJSONArray("crop")) }
        }
        val icon = widgetData.getString("icon", null)?.let { BitmapFactory.decodeFile(it) }
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.reading_widget)
            applyColors(context, views, widgetData)
            if (icon != null) {
                views.setImageViewBitmap(R.id.widget_icon, icon)
                views.setViewVisibility(R.id.widget_icon, View.VISIBLE)
            } else {
                views.setViewVisibility(R.id.widget_icon, View.GONE)
            }
            views.setViewVisibility(R.id.widget_empty, if (bitmaps.isEmpty()) View.VISIBLE else View.GONE)
            views.setOnClickPendingIntent(android.R.id.background, launch(context, "ark://shelf"))
            covers.forEachIndexed { i, coverId ->
                if (i >= bitmaps.size) {
                    // 不够 4 本：占着位置但不显示，封面大小不变
                    views.setViewVisibility(coverId, View.INVISIBLE)
                    return@forEachIndexed
                }
                val b = books[i]
                views.setViewVisibility(coverId, View.VISIBLE)
                val bmp = bitmaps[i]
                if (bmp != null) views.setImageViewBitmap(coverId, bmp) else views.setImageViewResource(coverId, R.mipmap.launcher_icon)
                val aid = b.optString("aid")
                val cid = b.optString("cid")
                views.setOnClickPendingIntent(coverId, launch(context, if (aid.isEmpty() || cid.isEmpty()) "ark://shelf" else "ark://reader/$aid/$cid"))
            }
            appWidgetManager.updateAppWidget(id, views)
        }
    }

    // App 跟随系统时把浅色、深色两套都给出来：安卓 12 起小组件自己随深浅色切换，不用等 App 刷新
    private fun applyColors(context: Context, views: RemoteViews, data: SharedPreferences) {
        val bgLight = parse(data.getString("bgLight", null)) ?: return
        val bgDark = parse(data.getString("bgDark", null)) ?: bgLight
        val accentLight = parse(data.getString("accentLight", null)) ?: bgLight
        val accentDark = parse(data.getString("accentDark", null)) ?: accentLight
        val subLight = parse(data.getString("subLight", null)) ?: accentLight
        val subDark = parse(data.getString("subDark", null)) ?: accentDark
        val mode = data.getString("mode", "system")
        val night = (context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        fun set(viewId: Int, method: String, light: Int, dark: Int) = when {
            mode == "light" -> views.setInt(viewId, method, light)
            mode == "dark" -> views.setInt(viewId, method, dark)
            Build.VERSION.SDK_INT >= 31 -> views.setColorInt(viewId, method, light, dark)
            else -> views.setInt(viewId, method, if (night) dark else light)
        }
        set(R.id.widget_bg, "setColorFilter", bgLight, bgDark)
        set(R.id.widget_title, "setTextColor", accentLight, accentDark)
        set(R.id.widget_empty, "setTextColor", subLight, subDark)
    }

    private fun parse(s: String?) = try {
        s?.let { Color.parseColor(it) }
    } catch (e: Exception) {
        null
    }

    private fun launch(context: Context, uri: String): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            data = Uri.parse(uri)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        return PendingIntent.getActivity(context, uri.hashCode(), intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    // 小组件的图片走进程间传输，有大小上限：按高约 300 像素缩，再切圆角。[crop] 是书架上自选封面的裁剪框（左、上、宽、高，0~1 的比例）
    private fun roundedCover(path: String, crop: JSONArray?): Bitmap? = try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        var sample = 1
        while (bounds.outHeight / (sample * 2) >= 300) sample *= 2
        BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = sample })?.let { full ->
            val raw = if (crop != null && crop.length() == 4) {
                val x = (crop.getDouble(0) * full.width).toInt().coerceIn(0, full.width - 1)
                val y = (crop.getDouble(1) * full.height).toInt().coerceIn(0, full.height - 1)
                val cw = (crop.getDouble(2) * full.width).toInt().coerceIn(1, full.width - x)
                val ch = (crop.getDouble(3) * full.height).toInt().coerceIn(1, full.height - y)
                Bitmap.createBitmap(full, x, y, cw, ch)
            } else full
            // 有的卷封面是横着的跨页图：从中间裁成竖版书封的比例，4 本才对得齐
            val w = minOf(raw.width, (raw.height * 0.7f).toInt())
            val src = if (w < raw.width) Bitmap.createBitmap(raw, (raw.width - w) / 2, 0, w, raw.height) else raw
            val out = Bitmap.createBitmap(src.width, src.height, Bitmap.Config.ARGB_8888)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { shader = BitmapShader(src, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP) }
            val r = src.width * 0.08f
            Canvas(out).drawRoundRect(RectF(0f, 0f, src.width.toFloat(), src.height.toFloat()), r, r, paint)
            // 中间几张已经画进 out 了，马上释放（createBitmap 尺寸不变时会返回同一个对象，别重复释放）
            if (src !== raw) src.recycle()
            if (raw !== full) raw.recycle()
            full.recycle()
            out
        }
    } catch (e: Exception) {
        null
    }
}
