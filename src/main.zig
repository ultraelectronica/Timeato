//! Timeato WASM entry point.
//!
//! Exposes the Zig-owned app to the web shell through a tiny C ABI. The shell
//! only pumps time in and applies the JSON view that Zig hands back.

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
    const event: engine.Event = switch (code) {
        view.Action.toggle => .toggle,
        view.Action.reset => .reset,
        view.Action.skip => .skip,
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
