package app.followsound.android

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.webkit.JavascriptInterface

/**
 * 把 WebView 里选的特效/配色/高度落进 SharedPreferences，
 * 悬浮层（OverlayService）启动时读同一份，两层就不会各显示各的。
 *
 * 只暴露一个 set(key, value)，且 key 有白名单，避免页面能任意写偏好。
 */
class AndroidHost(context: Context) {

    private val ctx = context.applicationContext
    private val sp = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @JavascriptInterface
    fun set(key: String, value: String) {
        if (key !in ALLOWED) return
        sp.edit().putString(key, value).apply()
    }

    @JavascriptInterface
    fun get(key: String): String = if (key in ALLOWED) sp.getString(key, "") ?: "" else ""

    /**
     * 麦克风被拒后「去设置」：直接落到本 App 的权限页。
     * 页面自己跳不了，Android 也不会把永久拒绝的用户再弹一次窗。
     */
    @JavascriptInterface
    fun settings() {
        val i = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${ctx.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(i)
    }

    companion object {
        const val PREFS = "followsound"
        const val STYLE = "style"
        const val THEME = "theme"
        const val HEIGHT = "height"
        private val ALLOWED = setOf(STYLE, THEME, HEIGHT)

        /** 悬浮层比光带本身留出的余量，光晕/光斑才有地方画（与 macOS 的 overlayHeadroom 同义） */
        const val HEADROOM_DP = 56

        fun height(ctx: Context): Int =
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(HEIGHT, null)?.toIntOrNull()?.coerceIn(80, 400) ?: 180

        fun style(ctx: Context): String =
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(STYLE, null) ?: "band"

        fun theme(ctx: Context): String =
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(THEME, null) ?: "ocean"
    }
}
