package de.letzgo.porridge.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AppUpdateTest {
    @Test fun comparesNumberByNumber() {
        assertTrue(AppUpdate.isNewer("0.10.1", "0.9.3"))
        assertTrue(AppUpdate.isNewer("1.0", "0.99.99"))
        assertEquals(0, AppUpdate.compare("1.2", "1.2.0"))
        assertTrue(!AppUpdate.isNewer("0.3.0", "0.3.0"))
    }

    private val json = """
        [
          {"tag_name":"mac-v0.9.0","name":"Porridge Mac 0.9.0","draft":false,"prerelease":false,"html_url":"m",
           "assets":[{"name":"Porridge-mac-0.9.0.zip","browser_download_url":"z"}]},
          {"tag_name":"android-v0.4.0","name":"Porridge Android 0.4.0","body":" notes ","draft":false,"prerelease":false,"html_url":"p4",
           "assets":[{"name":"Porridge-android-0.4.0.apk","browser_download_url":"a4","digest":"sha256:abc"}]},
          {"tag_name":"android-v0.10.0","name":"draft","draft":true,"prerelease":false,"html_url":"p10",
           "assets":[{"name":"Porridge-android-0.10.0.apk","browser_download_url":"a10"}]},
          {"tag_name":"android-v0.5.0","name":"no apk","draft":false,"prerelease":false,"html_url":"p5","assets":[]},
          {"tag_name":"android-v0.3.1","name":"Porridge Android 0.3.1","draft":false,"prerelease":false,"html_url":"p31",
           "assets":[{"name":"Porridge-android-0.3.1.apk","browser_download_url":"a31"}],"extra":"ignored"}
        ]
    """.trimIndent()

    @Test fun picksNewestAndroidReleaseWithApk() {
        val release = AppUpdate.newest(AppUpdate.parse(json), installed = "0.3.0")!!
        assertEquals("0.4.0", release.version)
        assertEquals("android-v0.4.0", release.tag)
        assertEquals("a4", release.apkUrl)
        assertEquals("abc", release.sha256)
        assertEquals("notes", release.notes)
    }

    @Test fun nothingWhenUpToDate() {
        assertNull(AppUpdate.newest(AppUpdate.parse(json), installed = "0.4.0"))
    }
}
