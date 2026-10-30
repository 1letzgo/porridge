package de.letzgo.porridge.data

import de.letzgo.porridge.BuildConfig
import okhttp3.OkHttpClient
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
                chain.proceed(withAgent)
            }
            .build()
    }
}
