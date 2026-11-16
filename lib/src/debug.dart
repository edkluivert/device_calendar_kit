import 'package:dartnative/dartnative.dart' show dnLog;

/// Set to true to log every native call and reply of device_calendar_kit.
bool deviceCalendarKitVerbose = false;

void deviceCalendarKitLog(String message) {
  if (deviceCalendarKitVerbose) dnLog('[device_calendar_kit] $message');
}
