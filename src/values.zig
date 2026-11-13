//! Committed skeleton of the secret values and filters: ZERO rules and ZERO
//! values, so by default nothing is replaced. Put your real data in
//! secrets/values.zig (same shape; git ignores secrets/), the build uses it
//! when present. Values are compiled into the binary: never distribute it.
//!
//! vars: .{ "NAME", "value" } pairs. Names with TOKEN/SECRET/PASSWORD/PASSWD/
//! PAT/KEY/CREDENTIAL parts protect the whole value (6+ bytes); URL values
//! protect the URL, its host and portless host.
//!
//! rules: filters with the fields of engine.RuleSpec. Example — mask every
//! *.com domain as *.intra and back:
//!
//!     .{
//!         .name = "com-to-intra",
//!         .match = "(?i)\\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+)com\\b",
//!         .replace = "${1}intra",
//!         .restore_match = "(?i)\\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+)intra\\b",
//!         .restore_replace = "${1}com",
//!         .allowlist_seed = true,
//!         .preserve_case = true,
//!     },

pub const vars = .{};

pub const rules = .{};
