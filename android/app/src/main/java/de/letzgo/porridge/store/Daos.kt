package de.letzgo.porridge.store

import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Query
import androidx.room.Upsert
import de.letzgo.porridge.model.ActionItem
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder
import de.letzgo.porridge.model.VoiceProfile
import kotlinx.coroutines.flow.Flow

@Dao
interface NoteDao {
    /** Alle Notizen, neueste zuerst (iOS: `@Query(sort: \Note.updatedAt, order: .reverse)`). */
    @Query("SELECT * FROM notes ORDER BY updatedAt DESC")
    fun observeAll(): Flow<List<Note>>

    @Query("SELECT * FROM notes")
    suspend fun all(): List<Note>

    @Query("SELECT * FROM notes WHERE id = :id")
    suspend fun get(id: String): Note?

    @Query("SELECT * FROM notes WHERE id = :id")
    fun observe(id: String): Flow<Note?>

    @Query("SELECT * FROM notes WHERE deletedAt IS NOT NULL")
    suspend fun trashed(): List<Note>

    @Query("SELECT * FROM notes WHERE statusRaw IN ('recorded', 'transcribing') AND deletedAt IS NULL")
    suspend fun unfinished(): List<Note>

    @Upsert
    suspend fun upsert(note: Note)

    @Upsert
    suspend fun upsertAll(notes: List<Note>)

    @Delete
    suspend fun delete(note: Note)
}

@Dao
interface FolderDao {
    @Query("SELECT * FROM folders")
    fun observeAll(): Flow<List<NoteFolder>>

    @Query("SELECT * FROM folders")
    suspend fun all(): List<NoteFolder>

    @Query("SELECT COUNT(*) FROM folders WHERE id = :id")
    suspend fun count(id: String): Int

    @Upsert
    suspend fun upsert(folder: NoteFolder)

    @Upsert
    suspend fun upsertAll(folders: List<NoteFolder>)

    @Query("DELETE FROM folders WHERE id IN (:ids)")
    suspend fun deleteAll(ids: Collection<String>)
}

@Dao
interface VoiceProfileDao {
    @Query("SELECT * FROM voice_profiles ORDER BY name")
    fun observeAll(): Flow<List<VoiceProfile>>

    @Query("SELECT * FROM voice_profiles")
    suspend fun all(): List<VoiceProfile>

    @Upsert
    suspend fun upsert(profile: VoiceProfile)

    @Upsert
    suspend fun upsertAll(profiles: List<VoiceProfile>)

    @Delete
    suspend fun delete(profile: VoiceProfile)
}

@Dao
interface ActionItemDao {
    @Query("SELECT * FROM action_items ORDER BY createdAt DESC, `order`")
    fun observeAll(): Flow<List<ActionItem>>

    @Query("SELECT * FROM action_items")
    suspend fun all(): List<ActionItem>

    @Query("SELECT * FROM action_items WHERE id = :id")
    suspend fun get(id: String): ActionItem?

    @Query("SELECT * FROM action_items WHERE id = :id")
    fun observe(id: String): Flow<ActionItem?>

    @Query("SELECT * FROM action_items WHERE noteID = :noteID ORDER BY `order`")
    suspend fun forNote(noteID: String): List<ActionItem>

    @Upsert
    suspend fun upsert(item: ActionItem)

    @Upsert
    suspend fun upsertAll(items: List<ActionItem>)

    @Delete
    suspend fun delete(item: ActionItem)

    @Query("DELETE FROM action_items WHERE noteID = :noteID")
    suspend fun deleteForNote(noteID: String)
}
