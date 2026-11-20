package de.letzgo.porridge.store

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.TypeConverters
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import de.letzgo.porridge.model.ChatEntry
import de.letzgo.porridge.model.ChatThread
import de.letzgo.porridge.model.Note
import de.letzgo.porridge.model.NoteFolder
import de.letzgo.porridge.model.VoiceProfile

/**
 * iOS: `AppContainer` (SwiftData). Auf Android eine lokale Room-Datenbank; der Abgleich läuft über `sync/NextcloudSync.kt`,
 * die Sicherung über `data/Backup.kt`. Schema in `app/schemas/` (Migrationen ab Version 2 dort prüfen).
 */
@Database(entities = [Note::class, NoteFolder::class, VoiceProfile::class, ChatThread::class, ChatEntry::class], version = 13, exportSchema = true)
@TypeConverters(Converters::class)
abstract class PorridgeDatabase : RoomDatabase() {
    abstract fun notes(): NoteDao
    abstract fun folders(): FolderDao
    abstract fun voiceProfiles(): VoiceProfileDao
    abstract fun chats(): ChatDao

    companion object {
        @Volatile private var instance: PorridgeDatabase? = null

        val shared: PorridgeDatabase get() = checkNotNull(instance) { "PorridgeDatabase.init fehlt" }

        const val FILE_NAME = "porridge.db"

        /**
         * Öffnet die Datenbank gleich beim Start (statt bei der ersten Abfrage irgendwo im Hintergrund): Lässt sie sich
         * nicht öffnen, baut [DatabaseRepair] sie aus ihren eigenen Daten neu auf, statt dass die App bei jedem Start abstürzt.
         */
        fun init(context: Context) {
            if (instance != null) return
            val app = context.applicationContext
            instance = DatabaseRepair.open(app, FILE_NAME) { name -> builder(app, name).build() }
        }

        /** Alle Migrationen; auch für Tests und den Neuaufbau in [DatabaseRepair]. */
        fun builder(context: Context, name: String): RoomDatabase.Builder<PorridgeDatabase> =
            Room.databaseBuilder(context, PorridgeDatabase::class.java, name)
                .addMigrations(MIGRATION_1_2, MIGRATION_2_3, MIGRATION_3_4, MIGRATION_4_5, MIGRATION_5_6, MIGRATION_6_7, MIGRATION_7_8, MIGRATION_8_9, MIGRATION_9_10, MIGRATION_10_11, MIGRATION_11_12, MIGRATION_12_13)

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

        /**
         * Eingang, Anhänge und To-dos: Notizen bekommen Kanal, Anhänge, Ablage, Bucket-Vorschläge und Erinnerung. Was in
         * keinem Bucket liegt, steht im Eingang. Die To-dos heißen
         * `todos`, nicht wie die früheren `action_items`.
         */
        val MIGRATION_7_8 = object : Migration(7, 8) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE notes ADD COLUMN sourceRaw TEXT NOT NULL DEFAULT ''")
                db.execSQL("ALTER TABLE notes ADD COLUMN attachmentsData TEXT")
                db.execSQL("ALTER TABLE notes ADD COLUMN filedAt INTEGER")
                db.execSQL("ALTER TABLE notes ADD COLUMN suggestedProjectIDs TEXT NOT NULL DEFAULT '[]'")
                db.execSQL("ALTER TABLE notes ADD COLUMN remindAt INTEGER")
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `todos` (`id` TEXT NOT NULL, `noteID` TEXT, `text` TEXT NOT NULL, `details` TEXT NOT NULL, " +
                        "`isDone` INTEGER NOT NULL, `doneAt` INTEGER, `dueAt` INTEGER, `remindAt` INTEGER, `createdAt` INTEGER NOT NULL, " +
                        "`updatedAt` INTEGER NOT NULL, `order` INTEGER NOT NULL, `source` TEXT NOT NULL, `summaryKey` TEXT, " +
                        "`reviewRaw` TEXT NOT NULL, `projectIDs` TEXT NOT NULL, `archivedAt` INTEGER, PRIMARY KEY(`id`))",
                )
            }
        }

        /** Kalender: Notizen kennen ihren Termin, To-dos ihre Erinnerung, und Termine bekommen Buckets (`event_refs`). */
        val MIGRATION_8_9 = object : Migration(8, 9) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE notes ADD COLUMN eventID TEXT")
                db.execSQL("ALTER TABLE notes ADD COLUMN eventStart INTEGER")
                db.execSQL("ALTER TABLE todos ADD COLUMN reminderID TEXT")
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `event_refs` (`id` TEXT NOT NULL, `eventID` TEXT NOT NULL, `eventStart` INTEGER, `title` TEXT NOT NULL, " +
                        "`start` INTEGER, `projectIDs` TEXT NOT NULL, `createdAt` INTEGER NOT NULL, `updatedAt` INTEGER NOT NULL, PRIMARY KEY(`id`))",
                )
            }
        }

        /**
         * To-dos, Kalendertermine und Erinnerungen gehen wieder: Aufgaben stehen nur als Zeilen in der Zusammenfassung, Termine nur im
         * Kalender. Die Tabellen `todos` und `event_refs` fallen weg, die Notizen verlieren `eventID`, `eventStart` und `remindAt` (auch die Erinnerungen gehen)
         * (dafür wird ihre Tabelle neu gebaut: SQLite kann Spalten erst in neueren Versionen streichen).
         */
        val MIGRATION_9_10 = object : Migration(9, 10) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("DROP TABLE IF EXISTS `todos`")
                db.execSQL("DROP TABLE IF EXISTS `event_refs`")
                val columns = "`id`, `title`, `text`, `createdAt`, `updatedAt`, `statusRaw`, `errorMessage`, `pendingAudioFileName`, `audioFileNames`, " +
                    "`folderID`, `projectIDs`, `isPinned`, `deletedAt`, `url`, `pageText`, `labels`, `summary`, `summaryModel`, `summarizedAt`, " +
                    "`titleIsCustom`, `duration`, `inputName`, `channelCount`, `speakerModeRaw`, `audioFileName`, `speakersData`, `segmentsData`, " +
                    "`archivedAt`, `sourceRaw`, `attachmentsData`, `filedAt`, `suggestedProjectIDs`"
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `notes_new` (`id` TEXT NOT NULL, `title` TEXT NOT NULL, `text` TEXT NOT NULL, `createdAt` INTEGER NOT NULL, " +
                        "`updatedAt` INTEGER NOT NULL, `statusRaw` TEXT NOT NULL, `errorMessage` TEXT, `pendingAudioFileName` TEXT, `audioFileNames` TEXT NOT NULL, " +
                        "`folderID` TEXT, `projectIDs` TEXT NOT NULL, `isPinned` INTEGER NOT NULL, `deletedAt` INTEGER, `url` TEXT, `pageText` TEXT, " +
                        "`labels` TEXT NOT NULL, `summary` TEXT, `summaryModel` TEXT, `summarizedAt` INTEGER, `titleIsCustom` INTEGER NOT NULL, " +
                        "`duration` REAL NOT NULL, `inputName` TEXT, `channelCount` INTEGER NOT NULL, `speakerModeRaw` TEXT NOT NULL, `audioFileName` TEXT, " +
                        "`speakersData` TEXT, `segmentsData` TEXT, `archivedAt` INTEGER, `sourceRaw` TEXT NOT NULL, `attachmentsData` TEXT, `filedAt` INTEGER, " +
                        "`suggestedProjectIDs` TEXT NOT NULL, PRIMARY KEY(`id`))",
                )
                db.execSQL("INSERT INTO `notes_new` ($columns) SELECT $columns FROM `notes`")
                db.execSQL("DROP TABLE `notes`")
                db.execSQL("ALTER TABLE `notes_new` RENAME TO `notes`")
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_notes_folderID` ON `notes` (`folderID`)")
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_notes_deletedAt` ON `notes` (`deletedAt`)")
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_notes_updatedAt` ON `notes` (`updatedAt`)")
            }
        }

        /** Der Chat mit den Notizen: mehrere Chats und ihre Nachrichten werden gehalten (nur auf diesem Gerät). */
        val MIGRATION_10_11 = object : Migration(10, 11) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `chat_threads` (`id` TEXT NOT NULL, `title` TEXT NOT NULL, `createdAt` INTEGER NOT NULL, " +
                        "`updatedAt` INTEGER NOT NULL, `projectID` TEXT, PRIMARY KEY(`id`))",
                )
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS `chat_entries` (`id` TEXT NOT NULL, `threadID` TEXT NOT NULL, `roleRaw` TEXT NOT NULL, `text` TEXT NOT NULL, " +
                        "`createdAt` INTEGER NOT NULL, `isError` INTEGER NOT NULL, `sourcesData` TEXT, PRIMARY KEY(`id`))",
                )
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_chat_entries_threadID` ON `chat_entries` (`threadID`)")
            }
        }

        /**
         * To-dos (iOS: `Note.todoStateRaw`, `todoDoneAt`, `todoSourceID`): eine Notiz mit Erledigt-Stand. Alle drei leer bei
         * bestehenden Notizen; sie waren nie To-dos. Andere Stände (frühere Entwicklungs-Builds) fängt `DatabaseRepair` ab.
         */
        val MIGRATION_11_12 = object : Migration(11, 12) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE notes ADD COLUMN todoStateRaw TEXT")
                db.execSQL("ALTER TABLE notes ADD COLUMN todoDoneAt INTEGER")
                db.execSQL("ALTER TABLE notes ADD COLUMN todoSourceID TEXT")
            }
        }

        /** Fällige Tage der To-dos (iOS: `Note.todoDueDay`), leer bei allen bestehenden Notizen. */
        val MIGRATION_12_13 = object : Migration(12, 13) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE notes ADD COLUMN todoDueDay TEXT")
            }
        }

        /** Für Tests: eine Datenbank im Speicher. */
        fun inMemory(context: Context): PorridgeDatabase =
            Room.inMemoryDatabaseBuilder(context, PorridgeDatabase::class.java).allowMainThreadQueries().build().also { instance = it }
    }
}
