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

    pub fn setDurationFor(self: *Config, phase: Phase, ms: u32) void {
        switch (phase) {
            .focus => self.focus_ms = ms,
            .short_break => self.short_break_ms = ms,
            .long_break => self.long_break_ms = ms,
        }
    }
};

/// Duration editor bounds. Every phase is capped at three hours, matching the
/// measuring-tape picker's minutes strip (0-180).
pub const MAX_DURATION_MS: u32 = 3 * 60 * 60 * 1000;
pub const MAX_MINUTES: u32 = 180;
pub const MIN_DURATION_MS: u32 = 1000;
pub const PHASE_COUNT: u32 = 3;

pub fn phaseIndex(phase: Phase) u32 {
    return @intFromEnum(phase);
}

pub fn phaseFromIndex(i: u32) Phase {
    return switch (i) {
        1 => .short_break,
        2 => .long_break,
        else => .focus,
    };
}

pub const Event = union(enum) {
    start,
    pause,
    toggle,
    reset,
    skip,
    tick: u32,
    open_settings,
    close_settings,
    select_alarm: u32,
    open_duration,
    duration_cancel,
    duration_done,
    select_duration_phase: u32,
    set_minutes: u32,
    set_seconds: u32,
};

/// How the current phase was last interrupted. Lets the view choose copy
/// without guessing from a phase that reset/skip already refilled.
pub const Interrupt = enum(u8) {
    none,
    paused,
    reset,
    skipped,
};

pub const MAX_HISTORY = 6;

/// Alarm tones bundled under `android/app/src/main/res/raw/` (AOSP material
/// alarms, Apache 2.0 - see alarm_sounds_notice.txt). Index 0 is the default.
/// The Java shell must keep its res-id table in this exact order.
pub const ALARM_COUNT: u32 = 6;
pub const DEFAULT_ALARM: u32 = 0;

pub fn alarmName(i: u32) []const u8 {
    return switch (i) {
        0 => "Helium",
        1 => "Argon",
        2 => "Carbon",
        3 => "Krypton",
        4 => "Neon",
        else => "Oxygen",
    };
}

pub fn alarmKey(i: u32) []const u8 {
    return switch (i) {
        0 => "helium",
        1 => "argon",
        2 => "carbon",
        3 => "krypton",
        4 => "neon",
        else => "oxygen",
    };
}

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
    /// Selected alarm tone index (see ALARM_COUNT/alarmName). Survives reset.
    alarm_sound: u32 = DEFAULT_ALARM,
    /// Bumped on every automatic phase completion (tick-driven advance only,
    /// never on manual skip). The shell watches it to fire the alarm sound.
    alarm_seq: u32 = 0,
    settings_open: bool = false,
    /// Duration editor. Staged per-phase values are edited here and only copied
    /// into `config` on `duration_done`; `duration_cancel` throws them away.
    duration_open: bool = false,
    duration_phase: Phase = .focus,
    edit_minutes: [PHASE_COUNT]u32 = .{ 25, 5, 15 },
    edit_seconds: [PHASE_COUNT]u32 = .{ 0, 0, 0 },
    /// Last way the phase was interrupted, plus the phase and progress it was
    /// at when that happened (0-100). Cleared on start and natural completion.
    last_interrupt: Interrupt = .none,
    interrupt_phase: Phase = .focus,
    interrupt_progress: u32 = 0,

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
            .start => {
                self.running = true;
                self.last_interrupt = .none;
            },
            .pause => {
                self.running = false;
                self.recordInterrupt(.paused);
            },
            .toggle => {
                if (self.running) {
                    self.running = false;
                    self.recordInterrupt(.paused);
                } else {
                    self.running = true;
                    self.last_interrupt = .none;
                }
            },
            .reset => {
                self.recordInterrupt(.reset);
                self.reset();
            },
            .skip => {
                // Skipping is a stop, not an auto-advance: the next phase waits
                // paused so the view can acknowledge the skip.
                self.recordInterrupt(.skipped);
                self.running = false;
                self.advance();
            },
            .tick => |delta_ms| self.tick(delta_ms),
            .open_settings => self.settings_open = true,
            .close_settings => self.settings_open = false,
            .select_alarm => |i| self.alarm_sound = @min(i, ALARM_COUNT - 1),
            .open_duration => self.openDuration(),
            .duration_cancel => self.duration_open = false,
            .duration_done => self.commitDuration(),
            .select_duration_phase => |i| {
                if (self.duration_open) self.duration_phase = phaseFromIndex(i);
            },
            .set_minutes => |v| self.setEdit(true, v),
            .set_seconds => |v| self.setEdit(false, v),
        }
    }

    // --- duration editor ------------------------------------------------

    /// Open the editor only when nothing is counting: it is a setup screen, and
    /// applying it mid-focus would silently rewrite a running session.
    fn openDuration(self: *Engine) void {
        if (self.running or self.settings_open) return;
        self.duration_open = true;
        self.duration_phase = self.phase;
        var i: u32 = 0;
        while (i < PHASE_COUNT) : (i += 1) {
            const ms = self.config.durationFor(phaseFromIndex(i));
            self.edit_minutes[i] = ms / 60000;
            self.edit_seconds[i] = (ms / 1000) % 60;
        }
    }

    fn setEdit(self: *Engine, is_minutes: bool, value: u32) void {
        if (!self.duration_open) return;
        const i = phaseIndex(self.duration_phase);
        if (is_minutes) {
            self.edit_minutes[i] = @min(value, MAX_MINUTES);
        } else {
            self.edit_seconds[i] = @min(value, 59);
        }
        self.clampStaged(i);
    }

    /// A minute cap of 180 leaves no room for seconds on that last minute, so
    /// anything past three hours collapses back to exactly 3:00:00.
    fn clampStaged(self: *Engine, i: u32) void {
        const total = self.edit_minutes[i] * 60 + self.edit_seconds[i];
        if (total > MAX_MINUTES * 60) {
            self.edit_minutes[i] = MAX_MINUTES;
            self.edit_seconds[i] = 0;
        }
    }

    fn stagedMs(self: *const Engine, i: u32) u32 {
        return self.edit_minutes[i] * 60000 + self.edit_seconds[i] * 1000;
    }

    pub fn editMinutes(self: *const Engine, phase: Phase) u32 {
        return self.edit_minutes[phaseIndex(phase)];
    }

    pub fn editSeconds(self: *const Engine, phase: Phase) u32 {
        return self.edit_seconds[phaseIndex(phase)];
    }

    pub fn editTotalMs(self: *const Engine, phase: Phase) u32 {
        return self.stagedMs(phaseIndex(phase));
    }

    /// Copy staged durations into the live config. If the timer was sitting
    /// idle at the top of the current phase, refill it with the new length so
    /// the clock immediately shows what was just set.
    fn commitDuration(self: *Engine) void {
        if (!self.duration_open) return;
        const was_ready = !self.running and self.remaining_ms >= self.durationMs();

        self.config.focus_ms = self.stagedMs(0);
        self.config.short_break_ms = self.stagedMs(1);
        self.config.long_break_ms = self.stagedMs(2);
        self.duration_open = false;

        if (was_ready) self.remaining_ms = self.durationMs();
    }

    /// Restore a persisted duration (called by the shell at startup).
    pub fn setDurationMs(self: *Engine, phase: Phase, ms: u32) void {
        const clamped = @min(ms, MAX_DURATION_MS);
        const was_ready = !self.running and self.phase == phase and
            self.remaining_ms >= self.config.durationFor(phase);
        self.config.setDurationFor(phase, clamped);
        if (was_ready) self.remaining_ms = clamped;
    }

    fn recordInterrupt(self: *Engine, kind: Interrupt) void {
        self.last_interrupt = kind;
        self.interrupt_phase = self.phase;
        self.interrupt_progress = self.progressPercent();
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
            self.alarm_seq +%= 1;
            self.last_interrupt = .none;
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
    const hours = total / 3600;
    const minutes = (total % 3600) / 60;
    const seconds = total % 60;
    if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ hours, minutes, seconds }) catch buf[0..0];
    }
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ minutes, seconds }) catch buf[0..0];
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

test "automatic completion bumps the alarm, manual skip does not" {
    var engine = Engine.init();
    engine.apply(.start);
    try std.testing.expectEqual(@as(u32, 0), engine.alarm_seq);
    engine.tick(engine.config.focus_ms);
    try std.testing.expectEqual(@as(u32, 1), engine.alarm_seq);
    engine.apply(.skip);
    try std.testing.expectEqual(@as(u32, 1), engine.alarm_seq);
    try std.testing.expectEqual(Phase.focus, engine.phase);
}

test "alarm selection clamps to the bundled tones" {
    var engine = Engine.init();
    try std.testing.expectEqual(DEFAULT_ALARM, engine.alarm_sound);
    engine.apply(.{ .select_alarm = 4 });
    try std.testing.expectEqual(@as(u32, 4), engine.alarm_sound);
    try std.testing.expectEqualStrings("Neon", alarmName(engine.alarm_sound));
    engine.apply(.{ .select_alarm = 99 });
    try std.testing.expectEqual(ALARM_COUNT - 1, engine.alarm_sound);
}

test "settings open and close" {
    var engine = Engine.init();
    try std.testing.expect(!engine.settings_open);
    engine.apply(.open_settings);
    try std.testing.expect(engine.settings_open);
    engine.apply(.close_settings);
    try std.testing.expect(!engine.settings_open);
}

test "reset keeps the alarm choice" {
    var engine = Engine.init();
    engine.apply(.{ .select_alarm = 2 });
    engine.apply(.start);
    engine.tick(engine.config.focus_ms);
    engine.apply(.reset);
    try std.testing.expectEqual(@as(u32, 2), engine.alarm_sound);
}

test "pause records where the timer stopped" {
    var engine = Engine.init();
    engine.apply(.start);
    engine.tick(engine.config.focus_ms / 2);
    engine.apply(.toggle);

    try std.testing.expectEqual(Interrupt.paused, engine.last_interrupt);
    try std.testing.expectEqual(@as(u32, 50), engine.interrupt_progress);
}

test "reset records the progress it threw away" {
    var engine = Engine.init();
    engine.apply(.start);
    engine.tick(engine.config.focus_ms / 4);
    engine.apply(.reset);

    try std.testing.expectEqual(Interrupt.reset, engine.last_interrupt);
    try std.testing.expectEqual(@as(u32, 25), engine.interrupt_progress);
    try std.testing.expectEqual(@as(u32, 0), engine.progressPercent());
}

test "skip records the progress it skipped" {
    var engine = Engine.init();
    engine.apply(.start);
    engine.tick(engine.config.focus_ms - 1000);
    engine.apply(.skip);

    try std.testing.expectEqual(Interrupt.skipped, engine.last_interrupt);
    try std.testing.expectEqual(Phase.focus, engine.interrupt_phase);
    try std.testing.expect(engine.interrupt_progress >= 99);
    try std.testing.expectEqual(Phase.short_break, engine.phase);
}

test "skipping a break records the break as the interrupted phase" {
    var engine = Engine.init();
    engine.apply(.start);
    engine.tick(engine.config.focus_ms); // into a short break
    engine.tick(engine.config.short_break_ms / 2);
    engine.apply(.skip);

    try std.testing.expectEqual(Interrupt.skipped, engine.last_interrupt);
    try std.testing.expectEqual(Phase.short_break, engine.interrupt_phase);
    try std.testing.expectEqual(Phase.focus, engine.phase);
}

test "starting clears the interruption" {
    var engine = Engine.init();
    engine.apply(.start);
    engine.tick(engine.config.focus_ms / 2);
    engine.apply(.pause);
    try std.testing.expectEqual(Interrupt.paused, engine.last_interrupt);

    engine.apply(.start);
    try std.testing.expectEqual(Interrupt.none, engine.last_interrupt);
}

test "natural completion clears the interruption" {
    var engine = Engine.init();
    engine.apply(.start);
    engine.tick(engine.config.focus_ms / 2);
    engine.apply(.pause);
    engine.apply(.start);
    engine.tick(engine.config.focus_ms / 2);

    try std.testing.expectEqual(Interrupt.none, engine.last_interrupt);
    try std.testing.expectEqual(Phase.short_break, engine.phase);
}

test "hour format drops the hour field until it is needed" {
    var buf: [12]u8 = undefined;
    try std.testing.expectEqualStrings("25:00", formatMs(25 * 60 * 1000, &buf));
    try std.testing.expectEqualStrings("59:59", formatMs(59 * 60 * 1000 + 59 * 1000, &buf));
    try std.testing.expectEqualStrings("1:00:00", formatMs(60 * 60 * 1000, &buf));
    try std.testing.expectEqualStrings("1:05:30", formatMs(65 * 60 * 1000 + 30 * 1000, &buf));
    try std.testing.expectEqualStrings("3:00:00", formatMs(MAX_DURATION_MS, &buf));
}

test "duration editor opens staged from config and closes on done" {
    var engine = Engine.init();
    engine.apply(.open_duration);
    try std.testing.expect(engine.duration_open);
    try std.testing.expectEqual(Phase.focus, engine.duration_phase);
    try std.testing.expectEqual(@as(u32, 25), engine.editMinutes(.focus));
    try std.testing.expectEqual(@as(u32, 5), engine.editMinutes(.short_break));
    try std.testing.expectEqual(@as(u32, 15), engine.editMinutes(.long_break));

    engine.apply(.duration_done);
    try std.testing.expect(!engine.duration_open);
}

test "duration editor ignores a running timer" {
    var engine = Engine.init();
    engine.apply(.start);
    engine.apply(.open_duration);
    try std.testing.expect(!engine.duration_open);
}

test "minute edits clamp to three hours" {
    var engine = Engine.init();
    engine.apply(.open_duration);
    engine.apply(.{ .set_minutes = 999 });
    try std.testing.expectEqual(MAX_MINUTES, engine.editMinutes(.focus));
    try std.testing.expectEqual(@as(u32, 0), engine.editSeconds(.focus));

    // A second past the last minute has nowhere to go.
    engine.apply(.{ .set_seconds = 30 });
    try std.testing.expectEqual(MAX_MINUTES, engine.editMinutes(.focus));
    try std.testing.expectEqual(@as(u32, 0), engine.editSeconds(.focus));
}

test "seconds clamp independently below the cap" {
    var engine = Engine.init();
    engine.apply(.open_duration);
    engine.apply(.{ .set_seconds = 99 });
    try std.testing.expectEqual(@as(u32, 59), engine.editSeconds(.focus));
    engine.apply(.{ .set_minutes = 179 });
    try std.testing.expectEqual(@as(u32, 179), engine.editMinutes(.focus));
    try std.testing.expectEqual(@as(u32, 59), engine.editSeconds(.focus));
}

test "each phase keeps its own staged values" {
    var engine = Engine.init();
    engine.apply(.open_duration);
    engine.apply(.{ .select_duration_phase = 1 });
    engine.apply(.{ .set_minutes = 8 });
    engine.apply(.{ .select_duration_phase = 2 });
    engine.apply(.{ .set_minutes = 30 });

    try std.testing.expectEqual(@as(u32, 8), engine.editMinutes(.short_break));
    try std.testing.expectEqual(@as(u32, 30), engine.editMinutes(.long_break));
    // focus untouched
    try std.testing.expectEqual(@as(u32, 25), engine.editMinutes(.focus));
}

test "done applies every staged duration" {
    var engine = Engine.init();
    engine.apply(.open_duration);
    engine.apply(.{ .set_minutes = 90 });
    engine.apply(.{ .select_duration_phase = 1 });
    engine.apply(.{ .set_minutes = 3 });
    engine.apply(.{ .set_seconds = 20 });
    engine.apply(.duration_done);

    try std.testing.expectEqual(@as(u32, 90 * 60000), engine.config.focus_ms);
    try std.testing.expectEqual(@as(u32, 3 * 60000 + 20 * 1000), engine.config.short_break_ms);
    // idle at the top of focus: the clock refills to the new length
    try std.testing.expectEqual(@as(u32, 90 * 60000), engine.remaining_ms);
}

test "done leaves a paused session's progress alone" {
    var engine = Engine.init();
    engine.apply(.start);
    engine.tick(engine.config.focus_ms / 2);
    engine.apply(.pause);

    engine.apply(.open_duration);
    engine.apply(.{ .set_minutes = 50 });
    engine.apply(.duration_done);

    try std.testing.expectEqual(@as(u32, 50 * 60000), engine.config.focus_ms);
    try std.testing.expectEqual(@as(u32, 25 * 60000 / 2), engine.remaining_ms);
    try std.testing.expect(!engine.running);
}

test "cancel throws staged edits away" {
    var engine = Engine.init();
    engine.apply(.open_duration);
    engine.apply(.{ .set_minutes = 90 });
    engine.apply(.duration_cancel);

    try std.testing.expect(!engine.duration_open);
    try std.testing.expectEqual(@as(u32, 25 * 60000), engine.config.focus_ms);
    try std.testing.expectEqual(@as(u32, 25 * 60 * 1000), engine.remaining_ms);
}

test "custom durations survive a reset" {
    var engine = Engine.init();
    engine.apply(.open_duration);
    engine.apply(.{ .set_minutes = 40 });
    engine.apply(.duration_done);
    engine.apply(.start);
    engine.tick(1000);
    engine.apply(.reset);

    try std.testing.expectEqual(@as(u32, 40 * 60000), engine.config.focus_ms);
    try std.testing.expectEqual(@as(u32, 40 * 60000), engine.remaining_ms);
}

test "persisted durations restore and refill the idle clock" {
    var engine = Engine.init();
    engine.setDurationMs(.focus, 2 * 60 * 60 * 1000);
    try std.testing.expectEqual(@as(u32, 2 * 60 * 60 * 1000), engine.config.focus_ms);
    try std.testing.expectEqual(@as(u32, 2 * 60 * 60 * 1000), engine.remaining_ms);

    engine.setDurationMs(.short_break, 999 * 60 * 1000);
    try std.testing.expectEqual(MAX_DURATION_MS, engine.config.short_break_ms);
}
