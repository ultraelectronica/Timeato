//! Timeato view - expresses the UI as a Zylix virtual DOM tree and serializes
//! it to JSON for the thin web shell.
//!
//! Nothing here renders pixels: Zig decides the whole structure (elements,
//! classes, text, click callbacks), then the shell applies it to the DOM.

const std = @import("std");
const zylix = @import("zylix");
const engine = @import("engine.zig");

pub const SEGMENTS = 12;
pub const MAX_JSON = 16384;

/// Click callback ids. They mirror the event codes the shell dispatches.
pub const Action = struct {
    pub const toggle: u32 = 1;
    pub const reset: u32 = 2;
    pub const skip: u32 = 3;
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

fn histClass(buf: []u8, phase: engine.Phase) []const u8 {
    return std.fmt.bufPrint(buf, "hist-item phase-{s}", .{engine.key(phase)}) catch "hist-item";
}

/// Build the complete Timeato UI into the reconciler's next tree and commit it.
pub fn build(e: *const engine.Engine) void {
    const tree = zylix.getReconciler().getNextTree();

    var root_buf: [64]u8 = undefined;
    const root_class = std.fmt.bufPrint(&root_buf, "app phase-{s} {s}", .{
        engine.key(e.phase),
        if (e.running) "is-running" else "is-paused",
    }) catch "app";

    const root = el(tree, .div, root_class);
    tree.setRoot(root);

    // Top bar: brand + current phase.
    const top = el(tree, .header, "topbar");
    append(tree, root, top);
    const brand = el(tree, .div, "brand");
    append(tree, top, brand);
    append(tree, brand, txt(tree, "Timeato"));
    const pill = el(tree, .div, "pill");
    append(tree, top, pill);
    append(tree, pill, txt(tree, engine.label(e.phase)));

    // Timer: countdown, caption, segmented progress.
    const timer = el(tree, .section, "timer");
    append(tree, root, timer);

    var time_buf: [8]u8 = undefined;
    const display = el(tree, .div, "display");
    append(tree, timer, display);
    append(tree, display, txt(tree, e.formatRemaining(&time_buf)));

    const caption = el(tree, .div, "caption");
    append(tree, timer, caption);
    append(tree, caption, txt(tree, if (e.running) "in progress" else if (e.elapsedMs() == 0) "ready" else "paused"));

    const progress = el(tree, .div, "progress");
    append(tree, timer, progress);
    const percent = e.progressPercent();
    var seg: u32 = 0;
    while (seg < SEGMENTS) : (seg += 1) {
        const threshold = ((seg + 1) * 100) / SEGMENTS;
        append(tree, progress, el(tree, .span, if (percent >= threshold) "seg on" else "seg"));
    }

    // Controls.
    const controls = el(tree, .div, "controls");
    append(tree, root, controls);
    button(tree, controls, "btn primary", Action.toggle, if (e.running) "Pause" else "Start");
    button(tree, controls, "btn ghost", Action.reset, "Reset");
    button(tree, controls, "btn ghost", Action.skip, "Skip");

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

    _ = zylix.commit();
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
