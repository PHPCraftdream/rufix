//! A filter as written in values.zig, and the helpers that build the usual
//! ones: a domain, an import, a path and a word, each as a pair `from` (the
//! real name) and `to` (what the model sees). Every helper makes one reversible
//! rule that keeps the letter case and marks its masks as protected-host
//! evidence (`allowlist_seed`). This file is a module of its own ("rules"), so
//! values.zig can import it; it depends on the standard library only.
//!
//! The patterns are written once, as lists of pieces (`Spec`). `build` renders
//! them at compile time, for values.zig; `expand` renders the same pieces at
//! run time, which is how conformance/rules drives them with fixture data.
const std = @import("std");

pub const Rule = struct {
    name: []const u8,
    match: []const u8,
    replace: []const u8,
    restore_match: []const u8 = "",
    restore_replace: []const u8 = "",
    allowlist_seed: bool = false,
    strict_tld: bool = false,
    preserve_case: bool = false,
    /// Apply the rule again while it still changes the text: a match that
    /// consumes a delimiter (`_` in `x_x`) otherwise hides the next one.
    until_stable: bool = false,
};

pub const Kind = enum { domain, import, path, word };

/// Where a name goes in a pattern: as written, or as regex text (a dot is
/// escaped).
const Slot = enum { none, from, to, from_re, to_re };

/// Fixed text, or a name in a slot.
const Piece = struct { text: []const u8 = "", slot: Slot = .none };

fn lit(text: []const u8) Piece {
    return .{ .text = text };
}

const F: Piece = .{ .slot = .from };
const T: Piece = .{ .slot = .to };
const F_RE: Piece = .{ .slot = .from_re };
const T_RE: Piece = .{ .slot = .to_re };

const Spec = struct {
    /// The rule's name is this text followed by `from`.
    label: []const u8,
    match: []const Piece,
    replace: []const Piece,
    restore_match: []const Piece,
    restore_replace: []const Piece,
    strict_tld: bool = false,
    until_stable: bool = false,
};

const labels = lit("((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+)");

/// `*.from` as `*.to`: a host name whose last label is `from`; `a.from.org`
/// is left alone (`strict_tld`).
const domain_spec = Spec{
    .label = "domain ",
    .match = &[_]Piece{ lit("(?i)\\b"), labels, F_RE, lit("\\b") },
    .replace = &[_]Piece{ lit("${1}"), T },
    .restore_match = &[_]Piece{ lit("(?i)\\b"), labels, T_RE, lit("\\b") },
    .restore_replace = &[_]Piece{ lit("${1}"), F },
    .strict_tld = true,
};

/// `from.` as `to.`: the first part of a dotted name, such as a package in an
/// import.
const import_spec = Spec{
    .label = "import ",
    .match = &[_]Piece{ lit("(?i)\\b(?:"), F_RE, lit(")\\.") },
    .replace = &[_]Piece{ T, lit(".") },
    .restore_match = &[_]Piece{ lit("(?i)\\b(?:"), T_RE, lit(")\\.") },
    .restore_replace = &[_]Piece{ F, lit(".") },
};

/// `from/` and `from\` as `to/` and `to\`: the first folder of a path.
const path_spec = Spec{
    .label = "path ",
    .match = &[_]Piece{ lit("(?i)\\b(?:"), F_RE, lit(")([\\\\/])") },
    .replace = &[_]Piece{ T, lit("${1}") },
    .restore_match = &[_]Piece{ lit("(?i)\\b(?:"), T_RE, lit(")([\\\\/])") },
    .restore_replace = &[_]Piece{ F, lit("${1}") },
};

/// `from` as `to` where it stands alone, or is glued to `_` (`from_x`,
/// `x_from`, `from_from`). A match consumes the `_` the next one needs, so the
/// rule runs `until_stable`.
const word_spec = Spec{
    .label = "word ",
    .match = &[_]Piece{ lit("(?i)(?:\\b|(_))"), F_RE, lit("(?:\\b|(_))") },
    .replace = &[_]Piece{ lit("${1}"), T, lit("${2}") },
    .restore_match = &[_]Piece{ lit("(?i)(?:\\b|(_))"), T_RE, lit("(?:\\b|(_))") },
    .restore_replace = &[_]Piece{ lit("${1}"), F, lit("${2}") },
    .until_stable = true,
};

fn spec(kind: Kind) *const Spec {
    return switch (kind) {
        .domain => &domain_spec,
        .import => &import_spec,
        .path => &path_spec,
        .word => &word_spec,
    };
}

/// Names are ASCII letters, digits, `_`, `-` and `.`: anything else could mean
/// more (or less) in a pattern than it says. Non-ASCII text is refused rather
/// than accepted, because `\b` is an ASCII boundary: a rule around a Cyrillic
/// word would compile and then silently never match.
fn validName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
            else => return false,
        }
    }
    return true;
}

// ---------- compile time: values.zig ----------

fn quote(comptime s: []const u8) []const u8 {
    if (!validName(s)) @compileError("rufix rules: a name must be non-empty and hold only ASCII letters, digits, _ - and . (write a plain rule for anything else): " ++ s);
    comptime var out: []const u8 = "";
    inline for (s) |c| {
        const piece: []const u8 = if (c == '.') "\\." else &[_]u8{c};
        out = out ++ piece;
    }
    return out;
}

fn render(comptime pieces: []const Piece, comptime from: []const u8, comptime to: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    inline for (pieces) |p| {
        const text: []const u8 = switch (p.slot) {
            .none => p.text,
            .from => from,
            .to => to,
            .from_re => quote(from),
            .to_re => quote(to),
        };
        out = out ++ text;
    }
    return out;
}

pub fn build(comptime kind: Kind, comptime from: []const u8, comptime to: []const u8) Rule {
    const s = comptime spec(kind);
    return .{
        .name = comptime s.label ++ from,
        .match = comptime render(s.match, from, to),
        .replace = comptime render(s.replace, from, to),
        .restore_match = comptime render(s.restore_match, from, to),
        .restore_replace = comptime render(s.restore_replace, from, to),
        .allowlist_seed = true,
        .strict_tld = s.strict_tld,
        .preserve_case = true,
        .until_stable = s.until_stable,
    };
}

pub fn domain(comptime from: []const u8, comptime to: []const u8) Rule {
    return build(.domain, from, to);
}

pub fn import(comptime from: []const u8, comptime to: []const u8) Rule {
    return build(.import, from, to);
}

pub fn path(comptime from: []const u8, comptime to: []const u8) Rule {
    return build(.path, from, to);
}

pub fn word(comptime from: []const u8, comptime to: []const u8) Rule {
    return build(.word, from, to);
}

// ---------- run time: fixtures ----------

fn renderAlloc(a: std.mem.Allocator, pieces: []const Piece, from: []const u8, to: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (pieces) |p| {
        switch (p.slot) {
            .none => try out.appendSlice(a, p.text),
            .from => try out.appendSlice(a, from),
            .to => try out.appendSlice(a, to),
            .from_re => try appendQuoted(a, &out, from),
            .to_re => try appendQuoted(a, &out, to),
        }
    }
    return out.items;
}

fn appendQuoted(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        if (c == '.') try out.appendSlice(a, "\\.") else try out.append(a, c);
    }
}

/// What `build` makes, for names known only at run time. A name the helpers
/// do not accept is `error.InvalidName`.
pub fn expand(a: std.mem.Allocator, kind: Kind, from: []const u8, to: []const u8) !Rule {
    if (!validName(from) or !validName(to)) return error.InvalidName;
    const s = spec(kind);
    return .{
        .name = try std.mem.concat(a, u8, &.{ s.label, from }),
        .match = try renderAlloc(a, s.match, from, to),
        .replace = try renderAlloc(a, s.replace, from, to),
        .restore_match = try renderAlloc(a, s.restore_match, from, to),
        .restore_replace = try renderAlloc(a, s.restore_replace, from, to),
        .allowlist_seed = true,
        .strict_tld = s.strict_tld,
        .preserve_case = true,
        .until_stable = s.until_stable,
    };
}
