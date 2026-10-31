package de.letzgo.porridge.model

import androidx.room.Entity
import androidx.room.PrimaryKey
import kotlinx.serialization.Serializable
import java.text.Collator
import java.util.UUID

/**
 * iOS: `NoteFolder` — heute ein Projekt (früher Ordner). Notizen und Aufgaben verweisen über `projectIDs`;
 * `parentID` und `Note.folderID` bleiben nur für alte Daten.
 */
@Serializable
@Entity(tableName = "folders")
data class NoteFolder(
    @PrimaryKey val id: String = UUID.randomUUID().toString().uppercase(),
    val name: String = "",
    val createdAt: Long = System.currentTimeMillis(),
    val parentID: String? = null,
    /** Letzte Änderung (Anlegen, Umbenennen); 0 bei alten Ordnern. */
    val updatedAt: Long = 0,
)

/** iOS: `NoteScope` — was eine Liste zeigt: alles, einen Tag oder „Recently Deleted“. Ordner werden nicht mehr gezeigt; `NoteFolder` bleibt in der Datenbank. */
sealed interface NoteScope {
    data object All : NoteScope
    data class Tag(val name: String) : NoteScope
    data object Trash : NoteScope
}

/** iOS: `Array<NoteFolder>.tree` — Tiefensuche (Geschwister nach Namen) mit Ebene. */
fun List<NoteFolder>.tree(): List<Pair<NoteFolder, Int>> {
    val collator = Collator.getInstance().apply { strength = Collator.SECONDARY }
    val byParent = groupBy { it.parentID }
    val ids = map { it.id }.toSet()
    val result = mutableListOf<Pair<NoteFolder, Int>>()
    fun walk(parent: String?, depth: Int) {
        for (folder in (byParent[parent] ?: emptyList()).sortedWith { a, b -> collator.compare(a.name, b.name) }) {
            result += folder to depth
            walk(folder.id, depth + 1)
        }
    }
    walk(null, 0)
    // Ordner, deren Elternordner fehlt, erscheinen oben.
    for (orphan in this) {
        val parent = orphan.parentID ?: continue
        if (parent !in ids && result.none { it.first.id == orphan.id }) {
            result += orphan to 0
            walk(orphan.id, 1)
        }
    }
    return result
}

/** iOS: `path(of:)` — „Eltern › Kind“. */
fun List<NoteFolder>.path(folder: NoteFolder): String {
    val names = mutableListOf(folder.name)
    var current = folder
    var guardCount = 0
    while (guardCount < 20) {
        val parent = current.parentID?.let { id -> firstOrNull { it.id == id } } ?: break
        names.add(0, parent.name)
        current = parent
        guardCount++
    }
    return names.joinToString(" › ")
}

/** iOS: `subtreeIDs(of:)` — der Ordner und alles darunter. */
fun List<NoteFolder>.subtreeIDs(id: String): Set<String> {
    val ids = mutableSetOf(id)
    var added = true
    while (added) {
        added = false
        for (folder in this) {
            if (folder.id !in ids && folder.parentID != null && folder.parentID in ids) { ids += folder.id; added = true }
        }
    }
    return ids
}
