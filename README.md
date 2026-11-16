# device_calendar_kit

Read the device calendar from [DartNative](https://dartnative.com) apps:
every calendar from every account on the phone, and the events in them.

The phone already syncs every account the user added in Settings (iCloud,
Google, Exchange/Outlook, CalDAV, subscribed calendars, the contacts'
birthdays) into one calendar database. This plugin reads that database, so
there is no Google or Apple sign-in, no OAuth and no network.

- **iOS**: EventKit in Swift. Full access on iOS 17+, the classic prompt on
  older versions.
- **Android**: `CalendarContract` in Kotlin. Repeating events are expanded
  by the provider's `Instances` table.
- **No platform channels**: every call is an FFI call, and replies come back
  through one hot-restart safe dispatcher, as JSON on the wire.
- **Read-only**: it lists calendars and events. It does not create, edit or
  delete them.

## Install

```yaml
dependencies:
  device_calendar_kit:
    hosted: https://dartpub.dev
    version: ^0.1.0
```

Then run `dn pub get`. It regenerates `lib/dartnative_plugin_registrant.dart`
so that `DartNativePluginRegistrant.registerAll()` loads the native
functions. Keep that call as the first line of `main()`.

### iOS

Add the usage descriptions to `ios/Runner/Info.plist`. iOS shows the text in
the permission prompt:

```xml
<!-- iOS 17 and later -->
<key>NSCalendarsFullAccessUsageDescription</key>
<string>Import your birthdays and events as countdowns.</string>
<!-- iOS 16 and earlier -->
<key>NSCalendarsUsageDescription</key>
<string>Import your birthdays and events as countdowns.</string>
```

Without the key, iOS ends the app as soon as it asks. The plugin checks for
the key first and fails with `missing_usage_description` instead.

### Android

Nothing to add. The plugin's manifest declares `READ_CALENDAR`, which is
merged into the app's manifest, along with the invisible activity that
shows the permission dialog.

## Use

```dart
import 'package:device_calendar_kit/device_calendar_kit.dart';

Future<List<DeviceEvent>> upcoming() async {
  var permission = await DeviceCalendarKit.permissionStatus();
  if (permission == CalendarPermission.notDetermined) {
    permission = await DeviceCalendarKit.requestPermission();
  }
  if (!permission.canRead) {
    // denied, restricted, or writeOnly: only Settings can change it now.
    await DeviceCalendarKit.openSettings();
    return const [];
  }

  final calendars = await DeviceCalendarKit.calendars();
  for (final c in calendars) {
    print('${c.title} · ${c.accountName}${c.isBirthdays ? ' (birthdays)' : ''}');
  }

  final now = DateTime.now();
  return DeviceCalendarKit.events(
    start: now,
    end: now.add(const Duration(days: 365)),
    // Optional: only these calendars. Null means all of them.
    calendarIds: calendars.map((c) => c.id),
  );
}
```

## API

### `DeviceCalendarKit`

| Method | Returns |
| --- | --- |
| `permissionStatus()` | The current `CalendarPermission`, without a prompt. |
| `requestPermission()` | Shows the prompt if it was never shown, and returns the result. Otherwise returns the current permission. |
| `calendars()` | Every `DeviceCalendar`, sorted by account, then title. |
| `events(start:, end:, calendarIds:)` | `DeviceEvent` occurrences that overlap the range, sorted by start. |
| `openSettings()` | Opens this app's page in system Settings. Returns whether it opened. |

`calendars()` and `events()` throw `DeviceCalendarException('permission_denied')`
unless the permission is `granted`.

### `CalendarPermission`

| Value | Meaning |
| --- | --- |
| `notDetermined` | Never asked. `requestPermission()` shows the prompt. |
| `denied` | The user said no. On iOS, and on Android after a second refusal, the prompt will not show again. |
| `restricted` | iOS only: blocked by Screen Time or device management. |
| `writeOnly` | iOS 17+ only: the app may add events but not read them. |
| `granted` | Reading is allowed. `canRead` is true only for this value. |

Android cannot tell "never asked" from "denied" on its own, so the plugin
remembers that it showed the prompt.

### `DeviceCalendar`

| Field | |
| --- | --- |
| `id` | Stable. Pass it to `events(calendarIds:)`. |
| `title` | "Home", "Work", "Birthdays". |
| `accountName` | Android: the account address (`you@gmail.com`). iOS: the account title (`iCloud`, `Gmail`). |
| `accountType` | Android: the sync adapter type (`com.google`, `LOCAL`, …). iOS: `local`, `exchange`, `calDAV`, `mobileMe`, `subscribed` or `birthdays`. |
| `color` | `0xAARRGGBB`, or null. |
| `isReadOnly` | Whether other apps can add events to it. |
| `isBirthdays` | The calendar generated from contacts' birthdays: the iOS Birthdays calendar, or Google's contacts birthdays calendar on Android. |

### `DeviceEvent`

A repeating event comes back once for each occurrence in the range. All of
its occurrences share the same `eventId`.

| Field | |
| --- | --- |
| `eventId` | The event, or the whole series for a repeating one. Stable on the device, so it works for skipping events you already imported. |
| `calendarId` | The `DeviceCalendar.id` it belongs to. |
| `title`, `location`, `notes` | Blank text reads as null. |
| `start`, `end` | Local time. `end` is exclusive. |
| `isAllDay` | For an all-day event, `start` is midnight of its first day and `end` is midnight after its last day. A one-day event on 25 December ends at 26 December 00:00. |
| `day` | `start` without the time. |
| `recurrence` | `EventRecurrence(frequency, interval:)` or null. `isYearly` is true for birthdays and anniversaries. |

All-day events keep their calendar day in every timezone. Android stores
them at UTC midnight and iOS at local midnight; the plugin turns both into
the same local day.

Birthdays on iOS carry no repeat rule, so the plugin reports them as yearly.
Android does the same for Google's birthdays calendar.

### Errors

`DeviceCalendarException.code` is one of:

| Code | When |
| --- | --- |
| `permission_denied` | Reading without `granted`. |
| `missing_usage_description` | iOS: the Info.plist key is missing. |
| `no_activity` | Android: there was no screen to show the dialog from. |
| `unsupported` | No native code on this platform, or `dn pub get` was not run. |
| `unavailable` | The native side did not accept the call. |
| `error` | Anything else; see `message`. |

## Notes

- **Ranges**: EventKit refuses ranges longer than four years, so iOS reads
  long ranges one year at a time and removes duplicates. Android has no
  limit, but a long range with daily events returns a lot of rows.
- **Recurrence** is simplified to frequency (`daily`, `weekly`, `monthly`,
  `yearly`) and interval. Rules such as "the second Tuesday" or "until 2027"
  are reduced to that. Each occurrence still comes back on its real date.
- **Android birthdays**: Google's contacts birthdays calendar is detected by
  its owner account. Other vendors may keep birthdays only in Contacts.
- **Logging**: set `deviceCalendarKitVerbose = true` to log every native
  call and reply.

## Example

`example/` lists the calendars and the next 12 months of events. To run
every call on launch and log the results:

```sh
cd example
dn pub get
dn run --dart-define=AUTORUN=true
```

## License

MIT
