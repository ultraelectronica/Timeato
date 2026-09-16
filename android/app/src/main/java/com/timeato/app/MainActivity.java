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
 * Android shell. Mirrors web/timeato.js: pump frame deltas into the Zig core
 * while the timer runs, forward taps, and paint whatever tree comes back.
 */
public class MainActivity extends Activity implements Renderer.ActionSink {

    private static final int BG = Color.parseColor("#12100E");

    private Renderer renderer;
    private LinearLayout host;
    private long lastNs = 0L;

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
        draw();
        Choreographer.getInstance().postFrameCallback(frame);
    }

    @Override
    public void onAction(int action) {
        NativeBridge.nativeDispatch(action);
        draw();
    }

    private void draw() {
        try {
            JSONObject view = new JSONObject(NativeBridge.nativeRender());
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
}
