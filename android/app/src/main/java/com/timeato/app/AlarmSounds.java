package com.timeato.app;

import android.content.Context;
import android.content.SharedPreferences;
import android.media.AudioAttributes;
import android.media.MediaPlayer;
import android.os.Handler;
import android.os.Looper;

/**
 * Bundled alarm tones + playback.
 *
 * The six tones are the AOSP material alarms (Apache 2.0, see
 * res/raw/alarm_sounds_notice.txt). Order must match engine.zig
 * alarmName/alarmKey: 0 helium (default), 1 argon, 2 carbon,
 * 3 krypton, 4 neon, 5 oxygen. Select actions are 10 + index.
 */
final class AlarmSounds {

    static final int COUNT = 6;
    static final int DEFAULT = 0;
    static final int ACTION_BASE = 10;

    private static final String PREFS = "timeato";
    private static final String KEY = "alarm_sound";

    /** Picker previews are a short snippet; the bundled tones run up to ~19s. */
    private static final int PREVIEW_MS = 2500;

    private static final Handler handler = new Handler(Looper.getMainLooper());
    private static Runnable stopTask = null;

    private static MediaPlayer player = null;

    static int resFor(int index) {
        switch (index) {
            case 1:
                return R.raw.alarm_argon;
            case 2:
                return R.raw.alarm_carbon;
            case 3:
                return R.raw.alarm_krypton;
            case 4:
                return R.raw.alarm_neon;
            case 5:
                return R.raw.alarm_oxygen;
            case 0:
            default:
                return R.raw.alarm_helium;
        }
    }

    static int clamp(int index) {
        if (index < 0) return 0;
        if (index >= COUNT) return COUNT - 1;
        return index;
    }

    static int load(Context ctx) {
        try {
            SharedPreferences prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
            return clamp(prefs.getInt(KEY, DEFAULT));
        } catch (Exception e) {
            return DEFAULT;
        }
    }

    static void save(Context ctx, int index) {
        try {
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    .edit()
                    .putInt(KEY, clamp(index))
                    .apply();
        } catch (Exception ignored) {
        }
    }

    /** Preview a tone while the user is picking it: a short one-shot snippet. */
    static synchronized void preview(Context ctx, int index) {
        start(ctx, index, AudioAttributes.USAGE_MEDIA);
        final MediaPlayer current = player;
        if (current == null) return;
        stopTask = () -> {
            synchronized (AlarmSounds.class) {
                if (player == current) stop();
                stopTask = null;
            }
        };
        handler.postDelayed(stopTask, PREVIEW_MS);
    }

    /** Ring the chosen tone when a session ends (alarm stream). */
    static synchronized void play(Context ctx, int index) {
        start(ctx, index, AudioAttributes.USAGE_ALARM);
    }

    private static void start(Context ctx, int index, int usage) {
        stop();
        try {
            android.content.res.AssetFileDescriptor afd =
                    ctx.getResources().openRawResourceFd(resFor(clamp(index)));
            if (afd == null) return;
            MediaPlayer mp = new MediaPlayer();
            mp.setAudioAttributes(new AudioAttributes.Builder()
                    .setUsage(usage)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build());
            mp.setDataSource(afd.getFileDescriptor(), afd.getStartOffset(), afd.getLength());
            afd.close();
            mp.setOnCompletionListener(released -> {
                released.release();
                synchronized (AlarmSounds.class) {
                    if (player == released) player = null;
                }
            });
            mp.prepare();
            mp.setVolume(1f, 1f);
            // Must come after prepare: the bundled tones carry ANDROID_LOOP,
            // which prepare would otherwise re-apply. One shot, then stop.
            mp.setLooping(false);
            player = mp;
            mp.start();
        } catch (Exception e) {
            stop();
        }
    }

    static synchronized void stop() {
        if (stopTask != null) {
            handler.removeCallbacks(stopTask);
            stopTask = null;
        }
        if (player != null) {
            try {
                player.stop();
            } catch (Exception ignored) {
            }
            try {
                player.release();
            } catch (Exception ignored) {
            }
            player = null;
        }
    }

    private AlarmSounds() {}
}
