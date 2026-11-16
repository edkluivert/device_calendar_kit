import 'dart:async';
import 'dart:convert';

import 'bindings.dart';
import 'debug.dart';
import 'models.dart';

/// Reads the device calendar: every calendar from every account on the
/// phone (iCloud, Google, Exchange/Outlook, CalDAV, subscribed, local),
/// through EventKit on iOS and CalendarContract on Android.
///
/// Read-only. No account sign-in: the phone's own calendar database already
/// holds every account the user added in Settings.
abstract final class DeviceCalendarKit {
  /// The current permission, without prompting.
  static Future<CalendarPermission> permissionStatus() async =>
      CalendarPermission.parse(await _call('permissionStatus'));

  /// Shows the system prompt when the permission was never asked, and
  /// returns the result. Otherwise returns the current permission without
  /// a prompt: once denied, only [openSettings] can change it.
  static Future<CalendarPermission> requestPermission() async =>
      CalendarPermission.parse(await _call('requestPermission'));

  /// Every calendar on the device, sorted by account then title.
  ///
  /// Throws [DeviceCalendarException] `permission_denied` without
  /// [CalendarPermission.granted].
  static Future<List<DeviceCalendar>> calendars() async {
    final list = await _call('calendars') as List<dynamic>;
    return [
      for (final item in list)
        DeviceCalendar.fromMap((item as Map).cast<String, dynamic>()),
    ];
  }

  /// Event occurrences that overlap [start] to [end], sorted by start.
  ///
  /// [calendarIds] limits the search to those calendars; null searches all
  /// of them. A repeating event comes back once per occurrence in the range.
  ///
  /// Throws [DeviceCalendarException] `permission_denied` without
  /// [CalendarPermission.granted].
  static Future<List<DeviceEvent>> events({
    required DateTime start,
    required DateTime end,
    Iterable<String>? calendarIds,
  }) async {
    if (!end.isAfter(start)) {
      throw ArgumentError.value(end, 'end', 'must be after start');
    }
    final list = await _call('events', {
      'start': start.millisecondsSinceEpoch,
      'end': end.millisecondsSinceEpoch,
      'calendarIds': calendarIds?.toList(),
    }) as List<dynamic>;
    final events = [
      for (final item in list)
        DeviceEvent.fromMap((item as Map).cast<String, dynamic>()),
    ]..sort((a, b) => a.start.compareTo(b.start));
    return events;
  }

  /// Opens this app's page in the system Settings, where the user can
  /// change a denied permission. Returns whether Settings opened.
  static Future<bool> openSettings() async =>
      await _call('openSettings') as bool? ?? false;

  static Future<Object?> _call(String method, [Map<String, Object?>? args]) {
    if (!DeviceCalendarKitBindings.isLoaded) {
      // The registrant normally loads them; this covers an app that calls
      // the plugin before registerAll() or was not regenerated.
      DeviceCalendarKitBindings.loadSymbols();
      if (!DeviceCalendarKitBindings.isLoaded) {
        return Future.error(const DeviceCalendarException(
          'unsupported',
          'device_calendar_kit has native code for iOS and Android only. '
              'On those, run `dn pub get` so the registrant loads it.',
        ));
      }
    }
    final completer = Completer<Object?>();
    final arguments = jsonEncode(args);
    final rc = DeviceCalendarKitBindings.invoke(method, arguments, (type, payload) {
      deviceCalendarKitLog('$method -> type=$type ${_short(payload)}');
      // Runs inside a native callback, which must not throw.
      try {
        final decoded = jsonDecode(payload);
        if (type == DeviceCalendarKitReplyType.error) {
          final map = decoded is Map ? decoded : const {};
          completer.completeError(DeviceCalendarException(
            map['code'] as String? ?? 'error',
            map['message'] as String?,
          ));
        } else {
          completer.complete(decoded);
        }
      } catch (e) {
        completer.completeError(
            DeviceCalendarException('error', 'Bad reply to $method: $e'));
      }
    });
    deviceCalendarKitLog('invoke $method $arguments rc=$rc');
    if (rc != 0) {
      return Future.error(DeviceCalendarException(
        'unavailable',
        'The native side did not accept $method (code $rc).',
      ));
    }
    return completer.future;
  }

  static String _short(String text) =>
      text.length <= 200 ? text : '${text.substring(0, 200)}…';
}
