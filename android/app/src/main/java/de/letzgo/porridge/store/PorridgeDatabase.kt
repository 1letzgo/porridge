package de.letzgo.porridge.store

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.TypeConverters
import de.letzgo.porridge.model.ActionItem
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder
import de.letzgo.porridge.model.VoiceProfile

/**
 * iOS: `AppContainer` (SwiftData + CloudKit). Auf Android eine lokale Room-Datenbank ohne Sync;
 * Sicherung über `data/Backup.kt`. Schema in `app/schemas/` (Migrationen ab Version 2 dort prüfen).
 */
@Database(entities = [Note::class, NoteFolder::class, VoiceProfile::class, ActionItem::class], version = 1, exportSchema = true)
@TypeConverters(Converters::class)
abstract class PorridgeDatabase : RoomDatabase() {
    abstract fun notes(): NoteDao
    abstract fun folders(): FolderDao
    abstract fun voiceProfiles(): VoiceProfileDao
    abstract fun actionItems(): ActionItemDao

    companion object {
        @Volatile private var instance: PorridgeDatabase? = null

        val shared: PorridgeDatabase get() = checkNotNull(instance) { "PorridgeDatabase.init fehlt" }

        fun init(context: Context) {
            if (instance != null) return
            instance = Room.databaseBuilder(context.applicationContext, PorridgeDatabase::class.java, "porridge.db").build()
        }

        /** Für Tests: eine Datenbank im Speicher. */
        fun inMemory(context: Context): PorridgeDatabase =
            Room.inMemoryDatabaseBuilder(context, PorridgeDatabase::class.java).allowMainThreadQueries().build().also { instance = it }
    }
}
