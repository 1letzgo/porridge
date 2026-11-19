package de.letzgo.porridge.store

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import de.letzgo.porridge.data.CrashLog
import java.io.File

/**
 * Öffnet die Datenbank so, dass Altbestand nie zum Absturz beim Start führt (nur Android).
 *
 * Lässt Room sie nicht öffnen (ein früherer Entwicklungs-Build hat sie auf eine Version mit anderem Schema gebracht, eine
 * Migration scheitert an einer fehlenden Spalte, eine neuere Version liegt vor, die Integritätsprüfung schlägt fehl), wird
 * sie neu aufgebaut: Die alte Datei wird zuerst als Sicherung kopiert, dann legt Room eine leere Datenbank mit dem
 * aktuellen Schema an, und jede Tabelle übernimmt aus der alten alle Spalten, die beide kennen. Was neu ist, bekommt den
 * Standardwert seines Typs. Das ist allgemein und gilt auch für künftige Schemaversionen.
 */
object DatabaseRepair {
    /** Room-eigene und SQLite-eigene Tabellen: die legt Room selbst an. */
    private val internalTables = setOf("android_metadata", "room_master_table", "sqlite_sequence")

    /** [build] baut Room für einen Dateinamen (in `getDatabasePath`), ohne sie zu öffnen. */
    fun <T : androidx.room.RoomDatabase> open(context: Context, name: String, build: (String) -> T): T {
        val database = build(name)
        val failure = try {
            database.openHelper.writableDatabase
            return database
        } catch (e: Exception) {
            e
        }
        runCatching { database.close() }
        CrashLog.note("Database \"$name\" could not be opened; rebuilding it from its own data.", failure)
        return rebuild(context, name, build)
    }

    private fun <T : androidx.room.RoomDatabase> rebuild(context: Context, name: String, build: (String) -> T): T {
        val original = context.getDatabasePath(name)
        // Was noch im Write-Ahead-Log steht, gehört in die Datei, bevor sie gesichert und gelesen wird.
        runCatching {
            SQLiteDatabase.openDatabase(original.path, null, SQLiteDatabase.OPEN_READWRITE).use { db ->
                db.rawQuery("PRAGMA wal_checkpoint(TRUNCATE)", null).use { it.moveToFirst() }
            }
        }
        // Ohne Sicherung wird nichts angefasst: Dann bleibt der Fehler, aber die Daten bleiben auch.
        val backup = File(original.parentFile, "$name.backup-${System.currentTimeMillis()}")
        // Die Datei und ihr Write-Ahead-Log (falls der Abschluss oben nicht ging); `-shm` und `-journal` sind nur Arbeitsdateien.
        listOf("", "-wal").map { File(original.path + it) }.forEach { file ->
            if (file.exists()) file.copyTo(File(backup.path + file.path.removePrefix(original.path)), overwrite = true)
        }
        check(backup.length() == original.length()) { "Could not back up the database before repairing it." }

        val repairName = "$name.repair"
        val repaired = context.getDatabasePath(repairName)
        companions(repaired).forEach { it.delete() }
        val copied = try {
            build(repairName).also { it.openHelper.writableDatabase }.close()
            copyRows(from = original, into = repaired)
        } catch (e: Exception) {
            // Nicht einmal das ging: neu anfangen. Die alte Datei liegt als Sicherung daneben.
            CrashLog.note("Could not copy the old data; starting with an empty database. Backup: ${backup.name}", e)
            companions(repaired).forEach { it.delete() }
            null
        }
        companions(original).forEach { it.delete() }
        if (copied != null) {
            companions(repaired).forEach { file -> if (file.exists()) file.renameTo(File(original.path + file.path.removePrefix(repaired.path))) }
            CrashLog.note("Database rebuilt: $copied. Backup of the old file: ${backup.name}")
        }
        val database = build(name)
        database.openHelper.writableDatabase
        return database
    }

    /** Die Datei und was SQLite neben ihr führt. */
    private fun companions(file: File) = listOf("", "-wal", "-shm", "-journal").map { File(file.path + it) }

    /**
     * Übernimmt jede Zeile jeder Tabelle von [from] in [into], soweit [into] die Tabelle kennt, und gibt eine kurze Zählung
     * zurück. Zeilen, deren Schlüssel schon da ist oder fehlt, werden ausgelassen.
     */
    internal fun copyRows(from: File, into: File): String {
        val counts = mutableListOf<String>()
        SQLiteDatabase.openDatabase(into.path, null, SQLiteDatabase.OPEN_READWRITE).use { db ->
            db.execSQL("ATTACH DATABASE ? AS old", arrayOf(from.path))
            try {
                val oldTables = names(db, "old").toSet()
                for (table in names(db, "main")) {
                    if (table !in oldTables) continue
                    val target = columns(db, "main", table)
                    val source = columns(db, "old", table).associateBy { it.name }
                    val keys = target.filter { it.primaryKey && it.name in source }
                    val selects = target.joinToString(", ") { column ->
                        val present = column.name in source
                        when {
                            present && column.notNull -> "COALESCE(${quote(column.name)}, ${column.fallback})"
                            present -> quote(column.name)
                            column.notNull -> column.fallback
                            else -> "NULL"
                        }
                    }
                    val where = if (keys.isEmpty()) "" else " WHERE " + keys.joinToString(" AND ") { "${quote(it.name)} IS NOT NULL" }
                    try {
                        db.execSQL(
                            "INSERT OR IGNORE INTO main.${quote(table)} (${target.joinToString(", ") { quote(it.name) }}) " +
                                "SELECT $selects FROM old.${quote(table)}$where",
                        )
                        val count = db.rawQuery("SELECT COUNT(*) FROM main.${quote(table)}", null).use { it.moveToFirst(); it.getLong(0) }
                        counts += "$table $count"
                    } catch (e: Exception) {
                        CrashLog.note("Could not take over table $table", e)
                        counts += "$table failed"
                    }
                }
            } finally {
                db.execSQL("DETACH DATABASE old")
            }
        }
        return counts.joinToString(", ")
    }

    private class Column(val name: String, val type: String, val notNull: Boolean, val default: String?, val primaryKey: Boolean) {
        /** Was eine Pflichtspalte bekommt, die in der alten Tabelle fehlt oder leer ist. */
        val fallback: String
            get() = default ?: when {
                type.contains("INT", ignoreCase = true) -> "0"
                type.contains("REAL", ignoreCase = true) || type.contains("FLOA", ignoreCase = true) || type.contains("DOUB", ignoreCase = true) -> "0.0"
                type.contains("BLOB", ignoreCase = true) -> "X''"
                else -> "''"
            }
    }

    private fun names(db: SQLiteDatabase, schema: String): List<String> =
        db.rawQuery("SELECT name FROM $schema.sqlite_master WHERE type = 'table'", null).use { cursor ->
            buildList { while (cursor.moveToNext()) add(cursor.getString(0)) }
        }.filter { it !in internalTables && !it.startsWith("sqlite_") }

    private fun columns(db: SQLiteDatabase, schema: String, table: String): List<Column> =
        db.rawQuery("PRAGMA $schema.table_info(${quote(table)})", null).use { cursor ->
            buildList {
                while (cursor.moveToNext()) {
                    add(
                        Column(
                            name = cursor.getString(cursor.getColumnIndexOrThrow("name")),
                            type = cursor.getString(cursor.getColumnIndexOrThrow("type")).orEmpty(),
                            notNull = cursor.getInt(cursor.getColumnIndexOrThrow("notnull")) != 0,
                            default = cursor.getString(cursor.getColumnIndexOrThrow("dflt_value")),
                            primaryKey = cursor.getInt(cursor.getColumnIndexOrThrow("pk")) != 0,
                        ),
                    )
                }
            }
        }

    private fun quote(name: String) = "`" + name.replace("`", "``") + "`"
}
