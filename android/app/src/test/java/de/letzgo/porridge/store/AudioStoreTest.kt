package de.letzgo.porridge.store

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class AudioStoreTest {
    @get:Rule val folder = TemporaryFolder()

    @Test fun namesFromTheSyncFileStayInsideTheStore() {
        val outside = folder.newFile("porridge.db")
        AudioStore.initForTests(File(folder.root, "Recordings"))
        for (name in listOf("../porridge.db", "..", "sub/a.m4a", ".hidden", "")) {
            assertFalse(name, AudioStore.isPlainName(name))
            assertFalse(name, AudioStore.exists(name))
            AudioStore.delete(name)
        }
        assertTrue(outside.exists())
    }

    @Test fun plainNamesWork() {
        AudioStore.initForTests(File(folder.root, "Recordings"))
        val name = AudioStore.newFileName()
        assertTrue(AudioStore.isPlainName(name))
        AudioStore.file(name).writeText("x")
        assertTrue(AudioStore.exists(name))
        AudioStore.delete(name)
        assertFalse(AudioStore.exists(name))
    }
}
