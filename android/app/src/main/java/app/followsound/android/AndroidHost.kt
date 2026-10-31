package app.followsound.android

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.util.Log
import android.webkit.JavascriptInterface

/**
 * 把 WebView 里选的特效/配色/高度落进 SharedPreferences，
 * 悬浮层（OverlayService）启动时读同一份，两层就不会各显示各的。
 *
 * 只暴露一个 set(key, value)，且 key 有白名单，避免页面能任意写偏好。
 */
class AndroidHost(context: Context) {

    private val ctx = context.applicationContext
    // 走 prefs() 而不是直接 getSharedPreferences：这里顺手把过期的出厂默认值迁移掉
    private val sp = prefs(ctx)

    @JavascriptInterface
    fun set(key: String, value: String) {
        if (key !in ALLOWED) return
        sp.edit().putString(key, value).apply()
        // 悬浮层是另一个 WebView，页面里的 localStorage 管不到它。
        // 用户在主界面换了特效/配色，不通知那一层，屏幕上就还是老样子。
        if (key == STYLE || key == THEME) OverlayService.refresh()
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

    /**
     * 排障探针：页面把实时电平/采集状态报上来。
     *
     * WebView 里没有控制台，而 onConsoleMessage 在部分 ROM 上收不到；
     * 出问题（「授权了但不动」）时，这里的一行 logcat 是唯一能定位的数据。
     * 只在 debug 版调用，正式版页面不会调。
     */
    @JavascriptInterface
    fun probe(level: String, state: String, frames: String) {
        // 正式版不刷 logcat：页面每 1.25 秒报一次，只有排障时才值这几行
        if (!BuildConfig.DEBUG) return
        Log.i(TAG, "probe level=$level state=$state frames=$frames")
    }

    companion object {
        private const val TAG = "FollowSound"
        const val PREFS = "followsound"
        const val STYLE = "style"
        const val THEME = "theme"
        const val HEIGHT = "height"
        private const val REV = "prefsRev"
        private val ALLOWED = setOf(STYLE, THEME, HEIGHT)

        /**
         * 出厂默认值的版本号。改了默认特效/配色就把它 +1：
         * 老用户 SharedPreferences 里存的旧选择会作废一次，
         * 否则新默认永远被旧值压着，看起来就是「改了不生效」。
         */
        private const val PREFS_REV = 2

        /** 悬浮层比光带本身留出的余量，光晕/光斑才有地方画（与 macOS 的 overlayHeadroom 同义） */
        const val HEADROOM_DP = 56

        private fun prefs(ctx: Context): android.content.SharedPreferences {
            val sp = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            if (sp.getString(REV, null) != PREFS_REV.toString()) {
                sp.edit()
                    .remove(STYLE)
                    .remove(THEME)
                    .putString(REV, PREFS_REV.toString())
                    .apply()
            }
            return sp
        }

        fun height(ctx: Context): Int =
            prefs(ctx).getString(HEIGHT, null)?.toIntOrNull()?.coerceIn(80, 400) ?: 180

        fun style(ctx: Context): String = prefs(ctx).getString(STYLE, null) ?: "rain"

        fun theme(ctx: Context): String = prefs(ctx).getString(THEME, null) ?: "crimson"
    }
}
