package com.timeato.app;

/**
 * Thin hop into the Zig core. Every method maps to a `Java_com_timeato_app_
 * NativeBridge_*` symbol exported by src/jni.zig; no logic lives here.
 */
final class NativeBridge {

    static {
        System.loadLibrary("timeato");
    }

    static native void nativeInit();

    static native void nativeDispatch(int code);

    static native void nativeTick(int deltaMs);

    static native int nativeRunning();

    static native String nativeRender();

    static native void nativeSetAlarm(int index);

    static native void nativeSetPhaseDuration(int phase, int ms);

    static native int nativePhaseDuration(int phase);

    private NativeBridge() {}
}
