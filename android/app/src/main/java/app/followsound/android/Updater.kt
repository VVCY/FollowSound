package app.followsound.android

import android.app.Activity
import android.app.Dialog
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.FileProvider
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 走 GitHub Releases 的自动更新。
 * 不依赖任何应用商店：查 latest release → 下 APK → 交给系统安装器。
 *
 * 界面统一用 R.layout.dialog_update 那张卡片（Element 风格的深色面板），
 * 不再用系统 AlertDialog —— 系统弹窗是浅灰方角 + 系统字体，和 App 里其它控件完全不是一套。
 */
object Updater {

    // 地址由 build.gradle.kts 注入（默认 GitHub，联调可用 -PfsUpdateApi 指到本地）
    private val API = BuildConfig.UPDATE_API

    /**
     * 国内加速前缀（逗号分隔，空串=直连）。
     *
     * GitHub 直连在手机运营商网络上基本连不上（真机实测 timeout），所以加了一层
     * 「前缀 + 原地址」的反代。反代是社区服务，随时可能关停 —— 因此它们只是候选，
     * 不是写死的唯一入口：谁先回一个合法的 JSON 就用谁，选中的记下来，下次先试它。
     */
    private val MIRRORS: List<String> =
        BuildConfig.UPDATE_MIRRORS.split(',').map { it.trim() }.filter { it.startsWith("http") }

    /** 上次成功的源（完整地址），下次排在候选第一位 */
    private const val KEY_SRC = "updateSource"

    /** 本次版本信息来自哪个前缀（"" = 直连），下载沿用同一个源 */
    @Volatile private var sourcePrefix: String = ""

    /**
     * 已经下完、但卡在「允许安装未知来源」那一步的包。
     * 用户去设置里点开开关回来，不该再从 GitHub 重下 20 多 MB —— 直接装这个。
     */
    @Volatile private var pendingApk: File? = null
    @Volatile private var pendingVersion: String? = null
    @Volatile private var downloading = false

    /** 三种状态共用的一张卡片 */
    private class Panel(val activity: Activity) {
        private val root: View = LayoutInflater.from(activity).inflate(R.layout.dialog_update, null)
        val dialog = Dialog(activity, R.style.FollowSoundDialog)
        val title: TextView = root.findViewById(R.id.dTitle)
        val sub: TextView = root.findViewById(R.id.dSub)
        val scroll: View = root.findViewById(R.id.dScroll)
        val body: TextView = root.findViewById(R.id.dBody)
        val progressBox: View = root.findViewById(R.id.dProgressBox)
        val bar: ProgressBar = root.findViewById(R.id.dBar)
        val progressText: TextView = root.findViewById(R.id.dProgressText)
        val cancel: TextView = root.findViewById(R.id.dCancel)
        val ok: TextView = root.findViewById(R.id.dOk)

        private val density = activity.resources.displayMetrics.density
        private fun dp(v: Int) = (v * density).toInt()

        init {
            dialog.setContentView(root)
            dialog.window?.apply {
                setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
                val dm = activity.resources.displayMetrics
                setLayout(
                    minOf((dm.widthPixels * 0.88f).toInt(), dp(400)),
                    ViewGroup.LayoutParams.WRAP_CONTENT
                )
                // 卡片自己就是圆角，窗口别再叠一层系统底板
                decorView.setPadding(0, 0, 0, 0)
            }
        }

        /** 版本说明可能很长：超过 240dp 就限高滚动，别把按钮顶出屏幕 */
        fun setNotes(text: String) {
            body.text = text
            scroll.visibility = View.VISIBLE
            root.post {
                val max = dp(240)
                if (scroll.height > max) {
                    scroll.layoutParams = scroll.layoutParams.also { it.height = max }
                }
            }
        }

        fun show() {
            if (activity.isFinishing || activity.isDestroyed) return
            dialog.show()
        }

        fun dismiss() {
            if (dialog.isShowing) dialog.dismiss()
        }

        fun progress(pct: Int, label: String) {
            progressBox.visibility = View.VISIBLE
            bar.progress = pct.coerceIn(0, 100)
            progressText.text = label
        }
    }

    fun check(activity: Activity, manual: Boolean) {
        Thread {
            try {
                val obj = fetchLatest(activity)
                val tag = obj.optString("tag_name").trim().removePrefix("v").removePrefix("V")
                if (!isNewer(tag, BuildConfig.VERSION_NAME)) {
                    if (manual) toast(activity, "已是最新版本 v${BuildConfig.VERSION_NAME}")
                    return@Thread
                }
                // 上次已经下好了、只差安装权限：别让用户白等第二遍
                val cached = pendingApk
                if (cached != null && pendingVersion == tag && cached.exists()) {
                    activity.runOnUiThread { install(activity, cached) }
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
                if (manual) toast(activity, "检查更新失败：${friendly(e)}")
            }
        }.start()
    }

    /**
     * 候选接口地址：只有真正指向 GitHub 时才套反代。
     * 本地联调会换成 127.0.0.1，那种地址前面加前缀只会更慢，原样用。
     */
    private fun apiCandidates(ctx: Context): List<String> {
        if (!API.contains("api.github.com")) return listOf(API)
        val all = MIRRORS.map { it + API } + API
        val last = prefs(ctx).getString(KEY_SRC, null)
        // sortedBy 是稳定排序：除了「上次成功的那个」，其余保持原顺序
        return all.sortedBy { if (it == last) 0 else 1 }
    }

    /**
     * 同时把候选源都问一遍，谁先给出合法 JSON 用谁。
     *
     * 不做「挨个试」是因为每个源的超时都按秒算：国内直连 GitHub 要等满 15s 才失败，
     * 用户会觉得点了没反应。竞速最好 1s 出结果，最差也只是等第一个超时。
     */
    private fun fetchLatest(ctx: Context): JSONObject {
        val cands = apiCandidates(ctx)
        val pool = Executors.newFixedThreadPool(minOf(cands.size, 3))
        try {
            val tasks = cands.map { c ->
                Callable {
                    val obj = JSONObject(httpGet(c, connect = 4000, read = 9000))
                    // 反代挂掉时常回 403/502 或一页 HTML，JSONObject 能解析但没版本号
                    if (obj.optString("tag_name").isBlank()) throw IOException("没有版本号")
                    c to obj
                }
            }
            val done = pool.invokeAny(tasks, 16, TimeUnit.SECONDS)
            sourcePrefix = done.first.removeSuffix(API)
            prefs(ctx).edit().putString(KEY_SRC, done.first).apply()
            // 留在 logcat 里：用户报「更不了」时，先看它到底挑了哪个源
            Log.i("FollowSound", "update source: ${done.first}")
            return done.second
        } catch (e: Exception) {
            throw IOException("所有更新源都连不上，请检查网络后重试")
        } finally {
            pool.shutdownNow()
        }
    }

    /** 下载地址走同一套源：本次用的源排第一，其余镜像兜底，直连垫底 */
    private fun downloadCandidates(url: String): List<String> {
        if (!API.contains("api.github.com")) return listOf(url)
        val ordered = ArrayList<String>()
        if (sourcePrefix.isNotEmpty()) ordered += sourcePrefix + url
        MIRRORS.forEach { if (it != sourcePrefix) ordered += it + url }
        ordered += url
        return ordered.distinct()
    }

    /**
     * 依次试候选地址，返回第一个真能读的连接。
     * 除了「连得上」还要看状态码 —— 反代最常见的失败是 403/502 配一页错误页，
     * 那种连接拿来当下载流，最后只会得到「不是安装包」。
     */
    private fun connectAny(cands: List<String>): HttpURLConnection {
        var last: Exception? = null
        for (u in cands) {
            try {
                val conn = (URL(u).openConnection() as HttpURLConnection).apply {
                    connectTimeout = 8000
                    readTimeout = 30000
                    instanceFollowRedirects = true
                    setRequestProperty("Accept", "application/octet-stream")
                    setRequestProperty("User-Agent", "FollowSound-Android/${BuildConfig.VERSION_NAME}")
                }
                val code = conn.responseCode
                if (code == HttpURLConnection.HTTP_OK || code == 206) return conn
                conn.disconnect()
                last = IOException("HTTP $code")
            } catch (e: Exception) {
                last = e
            }
        }
        throw last ?: IOException("没有可用的下载源")
    }

    private fun prefs(ctx: Context) =
        ctx.getSharedPreferences(AndroidHost.PREFS, Context.MODE_PRIVATE)

    private fun ask(activity: Activity, version: String, notes: String, url: String, name: String) {
        val p = Panel(activity)
        p.title.text = "发现新版本 v$version"
        p.setNotes(notes.take(1200).ifBlank { "包含若干修复与优化。" })
        p.cancel.text = "稍后"
        p.ok.text = "下载并安装"
        p.cancel.setOnClickListener { p.dismiss() }
        p.ok.setOnClickListener {
            p.dismiss()
            download(activity, url, name, version)
        }
        p.show()
    }

    /** 下载被用户取消。单独一个类型，免得和网络异常混在一起报「下载失败」。 */
    private class Cancelled : Exception()

    /**
     * 带进度条的下载。
     *
     * 以前是静默 copyTo，界面上只有一句「开始下载…」—— 包 20 多 MB，
     * 用户对着不动的屏幕等十几秒，不知道是在下、卡住了、还是已经死了。
     */
    private fun download(activity: Activity, url: String, name: String, version: String) {
        // 连点两下「检查更新」不要开出两条下载线程，各写同一个文件会写坏
        if (downloading) {
            toast(activity, "正在下载中…")
            return
        }
        downloading = true

        val p = Panel(activity)
        p.title.text = "正在下载 v$version"
        p.scroll.visibility = View.GONE
        p.progress(0, "连接中…")
        p.cancel.text = "取消"
        p.ok.visibility = View.GONE
        p.dialog.setCancelable(false)
        p.dialog.setCanceledOnTouchOutside(false)
        val cancelled = AtomicBoolean(false)
        p.cancel.setOnClickListener {
            cancelled.set(true)
            p.cancel.isEnabled = false
            p.cancel.text = "正在取消…"
            p.cancel.alpha = 0.5f
        }
        p.show()

        Thread {
            var conn: HttpURLConnection? = null
            var out: File? = null
            try {
                val dir = File(activity.getExternalFilesDir(null), "Download").apply { mkdirs() }
                out = File(dir, name)
                conn = connectAny(downloadCandidates(url))
                val total = conn.contentLengthLong      // -1 = 服务端没给长度
                var read = 0L
                conn.inputStream.use { input ->
                    out.outputStream().use { os ->
                        val buf = ByteArray(64 * 1024)
                        var lastPct = -1
                        while (true) {
                            if (cancelled.get()) throw Cancelled()
                            val n = input.read(buf)
                            if (n < 0) break
                            os.write(buf, 0, n)
                            read += n
                            // 拿不到总长度时按「已下载多少」报，不做百分比
                            val pct = if (total > 0) ((read * 100) / total).toInt() else -1
                            if (pct != lastPct) {
                                lastPct = pct
                                activity.runOnUiThread {
                                    if (pct >= 0) {
                                        p.progress(pct, "${mb(read)} / ${mb(total)} · $pct%")
                                    } else {
                                        p.progressText.text = "已下载 ${mb(read)}"
                                    }
                                }
                            }
                        }
                    }
                }
                if (cancelled.get()) throw Cancelled()
                verifyApk(out, read, total)
                downloading = false
                pendingApk = out
                pendingVersion = version
                activity.runOnUiThread { p.dismiss(); install(activity, out!!) }
            } catch (e: Cancelled) {
                downloading = false
                try { out?.delete() } catch (ignored: Exception) { }
                activity.runOnUiThread { p.dismiss(); toast(activity, "已取消下载") }
            } catch (e: Exception) {
                downloading = false
                try { out?.delete() } catch (ignored: Exception) { }
                val why = friendly(e)
                activity.runOnUiThread {
                    p.dismiss()
                    failed(activity, url, name, version, why)
                }
            } finally {
                try { conn?.disconnect() } catch (ignored: Exception) { }
            }
        }.start()
    }

    /**
     * 下完先验一眼再交给系统安装器。
     *
     * 少了这一步，网络中断只会留下半个包、代理拦截会留下一个 HTML 错误页，
     * 用户点开安装看到的是系统那句「解析软件包时出现问题」—— 完全不知道是下载没下全。
     * APK 本质是个 zip，头两字节一定是 "PK"。
     */
    private fun verifyApk(file: File, read: Long, total: Long) {
        if (total > 0 && read != total) {
            throw IOException("下载不完整（${mb(read)} / ${mb(total)}），请重试")
        }
        val head = ByteArray(2)
        FileInputStream(file).use { if (it.read(head) < 2) throw IOException("安装包为空，请重试") }
        if (head[0] != 0x50.toByte() || head[1] != 0x4B.toByte()) {
            throw IOException("下载到的不是安装包（可能被网络拦截），请重试")
        }
        if (file.length() < 1024 * 64) {
            throw IOException("安装包只有 ${file.length() / 1024} KB，明显不完整，请重试")
        }
    }

    private fun install(activity: Activity, apk: File) {
        // Android 8+ 装"商店外"的包要先允许本应用安装未知来源
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !activity.packageManager.canRequestPackageInstalls()
        ) {
            activity.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}"))
            )
            toast(activity, "允许「随响」安装应用后，回来点「检查更新」即可安装，不用重新下载")
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

    private fun httpGet(url: String, connect: Int = 15000, read: Int = 15000): String {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = connect
            readTimeout = read
            instanceFollowRedirects = true
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

    private fun mb(bytes: Long): String = String.format("%.1f MB", bytes / 1024.0 / 1024.0)

    /** 把网络异常翻成人话：用户看到 "timeout" 只会更困惑 */
    private fun friendly(e: Exception): String = when {
        e is java.net.SocketTimeoutException -> "网络连接超时，已自动换源；仍失败请检查网络后重试"
        e is java.net.UnknownHostException -> "解析不到域名，请检查网络"
        e is javax.net.ssl.SSLException -> "安全连接失败，请检查网络是否被劫持"
        e.message.isNullOrBlank() -> "未知原因"
        else -> e.message!!
    }

    /** 失败不吞掉：给原因 + 直接重试，不用再点一遍「检查更新」重新走一遍版本比对 */
    private fun failed(activity: Activity, url: String, name: String, version: String, why: String) {
        val p = Panel(activity)
        p.title.text = "下载失败"
        p.title.setTextColor(Color.parseColor("#FF8C9F"))
        p.sub.visibility = View.VISIBLE
        p.sub.text = "v$version · 可以重试，已下载的部分不会保留"
        p.setNotes(why)
        p.cancel.text = "关闭"
        p.ok.text = "重试"
        p.cancel.setOnClickListener { p.dismiss() }
        p.ok.setOnClickListener {
            p.dismiss()
            download(activity, url, name, version)
        }
        p.show()
    }

    private fun toast(ctx: Context, msg: String) {
        (ctx as? Activity)?.runOnUiThread { Toast.makeText(ctx, msg, Toast.LENGTH_SHORT).show() }
            ?: Toast.makeText(ctx, msg, Toast.LENGTH_SHORT).show()
    }
}
