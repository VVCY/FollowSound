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
    }

    private var web: WebView? = null
    private lateinit var wm: WindowManager

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        createChannel()
        startForeground(NOTIF_ID, buildNotification())
        showOverlay()
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
        view.loadUrl("${Web.BASE}player.html?autostart=1")

        val height = (resources.displayMetrics.density * 230).toInt()
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
        web?.let {
            try { wm.removeView(it) } catch (e: Exception) { /* 已移除 */ }
            it.destroy()
        }
        web = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
