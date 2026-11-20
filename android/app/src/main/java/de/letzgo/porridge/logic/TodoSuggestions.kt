package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteSource
import de.letzgo.porridge.model.TodoState
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import java.text.Normalizer
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

/**
 * iOS: `TaskSuggestion` — eine Aufgabe einer Zusammenfassung, als To-do angeboten: „Send the offer – Anna – 2026-11-28“
 * wird Titel, Zuständige und fälliger Tag.
 */
data class TaskSuggestion(
    /** Die Wörter der Aufgabe, normalisiert ([TodoSuggestions.key]): was „dieselbe Aufgabe“ über Zusammenfassungen hinweg heißt. */
    val key: String,
    val title: String,
    val owner: String?,
    /** "yyyy-MM-dd", wenn die Zusammenfassung ein Datum nennt, das einen Tag ergibt; sonst null (nichts wird geraten). */
    val dueDay: String?,
    /** Index der Zeile in der Zusammenfassung. */
    val line: Int,
    /** Die Aufgabe ist die des Nutzers (einer seiner Namen ist zuständig) oder niemandes. */
    val isMine: Boolean,
)

/**
 * iOS: `TodoSuggestions` (Services/TodoSuggestions.swift) — To-dos, vorgeschlagen aus den Aufgaben einer Zusammenfassung.
 * Nichts wird ohne Tipp ein To-do: Die Seite des Meetings bietet sie an, der Nutzer wählt und übernimmt sie oder
 * verwirft sie. Was mit jeder Aufgabe geschah, steht am Meeting (`Note.todoSuggestionsRaw`), auf jedem Gerät gleich.
 * Format in `DESIGN.md`, Abschnitt „Suggested to-dos“; `TodoSuggestionsTest` prüft die Fälle von `TodoSuggestionsTests.swift`.
 */
object TodoSuggestions {
    const val TAKEN = "taken"
    const val DISMISSED = "dismissed"

    // Die Aufgaben lesen

    /** Die offenen Aufgaben einer Zusammenfassung als Vorschläge, in ihrer Reihenfolge, jede einmal. */
    fun parse(summary: String, meetingDate: Long, zone: ZoneId = ZoneId.systemDefault(), myNames: List<String> = de.letzgo.porridge.data.Me.names): List<TaskSuggestion> {
        val seen = HashSet<String>()
        return SummaryTasks.parse(summary).mapNotNull { task ->
            if (task.done) return@mapNotNull null
            val (title, owner, due) = split(task.text, meetingDate, zone)
            val key = key(title)
            if (key.isEmpty() || !seen.add(key)) return@mapNotNull null
            // Niemandes Aufgabe zählt als die des Nutzers; „Anna und Ben“ ist seine, wenn einer von beiden er ist.
            val mine = owner?.let { o ->
                o.replace(Regex("""\s+(and|und|et|y|e|en|i)\s+""", RegexOption.IGNORE_CASE), ",")
                    .split(',', '&', '/').filter { it.isNotEmpty() }
                    .any { de.letzgo.porridge.data.Me.isMe(it, myNames) }
            } ?: true
            TaskSuggestion(key, title, owner, due, task.line, mine)
        }
    }

    /** Wie Swifts `.whitespaces`: Leerzeichen aller Art und Tab. */
    private fun isSpace(c: Char) = c == '\t' || Character.getType(c) == Character.SPACE_SEPARATOR.toInt()

    /**
     * „Send the offer – Anna – 2026-11-28“: die Aufgabe, dann Zuständige und Frist in beliebiger Reihenfolge, je optional.
     * Geteilt an einem Gedankenstrich mit Leerzeichen (–, — oder -). Platzhalter („n/a“, „–“, „unknown“) sind keine Zuständigen.
     */
    fun split(text: String, meetingDate: Long, zone: ZoneId = ZoneId.systemDefault()): Triple<String, String?, String?> {
        var parts = text.split(" – ").flatMap { it.split(" — ") }
        if (parts.size == 1) parts = text.split(" - ")
        parts = parts.map { p -> p.trim { isSpace(it) } }
        val title = cleanTitle(parts.firstOrNull() ?: text)
        var owner: String? = null
        var due: String? = null
        for (part in parts.drop(1)) {
            val cleaned = part.trim { isSpace(it) || it in " ()[]*_.,;–—-" }
            if (cleaned.isEmpty() || isPlaceholder(cleaned)) continue
            // Das Datum vor dem Kürzen der Punkte gelesen: „28.11.“ behält seinen letzten.
            val dateText = part.trim { isSpace(it) || it in " ()[]*_,;–—-" }
            val day = if (due == null) dueDay(dateText, meetingDate, zone) else null
            if (day != null) {
                due = day
            } else if (owner == null && !cleaned.any { it.isDigit() }) {
                owner = cleaned.replace(Regex("""^(owner|verantwortlich|zuständig|wer)\s*:\s*""", RegexOption.IGNORE_CASE), "")
            }
        }
        // Kleine Modelle kopieren den Tag des Meetings in jede Aufgabe: Er zählt nur für eine Aufgabe, die „heute“ fällig ist.
        val meetingDay = Todos.dueKey(meetingDate, zone)
        if (due == meetingDay && !saysToday(title)) due = null
        // Eine Frist in den Worten der Aufgabe selbst („… bis zum 3. Dezember“).
        if (due == null) {
            val inTitle = dueDay(title, meetingDate, zone)
            if (inTitle != null && (inTitle != meetingDay || saysToday(title))) due = inTitle
        }
        return Triple(title, owner, due)
    }

    private val todayWords = listOf("today", "heute", "aujourd", "hoy", "oggi", "vandaag", "hoje", "dzisiaj", "dziś")

    private fun saysToday(text: String): Boolean {
        val lower = text.lowercase()
        return todayWords.any { lower.contains(it) }
    }

    private fun cleanTitle(text: String) = text.replace("**", "").trim { isSpace(it) || it in "–—-:" }

    private val placeholders = setOf(
        "-", "–", "—", "?", "n/a", "na", "none", "unknown", "tbd", "tba", "not named", "not specified", "unassigned", "nobody",
        "keine", "keiner", "niemand", "unbekannt", "offen", "nicht genannt", "nicht festgelegt", "k.a.", "ka", "ohne",
        "aucun", "inconnu", "ninguno", "nessuno", "geen", "nenhum", "brak",
    )

    private fun isPlaceholder(text: String): Boolean {
        val lower = text.lowercase()
        return lower in placeholders || lower.startsWith("<") || (lower.startsWith("owner") && lower.length <= 6) ||
            lower.contains("if known") || lower.contains("if named") || lower.contains("falls")
    }

    // Daten

    private val iso = Regex("""\b(\d{4})-(\d{1,2})-(\d{1,2})\b""", RegexOption.IGNORE_CASE)
    private val dotted = Regex("""(?<![\d.])(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})?(?![\d])""", RegexOption.IGNORE_CASE)
    private val dayMonth = Regex("""(?<!\d)(\d{1,2})(?:st|nd|rd|th|er|º)?\.?\s+(?:de\s+)?(\p{L}{3,})\.?(?:\s+(?:de\s+)?(\d{4}))?""", RegexOption.IGNORE_CASE)
    private val monthDay = Regex("""(\p{L}{3,})\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b,?(?:\s+(\d{4}))?""", RegexOption.IGNORE_CASE)

    /**
     * Der Tag, den eine Frist nennt, als "yyyy-MM-dd", nur wenn sie ein Datum ist: "2026-11-28", "28.11.2026", "28.11.",
     * "28 November", "November 28, 2026", "28. Nov". Ein Tag ohne Jahr ist der erste solche am oder nach dem Meeting.
     * Wörter wie „next Friday“ oder „Ende des Monats“ geben nichts: Nichts wird geraten.
     */
    fun dueDay(text: String, meetingDate: Long, zone: ZoneId = ZoneId.systemDefault()): String? {
        fun MatchResult.int(i: Int) = groups[i]?.value?.toIntOrNull()
        iso.find(text)?.let { m ->
            val y = m.int(1); val mo = m.int(2); val d = m.int(3)
            if (y != null && mo != null && d != null) return day(y, mo, d)
        }
        dotted.find(text)?.let { m ->
            val d = m.int(1); val mo = m.int(2)
            if (d != null && mo != null) return resolve(m.int(3)?.let { if (it < 100) 2000 + it else it }, mo, d, meetingDate, zone)
        }
        for (m in dayMonth.findAll(text)) {
            val d = m.int(1) ?: continue
            val mo = month(m.groupValues[2]) ?: continue
            return resolve(m.int(3), mo, d, meetingDate, zone)
        }
        for (m in monthDay.findAll(text)) {
            val d = m.int(2) ?: continue
            val mo = month(m.groupValues[1]) ?: continue
            return resolve(m.int(3), mo, d, meetingDate, zone)
        }
        return null
    }

    /** Monatsnamen und ihre üblichen Kurzformen in den Sprachen der Zusammenfassungen. */
    private val months: List<Pair<Int, List<String>>> = listOf(
        1 to listOf("january", "jan", "januar", "jänner", "janvier", "janv", "enero", "ene", "gennaio", "gen", "januari", "janeiro", "stycznia", "styczeń"),
        2 to listOf("february", "feb", "februar", "février", "févr", "fevrier", "febrero", "febbraio", "februari", "fevereiro", "fev", "lutego", "luty"),
        3 to listOf("march", "mar", "märz", "maerz", "mrz", "mars", "marzo", "maart", "mrt", "março", "marca", "marzec"),
        4 to listOf("april", "apr", "avril", "avr", "abril", "abr", "aprile", "kwietnia", "kwiecień"),
        5 to listOf("may", "mai", "mayo", "maggio", "mag", "mei", "maio", "maja", "maj"),
        6 to listOf("june", "jun", "juni", "juin", "junio", "giugno", "giu", "junho", "czerwca", "czerwiec"),
        7 to listOf("july", "jul", "juli", "juillet", "juil", "julio", "luglio", "lug", "julho", "lipca", "lipiec"),
        8 to listOf("august", "aug", "août", "aout", "agosto", "ago", "augustus", "sierpnia", "sierpień"),
        9 to listOf("september", "sep", "sept", "septembre", "septiembre", "settembre", "set", "setembro", "września", "wrzesień"),
        10 to listOf("october", "oct", "oktober", "okt", "octobre", "octubre", "ottobre", "ott", "outubro", "out", "października", "październik"),
        11 to listOf("november", "nov", "novembre", "noviembre", "novembro", "listopada", "listopad"),
        12 to listOf("december", "dec", "dezember", "dez", "décembre", "déc", "decembre", "diciembre", "dic", "dicembre", "dezembro", "grudnia", "grudzień"),
    )

    private fun month(word: String): Int? {
        val lower = word.lowercase()
        return months.firstOrNull { lower in it.second }?.first
    }

    /** Ein gültiger Tag, sonst null (kein 31. Februar). */
    private fun day(year: Int, month: Int, day: Int): String? = runCatching { Todos.dueKey(LocalDate.of(year, month, day)) }.getOrNull()

    private fun resolve(year: Int?, month: Int, d: Int, meetingDate: Long, zone: ZoneId): String? {
        if (year != null) return day(year, month, d)
        val meeting = Instant.ofEpochMilli(meetingDate).atZone(zone).toLocalDate()
        val meetingDay = Todos.dueKey(meeting)
        val thisYear = day(meeting.year, month, d) ?: return day(meeting.year + 1, month, d)
        return if (thisYear >= meetingDay) thisYear else day(meeting.year + 1, month, d)
    }

    // Dieselbe Aufgabe

    /** Die Wörter einer Aufgabe, klein, ohne Akzente und Satzzeichen: "Send the offer!" → "send the offer". */
    fun key(title: String): String =
        Normalizer.normalize(title, Normalizer.Form.NFD).replace(Regex("\\p{Mn}+"), "").lowercase()
            .split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }.joinToString(" ")

    /**
     * Zwei Aufgaben sind dieselbe, wenn ihre Schlüssel gleich sind, oder, mit je drei Wörtern oder mehr, wenn mindestens
     * 60 % aller ihrer Wörter gemeinsam sind (eine neu geschriebene Zusammenfassung sagt eine Aufgabe etwas anders).
     */
    fun isSame(a: String, b: String): Boolean {
        if (a == b) return true
        val x = a.split(" ").filter { it.isNotEmpty() }.toSet()
        val y = b.split(" ").filter { it.isNotEmpty() }.toSet()
        if (x.size < 3 || y.size < 3) return false
        return (x intersect y).size.toDouble() / (x union y).size.toDouble() >= 0.6
    }

    // Was mit ihnen geschah

    /** Die gespeicherten Stände: Schlüssel der Aufgabe → "taken" oder "dismissed". Unbekannte Werte bleiben, wie sie sind. */
    fun states(raw: String?): Map<String, String> {
        raw ?: return emptyMap()
        val obj = runCatching { de.letzgo.porridge.data.PorridgeJson.parseToJsonElement(raw).jsonObject }.getOrNull() ?: return emptyMap()
        // Wie iOS (`as? [String: String]`): Ist ein Wert kein Text, gilt das Ganze als leer.
        val result = LinkedHashMap<String, String>()
        for ((k, v) in obj) {
            val p = v as? JsonPrimitive ?: return emptyMap()
            if (!p.isString) return emptyMap()
            result[k] = p.contentOrNull ?: return emptyMap()
        }
        return result
    }

    /** Die Stände, wie sie gespeichert werden: ein JSON-Objekt mit sortierten Schlüsseln, "{}", solange nichts geschah. */
    fun encode(states: Map<String, String>): String =
        JsonObject(states.toSortedMap().mapValues { JsonPrimitive(it.value) }).toString()

    fun state(key: String, states: Map<String, String>): String? = states[key] ?: states.entries.firstOrNull { isSame(it.key, key) }?.value

    /** Vorschläge, die noch warten: nicht übernommen (auch nicht anders zum To-do gemacht) und nicht verworfen. */
    fun pending(suggestions: List<TaskSuggestion>, states: Map<String, String>, madeTitles: List<String>): List<TaskSuggestion> {
        val made = madeTitles.map(::key)
        return suggestions.filter { s -> state(s.key, states) == null && made.none { isSame(it, s.key) } }
    }

    /** Ob eine Aufgabe der Zusammenfassung (ihr Text) ein To-do wurde, für das Zeichen an ihrer Zeile. */
    fun isTaken(taskText: String, states: Map<String, String>, madeTitles: List<String>): Boolean {
        val key = key(split(taskText, System.currentTimeMillis()).first)
        return state(key, states) == TAKEN || madeTitles.map(::key).any { isSame(it, key) }
    }

    // An der Notiz (iOS: `extension Note` und `@MainActor extension TodoSuggestions`, hier rein)

    /** Ob für diese Notiz Vorschläge angeboten werden: eine Zusammenfassung, nie ein Link oder eine Datei, und angeboten. */
    fun offers(note: Note): Boolean = note.todoSuggestionsRaw != null && !note.isSaved && !note.isTodo && note.summary != null && !note.isDeleted

    /** Die Vorschläge, die an dieser Notiz warten, bei den aus ihr gemachten To-dos [made]. */
    fun pendingFor(note: Note, made: List<Note>, zone: ZoneId = ZoneId.systemDefault(), myNames: List<String> = de.letzgo.porridge.data.Me.names): List<TaskSuggestion> {
        if (!offers(note)) return emptyList()
        val summary = note.summary ?: return emptyList()
        return pending(parse(summary, note.createdAt, zone, myNames), states(note.todoSuggestionsRaw), made.map { it.title })
    }

    /** Eine Zusammenfassung wurde geschrieben: Ihre Aufgaben werden angeboten. Was übernommen oder verworfen war, bleibt. */
    fun offered(note: Note): Note = if (note.isSaved || note.todoSuggestionsRaw != null) note else note.copy(todoSuggestionsRaw = encode(emptyMap()))

    /** „Suggest To-dos“: Die verworfenen kommen zurück, übernommene bleiben übernommen. */
    fun suggestedAgain(note: Note): Note? {
        if (note.isSaved) return null
        return note.copy(todoSuggestionsRaw = encode(states(note.todoSuggestionsRaw).filterValues { it != DISMISSED }))
    }

    /** Nichts davon jetzt: Die Aufgaben sind verworfen bis „Suggest To-dos“. */
    fun dismissed(suggestions: List<TaskSuggestion>, note: Note): Note {
        val all = LinkedHashMap(states(note.todoSuggestionsRaw))
        for (s in suggestions) if (all[s.key] == null) all[s.key] = DISMISSED
        return note.copy(todoSuggestionsRaw = encode(all))
    }

    /**
     * Übernimmt die gewählten Vorschläge: je ein To-do, oder ein To-do „Follow-ups: <Titel>“ mit ihnen als Unteraufgaben.
     * Die nicht gewählten sind verworfen. Die To-dos liegen in den Buckets der Notiz und zeigen auf sie zurück.
     * Gibt die neuen To-dos und die geänderte Notiz zurück; null, wenn nichts zu tun ist.
     */
    fun take(chosen: List<TaskSuggestion>, rest: List<TaskSuggestion>, note: Note, asOne: Boolean, now: Long = System.currentTimeMillis()): Pair<List<Note>, Note>? {
        if (note.isSaved || chosen.isEmpty()) return null
        val made = if (asOne) {
            listOf(
                newTodo("Follow-ups: ${note.displayTitle}", note, now).copy(
                    text = chosen.joinToString("\n") { s -> "- [ ] " + s.title + (ownerNote(s)?.let { " ($it)" } ?: "") },
                    todoDueDay = chosen.mapNotNull { it.dueDay }.minOrNull(),
                ),
            )
        } else {
            chosen.map { s -> newTodo(s.title, note, now).copy(text = ownerNote(s)?.let { "Owner: $it" } ?: "", todoDueDay = s.dueDay) }
        }
        val all = LinkedHashMap(states(note.todoSuggestionsRaw))
        for (s in chosen) all[s.key] = TAKEN
        for (s in rest) if (all[s.key] == null) all[s.key] = DISMISSED
        return made to note.copy(todoSuggestionsRaw = encode(all), updatedAt = now)
    }

    /** Die Zuständige, die es wert ist, notiert zu werden: der Name eines anderen (die eigenen Aufgaben brauchen keinen). */
    private fun ownerNote(s: TaskSuggestion): String? = if (s.owner != null && !s.isMine) s.owner else null

    private fun newTodo(title: String, note: Note, now: Long) = Note(
        title = title, titleIsCustom = true, sourceRaw = NoteSource.NOTE.raw, todoStateRaw = TodoState.OPEN.raw,
        todoSourceID = note.id, projectIDs = note.projectIDs, filedAt = if (note.projectIDs.isEmpty()) null else now,
        createdAt = now, updatedAt = now,
    )
}
