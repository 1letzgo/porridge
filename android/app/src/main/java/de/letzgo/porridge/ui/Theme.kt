package de.letzgo.porridge.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
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
    val navy = Color(0xFF1F3667)
    /** Aufgaben: frisches Grün neben dem Sky-Blau (iOS: `brandTask`). */
    val task = Color(0xFF29BD80)
    val hairline = Color(0x1F000000)
    val danger = Color(0xFFD93025)
    /** Chat (iOS: `brandChat`). */
    val chat = Color(0xFFE63F3D)
}

private val LightColors = lightColorScheme(
    primary = Brand.sky,
    onPrimary = Color.White,
    secondary = Brand.navy,
    onSecondary = Color.White,
    background = Color.White,
    surface = Color.White,
    surfaceVariant = Color(0xFFF4F5F7),
    onSurface = Color(0xFF111418),
    onSurfaceVariant = Color(0xFF6B7280),
    outlineVariant = Brand.hairline,
    error = Brand.danger,
)

private val DarkColors = darkColorScheme(
    primary = Brand.sky,
    onPrimary = Color.White,
    secondary = Color(0xFF9DB4E6),
    background = Color(0xFF111214),
    surface = Color(0xFF111214),
    surfaceVariant = Color(0xFF1C1D20),
    outlineVariant = Color(0x29FFFFFF),
    error = Brand.danger,
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
        content = content,
    )
}
