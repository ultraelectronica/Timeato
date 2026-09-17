package com.timeato.app;

import android.content.Context;
import android.content.SharedPreferences;

/**
 * Persists the per-phase session lengths picked on the duration tape.
 *
 * Index order matches engine.phaseFromIndex: 0 focus, 1 short break, 2 long
 * break. The Zig core stays the source of truth; the shell only mirrors values
 * it commits so they survive process death.
 */
final class DurationPrefs {

    static final int PHASE_COUNT = 3;

    private static final String PREFS = "timeato";
    private static final String[] KEYS = {"focus_ms", "short_ms", "long_ms"};

    static boolean has(Context ctx, int phase) {
        if (phase < 0 || phase >= PHASE_COUNT) return false;
        try {
            return ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).contains(KEYS[phase]);
        } catch (Exception e) {
            return false;
        }
    }

    static int load(Context ctx, int phase) {
        if (phase < 0 || phase >= PHASE_COUNT) return 0;
        try {
            return ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getInt(KEYS[phase], 0);
        } catch (Exception e) {
            return 0;
        }
    }

    static void save(Context ctx, int phase, int ms) {
        if (phase < 0 || phase >= PHASE_COUNT) return;
        try {
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    .edit()
                    .putInt(KEYS[phase], ms)
                    .apply();
        } catch (Exception ignored) {
        }
    }

    private DurationPrefs() {}
}
