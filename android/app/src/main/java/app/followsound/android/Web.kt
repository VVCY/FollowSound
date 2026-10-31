package app.followsound.android

import android.annotation.SuppressLint
import android.content.Context
import android.webkit.PermissionRequest
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.WebViewAssetLoader

/**
 * 视觉核心（themes.js / visualizer.js / player.html）随 APK 放在 assets 里。
 * 用 WebViewAssetLoader 以 https://appassets.androidplatform.net/ 提供，
 * 是为了拿到「安全上下文」—— 否则 WebView 里的 getUserMedia 会被直接拒绝。
 */
object Web {
    const val BASE = "https://appassets.androidplatform.net/assets/"

    @SuppressLint("SetJavaScriptEnabled")
    fun setup(view: WebView, ctx: Context) {
        val loader = WebViewAssetLoader.Builder()
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
                // 只放行音频，别的一概不给
                request?.grant(arrayOf(android.webkit.PermissionRequest.RESOURCE_AUDIO_CAPTURE))
            }
        }
    }
}
