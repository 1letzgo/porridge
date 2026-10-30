package de.letzgo.porridge.plaud

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.KeyPairGenerator
import java.util.Base64
import javax.crypto.Cipher

class PlaudCryptoTest {
    private fun hex(s: String) = s.replace(" ", "").replace("\n", "").chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test fun chacha20Rfc8439Vector() {
        // RFC 8439, Abschnitt 2.4.2.
        val key = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        val nonce = hex("000000000000004a00000000")
        val plain = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".toByteArray()
        val ct = PlaudCrypto.chacha20(plain, key, nonce, 1)
        assertArrayEquals(hex("6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0bf91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d807ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab77937365af90bbf74a35be6b40b8eedf2785e42874d"), ct)
        assertArrayEquals(plain, PlaudCrypto.chacha20(ct, key, nonce, 1))
    }

    @Test fun aeadRfc8439Vector() {
        // RFC 8439, Abschnitt 2.8.2.
        val key = hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
        val nonce = hex("070000004041424344454647")
        val aad = hex("50515253c0c1c2c3c4c5c6c7")
        val plain = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".toByteArray()
        val sealed = PlaudCrypto.aeadSeal(plain, key, nonce, aad)
        assertArrayEquals(hex("1ae10b594f09e26a7e902ecbd0600691"), sealed.copyOfRange(sealed.size - 16, sealed.size))
        assertArrayEquals(hex("d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b6116"), sealed.copyOfRange(0, sealed.size - 16))
        assertArrayEquals(plain, PlaudCrypto.aeadOpen(sealed, key, nonce, aad))
        sealed[3] = (sealed[3].toInt() xor 1).toByte()
        assertNull(PlaudCrypto.aeadOpen(sealed, key, nonce, aad))
    }

    @Test fun fernetRoundTrip() {
        val token = PlaudCrypto.fernetEncrypt("""{"status":0}""".toByteArray(), ByteArray(16) { it.toByte() })
        assertEquals("""{"status":0}""", String(PlaudCrypto.fernetDecrypt(token)))
    }

    @Test fun rsaPkcs8Pem() {
        val pair = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
        val pem = "-----BEGIN PRIVATE KEY-----\n" + Base64.getMimeEncoder().encodeToString(pair.private.encoded) + "\n-----END PRIVATE KEY-----"
        val key = PlaudCrypto.importRSAPrivateKey(pem)
        val secret = ByteArray(56) { it.toByte() }
        val cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding").apply { init(Cipher.ENCRYPT_MODE, pair.public) }.doFinal(secret)
        assertArrayEquals(secret, PlaudCrypto.rsaDecryptPKCS1(cipher, key))
    }

    @Test fun wrappedFramesAreCompleteOgg() {
        val frames = ByteArray(80 * 120) { if (it % 80 == 0) 0xB8.toByte() else (it % 7).toByte() }
        assertTrue(PlaudCrypto.opusFramesLookValid(frames, 80))
        val ogg = PlaudOggOpus.wrap(frames)
        assertTrue(PlaudCrypto.isCompleteOgg(ogg))
        ogg[ogg.size - 3] = (ogg[ogg.size - 3].toInt() xor 1).toByte()
        assertTrue(!PlaudCrypto.isCompleteOgg(ogg))
    }
}
