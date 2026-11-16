## 0.1.0

- Initial release.
- `DeviceCalendarKit.permissionStatus`, `requestPermission` and
  `openSettings`: full access on iOS 17+ (with the pre-17 prompt on older
  versions), `READ_CALENDAR` on Android through an invisible proxy
  activity. Android remembers that it asked, so `notDetermined` and
  `denied` are told apart.
- `DeviceCalendarKit.calendars`: every calendar from every account on the
  device, with account name and type, colour, read-only and birthdays
  flags.
- `DeviceCalendarKit.events`: event occurrences in a date range, optionally
  limited to some calendars. Repeating events are expanded; all-day events
  come back as local days with an exclusive end; recurrence is reduced to
  frequency and interval. Ranges over four years are read in windows on
  iOS.
- Native side over FFI, no platform channels: EventKit in Swift,
  CalendarContract in Kotlin behind a C++ JNI bridge, hot-restart safe
  dispatcher.
- A missing iOS usage description fails with `missing_usage_description`
  instead of ending the app.
