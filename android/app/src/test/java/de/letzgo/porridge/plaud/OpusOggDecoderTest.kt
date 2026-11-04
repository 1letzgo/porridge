package de.letzgo.porridge.plaud

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class OpusOggDecoderTest {
    private fun bytes(vararg b: Int) = ByteArray(b.size) { b[it].toByte() }
    private val celt = ByteArray(80).also { it[0] = 0xB8.toByte() }

    @Test fun acceptsWhatLibopusAccepts() {
        assertTrue(OpusOggDecoder.isValidPacket(celt))
        assertTrue("TOC only is a lost frame", OpusOggDecoder.isValidPacket(bytes(0xB8)))
        assertTrue("all zero", OpusOggDecoder.isValidPacket(ByteArray(80)))
        assertTrue("code 1, two equal frames", OpusOggDecoder.isValidPacket(bytes(0xB9, 1, 2)))
        assertTrue("code 2", OpusOggDecoder.isValidPacket(bytes(0xBA, 1, 9, 9)))
        assertTrue("code 3 CBR", OpusOggDecoder.isValidPacket(bytes(0xBB, 2, 7, 7)))
        assertTrue("code 3 VBR", OpusOggDecoder.isValidPacket(bytes(0xBB, 0x82, 1, 7, 7, 7)))
        assertTrue("code 3 padding", OpusOggDecoder.isValidPacket(bytes(0xBB, 0x41, 1, 7, 0)))
    }

    @Test fun rejectsWhatStopsTheDecoder() {
        assertFalse("empty", OpusOggDecoder.isValidPacket(ByteArray(0)))
        assertFalse("code 1, odd", OpusOggDecoder.isValidPacket(bytes(0xB9, 1)))
        assertFalse("code 2, frame too long", OpusOggDecoder.isValidPacket(bytes(0xBA, 9, 1)))
        assertFalse("code 3, no header", OpusOggDecoder.isValidPacket(bytes(0xBB)))
        assertFalse("code 3, no frames", OpusOggDecoder.isValidPacket(bytes(0xBB, 0, 1)))
        assertFalse("code 3, over 120 ms", OpusOggDecoder.isValidPacket(ByteArray(80).also { it[0] = 0xBB.toByte(); it[1] = 7 }))
        assertFalse("code 3 CBR, uneven", OpusOggDecoder.isValidPacket(bytes(0xBB, 2, 7)))
        assertFalse("code 3, padding too long", OpusOggDecoder.isValidPacket(bytes(0xBB, 0x41, 9)))
        assertFalse("frame over 1275 bytes", OpusOggDecoder.isValidPacket(ByteArray(1277).also { it[0] = 0xB8.toByte() }))
    }

    @Test fun replacesFewBadPacketsAndKeepsTheirPlaces() {
        val bad = bytes(0xBB, 0, 1)
        val packets = List(600) { celt }.toMutableList().also { it[200] = bad; it[300] = ByteArray(0) }
        val repaired = OpusOggDecoder.repaired(packets)
        assertEquals(600, repaired.size)
        assertTrue(repaired.all(OpusOggDecoder::isValidPacket))
        assertEquals(1, repaired[200].size)
        assertEquals(0xB8.toByte(), repaired[200][0])
        assertEquals(80, repaired[201].size)
    }

    @Test fun leavesGoodPacketsAlone() {
        val packets = List(10) { celt }
        assertTrue(OpusOggDecoder.repaired(packets) === packets)
    }

    @Test fun refusesAMostlyBrokenFile() {
        val packets = List(100) { celt }.toMutableList().also { for (i in 0 until 5) it[i] = ByteArray(0) }
        assertThrows(IllegalStateException::class.java) { OpusOggDecoder.repaired(packets) }
    }
}
