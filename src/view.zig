//! Timeato view - expresses the UI as a Zylix virtual DOM tree and serializes
//! it to JSON for the thin Android shell.
//!
//! Nothing here renders pixels: Zig decides the whole structure (elements,
//! classes, text, click callbacks), then the shell applies it natively.

const std = @import("std");
const zylix = @import("zylix");
const engine = @import("engine.zig");

pub const MAX_JSON = 16384;

/// Click callback ids. They mirror the event codes the shell dispatches.
pub const Action = struct {
    pub const toggle: u32 = 1;
    pub const reset: u32 = 2;
    pub const skip: u32 = 3;
    pub const settings: u32 = 4;
    pub const back: u32 = 5;
    /// Opens the duration editor (double-tapped on the clock, not single-tapped).
    pub const edit_duration: u32 = 6;
    /// Leaves the duration editor without applying staged values.
    pub const duration_cancel: u32 = 7;
    /// Applies staged durations (the shell also persists them here).
    pub const duration_done: u32 = 8;
    /// Selects which phase the editor targets: `duration_phase_base + index`.
    pub const duration_phase_base: u32 = 20;
    /// Measuring-tape values: `base + value`. Ranges mirror engine constants
    /// (minutes 0-180, seconds 0-59); the shell binds drags to these.
    pub const minute_base: u32 = 100;
    pub const second_base: u32 = 300;
    /// Selecting alarm tone i uses `sound_base + i` (i < engine.ALARM_COUNT).
    pub const sound_base: u32 = 10;

    pub fn sound(i: u32) u32 {
        return sound_base + i;
    }
};

/// Icon glyphs for the control buttons, drawn as text by the shell using the
/// bundled Lucide icon font (private-use codepoints). Names map to the Lucide
/// icons: play, pause, rotate-ccw, skip-forward, settings, arrow-left, check.
pub const Icon = struct {
    pub const play: []const u8 = "\u{e13c}";
    pub const pause: []const u8 = "\u{e12e}";
    pub const reset: []const u8 = "\u{e148}";
    pub const skip: []const u8 = "\u{e160}";
    pub const gear: []const u8 = "\u{e154}";
    pub const back: []const u8 = "\u{e048}";
    pub const check: []const u8 = "\u{e06c}";
};

fn el(tree: *zylix.VTree, tag: zylix.ElementTag, class: []const u8) u32 {
    const id = tree.create(zylix.VNode.element(tag));
    if (tree.get(id)) |node| node.props.setClass(class);
    return id;
}

fn txt(tree: *zylix.VTree, value: []const u8) u32 {
    return tree.create(zylix.VNode.textNode(value));
}

fn append(tree: *zylix.VTree, parent: u32, child: u32) void {
    _ = tree.addChild(parent, child);
}

fn button(
    tree: *zylix.VTree,
    parent: u32,
    class: []const u8,
    action: u32,
    text: []const u8,
) void {
    const id = el(tree, .button, class);
    if (tree.get(id)) |node| node.props.on_click = action;
    append(tree, id, txt(tree, text));
    append(tree, parent, id);
}

/// A picker row: name on the left, a check on the right when selected. The
/// whole row is the tap target, so the shell binds the select action to it.
fn soundRow(tree: *zylix.VTree, parent: u32, index: u32, selected: bool) void {
    const cls = if (selected) "sound-row selected" else "sound-row";
    const id = el(tree, .button, cls);
    if (tree.get(id)) |node| node.props.on_click = Action.sound(index);

    const name_cls = if (selected) "sound-name selected" else "sound-name";
    const name = el(tree, .span, name_cls);
    append(tree, id, name);
    append(tree, name, txt(tree, engine.alarmName(index)));

    const check = el(tree, .span, "sound-check");
    append(tree, id, check);
    if (selected) append(tree, check, txt(tree, Icon.check));

    append(tree, parent, id);
}

fn histClass(buf: []u8, phase: engine.Phase) []const u8 {
    return std.fmt.bufPrint(buf, "hist-item phase-{s}", .{engine.key(phase)}) catch "hist-item";
}

/// Hero title + subtitle shown above the clock. One fixed line per state.
const Copy = struct {
    title: []const u8,
    sub: []const u8,
};

const Band = enum { early, middle, late };

fn band(progress: u32) Band {
    if (progress < 25) return .early;
    if (progress < 75) return .middle;
    return .late;
}

fn heroCopy(e: *const engine.Engine) Copy {
    if (e.running) return runningCopy(e.phase);
    return switch (e.last_interrupt) {
        .none => idleCopy(e.phase),
        .paused => pausedCopy(e.interrupt_phase, band(e.interrupt_progress)),
        .reset => resetCopy(e.interrupt_phase, band(e.interrupt_progress)),
        .skipped => skippedCopy(e.interrupt_phase, band(e.interrupt_progress)),
    };
}

fn runningCopy(phase: engine.Phase) Copy {
    return switch (phase) {
        .focus => .{
            .title = "You're in it now.",
            .sub = "The timer is running. Try to keep up.",
        },
        .short_break => .{
            .title = "Short break. Take it.",
            .sub = "Look away from the screen. Five minutes, no guilt.",
        },
        .long_break => .{
            .title = "Long break. Really stop.",
            .sub = "Fifteen minutes. Recharge properly.",
        },
    };
}

fn idleCopy(phase: engine.Phase) Copy {
    return switch (phase) {
        .focus => .{
            .title = "Got any time to study?",
            .sub = "Let's go and time it up! No time to be lazy.",
        },
        .short_break => .{
            .title = "Break time is waiting.",
            .sub = "Press play and go do nothing useful.",
        },
        .long_break => .{
            .title = "Long break earned.",
            .sub = "Four sessions done. Enjoy this one.",
        },
    };
}

fn pausedCopy(phase: engine.Phase, b: Band) Copy {
    return switch (phase) {
        .focus => switch (b) {
            .early => .{ .title = "Done already?", .sub = "That was less a session and more a glance at the clock." },
            .middle => .{ .title = "Halfway, then nothing?", .sub = "You were doing so well. Suspiciously well." },
            .late => .{ .title = "Stopping with minutes to go?", .sub = "The finish line was right there. It saw you leave." },
        },
        .short_break => switch (b) {
            .early => .{ .title = "Break cut short?", .sub = "You had barely started relaxing." },
            .middle => .{ .title = "Pausing a break?", .sub = "Half a break is still a break. Barely." },
            .late => .{ .title = "Stopping near the end of the break?", .sub = "Almost free. Almost." },
        },
        .long_break => switch (b) {
            .early => .{ .title = "Cutting the long break short?", .sub = "You earned this. Sit with it a while." },
            .middle => .{ .title = "Pausing your reward?", .sub = "Halfway through doing nothing." },
            .late => .{ .title = "Stopping as the break ends?", .sub = "Fine. Back to it." },
        },
    };
}

fn resetCopy(phase: engine.Phase, b: Band) Copy {
    return switch (phase) {
        .focus => switch (b) {
            .early => .{ .title = "Fresh start, again.", .sub = "New timer, same goal. Maybe this one counts." },
            .middle => .{ .title = "Erased the progress?", .sub = "Bold. The books will remember." },
            .late => .{ .title = "Reset with seconds left?", .sub = "That one hurt to watch. Go again." },
        },
        .short_break => switch (b) {
            .early => .{ .title = "Reset the break?", .sub = "Back to a full five. Bold of you." },
            .middle => .{ .title = "Fresh break, same you.", .sub = "The clock restarted. So should you." },
            .late => .{ .title = "Reset with seconds of freedom left?", .sub = "Cruel. Go finish it." },
        },
        .long_break => switch (b) {
            .early => .{ .title = "Reset the long break?", .sub = "Starting your reward over. Ambitious." },
            .middle => .{ .title = "Long break, restarted.", .sub = "The clock is fresh. So are you." },
            .late => .{ .title = "Reset with the break almost over?", .sub = "That was a choice." },
        },
    };
}

fn skippedCopy(phase: engine.Phase, b: Band) Copy {
    return switch (phase) {
        .focus => switch (b) {
            .early => .{ .title = "Skipping out?", .sub = "The pomodoro noticed. It always notices." },
            .middle => .{ .title = "Half a session is a session?", .sub = "Sure. We'll call it a warm up." },
            .late => .{ .title = "Skipped at the finish line?", .sub = "Almost done counts as not done. Run it back." },
        },
        .short_break => switch (b) {
            .early => .{ .title = "Skipping the break?", .sub = "Back to work this soon? Doubtful." },
            .middle => .{ .title = "Skip the break at halfway?", .sub = "The books will still be there." },
            .late => .{ .title = "Skipped the break at the end?", .sub = "You were basically done resting." },
        },
        .long_break => switch (b) {
            .early => .{ .title = "Skipping the long break?", .sub = "Rest is not a suggestion." },
            .middle => .{ .title = "Skipped halfway through resting?", .sub = "Hmm. We'll allow it." },
            .late => .{ .title = "Skipped the long break at the end?", .sub = "You were basically done. Run it back." },
        },
    };
}

/// Build the complete Timeato UI into the reconciler's next tree and commit it.
///
/// Layout (all centered):
///   topbar (timer):    spacer + settings gear pushed right
///   topbar (settings): back button + centered "Alarm sound" header, same row
///   stage:
///     hero:          centered title + subtitle that react to the timer state
///     phase-label:   colored phase word ("Focus"/"Short Break"/...), slot-animated by shell
///     ring:          circular progress (class carries `p<remaining>` 0-100),
///                    clock (display + caption) inside
///   controls:        icon buttons (play/pause, reset, skip) under the clock
///   history:         centered session list under the controls
///   settings:        sound list + note (header lives in the topbar while open)
pub fn build(e: *const engine.Engine) void {
    const tree = zylix.getReconciler().getNextTree();

    var root_buf: [80]u8 = undefined;
    const root_class = std.fmt.bufPrint(&root_buf, "app phase-{s} {s}{s}{s}", .{
        engine.key(e.phase),
        if (e.running) "is-running" else "is-paused",
        if (e.settings_open) " settings-open" else "",
        if (e.duration_open) " duration-open" else "",
    }) catch "app";

    const root = el(tree, .div, root_class);
    tree.setRoot(root);

    // Top bar: centered brand + gear on the timer screen; back + centered
    // alarm header on the settings screen; cancel + done on the duration
    // editor (no brand there).
    const top = el(tree, .header, "topbar");
    append(tree, root, top);
    if (e.duration_open) {
        buildDurationTop(tree, top);
    } else if (!e.settings_open) {
        const grow = el(tree, .div, "topbar-grow");
        append(tree, top, grow);
        button(tree, top, "gear", Action.settings, Icon.gear);
    } else {
        buildSettingsTop(tree, top);
    }

    if (e.duration_open) {
        buildDurationEditor(tree, root, e);
    } else if (e.settings_open) {
        buildSettings(tree, root, e);
    } else {
        buildTimer(tree, root, e);
    }

    _ = zylix.commit();
}

/// Settings header: back button on the left, "Alarm sound" title + subtext
/// centered in the same topbar row.
fn buildSettingsTop(tree: *zylix.VTree, top: u32) void {
    button(tree, top, "back-btn", Action.back, Icon.back);

    const head = el(tree, .div, "settings-head");
    append(tree, top, head);

    const title = el(tree, .div, "settings-title");
    append(tree, head, title);
    append(tree, title, txt(tree, "Alarm sound"));

    const sub = el(tree, .div, "settings-sub");
    append(tree, head, sub);
    append(tree, sub, txt(tree, "Tap a sound to preview and select it."));

    // Balance spacer so the centered head stays truly centered.
    const spacer = el(tree, .div, "topbar-spacer");
    append(tree, top, spacer);
}

/// Alarm picker. Every row is a button (`Action.sound(i)`); the shell plays
/// a preview and persists the choice, Zig just records the index.
fn buildSettings(tree: *zylix.VTree, root: u32, e: *const engine.Engine) void {
    const settings = el(tree, .section, "settings");
    append(tree, root, settings);

    const list = el(tree, .div, "sound-list");
    append(tree, settings, list);

    var i: u32 = 0;
    while (i < engine.ALARM_COUNT) : (i += 1) {
        soundRow(tree, list, i, i == e.alarm_sound);
    }

    const note = el(tree, .div, "settings-note");
    append(tree, settings, note);
    append(tree, note, txt(tree, "Plays when a session ends."));
}

/// Duration editor header: cancel on the left, title centered, a check that
/// commits on the right.
fn buildDurationTop(tree: *zylix.VTree, top: u32) void {
    button(tree, top, "back-btn", Action.duration_cancel, Icon.back);

    const head = el(tree, .div, "settings-head");
    append(tree, top, head);

    const title = el(tree, .div, "settings-title");
    append(tree, head, title);
    append(tree, title, txt(tree, "Set duration"));

    const sub = el(tree, .div, "settings-sub");
    append(tree, head, sub);
    append(tree, sub, txt(tree, "Drag the tape to set a phase. Max 3 hours."));

    button(tree, top, "done-btn", Action.duration_done, Icon.check);
}

/// Measuring-tape duration editor. A tab row picks the phase; two ruler strips
/// (minutes 0-180, seconds 0-59) share one fixed centre needle. The shell
/// renders the tape and feeds drag detents back as `Action.minute_base` /
/// `Action.second_base` offsets; Zig only stages the value here.
fn buildDurationEditor(tree: *zylix.VTree, root: u32, e: *const engine.Engine) void {
    const screen = el(tree, .section, "duration");
    append(tree, root, screen);

    const tabs = el(tree, .div, "phase-tabs");
    append(tree, screen, tabs);

    var i: u32 = 0;
    while (i < engine.PHASE_COUNT) : (i += 1) {
        const phase = engine.phaseFromIndex(i);
        const selected = engine.phaseIndex(e.duration_phase) == i;
        const tab = el(tree, .button, if (selected) "tab tab-on" else "tab");
        if (tree.get(tab)) |node| node.props.on_click = Action.duration_phase_base + i;
        append(tree, tab, txt(tree, engine.label(phase)));
        append(tree, tabs, tab);
    }

    var preview_buf: [12]u8 = undefined;
    const preview = el(tree, .div, "duration-preview");
    append(tree, screen, preview);
    append(tree, preview, txt(tree, engine.formatMs(e.editTotalMs(e.duration_phase), &preview_buf)));

    const tapes = el(tree, .div, "tape-wrap");
    append(tree, screen, tapes);
    tapeField(tree, tapes, e, true);
    tapeField(tree, tapes, e, false);

    const note = el(tree, .div, "settings-note");
    append(tree, screen, note);
    append(tree, note, txt(tree, "Minutes cap at 180 - three hours."));
}

/// One labelled tape strip. The class carries the unit and the current value
/// (`v<n>`) so the native ruler can place its ticks without extra properties.
fn tapeField(tree: *zylix.VTree, parent: u32, e: *const engine.Engine, is_minutes: bool) void {
    const field = el(tree, .div, "tape-field");
    append(tree, parent, field);

    const label = el(tree, .span, "tape-label");
    append(tree, field, label);
    append(tree, label, txt(tree, if (is_minutes) "Minutes" else "Seconds"));

    const value = if (is_minutes) e.editMinutes(e.duration_phase) else e.editSeconds(e.duration_phase);
    var buf: [72]u8 = undefined;
    const cls = std.fmt.bufPrint(&buf, "tape tape-{s} v{d} phase-{s}", .{
        if (is_minutes) "minutes" else "seconds",
        value,
        engine.key(e.duration_phase),
    }) catch if (is_minutes) "tape tape-minutes" else "tape tape-seconds";
    const tape = el(tree, .div, cls);
    append(tree, field, tape);
}

fn buildTimer(tree: *zylix.VTree, root: u32, e: *const engine.Engine) void {
    // Stage: hero copy + phase word + circular clock.
    const stage = el(tree, .section, "stage");
    append(tree, root, stage);

    const copy = heroCopy(e);
    const hero = el(tree, .div, "hero");
    append(tree, stage, hero);

    const hero_title = el(tree, .div, "hero-title");
    append(tree, hero, hero_title);
    append(tree, hero_title, txt(tree, copy.title));

    const hero_sub = el(tree, .div, "hero-sub");
    append(tree, hero, hero_sub);
    append(tree, hero_sub, txt(tree, copy.sub));

    var phase_buf: [48]u8 = undefined;
    const phase_class = std.fmt.bufPrint(&phase_buf, "phase-label phase-{s}", .{engine.key(e.phase)}) catch "phase-label";
    const phase_label = el(tree, .div, phase_class);
    append(tree, stage, phase_label);
    append(tree, phase_label, txt(tree, engine.label(e.phase)));

    const ring_wrap = el(tree, .div, "ring-wrap");
    append(tree, stage, ring_wrap);

    // Remaining percent drives the ring: the track sits empty while ready,
    // fills red on start, and the emptying sweep removes the red as time runs.
    const time_remaining: u32 = 100 -| e.progressPercent();
    const remaining: u32 = if (!e.running and e.elapsedMs() == 0) 0 else time_remaining;
    var ring_buf: [64]u8 = undefined;
    const ring_class = std.fmt.bufPrint(&ring_buf, "ring p{d} phase-{s} {s}", .{
        remaining,
        engine.key(e.phase),
        if (e.running) "is-running" else "is-paused",
    }) catch "ring p100";
    const ring = el(tree, .div, ring_class);
    append(tree, ring_wrap, ring);

    const center = el(tree, .div, "ring-center");
    append(tree, ring, center);

    var time_buf: [12]u8 = undefined;
    var disp_buf: [40]u8 = undefined;
    const disp_class = std.fmt.bufPrint(&disp_buf, "display clock-edit{s}", .{
        if (e.remaining_ms >= 60 * 60 * 1000) " has-hours" else "",
    }) catch "display clock-edit";
    const display = el(tree, .div, disp_class);
    if (tree.get(display)) |node| node.props.on_click = Action.edit_duration;
    append(tree, center, display);
    append(tree, display, txt(tree, e.formatRemaining(&time_buf)));

    const caption = el(tree, .div, "caption");
    append(tree, center, caption);
    append(tree, caption, txt(tree, if (e.running) "in progress" else if (e.elapsedMs() == 0) "ready" else "paused"));

    // Controls: icon buttons under the clock (play in the middle).
    const controls = el(tree, .div, "controls");
    append(tree, root, controls);
    button(tree, controls, "icon-btn", Action.reset, Icon.reset);
    button(tree, controls, "icon-btn play", Action.toggle, if (e.running) Icon.pause else Icon.play);
    button(tree, controls, "icon-btn", Action.skip, Icon.skip);

    // Session history, newest first.
    const history = el(tree, .section, "history");
    append(tree, root, history);

    const head = el(tree, .div, "history-head");
    append(tree, history, head);
    append(tree, head, txt(tree, "Sessions"));

    var count_buf: [16]u8 = undefined;
    const count_text = std.fmt.bufPrint(&count_buf, "{d} done", .{e.completed_focus}) catch "0 done";
    const count = el(tree, .span, "history-count");
    append(tree, head, count);
    append(tree, count, txt(tree, count_text));

    if (e.history_len == 0) {
        const empty = el(tree, .div, "empty");
        append(tree, history, empty);
        append(tree, empty, txt(tree, "No sessions yet - press start."));
    } else {
        const list = el(tree, .ul, "history-list");
        append(tree, history, list);

        var i: u32 = e.history_len;
        while (i > 0) {
            i -= 1;
            const session = e.history[i];

            var class_buf: [40]u8 = undefined;
            const item = el(tree, .li, histClass(&class_buf, session.phase));
            append(tree, list, item);

            const phase = el(tree, .span, "hist-phase");
            append(tree, item, phase);
            append(tree, phase, txt(tree, engine.label(session.phase)));

            var dur_buf: [8]u8 = undefined;
            const duration = el(tree, .span, "hist-dur");
            append(tree, item, duration);
            append(tree, duration, txt(tree, engine.formatMs(session.duration_ms, &dur_buf)));
        }
    }
}

// --- JSON serialization -------------------------------------------------

const Json = struct {
    buf: []u8,
    len: usize = 0,

    fn put(self: *Json, value: []const u8) void {
        const room = self.buf.len - self.len;
        const n = @min(value.len, room);
        @memcpy(self.buf[self.len .. self.len + n], value[0..n]);
        self.len += n;
    }

    fn byte(self: *Json, c: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = c;
            self.len += 1;
        }
    }

    fn int(self: *Json, value: u32) void {
        var tmp: [12]u8 = undefined;
        self.put(std.fmt.bufPrint(&tmp, "{d}", .{value}) catch return);
    }

    fn escaped(self: *Json, value: []const u8) void {
        for (value) |c| switch (c) {
            '"' => self.put("\\\""),
            '\\' => self.put("\\\\"),
            '\n' => self.put("\\n"),
            '\r' => self.put("\\r"),
            '\t' => self.put("\\t"),
            else => if (c < 0x20) self.byte(' ') else self.byte(c),
        };
    }
};

fn tagName(tag: zylix.ElementTag) []const u8 {
    return switch (tag) {
        .div => "div",
        .span => "span",
        .section => "section",
        .article => "article",
        .header => "header",
        .footer => "footer",
        .nav => "nav",
        .main => "main",
        .aside => "aside",
        .h1 => "h1",
        .h2 => "h2",
        .h3 => "h3",
        .h4 => "h4",
        .h5 => "h5",
        .h6 => "h6",
        .p => "p",
        .button => "button",
        .a => "a",
        .input => "input",
        .img => "img",
        .ul => "ul",
        .ol => "ol",
        .li => "li",
        .form => "form",
        .label => "label",
    };
}

fn writeNode(w: *Json, tree: *const zylix.VTree, id: u32) void {
    const node = tree.getConst(id) orelse {
        w.put("null");
        return;
    };

    w.byte('{');
    if (node.node_type == .text) {
        w.put("\"t\":\"#text\",\"x\":\"");
        w.escaped(node.getText());
        w.byte('"');
    } else {
        w.put("\"t\":\"");
        w.put(tagName(node.tag));
        w.byte('"');

        const class = node.props.getClass();
        if (class.len > 0) {
            w.put(",\"c\":\"");
            w.escaped(class);
            w.byte('"');
        }
        if (node.props.on_click != 0) {
            w.put(",\"a\":");
            w.int(node.props.on_click);
        }
        if (node.hasKey()) {
            w.put(",\"k\":\"");
            w.escaped(node.getKey());
            w.byte('"');
        }
        if (node.child_count > 0) {
            w.put(",\"ch\":[");
            var i: u8 = 0;
            while (i < node.child_count) : (i += 1) {
                if (i != 0) w.byte(',');
                writeNode(w, tree, node.children[i]);
            }
            w.byte(']');
        }
    }
    w.byte('}');
}

/// Rebuild the view and serialize it. Returns the used slice of `buf`.
pub fn renderJson(e: *const engine.Engine, buf: []u8) []u8 {
    build(e);
    const tree = zylix.getReconciler().getCurrentTree();

    var w = Json{ .buf = buf };
    w.put("{\"running\":");
    w.put(if (e.running) "true" else "false");
    w.put(",\"progress\":");
    w.int(e.progressPercent());
    w.put(",\"remaining\":");
    w.int(100 -| e.progressPercent());
    w.put(",\"phase\":\"");
    w.put(engine.key(e.phase));
    w.put("\",\"label\":\"");
    w.escaped(engine.label(e.phase));
    w.put("\",\"alarm\":");
    w.int(e.alarm_seq);
    w.put(",\"alarm_sound\":");
    w.int(e.alarm_sound);
    w.put(",\"settings\":");
    w.put(if (e.settings_open) "true" else "false");
    w.put(",\"tree\":");
    writeNode(&w, tree, tree.root_id);
    w.byte('}');
    return buf[0..w.len];
}

// --- tests --------------------------------------------------------------

test "view carries the countdown and phase class" {
    var app = engine.Engine.init();
    var buf: [MAX_JSON]u8 = undefined;
    const json = renderJson(&app, &buf);

    try std.testing.expect(std.mem.indexOf(u8, json, "25:00") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "phase-focus") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "is-paused") != null);

    app.apply(.start);
    var buf2: [MAX_JSON]u8 = undefined;
    const json2 = renderJson(&app, &buf2);
    try std.testing.expect(std.mem.indexOf(u8, json2, "is-running") != null);
}

test "view lists recorded sessions" {
    var app = engine.Engine.init();
    app.apply(.start);
    app.tick(app.config.focus_ms);

    var buf: [MAX_JSON]u8 = undefined;
    const json = renderJson(&app, &buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "Sessions") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "hist-item") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "No sessions yet") == null);
}

test "view marks click actions" {
    var app = engine.Engine.init();
    var buf: [MAX_JSON]u8 = undefined;
    const json = renderJson(&app, &buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"a\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"a\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"a\":3") != null);
}

test "controls keep play in the middle" {
    var app = engine.Engine.init();
    var buf: [MAX_JSON]u8 = undefined;
    const json = renderJson(&app, &buf);

    const reset = std.mem.indexOf(u8, json, Icon.reset);
    const play = std.mem.indexOf(u8, json, Icon.play);
    const skip = std.mem.indexOf(u8, json, Icon.skip);
    try std.testing.expect(reset != null and play != null and skip != null);
    try std.testing.expect(reset.? < play.? and play.? < skip.?);
}

test "view uses a ring with remaining progress and icon buttons" {
    var app = engine.Engine.init();
    var buf: [MAX_JSON]u8 = undefined;
    const json = renderJson(&app, &buf);

    try std.testing.expect(std.mem.indexOf(u8, json, "ring p0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "phase-label") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "icon-btn play") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "ring-center") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"remaining\":100") != null);

    app.apply(.start);
    app.tick(app.config.focus_ms / 2);
    var buf2: [MAX_JSON]u8 = undefined;
    const json2 = renderJson(&app, &buf2);
    try std.testing.expect(std.mem.indexOf(u8, json2, "ring p50") != null);
    try std.testing.expect(std.mem.indexOf(u8, json2, "\"remaining\":50") != null);
}

test "timer screen links to settings" {
    var app = engine.Engine.init();
    var buf: [MAX_JSON]u8 = undefined;
    const json = renderJson(&app, &buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"a\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, Icon.gear) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"settings\":false") != null);
}

test "settings lists every alarm tone with select actions" {
    var app = engine.Engine.init();
    app.apply(.open_settings);
    var buf: [MAX_JSON]u8 = undefined;
    const json = renderJson(&app, &buf);

    try std.testing.expect(std.mem.indexOf(u8, json, "settings-open") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"settings\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Alarm sound") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "sound-row selected") != null);
    // One select action per bundled tone, plus the back button.
    var i: u32 = 0;
    while (i < engine.ALARM_COUNT) : (i += 1) {
        var needle: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&needle, "\"a\":{d}", .{Action.sound(i)}) catch continue;
        try std.testing.expect(std.mem.indexOf(u8, json, text) != null);
        try std.testing.expect(std.mem.indexOf(u8, json, engine.alarmName(i)) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, json, "\"a\":5") != null);
    // The timer chrome is gone while settings are open.
    try std.testing.expect(std.mem.indexOf(u8, json, "ring-center") == null);
}

test "idle hero asks about study time and drops the brand title" {
    var app = engine.Engine.init();
    var buf: [MAX_JSON]u8 = undefined;
    const json = renderJson(&app, &buf);

    try std.testing.expect(std.mem.indexOf(u8, json, "Got any time to study?") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "No time to be lazy.") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "hero-title") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "hero-sub") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Timeato") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "topbar-grow") != null);
}

test "running hero encourages" {
    var app = engine.Engine.init();
    app.apply(.start);
    var buf: [MAX_JSON]u8 = undefined;
    const json = renderJson(&app, &buf);

    try std.testing.expect(std.mem.indexOf(u8, json, "You're in it now.") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Got any time to study?") == null);
}

test "paused copy reflects how far in the user stopped" {
    // Early: 10% done.
    {
        var app = engine.Engine.init();
        app.apply(.start);
        app.tick(app.config.focus_ms / 10);
        app.apply(.pause);
        var buf: [MAX_JSON]u8 = undefined;
        const json = renderJson(&app, &buf);
        try std.testing.expect(std.mem.indexOf(u8, json, "Done already?") != null);
    }
    // Middle: 50% done.
    {
        var app = engine.Engine.init();
        app.apply(.start);
        app.tick(app.config.focus_ms / 2);
        app.apply(.pause);
        var buf: [MAX_JSON]u8 = undefined;
        const json = renderJson(&app, &buf);
        try std.testing.expect(std.mem.indexOf(u8, json, "Halfway, then nothing?") != null);
    }
    // Late: 90% done.
    {
        var app = engine.Engine.init();
        app.apply(.start);
        app.tick(app.config.focus_ms * 9 / 10);
        app.apply(.pause);
        var buf: [MAX_JSON]u8 = undefined;
        const json = renderJson(&app, &buf);
        try std.testing.expect(std.mem.indexOf(u8, json, "Stopping with minutes to go?") != null);
    }
}

test "short break has its own copy" {
    var app = engine.Engine.init();
    app.apply(.start);
    app.tick(app.config.focus_ms);

    var buf: [MAX_JSON]u8 = undefined;
    const json = renderJson(&app, &buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "Short break. Take it.") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "You're in it now.") == null);

    app.apply(.pause);
    var buf2: [MAX_JSON]u8 = undefined;
    const json2 = renderJson(&app, &buf2);
    try std.testing.expect(std.mem.indexOf(u8, json2, "Break cut short?") != null);
}

test "long break has its own copy" {
    var app = engine.Engine.init();
    app.apply(.start);
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        app.tick(app.config.focus_ms);
        if (i < 3) app.tick(app.config.short_break_ms);
    }
    try std.testing.expectEqual(engine.Phase.long_break, app.phase);

    var buf: [MAX_JSON]u8 = undefined;
    const json = renderJson(&app, &buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "Long break. Really stop.") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Short break. Take it.") == null);
}

test "skipping a break shows break copy, not focus copy" {
    var app = engine.Engine.init();
    app.apply(.start);
    app.tick(app.config.focus_ms); // auto-advance into the short break
    app.tick(app.config.short_break_ms / 2);
    app.apply(.skip);

    var buf: [MAX_JSON]u8 = undefined;
    const json = renderJson(&app, &buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "Skip the break at halfway?") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Half a session is a session?") == null);
}

test "reset and skip have their own copy" {
    var app = engine.Engine.init();
    app.apply(.start);
    app.tick(app.config.focus_ms / 2);
    app.apply(.reset);
    var buf: [MAX_JSON]u8 = undefined;
    const json = renderJson(&app, &buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "Erased the progress?") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Halfway, then nothing?") == null);

    var app2 = engine.Engine.init();
    app2.apply(.start);
    app2.tick(app2.config.focus_ms / 2);
    app2.apply(.skip);
    var buf2: [MAX_JSON]u8 = undefined;
    const json2 = renderJson(&app2, &buf2);
    try std.testing.expect(std.mem.indexOf(u8, json2, "Half a session is a session?") != null);
    try std.testing.expect(std.mem.indexOf(u8, json2, "Erased the progress?") == null);
}

test "render carries the alarm seq and selected tone" {
    var app = engine.Engine.init();
    app.apply(.{ .select_alarm = 3 });
    app.apply(.start);
    app.tick(app.config.focus_ms);
    var buf: [MAX_JSON]u8 = undefined;
    const json = renderJson(&app, &buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"alarm\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"alarm_sound\":3") != null);
}

test "clock is double-tap editable only through its own action" {
    var app = engine.Engine.init();
    var buf: [MAX_JSON]u8 = undefined;
    const json = renderJson(&app, &buf);

    try std.testing.expect(std.mem.indexOf(u8, json, "clock-edit") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"a\":6") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "has-hours") == null);
}

test "clock grows an hour field past sixty minutes" {
    var app = engine.Engine.init();
    app.apply(.open_duration);
    app.apply(.{ .set_minutes = 90 });
    app.apply(.duration_done);

    var buf: [MAX_JSON]u8 = undefined;
    const json = renderJson(&app, &buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "has-hours") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "1:30:00") != null);
}

test "duration editor lays out tabs, tapes and a preview" {
    var app = engine.Engine.init();
    app.apply(.open_duration);
    var buf: [MAX_JSON]u8 = undefined;
    const json = renderJson(&app, &buf);

    try std.testing.expect(std.mem.indexOf(u8, json, "duration-open") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Set duration") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "phase-tabs") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "tab-on") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "duration-preview") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "tape tape-minutes v25") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "tape tape-seconds v0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"a\":8") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"a\":7") != null);
    // The timer chrome is gone while editing.
    try std.testing.expect(std.mem.indexOf(u8, json, "ring-center") == null);
}

test "duration editor targets the selected phase" {
    var app = engine.Engine.init();
    app.apply(.open_duration);
    app.apply(.{ .select_duration_phase = 1 });
    app.apply(.{ .set_minutes = 8 });
    var buf: [MAX_JSON]u8 = undefined;
    const json = renderJson(&app, &buf);

    try std.testing.expect(std.mem.indexOf(u8, json, "tape tape-minutes v8") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"a\":21") != null);
    // 8 minutes previews without an hour field.
    try std.testing.expect(std.mem.indexOf(u8, json, "08:00") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "0:08:00") == null);
}

test "tape values surface staged hour and second edits" {
    var app = engine.Engine.init();
    app.apply(.open_duration);
    app.apply(.{ .set_minutes = 180 });
    app.apply(.{ .set_seconds = 45 });
    var buf: [MAX_JSON]u8 = undefined;
    const json = renderJson(&app, &buf);
    // The 3h cap collapsed the seconds that no longer fit.
    try std.testing.expect(std.mem.indexOf(u8, json, "tape tape-minutes v180") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "tape tape-seconds v0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "3:00:00") != null);
}
