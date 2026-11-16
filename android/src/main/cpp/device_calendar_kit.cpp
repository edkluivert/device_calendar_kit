// Android entry points for device_calendar_kit.
//
// Dart calls the exported DeviceCalendarKit* functions below
// (DynamicLibrary.open("libdevice_calendar_kit.so")); they forward to the
// Kotlin object com.kluivert.device_calendar_kit.DeviceCalendarKitBridge over
// JNI. Kotlin answers Dart through nativeDeliver, guarded by the framework's
// restart counter DN_IsolateGen().
//
// JNI_OnLoad runs when DeviceCalendarKitPlugin.onAttachedToEngine calls
// System.loadLibrary("device_calendar_kit") on the main thread. The bridge
// class is resolved there on purpose: FindClass from a Dart thread sees only
// the system class loader and would not find the app's classes.

#include <android/log.h>
#include <dlfcn.h>
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define EXPORT extern "C" __attribute__((visibility("default")))
#define LOG_TAG "DeviceCalendarKit"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static JavaVM* g_jvm = nullptr;
static jclass g_bridge = nullptr;
static jmethodID g_setDispatcher = nullptr;
static jmethodID g_invoke = nullptr;

// A JNIEnv for the calling thread, attaching a Dart thread the VM has not
// seen. Attached threads stay attached: Dart reuses its threads.
static JNIEnv* envForThisThread() {
  if (g_jvm == nullptr) return nullptr;
  JNIEnv* env = nullptr;
  jint rc = g_jvm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
  if (rc == JNI_EDETACHED) {
    if (g_jvm->AttachCurrentThread(&env, nullptr) != JNI_OK) return nullptr;
  } else if (rc != JNI_OK) {
    return nullptr;
  }
  return env;
}

static void clearException(JNIEnv* env) {
  if (env->ExceptionCheck()) {
    env->ExceptionDescribe();
    env->ExceptionClear();
  }
}

// ── Kotlin → Dart (registered natives) ──────────────────────────────────

// The framework's restart counter, read from the core library.
static jlong nativeIsolateGen(JNIEnv*, jclass) {
  using GenFn = uint64_t (*)();
  static GenFn fn = reinterpret_cast<GenFn>(dlsym(RTLD_DEFAULT, "DN_IsolateGen"));
  return fn ? static_cast<jlong>(fn()) : 0;
}

// Calls the Dart dispatcher. The payload travels as UTF-8 bytes: JNI strings
// are Modified UTF-8, which Dart rejects for emoji. Dart copies the string
// during the call, so the buffer is freed right after.
static void nativeDeliver(JNIEnv* env, jclass, jlong ptr, jlong token,
                          jint type, jbyteArray payload) {
  using Dispatch = void (*)(int64_t, int32_t, const char*);
  if (ptr == 0) return;
  if (payload == nullptr) {
    reinterpret_cast<Dispatch>(ptr)(token, type, "null");
    return;
  }
  jsize len = env->GetArrayLength(payload);
  char* buf = static_cast<char*>(malloc(static_cast<size_t>(len) + 1));
  if (buf == nullptr) return;
  env->GetByteArrayRegion(payload, 0, len, reinterpret_cast<jbyte*>(buf));
  buf[len] = '\0';
  reinterpret_cast<Dispatch>(ptr)(token, type, buf);
  free(buf);
}

extern "C" JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void*) {
  g_jvm = vm;
  JNIEnv* env = nullptr;
  if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
    return JNI_ERR;
  }
  jclass local = env->FindClass("com/kluivert/device_calendar_kit/DeviceCalendarKitBridge");
  if (local == nullptr) {
    LOGE("DeviceCalendarKitBridge class not found");
    clearException(env);
    return JNI_ERR;
  }
  g_bridge = static_cast<jclass>(env->NewGlobalRef(local));
  env->DeleteLocalRef(local);

  g_setDispatcher = env->GetStaticMethodID(g_bridge, "setDispatcher", "(J)V");
  g_invoke = env->GetStaticMethodID(g_bridge, "invoke", "(J[B[B)I");
  clearException(env);

  static const JNINativeMethod methods[] = {
      {"nativeIsolateGen", "()J", reinterpret_cast<void*>(nativeIsolateGen)},
      {"nativeDeliver", "(JJI[B)V", reinterpret_cast<void*>(nativeDeliver)},
  };
  if (env->RegisterNatives(g_bridge, methods, 2) != JNI_OK) {
    LOGE("RegisterNatives failed");
    clearException(env);
    return JNI_ERR;
  }
  return JNI_VERSION_1_6;
}

// ── Dart → Kotlin (exported for dart:ffi) ───────────────────────────────

EXPORT void DeviceCalendarKitSetDispatcher(int64_t ptr) {
  JNIEnv* env = envForThisThread();
  if (env == nullptr || g_setDispatcher == nullptr) return;
  env->CallStaticVoidMethod(g_bridge, g_setDispatcher, static_cast<jlong>(ptr));
  clearException(env);
}

// A UTF-8 C string as a Java byte array (Kotlin decodes it as UTF-8).
static jbyteArray bytesOf(JNIEnv* env, const char* s) {
  if (s == nullptr) s = "";
  jsize len = static_cast<jsize>(strlen(s));
  jbyteArray arr = env->NewByteArray(len);
  if (arr == nullptr) return nullptr;
  env->SetByteArrayRegion(arr, 0, len, reinterpret_cast<const jbyte*>(s));
  return arr;
}

// 0 when Kotlin accepted the call, 2 for an unknown method, -2 when JNI is
// not ready, -3 when Kotlin threw.
EXPORT int32_t DeviceCalendarKitInvoke(int64_t token, const char* method,
                                       const char* argumentsJson) {
  JNIEnv* env = envForThisThread();
  if (env == nullptr || g_invoke == nullptr) return -2;
  jbyteArray jm = bytesOf(env, method);
  jbyteArray ja = bytesOf(env, argumentsJson ? argumentsJson : "null");
  if (jm == nullptr || ja == nullptr) {
    clearException(env);
    return -2;
  }
  jint rc = env->CallStaticIntMethod(g_bridge, g_invoke, static_cast<jlong>(token), jm, ja);
  env->DeleteLocalRef(jm);
  env->DeleteLocalRef(ja);
  if (env->ExceptionCheck()) {
    clearException(env);
    return -3;
  }
  return rc;
}
