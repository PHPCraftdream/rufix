//! zig build test: every suite.
test {
    _ = @import("core.zig");
    _ = @import("hook.zig");
    _ = @import("install.zig");
    _ = @import("cli.zig");
    _ = @import("lint.zig");
}
