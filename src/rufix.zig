//! Library root for the tests: every part of rufix by name.
pub const engine = @import("core/engine.zig");
pub const json = @import("core/json.zig");
pub const regex = @import("core/regex/regex.zig");
pub const url = @import("core/url.zig");
pub const vm = @import("core/vm.zig");
pub const hook = @import("hooks/hook.zig");
pub const install = @import("hooks/install.zig");
pub const shell = @import("hooks/shell.zig");
pub const shellinstall = @import("hooks/shellinstall.zig");
pub const envfile = @import("platform/envfile.zig");
pub const io = @import("platform/io.zig");
pub const os = @import("platform/os.zig");
