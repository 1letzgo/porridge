package de.letzgo.porridge.store

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * Altbestand, den Room nicht öffnen kann, darf die App nicht abstürzen lassen und keine Notizen verlieren
 * ([DatabaseRepair]). Die Datenbanken entstehen aus den exportierten Schemas in `app/schemas/`, verändert wie von einem
 * früheren Entwicklungs-Build.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class DatabaseRepairTest {
    private lateinit var context: Context
    private val name = "repair-test.db"
    private var opened: PorridgeDatabase? = null

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        cleanUp()
    }

    @After
    fun tearDown() {
        opened?.close()
        cleanUp()
    }

    private fun cleanUp() {
        context.getDatabasePath(name).parentFile?.listFiles()?.filter { it.name.startsWith(name) }?.forEach { it.delete() }
    }

    private fun open(): PorridgeDatabase =
        DatabaseRepair.open(context, name) { PorridgeDatabase.builder(context, it).allowMainThreadQueries().build() }.also { opened = it }

    private fun backups() = context.getDatabasePath(name).parentFile!!.listFiles()!!.filter { it.name.startsWith("$name.backup-") && !it.name.endsWith("-wal") && !it.name.endsWith("-shm") }

    @Test
    fun sameVersionWithOtherSchemaKeepsNotes() {
        // Version 11 eines Entwicklungs-Builds: Notizen ohne Vorschläge, eine To-do-Tabelle, keine Chat-Nachrichten.
        create(11, hash = "development-build") { table, sql ->
            when (table) {
                "notes" -> sql.replace(", `suggestedProjectIDs` TEXT NOT NULL", ", `remindAt` INTEGER")
                "chat_entries" -> null
                else -> sql
            }
        }
        write { db ->
            db.execSQL("CREATE TABLE todos (id TEXT NOT NULL PRIMARY KEY, text TEXT NOT NULL)")
            db.execSQL("INSERT INTO todos VALUES ('T1', 'Call Anna')")
        }
        insertNote("N1", "Budget meeting", projects = "[\"P1\"]")
        insertNote("N2", "Shopping list")
        insertFolder("P1", "Work")

        val notes = runBlocking { open().notes().all() }.sortedBy { it.id }
        assertEquals(listOf("N1", "N2"), notes.map { it.id })
        assertEquals("Budget meeting", notes[0].title)
        assertEquals(listOf("P1"), notes[0].projectIDs)
        assertEquals(emptyList<String>(), notes[0].suggestedProjectIDs)
        assertEquals(listOf("Work"), runBlocking { opened!!.folders().all() }.map { it.name })
        // Die alte Datei liegt unverändert daneben, mit den To-dos.
        val backup = backups().single()
        SQLiteDatabase.openDatabase(backup.path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
            db.rawQuery("SELECT COUNT(*) FROM todos", null).use { it.moveToFirst(); assertEquals(1, it.getInt(0)) }
        }
    }

    @Test
    fun failingMigrationKeepsNotes() {
        // Version 9 ohne `filedAt`: MIGRATION_9_10 kopiert diese Spalte und scheitert.
        create(9) { table, sql -> if (table == "notes") sql.replace(", `filedAt` INTEGER", "") else sql }
        insertNote("N1", "Old note")

        val notes = runBlocking { open().notes().all() }
        assertEquals(listOf("Old note"), notes.map { it.title })
        assertEquals(1, backups().size)
    }

    @Test
    fun newerVersionKeepsNotes() {
        // Ein Build mit Version 12 lag schon auf dem Gerät: Room kennt keinen Weg zurück.
        create(11, version = 12, hash = "future")
        insertNote("N1", "From the future")

        assertEquals(listOf("From the future"), runBlocking { open().notes().all() }.map { it.title })
        assertEquals(1, backups().size)
    }

    @Test
    fun releasedVersionMigratesWithoutRepair() {
        // 1.1.4: Version 7. Die normalen Migrationen laufen, nichts wird gesichert.
        create(7)
        insertNote("N1", "From 1.1.4")

        val notes = runBlocking { open().notes().all() }
        assertEquals(listOf("From 1.1.4"), notes.map { it.title })
        assertTrue(backups().isEmpty())
    }

    // Aufbau

    private fun write(block: (SQLiteDatabase) -> Unit) {
        SQLiteDatabase.openOrCreateDatabase(context.getDatabasePath(name).apply { parentFile?.mkdirs() }, null).use(block)
    }

    /** Legt die Datenbank nach `schemas/<schema>.json` an; [edit] ändert oder streicht (null) die Tabellen. */
    private fun create(schema: Int, version: Int = schema, hash: String? = null, edit: (String, String) -> String? = { _, sql -> sql }) {
        val file = listOf("schemas", "app/schemas", "android/app/schemas").map { File(it, "de.letzgo.porridge.store.PorridgeDatabase/$schema.json") }.first { it.exists() }
        val database = Json.parseToJsonElement(file.readText()).jsonObject.getValue("database").jsonObject
        write { db ->
            for (entity in database.getValue("entities").jsonArray) {
                val table = entity.jsonObject.getValue("tableName").jsonPrimitive.content
                val sql = edit(table, entity.jsonObject.getValue("createSql").jsonPrimitive.content.replace("\${TABLE_NAME}", table)) ?: continue
                db.execSQL(sql)
            }
            db.execSQL("CREATE TABLE IF NOT EXISTS room_master_table (id INTEGER PRIMARY KEY,identity_hash TEXT)")
            db.execSQL("INSERT OR REPLACE INTO room_master_table (id,identity_hash) VALUES(42, ?)", arrayOf(hash ?: database.getValue("identityHash").jsonPrimitive.content))
            db.version = version
        }
    }

    private fun insertNote(id: String, title: String, projects: String = "[]") = insert("notes", mapOf("id" to id, "title" to title, "projectIDs" to projects))

    private fun insertFolder(id: String, name: String) = insert("folders", mapOf("id" to id, "name" to name))

    /** Füllt jede Pflichtspalte mit einem Wert ihres Typs, damit die Zeile zu jeder Schemaversion passt. */
    private fun insert(table: String, values: Map<String, Any>) = write { db ->
        val row = linkedMapOf<String, Any>()
        db.rawQuery("PRAGMA table_info(`$table`)", null).use { cursor ->
            while (cursor.moveToNext()) {
                val column = cursor.getString(1)
                val type = cursor.getString(2)
                if (cursor.getInt(3) == 0) continue
                row[column] = when {
                    column.endsWith("IDs") || column == "labels" || column == "audioFileNames" -> "[]"
                    type.contains("INT") -> 0
                    type.contains("REAL") -> 0.0
                    else -> ""
                }
            }
        }
        row.putAll(values)
        db.execSQL("INSERT INTO `$table` (${row.keys.joinToString { "`$it`" }}) VALUES (${row.keys.joinToString { "?" }})", row.values.toTypedArray())
    }
}
