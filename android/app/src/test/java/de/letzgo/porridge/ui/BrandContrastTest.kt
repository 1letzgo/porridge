package de.letzgo.porridge.ui

import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import org.junit.Assert.assertTrue
import org.junit.Test

/** Die Palette gegen die Grenzwerte: 4,5:1 für Schrift, 3:1 für fette Schrift und Symbole (iOS: `BrandContrastTests`). */
class BrandContrastTest {
    private fun luminance(color: Long): Double {
        fun linear(part: Long): Double {
            val value = part / 255.0
            return if (value <= 0.03928) value / 12.92 else ((value + 0.055) / 1.055).pow(2.4)
        }
        return 0.2126 * linear((color shr 16) and 0xFF) + 0.7152 * linear((color shr 8) and 0xFF) + 0.0722 * linear(color and 0xFF)
    }

    private fun ratio(a: Long, b: Long): Double {
        val (x, y) = luminance(a) to luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    private fun assertRatio(foreground: Long, background: Long, limit: Double, name: String) =
        assertTrue("$name: ${ratio(foreground, background)}", ratio(foreground, background) >= limit)

    private val white = 0xFFFFFFFF

    @Test fun textOnThePage() {
        assertRatio(BrandPalette.SKY_TEXT, white, 4.5, "sky text")
        assertRatio(BrandPalette.LINK_TEXT, white, 4.5, "link text")
        assertRatio(BrandPalette.TASK_TEXT, white, 3.0, "task text")
        assertRatio(BrandPalette.DANGER, white, 4.5, "danger")
        assertRatio(BrandPalette.PROJECT, white, 4.5, "project")
        assertRatio(BrandPalette.NAVY, white, 4.5, "navy")
        val page = BrandPalette.PAGE_DARK
        assertRatio(BrandPalette.SKY, page, 4.5, "sky, dark")
        assertRatio(BrandPalette.LINK, page, 4.5, "link, dark")
        assertRatio(BrandPalette.TASK, page, 4.5, "task, dark")
        assertRatio(BrandPalette.DANGER_DARK, page, 4.5, "danger, dark")
        assertRatio(BrandPalette.PROJECT_DARK, page, 4.5, "project, dark")
        assertRatio(BrandPalette.NAVY_DARK, page, 4.5, "navy, dark")
    }

    @Test fun symbolsOnFullFills() {
        assertRatio(BrandPalette.NAVY, BrandPalette.SKY, 3.0, "navy on sky")
        assertRatio(BrandPalette.NAVY, BrandPalette.LINK, 3.0, "navy on orange")
        assertRatio(BrandPalette.NAVY, BrandPalette.TASK, 3.0, "navy on green")
        assertRatio(BrandPalette.NAVY, BrandPalette.NAVY_DARK, 3.0, "navy on light navy")
        assertRatio(white, BrandPalette.PROJECT_DARK, 3.0, "white on violet, dark")
        assertRatio(white, BrandPalette.DANGER, 3.0, "white on red")
    }
}
