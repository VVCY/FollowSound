package app.followsound.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.webkit.WebView
import android.widget.Button
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat

class MainActivity : AppCompatActivity() {

    private lateinit var web: WebView
    private lateinit var overlayBtn: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        web = findViewById(R.id.web)
        overlayBtn = findViewById(R.id.overlayBtn)
        Web.setup(web, this)
        // autostart=1：进 App 就直接接麦克风，不让用户先点一层「允许麦克风」的遮罩
        val q = "chrome=1&autostart=1" +
                "&style=${AndroidHost.style(this)}" +
                "&theme=${AndroidHost.theme(this)}" +
                "&height=${AndroidHost.height(this)}"
        web.loadUrl("${Web.BASE}player.html?$q")

        findViewById<TextView>(R.id.ver).text = "v${BuildConfig.VERSION_NAME}"
        findViewById<View>(R.id.updateBtn).setOnClickListener { Updater.check(this, manual = true) }

        overlayBtn.setOnClickListener { toggleOverlay() }

        ensureMic()
        Updater.check(this, manual = false)
    }

    override fun onResume() {
        super.onResume()
        overlayBtn.text = getString(
            if (OverlayService.isRunning) R.string.overlay_off else R.string.overlay_on
        )
    }

    private fun ensureMic() {
        val ask = mutableListOf<String>()
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            ask += Manifest.permission.RECORD_AUDIO
        }
        // Android 13+ 不申请的话，前台服务的通知会被静默丢掉，用户找不到「关闭悬浮窗」的入口
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            ask += Manifest.permission.POST_NOTIFICATIONS
        }
        if (ask.isNotEmpty()) requestPermissions(ask.toTypedArray(), 1001)
    }

    private fun toggleOverlay() {
        if (OverlayService.isRunning) {
            stopService(Intent(this, OverlayService::class.java))
            OverlayService.isRunning = false
            overlayBtn.setText(R.string.overlay_on)
            return
        }
        if (!Settings.canDrawOverlays(this)) {
            // 悬浮层要「显示在其他应用上层」权限，只能跳到系统设置让用户手动开
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:$packageName")
                )
            )
            return
        }
        ensureMic()
        startForegroundService(Intent(this, OverlayService::class.java))
        overlayBtn.setText(R.string.overlay_off)
    }
}
