package app.followsound.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import android.view.Gravity
import android.view.WindowManager
import android.webkit.WebView

/**
 * 悬浮光带：在别的 App 上面盖一条贴底、可穿透的覆盖层。
 * 与 macOS 版是同一个形态 —— 只是这里用 WebView 铺一条透明窗口。
 */
class OverlayService : Service() {

    companion object {
        const val ACTION_STOP = "app.followsound.android.STOP"
        var isRunning = false
        private const val CH_ID = "overlay"
        private const val NOTIF_ID = 42

        /** 正在显示的悬浮层（没开时为 null）。App 内换了特效/配色要立刻推到这一层。 */
        private var instance: OverlayService? = null

        fun refresh() {
            instance?.applyPrefs()
        }
    }

    private var web: WebView? = null
    private lateinit var wm: WindowManager

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        instance = this
        createChannel()
        startForeground(NOTIF_ID, buildNotification())
        showOverlay()
    }

    /**
     * 把 App 里最新选的特效/配色推给已经在显示的悬浮层。
     * 直接操作 window.fs 而不 reload：刷新一次会清空粒子、闪一下，
     * 用户只是换个配色，不该让画面断一帧。
     */
    private fun applyPrefs() {
        val v = web ?: return
        val s = AndroidHost.style(this)
        val t = AndroidHost.theme(this)
        v.post {
            v.evaluateJavascript(
                "window.fsSetStyle&&fsSetStyle(\"$s\");" +
                    "window.fsSetTheme&&fsSetTheme(\"$t\");",
                null
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    private fun createChannel() {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CH_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CH_ID, getString(R.string.overlay_channel), NotificationManager.IMPORTANCE_LOW)
            )
        }
    }

    private fun buildNotification(): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE
        )
        val stop = PendingIntent.getService(
            this, 1, Intent(this, OverlayService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE
        )
        return Notification.Builder(this, CH_ID)
            .setContentTitle(getString(R.string.app_name))
            .setContentText("悬浮光带已开启，随声音亮起")
            .setSmallIcon(Icon.createWithResource(this, android.R.drawable.ic_media_play))
            .setContentIntent(open)
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, android.R.drawable.ic_menu_close_clear_cancel),
                    "关闭悬浮窗", stop
                ).build()
            )
            .setOngoing(true)
            .build()
    }

    private fun showOverlay() {
        wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val view = WebView(this)
        Web.setup(view, this)

        // 与 App 内选的一致：特效/配色/高度都从同一份偏好里取，
        // 否则用户在 App 里挑好的样式，悬浮层还画着默认值。
        val bandDp = AndroidHost.height(this)
        val q = "style=${AndroidHost.style(this)}&theme=${AndroidHost.theme(this)}" +
                "&height=$bandDp&autostart=1"
        view.loadUrl("${Web.BASE}player.html?$q")

        // 窗口比光带高出一截，光晕才有地方画，否则满音量时顶部会被窗口裁掉
        val height = (resources.displayMetrics.density * (bandDp + AndroidHost.HEADROOM_DP)).toInt()
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else
            @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE

        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            height,
            type,
            // 不抢焦点、不接受触摸：光带只是"贴在上面"，不挡用户点别的东西
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.BOTTOM or Gravity.START
            // 让内容能画到导航栏下面，光带才是真的贴底
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
        wm.addView(view, lp)
        web = view
    }

    override fun onDestroy() {
        isRunning = false
        if (instance === this) instance = null
        web?.let {
            try { wm.removeView(it) } catch (e: Exception) { /* 已移除 */ }
            it.destroy()
        }
        web = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
