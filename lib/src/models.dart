/// Whether the app may read the device calendar.
enum CalendarPermission {
  /// Never asked. [DeviceCalendarKit.requestPermission] shows the prompt.
  notDetermined,

  /// The user said no. On iOS, and on Android after a second refusal, the
  /// prompt does not show again: send the user to
  /// [DeviceCalendarKit.openSettings].
  denied,

  /// iOS only: blocked by Screen Time or a device management profile. The
  /// user cannot change it.
  restricted,

  /// iOS 17+ only: the app may add events but not read them. Reading needs
  /// full access, which only Settings can grant now.
  writeOnly,

  /// Reading is allowed.
  granted;

  /// Whether calendars and events can be read.
  bool get canRead => this == granted;

  static CalendarPermission parse(Object? value) => CalendarPermission.values
      .firstWhere((p) => p.name == value, orElse: () => notDetermined);
}

/// One calendar on the device, from any account: iCloud, Google,
/// Exchange/Outlook, CalDAV, a subscribed calendar or a local one.
class DeviceCalendar {
  const DeviceCalendar({
    required this.id,
    required this.title,
    required this.accountName,
    required this.accountType,
    this.color,
    this.isReadOnly = false,
    this.isBirthdays = false,
  });

  /// Reads the native wire format.
  factory DeviceCalendar.fromMap(Map<String, dynamic> map) => DeviceCalendar(
        id: map['id'] as String,
        title: map['title'] as String? ?? '',
        accountName: map['accountName'] as String? ?? '',
        accountType: map['accountType'] as String? ?? '',
        color: (map['color'] as num?)?.toInt(),
        isReadOnly: map['readOnly'] as bool? ?? false,
        isBirthdays: map['birthdays'] as bool? ?? false,
      );

  /// Stable across launches. Pass it to [DeviceCalendarKit.events].
  final String id;

  /// The name the user sees: "Home", "Work", "Birthdays".
  final String title;

  /// The account the calendar belongs to. On Android the account's address
  /// ("you@gmail.com"); on iOS the account's title ("iCloud", "Gmail").
  final String accountName;

  /// The kind of account. On Android the sync adapter type ("com.google",
  /// "com.microsoft.office.outlook", "LOCAL"); on iOS one of `local`,
  /// `exchange`, `calDAV`, `mobileMe`, `subscribed`, `birthdays`.
  final String accountType;

  /// The calendar's colour as 0xAARRGGBB, when it has one.
  final int? color;

  /// Whether the user can add or edit events in it from other apps.
  final bool isReadOnly;

  /// Whether this is the calendar generated from contacts' birthdays: the
  /// iOS Birthdays calendar, or Google's contacts birthdays calendar on
  /// Android. Every event in it repeats yearly.
  final bool isBirthdays;

  @override
  String toString() => 'DeviceCalendar($title, $accountName)';
}

/// How often an event repeats.
enum RecurrenceFrequency { daily, weekly, monthly, yearly }

/// An event's repeat rule, simplified to the frequency and the interval.
/// "Every 2 weeks" is `weekly` with an [interval] of 2.
class EventRecurrence {
  const EventRecurrence(this.frequency, {this.interval = 1});

  static EventRecurrence? fromMap(Object? value) {
    if (value is! Map) return null;
    final name = value['frequency'];
    final frequency = RecurrenceFrequency.values
        .where((f) => f.name == name)
        .firstOrNull;
    if (frequency == null) return null;
    final interval = (value['interval'] as num?)?.toInt() ?? 1;
    return EventRecurrence(frequency, interval: interval < 1 ? 1 : interval);
  }

  final RecurrenceFrequency frequency;
  final int interval;

  /// Every year: birthdays, anniversaries.
  bool get isYearly =>
      frequency == RecurrenceFrequency.yearly && interval == 1;

  @override
  bool operator ==(Object other) =>
      other is EventRecurrence &&
      other.frequency == frequency &&
      other.interval == interval;

  @override
  int get hashCode => Object.hash(frequency, interval);

  @override
  String toString() =>
      interval == 1 ? frequency.name : '${frequency.name} x$interval';
}

/// One occurrence of an event. A repeating event inside the requested range
/// comes back once per occurrence, all with the same [eventId].
class DeviceEvent {
  const DeviceEvent({
    required this.eventId,
    required this.calendarId,
    required this.title,
    required this.start,
    required this.end,
    this.isAllDay = false,
    this.location,
    this.notes,
    this.recurrence,
  });

  /// Reads the native wire format. An all-day event carries `startDate` and
  /// `endDate` as `YYYY-MM-DD`; a timed one carries `start` and `end` in
  /// milliseconds since the epoch.
  factory DeviceEvent.fromMap(Map<String, dynamic> map) {
    final allDay = map['allDay'] as bool? ?? false;
    final DateTime start;
    final DateTime end;
    if (allDay) {
      start = _day(map['startDate'] as String);
      final endText = map['endDate'] as String?;
      end = endText == null
          ? DateTime(start.year, start.month, start.day + 1)
          : _day(endText);
    } else {
      start = DateTime.fromMillisecondsSinceEpoch((map['start'] as num).toInt());
      end = DateTime.fromMillisecondsSinceEpoch((map['end'] as num).toInt());
    }
    return DeviceEvent(
      eventId: map['eventId'] as String,
      calendarId: map['calendarId'] as String,
      title: map['title'] as String? ?? '',
      start: start,
      end: end,
      isAllDay: allDay,
      location: _text(map['location']),
      notes: _text(map['notes']),
      recurrence: EventRecurrence.fromMap(map['recurrence']),
    );
  }

  static DateTime _day(String text) {
    final parts = text.split('-').map(int.parse).toList();
    return DateTime(parts[0], parts[1], parts[2]);
  }

  static String? _text(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// The event (the whole series, for a repeating one). Stable across
  /// launches on the same device, so it works for skipping events already
  /// imported. Combine with [start] to tell occurrences apart.
  final String eventId;

  /// The [DeviceCalendar.id] it belongs to.
  final String calendarId;

  final String title;

  /// Local time. For an all-day event, midnight of its first day.
  final DateTime start;

  /// Local time, exclusive. For an all-day event, midnight of the day after
  /// its last day: a one-day event on 25 December ends at 26 December 00:00.
  final DateTime end;

  final bool isAllDay;
  final String? location;
  final String? notes;

  /// Null for a one-off event.
  final EventRecurrence? recurrence;

  /// The first day, without the time.
  DateTime get day => DateTime(start.year, start.month, start.day);

  @override
  String toString() => 'DeviceEvent($title, $start${isAllDay ? ', all day' : ''})';
}

/// A native call failed.
class DeviceCalendarException implements Exception {
  const DeviceCalendarException(this.code, [this.message]);

  /// One of:
  /// - `permission_denied`: reading needs [CalendarPermission.granted].
  /// - `missing_usage_description`: iOS, the Info.plist key is missing (see
  ///   the README); without it iOS would end the app.
  /// - `no_activity`: Android, no screen to show the prompt from.
  /// - `unsupported`: no native code on this platform.
  /// - `unavailable`: the native side did not accept the call.
  /// - `error`: anything else; see [message].
  final String code;
  final String? message;

  @override
  String toString() =>
      'DeviceCalendarException($code${message == null ? '' : ': $message'})';
}
