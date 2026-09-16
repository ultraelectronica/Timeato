//! Native demo: drives the same engine/view the Android shell uses and prints
//! the JSON the shell would receive. Handy for eyeballing the view natively.

const std = @import("std");
const engine = @import("engine.zig");
const view = @import("view.zig");

pub fn main() void {
    var app = engine.Engine.init();
    app.apply(.start);
    app.tick(app.config.focus_ms); // finish one focus block
    app.tick(60 * 1000); // one minute into the break
    app.apply(.pause);

    var buf: [view.MAX_JSON]u8 = undefined;
    const json = view.renderJson(&app, &buf);
    std.debug.print("{s}\n", .{json});
}
