//! Timeato engine - the Pomodoro state machine, in pure Zig.
//!
//! No framework, no allocator, no I/O. Every rule of the timer lives here and
//! is exercised by the unit tests at the bottom of this file.

const std = @import("std");

pub const Phase = enum(u8) {
    focus,
    short_break,
    long_break,
};

pub fn label(phase: Phase) []const u8 {
    return switch (phase) {
        .focus => "Focus",
        .short_break => "Short Break",
        .long_break => "Long Break",
    };
}

pub fn key(phase: Phase) []const u8 {
    return switch (phase) {
        .focus => "focus",
        .short_break => "short_break",
        .long_break => "long_break",
    };
}

pub const Config = struct {
    focus_ms: u32 = 25 * 60 * 1000,
    short_break_ms: u32 = 5 * 60 * 1000,
    long_break_ms: u32 = 15 * 60 * 1000,
    long_break_every: u32 = 4,

    pub fn durationFor(self: Config, phase: Phase) u32 {
        return switch (phase) {
            .focus => self.focus_ms,
            .short_break => self.short_break_ms,
            .long_break => self.long_break_ms,
        };
    }
};

pub const Event = union(enum) {
    start,
    pause,
    toggle,
    reset,
    skip,
    tick: u32,
};

pub const MAX_HISTORY = 6;

pub const Session = struct {
    phase: Phase,
    duration_ms: u32,
};

pub const Engine = struct {
    config: Config = .{},
    phase: Phase = .focus,
    remaining_ms: u32 = 0,
    running: bool = false,
    completed_focus: u32 = 0,
    history: [MAX_HISTORY]Session = undefined,
    history_len: u32 = 0,

    pub fn init() Engine {
        var engine = Engine{};
        engine.remaining_ms = engine.config.focus_ms;
        return engine;
    }

    // --- queries --------------------------------------------------------

    pub fn durationMs(self: *const Engine) u32 {
        return self.config.durationFor(self.phase);
    }

    pub fn elapsedMs(self: *const Engine) u32 {
        const total = self.durationMs();
        return if (self.remaining_ms >= total) 0 else total - self.remaining_ms;
    }

    pub fn progressPercent(self: *const Engine) u32 {
        const total = self.durationMs();
        if (total == 0) return 100;
        return (self.elapsedMs() * 100) / total;
    }

    pub fn remainingSeconds(self: *const Engine) u32 {
        return (self.remaining_ms + 999) / 1000;
    }

    pub fn formatRemaining(self: *const Engine, buf: []u8) []const u8 {
        return formatMs(self.remaining_ms, buf);
    }

    // --- commands -------------------------------------------------------

    pub fn apply(self: *Engine, event: Event) void {
        switch (event) {
            .start => self.running = true,
            .pause => self.running = false,
            .toggle => self.running = !self.running,
            .reset => self.reset(),
            .skip => self.advance(),
            .tick => |delta_ms| self.tick(delta_ms),
        }
    }

    pub fn reset(self: *Engine) void {
        self.phase = .focus;
        self.remaining_ms = self.config.focus_ms;
        self.running = false;
        self.completed_focus = 0;
        self.history_len = 0;
    }

    pub fn tick(self: *Engine, delta_ms: u32) void {
        if (!self.running or delta_ms == 0) return;

        var left = delta_ms;
        while (true) {
            if (self.remaining_ms > left) {
                self.remaining_ms -= left;
                return;
            }
            left -= self.remaining_ms;
            self.advance();
            if (self.remaining_ms == 0) { // zero-length phase guard
                self.running = false;
                return;
            }
            if (left == 0) return;
        }
    }

    fn advance(self: *Engine) void {
        self.record(self.phase, self.durationMs());

        switch (self.phase) {
            .focus => {
                self.completed_focus += 1;
                const long_due = self.completed_focus % self.config.long_break_every == 0;
                self.phase = if (long_due) .long_break else .short_break;
            },
            .short_break, .long_break => self.phase = .focus,
        }
        self.remaining_ms = self.durationMs();
    }

    fn record(self: *Engine, phase: Phase, duration_ms: u32) void {
        const session = Session{ .phase = phase, .duration_ms = duration_ms };
        if (self.history_len < MAX_HISTORY) {
            self.history[self.history_len] = session;
            self.history_len += 1;
            return;
        }
        var i: u32 = 1;
        while (i < MAX_HISTORY) : (i += 1) self.history[i - 1] = self.history[i];
        self.history[MAX_HISTORY - 1] = session;
    }
};

pub fn formatMs(ms: u32, buf: []u8) []const u8 {
    const total = (ms + 999) / 1000;
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ total / 60, total % 60 }) catch buf[0..0];
}

// --- tests --------------------------------------------------------------

test "starts idle in focus at the full duration" {
    const engine = Engine.init();
    try std.testing.expectEqual(Phase.focus, engine.phase);
    try std.testing.expect(!engine.running);
    try std.testing.expectEqual(@as(u32, 25 * 60 * 1000), engine.remaining_ms);
    try std.testing.expectEqual(@as(u32, 0), engine.progressPercent());
}

test "time only moves while running" {
    var engine = Engine.init();
    engine.tick(1000);
    try std.testing.expectEqual(@as(u32, 25 * 60 * 1000), engine.remaining_ms);

    engine.apply(.start);
    engine.tick(1000);
    try std.testing.expectEqual(@as(u32, 25 * 60 * 1000 - 1000), engine.remaining_ms);
}

test "finishing focus rolls into a short break" {
    var engine = Engine.init();
    engine.apply(.start);
    engine.tick(engine.config.focus_ms);

    try std.testing.expectEqual(Phase.short_break, engine.phase);
    try std.testing.expectEqual(@as(u32, 1), engine.completed_focus);
    try std.testing.expectEqual(engine.config.short_break_ms, engine.remaining_ms);
    try std.testing.expect(engine.running);
    try std.testing.expectEqual(@as(u32, 1), engine.history_len);
}

test "every fourth focus earns a long break" {
    var engine = Engine.init();
    engine.apply(.start);

    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        engine.tick(engine.config.focus_ms);
        const expected: Phase = if (i == 3) .long_break else .short_break;
        try std.testing.expectEqual(expected, engine.phase);
        if (i != 3) engine.tick(engine.config.short_break_ms);
    }

    try std.testing.expectEqual(@as(u32, 4), engine.completed_focus);
    try std.testing.expectEqual(Phase.long_break, engine.phase);
}

test "long break returns to focus" {
    var engine = Engine.init();
    engine.apply(.start);

    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        engine.tick(engine.config.focus_ms);
        if (i < 3) engine.tick(engine.config.short_break_ms);
    }
    try std.testing.expectEqual(Phase.long_break, engine.phase);

    engine.tick(engine.config.long_break_ms);
    try std.testing.expectEqual(Phase.focus, engine.phase);
}

test "reset clears progress and history" {
    var engine = Engine.init();
    engine.apply(.start);
    engine.tick(engine.config.focus_ms);
    engine.apply(.reset);

    try std.testing.expectEqual(Phase.focus, engine.phase);
    try std.testing.expectEqual(@as(u32, 0), engine.completed_focus);
    try std.testing.expectEqual(@as(u32, 0), engine.history_len);
    try std.testing.expect(!engine.running);
    try std.testing.expectEqual(engine.config.focus_ms, engine.remaining_ms);
}

test "skip advances the phase immediately" {
    var engine = Engine.init();
    engine.apply(.skip);
    try std.testing.expectEqual(Phase.short_break, engine.phase);
    try std.testing.expectEqual(@as(u32, 1), engine.completed_focus);
}

test "a single tick carries overshoot into the next phase" {
    var engine = Engine.init();
    engine.apply(.start);
    engine.tick(engine.config.focus_ms + 1000);

    try std.testing.expectEqual(Phase.short_break, engine.phase);
    try std.testing.expectEqual(engine.config.short_break_ms - 1000, engine.remaining_ms);
}

test "history keeps the most recent sessions" {
    var engine = Engine.init();
    engine.apply(.start);
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        engine.tick(engine.config.focus_ms);
        if (engine.phase != .focus) engine.tick(engine.config.durationFor(engine.phase));
    }
    try std.testing.expectEqual(@as(u32, MAX_HISTORY), engine.history_len);
}

test "mm:ss formatting pads both fields" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("25:00", formatMs(25 * 60 * 1000, &buf));
    try std.testing.expectEqualStrings("05:00", formatMs(5 * 60 * 1000, &buf));
    try std.testing.expectEqualStrings("00:09", formatMs(9000, &buf));
}

test "progress tracks elapsed time" {
    var engine = Engine.init();
    engine.apply(.start);
    engine.tick(engine.config.focus_ms / 2);
    try std.testing.expectEqual(@as(u32, 50), engine.progressPercent());
}
