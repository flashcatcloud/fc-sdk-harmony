#include "napi/native_api.h"
#include <cstdint>

// Demo-only: deliberately crash the native layer so the SDK's hiAppEvent
// APP_CRASH watcher captures a real C/C++ stack with a frame in libentry.so.
// This is what makes native-crash symbolication (Round 4) verifiable end-to-end.
// NEVER ship anything like this in production code.

static int FlashcatCrashDepthTwo() {
    volatile int *p = nullptr; // null deref → SIGSEGV
    return *p;
}

static int FlashcatCrashDepthOne() {
    return FlashcatCrashDepthTwo() + 1;
}

static napi_value TriggerNativeCrash(napi_env env, napi_callback_info info) {
    int v = FlashcatCrashDepthOne();
    napi_value result;
    napi_create_int32(env, v, &result);
    return result;
}

// A benign add() so the module is also useful as a sanity check that the .so loads.
static napi_value Add(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    double value0 = 0;
    double value1 = 0;
    napi_get_value_double(env, args[0], &value0);
    napi_get_value_double(env, args[1], &value1);

    napi_value sum;
    napi_create_double(env, value0 + value1, &sum);
    return sum;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"add", nullptr, Add, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"triggerNativeCrash", nullptr, TriggerNativeCrash, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void) {
    napi_module_register(&demoModule);
}
