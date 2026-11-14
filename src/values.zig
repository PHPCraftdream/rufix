//! Committed skeleton of the secret values and filters: ZERO rules and ZERO
//! values, so by default nothing is replaced. Put your real data in
//! secrets/values.zig (same shape; git ignores secrets/), the build uses it
//! when present. Values are compiled into the binary: never distribute it.
//!
//! vars: .{ "NAME", "value" } pairs. Names with TOKEN/SECRET/PASSWORD/PASSWD/
//! PAT/KEY/CREDENTIAL parts protect the whole value (6+ bytes); URL values
//! protect the URL, its host and portless host.
//!
//! rules: build them with the helpers of src/core/rules.zig, `rule.domain`,
//! `rule.import`, `rule.path` and `rule.word`, each taking the real name and
//! what the model sees instead. The commented examples below (fake names) show
//! them; uncomment and adapt them in secrets/values.zig, not here. Anything
//! else is a plain `.{ .name = .., .match = .., .replace = .. }` (see
//! `Rule` there for the optional fields).
//!
//! Style: put a group after a boundary, `\\b(?:word)`. Written without it the
//! `b` and the word fuse into one token and the editor stops highlighting the
//! word when you select it.

const rule = @import("rules");

pub const vars = .{
    // .{ "JIRA_TOKEN", "..." },
    // .{ "JIRA_URL", "https://jira.example.com" },
};

pub const rules = .{
    // *.acme as *.zephyr, host labels and letter case kept; `x.acme.org` stays.
    // rule.domain("acme", "zephyr"),

    // `acme.` as `zephyr.`: the first part of a dotted name, as in an import.
    // rule.import("acme", "zephyr"),

    // `acme/` and `acme\` as `zephyr/` and `zephyr\`: the first folder of a path.
    // rule.path("acme", "zephyr"),

    // The bare word, also glued to `_` (acme_name, name_acme, acme_acme).
    // rule.word("acme", "zephyr"),

    // Anything the helpers do not cover; the match is plain RE2 (Go regexp).
    // .{
    //     .name = "com-to-intra",
    //     .match = "(?i)\\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+)com\\b",
    //     .replace = "${1}intra",
    //     .restore_match = "(?i)\\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+)intra\\b",
    //     .restore_replace = "${1}com",
    //     .allowlist_seed = true,
    //     .preserve_case = true,
    // },
};
