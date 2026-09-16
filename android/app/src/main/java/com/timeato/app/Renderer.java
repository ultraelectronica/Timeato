package com.timeato.app;

import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Applies the JSON view tree Zig produces, mirroring the CSS in web/index.html.
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

    private final Context ctx;
    private final ActionSink sink;
    private final Typeface outfit;
    private int accent = Color.parseColor("#FF6B57");

    Renderer(Context ctx, ActionSink sink) {
        this.ctx = ctx;
        this.sink = sink;
        this.outfit = ctx.getResources().getFont(R.font.outfit);
    }

    static final class TaggedLinear extends LinearLayout {
        String vtag = "";
        String lastClass = null;
        int lastAccent = 0;

        TaggedLinear(Context c) {
            super(c);
        }
    }

    static final class TaggedText extends TextView {
        String vtag = "";
        String lastClass = null;
        int lastAccent = 0;
        int action = -1;

        TaggedText(Context c) {
            super(c);
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

        if (isContainer(node)) {
            TaggedLinear l = (cur instanceof TaggedLinear) ? (TaggedLinear) cur : new TaggedLinear(ctx);
            l.vtag = tag;
            styleContainer(l, cls, accent);
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
        bindAction(t, node.optInt("a", -1));
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
                    l.setPadding(0, 0, 0, dp(26));
                    break;
                case "timer":
                    l.setGravity(Gravity.CENTER_HORIZONTAL);
                    l.setPadding(0, dp(4), 0, dp(26));
                    break;
                case "progress":
                    l.setOrientation(LinearLayout.HORIZONTAL);
                    l.setPadding(0, dp(24), 0, 0);
                    break;
                case "controls":
                    l.setOrientation(LinearLayout.HORIZONTAL);
                    l.setPadding(0, 0, 0, dp(28));
                    break;
                case "history-head":
                    l.setOrientation(LinearLayout.HORIZONTAL);
                    l.setGravity(Gravity.CENTER_VERTICAL);
                    l.setPadding(0, 0, 0, dp(12));
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
            for (String tok : cls.split(" ")) {
                applyTextToken(t, tok, accent);
            }
        }
    }

    private void resetText(TaggedText t) {
        t.setTextSize(14);
        t.setTextColor(MUTED);
        t.setTypeface(outfit);
        t.setFontVariationSettings("'wght' 400");
        t.setFontFeatureSettings("tnum");
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
                t.setFontVariationSettings("'wght' 700");
                t.setLetterSpacing(0.02f);
                lp(t, 0, WRAP, 1f, 0, 0, 0, 0);
                break;
            case "pill":
                t.setTextSize(11);
                t.setTextColor(accent);
                t.setFontVariationSettings("'wght' 700");
                t.setLetterSpacing(0.18f);
                t.setAllCaps(true);
                t.setBackground(strokeRound(alpha(accent, 0.16f), alpha(accent, 0.55f), 999, 1));
                t.setPadding(dp(10), dp(5), dp(10), dp(5));
                break;
            case "display":
                t.setTextSize(72);
                t.setTextColor(TEXT);
                t.setTypeface(outfit);
                t.setFontVariationSettings("'wght' 300");
                t.setFontFeatureSettings("tnum");
                t.setLetterSpacing(-0.03f);
                t.setIncludeFontPadding(false);
                break;
            case "caption":
                t.setTextSize(12);
                t.setTextColor(MUTED);
                t.setLetterSpacing(0.22f);
                t.setAllCaps(true);
                break;
            case "empty":
                t.setTextSize(14);
                t.setTextColor(MUTED);
                t.setBackground(strokeRound(SURFACE, TRACK, 14, 1));
                t.setPadding(dp(18), dp(16), dp(18), dp(16));
                break;
            case "btn":
                t.setTextSize(15);
                t.setTextColor(TEXT);
                t.setFontVariationSettings("'wght' 700");
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
            case "hist-phase":
                t.setTextSize(14);
                t.setTextColor(accent);
                t.setFontVariationSettings("'wght' 700");
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
        if ("history-head".equals(parentClass)) {
            t.setTextSize(12);
            t.setTextColor(MUTED);
            t.setLetterSpacing(0.18f);
            t.setAllCaps(true);
            lp(t, 0, WRAP, 1f, 0, 0, 0, 0);
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

    private void setTextIfChanged(TaggedText t, String value) {
        if (!value.contentEquals(t.getText())) {
            t.setText(value);
        }
    }

    // --- helpers --------------------------------------------------------

    private void lp(View v, int w, int h, float weight, int top, int bottom, int start, int end) {
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(w, h, weight);
        p.setMargins(start, top, end, bottom);
        v.setLayoutParams(p);
    }

    private GradientDrawable round(int color, float radiusDp) {
        GradientDrawable d = new GradientDrawable();
        d.setShape(GradientDrawable.RECTANGLE);
        d.setColor(color);
        d.setCornerRadius(dp(radiusDp));
        return d;
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
