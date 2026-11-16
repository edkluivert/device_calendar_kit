#
# The pod an app's `pod install` adds for this plugin: `dn pub get` lists the
# plugin in the app's .dn-plugins-dependencies and the Podfile picks it up
# from there. `dn plugin build` reads this file too, so keep s.platform,
# s.frameworks and any s.dependency lines in this plain one-per-line form.
#
Pod::Spec.new do |s|
  s.name             = 'device_calendar_kit'
  s.version          = '0.1.0'
  s.summary          = 'Device calendar access for DartNative: EventKit over FFI.'
  s.description      = <<-DESC
Native side of device_calendar_kit for iOS: calendar permission, every
calendar from every account on the device, and event occurrences in a date
range from EventKit, exposed to Dart as C entry points.
                       DESC
  s.homepage         = 'https://github.com/edkluivert/device_calendar_kit'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Kluivert' => 'team@funkash.com' }
  s.source           = { :path => '.' }

  # The @_cdecl functions in these files are what lib/src/bindings.dart
  # looks up.
  s.source_files     = 'Classes/**/*.swift'
  s.swift_version    = '5.9'
  s.platform = :ios, '15.0'
  s.frameworks       = 'EventKit', 'UIKit'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
