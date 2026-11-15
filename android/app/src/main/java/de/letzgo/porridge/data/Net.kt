package de.letzgo.porridge.data

import de.letzgo.porridge.BuildConfig
import okhttp3.OkHttpClient
import java.io.IOException
import java.util.concurrent.TimeUnit

/** Ein gemeinsamer HTTP-Client (iOS: `URLSession.shared`). */
object Net {
    val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(120, TimeUnit.SECONDS)
            .addInterceptor { chain ->
                val request = chain.request()
                val withAgent = if (request.header("User-Agent") == null) {
                    request.newBuilder().header("User-Agent", "Porridge-android/${BuildConfig.VERSION_NAME}").build()
                } else request
                // Klartext nur ins eigene Netz (siehe res/xml/network_security_config.xml).
                if (!withAgent.isHttps && !isLocalHost(withAgent.url.host)) {
                    throw IOException("Porridge only connects without encryption (http://) to servers in your own network. Use https:// for ${withAgent.url.host}.")
                }
                chain.proceed(withAgent)
            }
            .build()
    }

    /**
     * Ein Rechner im eigenen Netz: dieser hier, ein Name ohne Punkt oder auf .local/.lan/.home.arpa/.internal, oder eine
     * private Adresse (auch 100.64/10, wie Tailscale sie vergibt). iOS: was `NSAllowsLocalNetworking` durchlässt.
     */
    fun isLocalHost(host: String): Boolean {
        val name = host.lowercase().trim('[', ']')
        if (name == "localhost" || name.endsWith(".local") || name.endsWith(".lan") || name.endsWith(".home.arpa") || name.endsWith(".internal")) return true
        if (':' in name) return name == "::1" || name.startsWith("fe8") || name.startsWith("fe9") || name.startsWith("fea") || name.startsWith("feb") || name.startsWith("fc") || name.startsWith("fd")
        val parts = name.split(".")
        val numbers = parts.map { it.toIntOrNull() }
        if (parts.size == 4 && numbers.all { it != null && it in 0..255 }) {
            val (a, b) = numbers[0]!! to numbers[1]!!
            return a == 10 || a == 127 || (a == 172 && b in 16..31) || (a == 192 && b == 168) || (a == 169 && b == 254) || (a == 100 && b in 64..127)
        }
        return '.' !in name
    }
}
