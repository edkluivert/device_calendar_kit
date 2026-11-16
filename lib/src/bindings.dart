/// FFI bindings to device_calendar_kit's native side.
///
/// iOS: `@_cdecl` functions in `ios/Classes/DeviceCalendarKit.swift`,
/// compiled into the app and resolved with `DynamicLibrary.process()`.
/// Android: exported C functions in
/// `android/src/main/cpp/device_calendar_kit.cpp` (libdevice_calendar_kit.so),
/// which call `DeviceCalendarKitBridge.kt` over JNI.
///
/// Every call carries a token. Native answers later, on the main thread and
/// never inside the call itself, through one dispatcher pointer for the
/// whole plugin, and the reply is routed to the handler registered under
/// that token. Native checks the framework's restart signal before each
/// delivery, so a hot restart never calls a stale pointer.
library;

import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:math' show Random;

import 'package:ffi/ffi.dart';

import 'debug.dart';

typedef _SetDispatcherC = Void Function(Int64);
typedef _SetDispatcherD = void Function(int);

typedef _InvokeC = Int32 Function(Int64, Pointer<Utf8>, Pointer<Utf8>);
typedef _InvokeD = int Function(int, Pointer<Utf8>, Pointer<Utf8>);

/// (token, type, payload): the C signature every reply arrives with. The
/// payload is JSON.
typedef _DispatchC = Void Function(Int64, Int32, Pointer<Utf8>);

/// A handler registered under a token.
typedef DeviceCalendarKitReplyHandler = void Function(int type, String payload);

/// Reply types native delivers.
abstract final class DeviceCalendarKitReplyType {
  /// The payload is the JSON encoded result.
  static const int success = 0;

  /// The payload is `{"code": ..., "message": ...}`.
  static const int error = 1;
}

abstract final class DeviceCalendarKitBindings {
  static bool _loaded = false;

  /// Whether [loadSymbols] found the native functions. False on a platform
  /// other than iOS and Android, or when the app's registrant was not
  /// regenerated with `dn pub get`.
  static bool get isLoaded => _loaded;

  static _InvokeD? _invoke;

  /// Loads the native functions. Called by the app's generated
  /// `DartNativePluginRegistrant.registerAll()`. Safe to call more than
  /// once, and does nothing where there is no native code, so `dn test`
  /// runs on the development machine.
  static void loadSymbols() {
    if (_loaded) return;
    if (!Platform.isIOS && !Platform.isAndroid) return;
    try {
      final lib = Platform.isAndroid
          ? DynamicLibrary.open('libdevice_calendar_kit.so')
          : DynamicLibrary.process();
      final setDispatcher = lib.lookupFunction<_SetDispatcherC, _SetDispatcherD>(
        'DeviceCalendarKitSetDispatcher',
      );
      _invoke = lib.lookupFunction<_InvokeC, _InvokeD>('DeviceCalendarKitInvoke');
      // Once per Dart session. A second call tells native a new session
      // started, so it drops what the old one was waiting for.
      setDispatcher(_dispatchPtr.address);
      _loaded = true;
      deviceCalendarKitLog('bindings loaded (${Platform.operatingSystem})');
    } catch (error) {
      deviceCalendarKitLog('loadSymbols failed: $error');
    }
  }

  // ── Dispatcher ─────────────────────────────────────────────────────────

  static final Map<int, DeviceCalendarKitReplyHandler> _handlers = {};

  // Tokens start at a random point per Dart session, so a reply meant for
  // a session that a hot restart ended never matches a new token.
  static int _nextToken = (Random().nextInt(1 << 20) + 1) << 20;

  static void _dispatch(int token, int type, Pointer<Utf8> payload) {
    final handler = _handlers.remove(token);
    if (handler == null) return;
    handler(type, payload == nullptr ? 'null' : payload.toDartString());
  }

  static final Pointer<NativeFunction<_DispatchC>> _dispatchPtr =
      Pointer.fromFunction<_DispatchC>(_dispatch);

  /// Runs [method] natively with [argumentsJson]. [handler] receives the
  /// one reply. Returns 0 when native accepted the call, otherwise an error
  /// code: -1 symbols not loaded, -2/-3 the JNI call failed, 2 unknown
  /// method. On a non-zero return [handler] is never called.
  static int invoke(
    String method,
    String argumentsJson,
    DeviceCalendarKitReplyHandler handler,
  ) {
    final fn = _invoke;
    if (fn == null) return -1;
    final token = _nextToken++;
    _handlers[token] = handler;
    final pm = method.toNativeUtf8();
    final pa = argumentsJson.toNativeUtf8();
    try {
      final rc = fn(token, pm, pa);
      if (rc != 0) _handlers.remove(token);
      return rc;
    } finally {
      calloc.free(pm);
      calloc.free(pa);
    }
  }
}
