package de.letzgo.porridge.logic

import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteText
import kotlinx.serialization.Serializable
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * iOS: `ChatDocument` (Services/ChatDocument.swift) — ein Eintrag, wie der Chat ihn sieht: Art, Daten, Buckets, Link und
 * To-do-Stand und ein kurzer Ausschnitt. Liegt neben den Passagen des Eintrags im Index (`index/NoteIndex.kt`); aus der
 * Notiz abgeleitet, nie synchronisiert, jederzeit neu baubar. Die Namen der Buckets stehen nicht darin (ein Bucket kann
 * umbenannt werden): Sie werden nachgesehen, wenn gefragt wird. DESIGN.md „Chat data“ beschreibt das Format.
 */
@Serializable
data class ChatDocument(
    val noteID: String,
    val kind: Kind,
    val title: String,
    val createdAt: Long,
    /** `Note.projectIDs`: leer ist die Inbox. */
    val bucketIDs: List<String>,
    val url: String? = null,
    val domain: String? = null,
    /** "open" oder "done"; null für alles, was kein To-do ist. */
    val todoState: String? = null,
    /** "yyyy-MM-dd" (`Todos.dueKey`); null ohne fälligen Tag. */
    val dueDay: String? = null,
    val doneAt: Long? = null,
    val subtasksDone: Int = 0,
    val subtasksTotal: Int = 0,
    val tags: List<String> = emptyList(),
    /** Der Anfang des Eintrags: seine Zusammenfassung, sonst sein Text, seine Seite oder sein Transkript; höchstens 200 Zeichen. */
    val snippet: String = "",
) {
    @Serializable
    enum class Kind(val label: String) {
        NOTE("Note"), MEETING("Meeting"), LINK("Link"), TODO("To-do"), IMAGE("Image"), FILE("File");
    }

    val isOpenTodo: Boolean get() = todoState == "open"
    val isDoneTodo: Boolean get() = todoState == "done"

    /**
     * Die Zeile, die den Eintrag dem Modell vorstellt:
     * `«Title» — To-do, open, due 12 December 2026, overdue, 1 of 3 subtasks done · created Tue 17 Nov 2026 · Bucket: Travel`
     * und für einen Link `«Title» — Link (example.com) · created … · Inbox · https://example.com/a`.
     */
    fun header(bucketNames: Map<String, String>, now: Long = System.currentTimeMillis(), zone: ZoneId = ZoneId.systemDefault()): String {
        var kindText = kind.label
        if (kind == Kind.LINK && domain != null) kindText += " ($domain)"
        if (todoState != null) {
            kindText += ", $todoState"
            if (todoState == "done" && doneAt != null) kindText += " on " + dayText(doneAt, zone)
            if (dueDay != null) {
                kindText += ", due " + Todos.dueText(dueDay)
                if (todoState == "open" && Todos.dueStatus(dueDay, now, zone) == Todos.DueStatus.OVERDUE) kindText += ", overdue"
            }
            if (subtasksTotal > 0) kindText += ", $subtasksDone of $subtasksTotal subtasks done"
        }
        val parts = mutableListOf(kindText, "created " + dayText(createdAt, zone))
        val names = bucketIDs.mapNotNull { bucketNames[it] }
        parts += if (names.isEmpty()) "Inbox" else (if (names.size == 1) "Bucket: " else "Buckets: ") + names.joinToString(", ")
        if (tags.isNotEmpty()) parts += tags.joinToString(" ") { "#$it" }
        url?.let { parts += it }
        return "«$title» — " + parts.joinToString(" · ")
    }

    companion object {
        const val SNIPPET_LENGTH = 200

        private val dayFormat = DateTimeFormatter.ofPattern("EEE d MMM yyyy", Locale.US)

        /** „Tue 17 Nov 2026“: in jeder Sprache gleich, damit das Modell es gleich liest. */
        fun dayText(time: Long, zone: ZoneId = ZoneId.systemDefault()): String = dayFormat.format(Instant.ofEpochMilli(time).atZone(zone))

        fun of(note: Note): ChatDocument {
            val kind = when {
                note.isTodo -> Kind.TODO
                note.isLink -> Kind.LINK
                note.isImage -> Kind.IMAGE
                note.isFile -> Kind.FILE
                note.isRecording -> Kind.MEETING
                else -> Kind.NOTE
            }
            val title = note.displayTitle
            val sources = listOf(note.summary.orEmpty(), note.text, note.pageText.orEmpty(), note.segments.take(20).joinToString(" ") { it.text })
            var lines: List<String> = emptyList()
            for (source in sources) {
                if (lines.isNotEmpty()) break
                // Überschriften („## Summary“) fallen weg, bevor die Zeichen abgenommen werden.
                val withoutHeadings = source.split("\n").filter { !it.trim(' ', '\t').startsWith("#") }
                lines = NoteText.plainLines(withoutHeadings.joinToString("\n"))
                // Die erste Zeile einer Notiz ohne Titel ist schon ihr Titel.
                if (note.title.trim().isEmpty() && source == note.text && lines.firstOrNull() == title) lines = lines.drop(1)
            }
            val joined = lines.joinToString(" ")
            val progress = note.todoProgress
            return ChatDocument(
                noteID = note.id,
                kind = kind,
                title = title,
                createdAt = note.createdAt,
                bucketIDs = note.projectIDs,
                url = note.url,
                domain = note.domain,
                todoState = if (note.isTodo) (if (note.isDone) "done" else "open") else null,
                dueDay = note.todoDue,
                doneAt = if (note.isDone) note.todoDoneAt else null,
                subtasksDone = progress.done,
                subtasksTotal = progress.total,
                tags = note.tags,
                snippet = if (joined.length > SNIPPET_LENGTH) joined.take(SNIPPET_LENGTH - 1) + "…" else joined,
            )
        }
    }
}

/** Eine Zeitspanne aus ganzen Tagen, `[start, end)` in Millisekunden. */
data class DaySpan(val start: Long, val end: Long) {
    operator fun contains(time: Long) = time >= start && time < end
}

/**
 * iOS: `ChatQuery` (Services/ChatDocument.swift) — was eine Frage über ihre Wörter hinaus verlangt: eine Art Eintrag, einen
 * Bucket, den Stand eines To-dos, eine Zeit. Aus der Frage über feste Wortlisten gelesen (Deutsch und Englisch); die Wörter,
 * aus denen das gelesen wurde, werden nicht gesucht.
 */
data class ChatQuery(
    val kinds: Set<ChatDocument.Kind> = emptySet(),
    val bucketIDs: Set<String> = emptySet(),
    /** „Inbox“: Einträge in keinem Bucket. */
    val inbox: Boolean = false,
    val todo: TodoFilter? = null,
    val range: DaySpan? = null,
    val dateField: DateField = DateField.AUTO,
    /** Die Wörter, die zu suchen bleiben. */
    val words: List<String> = emptyList(),
) {
    enum class TodoFilter(val raw: String) { OPEN("open"), DONE("done"), OVERDUE("overdue") }

    /** Um welches Datum eines Eintrags es bei der Zeit geht. */
    enum class DateField { CREATED, DUE, DONE, AUTO }

    val isStructured: Boolean get() = kinds.isNotEmpty() || bucketIDs.isNotEmpty() || inbox || todo != null || range != null

    /** Ob ein Eintrag einer ist, nach dem die Frage fragt. */
    fun matches(document: ChatDocument, now: Long = System.currentTimeMillis(), zone: ZoneId = ZoneId.systemDefault()): Boolean {
        if (kinds.isNotEmpty() && document.kind !in kinds) return false
        if (bucketIDs.isNotEmpty() || inbox) {
            val inBucket = document.bucketIDs.any { it in bucketIDs }
            val inInbox = inbox && document.bucketIDs.isEmpty()
            if (!inBucket && !inInbox) return false
        }
        if (document.kind == ChatDocument.Kind.TODO && todo != null) {
            when (todo) {
                TodoFilter.OPEN -> if (!document.isOpenTodo) return false
                TodoFilter.DONE -> if (!document.isDoneTodo) return false
                TodoFilter.OVERDUE -> {
                    val due = document.dueDay
                    if (!document.isOpenTodo || due == null || Todos.dueStatus(due, now, zone) != Todos.DueStatus.OVERDUE) return false
                }
            }
        }
        if (range != null) {
            val due = document.dueDay?.let { Todos.dueStart(it, zone) }
            val date = when (dateField) {
                DateField.DUE -> due
                DateField.DONE -> document.doneAt
                DateField.CREATED -> document.createdAt
                DateField.AUTO -> if (document.kind == ChatDocument.Kind.TODO) (due ?: document.createdAt) else document.createdAt
            }
            if (date == null || date !in range) return false
        }
        return true
    }

    /** Die Filter in Worten, für das Modell: „kind: to-do; to-do state: open; due between Mon 16 Nov 2026 and Sun 22 Nov 2026“. */
    fun describe(bucketNames: Map<String, String>, zone: ZoneId = ZoneId.systemDefault()): String {
        val parts = mutableListOf<String>()
        if (kinds.isNotEmpty()) parts += "kind: " + ChatDocument.Kind.entries.filter { it in kinds }.joinToString(" or ") { it.label.lowercase() }
        todo?.let { parts += "to-do state: " + it.raw }
        val names = bucketIDs.mapNotNull { bucketNames[it] }.sorted() + (if (inbox) listOf("Inbox") else emptyList())
        if (names.isNotEmpty()) parts += "in " + names.joinToString(" or ")
        range?.let { span ->
            val last = Instant.ofEpochMilli(span.end).atZone(zone).toLocalDate().minusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
            val field = when (dateField) {
                DateField.DUE -> "due"
                DateField.DONE -> "done"
                DateField.CREATED -> "created"
                DateField.AUTO -> if (kinds == setOf(ChatDocument.Kind.TODO)) "due (or created, without a due day)" else "created"
            }
            val from = ChatDocument.dayText(span.start, zone)
            val to = ChatDocument.dayText(last, zone)
            parts += field + if (from == to) " on $from" else " between $from and $to"
        }
        return parts.joinToString("; ")
    }

    companion object {
        // Wortlisten. Ein Wort zählt als ganzes Wort der Frage, Bindestriche bleiben („to-dos“).
        val kindWords: Map<ChatDocument.Kind, Set<String>> = linkedMapOf(
            ChatDocument.Kind.TODO to setOf("todo", "todos", "to-do", "to-dos", "aufgabe", "aufgaben", "task", "tasks", "todo-liste", "to-do-liste", "todo-list", "to-do-list"),
            ChatDocument.Kind.LINK to setOf("link", "links", "lesezeichen", "bookmark", "bookmarks", "artikel", "article", "articles", "webseite", "webseiten", "website", "websites"),
            ChatDocument.Kind.MEETING to setOf("meeting", "meetings", "besprechung", "besprechungen", "aufnahme", "aufnahmen", "recording", "recordings", "transkript", "transkripte", "transcript", "transcripts", "call", "calls", "telefonat", "telefonate"),
            ChatDocument.Kind.IMAGE to setOf("bild", "bilder", "foto", "fotos", "image", "images", "photo", "photos", "screenshot", "screenshots"),
            ChatDocument.Kind.FILE to setOf("datei", "dateien", "file", "files", "pdf", "pdfs", "dokument", "dokumente", "document", "documents"),
        )
        val openWords = setOf("offen", "offene", "offenen", "offener", "open", "unerledigt", "unerledigte", "unerledigten", "ausstehend", "ausstehende", "pending", "anstehend", "anstehende")
        val doneWords = setOf("erledigt", "erledigte", "erledigten", "done", "completed", "finished", "abgehakt", "abgehakte", "abgeschlossen", "abgeschlossene", "geschafft")
        val overdueWords = setOf("überfällig", "überfällige", "überfälligen", "overdue", "verspätet", "late")
        val dueWords = setOf("fällig", "fällige", "fälligen", "due", "deadline", "deadlines", "frist", "fristen")
        val bucketWords = setOf("bucket", "buckets")
        /** Wie Foundation: Sonntag 1 … Samstag 7. */
        val weekdays: Map<String, Int> = mapOf(
            "sonntag" to 1, "montag" to 2, "dienstag" to 3, "mittwoch" to 4, "donnerstag" to 5, "freitag" to 6, "samstag" to 7, "sonnabend" to 7,
            "sunday" to 1, "monday" to 2, "tuesday" to 3, "wednesday" to 4, "thursday" to 5, "friday" to 6, "saturday" to 7,
        )

        /** Die Wörter einer Frage in Kleinbuchstaben, Bindestriche behalten. */
        fun words(question: String): List<String> =
            question.lowercase().split(Regex("""[^\p{L}\p{N}-]+""")).map { it.trim('-') }.filter { it.isNotEmpty() }

        /** Liest die Filter von [question]. [buckets]: die Namen, die eine Frage nennen kann (Bucket-ID → Name). */
        fun parse(question: String, buckets: Map<String, String> = emptyMap(), now: Long = System.currentTimeMillis(), zone: ZoneId = ZoneId.systemDefault()): ChatQuery {
            val all = words(question)
            val used = HashSet<Int>()
            val kinds = LinkedHashSet<ChatDocument.Kind>()
            val bucketIDs = LinkedHashSet<String>()
            var inbox = false
            var todo: TodoFilter? = null
            var dateField = DateField.AUTO

            for ((index, word) in all.withIndex()) {
                for ((kind, list) in kindWords) if (word in list) { kinds += kind; used += index }
                if (word in openWords) { todo = todo ?: TodoFilter.OPEN; used += index }
                if (word in doneWords) { todo = TodoFilter.DONE; used += index }
                if (word in overdueWords) { todo = TodoFilter.OVERDUE; used += index }
                if (word in dueWords) { dateField = DateField.DUE; used += index }
                if (word in bucketWords) used += index
                if (word == "inbox") { inbox = true; used += index }
            }

            // Ein in der Frage genannter Bucket, mit seinem ganzen Namen („Reisen“, „Haus und Garten“).
            for ((id, name) in buckets) {
                val nameWords = words(name)
                if (nameWords.isEmpty() || nameWords.size > all.size) continue
                for (start in 0..(all.size - nameWords.size)) {
                    if (all.subList(start, start + nameWords.size) == nameWords) {
                        bucketIDs += id
                        used += start until start + nameWords.size
                    }
                }
            }

            var range: DaySpan? = null
            timeRange(all, question, dateField == DateField.DUE || todo == TodoFilter.OPEN, now, zone)?.let { (span, consumed) ->
                range = span
                used += consumed
            }

            // Ein fälliger Tag oder ein To-do-Stand geht um To-dos.
            if (dateField == DateField.DUE || todo == TodoFilter.OVERDUE) kinds += ChatDocument.Kind.TODO
            if (todo != null && kinds.isEmpty()) kinds += ChatDocument.Kind.TODO
            // Eine Liste von To-dos ist eine Liste dessen, was offen ist, außer erledigte sind gefragt.
            if (kinds == setOf(ChatDocument.Kind.TODO) && todo == null) todo = TodoFilter.OPEN
            if (todo == TodoFilter.DONE && range != null && dateField == DateField.AUTO) dateField = DateField.DONE

            val rest = all.filterIndexed { index, _ -> index !in used }.joinToString(" ")
            return ChatQuery(kinds, bucketIDs, inbox, todo, range, dateField, ChatLogic.queryWords(rest).distinct())
        }

        /**
         * Die Zeit, die eine Frage nennt, als Spanne von Tagen, und die Stellen der Wörter, aus denen sie gelesen wurde.
         * [future] liest einen Wochentag als den nächsten (ein fälliger Tag), sonst als den letzten („das Meeting am Dienstag“).
         */
        fun timeRange(words: List<String>, question: String, future: Boolean, now: Long, zone: ZoneId): Pair<DaySpan, List<Int>>? {
            val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
            fun ms(date: LocalDate) = date.atStartOfDay(zone).toInstant().toEpochMilli()
            fun days(from: Int, to: Int) = DaySpan(ms(today.plusDays(from.toLong())), ms(today.plusDays(to.toLong())))
            val weekday = today.dayOfWeek.value % 7 + 1
            val monday = -((weekday + 5) % 7)
            val thisMonth = today.withDayOfMonth(1)
            fun month(offset: Int): DaySpan {
                val start = thisMonth.plusMonths(offset.toLong())
                return DaySpan(ms(start), ms(start.plusMonths(1)))
            }
            fun index(phrase: String): List<Int>? {
                val parts = phrase.split(" ")
                if (parts.size > words.size) return null
                for (start in 0..(words.size - parts.size)) {
                    if (words.subList(start, start + parts.size) == parts) return (start until start + parts.size).toList()
                }
                return null
            }
            fun first(phrases: List<String>): List<Int>? = phrases.firstNotNullOfOrNull { index(it) }

            // Ein geschriebenes Datum: „17.11.“, „17.11.2026“, „2026-11-17“.
            val patterns = listOf(Regex("""\b(\d{4})-(\d{2})-(\d{2})\b"""), Regex("""\b(\d{1,2})\.(\d{1,2})\.(\d{2,4})?"""))
            for ((number, pattern) in patterns.withIndex()) {
                val match = pattern.find(question) ?: continue
                fun value(group: Int) = match.groups[group]?.value?.toIntOrNull()
                var year = if (number == 0) value(1) else value(3)
                val monthOfYear = value(2)
                val dayOfMonth = if (number == 0) value(3) else value(1)
                if (year != null && year < 100) year += 2000
                if (monthOfYear != null && dayOfMonth != null) {
                    // Nachsichtig wie Foundation: Der 32.1. ist der 1.2.
                    val start = LocalDate.of(year ?: today.year, 1, 1).plusMonths(monthOfYear - 1L).plusDays(dayOfMonth - 1L)
                    val consumed = words.indices.filter { i -> words[i].all { it.isDigit() } }
                    return DaySpan(ms(start), ms(start.plusDays(1))) to consumed
                }
            }

            // „der letzten 3 Tage“, „last two weeks“, „next 5 days“
            val numbers = mapOf(
                "zwei" to 2, "drei" to 3, "vier" to 4, "fünf" to 5, "sechs" to 6, "sieben" to 7, "acht" to 8, "neun" to 9, "zehn" to 10,
                "two" to 2, "three" to 3, "four" to 4, "five" to 5, "six" to 6, "seven" to 7, "eight" to 8, "nine" to 9, "ten" to 10,
            )
            val ahead = setOf("nächsten", "nächste", "kommenden", "kommende", "next", "coming")
            for (i in 0 until words.size - 1) {
                val count = words[i].toIntOrNull() ?: numbers[words[i]] ?: continue
                if (count <= 0 || count >= 1000) continue
                val unit = words[i + 1]
                val forward = i > 0 && words[i - 1] in ahead
                val length = when (unit) {
                    "tag", "tage", "tagen", "day", "days" -> count
                    "woche", "wochen", "week", "weeks" -> 7 * count
                    "monat", "monate", "monaten", "month", "months" -> 30 * count
                    else -> continue
                }
                val lead = ahead + setOf("letzten", "letzte", "vergangenen", "last", "past")
                val consumed = (if (i > 0 && words[i - 1] in lead) listOf(i - 1) else emptyList()) + listOf(i, i + 1)
                return (if (forward) days(0, length + 1) else days(-length, 1)) to consumed
            }

            val table: List<Pair<List<String>, DaySpan>> = listOf(
                listOf("übermorgen", "day after tomorrow") to days(2, 3),
                listOf("vorgestern", "day before yesterday") to days(-2, -1),
                listOf("heute", "today", "tonight") to days(0, 1),
                listOf("gestern", "yesterday") to days(-1, 0),
                listOf("morgen", "tomorrow") to days(1, 2),
                listOf("nächste woche", "nächsten woche", "kommende woche", "kommenden woche", "next week", "coming week") to days(monday + 7, monday + 14),
                listOf("letzte woche", "letzten woche", "letzter woche", "vergangene woche", "vergangenen woche", "last week", "past week") to days(monday - 7, monday),
                listOf("diese woche", "dieser woche", "diesen woche", "this week") to days(monday, monday + 7),
                listOf("nächsten monat", "nächster monat", "kommenden monat", "next month") to month(1),
                listOf("letzten monat", "letzter monat", "letzte monat", "vergangenen monat", "last month", "past month") to month(-1),
                listOf("diesen monat", "diesem monat", "dieser monat", "this month") to month(0),
                listOf(
                    "letzten tage", "letzte tage", "letzten tagen", "vergangenen tage", "vergangenen tagen", "paar tage", "paar tagen",
                    "letzter zeit", "letzten zeit", "kürzlich", "neulich", "zuletzt",
                    "last days", "last few days", "past days", "past few days", "recent", "recently", "lately",
                ) to days(-7, 1),
            )
            for ((phrases, span) in table) first(phrases)?.let { return span to it }

            // „am Dienstag“, „on Friday“: der letzte solche Tag, oder der nächste für einen fälligen Tag.
            for ((i, word) in words.withIndex()) {
                val target = weekdays[word] ?: continue
                val back = (weekday - target + 7) % 7
                val offset = if (future) (target - weekday + 7) % 7 else -back
                val consumed = mutableListOf(i)
                if (i > 0 && words[i - 1] in setOf("am", "on", "letzten", "last", "nächsten", "next", "diesen", "this")) consumed.add(0, i - 1)
                return days(offset, offset + 1) to consumed
            }
            return null
        }
    }
}

/** iOS: `ChatContextItem` — ein nummerierter Punkt, den das Modell liest: ein Eintrag der Trefferliste ([isListing]) oder eine Passage. */
data class ChatContextItem(
    val noteID: String,
    val title: String,
    val date: Long,
    val header: String,
    val text: String,
    val isListing: Boolean,
    /** Eine Passage eines Eintrags außerhalb der Filter, angeboten, weil darin nichts die Wörter hatte. */
    val isOutside: Boolean = false,
)

/** iOS: `ChatContext`. */
data class ChatContext(
    val items: List<ChatContextItem> = emptyList(),
    /** Wie viele Einträge zu den Filtern passen; null für eine Frage ohne Filter. */
    val matched: Int? = null,
    /** Die Filter in Worten (`ChatQuery.describe`). */
    val filter: String = "",
    /**
     * Die Frage hatte Wörter zum Suchen, aber keine Passage hatte sie: Die neuesten Einträge stehen ein, und eine Antwort,
     * die keinen davon nennt, bekommt keine Quellen (`ChatLogic.sources`).
     */
    val wordsNotFound: Boolean = false,
    val query: ChatQuery = ChatQuery(),
) {
    val isEmpty: Boolean get() = items.isEmpty()
}

/** iOS: `ChatBudget` (Services/ChatDocument.swift) — wie viel Zusammenhang ein Modell bekommt. Ein Cloud-Modell hat viel Platz. */
data class ChatBudget(
    /** Höchstens so viele Einträge werden für eine Frage mit Filtern aufgezählt; das Modell erfährt, wenn es mehr sind. */
    val listLimit: Int,
    /** Die Passagen der Treffer füllen den Zusammenhang bis zu so vielen Zeichen. */
    val fillBudget: Int,
    /** Passagen von Einträgen außerhalb der Filter, wenn kein Treffer die Wörter der Frage hat. */
    val outsideBudget: Int,
    /** Passagen für eine Frage ohne Filter: so viele Zeichen, höchstens [maxPassages]. */
    val searchBudget: Int,
    val maxPassages: Int,
    /** Der ganze Prompt wird bei so vielen Zeichen gekürzt (`ChatLogic.user`). */
    val promptLimit: Int,
) {
    companion object {
        /** Lokale Modelle. (Das Apple-Modell mit seinen 7000 Zeichen, iOS `small`, gibt es auf Android nicht.) */
        val STANDARD = ChatBudget(40, 6500, 3000, 6500, 10, Int.MAX_VALUE)
        /** Cloud-Modelle: etwa dreimal so viel Platz (gut in ihren Kontextfenstern, ein paar Cent je Frage). */
        val LARGE = ChatBudget(100, 20000, 8000, 20000, 30, 100_000)

        fun of(model: de.letzgo.porridge.cloud.SummaryModel): ChatBudget = if (model.isLocal) STANDARD else LARGE
    }
}

/**
 * iOS: `ChatRetrieval.context` (Services/ChatDocument.swift) — der Zusammenhang, aus dem eine Frage beantwortet wird. Mit
 * Filtern (Art, Bucket, To-do-Stand, Zeit) wird jeder passende Eintrag aufgezählt (bis [ChatBudget.listLimit]), dann die Passagen
 * der Treffer mit den Wörtern der Frage, dann weitere Passagen der ersten Treffer; hat kein Treffer die Wörter, folgen die
 * besten Passagen aller Einträge, als außerhalb markiert. Ohne Filter die besten Passagen aller Einträge (`select`).
 */
fun ChatLogic.context(
    question: String, documents: Map<String, ChatDocument>, chunks: List<NoteChunk>, bucketNames: Map<String, String>,
    now: Long = System.currentTimeMillis(), zone: ZoneId = ZoneId.systemDefault(), budget: ChatBudget = ChatBudget.STANDARD,
): ChatContext {
    val query = ChatQuery.parse(question, bucketNames, now, zone)
    fun item(chunk: NoteChunk, outside: Boolean = false): ChatContextItem? {
        val document = documents[chunk.noteID] ?: return null
        return ChatContextItem(chunk.noteID, document.title, document.createdAt, document.header(bucketNames, now, zone), chunk.text, false, outside)
    }

    if (!query.isStructured) {
        val (picked, isNewest) = selection(question, chunks, now, zone, budget.searchBudget, budget.maxPassages)
        return ChatContext(picked.mapNotNull { item(it) }, wordsNotFound = isNewest && queryWords(question).isNotEmpty(), query = query)
    }

    val filter = query.describe(bucketNames, zone)
    var matches = order(documents.values.filter { query.matches(it, now, zone) }, todosFirst = ChatDocument.Kind.TODO in query.kinds || query.todo != null)
    val matched = matches.size
    // Mit Wörtern zum Suchen dazu („Links über Swift“) bleibt die Liste vollständig, aber die Einträge mit den Wörtern
    // kommen zuerst (die meisten Wörter zuerst) und sagen, welche.
    val mentions = HashMap<String, List<String>>()
    if (query.words.isNotEmpty()) {
        val byNote = chunks.groupBy { it.noteID }
        for (document in matches) {
            val hits = query.words.filter { word -> byNote[document.noteID]?.any { NoteChunks.frequency(word, it) > 0 } ?: false }
            if (hits.isNotEmpty()) mentions[document.noteID] = hits
        }
        matches = matches.sortedByDescending { mentions[it.noteID]?.size ?: 0 }
    }
    if (matches.isEmpty()) {
        // Nichts ist, wonach die Filter fragen: die besten Passagen aller Einträge, so markiert.
        return ChatContext(search(query.words, chunks, budget.searchBudget, budget.maxPassages).mapNotNull { item(it, outside = true) }, 0, filter, query = query)
    }

    val items = mutableListOf<ChatContextItem>()
    for (document in matches.take(budget.listLimit)) {
        val mention = mentions[document.noteID]?.let { (if (document.snippet.isEmpty()) "" else " — ") + "mentions: " + it.joinToString(", ") } ?: ""
        items += ChatContextItem(document.noteID, document.title, document.createdAt, document.header(bucketNames, now, zone), document.snippet + mention, isListing = true)
    }

    val ids = matches.map { it.noteID }.toSet()
    val inside = chunks.filter { it.noteID in ids }
    var used = 0
    val taken = HashSet<String>()
    fun add(chunk: NoteChunk) {
        if (!taken.add(chunk.noteID + chunk.text)) return
        val next = item(chunk) ?: return
        items += next
        used += chunk.text.length
    }
    // Die Listenzeilen tragen Titel, Link, Dateien und To-do-Stand: Hier nehmen nur Passagen mit Inhalt Plätze ein.
    val found = if (query.words.isEmpty()) emptyList() else search(query.words, inside.filter { it.part.fillsContext }, budget.searchBudget, budget.maxPassages)
    found.forEach(::add)
    // Die ersten Treffer mit mehr von dem, was sie halten: wenige Einträge bekommen viele Passagen, viele Einträge wenige.
    val perEntry = if (matches.size <= 2) 12 else if (matches.size <= 5) 4 else 2
    val byNote = inside.groupBy { it.noteID }
    fill@ for (document in matches.take(8)) {
        var count = 0
        for (chunk in byNote[document.noteID].orEmpty()) {
            if (!chunk.part.fillsContext) continue
            if (count >= perEntry) break
            if (used + chunk.text.length > budget.fillBudget) break@fill
            add(chunk)
            count += 1
        }
    }
    if (query.words.isNotEmpty() && found.isEmpty()) {
        items += search(query.words, chunks.filter { it.noteID !in ids }, budget.outsideBudget, budget.maxPassages).mapNotNull { item(it, outside = true) }
    }
    return ChatContext(items, matched, filter, query = query)
}

/**
 * iOS: `ChatRetrieval.order` — offene To-dos nach fälligem Tag (ohne zuletzt), dann erledigte nach Erledigt-Zeit, der Rest
 * neueste zuerst; To-dos zuerst, wenn die Frage um sie geht.
 */
fun ChatLogic.order(documents: List<ChatDocument>, todosFirst: Boolean): List<ChatDocument> {
    val open = documents.filter { it.kind == ChatDocument.Kind.TODO && it.isOpenTodo }
        .sortedWith(compareBy<ChatDocument> { it.dueDay == null }.thenBy { it.dueDay ?: "" }.thenByDescending { it.createdAt })
    val done = documents.filter { it.kind == ChatDocument.Kind.TODO && !it.isOpenTodo }.sortedByDescending { it.doneAt ?: it.createdAt }
    val others = documents.filter { it.kind != ChatDocument.Kind.TODO }.sortedByDescending { it.createdAt }
    return if (todosFirst) open + done + others else others + open + done
}
