cmake_minimum_required(VERSION 3.22.1)
project("device_calendar_kit" CXX)

# libdevice_calendar_kit.so: the C entry points Dart opens by this name
# (lib/src/bindings.dart), bridged to DeviceCalendarKitBridge.kt over JNI.
# DeviceCalendarKitPlugin.kt loads it when the engine starts.
add_library(device_calendar_kit SHARED
    src/main/cpp/device_calendar_kit.cpp
)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# The NDK provides the JNI headers; find_package(JNI) would look for a host JDK.
find_library(log-lib log)

target_link_libraries(device_calendar_kit
    ${log-lib}
)

# Only the EXPORT-marked functions are visible to dart:ffi.
target_compile_options(device_calendar_kit PRIVATE -fvisibility=hidden)

# 16 KB page alignment, required by Google Play on Android 15 and later.
target_link_options(device_calendar_kit PRIVATE "-Wl,-z,max-page-size=16384")
