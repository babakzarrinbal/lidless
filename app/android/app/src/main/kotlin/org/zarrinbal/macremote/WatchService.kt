package org.zarrinbal.macremote

import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

// Keeps the app's process (and so its link to the Mac) alive while an agent
// works and the app is away; without it Android freezes the app and the
// "needs you" notification never comes. Stopped as soon as nothing works.
class WatchService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        MainActivity.channels(this)
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val n = MainActivity.builder(this, MainActivity.WATCH)
            .setSmallIcon(R.drawable.ic_notify)
            .setContentTitle(intent?.getStringExtra("text") ?: "Agents working")
            .setContentText("You'll get a notification when it needs you")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(ID, n)
            }
        } catch (_: Exception) {
            stopSelf()
        }
        starting = false
        if (stopWanted) stopSelf()
        return START_NOT_STICKY
    }

    companion object {
        private const val ID = 1

        // Stopping a service Android still waits on to call startForeground
        // crashes the app (ForegroundServiceDidNotStartInTimeException): back
        // and away again within a moment. Such a stop waits for the start.
        private var starting = false
        private var stopWanted = false

        fun start(c: Context, text: String) {
            try {
                val i = Intent(c, WatchService::class.java).putExtra("text", text)
                if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(i) else c.startService(i)
                starting = true
                stopWanted = false
            } catch (_: Exception) { // not allowed from the background: the app may still be up
            }
        }

        fun stop(c: Context) {
            if (starting) {
                stopWanted = true
                return
            }
            c.stopService(Intent(c, WatchService::class.java))
        }
    }
}
