import 'package:device_calendar_kit/device_calendar_kit.dart';
import 'package:test/test.dart';

void main() {
  group('without native code', () {
    test('loadSymbols does nothing', () {
      DeviceCalendarKitBindings.loadSymbols();
      expect(DeviceCalendarKitBindings.isLoaded, isFalse);
    });

    test('calls fail with unsupported', () {
      expect(
        DeviceCalendarKit.permissionStatus(),
        throwsA(isA<DeviceCalendarException>()
            .having((e) => e.code, 'code', 'unsupported')),
      );
    });

    test('events rejects an empty range before calling native', () {
      final day = DateTime(2026, 12, 25);
      expect(
        () => DeviceCalendarKit.events(start: day, end: day),
        throwsArgumentError,
      );
    });
  });

  group('CalendarPermission', () {
    test('parses every wire name', () {
      for (final p in CalendarPermission.values) {
        expect(CalendarPermission.parse(p.name), p);
      }
    });

    test('unknown values read as notDetermined', () {
      expect(CalendarPermission.parse('nope'), CalendarPermission.notDetermined);
      expect(CalendarPermission.parse(null), CalendarPermission.notDetermined);
    });

    test('only granted can read', () {
      expect(
        CalendarPermission.values.where((p) => p.canRead),
        [CalendarPermission.granted],
      );
    });
  });

  group('DeviceCalendar.fromMap', () {
    test('reads every field', () {
      final c = DeviceCalendar.fromMap({
        'id': '7',
        'title': 'Birthdays',
        'accountName': 'you@gmail.com',
        'accountType': 'com.google',
        'color': 0xFF3366CC,
        'readOnly': true,
        'birthdays': true,
      });
      expect(c.id, '7');
      expect(c.title, 'Birthdays');
      expect(c.accountName, 'you@gmail.com');
      expect(c.accountType, 'com.google');
      expect(c.color, 0xFF3366CC);
      expect(c.isReadOnly, isTrue);
      expect(c.isBirthdays, isTrue);
    });

    test('missing optional fields fall back', () {
      final c = DeviceCalendar.fromMap({'id': '1'});
      expect(c.title, '');
      expect(c.color, isNull);
      expect(c.isReadOnly, isFalse);
      expect(c.isBirthdays, isFalse);
    });
  });

  group('DeviceEvent.fromMap', () {
    test('all-day events are local days with an exclusive end', () {
      final e = DeviceEvent.fromMap({
        'eventId': '42',
        'calendarId': '7',
        'title': 'Christmas',
        'allDay': true,
        'startDate': '2026-12-25',
        'endDate': '2026-12-26',
      });
      expect(e.isAllDay, isTrue);
      expect(e.start, DateTime(2026, 12, 25));
      expect(e.end, DateTime(2026, 12, 26));
      expect(e.day, DateTime(2026, 12, 25));
    });

    test('an all-day event without an end lasts one day', () {
      final e = DeviceEvent.fromMap({
        'eventId': '1',
        'calendarId': '1',
        'allDay': true,
        'startDate': '2028-02-29',
      });
      expect(e.end, DateTime(2028, 3, 1));
    });

    test('timed events are milliseconds since the epoch', () {
      final start = DateTime(2026, 11, 20, 9, 30);
      final end = DateTime(2026, 11, 20, 10, 15);
      final e = DeviceEvent.fromMap({
        'eventId': '9',
        'calendarId': '2',
        'title': 'Dentist',
        'allDay': false,
        'start': start.millisecondsSinceEpoch,
        'end': end.millisecondsSinceEpoch,
        'location': '  Main St  ',
        'notes': '   ',
      });
      expect(e.start, start);
      expect(e.end, end);
      expect(e.day, DateTime(2026, 11, 20));
      expect(e.location, 'Main St');
      expect(e.notes, isNull);
      expect(e.recurrence, isNull);
    });

    test('recurrence', () {
      final e = DeviceEvent.fromMap({
        'eventId': '3',
        'calendarId': '1',
        'allDay': true,
        'startDate': '2026-06-01',
        'endDate': '2026-06-02',
        'recurrence': {'frequency': 'yearly', 'interval': 1},
      });
      expect(e.recurrence, const EventRecurrence(RecurrenceFrequency.yearly));
      expect(e.recurrence!.isYearly, isTrue);
    });
  });

  group('EventRecurrence.fromMap', () {
    test('interval below one reads as one', () {
      final r = EventRecurrence.fromMap({'frequency': 'weekly', 'interval': 0});
      expect(r, const EventRecurrence(RecurrenceFrequency.weekly));
    });

    test('every other year is not yearly', () {
      final r = EventRecurrence.fromMap({'frequency': 'yearly', 'interval': 2});
      expect(r!.isYearly, isFalse);
      expect(r.toString(), 'yearly x2');
    });

    test('unknown frequency or shape is null', () {
      expect(EventRecurrence.fromMap({'frequency': 'hourly'}), isNull);
      expect(EventRecurrence.fromMap('FREQ=YEARLY'), isNull);
      expect(EventRecurrence.fromMap(null), isNull);
    });
  });
}
