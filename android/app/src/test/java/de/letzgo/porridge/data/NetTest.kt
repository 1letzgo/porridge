package de.letzgo.porridge.data

import de.letzgo.porridge.plaud.PlaudAPI
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NetTest {
    @Test fun plainHttpIsOnlyForTheOwnNetwork() {
        for (host in listOf("localhost", "nas", "ollama.local", "box.lan", "192.168.1.20", "10.0.0.5", "172.20.1.1", "100.100.4.2", "127.0.0.1", "[::1]", "fd12:3456::1", "fe80::1")) {
            assertTrue(host, Net.isLocalHost(host))
        }
        for (host in listOf("example.com", "8.8.8.8", "172.32.0.1", "192.169.1.1", "100.128.0.1", "2001:db8::1", "api.openai.com")) {
            assertFalse(host, Net.isLocalHost(host))
        }
    }

    @Test fun thePlaudTokenOnlyGoesToPlaud() {
        assertTrue(PlaudAPI.isPlaudHost("https://api.plaud.ai"))
        assertTrue(PlaudAPI.isPlaudHost("https://api-euc1.plaud.ai"))
        assertFalse(PlaudAPI.isPlaudHost("http://api.plaud.ai"))
        assertFalse(PlaudAPI.isPlaudHost("https://plaud.ai.example.com"))
        assertFalse(PlaudAPI.isPlaudHost("https://evilplaud.ai"))
    }
}
