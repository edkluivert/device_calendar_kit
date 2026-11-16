/// Read the device calendar from DartNative apps: every calendar from every
/// account on the phone, through EventKit on iOS and CalendarContract on
/// Android, over FFI.
library;

export 'src/bindings.dart' show DeviceCalendarKitBindings;
export 'src/debug.dart' show deviceCalendarKitVerbose;
export 'src/device_calendar_kit.dart' show DeviceCalendarKit;
export 'src/models.dart';
