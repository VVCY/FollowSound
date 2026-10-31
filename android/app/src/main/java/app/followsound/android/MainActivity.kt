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
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity

class MainActivity : AppCompatActivity() {

    private lateinit var web: WebView
    private lateinit var overlayBtn: Button

    private var pageLoaded = false
    /** 用户点了悬浮窗、但麦克风还没授权：授权回来后自动把它开起来 */
    private var pendingOverlay = false
    /** 用户勾了「不再询问」/ 连续拒绝：再 requestPermissions 也不会弹窗，只能去系统设置 */
    private var micBlocked = false
    private var asking = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        web = findViewById(R.id.web)
        overlayBtn = findViewById(R.id.overlayBtn)
        // 页面自己要麦克风、但 App 还没有系统权限时，回头看 requestMic()
        Web.setup(web, this) { requestMic() }

        // 没授权就先加载页面（autostart=0，页面只画底噪不假装接上了），
        // 授权回来再让页面接 —— 否则页面在权限弹窗之前就 getUserMedia 失败，且不会重试。
        loadPlayer()

        findViewById<TextView>(R.id.ver).text = "v${BuildConfig.VERSION_NAME}"
        findViewById<View>(R.id.updateBtn).setOnClickListener { Updater.check(this, manual = true) }
        overlayBtn.setOnClickListener { toggleOverlay() }

        requestMic()
        Updater.check(this, manual = false)
    }

    override fun onResume() {
        super.onResume()
        overlayBtn.text = getString(
            if (OverlayService.isRunning) R.string.overlay_off else R.string.overlay_on
        )
        // 用户可能刚在系统设置里把麦克风打开：页面还在，喊它重试一次
        if (pageLoaded && Web.hasMic(this)) {
            micBlocked = false
            jsRetryMic()
        }
    }

    private fun loadPlayer() {
        if (pageLoaded) return
        pageLoaded = true
        val auto = if (Web.hasMic(this)) 1 else 0
        val q = "chrome=1&autostart=$auto" +
                "&style=${AndroidHost.style(this)}" +
                "&theme=${AndroidHost.theme(this)}" +
                "&height=${AndroidHost.height(this)}"
        web.loadUrl("${Web.BASE}player.html?$q")
    }

    private fun jsRetryMic() {
        web.evaluateJavascript("window.fsEnsureMic&&window.fsEnsureMic(1)", null)
    }

    private fun requestMic() {
        if (Web.hasMic(this)) {
            jsRetryMic()
            return
        }
        if (asking) return
        if (micBlocked) {
            // 再申请也弹不出窗口，直接把话说清楚，页面那条「去设置」才是出口
            Toast.makeText(this, R.string.mic_denied, Toast.LENGTH_LONG).show()
            return
        }
        val ask = mutableListOf(Manifest.permission.RECORD_AUDIO)
        // Android 13+ 不申请的话，前台服务的通知会被静默丢掉，用户找不到「关闭悬浮窗」的入口
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            ask += Manifest.permission.POST_NOTIFICATIONS
        }
        asking = true
        requestPermissions(ask.toTypedArray(), 1001)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 1001) return
        asking = false

        if (Web.hasMic(this)) {
            micBlocked = false
            jsRetryMic()
            if (pendingOverlay) {
                pendingOverlay = false
                startOverlay()
            }
            return
        }

        // 拒了：直接让页面切到「麦克风没接上」的状态条。
        // 这里不去再要一次 getUserMedia —— 那会绕回 onPermissionRequest，把权限弹窗顶第二次。
        micBlocked = !shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)
        web.evaluateJavascript("window.fsMicError&&window.fsMicError('NotAllowedError')", null)
        Toast.makeText(this, R.string.mic_denied, Toast.LENGTH_LONG).show()
        if (micBlocked) {
            // 永久拒绝后「再点一次」不会再弹窗，只能把用户送到系统设置
            startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$packageName")
                )
            )
        }
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
        if (!Web.hasMic(this)) {
            // 悬浮层自己也要麦克风，先拿到权限再开，别开一条不会亮的空带子
            pendingOverlay = true
            requestMic()
            return
        }
        startOverlay()
    }

    private fun startOverlay() {
        startForegroundService(Intent(this, OverlayService::class.java))
        overlayBtn.setText(R.string.overlay_off)
    }
}
