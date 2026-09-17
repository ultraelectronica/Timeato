//! Timeato core entry point.
//!
//! Exposes the Zig-owned app to the Android shell through a tiny C ABI. The
//! shell only pumps time in and applies the JSON view that Zig hands back.

const engine = @import("engine.zig");
const view = @import("view.zig");

var app: engine.Engine = engine.Engine.init();
var view_buf: [view.MAX_JSON]u8 = undefined;
var view_len: usize = 0;

pub export fn timeato_init() void {
    app = engine.Engine.init();
    view_len = 0;
}

/// Dispatch a control event. Codes match `view.Action`.
pub export fn timeato_dispatch(code: u32) void {
    if (code >= view.Action.sound_base and code < view.Action.sound_base + engine.ALARM_COUNT) {
        app.apply(.{ .select_alarm = code - view.Action.sound_base });
        return;
    }
    if (code >= view.Action.duration_phase_base and
        code < view.Action.duration_phase_base + engine.PHASE_COUNT)
    {
        app.apply(.{ .select_duration_phase = code - view.Action.duration_phase_base });
        return;
    }
    if (code >= view.Action.minute_base and code <= view.Action.minute_base + engine.MAX_MINUTES) {
        app.apply(.{ .set_minutes = code - view.Action.minute_base });
        return;
    }
    if (code >= view.Action.second_base and code < view.Action.second_base + 60) {
        app.apply(.{ .set_seconds = code - view.Action.second_base });
        return;
    }
    const event: engine.Event = switch (code) {
        view.Action.toggle => .toggle,
        view.Action.reset => .reset,
        view.Action.skip => .skip,
        view.Action.settings => .open_settings,
        view.Action.back => .close_settings,
        view.Action.edit_duration => .open_duration,
        view.Action.duration_cancel => .duration_cancel,
        view.Action.duration_done => .duration_done,
        else => return,
    };
    app.apply(event);
}

/// Advance the clock. The shell owns wall time and reports deltas.
pub export fn timeato_tick(delta_ms: u32) void {
    app.apply(.{ .tick = delta_ms });
}

/// Render the view. The buffer is NUL-terminated so native shells can hand the
/// same bytes straight to, for example, JNI's NewStringUTF.
pub export fn timeato_render() [*]const u8 {
    view_len = view.renderJson(&app, &view_buf).len;
    if (view_len < view.MAX_JSON) view_buf[view_len] = 0;
    return &view_buf;
}

pub export fn timeato_render_len() usize {
    return view_len;
}

// Scalars for quick inspection and native shells.

pub export fn timeato_running() u32 {
    return if (app.running) 1 else 0;
}

pub export fn timeato_phase() u32 {
    return @intFromEnum(app.phase);
}

pub export fn timeato_remaining_ms() u32 {
    return app.remaining_ms;
}

pub export fn timeato_completed() u32 {
    return app.completed_focus;
}

pub export fn timeato_progress() u32 {
    return app.progressPercent();
}

/// Restore a persisted alarm choice (e.g. from the shell's preferences).
/// Out-of-range ids clamp to the last bundled tone.
pub export fn timeato_set_alarm(id: u32) void {
    app.apply(.{ .select_alarm = id });
}

pub export fn timeato_alarm() u32 {
    return app.alarm_sound;
}

/// Restore a persisted phase duration (focus/short/long by index). Clamps to
/// three hours and refills the idle clock when the current phase is affected.
pub export fn timeato_set_phase_duration(phase: u32, ms: u32) void {
    app.setDurationMs(engine.phaseFromIndex(phase), ms);
}

/// Current duration of a phase, by index (for the shell to persist).
pub export fn timeato_phase_duration(phase: u32) u32 {
    return app.config.durationFor(engine.phaseFromIndex(phase));
}
