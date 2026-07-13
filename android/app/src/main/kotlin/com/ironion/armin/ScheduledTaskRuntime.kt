package com.ironion.armin

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugins.GeneratedPluginRegistrant

internal object ScheduledTaskAlarmScheduler {
    private const val preferencesName = "armin_scheduled_tasks"
    private const val alarmAction = "com.ironion.armin.RUN_SCHEDULED_TASK"
    private const val taskIdExtra = "taskId"

    fun schedule(context: Context, taskId: String, scheduledAtMillis: Long): Boolean {
        val alarmManager = context.getSystemService(AlarmManager::class.java)
        val pendingIntent = pendingIntent(context, taskId)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            !alarmManager.canScheduleExactAlarms()
        ) {
            alarmManager.setAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                scheduledAtMillis,
                pendingIntent,
            )
        } else {
            alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP,
                scheduledAtMillis,
                pendingIntent,
            )
        }
        preferences(context).edit().putLong(taskId, scheduledAtMillis).apply()
        return true
    }

    fun cancel(context: Context, taskId: String) {
        context.getSystemService(AlarmManager::class.java)
            .cancel(pendingIntent(context, taskId))
        preferences(context).edit().remove(taskId).apply()
    }

    fun restore(context: Context) {
        val now = System.currentTimeMillis()
        for ((taskId, value) in preferences(context).all) {
            val scheduledAtMillis = value as? Long ?: continue
            schedule(context, taskId, maxOf(now + 1_000L, scheduledAtMillis))
        }
    }

    private fun pendingIntent(context: Context, taskId: String): PendingIntent {
        val intent = Intent(context, ScheduledTaskAlarmReceiver::class.java).apply {
            action = alarmAction
            putExtra(taskIdExtra, taskId)
        }
        return PendingIntent.getBroadcast(
            context,
            taskId.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun preferences(context: Context) =
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
}

class ScheduledTaskAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val serviceIntent = Intent(context, ScheduledTaskRuntimeService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(serviceIntent)
        } else {
            context.startService(serviceIntent)
        }
    }
}

class ScheduledTaskBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            ScheduledTaskAlarmScheduler.restore(context)
        }
    }
}

class ScheduledTaskRuntimeService : Service() {
    private var flutterEngine: FlutterEngine? = null
    private val stopHandler = Handler(Looper.getMainLooper())

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(notificationId, foregroundNotification())
        startBackgroundRuntime()
        stopHandler.postDelayed({ stopSelf() }, runtimeLifetimeMillis)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopHandler.removeCallbacksAndMessages(null)
        flutterEngine?.destroy()
        flutterEngine = null
        super.onDestroy()
    }

    private fun startBackgroundRuntime() {
        val loader = FlutterInjector.instance().flutterLoader()
        if (!loader.initialized()) {
            loader.startInitialization(this)
            loader.ensureInitializationComplete(this, null)
        }
        flutterEngine = FlutterEngine(this).also { engine ->
            GeneratedPluginRegistrant.registerWith(engine)
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(
                    loader.findAppBundlePath(),
                    "arminBackgroundSchedulerMain",
                ),
            )
        }
    }

    private fun foregroundNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
        } else {
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Armin 正在启动计划任务")
            .setContentText("连接远端 Runtime 后将在后台继续执行。")
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            channelId,
            "Armin 后台调度",
            NotificationManager.IMPORTANCE_LOW,
        )
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private companion object {
        const val channelId = "armin_scheduled_runtime"
        const val notificationId = 3108
        const val runtimeLifetimeMillis = 30_000L
    }
}
