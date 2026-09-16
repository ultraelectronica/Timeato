# Timeato

A Pomodoro focus timer for **Android**, with its core written **entirely in Zig**,
rendering its UI through [Zylix](https://github.com/kotsutsumi/zylix)'s virtual DOM.

There is no split business logic: the state machine, the view tree, and the
rendering model all live in Zig. The Android shell is a thin layer that loads
the native library, forwards taps and frame deltas, and paints the tree Zig
hands back.

## How it works

```
   tap ──► Java shell ──► nativeDispatch(code) ──┐
                                                  ▼
   frame ─► Java shell ──► nativeTick(delta_ms) ─► Zig core (engine.zig)
                                                  │
                    nativeRender() ──► JSON ◄─────┘  + Zylix VDOM (view.zig)
                         │
                         ▼
   Java shell renders the returned tree natively
```

- `engine.zig` is a pure state machine: no allocator, no IO, no platform code.
- `view.zig` builds the full UI as a Zylix `VTree` (`getReconciler().getNextTree()`)
  and serializes it to compact JSON.
- `main.zig` exposes the C ABI the Android bridge calls.
- `jni.zig` is the JNI bridge (`NativeBridge.*`); no Kotlin, Compose, C, or CMake.
- The Java shell owns no timer logic — it only counts frames and paints.

## Layout

```
src/engine.zig   Pomodoro state machine + tests
src/view.zig     Zylix VDOM tree builder + JSON serializer + tests
src/main.zig     C ABI exports for the Android bridge
src/jni.zig      JNI bridge for the Android shell
src/demo.zig     native demo, prints the rendered view
src/tests.zig    test aggregator
android/         Gradle app: Java shell + native view renderer
scripts/android.sh build the .so, copy into jniLibs, assemble/install the APK
build.zig        test / demo / android steps
```

## Requirements

- **Zig 0.15+** (0.15.2 verified)
- A checkout of **Zylix** at `../zylix` (only `core/src/vdom.zig` and its
  relative imports are used; nothing in the checkout is modified)
- Android SDK + NDK (path set by `ndk_include` in `build.zig`)

Override the Zylix path via `zylix_src` in `build.zig` if your checkout differs.

## Commands

```sh
zig build test                 # 15 unit tests (engine + view)
zig build demo                 # print the rendered view natively
zig build android              # -> zig-out/android/{arm64-v8a,x86_64}/libtimeato.so
```

`scripts/android.sh` builds the JNI library, drops it into the app's
`jniLibs`, and runs Gradle. It needs the Android SDK plus an NDK at the path
set by `ndk_include` in `build.zig`, and a device/emulator reachable by `adb`:

```sh
ZIG=/path/to/zig scripts/android.sh            # assemble a debug APK
ZIG=/path/to/zig scripts/android.sh --install  # install + launch on the device
```

## Behaviour

- 25 min focus, 5 min short break, 15 min long break every 4th focus session.
- Phases auto-advance; the last 6 sessions are kept in memory (newest first).
- No persistence — closing the app resets the session.
- Wall-clock correct: the tick uses the platform frame delta, so a backgrounded
  app still advances by the real elapsed time when it resumes.

## Status

- **Android**: complete and verified on a physical device (Android 15, arm64).
  The Zig core (including its JNI bridge, written in Zig) builds to
  `libtimeato.so`; the Java shell loads it, forwards taps and frame deltas, and
  paints the JSON view tree `view.zig` emits. No Kotlin, Compose, C, or CMake.
- **Native test/demo**: works.

## Notes on the Android shell

- Zig talks JNI directly via `@cImport("jni.h")` against the NDK sysroot
  headers (`ndk_include` in `build.zig`); there is no C wrapper and no CMake.
- `Java_com_timeato_app_NativeBridge_*` must match `NativeBridge.java`. The env
  parameter is `*c.JNIEnv` (JNI passes a pointer to the function table).
- targetSdk 35 draws edge-to-edge on Android 15, so `MainActivity` applies the
  system-bar insets as padding on the root view; `setStatusBarColor` alone is
  not enough.
