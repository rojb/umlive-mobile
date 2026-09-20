package com.umlive.voice

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Holds the drain window open while the app is not in the foreground (`T19`).
 *
 * The drain itself lives in Dart and this class does none of it: no network, no
 * database, no business logic, nothing scheduled. It exists for one measured
 * reason -- this handset (HONOR `TFY-LX3`, MagicOS 7.1) kills background work
 * even with battery optimisation disabled, and a queued command that never
 * drains is a promise the app made and did not keep. A foreground service is
 * the platform's own mechanism for keeping a process scheduled through that,
 * and the ongoing notification is what makes the window visible to the operator
 * instead of invisible work.
 *
 * **This file owns no user-facing copy.** The notification's title and body
 * arrive in the launching intent, built by Dart from `app_es.arb`; an intent
 * that carries none is refused rather than filled in with a sentence invented
 * here.
 *
 * Intent-extras contract -- this is the Dart/Kotlin boundary:
 *  - [ACTION_START] with [EXTRA_TITLE] (`String`), [EXTRA_BODY] (`String`) and
 *    [EXTRA_COUNT] (`Int`) promotes the service to the foreground and shows the
 *    notification.
 *  - [ACTION_UPDATE] with the same three extras replaces the notification **in
 *    place**, without restarting the service: the count changes while the
 *    window is open (a drain, a cancel, a retry) and the notification has to
 *    follow it.
 *  - [ACTION_STOP] with no extras stops the service cleanly:
 *    `stopForeground(STOP_FOREGROUND_REMOVE)` and then `stopSelf()`.
 *
 * `START_STICKY`: if the OEM kills the process the work is still owed, so the
 * service asks the platform to recreate it. A recreation with nothing to
 * redeliver arrives with a null intent, and since the copy belongs to Dart this
 * service cannot say anything true about the queue in that state -- it stops
 * itself, and the Dart side re-establishes the notification the next time it
 * looks at the queue.
 */
class OutboxDrainService : Service() {

    /**
     * True once this instance has been promoted to the foreground.
     *
     * It is the only thing that tells the update path from the first show: a
     * notification for a service that is already in the foreground is replaced
     * with `notify`, and one for a service that is not is what makes it
     * foreground in the first place.
     */
    private var inForeground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // A sticky recreation asks this service to come back with nothing to
        // redeliver. There is no copy to show and no work to do in that state,
        // so the window is not claimed: the Dart side re-establishes it the
        // next time it looks at the queue.
        if (intent == null) {
            log("action=none", "reason=no_intent")
            stopSelf()
            return START_STICKY
        }
        when (intent.action) {
            ACTION_START, ACTION_UPDATE -> if (!show(intent)) stopSelf()
            ACTION_STOP -> stopWindow()
            else -> {
                // An intent this service does not own.
                log("action=none", "reason=unknown_action")
                stopSelf()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        // Any way the service dies -- the platform, the OEM, a stop this class
        // did not initiate -- the notification goes with it: one that outlives
        // the work is a lie about work still owed.
        if (inForeground) {
            stopForeground(Service.STOP_FOREGROUND_REMOVE)
            inForeground = false
        }
        log("action=destroy")
        super.onDestroy()
    }

    /**
     * Shows the notification, promoting the service to the foreground the first
     * time and replacing it in place afterwards.
     *
     * Returns false when nothing could be shown -- the intent carried no copy
     * (this file owns no user-facing string, and a notification that says
     * nothing is worse than none), or the platform refused the promotion -- so
     * the caller stops a service that has nothing to display.
     */
    private fun show(intent: Intent): Boolean {
        val title = intent.getStringExtra(EXTRA_TITLE)
        val body = intent.getStringExtra(EXTRA_BODY)
        if (title.isNullOrEmpty() || body.isNullOrEmpty()) {
            log("action=show", "result=refused reason=no_copy")
            return false
        }
        val count = intent.getIntExtra(EXTRA_COUNT, 0)
        return try {
            ensureChannel(title)
            val notification = buildNotification(title, body, count)
            if (inForeground) {
                // The update path: the running service's notification is
                // replaced in place, so a count that changed does not restart
                // anything.
                notificationManager.notify(NOTIFICATION_ID, notification)
                log("action=update", "count=$count")
            } else {
                startForegroundCompat(notification)
                inForeground = true
                log("action=start", "count=$count")
            }
            true
        } catch (error: Throwable) {
            // A platform that refuses to promote the service -- the OEM, or the
            // restriction on starting a foreground service from the background
            // -- must not take the process down with it. The window is refused,
            // the drain keeps running in Dart, and the refusal is a log line.
            log("action=show", "result=refused reason=${error.javaClass.simpleName}")
            false
        }
    }

    /**
     * The stop action: the foreground notification is removed and the service
     * ends, so nothing of this class survives the work it was holding open.
     */
    private fun stopWindow() {
        if (inForeground) {
            stopForeground(Service.STOP_FOREGROUND_REMOVE)
            inForeground = false
        }
        log("action=stop")
        stopSelf()
    }

    /**
     * Promotes the service, declaring the type on the API level that requires
     * it.
     *
     * From API 34 a data-sync foreground service states its own type at the
     * call; the manifest declares the same one, because this is a data-sync
     * service by Android's own taxonomy -- it exists so the app can keep
     * sending work the backend has not received.
     */
    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    /**
     * The notification channel, created on demand.
     *
     * `IMPORTANCE_LOW` because this is status, not an alert: nothing here needs
     * to interrupt the operator, it only has to be visible. The channel's name
     * is the title the app sent, because Android shows that name in system
     * settings and this file owns no user-facing copy.
     */
    private fun ensureChannel(title: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = notificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, title, NotificationManager.IMPORTANCE_LOW),
        )
    }

    /**
     * The ongoing notification, and the tap that opens the app.
     *
     * A tap carries `singleTop` and opens [MainActivity] instead of stacking a
     * second copy of it: the notification answers "where is the app that still
     * owes me this", and that question has one answer, not a back stack.
     */
    private fun buildNotification(title: String, body: String, count: Int): Notification {
        val tap = Intent(this, MainActivity::class.java)
            .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pending = PendingIntent.getActivity(
            this,
            0,
            tap,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }
        return builder
            // No drawable of this app's own may be added for this task, so the
            // platform's own sync icon is used: it is honest about what the
            // notification is, and it never ships as a blank square.
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle(title)
            .setContentText(body)
            // The count an operator can compare against the queue screen.
            .setNumber(count)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            // A status notification reports state, not time: no timestamp is
            // decoration this feature needs.
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_STATUS)
            .setContentIntent(pending)
            .build()
    }

    private val notificationManager: NotificationManager
        get() = getSystemService(NotificationManager::class.java)

    /**
     * The Kotlin half of the evidence.
     *
     * The Dart side logs the outcome of every channel call; this line is what
     * proves the service itself acted on the intent, which is the half the
     * device verification of `T19` needs with the screen off.
     */
    private fun log(pair: String, extra: String = "") {
        val suffix = if (extra.isEmpty()) "" else " $extra"
        Log.i(TAG, "[service] $pair$suffix")
    }

    companion object {
        const val ACTION_START = "com.umlive.voice.action.START_DRAIN"
        const val ACTION_UPDATE = "com.umlive.voice.action.UPDATE_DRAIN"
        const val ACTION_STOP = "com.umlive.voice.action.STOP_DRAIN"

        /** Notification content title, built by Dart from `app_es.arb`. */
        const val EXTRA_TITLE = "title"

        /** Notification content text, built by Dart from `app_es.arb`. */
        const val EXTRA_BODY = "body"

        /** How many items the drain still owes, as the queue last saw it. */
        const val EXTRA_COUNT = "count"

        private const val CHANNEL_ID = "com.umlive.voice.drain"
        private const val NOTIFICATION_ID = 1
        private const val TAG = "umlive"
    }
}
