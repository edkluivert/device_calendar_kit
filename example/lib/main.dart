import 'package:dartnative/dartnative.dart';
import 'package:device_calendar_kit/device_calendar_kit.dart';

import 'dartnative_plugin_registrant.dart';

void main() {
  // Binds the plugin's native functions. Keep it the first line of main().
  DartNativePluginRegistrant.registerAll();
  runApp(const CalendarExample());
}

const Color _brand = Color(0xFF3D5AFE);
const Color _ink = Color(0xFF1B1B1F);
const Color _muted = Color(0xFF6B6B76);

class CalendarExample extends StatefulWidget {
  const CalendarExample({super.key});

  @override
  State<CalendarExample> createState() => _CalendarExampleState();
}

class _CalendarExampleState extends State<CalendarExample> {
  CalendarPermission? _permission;
  List<DeviceCalendar> _calendars = const [];
  List<DeviceEvent> _events = const [];
  String? _error;
  bool _busy = false;

  // `dn run --dart-define=AUTORUN=true` runs every call on launch and logs
  // the results, for checking a build without tapping.
  static const bool _autorun = bool.fromEnvironment('AUTORUN');

  @override
  void initState() {
    super.initState();
    _run(() async => _permission = await DeviceCalendarKit.permissionStatus());
    if (_autorun) _autorunAll();
  }

  Future<void> _autorunAll() async {
    void log(String line) => dnLog('[example] $line');
    try {
      log('status: ${(await DeviceCalendarKit.permissionStatus()).name}');
      final permission = await DeviceCalendarKit.requestPermission();
      log('request: ${permission.name}');
      setState(() => _permission = permission);
      await _loadCalendars();
      for (final c in _calendars) {
        log('calendar: ${c.id} "${c.title}" ${c.accountName}/${c.accountType} '
            'color=${c.color?.toRadixString(16)} readOnly=${c.isReadOnly} '
            'birthdays=${c.isBirthdays}');
      }
      await _loadEvents();
      for (final e in _events.take(30)) {
        log('event: ${e.eventId} "${e.title}" ${_date(e)} -> ${e.end} '
            'allDay=${e.isAllDay} recurrence=${e.recurrence} cal=${e.calendarId}');
      }
      log('done: ${_calendars.length} calendars, ${_events.length} events');
    } catch (e) {
      log('failed: $e');
    }
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _request() async {
    _permission = await DeviceCalendarKit.requestPermission();
  }

  Future<void> _loadCalendars() async {
    _calendars = await DeviceCalendarKit.calendars();
  }

  Future<void> _loadEvents() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    _events = await DeviceCalendarKit.events(
      start: today,
      end: DateTime(today.year + 1, today.month, today.day),
    );
  }

  String _accountOf(String calendarId) {
    for (final c in _calendars) {
      if (c.id == calendarId) return c.title;
    }
    return '';
  }

  String _date(DeviceEvent e) {
    final d = e.start;
    final day = '${d.year}-${_two(d.month)}-${_two(d.day)}';
    return e.isAllDay ? day : '$day ${_two(d.hour)}:${_two(d.minute)}';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  Widget _button(String title, Future<void> Function() action) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Button(
        title: title,
        variant: ButtonVariant.filled,
        color: _brand,
        foregroundColor: Colors.white,
        width: double.infinity,
        onPressed: _busy ? null : () => _run(action),
      ),
    );
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: Text(
          text,
          style: const TextStyle(color: _ink, fontSize: 15, fontWeight: FontWeight.bold),
        ),
      );

  Widget _row(String title, String subtitle, {int? color}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(
                color: Color(color ?? 0xFFBDBDBD),
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: _ink, fontSize: 15)),
                  Text(subtitle, style: const TextStyle(color: _muted, fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      brightness: Brightness.light,
      backgroundColor: const Color(0xFFFFFFFF),
      appBar: AppBar(
        title: const Text(
          'device_calendar_kit',
          style: TextStyle(color: _ink, fontSize: 17, fontWeight: FontWeight.bold),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Permission: ${_permission?.name ?? '…'}',
                style: const TextStyle(color: _ink, fontSize: 15),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_error!, style: const TextStyle(color: Color(0xFFC62828))),
                ),
              const SizedBox(height: 12),
              _button('Request permission', _request),
              _button('List calendars', _loadCalendars),
              _button('Events in the next 12 months', () async {
                if (_calendars.isEmpty) await _loadCalendars();
                await _loadEvents();
              }),
              _button('Open Settings', () async {
                await DeviceCalendarKit.openSettings();
              }),
              if (_calendars.isNotEmpty) _heading('Calendars (${_calendars.length})'),
              for (final c in _calendars)
                _row(
                  c.title + (c.isBirthdays ? ' 🎂' : ''),
                  '${c.accountName} · ${c.accountType}${c.isReadOnly ? ' · read-only' : ''}',
                  color: c.color,
                ),
              if (_events.isNotEmpty) _heading('Events (${_events.length})'),
              for (final e in _events.take(200))
                _row(
                  e.title.isEmpty ? '(no title)' : e.title,
                  [
                    _date(e),
                    _accountOf(e.calendarId),
                    if (e.recurrence != null) 'repeats ${e.recurrence}',
                  ].where((s) => s.isNotEmpty).join(' · '),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
