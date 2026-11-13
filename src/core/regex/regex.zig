//! RE2-syntax regex compiler into vm.Program, matching like Go's regexp.
const parse = @import("parse.zig");
pub const Error = parse.Error;
pub const Compiled = parse.Compiled;
pub const compile = @import("compile.zig").compile;
pub const parseTemplate = @import("template.zig").parseTemplate;
