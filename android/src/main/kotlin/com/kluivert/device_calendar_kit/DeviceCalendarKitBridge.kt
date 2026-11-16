package com.kluivert.device_calendar_kit

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.annotation.Keep
import org.json.JSONObject
import java.util.concurrent.Executors

/**
 * Kotlin side of device_calendar_kit, called from device_calendar_kit.cpp.
 *
 * Every call answers later through [fireToDart]: one dispatcher pointer,
 * one restart counter checked before every delivery, always on the main
 * thread. Calendar queries run on a background thread.
 */
@Keep
object DeviceCalendarKitBridge {
    private const val TAG = "DeviceCalendarKit"
    private const val TYPE_SUCCESS = 0
    private const val TYPE_ERROR = 1
    private const val PREFS = "device_calendar_kit"
    private const val PREF_ASKED = "asked"

    private val main = Handler(Looper.getMainLooper())
    private val work = Executors.newSingleThreadExecutor { r ->
        Thread(r, "device_calendar_kit").apply { isDaemon = true }
    }

    private var context: Context? = null

    // The framework's DNAppContext is reached reflectively so this module
    // compiles on its own (the app always provides it).
    private val appContextClass: Class<*>? by lazy {
        try { Class.forName("com.dartnative.DNAppContext") } catch (_: Throwable) { null }
    }

    private fun currentActivity(): Activity? = try {
        appContextClass?.getMethod("activity")?.invoke(null) as? Activity
    } catch (_: Throwable) { null }

    fun attach(applicationContext: Context) {
        context = applicationContext
    }

    fun detach() {
        pendingPermission.clear()
    }

    // ── Dispatcher ────────────────────────────────────────────────────────

    @Volatile private var dispatcherPtr: Long = 0L
    @Volatile private var dispatcherGen: Long = 0L

    /**
     * Called once per Dart session. A second call means Dart restarted:
     * nobody waits on the old tokens, so pending prompts are forgotten.
     */
    @JvmStatic
    fun setDispatcher(ptr: Long) {
        main.post { pendingPermission.clear() }
        dispatcherPtr = ptr
        dispatcherGen = nativeIsolateGen()
    }

    @JvmStatic external fun nativeIsolateGen(): Long
    @JvmStatic external fun nativeDeliver(ptr: Long, token: Long, type: Int, payload: ByteArray)

    private fun fireToDart(token: Long, type: Int, payload: String) {
        main.post {
            if (dispatcherGen != nativeIsolateGen()) return@post // Dart restarted
            val ptr = dispatcherPtr
            if (ptr == 0L) return@post
            nativeDeliver(ptr, token, type, payload.toByteArray(Charsets.UTF_8))
        }
    }

    private fun success(token: Long, json: String) = fireToDart(token, TYPE_SUCCESS, json)

    private fun error(token: Long, code: String, message: String?) {
        val payload = JSONObject()
            .put("code", code)
            .put("message", message ?: JSONObject.NULL)
        fireToDart(token, TYPE_ERROR, payload.toString())
    }

    // ── Calls ─────────────────────────────────────────────────────────────

    /** 0 when accepted (the reply arrives later), 2 for an unknown method. */
    @JvmStatic
    fun invoke(token: Long, methodBytes: ByteArray, argumentsBytes: ByteArray): Int {
        val method = String(methodBytes, Charsets.UTF_8)
        val argsText = String(argumentsBytes, Charsets.UTF_8)
        val ctx = context
        if (ctx == null) {
            error(token, "unavailable", "device_calendar_kit is not attached to the engine yet.")
            return 0
        }
        try {
            when (method) {
                "permissionStatus" -> success(token, JSONObject.quote(permissionStatus(ctx)))
                "requestPermission" -> requestPermission(ctx, token)
                "calendars" -> whenReadable(ctx, token) {
                    CalendarReader.calendars(ctx).toString()
                }
                "events" -> {
                    val args = JSONObject(argsText)
                    val start = args.getLong("start")
                    val end = args.getLong("end")
                    val ids = args.optJSONArray("calendarIds")?.let { array ->
                        (0 until array.length()).map { array.getString(it) }
                    }
                    if (end <= start) {
                        error(token, "error", "events needs a start before its end.")
                    } else {
                        whenReadable(ctx, token) {
                            CalendarReader.events(ctx, start, end, ids).toString()
                        }
                    }
                }
                "openSettings" -> success(token, openSettings(ctx).toString())
                else -> return 2
            }
        } catch (e: Exception) {
            Log.e(TAG, "$method failed", e)
            error(token, "error", e.message)
        }
        return 0
    }

    /** Runs [query] on the work thread when reading is allowed. */
    private fun whenReadable(ctx: Context, token: Long, query: () -> String) {
        if (!granted(ctx)) {
            error(token, "permission_denied",
                "Reading the calendar needs READ_CALENDAR; permission is ${permissionStatus(ctx)}.")
            return
        }
        work.execute {
            try {
                success(token, query())
            } catch (e: SecurityException) {
                error(token, "permission_denied", e.message)
            } catch (e: Exception) {
                Log.e(TAG, "calendar query failed", e)
                error(token, "error", e.message)
            }
        }
    }

    // ── Permission ────────────────────────────────────────────────────────

    private fun granted(ctx: Context): Boolean =
        ctx.checkSelfPermission(Manifest.permission.READ_CALENDAR) ==
            PackageManager.PERMISSION_GRANTED

    /**
     * Android cannot tell "never asked" from "denied" by itself, so the
     * plugin remembers that it showed the prompt once.
     */
    private fun permissionStatus(ctx: Context): String = when {
        granted(ctx) -> "granted"
        prefs(ctx).getBoolean(PREF_ASKED, false) -> "denied"
        else -> "notDetermined"
    }

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // Tokens waiting on the one prompt on screen. Main thread only.
    private val pendingPermission = mutableListOf<Long>()

    private fun requestPermission(ctx: Context, token: Long) {
        if (granted(ctx)) {
            success(token, JSONObject.quote("granted"))
            return
        }
        main.post {
            pendingPermission.add(token)
            if (pendingPermission.size > 1) return@post // a prompt is already up
            val launcher = currentActivity() ?: ctx
            try {
                DeviceCalendarKitPermissionActivity.launch(launcher)
            } catch (e: Exception) {
                pendingPermission.remove(token)
                error(token, "no_activity", "Could not show the permission prompt: ${e.message}")
            }
        }
    }

    /** From the proxy activity, on the main thread. */
    internal fun onPermissionResult(ctx: Context, answered: Boolean) {
        if (answered) prefs(ctx).edit().putBoolean(PREF_ASKED, true).apply()
        val status = JSONObject.quote(permissionStatus(ctx))
        val tokens = pendingPermission.toList()
        pendingPermission.clear()
        for (token in tokens) success(token, status)
    }

    private fun openSettings(ctx: Context): Boolean = try {
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", ctx.packageName, null),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(intent)
        true
    } catch (_: Exception) {
        false
    }
}
