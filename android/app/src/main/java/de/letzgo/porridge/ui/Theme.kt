package de.letzgo.porridge.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/**
 * iOS: `Design/Brand.swift` + Richtung „Things 3“ (design-demos/direction-approved.md): weiße Flächen, große
 * fette Titel, Haarlinien, Sektionstitel klein-fett in Navy; Sky nur für Auswahl, Plus und Akzent.
 */
object Brand {
    val sky = Color(BrandPalette.SKY)
    /** Im Dunkeln die helle Variante, wie die iOS-Farbe `BrandNavy`. */
    val navy: Color
        @Composable @ReadOnlyComposable get() = if (isSystemInDarkTheme()) NavyDark else NavyLight
    /** Aufgaben: frisches Grün neben dem Sky-Blau (iOS: `brandTask`). */
    val task = Color(BrandPalette.TASK)
    val link = Color(BrandPalette.LINK)
    val hairline = Color(0x1F000000)
    /** Fläche von allem, was löscht; als Schrift oder Symbol [dangerText]. */
    val danger = Color(BrandPalette.DANGER)
    /** Projekte: Violett (iOS: `brandProject`). */
    val project: Color
        @Composable @ReadOnlyComposable get() = if (isSystemInDarkTheme()) Color(BrandPalette.PROJECT_DARK) else Color(BrandPalette.PROJECT)

    // Sky, Orange und Grün sind als Schrift und Symbol auf Weiß zu hell (iOS: `brandSkyText` usw.).
    val skyText: Color
        @Composable @ReadOnlyComposable get() = if (isSystemInDarkTheme()) sky else Color(BrandPalette.SKY_TEXT)
    val linkText: Color
        @Composable @ReadOnlyComposable get() = if (isSystemInDarkTheme()) link else Color(BrandPalette.LINK_TEXT)
    val taskText: Color
        @Composable @ReadOnlyComposable get() = if (isSystemInDarkTheme()) task else Color(BrandPalette.TASK_TEXT)
    val dangerText: Color
        @Composable @ReadOnlyComposable get() = if (isSystemInDarkTheme()) Color(BrandPalette.DANGER_DARK) else danger

    /** Symbole und Schrift auf einer vollen Fläche aus Sky, Orange oder Grün. */
    val onFill = Color(BrandPalette.NAVY)

    /** Diese Farbe als Schrift oder Symbol auf der Seite (iOS: `readable`). */
    @Composable @ReadOnlyComposable
    fun readable(color: Color): Color = when (color) {
        sky -> skyText
        link -> linkText
        task -> taskText
        danger -> dangerText
        else -> color
    }

    /** Was auf eine volle Fläche dieser Farbe gehört (iOS: `onFill`). */
    @Composable @ReadOnlyComposable
    fun onFill(fill: Color): Color = when {
        fill == sky || fill == link || fill == task -> onFill
        fill == NavyDark -> onFill
        else -> Color.White
    }

    /** Hauptknopf nach `DESIGN.md`: eine Tönung seiner Farbe mit Navy-Schrift. */
    @Composable
    fun mainButton() = androidx.compose.material3.ButtonDefaults.buttonColors(containerColor = sky.copy(alpha = 0.18f), contentColor = navy)
}

/** Die Werte der Palette; [BrandContrastTest] rechnet ihre Paare gegen die Grenzwerte. */
object BrandPalette {
    const val SKY = 0xFF24B4E9
    const val SKY_TEXT = 0xFF0B79A8
    const val NAVY = 0xFF1F3667
    const val NAVY_DARK = 0xFFB0C4EC
    const val LINK = 0xFFFA8F24
    const val LINK_TEXT = 0xFFB55D00
    const val TASK = 0xFF29BD80
    const val TASK_TEXT = 0xFF0F8A5A
    const val PROJECT = 0xFF7C5CD6
    const val PROJECT_DARK = 0xFF9B82E8
    const val DANGER = 0xFFD93025
    const val DANGER_DARK = 0xFFFF6B60
    const val PAGE_DARK = 0xFF111214
}

private val NavyLight = Color(BrandPalette.NAVY)
private val NavyDark = Color(BrandPalette.NAVY_DARK)

private val LightColors = lightColorScheme(
    primary = Color(BrandPalette.SKY_TEXT),
    onPrimary = Color.White,
    secondary = NavyLight,
    onSecondary = Color.White,
    background = Color.White,
    surface = Color.White,
    surfaceVariant = Color(0xFFF4F5F7),
    onSurface = Color(0xFF111418),
    onSurfaceVariant = Color(0xFF6B7280),
    outlineVariant = Brand.hairline,
    error = Brand.danger,
    // Dialoge, Menüs und Chips: weiß und blau statt der lila Vorgaben von Material.
    surfaceContainerLowest = Color.White,
    surfaceContainerLow = Color.White,
    surfaceContainer = Color.White,
    surfaceContainerHigh = Color.White,
    surfaceContainerHighest = Color(0xFFF4F5F7),
    secondaryContainer = Color(0xFFD9F1FB),
    onSecondaryContainer = NavyLight,
)

private val DarkColors = darkColorScheme(
    primary = Brand.sky,
    onPrimary = Brand.onFill,
    secondary = NavyDark,
    background = Color(0xFF111214),
    onBackground = Color(0xFFECEDEF),
    surface = Color(0xFF111214),
    onSurface = Color(0xFFECEDEF),
    surfaceVariant = Color(0xFF1C1D20),
    onSurfaceVariant = Color(0xFF9CA3AF),
    outlineVariant = Color(0x29FFFFFF),
    error = Color(BrandPalette.DANGER_DARK),
    surfaceContainerLowest = Color(0xFF111214),
    surfaceContainerLow = Color(0xFF1C1D20),
    surfaceContainer = Color(0xFF1C1D20),
    surfaceContainerHigh = Color(0xFF1C1D20),
    surfaceContainerHighest = Color(0xFF26272B),
    secondaryContainer = Color(0xFF12384A),
    onSecondaryContainer = NavyDark,
)

private val PorridgeTypography = Typography().let { base ->
    base.copy(
        // Große, fette Titel wie die iOS-Navigationstitel.
        headlineLarge = base.headlineLarge.copy(fontWeight = FontWeight.Bold, fontSize = 34.sp),
        titleLarge = base.titleLarge.copy(fontWeight = FontWeight.SemiBold),
        // Sektionstitel: klein und fett.
        labelLarge = TextStyle(fontWeight = FontWeight.Bold, fontSize = 13.sp, letterSpacing = 0.2.sp),
    )
}

@Composable
fun PorridgeTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) DarkColors else LightColors,
        typography = PorridgeTypography,
    ) {
        // Die Fläche setzt auch die Textfarbe; ohne sie wären Text und Icons im Dunkeln schwarz.
        Surface(color = MaterialTheme.colorScheme.background, content = content)
    }
}
