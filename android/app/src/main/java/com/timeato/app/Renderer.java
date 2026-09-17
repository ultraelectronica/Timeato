package com.timeato.app;

import android.animation.Animator;
import android.animation.AnimatorListenerAdapter;
import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PorterDuff;
import android.graphics.PorterDuffColorFilter;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.util.TypedValue;
import android.view.GestureDetector;
import android.view.Gravity;
import android.view.HapticFeedbackConstants;
import android.view.MotionEvent;
import android.view.VelocityTracker;
import android.view.View;
import android.view.ViewGroup;
import android.view.animation.DecelerateInterpolator;
import android.widget.LinearLayout;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Applies the JSON view tree Zig produces.
 *
 * The shell makes no layout or state decisions: it maps element tags to widgets
 * and class tokens to styles, then reuses widgets across frames by index.
 */
final class Renderer {

    interface ActionSink {
        void onAction(int action);
    }

    private static final int BG = Color.parseColor("#12100E");
    private static final int SURFACE = Color.parseColor("#1C1916");
    private static final int SURFACE_ALT = Color.parseColor("#241F1B");
    private static final int TRACK = Color.parseColor("#2A2622");
    private static final int TEXT = Color.parseColor("#F5EFE7");
    private static final int MUTED = Color.parseColor("#A89D90");
    private static final int ON_ACCENT = Color.parseColor("#1A1512");

    private static final int WRAP = ViewGroup.LayoutParams.WRAP_CONTENT;
    private static final int MATCH = ViewGroup.LayoutParams.MATCH_PARENT;

    // Mirrors view.Action in src/view.zig. Only the codes the tape widget emits
    // need to be known here.
    private static final int MINUTE_BASE = 100;
    private static final int SECOND_BASE = 300;

    private final Context ctx;
    private final ActionSink sink;
    private final Typeface outfit;
    private final Typeface lucide;
    private int accent = Color.parseColor("#FF6B57");

    Renderer(Context ctx, ActionSink sink) {
        this.ctx = ctx;
        this.sink = sink;
        this.outfit = ctx.getResources().getFont(R.font.outfit);
        this.lucide = ctx.getResources().getFont(R.font.lucide);
    }

    static final class TaggedLinear extends LinearLayout {
        String vtag = "";
        String lastClass = null;
        int lastAccent = 0;
        int action = -1;

        TaggedLinear(Context c) {
            super(c);
        }
    }

    static final class TaggedText extends TextView {
        String vtag = "";
        String lastClass = null;
        int lastAccent = 0;
        int action = -1;
        GestureDetector gestures = null;

        TaggedText(Context c) {
            super(c);
        }
    }

    /** Circular liquid-fill container. Fills with accent on start, drains as time runs; clock sits inside. */
    static final class RingLayout extends LinearLayout {
        String vtag = "div";
        String lastBase = null;
        int lastAccent = 0;
        float shown = -1f;
        int animTarget = -1;
        int accent = 0;
        ValueAnimator progAnim = null;
        float wavePhase = 0f;
        boolean waving = false;
        float lastRadius = 0f;
        float lastCx = 0f;
        float lastCy = 0f;
        float lastSurfaceY = Float.MAX_VALUE;
        final Paint bgFill = new Paint(Paint.ANTI_ALIAS_FLAG);
        final Paint liquidFill = new Paint(Paint.ANTI_ALIAS_FLAG);
        final Paint edgeStroke = new Paint(Paint.ANTI_ALIAS_FLAG);
        final Paint surfacePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final Paint recolorPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final Path clipPath = new Path();
        final Path wavePath = new Path();
        final Runnable waveTick = new Runnable() {
            @Override
            public void run() {
                if (shown > 0.5f) {
                    wavePhase += 0.14f;
                    invalidate();
                    postOnAnimationDelayed(this, 32);
                } else {
                    waving = false;
                }
            }
        };

        RingLayout(Context c) {
            super(c);
            setOrientation(VERTICAL);
            setGravity(Gravity.CENTER);
            setWillNotDraw(false);
            bgFill.setStyle(Paint.Style.FILL);
            liquidFill.setStyle(Paint.Style.FILL);
            edgeStroke.setStyle(Paint.Style.STROKE);
            edgeStroke.setStrokeCap(Paint.Cap.ROUND);
            surfacePaint.setStyle(Paint.Style.STROKE);
            surfacePaint.setStrokeCap(Paint.Cap.ROUND);
            recolorPaint.setColorFilter(new PorterDuffColorFilter(ON_ACCENT, PorterDuff.Mode.SRC_IN));
        }

        private int dp(float v) {
            return Math.round(TypedValue.applyDimension(
                    TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics()));
        }

        private void kickWave() {
            if (!waving && shown > 0.5f) {
                waving = true;
                postOnAnimationDelayed(waveTick, 32);
            }
        }

        void applyRing(String cls, int accent, int target) {
            String base = baseKey(cls);
            if (!base.equals(lastBase) || accent != lastAccent) {
                lastBase = base;
                lastAccent = accent;
                int s = dp(320);
                LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(s, s);
                p.gravity = Gravity.CENTER_HORIZONTAL;
                p.topMargin = dp(4);
                p.bottomMargin = dp(4);
                setLayoutParams(p);
                setPadding(0, 0, 0, 0);
                setBackground(null);
            }
            this.accent = accent;
            bgFill.setColor(TRACK);
            liquidFill.setColor(accent);
            edgeStroke.setColor(accent);
            edgeStroke.setAlpha(90);
            edgeStroke.setStrokeWidth(dp(3));
            surfacePaint.setColor(Color.WHITE);
            surfacePaint.setAlpha(70);
            surfacePaint.setStrokeWidth(dp(2));

            if (shown < 0f) {
                shown = target;
                animTarget = target;
                invalidate();
                kickWave();
                return;
            }
            if (Math.abs(target - shown) < 0.5f) {
                animTarget = target;
                return;
            }
            // Don't starve an in-flight fill/drain on near-identical frames.
            if (progAnim != null && progAnim.isRunning() && Math.abs(target - animTarget) < 3) return;
            if (Math.abs(target - shown) > 4f) {
                if (progAnim != null) progAnim.cancel();
                float from = shown;
                animTarget = target;
                progAnim = ValueAnimator.ofFloat(from, (float) target);
                // Big jumps (e.g. 0 -> 100 on play) pour like liquid; small ticks drain fast.
                float delta = Math.abs(target - from);
                long dur = (long) (280 + delta * 9);
                if (dur > 1250) dur = 1250;
                progAnim.setDuration(dur);
                progAnim.setInterpolator(new DecelerateInterpolator());
                progAnim.addUpdateListener(a -> {
                    shown = (float) a.getAnimatedValue();
                    invalidate();
                });
                progAnim.start();
                kickWave();
            } else {
                if (progAnim != null && progAnim.isRunning()) return;
                shown = target;
                animTarget = target;
                invalidate();
                kickWave();
            }
        }

        @Override
        protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            int w = getWidth();
            int h = getHeight();
            if (w <= 0 || h <= 0) return;
            float inset = dp(3);
            float radius = Math.min(w, h) / 2f - inset;
            float cx = w / 2f;
            float cy = h / 2f;
            lastRadius = radius;
            lastCx = cx;
            lastCy = cy;
            canvas.drawCircle(cx, cy, radius, bgFill);
            if (shown > 0.5f) {
                float frac = Math.max(0f, Math.min(1f, shown / 100f));
                float fillH = frac * (radius * 2f);
                float top = cy + radius - fillH;
                float amp = dp(7) * Math.min(1f, Math.min(frac, 1f - frac) * 4f + 0.3f);
                lastSurfaceY = top;
                clipPath.reset();
                clipPath.addCircle(cx, cy, radius, Path.Direction.CW);
                int save = canvas.save();
                canvas.clipPath(clipPath);
                // The wave itself is the top edge of the colored body, so the
                // whole liquid surface moves - not just a stroked line above it.
                wavePath.reset();
                int steps = 28;
                for (int i = 0; i <= steps; i++) {
                    float x = cx - radius + (2f * radius * i / steps);
                    float y = top + (float) Math.sin(wavePhase + (i / (float) steps) * Math.PI * 2f) * amp;
                    if (i == 0) wavePath.moveTo(x, y);
                    else wavePath.lineTo(x, y);
                }
                wavePath.lineTo(cx + radius, cy + radius);
                wavePath.lineTo(cx - radius, cy + radius);
                wavePath.close();
                canvas.drawPath(wavePath, liquidFill);
                // Soft highlight on the moving surface.
                wavePath.reset();
                for (int i = 0; i <= steps; i++) {
                    float x = cx - radius + (2f * radius * i / steps);
                    float y = top + (float) Math.sin(wavePhase + (i / (float) steps) * Math.PI * 2f) * amp;
                    if (i == 0) wavePath.moveTo(x, y);
                    else wavePath.lineTo(x, y);
                }
                canvas.drawPath(wavePath, surfacePaint);
                canvas.restoreToCount(save);
                canvas.drawCircle(cx, cy, radius - edgeStroke.getStrokeWidth() / 2f, edgeStroke);
            } else {
                lastSurfaceY = cy + radius + dp(4);
                canvas.drawCircle(cx, cy, radius - edgeStroke.getStrokeWidth() / 2f, edgeStroke);
            }
        }

        /**
         * Children (the clock) draw light on top of everything. Inside the
         * liquid region we redraw them through a recoloring layer, so the text
         * flips color exactly at the liquid surface with pixel-perfect
         * alignment (same views, same layout).
         */
        @Override
        protected void dispatchDraw(Canvas canvas) {
            super.dispatchDraw(canvas);
            if (shown <= 0.5f) return;
            int save = canvas.save();
            clipPath.reset();
            clipPath.addCircle(lastCx, lastCy, lastRadius, Path.Direction.CW);
            canvas.clipPath(clipPath);
            canvas.clipRect(lastCx - lastRadius, lastSurfaceY, lastCx + lastRadius, lastCy + lastRadius);
            int n = getChildCount();
            for (int i = 0; i < n; i++) {
                View c = getChildAt(i);
                int layer = canvas.saveLayer(null, recolorPaint);
                canvas.translate(c.getLeft(), c.getTop());
                c.draw(canvas);
                canvas.restoreToCount(layer);
            }
            canvas.restoreToCount(save);
        }
    }

    /** Phase word with a letter-by-letter slot animation on change. */
    static final class SlotLabelView extends LinearLayout {
        String vtag = "div";
        String current = null;
        String pendingText = null;
        int accent = 0;
        final Typeface tf;
        Runnable pending = null;
        int seq = 0;

        SlotLabelView(Context c, Typeface tf) {
            super(c);
            this.tf = tf;
            setOrientation(HORIZONTAL);
            setGravity(Gravity.CENTER);
            LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(MATCH, WRAP);
            setLayoutParams(p);
            setPadding(0, 0, 0, dpSelf(10));
        }

        private int dpSelf(float v) {
            return Math.round(TypedValue.applyDimension(
                    TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics()));
        }

        void setLabel(String text, int accent) {
            // Same target already queued: let the posted swap run instead of
            // cancelling it every frame and starving the animation.
            if (text.equals(pendingText) && pending != null) return;
            if (text.equals(current) && pending == null) {
                if (accent != this.accent) {
                    this.accent = accent;
                    for (int i = 0; i < getChildCount(); i++) {
                        View ch = getChildAt(i);
                        if (ch instanceof TextView) ((TextView) ch).setTextColor(accent);
                    }
                }
                return;
            }
            if (current == null) {
                build(text, accent);
                current = text;
                pendingText = null;
                this.accent = accent;
                return;
            }
            if (!text.equals(current)) {
                seq++;
                final int my = seq;
                if (pending != null) removeCallbacks(pending);
                int n = getChildCount();
                for (int i = 0; i < n; i++) {
                    View ch = getChildAt(i);
                    ch.animate().cancel();
                    ch.animate().translationY(-dpSelf(16)).alpha(0f)
                            .setStartDelay(i * 28L).setDuration(150L).start();
                }
                int totalDelay = n * 28 + 165;
                pendingText = text;
                pending = () -> {
                    if (my != seq) return;
                    build(text, accent);
                    int m = getChildCount();
                    for (int j = 0; j < m; j++) {
                        View ch = getChildAt(j);
                        ch.setTranslationY(dpSelf(16));
                        ch.setAlpha(0f);
                        ch.animate().translationY(0f).alpha(1f)
                                .setStartDelay(j * 28L).setDuration(185L)
                                .setInterpolator(new DecelerateInterpolator()).start();
                    }
                    current = text;
                    pendingText = null;
                    pending = null;
                    this.accent = accent;
                };
                postDelayed(pending, totalDelay);
            } else {
                this.accent = accent;
                for (int i = 0; i < getChildCount(); i++) {
                    View ch = getChildAt(i);
                    if (ch instanceof TextView) ((TextView) ch).setTextColor(accent);
                }
            }
        }

        private void build(String text, int accent) {
            for (int i = 0; i < getChildCount(); i++) getChildAt(i).animate().cancel();
            removeAllViews();
            for (int i = 0; i < text.length(); i++) {
                char c = text.charAt(i);
                TextView tv = new TextView(getContext());
                tv.setTypeface(tf);
                try {
                    tv.setFontVariationSettings("'wght' 700");
                } catch (Exception ignored) {
                }
                tv.setTextSize(17);
                tv.setTextColor(accent);
                tv.setLetterSpacing(0.06f);
                tv.setGravity(Gravity.CENTER);
                tv.setIncludeFontPadding(false);
                if (c == ' ') {
                    tv.setText(" ");
                } else {
                    tv.setText(String.valueOf(c));
                }
                addView(tv, new LinearLayout.LayoutParams(WRAP, WRAP));
            }
        }
    }

    /**
     * A ruler strip. The selected value sits under a fixed center needle; drag
     * or fling the tape and it snaps to whole detents, emitting one action per
     * detent so the core can restage the value. No Material pickers involved.
     */
    static final class TapeView extends View {
        String vtag = "div";
        final Renderer owner;
        final ActionSink sink;
        final Typeface tf;

        boolean minutes = true;
        int max = 180;
        int value = 0;
        float position = 0f;
        int accent = 0xFF6B57;
        int actionBase = 100;
        float spacing = 0f;
        boolean configured = false;
        boolean interacting = false;
        boolean animating = false;
        ValueAnimator anim = null;

        float downX = 0f;
        float downY = 0f;
        float downPos = 0f;
        VelocityTracker vt = null;
        final int slop;

        final Paint tickPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final Paint labelPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final Paint labelNearPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final Paint needlePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final Paint bandPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        final Paint fadePaint = new Paint(Paint.ANTI_ALIAS_FLAG);

        TapeView(Context c, Renderer owner, ActionSink sink, Typeface tf) {
            super(c);
            this.owner = owner;
            this.sink = sink;
            this.tf = tf;
            setWillNotDraw(false);
            slop = owner.dp(10);
            tickPaint.setStyle(Paint.Style.STROKE);
            tickPaint.setStrokeCap(Paint.Cap.ROUND);
            labelPaint.setTextAlign(Paint.Align.CENTER);
            labelPaint.setTypeface(tf);
            labelPaint.setTextSize(owner.dp(13));
            labelPaint.setColor(MUTED);
            try {
                labelPaint.setFontVariationSettings("'wght' 600");
            } catch (Exception ignored) {
            }
            labelNearPaint.set(labelPaint);
            labelNearPaint.setColor(TEXT);
            needlePaint.setStyle(Paint.Style.STROKE);
            needlePaint.setStrokeCap(Paint.Cap.ROUND);
            bandPaint.setStyle(Paint.Style.FILL);
            fadePaint.setStyle(Paint.Style.FILL);
        }

        int dp(float v) {
            return owner.dp(v);
        }

        static int parseValue(String cls) {
            if (cls == null) return 0;
            for (String tok : cls.split(" ")) {
                if (tok.length() < 2 || tok.charAt(0) != 'v') continue;
                boolean digits = true;
                for (int i = 1; i < tok.length(); i++) {
                    if (!Character.isDigit(tok.charAt(i))) {
                        digits = false;
                        break;
                    }
                }
                if (!digits) continue;
                try {
                    return Integer.parseInt(tok.substring(1));
                } catch (NumberFormatException e) {
                    return 0;
                }
            }
            return 0;
        }

        void applyTape(String cls, int accent) {
            this.accent = accent;
            boolean nowMinutes = hasToken(cls, "tape-minutes");
            this.minutes = nowMinutes;
            this.max = nowMinutes ? 180 : 59;
            this.actionBase = nowMinutes ? MINUTE_BASE : SECOND_BASE;
            float sp = dp(nowMinutes ? 15f : 28f);
            if (!configured || sp != spacing) {
                spacing = sp;
                LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(MATCH, dp(92));
                p.bottomMargin = dp(2);
                setLayoutParams(p);
                configured = true;
            }
            needlePaint.setColor(accent);
            needlePaint.setStrokeWidth(dp(2.5f));
            int target = Math.max(0, Math.min(max, parseValue(cls)));
            if (!interacting && !animating && (value != target || position != target)) {
                value = target;
                position = target;
                invalidate();
            } else if (!interacting && !animating) {
                invalidate();
            }
        }

        float clampPosition(float p) {
            if (p < 0f) return 0f;
            if (p > max) return max;
            return p;
        }

        void setPosition(float p) {
            position = clampPosition(p);
            int nearest = Math.round(position);
            if (nearest != value) {
                value = nearest;
                performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK);
                sink.onAction(actionBase + value);
            }
            invalidate();
        }

        void animateTo(int target) {
            final int goal = Math.max(0, Math.min(max, target));
            if (anim != null) anim.cancel();
            float from = position;
            if (Math.abs(goal - from) < 0.01f) {
                setPosition(goal);
                return;
            }
            animating = true;
            anim = ValueAnimator.ofFloat(from, goal);
            float dist = Math.abs(goal - from);
            long dur = (long) Math.max(110, Math.min(420, 110 + dist * 22));
            anim.setDuration(dur);
            anim.setInterpolator(new DecelerateInterpolator());
            anim.addUpdateListener(a -> setPosition((float) a.getAnimatedValue()));
            anim.addListener(new AnimatorListenerAdapter() {
                @Override
                public void onAnimationEnd(Animator a) {
                    animating = false;
                    anim = null;
                    setPosition(goal);
                }
            });
            anim.start();
        }

        @Override
        public boolean onTouchEvent(MotionEvent ev) {
            switch (ev.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    downX = ev.getX();
                    downY = ev.getY();
                    downPos = position;
                    interacting = true;
                    if (anim != null) anim.cancel();
                    animating = false;
                    vt = VelocityTracker.obtain();
                    vt.addMovement(ev);
                    getParent().requestDisallowInterceptTouchEvent(true);
                    return true;
                case MotionEvent.ACTION_MOVE: {
                    if (vt != null) vt.addMovement(ev);
                    float dx = ev.getX() - downX;
                    float dy = ev.getY() - downY;
                    if (Math.abs(dy) > Math.abs(dx) && Math.abs(dy) > slop) {
                        getParent().requestDisallowInterceptTouchEvent(false);
                        interacting = false;
                        return true;
                    }
                    getParent().requestDisallowInterceptTouchEvent(true);
                    interacting = true;
                    setPosition(downPos - dx / spacing);
                    return true;
                }
                case MotionEvent.ACTION_UP: {
                    float vx = 0f;
                    if (vt != null) {
                        vt.addMovement(ev);
                        vt.computeCurrentVelocity(1000);
                        vx = vt.getXVelocity();
                    }
                    releaseVelocity();
                    interacting = false;
                    float dv = -(vx / spacing) * 0.22f;
                    int target = Math.round(position + (Math.abs(dv) > 0.6f ? dv : 0f));
                    animateTo(target);
                    return true;
                }
                case MotionEvent.ACTION_CANCEL:
                    releaseVelocity();
                    interacting = false;
                    animateTo(Math.round(position));
                    return true;
                default:
                    return true;
            }
        }

        private void releaseVelocity() {
            if (vt != null) {
                vt.recycle();
                vt = null;
            }
        }

        @Override
        protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            int w = getWidth();
            int h = getHeight();
            if (w <= 0 || h <= 0 || spacing <= 0f) return;
            float cx = w / 2f;
            float baseY = h - dp(9);

            bandPaint.setColor(accent);
            bandPaint.setAlpha(26);
            canvas.drawRect(cx - spacing * 0.5f, dp(8), cx + spacing * 0.5f, h - dp(8), bandPaint);

            int lo = (int) Math.floor(position - (cx + spacing) / spacing);
            int hi = (int) Math.ceil(position + (cx + spacing) / spacing);
            if (lo < 0) lo = 0;
            if (hi > max) hi = max;

            for (int u = lo; u <= hi; u++) {
                float x = cx + (u - position) * spacing;
                boolean major = u % 5 == 0;
                boolean hour = minutes && u % 60 == 0 && u > 0;
                float len = major ? (hour ? dp(30) : dp(22)) : dp(13);
                tickPaint.setColor(MUTED);
                tickPaint.setAlpha(major ? 210 : 110);
                tickPaint.setStrokeWidth(major ? dp(1.6f) : dp(1f));
                canvas.drawLine(x, baseY, x, baseY - len, tickPaint);
                if (major) {
                    String label = hour ? (u / 60) + "h" : String.valueOf(u);
                    Paint p = Math.abs(x - cx) < spacing * 0.75f ? labelNearPaint : labelPaint;
                    canvas.drawText(label, x, baseY - len - dp(6), p);
                }
            }

            canvas.drawLine(cx, dp(6), cx, h - dp(6), needlePaint);

            LinearGradient lg = new LinearGradient(0, 0, dp(26), 0, BG, owner.alpha(BG, 0f), Shader.TileMode.CLAMP);
            fadePaint.setShader(lg);
            canvas.drawRect(0, 0, dp(26), h, fadePaint);
            LinearGradient rg = new LinearGradient(w - dp(26), 0, w, 0, owner.alpha(BG, 0f), BG, Shader.TileMode.CLAMP);
            fadePaint.setShader(rg);
            canvas.drawRect(w - dp(26), 0, w, h, fadePaint);
        }
    }

    void render(ViewGroup host, JSONObject root) {
        accent = accentFor(root.optString("c", ""));
        View cur = host.getChildCount() > 0 ? host.getChildAt(0) : null;
        View next = morph(cur, root, "", accent);
        if (next != cur) {
            host.removeAllViews();
            host.addView(next, new LinearLayout.LayoutParams(MATCH, WRAP));
        }
    }

    private int accentFor(String cls) {
        if (cls.contains("phase-short_break")) return Color.parseColor("#46C9A4");
        if (cls.contains("phase-long_break")) return Color.parseColor("#7C9CFF");
        return Color.parseColor("#FF6B57");
    }

    private static boolean hasToken(String cls, String tok) {
        if (cls == null || cls.isEmpty()) return false;
        for (String t : cls.split(" ")) {
            if (t.equals(tok)) return true;
        }
        return false;
    }

    private static int parseRemaining(String cls) {
        if (cls == null) return 100;
        for (String t : cls.split(" ")) {
            if (t.length() > 1 && t.charAt(0) == 'p') {
                boolean digits = true;
                for (int i = 1; i < t.length(); i++) {
                    if (!Character.isDigit(t.charAt(i))) {
                        digits = false;
                        break;
                    }
                }
                if (digits) {
                    try {
                        int v = Integer.parseInt(t.substring(1));
                        if (v < 0) return 0;
                        if (v > 100) return 100;
                        return v;
                    } catch (NumberFormatException e) {
                        return 100;
                    }
                }
            }
        }
        return 100;
    }

    private static String baseKey(String cls) {
        if (cls == null) return "";
        StringBuilder sb = new StringBuilder();
        for (String t : cls.split(" ")) {
            boolean isProg = false;
            if (t.length() > 1 && t.charAt(0) == 'p') {
                isProg = true;
                for (int i = 1; i < t.length(); i++) {
                    if (!Character.isDigit(t.charAt(i))) {
                        isProg = false;
                        break;
                    }
                }
            }
            if (isProg) continue;
            if (sb.length() > 0) sb.append(' ');
            sb.append(t);
        }
        return sb.toString();
    }

    private View morph(View cur, JSONObject node, String parentClass, int accent) {
        String tag = node.optString("t");

        if ("#text".equals(tag)) {
            TaggedText t = (cur instanceof TaggedText) ? (TaggedText) cur : new TaggedText(ctx);
            t.vtag = "#text";
            styleBareText(t, parentClass, accent);
            setTextIfChanged(t, node.optString("x", ""));
            return t;
        }

        String cls = node.optString("c", "");

        if (hasToken(cls, "phase-label")) {
            SlotLabelView v = (cur instanceof SlotLabelView) ? (SlotLabelView) cur : new SlotLabelView(ctx, outfit);
            v.vtag = tag;
            v.setLabel(textOf(node), accent);
            return v;
        }

        if (hasToken(cls, "ring")) {
            RingLayout r = (cur instanceof RingLayout) ? (RingLayout) cur : new RingLayout(ctx);
            r.vtag = tag;
            r.applyRing(cls, accent, parseRemaining(cls));
            JSONArray kids = node.optJSONArray("ch");
            if (kids != null) {
                sync(r, kids, cls, accent);
            } else if (r.getChildCount() > 0) {
                r.removeAllViews();
            }
            return r;
        }

        if (hasToken(cls, "tape")) {
            TapeView tv = (cur instanceof TapeView) ? (TapeView) cur : new TapeView(ctx, this, sink, outfit);
            tv.vtag = tag;
            tv.applyTape(cls, accent);
            return tv;
        }

        if (isContainer(node)) {
            TaggedLinear l = (cur instanceof TaggedLinear) ? (TaggedLinear) cur : new TaggedLinear(ctx);
            l.vtag = tag;
            styleContainer(l, cls, accent);
            bindAction(l, node.optInt("a", -1));
            JSONArray kids = node.optJSONArray("ch");
            if (kids != null) {
                sync(l, kids, cls, accent);
            } else if (l.getChildCount() > 0) {
                l.removeAllViews();
            }
            return l;
        }

        TaggedText t = (cur instanceof TaggedText) ? (TaggedText) cur : new TaggedText(ctx);
        t.vtag = tag;
        styleText(t, cls, accent);
        setTextIfChanged(t, textOf(node));
        int a = node.optInt("a", -1);
        if (hasToken(cls, "clock-edit")) bindDoubleTap(t, a);
        else bindAction(t, a);
        return t;
    }

    /** A node is a container when at least one child is an element, not text. */
    private boolean isContainer(JSONObject node) {
        JSONArray ch = node.optJSONArray("ch");
        if (ch == null) return false;
        for (int i = 0; i < ch.length(); i++) {
            JSONObject c = ch.optJSONObject(i);
            if (c != null && !"#text".equals(c.optString("t"))) return true;
        }
        return false;
    }

    private String textOf(JSONObject node) {
        JSONArray ch = node.optJSONArray("ch");
        if (ch == null) return "";
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < ch.length(); i++) {
            JSONObject c = ch.optJSONObject(i);
            if (c != null && "#text".equals(c.optString("t"))) sb.append(c.optString("x", ""));
        }
        return sb.toString();
    }

    private void sync(ViewGroup host, JSONArray kids, String parentClass, int accent) {
        int n = kids.length();
        for (int i = 0; i < n; i++) {
            JSONObject node = kids.optJSONObject(i);
            if (node == null) continue;
            View cur = host.getChildAt(i);
            View next = morph(cur, node, parentClass, accent);
            if (next != cur) {
                if (cur != null) host.removeViewAt(i);
                host.addView(next, i);
            }
        }
        while (host.getChildCount() > n) {
            host.removeViewAt(host.getChildCount() - 1);
        }
    }

    // --- styles ---------------------------------------------------------

    private void styleContainer(TaggedLinear l, String cls, int accent) {
        if (cls.equals(l.lastClass) && accent == l.lastAccent) return;
        l.lastClass = cls;
        l.lastAccent = accent;

        l.setOrientation(LinearLayout.VERTICAL);
        l.setGravity(Gravity.NO_GRAVITY);
        l.setPadding(0, 0, 0, 0);
        l.setBackground(null);
        lp(l, MATCH, WRAP, 0f, 0, 0, 0, 0);

        for (String tok : cls.split(" ")) {
            switch (tok) {
                case "app":
                    l.setBackgroundColor(BG);
                    l.setPadding(dp(22), dp(20), dp(22), dp(22));
                    break;
                case "topbar":
                    l.setOrientation(LinearLayout.HORIZONTAL);
                    l.setGravity(Gravity.CENTER_VERTICAL);
                    l.setPadding(0, 0, 0, dp(6));
                    break;
                case "stage":
                case "timer":
                    l.setGravity(Gravity.CENTER_HORIZONTAL);
                    l.setPadding(0, dp(24), 0, dp(10));
                    break;
                case "hero":
                    l.setOrientation(LinearLayout.VERTICAL);
                    l.setGravity(Gravity.CENTER_HORIZONTAL);
                    l.setPadding(dp(12), 0, dp(12), dp(14));
                    break;
                case "ring-wrap":
                    l.setGravity(Gravity.CENTER_HORIZONTAL);
                    l.setPadding(0, dp(10), 0, dp(6));
                    lp(l, MATCH, WRAP, 0f, 0, 0, 0, 0);
                    break;
                case "ring-center":
                    l.setGravity(Gravity.CENTER);
                    lpFill(l);
                    break;
                case "progress":
                    l.setOrientation(LinearLayout.HORIZONTAL);
                    l.setPadding(0, dp(24), 0, 0);
                    break;
                case "controls":
                    l.setOrientation(LinearLayout.HORIZONTAL);
                    l.setGravity(Gravity.CENTER);
                    l.setPadding(0, dp(14), 0, dp(22));
                    break;
                case "settings":
                    l.setGravity(Gravity.CENTER_HORIZONTAL);
                    l.setPadding(0, dp(8), 0, 0);
                    break;
                case "settings-head":
                    l.setOrientation(LinearLayout.VERTICAL);
                    l.setGravity(Gravity.CENTER_HORIZONTAL);
                    l.setPadding(0, 0, 0, 0);
                    lp(l, 0, WRAP, 1f, 0, 0, 0, 0);
                    break;
                case "sound-list":
                    l.setGravity(Gravity.NO_GRAVITY);
                    break;
                case "sound-row":
                    l.setOrientation(LinearLayout.HORIZONTAL);
                    l.setGravity(Gravity.CENTER_VERTICAL);
                    l.setBackground(ripple());
                    l.setPadding(dp(6), dp(17), dp(6), dp(17));
                    lp(l, MATCH, WRAP, 0f, 0, 0, 0, 0);
                    break;
                case "history":
                    l.setGravity(Gravity.CENTER_HORIZONTAL);
                    l.setPadding(0, dp(2), 0, 0);
                    break;
                case "history-head":
                    l.setOrientation(LinearLayout.HORIZONTAL);
                    l.setGravity(Gravity.CENTER);
                    l.setPadding(0, 0, 0, dp(12));
                    break;
                case "history-list":
                    l.setGravity(Gravity.CENTER_HORIZONTAL);
                    break;
                case "hist-item":
                    l.setOrientation(LinearLayout.HORIZONTAL);
                    l.setGravity(Gravity.CENTER_VERTICAL);
                    l.setBackground(round(SURFACE, 12));
                    l.setPadding(dp(14), dp(13), dp(14), dp(13));
                    LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(MATCH, WRAP);
                    p.bottomMargin = dp(8);
                    l.setLayoutParams(p);
                    break;
                case "duration":
                    l.setGravity(Gravity.CENTER_HORIZONTAL);
                    l.setPadding(0, dp(10), 0, 0);
                    break;
                case "phase-tabs":
                    l.setOrientation(LinearLayout.HORIZONTAL);
                    l.setGravity(Gravity.CENTER);
                    l.setPadding(0, dp(6), 0, dp(14));
                    lp(l, MATCH, WRAP, 0f, 0, 0, 0, 0);
                    break;
                case "tape-wrap":
                    l.setGravity(Gravity.CENTER_HORIZONTAL);
                    l.setPadding(0, dp(4), 0, 0);
                    break;
                case "tape-field":
                    l.setGravity(Gravity.CENTER_HORIZONTAL);
                    l.setBackground(strokeRound(SURFACE, alpha(TEXT, 0.06f), 20, 1));
                    l.setPadding(dp(10), dp(14), dp(10), dp(6));
                    LinearLayout.LayoutParams fp = new LinearLayout.LayoutParams(MATCH, WRAP);
                    fp.bottomMargin = dp(12);
                    l.setLayoutParams(fp);
                    break;
                default:
                    break;
            }
        }
    }

    private void styleText(TaggedText t, String cls, int accent) {
        if (!cls.equals(t.lastClass) || accent != t.lastAccent) {
            t.lastClass = cls;
            t.lastAccent = accent;
            resetText(t);
            if (isIconGlyph(String.valueOf(t.getText()))) t.setTypeface(lucide);
            for (String tok : cls.split(" ")) {
                applyTextToken(t, tok, accent);
            }
        }
    }

    private void resetText(TaggedText t) {
        t.setVisibility(View.VISIBLE);
        t.setTextSize(14);
        t.setTextColor(MUTED);
        t.setTypeface(outfit);
        try {
            t.setFontVariationSettings("'wght' 400");
        } catch (Exception ignored) {
        }
        try {
            t.setFontFeatureSettings("tnum");
        } catch (Exception ignored) {
        }
        t.setLetterSpacing(0f);
        t.setAllCaps(false);
        t.setGravity(Gravity.START);
        t.setIncludeFontPadding(true);
        t.setPadding(0, 0, 0, 0);
        t.setBackground(null);
        lp(t, WRAP, WRAP, 0f, 0, 0, 0, 0);
    }

    private void applyTextToken(TaggedText t, String tok, int accent) {
        switch (tok) {
            case "brand":
                t.setTextSize(22);
                t.setTextColor(TEXT);
                try {
                    t.setFontVariationSettings("'wght' 700");
                } catch (Exception ignored) {
                }
                t.setLetterSpacing(0.02f);
                t.setGravity(Gravity.CENTER);
                t.setTextAlignment(View.TEXT_ALIGNMENT_CENTER);
                lp(t, 0, WRAP, 1f, 0, 0, 0, 0);
                break;
            case "hero-title":
                t.setTextSize(24);
                t.setTextColor(TEXT);
                try {
                    t.setFontVariationSettings("'wght' 700");
                } catch (Exception ignored) {
                }
                t.setLetterSpacing(-0.01f);
                t.setGravity(Gravity.CENTER);
                t.setTextAlignment(View.TEXT_ALIGNMENT_CENTER);
                t.setIncludeFontPadding(false);
                lp(t, MATCH, WRAP, 0f, 0, dp(8), 0, 0);
                break;
            case "hero-sub":
                t.setTextSize(13);
                t.setTextColor(MUTED);
                t.setGravity(Gravity.CENTER);
                t.setTextAlignment(View.TEXT_ALIGNMENT_CENTER);
                t.setLineSpacing(dp(3), 1f);
                lp(t, MATCH, WRAP, 0f, 0, 0, 0, 0);
                break;
            case "topbar-grow":
                t.setText("");
                t.setBackground(null);
                t.setPadding(0, 0, 0, 0);
                lp(t, 0, dp(1), 1f, 0, 0, 0, 0);
                break;
            case "gear":
                t.setTextSize(27);
                t.setTextColor(MUTED);
                t.setGravity(Gravity.CENTER);
                t.setTextAlignment(View.TEXT_ALIGNMENT_CENTER);
                t.setBackground(null);
                t.setPadding(0, 0, 0, 0);
                t.setMinWidth(dp(48));
                t.setMinHeight(dp(48));
                lpFixed(t, dp(48), dp(48), 0);
                break;
            case "pill":
                t.setTextSize(11);
                t.setTextColor(accent);
                try {
                    t.setFontVariationSettings("'wght' 700");
                } catch (Exception ignored) {
                }
                t.setLetterSpacing(0.18f);
                t.setAllCaps(true);
                t.setBackground(strokeRound(alpha(accent, 0.16f), alpha(accent, 0.55f), 999, 1));
                t.setPadding(dp(10), dp(5), dp(10), dp(5));
                break;
            case "phase-label":
                t.setTextSize(17);
                t.setTextColor(accent);
                try {
                    t.setFontVariationSettings("'wght' 700");
                } catch (Exception ignored) {
                }
                t.setLetterSpacing(0.06f);
                t.setGravity(Gravity.CENTER);
                t.setTextAlignment(View.TEXT_ALIGNMENT_CENTER);
                lp(t, MATCH, WRAP, 0f, 0, 0, 0, 0);
                break;
            case "display":
                t.setTextSize(68);
                t.setTextColor(TEXT);
                t.setTypeface(outfit);
                try {
                    t.setFontVariationSettings("'wght' 300");
                } catch (Exception ignored) {
                }
                try {
                    t.setFontFeatureSettings("tnum");
                } catch (Exception ignored) {
                }
                t.setLetterSpacing(-0.02f);
                t.setGravity(Gravity.CENTER);
                t.setTextAlignment(View.TEXT_ALIGNMENT_CENTER);
                t.setIncludeFontPadding(false);
                break;
            case "caption":
                t.setTextSize(11);
                t.setTextColor(TEXT);
                t.setLetterSpacing(0.22f);
                t.setAllCaps(true);
                t.setGravity(Gravity.CENTER);
                t.setTextAlignment(View.TEXT_ALIGNMENT_CENTER);
                t.setPadding(0, dp(4), 0, 0);
                break;
            case "sound-name":
                t.setTextSize(16);
                t.setTextColor(TEXT);
                try {
                    t.setFontVariationSettings("'wght' 400");
                } catch (Exception ignored) {
                }
                t.setGravity(Gravity.START | Gravity.CENTER_VERTICAL);
                t.setBackground(null);
                lp(t, 0, WRAP, 1f, 0, 0, 0, 0);
                break;
            case "sound-check":
                t.setTextSize(20);
                t.setTextColor(accent);
                try {
                    t.setFontVariationSettings("'wght' 700");
                } catch (Exception ignored) {
                }
                t.setGravity(Gravity.END | Gravity.CENTER_VERTICAL);
                t.setBackground(null);
                lp(t, WRAP, WRAP, 0f, 0, 0, 0, 0);
                break;
            case "selected":
                t.setTextColor(accent);
                try {
                    t.setFontVariationSettings("'wght' 700");
                } catch (Exception ignored) {
                }
                t.setBackground(null);
                break;
            case "settings-title":
                t.setTextSize(22);
                t.setTextColor(TEXT);
                try {
                    t.setFontVariationSettings("'wght' 700");
                } catch (Exception ignored) {
                }
                t.setGravity(Gravity.CENTER);
                t.setTextAlignment(View.TEXT_ALIGNMENT_CENTER);
                t.setPadding(0, 0, 0, 0);
                lp(t, MATCH, WRAP, 0f, 0, 0, 0, 0);
                break;
            case "settings-sub":
                t.setTextSize(13);
                t.setTextColor(MUTED);
                t.setGravity(Gravity.CENTER);
                t.setTextAlignment(View.TEXT_ALIGNMENT_CENTER);
                t.setPadding(0, dp(2), 0, 0);
                lp(t, MATCH, WRAP, 0f, 0, 0, 0, 0);
                break;
            case "settings-note":
                t.setTextSize(12);
                t.setTextColor(MUTED);
                t.setGravity(Gravity.CENTER);
                t.setTextAlignment(View.TEXT_ALIGNMENT_CENTER);
                t.setPadding(0, dp(8), 0, 0);
                lp(t, MATCH, WRAP, 0f, 0, 0, 0, 0);
                break;
            case "back-btn":
                t.setTextSize(24);
                t.setTextColor(TEXT);
                try {
                    t.setFontVariationSettings("'wght' 600");
                } catch (Exception ignored) {
                }
                t.setGravity(Gravity.CENTER);
                t.setTextAlignment(View.TEXT_ALIGNMENT_CENTER);
                t.setIncludeFontPadding(false);
                t.setBackground(round(SURFACE_ALT, 999));
                t.setPadding(0, 0, 0, 0);
                t.setMinWidth(dp(44));
                t.setMinHeight(dp(44));
                LinearLayout.LayoutParams bp = new LinearLayout.LayoutParams(dp(44), dp(44));
                bp.gravity = Gravity.START | Gravity.CENTER_VERTICAL;
                bp.bottomMargin = 0;
                t.setLayoutParams(bp);
                break;
            case "topbar-spacer":
                t.setText("");
                t.setBackground(null);
                t.setPadding(0, 0, 0, 0);
                t.setMinWidth(dp(44));
                t.setMinHeight(dp(44));
                LinearLayout.LayoutParams sp = new LinearLayout.LayoutParams(dp(44), dp(44));
                sp.gravity = Gravity.END | Gravity.CENTER_VERTICAL;
                t.setLayoutParams(sp);
                t.setVisibility(View.INVISIBLE);
                break;
            case "empty":
                t.setTextSize(14);
                t.setTextColor(MUTED);
                t.setBackground(strokeRound(SURFACE, TRACK, 14, 1));
                t.setPadding(dp(18), dp(16), dp(18), dp(16));
                t.setGravity(Gravity.CENTER);
                t.setTextAlignment(View.TEXT_ALIGNMENT_CENTER);
                lp(t, MATCH, WRAP, 0f, 0, 0, 0, 0);
                break;
            case "btn":
                t.setTextSize(15);
                t.setTextColor(TEXT);
                try {
                    t.setFontVariationSettings("'wght' 700");
                } catch (Exception ignored) {
                }
                t.setGravity(Gravity.CENTER);
                t.setPadding(0, dp(14), 0, dp(14));
                t.setBackground(round(SURFACE_ALT, 14));
                lp(t, 0, WRAP, 1f, 0, 0, 0, dp(10));
                break;
            case "primary":
                t.setBackground(round(accent, 14));
                t.setTextColor(ON_ACCENT);
                lp(t, 0, WRAP, 1.5f, 0, 0, 0, dp(10));
                break;
            case "ghost":
                t.setBackground(round(SURFACE_ALT, 14));
                t.setTextColor(TEXT);
                break;
            case "icon-btn":
                t.setTextSize(27);
                t.setTextColor(TEXT);
                try {
                    t.setFontVariationSettings("'wght' 700");
                } catch (Exception ignored) {
                }
                t.setGravity(Gravity.CENTER);
                t.setTextAlignment(View.TEXT_ALIGNMENT_CENTER);
                t.setBackground(round(SURFACE_ALT, 999));
                t.setPadding(0, 0, 0, 0);
                t.setMinWidth(dp(64));
                t.setMinHeight(dp(64));
                lpFixed(t, dp(64), dp(64), dp(8));
                break;
            case "play":
                t.setBackground(round(accent, 999));
                t.setTextColor(ON_ACCENT);
                t.setTextSize(30);
                t.setMinWidth(dp(72));
                t.setMinHeight(dp(72));
                lpFixed(t, dp(72), dp(72), dp(8));
                break;
            case "hist-phase":
                t.setTextSize(14);
                t.setTextColor(accent);
                try {
                    t.setFontVariationSettings("'wght' 700");
                } catch (Exception ignored) {
                }
                lp(t, 0, WRAP, 1f, 0, 0, 0, 0);
                break;
            case "hist-dur":
                t.setTextSize(14);
                t.setTextColor(MUTED);
                break;
            case "history-count":
                t.setTextSize(12);
                t.setTextColor(accent);
                t.setLetterSpacing(0.08f);
                t.setAllCaps(true);
                t.setGravity(Gravity.CENTER);
                lp(t, WRAP, WRAP, 0f, 0, 0, dp(8), 0);
                break;
            case "duration-preview":
                t.setTextSize(46);
                t.setTextColor(TEXT);
                t.setTypeface(outfit);
                try {
                    t.setFontVariationSettings("'wght' 300");
                } catch (Exception ignored) {
                }
                try {
                    t.setFontFeatureSettings("tnum");
                } catch (Exception ignored) {
                }
                t.setLetterSpacing(-0.02f);
                t.setGravity(Gravity.CENTER);
                t.setTextAlignment(View.TEXT_ALIGNMENT_CENTER);
                t.setIncludeFontPadding(false);
                lp(t, MATCH, WRAP, 0f, dp(4), dp(10), 0, 0);
                break;
            case "tape-label":
                t.setTextSize(15);
                t.setTextColor(accent);
                try {
                    t.setFontVariationSettings("'wght' 700");
                } catch (Exception ignored) {
                }
                t.setLetterSpacing(0.18f);
                t.setAllCaps(true);
                t.setGravity(Gravity.CENTER);
                t.setTextAlignment(View.TEXT_ALIGNMENT_CENTER);
                t.setIncludeFontPadding(false);
                lp(t, MATCH, WRAP, 0f, 0, dp(4), 0, 0);
                break;
            case "tab":
                t.setTextSize(13);
                t.setTextColor(MUTED);
                try {
                    t.setFontVariationSettings("'wght' 600");
                } catch (Exception ignored) {
                }
                t.setGravity(Gravity.CENTER);
                t.setTextAlignment(View.TEXT_ALIGNMENT_CENTER);
                t.setBackground(round(SURFACE_ALT, 999));
                t.setPadding(dp(16), dp(9), dp(16), dp(9));
                LinearLayout.LayoutParams tabp = new LinearLayout.LayoutParams(WRAP, WRAP);
                tabp.setMargins(dp(4), 0, dp(4), 0);
                t.setLayoutParams(tabp);
                break;
            case "tab-on":
                t.setBackground(round(accent, 999));
                t.setTextColor(ON_ACCENT);
                break;
            case "done-btn":
                t.setTextSize(24);
                t.setTextColor(ON_ACCENT);
                try {
                    t.setFontVariationSettings("'wght' 700");
                } catch (Exception ignored) {
                }
                t.setGravity(Gravity.CENTER);
                t.setTextAlignment(View.TEXT_ALIGNMENT_CENTER);
                t.setIncludeFontPadding(false);
                t.setBackground(round(accent, 999));
                t.setPadding(0, 0, 0, 0);
                t.setMinWidth(dp(44));
                t.setMinHeight(dp(44));
                LinearLayout.LayoutParams dbp = new LinearLayout.LayoutParams(dp(44), dp(44));
                dbp.gravity = Gravity.END | Gravity.CENTER_VERTICAL;
                t.setLayoutParams(dbp);
                break;
            case "has-hours":
                t.setTextSize(50);
                break;
            case "seg":
                lp(t, 0, dp(5), 1f, 0, 0, dp(2), dp(2));
                t.setBackground(round(TRACK, 3));
                break;
            case "on":
                t.setBackground(round(accent, 3));
                break;
            default:
                break;
        }
    }

    private void styleBareText(TaggedText t, String parentClass, int accent) {
        if (parentClass.equals(t.lastClass) && accent == t.lastAccent) return;
        t.lastClass = parentClass;
        t.lastAccent = accent;
        resetText(t);
        if (parentClass != null && parentClass.contains("history-head")) {
            t.setTextSize(12);
            t.setTextColor(MUTED);
            t.setLetterSpacing(0.18f);
            t.setAllCaps(true);
            t.setGravity(Gravity.CENTER);
            lp(t, WRAP, WRAP, 0f, 0, 0, 0, 0);
        }
    }

    private void bindAction(TaggedText t, int a) {
        if (a >= 0) {
            if (t.action != a) {
                t.action = a;
                t.setOnClickListener(v -> sink.onAction(a));
            }
            t.setClickable(true);
            t.setFocusable(false);
        } else if (t.action != -1) {
            t.action = -1;
            t.setOnClickListener(null);
            t.setClickable(false);
        }
    }

    private void bindAction(TaggedLinear l, int a) {
        if (a >= 0) {
            if (l.action != a) {
                l.action = a;
                l.setOnClickListener(v -> sink.onAction(a));
            }
            l.setClickable(true);
            l.setFocusable(false);
        } else if (l.action != -1) {
            l.action = -1;
            l.setOnClickListener(null);
            l.setClickable(false);
        }
    }

    /**
     * The clock only reacts to a double tap. Single taps fall through (we don't
     * consume the touch) so the page can still be scrolled from the clock face.
     */
    private void bindDoubleTap(TaggedText t, int a) {
        if (a < 0) return;
        if (t.gestures == null) {
            GestureDetector gd = new GestureDetector(ctx, new GestureDetector.SimpleOnGestureListener() {
                @Override
                public boolean onDown(MotionEvent e) {
                    return true;
                }

                @Override
                public boolean onDoubleTap(MotionEvent e) {
                    sink.onAction(a);
                    return true;
                }
            });
            t.gestures = gd;
            t.setOnTouchListener((v, ev) -> {
                gd.onTouchEvent(ev);
                return false;
            });
        }
        t.setClickable(true);
        t.setFocusable(false);
    }

    private void setTextIfChanged(TaggedText t, String value) {
        if (!value.contentEquals(t.getText())) {
            t.setText(value);
            applyIconFont(t, value);
        }
    }

    /** Lucide glyphs live in the private-use area; swap them to the icon font. */
    private void applyIconFont(TaggedText t, String value) {
        if (!isIconGlyph(value)) return;
        t.setTypeface(lucide);
        t.setIncludeFontPadding(false);
    }

    private static boolean isIconGlyph(String value) {
        return value.length() == 1 && value.charAt(0) >= 0xE000 && value.charAt(0) <= 0xF8FF;
    }

    // --- helpers --------------------------------------------------------

    private void lp(View v, int w, int h, float weight, int top, int bottom, int start, int end) {
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(w, h, weight);
        p.setMargins(start, top, end, bottom);
        v.setLayoutParams(p);
    }

    private void lpFixed(View v, int size, int height, int sideMargin) {
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(size, height);
        p.setMargins(sideMargin, 0, sideMargin, 0);
        p.gravity = Gravity.CENTER_VERTICAL;
        v.setLayoutParams(p);
    }

    private void lpFill(View v) {
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(MATCH, MATCH);
        p.gravity = Gravity.CENTER;
        v.setLayoutParams(p);
    }

    private GradientDrawable round(int color, float radiusDp) {
        GradientDrawable d = new GradientDrawable();
        d.setShape(GradientDrawable.RECTANGLE);
        d.setColor(color);
        d.setCornerRadius(dp(radiusDp));
        return d;
    }

    /** Transient press feedback from the theme; keeps rows box-free at rest. */
    private Drawable ripple() {
        TypedValue out = new TypedValue();
        if (ctx.getTheme().resolveAttribute(android.R.attr.selectableItemBackground, out, true)) {
            return ctx.getResources().getDrawable(out.resourceId, ctx.getTheme());
        }
        return null;
    }

    private GradientDrawable strokeRound(int fill, int stroke, float radiusDp, int strokeDp) {
        GradientDrawable d = round(fill, radiusDp);
        d.setStroke(dp(strokeDp), stroke);
        return d;
    }

    private int alpha(int color, float a) {
        return (color & 0x00FFFFFF) | (((int) (a * 255f) & 0xFF) << 24);
    }

    private int dp(float v) {
        return Math.round(TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP, v, ctx.getResources().getDisplayMetrics()));
    }
}
