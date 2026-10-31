package app.followsound.android

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import android.webkit.ConsoleMessage
import android.webkit.PermissionRequest
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.core.content.ContextCompat
import androidx.webkit.WebViewAssetLoader

/**
 * 视觉核心（themes.js / visualizer.js / player.html）随 APK 放在 assets 里。
 * 用 WebViewAssetLoader 以 https://appassets.androidplatform.net/ 提供，
 * 是为了拿到「安全上下文」—— 否则 WebView 里的 getUserMedia 会被直接拒绝。
 */
object Web {
    const val BASE = "https://appassets.androidplatform.net/assets/"
    private const val TAG = "FollowSound"

    fun hasMic(ctx: Context): Boolean =
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED

    /**
     * @param onNeedMic 页面要麦克风、但 App 自己还没拿到系统权限时回调，
     *   由宿主去 requestPermissions，拿到后再让页面重试 getUserMedia。
     *
     *   两层权限是分开的：WebView 的 onPermissionRequest 只决定「这个网页」能不能用麦克风，
     *   App 级别的 RECORD_AUDIO 是另一层。缺这一层时就算 grant 了，流也是死的。
     */
    @SuppressLint("SetJavaScriptEnabled")
    fun setup(view: WebView, ctx: Context, onNeedMic: (() -> Unit)? = null) {        val loader = WebViewAssetLoader.Builder()
            .addPathHandler("/assets/", WebViewAssetLoader.AssetsPathHandler(ctx))
            .build()

        with(view.settings) {
            javaScriptEnabled = true
            domStorageEnabled = true
            mediaPlaybackRequiresUserGesture = false
            allowFileAccess = false
            allowContentAccess = false
        }
        view.setBackgroundColor(0x00000000)
        // 页面里选了特效/配色/高度，顺手存一份给悬浮层用
        view.addJavascriptInterface(AndroidHost(ctx), "FSHost")

        view.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(
                v: WebView?,
                request: WebResourceRequest?
            ): WebResourceResponse? {
                val url = request?.url ?: return null
                return loader.shouldInterceptRequest(url)
            }
        }
        view.webChromeClient = object : WebChromeClient() {
            override fun onPermissionRequest(request: PermissionRequest?) {
                if (request == null) return
                val audio = request.resources
                    .filter { it == PermissionRequest.RESOURCE_AUDIO_CAPTURE }
                    .toTypedArray()
                // 只放行音频，别的一概不给
                if (audio.isEmpty()) { request.deny(); return }
                if (!hasMic(ctx)) {
                    // 缺系统权限时 grant 只会得到一个打不开的流，页面随后静默变成演示动画
                    request.deny()
                    onNeedMic?.invoke()
                    return
                }
                request.grant(audio)
            }

            override fun onConsoleMessage(m: ConsoleMessage?): Boolean {
                m?.let { Log.d(TAG, "[web] ${it.message()}") }
                return true
            }
        }
    }
}
