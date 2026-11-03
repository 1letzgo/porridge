package de.letzgo.porridge.store

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.TypeConverters
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder
import de.letzgo.porridge.model.VoiceProfile

/**
 * iOS: `AppContainer` (SwiftData + CloudKit). Auf Android eine lokale Room-Datenbank ohne Sync;
 * Sicherung über `data/Backup.kt`. Schema in `app/schemas/` (Migrationen ab Version 2 dort prüfen).
 */
@Database(entities = [Note::class, NoteFolder::class, VoiceProfile::class], version = 7, exportSchema = true)
@TypeConverters(Converters::class)
abstract class PorridgeDatabase : RoomDatabase() {
    abstract fun notes(): NoteDao
    abstract fun folders(): FolderDao
    abstract fun voiceProfiles(): VoiceProfileDao

    companion object {
        @Volatile private var instance: PorridgeDatabase? = null

        val shared: PorridgeDatabase get() = checkNotNull(instance) { "PorridgeDatabase.init fehlt" }

        fun init(context: Context) {
            if (instance != null) return
            instance = Room.databaseBuilder(context.applicationContext, PorridgeDatabase::class.java, "porridge.db")
                .addMigrations(MIGRATION_1_2, MIGRATION_2_3, MIGRATION_3_4, MIGRATION_4_5, MIGRATION_5_6, MIGRATION_6_7)
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

        /** Projekte: Notizen und Aufgaben gehören zu Projekten (den früheren Ordnern), die einen Änderungszeitpunkt bekommen. */
        val MIGRATION_3_4 = object : Migration(3, 4) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE notes ADD COLUMN projectIDs TEXT NOT NULL DEFAULT '[]'")
                db.execSQL("ALTER TABLE action_items ADD COLUMN projectIDs TEXT NOT NULL DEFAULT '[]'")
                db.execSQL("ALTER TABLE folders ADD COLUMN updatedAt INTEGER NOT NULL DEFAULT 0")
            }
        }

        /** Archiv: Notizen, Aufgaben und Projekte lassen sich archivieren. */
        val MIGRATION_4_5 = object : Migration(4, 5) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE notes ADD COLUMN archivedAt INTEGER")
                db.execSQL("ALTER TABLE action_items ADD COLUMN archivedAt INTEGER")
                db.execSQL("ALTER TABLE folders ADD COLUMN archivedAt INTEGER")
            }
        }

        /** Projekte lassen sich anheften. */
        val MIGRATION_5_6 = object : Migration(5, 6) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE folders ADD COLUMN isPinned INTEGER NOT NULL DEFAULT 0")
            }
        }

        /** Aufgaben gibt es nur noch als Zeilen der Zusammenfassung: die Tabelle und alles darin geht. */
        val MIGRATION_6_7 = object : Migration(6, 7) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("DROP TABLE IF EXISTS action_items")
            }
        }

        /** Für Tests: eine Datenbank im Speicher. */
        fun inMemory(context: Context): PorridgeDatabase =
            Room.inMemoryDatabaseBuilder(context, PorridgeDatabase::class.java).allowMainThreadQueries().build().also { instance = it }
    }
}
