package de.letzgo.porridge.store

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.TypeConverters
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import de.letzgo.porridge.model.ActionItem
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder
import de.letzgo.porridge.model.VoiceProfile

/**
 * iOS: `AppContainer` (SwiftData + CloudKit). Auf Android eine lokale Room-Datenbank ohne Sync;
 * Sicherung über `data/Backup.kt`. Schema in `app/schemas/` (Migrationen ab Version 2 dort prüfen).
 */
@Database(entities = [Note::class, NoteFolder::class, VoiceProfile::class, ActionItem::class], version = 3, exportSchema = true)
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
            instance = Room.databaseBuilder(context.applicationContext, PorridgeDatabase::class.java, "porridge.db")
                .addMigrations(MIGRATION_1_2, MIGRATION_2_3)
                .build()
        }

        /** Aufgaben bekommen eigenen Text, ihre Ursprungszeile und einen Änderungszeitpunkt (iOS da54c01). */
        val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE action_items ADD COLUMN details TEXT NOT NULL DEFAULT ''")
                db.execSQL("ALTER TABLE action_items ADD COLUMN summaryKey TEXT")
                db.execSQL("ALTER TABLE action_items ADD COLUMN updatedAt INTEGER NOT NULL DEFAULT 0")
                db.execSQL("UPDATE action_items SET updatedAt = createdAt")
            }
        }

        /** Neue Aufgaben aus Zusammenfassungen werden erst geprüft; alle vorhandenen gelten als übernommen. */
        val MIGRATION_2_3 = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE action_items ADD COLUMN reviewRaw TEXT NOT NULL DEFAULT 'accepted'")
            }
        }

        /** Für Tests: eine Datenbank im Speicher. */
        fun inMemory(context: Context): PorridgeDatabase =
            Room.inMemoryDatabaseBuilder(context, PorridgeDatabase::class.java).allowMainThreadQueries().build().also { instance = it }
    }
}
