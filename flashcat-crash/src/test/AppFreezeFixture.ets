/**
 * A real hiAppEvent APP_FREEZE payload captured on a HarmonyOS emulator (API 24),
 * trimmed to the fields the mapper reads and two of its 39 threads; the app's
 * bundle and file names are replaced. The main thread is listed second so the
 * tests prove it is selected by `tid === pid`, not by position.
 */
export const APP_FREEZE_PID: number = 3097;

export function appFreezeParams(dumpStartTime: string): Record<string, Object> {
  const exception: Record<string, Object> = {
    'name': 'THREAD_BLOCK_6S',
    'message': `App main thread is not response!Main handler dump start time: ${dumpStartTime}`
  };
  const watchdogFrames: Array<Record<string, Object>> = [
    { 'buildId': 'e5b4d4ce83e5538298052bc2aa19dda3', 'file': '/system/lib/ld-musl-aarch64.so.1', 'offset': 0, 'pc': '00000000001df218', 'symbol': '' },
    { 'buildId': 'e5b4d4ce83e5538298052bc2aa19dda3', 'file': '/system/lib/ld-musl-aarch64.so.1', 'offset': 188, 'pc': '00000000001e1378', 'symbol': 'pthread_cond_timedwait' },
    { 'buildId': '40ba545878d2c82cd35793396ae407b45e4facf2', 'file': '/system/lib64/chipset-sdk-sp/libc++.so', 'offset': 116, 'pc': '00000000000c18ac', 'symbol': 'std::__h::condition_variable::__do_timed_wait(std::__h::unique_lock<std::__h::mutex>&, std::__h::chrono::time_point<std::__h::chrono::system_clock, std::__h::chrono::duration<long long, std::__h::ratio<1l, 1000000000l>>>)' },
    { 'buildId': '43527b320a20631a6ae2c646733c6a81', 'file': '/system/lib64/chipset-sdk-sp/libhicollie.z.so', 'offset': 0, 'pc': '000000000001d620', 'symbol': '' },
    { 'buildId': '43527b320a20631a6ae2c646733c6a81', 'file': '/system/lib64/chipset-sdk-sp/libhicollie.z.so', 'offset': 0, 'pc': '0000000000027764', 'symbol': '' },
    { 'buildId': 'e5b4d4ce83e5538298052bc2aa19dda3', 'file': '/system/lib/ld-musl-aarch64.so.1', 'offset': 0, 'pc': '00000000001e3b3c', 'symbol': '' },
    { 'buildId': 'e5b4d4ce83e5538298052bc2aa19dda3', 'file': '/system/lib/ld-musl-aarch64.so.1', 'offset': 0, 'pc': '00000000000b33cc', 'symbol': '' }
  ];
  const mainFrames: Array<Record<string, Object>> = [
    { 'buildId': '', 'file': '/system/lib64/module/arkcompiler/stub.an', 'offset': 8, 'pc': '0000000000458028', 'symbol': 'BCStub_HandleLdtrueStwCopy' },
    { 'column': 9, 'file': 'entry/src/main/ets/pages/Index.ets', 'line': 175, 'packageName': 'entry', 'symbol': 'anonymous' },
    { 'buildId': '288c26e6d639b21a16c12823f90d8168', 'file': '/system/lib64/platformsdk/libark_jsruntime.so', 'offset': 0, 'pc': '00000000004ba504', 'symbol': '' },
    { 'buildId': '288c26e6d639b21a16c12823f90d8168', 'file': '/system/lib64/platformsdk/libark_jsruntime.so', 'offset': 1764, 'pc': '00000000007d98f0', 'symbol': 'panda::FunctionRef::CallForNapi(panda::ecmascript::EcmaVM const*, panda::JSValueRef*, panda::JSValueRef* const*, int)' },
    { 'buildId': 'f212db6c534fd4d5225df352ee6109a1', 'file': '/system/lib64/platformsdk/libace_napi.z.so', 'offset': 300, 'pc': '000000000006dbd8', 'symbol': 'napi_call_function' },
    { 'buildId': '929d6466a325579c89fc7a2ac7534fcc', 'file': '/system/lib64/platformsdk/libtimer.z.so', 'offset': 500, 'pc': '0000000000008664', 'symbol': 'OHOS::JsSysModule::Timer::TimerCallback(uv_timer_s*)' },
    { 'buildId': '1002b69fb34924db60f6297e5d8d9312', 'file': '/system/lib64/platformsdk/libuv.so', 'offset': 0, 'pc': '0000000000012b2c', 'symbol': '' },
    { 'buildId': '1002b69fb34924db60f6297e5d8d9312', 'file': '/system/lib64/platformsdk/libuv.so', 'offset': 180, 'pc': '00000000000160ec', 'symbol': 'uv_run' },
    { 'buildId': 'de4d1333ae6026d5abb92ab679eab9c6', 'file': '/system/lib64/platformsdk/libruntime.z.so', 'offset': 92, 'pc': '000000000008734c', 'symbol': 'OHOS::AbilityRuntime::OHOSLoopHandler::OnTriggered()' },
    { 'buildId': 'de4d1333ae6026d5abb92ab679eab9c6', 'file': '/system/lib64/platformsdk/libruntime.z.so', 'offset': 0, 'pc': '00000000000875e8', 'symbol': '' },
    { 'buildId': '29416e98677bf8eb4235f6de65b3e041', 'file': '/system/lib64/chipset-sdk-sp/libeventhandler.z.so', 'offset': 964, 'pc': '000000000001a998', 'symbol': 'OHOS::AppExecFwk::EventHandler::DistributeEvent(std::__h::unique_ptr<OHOS::AppExecFwk::InnerEvent, void (*)(OHOS::AppExecFwk::InnerEvent*)> const&)' },
    { 'buildId': '29416e98677bf8eb4235f6de65b3e041', 'file': '/system/lib64/chipset-sdk-sp/libeventhandler.z.so', 'offset': 0, 'pc': '000000000002e9f0', 'symbol': '' },
    { 'buildId': '29416e98677bf8eb4235f6de65b3e041', 'file': '/system/lib64/chipset-sdk-sp/libeventhandler.z.so', 'offset': 0, 'pc': '000000000002e1d8', 'symbol': '' },
    { 'buildId': '29416e98677bf8eb4235f6de65b3e041', 'file': '/system/lib64/chipset-sdk-sp/libeventhandler.z.so', 'offset': 492, 'pc': '000000000002c0fc', 'symbol': 'OHOS::AppExecFwk::EventRunner::Run()' },
    { 'buildId': '8b20e9a7567f69eaaa6caabfe12c7e83', 'file': '/system/lib64/platformsdk/libappkit_native.z.so', 'offset': 244, 'pc': '00000000000ebcc4', 'symbol': 'OHOS::AppExecFwk::MainThread::Start()' },
    { 'buildId': 'a5807e1e9c611d007485842ddafac820', 'file': '/system/lib64/appspawn/appspawn/libappspawn_ace.z.so', 'offset': 0, 'pc': '000000000000a154', 'symbol': '' },
    { 'buildId': '9403a753b1b2191080a21eb13369c4f8', 'file': '/system/bin/appspawn', 'offset': 0, 'pc': '000000000000c0bc', 'symbol': '' },
    { 'buildId': '9403a753b1b2191080a21eb13369c4f8', 'file': '/system/bin/appspawn', 'offset': 0, 'pc': '0000000000015be0', 'symbol': '' },
    { 'buildId': '9403a753b1b2191080a21eb13369c4f8', 'file': '/system/bin/appspawn', 'offset': 0, 'pc': '0000000000013e40', 'symbol': '' },
    { 'buildId': '02cad22421954ab0b03cd6d48832db79', 'file': '/system/lib64/chipset-sdk-sp/libbegetutil.z.so', 'offset': 0, 'pc': '0000000000017534', 'symbol': '' },
    { 'buildId': '02cad22421954ab0b03cd6d48832db79', 'file': '/system/lib64/chipset-sdk-sp/libbegetutil.z.so', 'offset': 0, 'pc': '0000000000016fc0', 'symbol': '' },
    { 'buildId': '02cad22421954ab0b03cd6d48832db79', 'file': '/system/lib64/chipset-sdk-sp/libbegetutil.z.so', 'offset': 0, 'pc': '00000000000144fc', 'symbol': '' },
    { 'buildId': '02cad22421954ab0b03cd6d48832db79', 'file': '/system/lib64/chipset-sdk-sp/libbegetutil.z.so', 'offset': 0, 'pc': '00000000000140b8', 'symbol': '' },
    { 'buildId': '9403a753b1b2191080a21eb13369c4f8', 'file': '/system/bin/appspawn', 'offset': 0, 'pc': '0000000000011750', 'symbol': '' },
    { 'buildId': '9403a753b1b2191080a21eb13369c4f8', 'file': '/system/bin/appspawn', 'offset': 0, 'pc': '000000000000f248', 'symbol': '' },
    { 'buildId': 'e5b4d4ce83e5538298052bc2aa19dda3', 'file': '/system/lib/ld-musl-aarch64.so.1', 'offset': 0, 'pc': '00000000000b1be8', 'symbol': '' },
    { 'buildId': '9403a753b1b2191080a21eb13369c4f8', 'file': '/system/bin/appspawn', 'offset': 0, 'pc': '000000000000be94', 'symbol': '' }
  ];
  const threads: Array<Record<string, Object>> = [
    { 'thread_name': 'OS_DfxWatchdog', 'tid': 3145, 'state': 'S', 'frames': watchdogFrames },
    { 'thread_name': 'example.app', 'tid': APP_FREEZE_PID, 'state': 'R', 'frames': mainFrames }
  ];
  const params: Record<string, Object> = {
    'exception': exception,
    'pid': APP_FREEZE_PID,
    'time': 1793116300990,
    'cpu_abi': 'arm64-v8a',
    'threads': threads
  };
  return params;
}
