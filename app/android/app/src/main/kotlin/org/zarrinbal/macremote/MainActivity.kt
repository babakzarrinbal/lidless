package org.zarrinbal.macremote

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FragmentActivity: local_auth needs it for the biometric prompt.
// The "uniai/notify" channel: notifications for sessions that need the
// user, and the foreground service that keeps the app alive while agents work.
class MainActivity : FlutterFragmentActivity() {
    private var channel: MethodChannel? = null
    private var initial: String? = null
    private var watching: String? = null // the service's text while agents work
    private var away = false

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        initial = intent?.getStringExtra(EXTRA)
        channels(this)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, "uniai/notify").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "initial" -> {
                        result.success(initial)
                        initial = null
                    }
                    "ask" -> {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        ) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7)
                        result.success(null)
                    }
                    "show" -> {
                        show(call.argument<Int>("id")!!, call.argument<String>("title") ?: "",
                            call.argument<String>("text") ?: "", call.argument<String>("payload") ?: "")
                        result.success(null)
                    }
                    "cancel" -> {
                        manager().cancel(call.argument<Int>("id")!!)
                        result.success(null)
                    }
                    "watch" -> {
                        watching = call.argument<String>("text")
                        if (watching == null) WatchService.stop(this@MainActivity) else if (away) WatchService.start(this@MainActivity, watching!!)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra(EXTRA)?.let { channel?.invokeMethod("open", it) }
    }

    // A foreground service may only start while the app is visible: start it as
    // the app leaves, stop it when the app is back (the app keeps itself up).
    override fun onPause() {
        super.onPause()
        away = true
        watching?.let { WatchService.start(this, it) }
    }

    override fun onResume() {
        super.onResume()
        away = false
        WatchService.stop(this)
    }

    private fun manager() = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun show(id: Int, title: String, text: String, payload: String) {
        val open = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .putExtra(EXTRA, payload)
        val tap = PendingIntent.getActivity(this, id, open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val n = builder(this, UNREAD)
            .setSmallIcon(R.drawable.ic_notify)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(tap)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .build()
        try {
            manager().notify(id, n)
        } catch (_: SecurityException) { // no permission
        }
    }

    companion object {
        const val EXTRA = "uniai_session"
        const val UNREAD = "unread"
        const val WATCH = "watch"

        fun channels(c: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            val m = c.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            m.createNotificationChannel(NotificationChannel(UNREAD, "Sessions that need you",
                NotificationManager.IMPORTANCE_HIGH).apply {
                description = "An agent finished, or asks you something"
            })
            m.createNotificationChannel(NotificationChannel(WATCH, "Agents working",
                NotificationManager.IMPORTANCE_MIN).apply {
                description = "Keeps the connection open while the app is away, to tell you when they stop"
                setShowBadge(false)
            })
        }

        @Suppress("DEPRECATION")
        fun builder(c: Context, ch: String): Notification.Builder =
            if (Build.VERSION.SDK_INT >= 26) Notification.Builder(c, ch) else Notification.Builder(c)
    }
}
