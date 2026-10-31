package app.followsound.android

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.widget.Toast
import androidx.core.content.FileProvider
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * 走 GitHub Releases 的自动更新。
 * 不依赖任何应用商店：查 latest release → 下 APK → 交给系统安装器。
 */
object Updater {

    private const val API = "https://api.github.com/repos/VVCY/FollowSound/releases/latest"

    fun check(activity: Activity, manual: Boolean) {
        Thread {
            try {
                val obj = JSONObject(httpGet(API))
                val tag = obj.optString("tag_name").trim().removePrefix("v").removePrefix("V")
                if (!isNewer(tag, BuildConfig.VERSION_NAME)) {
                    if (manual) toast(activity, "已是最新版本 v${BuildConfig.VERSION_NAME}")
                    return@Thread
                }
                val notes = obj.optString("body", "")
                val assets = obj.optJSONArray("assets")
                var url: String? = null
                var name: String? = null
                for (i in 0 until (assets?.length() ?: 0)) {
                    val a = assets!!.getJSONObject(i)
                    val n = a.optString("name")
                    if (!n.endsWith(".apk")) continue
                    if (url == null || n.contains(tag)) { url = a.optString("browser_download_url"); name = n }
                    if (n.contains(tag)) break
                }
                if (url == null) {
                    if (manual) toast(activity, "这个版本还没有安卓安装包")
                    return@Thread
                }
                val finalUrl = url!!
                val finalName = name ?: "FollowSound-Android-$tag.apk"
                activity.runOnUiThread { ask(activity, tag, notes, finalUrl, finalName) }
            } catch (e: Exception) {
                if (manual) toast(activity, "检查更新失败：${e.message}")
            }
        }.start()
    }

    private fun ask(activity: Activity, version: String, notes: String, url: String, name: String) {
        AlertDialog.Builder(activity)
            .setTitle("发现新版本 v$version")
            .setMessage(notes.take(600).ifBlank { "包含若干修复与优化。" })
            .setPositiveButton("下载并安装") { _, _ -> download(activity, url, name) }
            .setNegativeButton("稍后", null)
            .show()
    }

    private fun download(activity: Activity, url: String, name: String) {
        toast(activity, "开始下载…")
        Thread {
            try {
                val dir = File(activity.getExternalFilesDir(null), "Download").apply { mkdirs() }
                val out = File(dir, name)
                val conn = (URL(url).openConnection() as HttpURLConnection).apply {
                    connectTimeout = 15000
                    readTimeout = 30000
                    instanceFollowRedirects = true
                    setRequestProperty("User-Agent", "FollowSound-Android/${BuildConfig.VERSION_NAME}")
                }
                conn.inputStream.use { input -> out.outputStream().use { input.copyTo(it) } }
                activity.runOnUiThread { install(activity, out) }
            } catch (e: Exception) {
                toast(activity, "下载失败：${e.message}")
            }
        }.start()
    }

    private fun install(activity: Activity, apk: File) {
        // Android 8+ 装"商店外"的包要先允许本应用安装未知来源
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !activity.packageManager.canRequestPackageInstalls()
        ) {
            activity.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}"))
            )
            toast(activity, "允许「随响」安装应用后，再点一次检查更新")
            return
        }
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", apk)
        activity.startActivity(
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        )
    }

    private fun httpGet(url: String): String {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15000
            readTimeout = 15000
            setRequestProperty("Accept", "application/vnd.github+json")
            setRequestProperty("User-Agent", "FollowSound-Android/${BuildConfig.VERSION_NAME}")
        }
        return conn.inputStream.bufferedReader().use { it.readText() }
    }

    private fun isNewer(remote: String, local: String): Boolean {
        val a = remote.split(".").map { it.takeWhile(Char::isDigit).toIntOrNull() ?: 0 }
        val b = local.split(".").map { it.takeWhile(Char::isDigit).toIntOrNull() ?: 0 }
        for (i in 0 until maxOf(a.size, b.size)) {
            val x = a.getOrElse(i) { 0 }
            val y = b.getOrElse(i) { 0 }
            if (x != y) return x > y
        }
        return false
    }

    private fun toast(ctx: Context, msg: String) {
        (ctx as? Activity)?.runOnUiThread { Toast.makeText(ctx, msg, Toast.LENGTH_SHORT).show() }
            ?: Toast.makeText(ctx, msg, Toast.LENGTH_SHORT).show()
    }
}
