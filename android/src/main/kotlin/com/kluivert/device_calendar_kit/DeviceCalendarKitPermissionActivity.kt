package com.kluivert.device_calendar_kit

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle

/**
 * Invisible activity that shows the READ_CALENDAR dialog and receives its
 * result. The DartNative embedding exposes no permission-result hook to
 * plugins, so the plugin owns the activity that gets it.
 */
class DeviceCalendarKitPermissionActivity : Activity() {
    private var delivered = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) return // recreated: the dialog is still up
        requestPermissions(arrayOf(Manifest.permission.READ_CALENDAR), REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_CODE) return
        delivered = true
        // An empty result means the request was interrupted, not answered.
        DeviceCalendarKitBridge.onPermissionResult(applicationContext, grantResults.isNotEmpty())
        finish()
    }

    override fun onDestroy() {
        // Gone without a result: answer the waiting calls with the current
        // status so they never hang.
        if (!delivered && !isChangingConfigurations) {
            DeviceCalendarKitBridge.onPermissionResult(applicationContext, false)
        }
        super.onDestroy()
    }

    companion object {
        private const val REQUEST_CODE = 0xCA1

        fun launch(context: Context) {
            val intent = Intent(context, DeviceCalendarKitPermissionActivity::class.java)
            if (context !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
        }
    }
}
