# Timeato

A Pomodoro focus timer written **entirely in Zig**, rendering its UI through
[Zylix](https://github.com/kotsutsumi/zylix)'s virtual DOM.

There is no Zig/JavaScript business logic split: the state machine, the view
tree, and the DOM diffing model all live in Zig. The web layer is a thin shell
that loads the WebAssembly module, forwards clicks, and applies the tree Zig
hands back.

## How it works

```
  click ──► JS shell ──► timeato_dispatch(code) ──┐
                                                   ▼
  rAF ───► JS shell ──► timeato_tick(delta_ms) ──► Zig core (engine.zig)
                                                   │
                     timeato_render() ──► JSON ◄───┘  + Zylix VDOM (view.zig)
                         │
                         ▼
  JS shell morphs the returned tree into the DOM
```

- `engine.zig` is a pure state machine: no allocator, no IO, no platform code.
- `view.zig` builds the full UI as a Zylix `VTree` (`getReconciler().getNextTree()`)
  and serializes it to compact JSON.
- `main.zig` exposes the C ABI the platforms call.
- The JS shell owns no timer logic — it only counts frames and paints.

## Layout

```
src/engine.zig   Pomodoro state machine + tests
src/view.zig     Zylix VDOM tree builder + JSON serializer + tests
src/main.zig     C ABI exports for wasm / Android
src/jni.zig      JNI bridge for the Android shell
src/demo.zig     native demo, prints the rendered view
src/tests.zig    test aggregator
web/             index.html + timeato.js shell (wasm lands here at build time)
android/         Gradle app: Java shell + native view renderer
scripts/build.sh   build wasm, copy it into web/, optionally serve
scripts/android.sh build the .so, copy into jniLibs, assemble/install the APK
build.zig        test / demo / wasm / android steps
```

## Requirements

- **Zig 0.15+** (0.15.2 verified)
- A checkout of **Zylix** at `../zylix` (only `core/src/vdom.zig` and its
  relative imports are used; nothing in the checkout is modified)

Override the Zylix path via `zylix_src` in `build.zig` if your checkout differs.

## Commands

```sh
zig build test                 # 15 unit tests (engine + view)
zig build demo                 # print the rendered view natively
zig build wasm -Doptimize=ReleaseSmall   # -> zig-out/wasm/timeato.wasm
zig build android              # -> zig-out/android/{arm64-v8a,x86_64}/libtimeato.so
```

`scripts/build.sh` wraps the wasm build and copies the artifact into `web/`:

```sh
ZIG=/path/to/zig scripts/build.sh            # release build + copy
ZIG=/path/to/zig scripts/build.sh debug      # debug build
ZIG=/path/to/zig scripts/build.sh --serve    # build, copy, serve on :8080
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

- **Web/WASM**: complete and verified (headless Chromium at 390x844 mobile).
- **Android**: complete and verified on a physical device (Android 15, arm64).
  The Zig core (including its JNI bridge, written in Zig) builds to
  `libtimeato.so`; the Java shell loads it, forwards taps and frame deltas, and
  paints the JSON view tree `view.zig` emits. No Kotlin, Compose, C, or CMake.
- **Native test/demo**: works.
- Upstream `zig build test-lib` fails in the AI modules (`coreml.zig`,
  `llama_cpp.zig`, `whisper_cpp.zig` need missing C sources). Timeato does not
  import those modules, so this does not affect us.

## Notes on the Android shell

- Zig talks JNI directly via `@cImport("jni.h")` against the NDK sysroot
  headers (`ndk_include` in `build.zig`); there is no C wrapper and no CMake.
- `Java_com_timeato_app_NativeBridge_*` must match `NativeBridge.java`. The env
  parameter is `*c.JNIEnv` (JNI passes a pointer to the function table).
- targetSdk 35 draws edge-to-edge on Android 15, so `MainActivity` applies the
  system-bar insets as padding on the root view; `setStatusBarColor` alone is
  not enough.
