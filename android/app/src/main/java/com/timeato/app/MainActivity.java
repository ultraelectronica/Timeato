package com.timeato.app;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Insets;
import android.os.Build;
import android.os.Bundle;
import android.view.Choreographer;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.widget.LinearLayout;
import android.widget.ScrollView;

import org.json.JSONObject;

/**
 * Android shell. Pumps frame deltas into the Zig core
 * while the timer runs, forwards taps, and paints whatever tree comes back.
 */
public class MainActivity extends Activity implements Renderer.ActionSink {

    private static final int BG = Color.parseColor("#12100E");

    // Mirrors view.Action.duration_done in src/view.zig: committing the tape
    // editor is the one action whose result the shell persists.
    private static final int ACTION_DURATION_DONE = 8;

    private Renderer renderer;
    private LinearLayout host;
    private long lastNs = 0L;
    private int lastAlarmSeq = -1;

    private final Choreographer.FrameCallback frame = new Choreographer.FrameCallback() {
        @Override
        public void doFrame(long ns) {
            if (lastNs != 0L) {
                long dt = Math.max(0L, (ns - lastNs) / 1_000_000L);
                if (NativeBridge.nativeRunning() == 1) {
                    NativeBridge.nativeTick((int) Math.min(dt, Integer.MAX_VALUE));
                    draw();
                }
            }
            lastNs = ns;
            Choreographer.getInstance().postFrameCallback(this);
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().setStatusBarColor(BG);
        getWindow().setNavigationBarColor(BG);

        ScrollView scroller = new ScrollView(this);
        scroller.setBackgroundColor(BG);
        scroller.setFillViewport(true);

        host = new LinearLayout(this);
        host.setOrientation(LinearLayout.VERTICAL);
        host.setBackgroundColor(BG);
        scroller.addView(host, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        setContentView(scroller);

        // Android 15 / targetSdk 35 draws edge-to-edge, so the brand row would
        // sit under the status bar. Push the content out of the system bars.
        scroller.setOnApplyWindowInsetsListener((v, insets) -> {
            if (Build.VERSION.SDK_INT >= 30) {
                Insets bars = insets.getInsets(WindowInsets.Type.systemBars());
                v.setPadding(0, bars.top, 0, bars.bottom);
            } else {
                v.setPadding(0, insets.getSystemWindowInsetTop(), 0, insets.getSystemWindowInsetBottom());
            }
            return insets;
        });

        renderer = new Renderer(this, this);
        NativeBridge.nativeInit();
        NativeBridge.nativeSetAlarm(AlarmSounds.load(this));
        for (int i = 0; i < DurationPrefs.PHASE_COUNT; i++) {
            if (DurationPrefs.has(this, i)) {
                NativeBridge.nativeSetPhaseDuration(i, DurationPrefs.load(this, i));
            }
        }
        draw();
        Choreographer.getInstance().postFrameCallback(frame);
    }

    @Override
    public void onAction(int action) {
        if (action >= AlarmSounds.ACTION_BASE
                && action < AlarmSounds.ACTION_BASE + AlarmSounds.COUNT) {
            // Tapping a tone selects it (preview included); the engine records
            // the index so the next render marks the row.
            int index = action - AlarmSounds.ACTION_BASE;
            AlarmSounds.save(this, index);
            NativeBridge.nativeDispatch(action);
            AlarmSounds.preview(this, index);
            draw();
            return;
        }
        NativeBridge.nativeDispatch(action);
        draw();
        if (action == ACTION_DURATION_DONE) {
            // The tape editor committed all three phases; mirror them to disk.
            for (int i = 0; i < DurationPrefs.PHASE_COUNT; i++) {
                DurationPrefs.save(this, i, NativeBridge.nativePhaseDuration(i));
            }
        }
    }

    private void draw() {
        try {
            JSONObject view = new JSONObject(NativeBridge.nativeRender());
            int seq = view.optInt("alarm", 0);
            if (lastAlarmSeq != -1 && seq != lastAlarmSeq) {
                // The Zig core completed a session; ring the selected tone.
                AlarmSounds.play(this, view.optInt("alarm_sound", AlarmSounds.DEFAULT));
            }
            lastAlarmSeq = seq;
            renderer.render(host, view.getJSONObject("tree"));
        } catch (Exception e) {
            // A malformed frame must never kill the render loop.
        }
    }

    @Override
    protected void onPause() {
        super.onPause();
        lastNs = 0L;
    }

    @Override
    protected void onDestroy() {
        AlarmSounds.stop();
        super.onDestroy();
    }
}
