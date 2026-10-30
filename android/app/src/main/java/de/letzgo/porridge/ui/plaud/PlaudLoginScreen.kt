package de.letzgo.porridge.ui.plaud

import android.annotation.SuppressLint
import android.os.Message
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import de.letzgo.porridge.plaud.PlaudAPI
import kotlinx.coroutines.delay

private const val PLAUD_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

/**
 * iOS: `PlaudLoginView` — zeigt web.plaud.ai und wartet auf das Anmelde-Cookie (`pld_ut`, dazu `pld_urt`). Von der
 * Seite selbst wird nichts gelesen. Google- und Apple-Anmeldung öffnen ein Popup-Fenster; ohne
 * `setSupportMultipleWindows` + `onCreateWindow` täten diese Knöpfe nichts.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun PlaudLoginScreen(onToken: (String, String?) -> Unit, onCancel: () -> Unit) {
    BackHandler { onCancel() }
    LaunchedEffect(Unit) {
        val cookies = CookieManager.getInstance()
        while (true) {
            // CookieManager liefert auch HttpOnly-Cookies (anders als document.cookie).
            val all = listOfNotNull(cookies.getCookie("https://web.plaud.ai"), cookies.getCookie("https://api.plaud.ai")).joinToString("; ")
            val values = all.split(";").map { it.trim() }.filter { '=' in it }.associate { it.substringBefore('=') to it.substringAfter('=') }
            val token = values["pld_ut"]?.takeIf { it.isNotEmpty() && (PlaudAPI.expiry(it)?.let { e -> e - System.currentTimeMillis() > 60_000 } ?: true) }
            if (token != null) { onToken(token, values["pld_urt"]?.ifEmpty { null }); return@LaunchedEffect }
            delay(1000)
        }
    }
    Column(Modifier.fillMaxSize().statusBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onCancel) { Text("Cancel") }
            Text("Plaud Sign-In", style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold))
        }
        AndroidView(modifier = Modifier.fillMaxSize(), factory = { context ->
            val container = FrameLayout(context)
            CookieManager.getInstance().setAcceptCookie(true)
            fun configure(web: WebView) {
                web.settings.javaScriptEnabled = true
                web.settings.domStorageEnabled = true
                web.settings.userAgentString = PLAUD_UA
                web.settings.setSupportMultipleWindows(true)
                web.settings.javaScriptCanOpenWindowsAutomatically = true
                CookieManager.getInstance().setAcceptThirdPartyCookies(web, true)
                web.webViewClient = WebViewClient()
            }
            val main = WebView(context)
            configure(main)
            main.webChromeClient = object : WebChromeClient() {
                override fun onCreateWindow(view: WebView, isDialog: Boolean, isUserGesture: Boolean, resultMsg: Message): Boolean {
                    // Das Popup liegt über der Seite und verschwindet, wenn die Seite es schließt.
                    val popup = WebView(context)
                    configure(popup)
                    popup.webChromeClient = object : WebChromeClient() {
                        override fun onCloseWindow(window: WebView) { container.removeView(window); window.destroy() }
                    }
                    container.addView(popup, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
                    (resultMsg.obj as WebView.WebViewTransport).webView = popup
                    resultMsg.sendToTarget()
                    return true
                }
            }
            container.addView(main, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            main.loadUrl("https://web.plaud.ai/")
            container
        })
    }
}
