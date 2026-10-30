package de.letzgo.porridge.sync

import kotlinx.coroutines.test.runTest
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

class WebDAVTest {
    private val server = MockWebServer()
    private val client = OkHttpClient()

    @Before fun start() = server.start()
    @After fun stop() = server.close()

    private fun dav() = WebDAV(NextcloudAccount(server.url("/").toString().trimEnd('/'), "anna", "secret"), client)

    @Test fun pathsAndConditionalWrites() = runTest {
        val dav = dav()
        assertEquals("/remote.php/dav/files/anna/Porridge/", dav.root.encodedPath)
        assertEquals("/remote.php/dav/files/anna/Porridge/Recordings/x.m4a", dav.file(dav.recordings, "x.m4a").encodedPath)

        server.enqueue(MockResponse.Builder().code(404).build())
        assertNull(dav.get(dav.file(dav.root, "porridge-sync.json")))

        server.enqueue(MockResponse.Builder().code(201).build())
        dav.put("{}".toByteArray(), dav.file(dav.root, "porridge-sync.json"), null)
        server.takeRequest()
        val created = server.takeRequest()
        assertEquals("*", created.headers["If-None-Match"])
        assertEquals("Basic YW5uYTpzZWNyZXQ=", created.headers["Authorization"])

        server.enqueue(MockResponse.Builder().code(412).build())
        val conflict = runCatching { dav.put("{}".toByteArray(), dav.file(dav.root, "porridge-sync.json"), "\"abc\"") }.exceptionOrNull()
        assertEquals(SyncConflict::class, conflict!!::class)
        assertEquals("\"abc\"", server.takeRequest().headers["If-Match"])
    }

    @Test fun listsFilesOfAFolder() = runTest {
        val xml = """
            <?xml version="1.0"?>
            <d:multistatus xmlns:d="DAV:">
              <d:response><d:href>/remote.php/dav/files/anna/Porridge/Recordings/</d:href></d:response>
              <d:response><d:href>/remote.php/dav/files/anna/Porridge/Recordings/A%20B.m4a</d:href></d:response>
              <d:response><d:href>/remote.php/dav/files/anna/Porridge/Recordings/C.m4a</d:href></d:response>
            </d:multistatus>
        """.trimIndent()
        server.enqueue(MockResponse.Builder().code(207).body(xml).build())
        assertEquals(setOf("A B.m4a", "C.m4a"), dav().list(dav().recordings))
    }

    @Test fun loginFlow() = runTest {
        val base = server.url("/").toString().trimEnd('/')
        server.enqueue(MockResponse.Builder().code(200).body("""{"poll":{"token":"t","endpoint":"$base/poll"},"login":"$base/login"}""").build())
        val pending = NextcloudLogin.start(base, client)
        assertEquals("$base/login", pending.loginUrl)
        server.enqueue(MockResponse.Builder().code(200).body("""{"server":"$base","loginName":"anna","appPassword":"pw"}""").build())
        assertEquals(NextcloudAccount(base, "anna", "pw"), NextcloudLogin.finish(pending, client))
    }

    @Test fun normalizesServerAddresses() {
        assertEquals("https://cloud.example.com", NextcloudLogin.normalize(" cloud.example.com/ "))
        assertEquals("https://example.com/nc", NextcloudLogin.normalize("https://example.com/nc/index.php"))
        assertNull(NextcloudLogin.normalize(""))
    }
}
