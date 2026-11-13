//! rufix executable entry point; the commands live in cli/commands.zig.
const commands = @import("cli/commands.zig");

pub export fn main(argc: c_int, argv: [*][*:0]u8) c_int {
    return commands.main(argc, argv);
}
