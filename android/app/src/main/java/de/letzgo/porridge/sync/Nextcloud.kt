package de.letzgo.porridge.sync

import de.letzgo.porridge.data.Net
import de.letzgo.porridge.data.Prefs
import de.letzgo.porridge.data.SecureStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Credentials
import okhttp3.FormBody
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.net.URLDecoder

/** iOS: `NextcloudAccount` — Server, Benutzer und ein eigenes App-Passwort aus dem Login im Browser (Login Flow v2). */
data class NextcloudAccount(val server: String, val loginName: String, val appPassword: String) {
    /** In den Einstellungen: „anna @ cloud.example.com“. */
    val label: String get() = "$loginName @ ${server.toHttpUrlOrNull()?.host ?: server}"

    fun save() {
        Prefs.set(SERVER_KEY, server)
        Prefs.set(LOGIN_KEY, loginName)
        SecureStore.set(appPassword, PASSWORD_KEY)
    }

    companion object {
        private const val SERVER_KEY = "nextcloudServer"
        private const val LOGIN_KEY = "nextcloudLogin"
        private const val PASSWORD_KEY = "nextcloudAppPassword"

        val saved: NextcloudAccount?
            get() {
                val server = Prefs.string(SERVER_KEY) ?: return null
                val login = Prefs.string(LOGIN_KEY) ?: return null
                val password = SecureStore.get(PASSWORD_KEY) ?: return null
                return NextcloudAccount(server, login, password)
            }

        fun remove() {
            Prefs.remove(SERVER_KEY)
            Prefs.remove(LOGIN_KEY)
            SecureStore.set(null, PASSWORD_KEY)
        }
    }
}

class NextcloudException(message: String, val code: Int = 0) : Exception(message)

/** Die Datei hat sich auf dem Server geändert, seit sie gelesen wurde (ein anderes Gerät war schneller). */
class SyncConflict : Exception("The sync file changed in the meantime.")

private fun httpError(code: Int) = NextcloudException(
    if (code == 401) "Nextcloud refused the login. Connect again." else "Nextcloud answered with error $code.", code,
)

/** iOS: `NextcloudLogin` — die App holt sich eine Login-Seite, der Nutzer bestätigt im Browser, die App holt das App-Passwort ab. */
object NextcloudLogin {
    data class Pending(val loginUrl: String, val pollUrl: String, val token: String)

    /** Nimmt „cloud.example.com“, „https://cloud.example.com/“ oder eine Adresse mit Pfad. */
    fun normalize(text: String): String? {
        var value = text.trim()
        if (value.isEmpty()) return null
        if ("://" !in value) value = "https://$value"
        value = value.trimEnd('/').removeSuffix("/index.php")
        return value.takeIf { it.toHttpUrlOrNull() != null }
    }

    suspend fun start(server: String, client: OkHttpClient = Net.client): Pending = withContext(Dispatchers.IO) {
        val request = Request.Builder().url("$server/index.php/login/v2").post(ByteArray(0).toRequestBody()).build()
        client.newCall(request).execute().use { response ->
            if (response.code != 200) throw NextcloudException("This does not look like a Nextcloud server.")
            val json = runCatching { Json.parseToJsonElement(response.body.string()).jsonObject }.getOrNull()
            val poll = json?.get("poll") as? JsonObject
            val token = poll?.get("token")?.jsonPrimitive?.content
            val endpoint = poll?.get("endpoint")?.jsonPrimitive?.content
            val login = json?.get("login")?.jsonPrimitive?.content
            if (token == null || endpoint == null || login == null) throw NextcloudException("This does not look like a Nextcloud server.")
            Pending(login, endpoint, token)
        }
    }

    /** Fragt alle zwei Sekunden nach, bis zu 20 Minuten (so lange gilt das Token). */
    suspend fun finish(pending: Pending, client: OkHttpClient = Net.client): NextcloudAccount {
        val deadline = System.currentTimeMillis() + 20 * 60 * 1000
        while (System.currentTimeMillis() < deadline) {
            val account = withContext(Dispatchers.IO) {
                runCatching {
                    val request = Request.Builder().url(pending.pollUrl).post(FormBody.Builder().add("token", pending.token).build()).build()
                    client.newCall(request).execute().use { response ->
                        if (response.code != 200) return@use null
                        val json = Json.parseToJsonElement(response.body.string()).jsonObject
                        val server = json["server"]?.jsonPrimitive?.content?.let(::normalize)
                        val login = json["loginName"]?.jsonPrimitive?.content
                        val password = json["appPassword"]?.jsonPrimitive?.content
                        if (server != null && login != null && password != null) NextcloudAccount(server, login, password) else null
                    }
                }.getOrNull()
            }
            if (account != null) return account
            delay(2000)
        }
        throw NextcloudException("The login in the browser was not finished in time.")
    }
}

/** iOS: `WebDAV` — die wenigen WebDAV-Aufrufe des Syncs, im Ordner „Porridge“ der Dateien des Nutzers. */
class WebDAV(private val account: NextcloudAccount, private val client: OkHttpClient = Net.client) {
    /** …/remote.php/dav/files/<user>/Porridge/ */
    val root: HttpUrl = account.server.toHttpUrlOrNull()!!.newBuilder()
        .addPathSegments("remote.php/dav/files").addPathSegment(account.loginName).addPathSegment("Porridge").addPathSegment("")
        .build()

    val recordings: HttpUrl = root.resolve("Recordings/")!!

    fun file(folder: HttpUrl, name: String): HttpUrl = folder.newBuilder().removePathSegment(folder.pathSize - 1).addPathSegment(name).build()

    private fun request(url: HttpUrl) = Request.Builder().url(url).header("Authorization", Credentials.basic(account.loginName, account.appPassword))

    data class Remote(val data: ByteArray, val etag: String?)

    /**
     * Die Datei und ihr ETag; null, wenn es sie noch nicht gibt.
     *
     * Das ETag kommt per PROPFIND, vor dem Herunterladen: Proxys wie Cloudflare ändern das ETag einer komprimierten
     * GET-Antwort (`W/"…-gzip"`), und dazu passt If-Match nie. Zuerst gelesen, endet eine Änderung dazwischen weiterhin
     * in einem Konflikt, nie im Überschreiben.
     */
    suspend fun get(url: HttpUrl): Remote? = withContext(Dispatchers.IO) {
        val etag = etag(url) ?: return@withContext null
        client.newCall(request(url).get().build()).execute().use { response ->
            when (response.code) {
                200 -> Remote(response.body.bytes(), etag)
                404 -> null
                else -> throw httpError(response.code)
            }
        }
    }

    /** Das ETag, wie Nextcloud selbst es meldet; null, wenn es die Datei nicht gibt. */
    private fun etag(url: HttpUrl): String? {
        val body = """<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>"""
        return client.newCall(request(url).header("Depth", "0").method("PROPFIND", body.toRequestBody()).build()).execute().use { response ->
            when (response.code) {
                207 -> etag(response.body.string())
                404 -> null
                else -> throw httpError(response.code)
            }
        }
    }

    /** Schreibt nur, wenn die Datei noch die gelesene ist ([etag]) oder es sie noch nicht gibt ([etag] null). */
    suspend fun put(data: ByteArray, url: HttpUrl, ifMatch: String?) = withContext(Dispatchers.IO) {
        val builder = request(url).put(data.toRequestBody())
        if (ifMatch != null) builder.header("If-Match", ifMatch) else builder.header("If-None-Match", "*")
        client.newCall(builder.build()).execute().use { response ->
            when {
                response.isSuccessful -> Unit
                response.code == 412 -> throw SyncConflict()
                else -> throw httpError(response.code)
            }
        }
    }

    suspend fun upload(file: File, url: HttpUrl) = withContext(Dispatchers.IO) {
        client.newCall(request(url).put(file.asRequestBody()).build()).execute().use { response ->
            if (!response.isSuccessful) throw httpError(response.code)
        }
    }

    suspend fun download(url: HttpUrl, target: File) = withContext(Dispatchers.IO) {
        client.newCall(request(url).get().build()).execute().use { response ->
            if (response.code != 200) throw httpError(response.code)
            val temp = File(target.parentFile, ".${target.name}.part")
            temp.outputStream().use { response.body.byteStream().copyTo(it) }
            temp.renameTo(target)
        }
    }

    /** Legt den Ordner an; ein vorhandener ist auch recht. */
    suspend fun makeFolder(url: HttpUrl) = withContext(Dispatchers.IO) {
        client.newCall(request(url).method("MKCOL", null).build()).execute().use { response ->
            if (response.code != 201 && response.code != 405) throw httpError(response.code)
        }
    }

    /** Namen der Dateien direkt im Ordner. */
    suspend fun list(url: HttpUrl): Set<String> = withContext(Dispatchers.IO) {
        val body = """<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>"""
        client.newCall(request(url).header("Depth", "1").method("PROPFIND", body.toRequestBody()).build()).execute().use { response ->
            when (response.code) {
                404 -> emptySet()
                207 -> hrefs(response.body.string())
                    .map { URLDecoder.decode(it.replace("+", "%2B"), "UTF-8") }
                    // Der Ordner selbst kommt mit Schrägstrich am Ende.
                    .filter { !it.endsWith("/") }
                    .map { it.substringAfterLast('/') }
                    .toSet()
                else -> throw httpError(response.code)
            }
        }
    }

    companion object {
        private val HREF = Regex("<(?:[A-Za-z0-9]+:)?href>([^<]*)</(?:[A-Za-z0-9]+:)?href>")

        fun hrefs(xml: String): List<String> = HREF.findAll(xml).map { it.groupValues[1].trim() }.toList()

        private val ETAG = Regex("<(?:[A-Za-z0-9]+:)?getetag>([^<]*)</(?:[A-Za-z0-9]+:)?getetag>")

        /** Das `<d:getetag>` einer PROPFIND-Antwort, mit aufgelösten Entities. */
        fun etag(xml: String): String? = ETAG.find(xml)?.groupValues?.get(1)
            ?.replace("&quot;", "\"")?.replace("&amp;", "&")?.trim()?.takeIf { it.isNotEmpty() }
    }
}
