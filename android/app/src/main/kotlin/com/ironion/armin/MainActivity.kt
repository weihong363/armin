package com.ironion.armin

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import android.os.Build
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.net.URI
import java.security.MessageDigest
import java.util.TimeZone
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var notificationChannel: MethodChannel? = null
    private var pendingOpenedTaskId: String? = null
    private var pendingNotificationPermissionResult: MethodChannel.Result? = null
    private var pendingCalendarPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.ironion.armin/native_slm"
        ).setMethodCallHandler { call, result ->
            NativeSlmChannel.handle(this, call, result)
        }
        notificationChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            TASK_NOTIFICATION_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                handleTaskNotification(call, result)
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SYSTEM_CALENDAR_CHANNEL,
        ).setMethodCallHandler { call, result ->
            handleSystemCalendar(call, result)
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SCHEDULED_TASK_CHANNEL,
        ).setMethodCallHandler { call, result ->
            handleScheduledTask(call, result)
        }
        createTaskNotificationChannel()
        handleNotificationIntent(intent, notifyFlutter = false)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleNotificationIntent(intent, notifyFlutter = true)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        when (requestCode) {
            TASK_NOTIFICATION_PERMISSION_REQUEST -> {
                val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
                pendingNotificationPermissionResult?.success(granted)
                pendingNotificationPermissionResult = null
            }
            CALENDAR_PERMISSION_REQUEST -> {
                val granted = grantResults.size == 2 && grantResults.all {
                    it == PackageManager.PERMISSION_GRANTED
                }
                pendingCalendarPermissionResult?.success(granted)
                pendingCalendarPermissionResult = null
            }
        }
    }

    private fun handleTaskNotification(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "permissionStatus" -> result.success(hasTaskNotificationPermission())
            "requestPermission" -> requestTaskNotificationPermission(result)
            "show" -> showTaskNotification(call, result)
            "consumePendingTaskId" -> {
                result.success(pendingOpenedTaskId)
                pendingOpenedTaskId = null
            }
            else -> result.notImplemented()
        }
    }

    private fun handleSystemCalendar(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "permissionStatus" -> result.success(hasCalendarPermission())
            "requestPermission" -> requestCalendarPermission(result)
            "upsertEvent" -> upsertCalendarEvent(call, result)
            "removeEvent" -> removeCalendarEvent(call, result)
            else -> result.notImplemented()
        }
    }

    private fun upsertCalendarEvent(call: MethodCall, result: MethodChannel.Result) {
        if (!hasCalendarPermission()) {
            result.error("calendar_permission_denied", "Calendar permission is required.", null)
            return
        }
        val taskId = call.argument<String>("taskId")?.trim().orEmpty()
        val title = call.argument<String>("title")?.trim().orEmpty()
        val startAtMillis = call.argument<Number>("startAtMillis")?.toLong()
        if (taskId.isEmpty() || title.isEmpty() || startAtMillis == null) {
            result.error("invalid_calendar_event", "Task id, title and start time are required.", null)
            return
        }
        val eventId = findCalendarEventId(taskId)
        val values = ContentValues().apply {
            put(CalendarContract.Events.TITLE, title)
            put(CalendarContract.Events.DESCRIPTION, calendarDescription(taskId, call))
            put(CalendarContract.Events.DTSTART, startAtMillis)
            put(CalendarContract.Events.DTEND, startAtMillis + CALENDAR_EVENT_DURATION_MS)
            put(CalendarContract.Events.EVENT_TIMEZONE, TimeZone.getDefault().id)
            put(
                CalendarContract.Events.RRULE,
                recurrenceRule(call.argument<String>("recurrence")),
            )
        }
        if (eventId != null) {
            contentResolver.update(
                CalendarContract.Events.CONTENT_URI,
                values,
                "${CalendarContract.Events._ID}=?",
                arrayOf(eventId.toString()),
            )
            result.success(true)
            return
        }
        val calendarId = writableCalendarId()
        if (calendarId == null) {
            result.success(false)
            return
        }
        values.put(CalendarContract.Events.CALENDAR_ID, calendarId)
        result.success(contentResolver.insert(CalendarContract.Events.CONTENT_URI, values) != null)
    }

    private fun removeCalendarEvent(call: MethodCall, result: MethodChannel.Result) {
        if (!hasCalendarPermission()) {
            result.success(null)
            return
        }
        val taskId = call.argument<String>("taskId")?.trim().orEmpty()
        val eventId = findCalendarEventId(taskId)
        if (eventId != null) {
            contentResolver.delete(
                CalendarContract.Events.CONTENT_URI,
                "${CalendarContract.Events._ID}=?",
                arrayOf(eventId.toString()),
            )
        }
        result.success(null)
    }

    private fun hasCalendarPermission(): Boolean =
        checkSelfPermission(Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED &&
            checkSelfPermission(Manifest.permission.WRITE_CALENDAR) == PackageManager.PERMISSION_GRANTED

    private fun requestCalendarPermission(result: MethodChannel.Result) {
        if (hasCalendarPermission()) {
            result.success(true)
            return
        }
        if (pendingCalendarPermissionResult != null) {
            result.success(false)
            return
        }
        pendingCalendarPermissionResult = result
        requestPermissions(
            arrayOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR),
            CALENDAR_PERMISSION_REQUEST,
        )
    }

    private fun writableCalendarId(): Long? {
        val projection = arrayOf(CalendarContract.Calendars._ID)
        val selection = "${CalendarContract.Calendars.VISIBLE}=1 AND " +
            "${CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL}>=?"
        val args = arrayOf(CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR.toString())
        return contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            projection,
            selection,
            args,
            "${CalendarContract.Calendars.IS_PRIMARY} DESC",
        )?.use { cursor -> if (cursor.moveToFirst()) cursor.getLong(0) else null }
    }

    private fun findCalendarEventId(taskId: String): Long? {
        if (taskId.isEmpty()) return null
        val marker = calendarTaskMarker(taskId)
        return contentResolver.query(
            CalendarContract.Events.CONTENT_URI,
            arrayOf(CalendarContract.Events._ID),
            "${CalendarContract.Events.DESCRIPTION} LIKE ? AND ${CalendarContract.Events.DELETED}=0",
            arrayOf("%$marker%"),
            null,
        )?.use { cursor -> if (cursor.moveToFirst()) cursor.getLong(0) else null }
    }

    private fun calendarDescription(taskId: String, call: MethodCall): String =
        "${calendarTaskMarker(taskId)}\nArmin 计划任务\n${call.argument<String>("description").orEmpty()}"

    private fun calendarTaskMarker(taskId: String) = "[ARMIN_TASK_ID:$taskId]"

    private fun handleScheduledTask(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> result.success(null)
            "schedule" -> {
                val taskId = call.argument<String>("taskId")?.trim().orEmpty()
                val scheduledAtMillis = call.argument<Number>("scheduledAtMillis")?.toLong()
                if (taskId.isEmpty() || scheduledAtMillis == null) {
                    result.error("invalid_schedule", "Task id and trigger time are required.", null)
                    return
                }
                result.success(
                    ScheduledTaskAlarmScheduler.schedule(this, taskId, scheduledAtMillis),
                )
            }
            "cancel" -> {
                val taskId = call.argument<String>("taskId")?.trim().orEmpty()
                if (taskId.isNotEmpty()) {
                    ScheduledTaskAlarmScheduler.cancel(this, taskId)
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun recurrenceRule(recurrence: String?): String? = when (recurrence) {
        "daily" -> "FREQ=DAILY"
        "weekly" -> "FREQ=WEEKLY"
        else -> null
    }

    private fun hasTaskNotificationPermission(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun requestTaskNotificationPermission(result: MethodChannel.Result) {
        if (hasTaskNotificationPermission()) {
            result.success(true)
            return
        }
        if (pendingNotificationPermissionResult != null) {
            result.success(false)
            return
        }
        pendingNotificationPermissionResult = result
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            TASK_NOTIFICATION_PERMISSION_REQUEST,
        )
    }

    private fun showTaskNotification(call: MethodCall, result: MethodChannel.Result) {
        val taskId = call.argument<String>("taskId")?.trim().orEmpty()
        val title = call.argument<String>("title")?.trim().orEmpty()
        if (taskId.isEmpty() || title.isEmpty()) {
            result.error("invalid_notification", "Task notification requires taskId and title.", null)
            return
        }
        val body = call.argument<String>("body")?.trim().orEmpty()
        val tapIntent = Intent(this, MainActivity::class.java).apply {
            action = TASK_NOTIFICATION_OPEN_ACTION
            putExtra(TASK_NOTIFICATION_TASK_ID, taskId)
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            taskId.hashCode(),
            tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(this, TASK_NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(pendingIntent)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_STATUS)
            .build()
        val notificationId = call.argument<String>("id")?.hashCode() ?: taskId.hashCode()
        getSystemService(NotificationManager::class.java).notify(notificationId, notification)
        result.success(null)
    }

    private fun createTaskNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val channel = NotificationChannel(
            TASK_NOTIFICATION_CHANNEL_ID,
            "Armin 任务状态",
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = "任务结果、审批和需要处理的状态更新"
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun handleNotificationIntent(intent: Intent?, notifyFlutter: Boolean) {
        val taskId = intent
            ?.takeIf { it.action == TASK_NOTIFICATION_OPEN_ACTION }
            ?.getStringExtra(TASK_NOTIFICATION_TASK_ID)
            ?.trim()
            .orEmpty()
        if (taskId.isEmpty()) {
            return
        }
        pendingOpenedTaskId = taskId
        if (notifyFlutter) {
            notificationChannel?.invokeMethod("opened", mapOf("taskId" to taskId))
        }
    }

    private companion object {
        const val TASK_NOTIFICATION_CHANNEL = "com.ironion.armin/task_notifications"
        const val TASK_NOTIFICATION_CHANNEL_ID = "armin_task_runtime"
        const val TASK_NOTIFICATION_OPEN_ACTION = "com.ironion.armin.OPEN_TASK"
        const val TASK_NOTIFICATION_TASK_ID = "taskId"
        const val TASK_NOTIFICATION_PERMISSION_REQUEST = 3107
        const val CALENDAR_PERMISSION_REQUEST = 3109
        const val SYSTEM_CALENDAR_CHANNEL = "com.ironion.armin/system_calendar"
        const val SCHEDULED_TASK_CHANNEL = "com.ironion.armin/scheduled_tasks"
        const val CALENDAR_EVENT_DURATION_MS = 30 * 60 * 1000L
    }
}

private object NativeSlmChannel {
    private const val MANAGED_MODEL_PATH = "managed://default"
    private const val BACKEND = "llama.cpp"
    private val generationExecutor = Executors.newSingleThreadExecutor()

    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capability" -> result.success(capability(call.modelPath(context)))
            "deleteModel" -> result.success(deleteManagedModel(context, call))
            "installModel" -> installManagedModel(context, call, result)
            "generate" -> generate(context, call, result)
            else -> result.notImplemented()
        }
    }

    private fun capability(modelPath: String): Map<String, Any?> {
        val model = File(modelPath)
        if (!NativeLlamaBridge.libraryLoaded) {
            return mapOf(
                "available" to false,
                "message" to "未加载 llama.cpp native runtime：libarmin_llama_jni.so。",
                "backend" to BACKEND,
                "modelPath" to modelPath,
                "modelSizeBytes" to if (model.isFile) model.length() else 0L,
            )
        }
        if (!NativeLlamaBridge.runtimeReady()) {
            return mapOf(
                "available" to false,
                "message" to "llama.cpp native runtime 尚未接入生成能力。",
                "backend" to BACKEND,
                "modelPath" to modelPath,
                "modelSizeBytes" to if (model.isFile) model.length() else 0L,
            )
        }
        if (!model.isFile) {
            return mapOf(
                "available" to false,
                "message" to "未找到端侧模型文件：$modelPath。",
                "backend" to BACKEND,
                "modelPath" to modelPath,
                "modelSizeBytes" to 0L,
            )
        }
        return mapOf(
            "available" to true,
            "message" to "端侧 llama.cpp 模型已就绪。",
            "backend" to BACKEND,
            "modelPath" to modelPath,
            "modelSizeBytes" to model.length(),
        )
    }

    private fun deleteManagedModel(context: Context, call: MethodCall): Boolean {
        if (call.argument<String>("modelPath") != MANAGED_MODEL_PATH) return false
        val model = managedModel(context)
        return !model.exists() || model.delete()
    }

    private fun installManagedModel(
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val distribution = modelDistribution(call)
        if (distribution == null) {
            result.error("invalid_model_distribution", "HTTPS URL and SHA-256 are required.", null)
            return
        }
        generationExecutor.execute {
            try {
                val model = installModel(context, distribution)
                result.success(capability(model.absolutePath))
            } catch (error: Throwable) {
                result.error("model_install_failed", error.message ?: "模型安装失败。", null)
            }
        }
    }

    private fun modelDistribution(call: MethodCall): ModelDistribution? {
        val url = call.argument<String>("url")?.trim().orEmpty()
        val sha256 = call.argument<String>("sha256")?.lowercase().orEmpty()
        if (!url.startsWith("https://") || !SHA256_PATTERN.matches(sha256)) return null
        return ModelDistribution(url, sha256)
    }

    private fun installModel(context: Context, distribution: ModelDistribution): File {
        val model = managedModel(context)
        model.parentFile?.mkdirs()
        val temporary = File(model.parentFile, "${model.name}.download")
        temporary.delete()
        try {
            check(downloadModel(distribution.url, temporary) == distribution.sha256) {
                "模型 SHA-256 校验失败。"
            }
            replaceModel(temporary, model)
            return model
        } catch (error: Throwable) {
            temporary.delete()
            throw error
        }
    }

    private fun downloadModel(url: String, destination: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        URI(url).toURL().openConnection().apply {
            connectTimeout = 15_000
            readTimeout = 60_000
        }.getInputStream().use { input ->
            FileOutputStream(destination).use { output ->
                copyAndDigest(input, output, digest)
                output.fd.sync()
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun copyAndDigest(
        input: java.io.InputStream,
        output: FileOutputStream,
        digest: MessageDigest,
    ) {
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) return
            digest.update(buffer, 0, count)
            output.write(buffer, 0, count)
        }
    }

    private fun replaceModel(temporary: File, model: File) {
        check(!model.exists() || model.delete()) { "无法替换旧模型。" }
        check(temporary.renameTo(model)) { "无法提交已校验模型。" }
    }

    private fun generate(context: Context, call: MethodCall, result: MethodChannel.Result) {
        val allowUnsafeDecode = call.argument<Boolean>("allowUnsafeDecode") == true
        if (!allowUnsafeDecode) {
            result.error(
                "native_slm_decode_disabled",
                "端侧 llama.cpp decode 默认关闭，避免 native abort 导致应用退出。",
                null,
            )
            return
        }
        val prompt = call.argument<String>("prompt")?.trim().orEmpty()
        if (prompt.isEmpty()) {
            result.error("invalid_prompt", "Prompt is empty.", null)
            return
        }
        val modelPath = call.modelPath(context)
        val current = capability(modelPath)
        if (current["available"] != true) {
            result.error("native_slm_unavailable", current["message"] as String, current)
            return
        }
        val maxTokens = call.argument<Int>("maxTokens") ?: 512
        val temperature = (call.argument<Double>("temperature") ?: 0.2).toFloat()
        generationExecutor.execute {
            try {
                val text = NativeLlamaBridge.generate(
                    modelPath,
                    prompt,
                    maxTokens.coerceIn(1, 2048),
                    temperature.coerceIn(0.0f, 1.5f),
                )
                result.success(
                    mapOf(
                        "text" to text,
                        "backend" to BACKEND,
                        "modelPath" to modelPath,
                    )
                )
            } catch (error: Throwable) {
                result.error(
                    "native_slm_failed",
                    error.message ?: "Native SLM generation failed.",
                    null,
                )
            }
        }
    }

    private fun MethodCall.modelPath(context: Context): String =
        argument<String>("modelPath")
            ?.takeIf { it.isNotBlank() && it != MANAGED_MODEL_PATH }
            ?: managedModel(context).absolutePath

    private fun managedModel(context: Context) = File(context.filesDir, "slm/model.gguf")

    private data class ModelDistribution(val url: String, val sha256: String)

    private val SHA256_PATTERN = Regex("[0-9a-f]{64}")
}

private object NativeLlamaBridge {
    val libraryLoaded: Boolean = runCatching {
        System.loadLibrary("armin_llama_jni")
    }.isSuccess

    external fun generate(
        modelPath: String,
        prompt: String,
        maxTokens: Int,
        temperature: Float,
    ): String

    external fun runtimeReady(): Boolean
}
