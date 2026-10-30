package de.letzgo.porridge.logic

import java.text.DateFormat
import java.util.Date

/** iOS: `ChatSource`. */
data class ChatSource(val noteID: String, val title: String, val date: Long)

/** iOS: `ChatMessage`. */
data class ChatMessage(
    val role: Role,
    val text: String,
    val sources: List<ChatSource> = emptyList(),
    val isError: Boolean = false,
    val id: Long = System.nanoTime(),
) {
    enum class Role { USER, ASSISTANT }
}

/** iOS: Prompt- und Quellen-Teil von `ChatStore` (Services/ChatService.swift). */
object ChatPrompt {
    fun system(hasTasks: Boolean): String = """
        You are the assistant of a private notes app. Answer the question using only the excerpts from the user's notes and meeting transcripts below${if (hasTasks) ", and the list of tasks and decisions taken from their summaries" else ""}.
        Every excerpt starts with a number in brackets. Name the numbers of the excerpts you used, like [2].${if (hasTasks) " For a task or decision name the note it comes from." else ""}
        If the excerpts do not contain the answer, say so briefly. Answer in the language of the question and be concise.
    """.trimIndent()

    fun user(question: String, history: List<ChatMessage>, context: List<ChatChunk>, tasks: String): String = buildString {
        append(tasks)
        if (history.isNotEmpty()) {
            append("Conversation so far:\n")
            for (message in history) {
                append(if (message.role == ChatMessage.Role.USER) "User: " else "Assistant: ")
                append(message.text.take(500)).append("\n")
            }
            append("\n")
        }
        append("Excerpts:\n")
        val format = DateFormat.getDateInstance(DateFormat.MEDIUM)
        context.forEachIndexed { index, chunk ->
            append("[${index + 1}] «${chunk.title}» (${format.format(Date(chunk.date))})\n${chunk.text}\n\n")
        }
        append("Question: $question")
    }

    /** Die Notizen hinter den Passagen, die die Antwort als [n] zitiert; ohne Zitat die besten drei Treffer. */
    fun sources(answer: String, context: List<ChatChunk>): List<ChatSource> {
        val numbers = Regex("""\[([^\]]*)]""").findAll(answer)
            .flatMap { match -> match.groupValues[1].split(',', ' ').mapNotNull { it.trim().toIntOrNull() } }
            .toList()
        var indices = numbers.mapNotNull { if (it in 1..context.size) it - 1 else null }
        if (indices.isEmpty()) indices = context.indices.take(3)
        val seen = HashSet<String>()
        return indices.mapNotNull { index ->
            val chunk = context[index]
            if (seen.add(chunk.noteID)) ChatSource(chunk.noteID, chunk.title, chunk.date) else null
        }
    }
}
