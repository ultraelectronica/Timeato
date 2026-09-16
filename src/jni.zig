//! JNI bridge for the Android shell.
//!
//! Kotlin pushes actions and frame deltas in and pulls the same JSON view the
//! web shell consumes. No logic lives here: it is a name-mangled hop into the
//! Zig core. Symbols must match the `external fun`s in `NativeBridge.kt`.

const c = @cImport({
    @cInclude("jni.h");
});

const core = @import("main.zig");

export fn Java_com_timeato_app_NativeBridge_nativeInit(env: *c.JNIEnv, clazz: c.jclass) void {
    _ = env;
    _ = clazz;
    core.timeato_init();
}

export fn Java_com_timeato_app_NativeBridge_nativeDispatch(env: *c.JNIEnv, clazz: c.jclass, code: c.jint) void {
    _ = env;
    _ = clazz;
    core.timeato_dispatch(@intCast(code));
}

export fn Java_com_timeato_app_NativeBridge_nativeTick(env: *c.JNIEnv, clazz: c.jclass, delta_ms: c.jint) void {
    _ = env;
    _ = clazz;
    if (delta_ms > 0) core.timeato_tick(@intCast(delta_ms));
}

export fn Java_com_timeato_app_NativeBridge_nativeRunning(env: *c.JNIEnv, clazz: c.jclass) c.jint {
    _ = env;
    _ = clazz;
    return @intCast(core.timeato_running());
}

export fn Java_com_timeato_app_NativeBridge_nativeRender(env: *c.JNIEnv, clazz: c.jclass) c.jstring {
    _ = clazz;
    const json = core.timeato_render();
    return env.*.*.NewStringUTF.?(env, @ptrCast(json));
}
