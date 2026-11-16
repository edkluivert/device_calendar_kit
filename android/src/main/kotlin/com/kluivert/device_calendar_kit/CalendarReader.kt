package com.kluivert.device_calendar_kit

import android.content.ContentUris
import android.content.Context
import android.provider.CalendarContract.Calendars
import android.provider.CalendarContract.Events
import android.provider.CalendarContract.Instances
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar
import java.util.Locale
import java.util.TimeZone

/**
 * The CalendarContract queries. Every account the user added to the phone
 * (Google, Exchange/Outlook, Samsung, CalDAV via a sync app, local) syncs
 * into this one provider, so no account API is needed.
 */
internal object CalendarReader {

    private val calendarProjection = arrayOf(
        Calendars._ID,
        Calendars.CALENDAR_DISPLAY_NAME,
        Calendars.ACCOUNT_NAME,
        Calendars.ACCOUNT_TYPE,
        Calendars.OWNER_ACCOUNT,
        Calendars.CALENDAR_COLOR,
        Calendars.CALENDAR_ACCESS_LEVEL,
    )

    fun calendars(ctx: Context): JSONArray {
        val out = JSONArray()
        ctx.contentResolver.query(
            Calendars.CONTENT_URI,
            calendarProjection,
            null,
            null,
            "${Calendars.ACCOUNT_NAME} ASC, ${Calendars.CALENDAR_DISPLAY_NAME} ASC",
        )?.use { c ->
            while (c.moveToNext()) {
                val owner = c.getString(4)
                val map = JSONObject()
                    .put("id", c.getLong(0).toString())
                    .put("title", c.getString(1) ?: "")
                    .put("accountName", c.getString(2) ?: "")
                    .put("accountType", c.getString(3) ?: "")
                    .put("readOnly", c.getInt(6) < Calendars.CAL_ACCESS_CONTRIBUTOR)
                    .put("birthdays", isBirthdays(owner))
                if (!c.isNull(5)) map.put("color", c.getInt(5).toLong() and 0xFFFFFFFFL)
                out.put(map)
            }
        }
        return out
    }

    /**
     * Google's calendar generated from contacts' birthdays. Its owner
     * account is "addressbook#contacts@group.v.calendar.google.com" (older)
     * or "<hash>#contacts@group.v.calendar.google.com".
     */
    private fun isBirthdays(ownerAccount: String?): Boolean =
        ownerAccount?.endsWith("#contacts@group.v.calendar.google.com") == true

    private val instanceProjection = arrayOf(
        Instances.EVENT_ID,
        Instances.CALENDAR_ID,
        Instances.TITLE,
        Instances.BEGIN,
        Instances.END,
        Instances.ALL_DAY,
        Instances.EVENT_LOCATION,
        Instances.DESCRIPTION,
        Instances.RRULE,
    )

    /**
     * Instances, not Events: the provider expands repeating events into one
     * row per occurrence inside [startMs]..[endMs].
     */
    fun events(ctx: Context, startMs: Long, endMs: Long, calendarIds: List<String>?): JSONArray {
        val out = JSONArray()
        if (calendarIds != null && calendarIds.isEmpty()) return out

        val birthdayCalendars = birthdayCalendarIds(ctx)
        val uri = Instances.CONTENT_URI.buildUpon().also {
            ContentUris.appendId(it, startMs)
            ContentUris.appendId(it, endMs)
        }.build()

        val selection = StringBuilder()
            .append("${Events.DELETED} != 1")
            .append(" AND (${Events.STATUS} IS NULL OR ${Events.STATUS} != ${Events.STATUS_CANCELED})")
        val selectionArgs = mutableListOf<String>()
        if (calendarIds != null) {
            selection.append(" AND ${Instances.CALENDAR_ID} IN (")
            selection.append(calendarIds.joinToString(",") { "?" })
            selection.append(")")
            selectionArgs.addAll(calendarIds)
        }

        ctx.contentResolver.query(
            uri,
            instanceProjection,
            selection.toString(),
            selectionArgs.toTypedArray(),
            "${Instances.BEGIN} ASC",
        )?.use { c ->
            while (c.moveToNext()) {
                val calendarId = c.getLong(1).toString()
                val begin = c.getLong(3)
                val end = if (c.isNull(4)) begin else c.getLong(4)
                val allDay = c.getInt(5) == 1
                val map = JSONObject()
                    .put("eventId", c.getLong(0).toString())
                    .put("calendarId", calendarId)
                    .put("title", c.getString(2) ?: "")
                    .put("allDay", allDay)
                if (allDay) {
                    // All-day rows are stored at UTC midnight; reading them in
                    // local time would shift the day west of Greenwich.
                    map.put("startDate", utcDay(begin))
                    map.put("endDate", utcDay(if (end > begin) end else begin + DAY_MS))
                } else {
                    map.put("start", begin)
                    map.put("end", end)
                }
                c.getString(6)?.takeIf { it.isNotBlank() }?.let { map.put("location", it) }
                c.getString(7)?.takeIf { it.isNotBlank() }?.let { map.put("notes", it) }
                val recurrence = parseRule(c.getString(8))
                    ?: if (calendarId in birthdayCalendars) yearly() else null
                recurrence?.let { map.put("recurrence", it) }
                out.put(map)
            }
        }
        return out
    }

    private fun birthdayCalendarIds(ctx: Context): Set<String> {
        val ids = mutableSetOf<String>()
        ctx.contentResolver.query(
            Calendars.CONTENT_URI,
            arrayOf(Calendars._ID, Calendars.OWNER_ACCOUNT),
            null, null, null,
        )?.use { c ->
            while (c.moveToNext()) {
                if (isBirthdays(c.getString(1))) ids.add(c.getLong(0).toString())
            }
        }
        return ids
    }

    /** FREQ and INTERVAL of an RFC 5545 rule; null for anything else. */
    internal fun parseRule(rule: String?): JSONObject? {
        if (rule.isNullOrBlank()) return null
        var frequency: String? = null
        var interval = 1
        for (part in rule.split(';')) {
            val pair = part.split('=', limit = 2)
            if (pair.size != 2) continue
            val key = pair[0].trim().uppercase(Locale.ROOT)
            val value = pair[1].trim()
            when (key) {
                "FREQ" -> frequency = when (value.uppercase(Locale.ROOT)) {
                    "DAILY" -> "daily"
                    "WEEKLY" -> "weekly"
                    "MONTHLY" -> "monthly"
                    "YEARLY" -> "yearly"
                    else -> null
                }
                "INTERVAL" -> interval = value.toIntOrNull()?.coerceAtLeast(1) ?: 1
            }
        }
        return frequency?.let { JSONObject().put("frequency", it).put("interval", interval) }
    }

    private fun yearly() = JSONObject().put("frequency", "yearly").put("interval", 1)

    private const val DAY_MS = 24L * 60 * 60 * 1000

    private fun utcDay(ms: Long): String {
        val cal = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
        cal.timeInMillis = ms
        return String.format(
            Locale.ROOT, "%04d-%02d-%02d",
            cal.get(Calendar.YEAR), cal.get(Calendar.MONTH) + 1, cal.get(Calendar.DAY_OF_MONTH),
        )
    }
}
