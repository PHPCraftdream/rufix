//! The part of Go's net/url.Parse that decides whether a variable is a URL
//! and what its host, hostname and password are. Errors follow Go: a value
//! Go rejects is not a URL here either.
const std = @import("std");

pub const Url = struct {
    host: []const u8 = "",
    password: ?[]const u8 = null,

    /// Go URL.Hostname: host without a valid port and without brackets.
    pub fn hostname(u: Url) []const u8 {
        var h = u.host;
        if (std.mem.lastIndexOfScalar(u8, h, ':')) |c| {
            if (validOptionalPort(h[c..])) h = h[0..c];
        }
        if (h.len >= 2 and h[0] == '[' and h[h.len - 1] == ']') h = h[1 .. h.len - 1];
        return h;
    }
};

pub const Error = error{ InvalidUrl, OutOfMemory };

const Mode = enum { path, host, zone, user_password, fragment };

fn isHex(c: u8) bool {
    return std.ascii.isHex(c);
}

fn unhex(c: u8) u8 {
    return std.fmt.charToDigit(c, 16) catch 0;
}

/// shouldEscape for host and zone modes (net/url encoding table).
fn hostShouldEscape(c: u8) bool {
    if (std.ascii.isAlphanumeric(c)) return false;
    return switch (c) {
        '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', ':', '[', ']', '<', '>', '"', '-', '_', '.', '~' => false,
        else => true,
    };
}

fn unescape(a: std.mem.Allocator, s: []const u8, mode: Mode) Error![]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        switch (s[i]) {
            '%' => {
                n += 1;
                if (i + 2 >= s.len or !isHex(s[i + 1]) or !isHex(s[i + 2])) return error.InvalidUrl;
                if (mode == .host and unhex(s[i + 1]) < 8 and !std.mem.eql(u8, s[i .. i + 3], "%25")) return error.InvalidUrl;
                if (mode == .zone) {
                    const v = unhex(s[i + 1]) << 4 | unhex(s[i + 2]);
                    if (!std.mem.eql(u8, s[i .. i + 3], "%25") and v != ' ' and hostShouldEscape(v)) return error.InvalidUrl;
                }
                i += 3;
            },
            else => {
                if ((mode == .host or mode == .zone) and s[i] < 0x80 and hostShouldEscape(s[i])) return error.InvalidUrl;
                i += 1;
            },
        }
    }
    if (n == 0) return s;
    var out: std.ArrayList(u8) = .empty;
    i = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%') {
            try out.append(a, unhex(s[i + 1]) << 4 | unhex(s[i + 2]));
            i += 2;
        } else try out.append(a, s[i]);
    }
    return out.items;
}

fn validOptionalPort(port: []const u8) bool {
    if (port.len == 0) return true;
    if (port[0] != ':') return false;
    for (port[1..]) |b| if (b < '0' or b > '9') return false;
    return true;
}

fn validUserinfo(s: []const u8) bool {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c)) continue;
        switch (c) {
            '-', '.', '_', ':', '~', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', '%', '@' => {},
            else => return false,
        }
    }
    return true;
}

fn parseIpv4(s: []const u8) bool {
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |p| {
        if (p.len == 0 or p.len > 3) return false;
        if (p.len > 1 and p[0] == '0') return false;
        const v = std.fmt.parseInt(u16, p, 10) catch return false;
        if (v > 255) return false;
        parts += 1;
    }
    return parts == 4;
}

/// netip.ParseAddr accepting IPv6 only (with optional zone).
fn validIpv6(s_in: []const u8) bool {
    var s = s_in;
    if (std.mem.indexOfScalar(u8, s, '%')) |z| {
        if (z + 1 >= s.len) return false;
        s = s[0..z];
    }
    if (std.mem.indexOfScalar(u8, s, ':') == null) return false;
    var groups: usize = 0;
    var ellipsis = false;
    var i: usize = 0;
    if (std.mem.startsWith(u8, s, "::")) {
        ellipsis = true;
        i = 2;
        if (s.len == 2) return true;
    } else if (s.len > 0 and s[0] == ':') return false;
    while (i < s.len) {
        // An embedded IPv4 tail counts as two groups.
        const rest = s[i..];
        const next_colon = std.mem.indexOfScalar(u8, rest, ':');
        const field = if (next_colon) |c| rest[0..c] else rest;
        if (next_colon == null and std.mem.indexOfScalar(u8, field, '.') != null) {
            if (!parseIpv4(field)) return false;
            groups += 2;
            i = s.len;
            break;
        }
        if (field.len == 0 or field.len > 4) return false;
        for (field) |c| if (!isHex(c)) return false;
        groups += 1;
        i += field.len;
        if (i == s.len) break;
        i += 1; // ':'
        if (i < s.len and s[i] == ':') {
            if (ellipsis) return false;
            ellipsis = true;
            i += 1;
            if (i == s.len) break;
        } else if (i == s.len) return false;
    }
    if (ellipsis) return groups < 8;
    return groups == 8;
}

fn parseHost(a: std.mem.Allocator, scheme: []const u8, host: []const u8) Error![]const u8 {
    if (std.mem.lastIndexOfScalar(u8, host, '[')) |open| {
        const close = std.mem.lastIndexOfScalar(u8, host, ']') orelse return error.InvalidUrl;
        if (close < open) return error.InvalidUrl;
        const colon_port = host[close + 1 ..];
        if (!validOptionalPort(colon_port)) return error.InvalidUrl;
        const port = try unescape(a, colon_port, .host);
        const name = host[open + 1 .. close];
        var unescaped: []const u8 = undefined;
        if (std.mem.indexOf(u8, name, "%25")) |z| {
            const h = try unescape(a, name[0..z], .host);
            const zone = try unescape(a, name[z..], .zone);
            unescaped = try std.mem.concat(a, u8, &.{ h, zone });
        } else unescaped = try unescape(a, name, .host);
        if (!validIpv6(unescaped)) return error.InvalidUrl;
        return std.mem.concat(a, u8, &.{ "[", unescaped, "]", port });
    }
    if (std.mem.indexOfScalar(u8, host, ':')) |first| {
        var i = first;
        const last = std.mem.lastIndexOfScalar(u8, host, ':').?;
        if (last != first and (std.mem.eql(u8, scheme, "postgresql") or std.mem.eql(u8, scheme, "postgres"))) i = last;
        if (!validOptionalPort(host[i..])) return error.InvalidUrl;
    }
    return unescape(a, host, .host);
}

pub fn parse(a: std.mem.Allocator, raw: []const u8) Error!Url {
    var u = raw;
    var frag: []const u8 = "";
    if (std.mem.indexOfScalar(u8, raw, '#')) |h| {
        u = raw[0..h];
        frag = raw[h + 1 ..];
    }
    var out = Url{};
    for (u) |c| if (c < ' ' or c == 0x7f) return error.InvalidUrl;
    if (!std.mem.eql(u8, u, "*")) {
        // Scheme.
        var scheme: []const u8 = "";
        var rest = u;
        for (u, 0..) |c, i| {
            if (std.ascii.isAlphabetic(c)) continue;
            if (std.ascii.isDigit(c) or c == '+' or c == '-' or c == '.') {
                if (i == 0) break;
                continue;
            }
            if (c == ':') {
                if (i == 0) return error.InvalidUrl;
                scheme = try std.ascii.allocLowerString(a, u[0..i]);
                rest = u[i + 1 ..];
            }
            break;
        }
        if (std.mem.endsWith(u8, rest, "?") and std.mem.count(u8, rest, "?") == 1) {
            rest = rest[0 .. rest.len - 1];
        } else if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
            rest = rest[0..q];
        }
        var opaque_url = false;
        if (!std.mem.startsWith(u8, rest, "/")) {
            if (scheme.len > 0) {
                opaque_url = true;
            } else {
                const seg_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
                if (std.mem.indexOfScalar(u8, rest[0..seg_end], ':') != null) return error.InvalidUrl;
            }
        }
        if (!opaque_url) {
            if ((scheme.len > 0 or !std.mem.startsWith(u8, rest, "///")) and std.mem.startsWith(u8, rest, "//")) {
                var authority = rest[2..];
                rest = "";
                if (std.mem.indexOfScalar(u8, authority, '/')) |sl| {
                    rest = authority[sl..];
                    authority = authority[0..sl];
                }
                const at = std.mem.lastIndexOfScalar(u8, authority, '@');
                out.host = try parseHost(a, scheme, if (at) |x| authority[x + 1 ..] else authority);
                if (at) |x| {
                    const userinfo = authority[0..x];
                    if (!validUserinfo(userinfo)) return error.InvalidUrl;
                    if (std.mem.indexOfScalar(u8, userinfo, ':')) |c| {
                        _ = try unescape(a, userinfo[0..c], .user_password);
                        out.password = try unescape(a, userinfo[c + 1 ..], .user_password);
                    } else _ = try unescape(a, userinfo, .user_password);
                }
            }
            _ = try unescape(a, rest, .path);
        }
    }
    if (frag.len > 0) _ = try unescape(a, frag, .fragment);
    return out;
}
