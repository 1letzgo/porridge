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
    val sky = Color(0xFF24B4E9)
    /** Im Dunkeln die helle Variante, wie die iOS-Farbe `BrandNavy`. */
    val navy: Color
        @Composable @ReadOnlyComposable get() = if (isSystemInDarkTheme()) NavyDark else NavyLight
    /** Aufgaben: frisches Grün neben dem Sky-Blau (iOS: `brandTask`). */
    val task = Color(0xFF29BD80)
    val hairline = Color(0x1F000000)
    val danger = Color(0xFFD93025)
    /** Chat (iOS: `brandChat`). */
    val chat = Color(0xFFE63F3D)
    /** Projekte: Violett (iOS: `brandProject`). */
    val project = Color(0xFF7C5CD6)
}

private val NavyLight = Color(0xFF1F3667)
private val NavyDark = Color(0xFFB0C4EC)

private val LightColors = lightColorScheme(
    primary = Brand.sky,
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
    onPrimary = Color.White,
    secondary = NavyDark,
    background = Color(0xFF111214),
    onBackground = Color(0xFFECEDEF),
    surface = Color(0xFF111214),
    onSurface = Color(0xFFECEDEF),
    surfaceVariant = Color(0xFF1C1D20),
    onSurfaceVariant = Color(0xFF9CA3AF),
    outlineVariant = Color(0x29FFFFFF),
    error = Brand.danger,
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
