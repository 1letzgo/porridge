// Ported from roopen219/plaude-archiver (MIT License, https://github.com/roopen219/plaude-archiver).
package de.letzgo.porridge.plaud

import de.letzgo.porridge.data.Net
import de.letzgo.porridge.data.PorridgeJson
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.Base64

sealed class PlaudAPIException(message: String) : Exception(message) {
    class Message(message: String) : PlaudAPIException(message)
    /** Plaud nimmt den Token nicht mehr (HTTP 401/403): die Anmeldung ist abgelaufen. */
    class Unauthorized : PlaudAPIException("Your Plaud sign-in has expired. Please sign in again.")
}

/**
 * iOS: `PlaudAPI` — die Geräte-Endpunkte mit dem UT-Token. Wie die App: `X-Encrypt-Response: 1`, Fernet-verschlüsselte
 * Antworten, der Regions-Redirect `-302`, Erneuerung über `pld_urt`.
 */
data class PlaudAPI(var userToken: String, var host: String) {
    private fun decode(headers: okhttp3.Headers, body: String, path: String): JsonObject {
        val text = if (headers["x-encrypt-response"] == "1") String(PlaudCrypto.fernetDecrypt(body)) else body
        return runCatching { PorridgeJson.parseToJsonElement(text).jsonObject }.getOrNull() ?: throw PlaudAPIException.Message("bad JSON from $path")
    }

    private data class Reply(val json: JsonObject, val host: String, val headers: okhttp3.Headers, val url: String)

    private suspend fun call(method: String, path: String, body: JsonObject?, extra: Map<String, String> = emptyMap()): Reply = withContext(Dispatchers.IO) {
        var current = host
        repeat(2) {
            val builder = Request.Builder().url(current + path)
                .header("Authorization", "Bearer $userToken").header("app-platform", "web").header("edit-from", "web").header("X-Encrypt-Response", "1")
            extra.forEach { (k, v) -> builder.header(k, v) }
            builder.method(method, body?.toString()?.toRequestBody("application/json".toMediaType()))
            Net.client.newCall(builder.build()).execute().use { response ->
                if (response.code == 401 || response.code == 403) throw PlaudAPIException.Unauthorized()
                val json = decode(response.headers, response.body.string(), path)
                val status = json.int("status") ?: json.int("code")
                val api = (json["data"] as? JsonObject)?.get("domains")?.let { it as? JsonObject }?.get("api")?.jsonPrimitive?.contentOrNull
                if (status == -302 && api != null) { current = api; return@repeat }
                if (status == 401 || status == 403) throw PlaudAPIException.Unauthorized()
                return@withContext Reply(json, current, response.headers, response.request.url.toString())
            }
        }
        throw PlaudAPIException.Message("region redirect loop")
    }

    private fun JsonObject.int(key: String) = (this[key] as? JsonPrimitive)?.intOrNull

    /** POST /device-app/device/sn-sign → Base64-Signatur für die Seriennummer. */
    suspend fun snSign(serial: String): Pair<String, String> {
        val reply = call("POST", "/device-app/device/sn-sign", buildJsonObject { put("sns", buildJsonArray { add(JsonPrimitive(serial)) }) })
        val sig = (reply.json["data"] as? JsonObject)?.get("signature")?.let { it as? JsonObject }?.get(serial)?.jsonPrimitive?.contentOrNull
        if (reply.json.int("status") != 0 || sig == null) throw PlaudAPIException.Message("sn-sign: ${reply.json["msg"] ?: reply.json}")
        return sig to reply.host
    }

    /** POST /device-app/e2ee/gen_key → (privates PEM, öffentliches PEM, Host). */
    suspend fun genKey(): Triple<String, String, String> {
        val reply = call("POST", "/device-app/e2ee/gen_key", JsonObject(emptyMap()))
        val data = reply.json["data"] as? JsonObject
        val priv = data?.get("private_key_base64")?.jsonPrimitive?.contentOrNull?.let { String(Base64.getDecoder().decode(it)) }
        val pub = data?.get("public_key_base64")?.jsonPrimitive?.contentOrNull?.let { String(Base64.getDecoder().decode(it)) }
        if (reply.json.int("status") != 0 || priv == null || pub == null) throw PlaudAPIException.Message("gen_key: ${reply.json["msg"] ?: reply.json}")
        return Triple(priv, pub, reply.host)
    }

    data class RenewedTokens(val userToken: String, val refreshToken: String?, val host: String)

    /** POST /auth/refresh-user-token mit den Cookies pld_ut + pld_urt → neue Cookies in Set-Cookie. */
    suspend fun refreshUserToken(refreshToken: String): RenewedTokens {
        val reply = call("POST", "/auth/refresh-user-token", JsonObject(emptyMap()), mapOf("Cookie" to "pld_ut=$userToken; pld_urt=$refreshToken", "Origin" to "https://web.plaud.ai"))
        if (reply.json.int("status") != 0) throw PlaudAPIException.Message("refresh-user-token: ${reply.json["msg"] ?: reply.json}")
        fun cookie(name: String) = reply.headers.values("Set-Cookie").mapNotNull { line ->
            val pair = line.substringBefore(';')
            if (pair.substringBefore('=').trim() == name) pair.substringAfter('=').trim().trim('"').ifEmpty { null } else null
        }.firstOrNull()
        val newUT = cookie("pld_ut") ?: (reply.json["data"] as? JsonObject)?.get("access_token")?.jsonPrimitive?.contentOrNull
            ?: throw PlaudAPIException.Message("refresh-user-token: no new token in the reply")
        return RenewedTokens(newUT, cookie("pld_urt"), reply.host)
    }

    companion object {
        /** Region aus dem JWT-Claim `region`, z. B. aws:ap-southeast-1 → api-apse1.plaud.ai. */
        fun hostFromToken(token: String): String {
            val region = claims(token)?.get("region")?.jsonPrimitive?.contentOrNull ?: return "https://api.plaud.ai"
            val map = mapOf("aws:ap-southeast-1" to "apse1", "aws:us-east-1" to "use1", "aws:eu-central-1" to "euc1", "aws:us-west-2" to "usw2")
            return map[region]?.let { "https://api-$it.plaud.ai" } ?: "https://api.plaud.ai"
        }

        /** Der Claim `sub` ist die user_id, zugleich das BLE-Bind-Token. */
        fun subject(token: String): String? = claims(token)?.get("sub")?.jsonPrimitive?.contentOrNull

        /** Ablauf aus dem JWT-Claim `exp` (Millisekunden), null wenn kein JWT. */
        fun expiry(token: String): Long? = (claims(token)?.get("exp") as? JsonPrimitive)?.contentOrNull?.toDoubleOrNull()?.let { (it * 1000).toLong() }

        private fun claims(token: String): JsonObject? {
            val parts = token.split(".")
            if (parts.size < 2) return null
            val payload = PlaudCrypto.base64urlDecode(parts[1]) ?: return null
            return runCatching { PorridgeJson.parseToJsonElement(String(payload)).jsonObject }.getOrNull()
        }
    }
}
