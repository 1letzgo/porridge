package de.letzgo.porridge.audio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import de.letzgo.porridge.MainActivity
import de.letzgo.porridge.R

/**
 * Ersatz für die Live Activity (iOS: `Shared/RecordingActivity.swift`, `PorridgeWidgets`, `LiveRecording.swift`):
 * ein Vordergrunddienst mit laufender Uhr und „Stop“ in der Benachrichtigung, solange aufgenommen wird. Läuft auch,
 * solange transkribiert oder ein Modell geladen wird, damit Android die App dabei nicht beendet.
 */
class RecordingService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                RecordingSession.requestStop()
                return START_NOT_STICKY
            }
            ACTION_UPDATE, null -> Unit
        }
        val recording = RecordingSession.isRecording
        if (!recording && !busy && downloads.isEmpty()) {
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        val type = if (recording && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification(recording), type)
        return START_NOT_STICKY
    }

    private fun notification(recording: Boolean): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL) == null) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Recording", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while Porridge records, transcribes or downloads a model."
                setShowBadge(false)
            })
        }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        val builder = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
        if (recording) {
            val stop = PendingIntent.getService(this, 1, Intent(this, RecordingService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
            builder.setContentTitle(RecordingSession.title.ifEmpty { "Recording" })
                .setContentText("Porridge is recording")
                .setUsesChronometer(true)
                .setWhen(RecordingSession.startedAt)
                .addAction(0, "Stop", stop)
        } else if (busy) {
            builder.setContentTitle("Transcribing …").setContentText("Porridge is working on your recordings").setProgress(0, 0, true)
        } else {
            val shown = downloads.toMap()
            val fraction = if (shown.isEmpty()) 0f else shown.values.sum() / shown.size
            builder.setContentTitle("Downloading ${shown.keys.joinToString()}")
                .setContentText("${(fraction * 100).toInt()} %")
                .setProgress(100, (fraction * 100).toInt(), false)
        }
        return builder.build()
    }

    companion object {
        private const val CHANNEL = "recording"
        private const val NOTIFICATION_ID = 7
        const val ACTION_STOP = "de.letzgo.porridge.STOP_RECORDING"
        private const val ACTION_UPDATE = "de.letzgo.porridge.UPDATE"

        /** Transkription: der Dienst hält die App am Leben. */
        @Volatile var busy = false

        /** Modelle, die gerade herunterladen (Name → Anteil); auch dabei bleibt die App im Hintergrund am Leben. */
        val downloads = java.util.concurrent.ConcurrentHashMap<String, Float>()

        fun update(context: Context) {
            val intent = Intent(context, RecordingService::class.java).setAction(ACTION_UPDATE)
            if (RecordingSession.isRecording || busy || downloads.isNotEmpty()) ContextCompat.startForegroundService(context, intent) else context.startService(intent)
        }
    }
}
