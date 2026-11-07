/**
 * Real hiAppEvent MAIN_THREAD_JANK payloads captured on a HarmonyOS emulator (API 24)
 * from an app whose ArkTS timer callback busy-waited the main thread for 1 s, three
 * times back to back, with `setEventConfig` log_type 1 (stacks only); and a trace-only
 * one from the default config. The app's bundle name is replaced. Each pairs `params`
 * with the text of the external log it names.
 *
 * The sampler does not resolve ArkTS frames on this system image: the busy-waiting
 * functions appear as `[Unknown]` frames between the timer callback and the runtime.
 */

/** The most frequent single stack and the call tree's heaviest path agree: both end in the busy-wait. */
export function busyJankParams(): Record<string, Object> {
  const params: Record<string, Object> = {
    'app_start_jiffies_time': 70007,
    'begin_time': 1793317687500,
    'bundle_name': 'com.example.app',
    'bundle_version': '1.0.0',
    'end_time': 1793317688501,
    'external_log': ['/data/storage/el2/log/watchdog/MAIN_THREAD_JANK_20261030074810_15650.txt'],
    'heaviest_stack': 'heaviest stack: \\nstack counts: 5\\n#00 pc 0000000000000668 [vdso](__kernel_gettimeofday+40)\\n#01 pc 00000000001eb88c /system/lib/ld-musl-aarch64.so.1(gettimeofday+52)(e5b4d4ce83e5538298052bc2aa19dda3)\\n#02 pc 00000000005c2d68 /system/lib64/platformsdk/libark_jsruntime.so(288c26e6d639b21a16c12823f90d8168)\\n#03 pc 0000000000e179f4 /system/lib64/module/arkcompiler/stub.an(RTStub_PushCallArgsAndDispatchNative+40)\\n#04 pc 000000000046b900 /system/lib64/module/arkcompiler/stub.an(BCStub_HandleCallthis0Imm8V8StwCopy+392)\\n#05 pc 0000007fae923751 [Unknown]\\n#06 pc 0000007fae9236da [Unknown]\\n#07 pc 0000007fae923504 [Unknown]\\n#08 pc 00000000004ba504 /system/lib64/platformsdk/libark_jsruntime.so(288c26e6d639b21a16c12823f90d8168)\\n#09 pc 00000000007d98f0 /system/lib64/platformsdk/libark_jsruntime.so(panda::FunctionRef::CallForNapi(panda::ecmascript::EcmaVM const*, panda::JSValueRef*, panda::JSValueRef* const*, int)+1764)(288c26e6d639b21a16c12823f90d8168)\\n#10 pc 000000000006dbd8 /system/lib64/platformsdk/libace_napi.z.so(napi_call_function+300)(f212db6c534fd4d5225df352ee6109a1)\\n#11 pc 0000000000008664 /system/lib64/platformsdk/libtimer.z.so(OHOS::JsSysModule::Timer::TimerCallback(uv_timer_s*)+500)(929d6466a325579c89fc7a2ac7534fcc)\\n#12 pc 0000000000012b2c /system/lib64/platformsdk/libuv.so(1002b69fb34924db60f6297e5d8d9312)\\n#13 pc 00000000000160ec /system/lib64/platformsdk/libuv.so(uv_run+180)(1002b69fb34924db60f6297e5d8d9312)\\n#14 pc 000000000008734c /system/lib64/platformsdk/libruntime.z.so(OHOS::AbilityRuntime::OHOSLoopHandler::OnTriggered()+92)(de4d1333ae6026d5abb92ab679eab9c6)\\n#15 pc 00000000000875e8 /system/lib64/platformsdk/libruntime.z.so(de4d1333ae6026d5abb92ab679eab9c6)\\n#16 pc 000000000001a998 /system/lib64/chipset-sdk-sp/libeventhandler.z.so(OHOS::AppExecFwk::EventHandler::DistributeEvent(std::__h::unique_ptr<OHOS::AppExecFwk::InnerEvent, void (*)(OHOS::AppExecFwk::InnerEvent*)> const&)+964)(29416e98677bf8eb4235f6de65b3e041)\\n#17 pc 000000000002e9f0 /system/lib64/chipset-sdk-sp/libeventhandler.z.so(29416e98677bf8eb4235f6de65b3e041)\\n#18 pc 000000000002e1d8 /system/lib64/chipset-sdk-sp/libeventhandler.z.so(29416e98677bf8eb4235f6de65b3e041)\\n#19 pc 000000000002c0fc /system/lib64/chipset-sdk-sp/libeventhandler.z.so(OHOS::AppExecFwk::EventRunner::Run()+492)(29416e98677bf8eb4235f6de65b3e041)\\n#20 pc 00000000000ebcc4 /system/lib64/platformsdk/libappkit_native.z.so(OHOS::AppExecFwk::MainThread::Start()+244)(8b20e9a7567f69eaaa6caabfe12c7e83)\\n#21 pc 000000000000a154 /system/lib64/appspawn/appspawn/libappspawn_ace.z.so(a5807e1e9c611d007485842ddafac820)\\n#22 pc 000000000000c0bc /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)\\n#23 pc 0000000000015be0 /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)\\n#24 pc 0000000000013e40 /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)\\n#25 pc 0000000000017534 /system/lib64/chipset-sdk-sp/libbegetutil.z.so(02cad22421954ab0b03cd6d48832db79)\\n#26 pc 0000000000016fc0 /system/lib64/chipset-sdk-sp/libbegetutil.z.so(02cad22421954ab0b03cd6d48832db79)\\n#27 pc 00000000000144fc /system/lib64/chipset-sdk-sp/libbegetutil.z.so(02cad22421954ab0b03cd6d48832db79)\\n#28 pc 00000000000140b8 /system/lib64/chipset-sdk-sp/libbegetutil.z.so(02cad22421954ab0b03cd6d48832db79)\\n#29 pc 0000000000011750 /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)\\n#30 pc 000000000000f248 /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)\\n#31 pc 00000000000b1be8 /system/lib/ld-musl-aarch64.so.1(e5b4d4ce83e5538298052bc2aa19dda3)\\n#32 pc 000000000000be94 /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)\\n',
    'log_over_limit': false,
    'pid': 15650,
    'time': 1793317690154,
    'uid': 20020092
  };
  return params;
}

export const BUSY_JANK_EXTERNAL_LOG: string = [
  '10 #00 pc 000000000000be94 /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)',
  '  10 #01 pc 00000000000b1be8 /system/lib/ld-musl-aarch64.so.1(e5b4d4ce83e5538298052bc2aa19dda3)',
  '    10 #02 pc 000000000000f248 /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)',
  '      10 #03 pc 0000000000011750 /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)',
  '        10 #04 pc 00000000000140b8 /system/lib64/chipset-sdk-sp/libbegetutil.z.so(02cad22421954ab0b03cd6d48832db79)',
  '          10 #05 pc 00000000000144fc /system/lib64/chipset-sdk-sp/libbegetutil.z.so(02cad22421954ab0b03cd6d48832db79)',
  '            10 #06 pc 0000000000016fc0 /system/lib64/chipset-sdk-sp/libbegetutil.z.so(02cad22421954ab0b03cd6d48832db79)',
  '              10 #07 pc 0000000000017534 /system/lib64/chipset-sdk-sp/libbegetutil.z.so(02cad22421954ab0b03cd6d48832db79)',
  '                10 #08 pc 0000000000013e40 /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)',
  '                  10 #09 pc 0000000000015be0 /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)',
  '                    10 #10 pc 000000000000c0bc /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)',
  '                      10 #11 pc 000000000000a154 /system/lib64/appspawn/appspawn/libappspawn_ace.z.so(a5807e1e9c611d007485842ddafac820)',
  '                        10 #12 pc 00000000000ebcc4 /system/lib64/platformsdk/libappkit_native.z.so(OHOS::AppExecFwk::MainThread::Start()+244)(8b20e9a7567f69eaaa6caabfe12c7e83)',
  '                          10 #13 pc 000000000002c0fc /system/lib64/chipset-sdk-sp/libeventhandler.z.so(OHOS::AppExecFwk::EventRunner::Run()+492)(29416e98677bf8eb4235f6de65b3e041)',
  '                            10 #14 pc 000000000002e1d8 /system/lib64/chipset-sdk-sp/libeventhandler.z.so(29416e98677bf8eb4235f6de65b3e041)',
  '                              10 #15 pc 000000000002e9f0 /system/lib64/chipset-sdk-sp/libeventhandler.z.so(29416e98677bf8eb4235f6de65b3e041)',
  '                                10 #16 pc 000000000001a998 /system/lib64/chipset-sdk-sp/libeventhandler.z.so(OHOS::AppExecFwk::EventHandler::DistributeEvent(std::__h::unique_ptr<OHOS::AppExecFwk::InnerEvent, void (*)(OHOS::AppExecFwk::InnerEvent*)> const&)+964)(29416e98677bf8eb4235f6de65b3e041)',
  '                                  10 #17 pc 00000000000875e8 /system/lib64/platformsdk/libruntime.z.so(de4d1333ae6026d5abb92ab679eab9c6)',
  '                                    10 #18 pc 000000000008734c /system/lib64/platformsdk/libruntime.z.so(OHOS::AbilityRuntime::OHOSLoopHandler::OnTriggered()+92)(de4d1333ae6026d5abb92ab679eab9c6)',
  '                                      10 #19 pc 00000000000160ec /system/lib64/platformsdk/libuv.so(uv_run+180)(1002b69fb34924db60f6297e5d8d9312)',
  '                                        10 #20 pc 0000000000012b2c /system/lib64/platformsdk/libuv.so(1002b69fb34924db60f6297e5d8d9312)',
  '                                          10 #21 pc 0000000000008664 /system/lib64/platformsdk/libtimer.z.so(OHOS::JsSysModule::Timer::TimerCallback(uv_timer_s*)+500)(929d6466a325579c89fc7a2ac7534fcc)',
  '                                            10 #22 pc 000000000006dbd8 /system/lib64/platformsdk/libace_napi.z.so(napi_call_function+300)(f212db6c534fd4d5225df352ee6109a1)',
  '                                              10 #23 pc 00000000007d98f0 /system/lib64/platformsdk/libark_jsruntime.so(panda::FunctionRef::CallForNapi(panda::ecmascript::EcmaVM const*, panda::JSValueRef*, panda::JSValueRef* const*, int)+1764)(288c26e6d639b21a16c12823f90d8168)',
  '                                                10 #24 pc 00000000004ba504 /system/lib64/platformsdk/libark_jsruntime.so(288c26e6d639b21a16c12823f90d8168)',
  '                                                  10 #25 pc 0000007fae923504 [Unknown]',
  '                                                    10 #26 pc 0000007fae9236da [Unknown]',
  '                                                      10 #27 pc 0000007fae923751 [Unknown]',
  '                                                        6 #28 pc 000000000046b900 /system/lib64/module/arkcompiler/stub.an(BCStub_HandleCallthis0Imm8V8StwCopy+392)',
  '                                                          6 #29 pc 0000000000e179f4 /system/lib64/module/arkcompiler/stub.an(RTStub_PushCallArgsAndDispatchNative+40)',
  '                                                            6 #30 pc 00000000005c2d68 /system/lib64/platformsdk/libark_jsruntime.so(288c26e6d639b21a16c12823f90d8168)',
  '                                                              6 #31 pc 00000000001eb88c /system/lib/ld-musl-aarch64.so.1(gettimeofday+52)(e5b4d4ce83e5538298052bc2aa19dda3)',
  '                                                                5 #32 pc 0000000000000668 [vdso](__kernel_gettimeofday+40)',
  '                                                                1 #32 pc 0000000000000664 [vdso](__kernel_gettimeofday+36)',
  '                                                        2 #28 pc 00000000004aa924 /system/lib64/module/arkcompiler/stub.an(BCStub_HandleLdaV8StwCopy+12)',
  '                                                        1 #28 pc 000000000045bce4 /system/lib64/module/arkcompiler/stub.an(BCStub_HandleAdd2Imm8V8StwCopy+16)',
  '                                                        1 #28 pc 00000000004aa938 /system/lib64/module/arkcompiler/stub.an(BCStub_HandleStaV8StwCopy+12)'
].join('\n');

/**
 * `heaviest_stack` is the idle event loop (epoll_wait, 4 samples), while the call tree
 * shows 6 of the 10 samples in the timer callback, spread over several leaves.
 */
export function idleHeaviestJankParams(): Record<string, Object> {
  const params: Record<string, Object> = {
    'app_start_jiffies_time': 70635,
    'begin_time': 1793317766564,
    'bundle_name': 'com.example.app',
    'bundle_version': '1.0.0',
    'end_time': 1793317767564,
    'external_log': ['/data/storage/el2/log/watchdog/MAIN_THREAD_JANK_20261030074929_15856.txt'],
    'heaviest_stack': 'heaviest stack: \\nstack counts: 4\\n#00 pc 000000000017a82c /system/lib/ld-musl-aarch64.so.1(epoll_wait+80)(e5b4d4ce83e5538298052bc2aa19dda3)\\n#01 pc 00000000000184b0 /system/lib64/chipset-sdk-sp/libeventhandler.z.so(29416e98677bf8eb4235f6de65b3e041)\\n#02 pc 000000000001e8ec /system/lib64/chipset-sdk-sp/libeventhandler.z.so(OHOS::AppExecFwk::EventQueue::WaitUntilLocked(std::__h::chrono::time_point<std::__h::chrono::steady_clock, std::__h::chrono::duration<long long, std::__h::ratio<1l, 1000000000l>>> const&, OHOS::AppExecFwk::UniqueLockBase&, bool)+112)(29416e98677bf8eb4235f6de65b3e041)\\n#03 pc 0000000000023c2c /system/lib64/chipset-sdk-sp/libeventhandler.z.so(OHOS::AppExecFwk::EventQueueBase::GetEvent()+176)(29416e98677bf8eb4235f6de65b3e041)\\n#04 pc 000000000002e1f4 /system/lib64/chipset-sdk-sp/libeventhandler.z.so(29416e98677bf8eb4235f6de65b3e041)\\n#05 pc 000000000002c0fc /system/lib64/chipset-sdk-sp/libeventhandler.z.so(OHOS::AppExecFwk::EventRunner::Run()+492)(29416e98677bf8eb4235f6de65b3e041)\\n#06 pc 00000000000ebcc4 /system/lib64/platformsdk/libappkit_native.z.so(OHOS::AppExecFwk::MainThread::Start()+244)(8b20e9a7567f69eaaa6caabfe12c7e83)\\n#07 pc 000000000000a154 /system/lib64/appspawn/appspawn/libappspawn_ace.z.so(a5807e1e9c611d007485842ddafac820)\\n#08 pc 000000000000c0bc /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)\\n#09 pc 0000000000015be0 /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)\\n#10 pc 0000000000013e40 /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)\\n#11 pc 0000000000017534 /system/lib64/chipset-sdk-sp/libbegetutil.z.so(02cad22421954ab0b03cd6d48832db79)\\n#12 pc 0000000000016fc0 /system/lib64/chipset-sdk-sp/libbegetutil.z.so(02cad22421954ab0b03cd6d48832db79)\\n#13 pc 00000000000144fc /system/lib64/chipset-sdk-sp/libbegetutil.z.so(02cad22421954ab0b03cd6d48832db79)\\n#14 pc 00000000000140b8 /system/lib64/chipset-sdk-sp/libbegetutil.z.so(02cad22421954ab0b03cd6d48832db79)\\n#15 pc 0000000000011750 /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)\\n#16 pc 000000000000f248 /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)\\n#17 pc 00000000000b1be8 /system/lib/ld-musl-aarch64.so.1(e5b4d4ce83e5538298052bc2aa19dda3)\\n#18 pc 000000000000be94 /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)\\n',
    'log_over_limit': false,
    'pid': 15856,
    'time': 1793317769221,
    'uid': 20020092
  };
  return params;
}

export const IDLE_HEAVIEST_JANK_EXTERNAL_LOG: string = [
  '10 #00 pc 000000000000be94 /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)',
  '  10 #01 pc 00000000000b1be8 /system/lib/ld-musl-aarch64.so.1(e5b4d4ce83e5538298052bc2aa19dda3)',
  '    10 #02 pc 000000000000f248 /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)',
  '      10 #03 pc 0000000000011750 /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)',
  '        10 #04 pc 00000000000140b8 /system/lib64/chipset-sdk-sp/libbegetutil.z.so(02cad22421954ab0b03cd6d48832db79)',
  '          10 #05 pc 00000000000144fc /system/lib64/chipset-sdk-sp/libbegetutil.z.so(02cad22421954ab0b03cd6d48832db79)',
  '            10 #06 pc 0000000000016fc0 /system/lib64/chipset-sdk-sp/libbegetutil.z.so(02cad22421954ab0b03cd6d48832db79)',
  '              10 #07 pc 0000000000017534 /system/lib64/chipset-sdk-sp/libbegetutil.z.so(02cad22421954ab0b03cd6d48832db79)',
  '                10 #08 pc 0000000000013e40 /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)',
  '                  10 #09 pc 0000000000015be0 /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)',
  '                    10 #10 pc 000000000000c0bc /system/bin/appspawn(9403a753b1b2191080a21eb13369c4f8)',
  '                      10 #11 pc 000000000000a154 /system/lib64/appspawn/appspawn/libappspawn_ace.z.so(a5807e1e9c611d007485842ddafac820)',
  '                        10 #12 pc 00000000000ebcc4 /system/lib64/platformsdk/libappkit_native.z.so(OHOS::AppExecFwk::MainThread::Start()+244)(8b20e9a7567f69eaaa6caabfe12c7e83)',
  '                          10 #13 pc 000000000002c0fc /system/lib64/chipset-sdk-sp/libeventhandler.z.so(OHOS::AppExecFwk::EventRunner::Run()+492)(29416e98677bf8eb4235f6de65b3e041)',
  '                            6 #14 pc 000000000002e1d8 /system/lib64/chipset-sdk-sp/libeventhandler.z.so(29416e98677bf8eb4235f6de65b3e041)',
  '                              6 #15 pc 000000000002e9f0 /system/lib64/chipset-sdk-sp/libeventhandler.z.so(29416e98677bf8eb4235f6de65b3e041)',
  '                                6 #16 pc 000000000001a998 /system/lib64/chipset-sdk-sp/libeventhandler.z.so(OHOS::AppExecFwk::EventHandler::DistributeEvent(std::__h::unique_ptr<OHOS::AppExecFwk::InnerEvent, void (*)(OHOS::AppExecFwk::InnerEvent*)> const&)+964)(29416e98677bf8eb4235f6de65b3e041)',
  '                                  6 #17 pc 00000000000875e8 /system/lib64/platformsdk/libruntime.z.so(de4d1333ae6026d5abb92ab679eab9c6)',
  '                                    6 #18 pc 000000000008734c /system/lib64/platformsdk/libruntime.z.so(OHOS::AbilityRuntime::OHOSLoopHandler::OnTriggered()+92)(de4d1333ae6026d5abb92ab679eab9c6)',
  '                                      6 #19 pc 00000000000160ec /system/lib64/platformsdk/libuv.so(uv_run+180)(1002b69fb34924db60f6297e5d8d9312)',
  '                                        6 #20 pc 0000000000012b2c /system/lib64/platformsdk/libuv.so(1002b69fb34924db60f6297e5d8d9312)',
  '                                          6 #21 pc 0000000000008664 /system/lib64/platformsdk/libtimer.z.so(OHOS::JsSysModule::Timer::TimerCallback(uv_timer_s*)+500)(929d6466a325579c89fc7a2ac7534fcc)',
  '                                            6 #22 pc 000000000006dbd8 /system/lib64/platformsdk/libace_napi.z.so(napi_call_function+300)(f212db6c534fd4d5225df352ee6109a1)',
  '                                              6 #23 pc 00000000007d98f0 /system/lib64/platformsdk/libark_jsruntime.so(panda::FunctionRef::CallForNapi(panda::ecmascript::EcmaVM const*, panda::JSValueRef*, panda::JSValueRef* const*, int)+1764)(288c26e6d639b21a16c12823f90d8168)',
  '                                                6 #24 pc 00000000004ba504 /system/lib64/platformsdk/libark_jsruntime.so(288c26e6d639b21a16c12823f90d8168)',
  '                                                  6 #25 pc 0000007fae923504 [Unknown]',
  '                                                    6 #26 pc 0000007fae9236da [Unknown]',
  '                                                      6 #27 pc 0000007fae923751 [Unknown]',
  '                                                        4 #28 pc 000000000046b900 /system/lib64/module/arkcompiler/stub.an(BCStub_HandleCallthis0Imm8V8StwCopy+392)',
  '                                                          4 #29 pc 0000000000e179f4 /system/lib64/module/arkcompiler/stub.an(RTStub_PushCallArgsAndDispatchNative+40)',
  '                                                            4 #30 pc 00000000005c2d68 /system/lib64/platformsdk/libark_jsruntime.so(288c26e6d639b21a16c12823f90d8168)',
  '                                                              3 #31 pc 00000000001eb88c /system/lib/ld-musl-aarch64.so.1(gettimeofday+52)(e5b4d4ce83e5538298052bc2aa19dda3)',
  '                                                                2 #32 pc 0000000000000668 [vdso](__kernel_gettimeofday+40)',
  '                                                                1 #32 pc 0000000000000664 [vdso](__kernel_gettimeofday+36)',
  '                                                              1 #31 pc 00000000001eb880 /system/lib/ld-musl-aarch64.so.1(gettimeofday+40)(e5b4d4ce83e5538298052bc2aa19dda3)',
  '                                                        1 #28 pc 000000000045bce4 /system/lib64/module/arkcompiler/stub.an(BCStub_HandleAdd2Imm8V8StwCopy+16)',
  '                                                        1 #28 pc 0000000000485bcc /system/lib64/module/arkcompiler/stub.an(BCStub_HandleLdobjbynameImm8Id16StwCopy+5468)',
  '                            4 #14 pc 000000000002e1f4 /system/lib64/chipset-sdk-sp/libeventhandler.z.so(29416e98677bf8eb4235f6de65b3e041)',
  '                              4 #15 pc 0000000000023c2c /system/lib64/chipset-sdk-sp/libeventhandler.z.so(OHOS::AppExecFwk::EventQueueBase::GetEvent()+176)(29416e98677bf8eb4235f6de65b3e041)',
  '                                4 #16 pc 000000000001e8ec /system/lib64/chipset-sdk-sp/libeventhandler.z.so(OHOS::AppExecFwk::EventQueue::WaitUntilLocked(std::__h::chrono::time_point<std::__h::chrono::steady_clock, std::__h::chrono::duration<long long, std::__h::ratio<1l, 1000000000l>>> const&, OHOS::AppExecFwk::UniqueLockBase&, bool)+112)(29416e98677bf8eb4235f6de65b3e041)',
  '                                  4 #17 pc 00000000000184b0 /system/lib64/chipset-sdk-sp/libeventhandler.z.so(29416e98677bf8eb4235f6de65b3e041)',
  '                                    4 #18 pc 000000000017a82c /system/lib/ld-musl-aarch64.so.1(epoll_wait+80)(e5b4d4ce83e5538298052bc2aa19dda3)'
].join('\n');

/** Default config, 1 s task: a trace is collected instead of stacks — no `heaviest_stack`, a binary log. */
export function traceOnlyJankParams(): Record<string, Object> {
  const params: Record<string, Object> = {
    'begin_time': 1793317882187,
    'bundle_name': 'com.example.app',
    'bundle_version': '1.0.0',
    'end_time': 1793317883187,
    'external_log': ['/data/storage/el2/log/watchdog/MAIN_THREAD_JANK_1793317886185_18309.trace'],
    'log_over_limit': false,
    'pid': 18309,
    'time': 1793317883187,
    'uid': 20020092
  };
  return params;
}
