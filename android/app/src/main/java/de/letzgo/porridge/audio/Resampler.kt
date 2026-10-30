package de.letzgo.porridge.audio

/**
 * Wandelt Mono-Samples fortlaufend auf eine andere Rate (iOS: `AVAudioConverter`). Beim Verkleinern wird über die
 * Fläche gemittelt (jedes Ausgabe-Sample ist der Mittelwert der Eingabe, die es überdeckt) — das dämpft Aliasing
 * genug für die Spracherkennung; beim Vergrößern linear interpoliert.
 */
class Resampler(private val inRate: Int, private val outRate: Int) {
    private val step = inRate.toDouble() / outRate
    /** Position (in Eingabe-Samples) des Beginns des nächsten Ausgabe-Samples, relativ zum nächsten Eingabeblock. */
    private var position = 0.0
    private var accumulator = 0.0
    private var covered = 0.0
    private var previous = 0f

    fun process(input: FloatArray, count: Int = input.size): FloatArray {
        if (inRate == outRate) return input.copyOf(count)
        val out = FloatArray(((count + 2) / step).toInt() + 2)
        var n = 0
        if (step >= 1.0) {
            // Flächenmittel: jedes Eingabe-Sample trägt mit dem Teil bei, der im aktuellen Ausgabe-Fenster liegt.
            for (i in 0 until count) {
                var remaining = 1.0
                val sample = input[i].toDouble()
                while (remaining > 0) {
                    val need = step - covered
                    val take = minOf(need, remaining)
                    accumulator += sample * take
                    covered += take
                    remaining -= take
                    if (covered >= step - 1e-9) {
                        out[n++] = (accumulator / step).toFloat()
                        accumulator = 0.0
                        covered = 0.0
                    }
                }
            }
        } else {
            for (i in 0 until count) {
                val current = input[i]
                while (position < 1.0) {
                    out[n++] = previous + (current - previous) * position.toFloat()
                    position += step
                }
                position -= 1.0
                previous = current
            }
        }
        return out.copyOf(n)
    }
}
