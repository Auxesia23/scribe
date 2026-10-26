//! Command semantics for the key-value engine.
//!
//! This module is transport agnostic: it never touches protocol bytes. The RESP
//! codec maps parsed arguments to `Command` values and encodes `Reply` values.
//!
//! `Reply` may borrow bytes from the `Store` or from a parsed command. Callers
//! must encode the reply before the next command runs or before the parsed
//! command is deinitialized.

const Store = @import("store.zig").Store;

/// Parsed expiry option, normalized to milliseconds.
///
/// The RESP codec converts seconds to milliseconds and rejects values that
/// do not fit in an i64 of milliseconds. The engine owns the semantics:
/// only SET rejects non-positive values, and relative deadlines are resolved
/// against the store clock.
pub const Expiry = union(enum) {
    /// Deadline relative to the current time, in milliseconds.
    relative_ms: i64,
    /// Absolute deadline in milliseconds since the Unix epoch.
    absolute_ms: i64,
};

/// Output unit for the TTL-family commands.
pub const TimeUnit = enum { seconds, milliseconds };

pub const Command = union(enum) {
    ping: struct { message: ?[]const u8 = null },
    set: struct {
        key: []const u8,
        value: []const u8,
        /// Expiry option; `null` clears any deadline the key had.
        expire: ?Expiry = null,
    },
    get: struct { key: []const u8 },
    del: struct { keys: []const []const u8 },
    exists: struct { keys: []const []const u8 },
    /// TTL/PTTL: report the remaining time for a key.
    ttl: struct { key: []const u8, unit: TimeUnit },
    /// EXPIRE/PEXPIRE: set an expiry on an existing key.
    expire: struct { key: []const u8, expiry: Expiry },
    /// PERSIST: remove the expiry from a key.
    persist: struct { key: []const u8 },
    /// A protocol-level command error (unknown command, wrong arity, empty).
    invalid: ErrorReply,
};

pub const ErrorReply = union(enum) {
    empty_command,
    unknown_command: []const u8,
    wrong_arity: []const u8,
    /// A SET expiry value is non-positive or overflows (Redis: "invalid
    /// expire time in '...' command").
    invalid_expire: []const u8,
    /// An integer argument is malformed or out of range (Redis: "value is
    /// not an integer or out of range").
    value_not_integer,
    /// A command option is unknown or malformed (Redis: "syntax error").
    syntax_error,
};

pub const Reply = union(enum) {
    pong,
    ok,
    nil,
    bulk: []const u8,
    int: i64,
    err: ErrorReply,
};

pub const Error = error{OutOfMemory};

/// Executes one command.
///
/// Command-level failures are represented as `Reply.err`; only storage
/// failures returned as errors.
pub fn execute(store: *Store, command: Command) Error!Reply {
    return switch (command) {
        .ping => |p| {
            if (p.message) |msg| {
                return .{ .bulk = msg };
            } else return .pong;
        },
        .set => |s| {
            // SET rejects non-positive expiry values outright (Redis:
            // "invalid expire time in 'set' command"); EXPIRE does not, see
            // the `.expire` arm. A positive absolute deadline in the past
            // is accepted and simply expires immediately.
            if (s.expire) |exp| {
                switch (exp) {
                    .relative_ms, .absolute_ms => |ms| {
                        if (ms <= 0) return .{ .err = .{ .invalid_expire = "set" } };
                    },
                }

                const deadline = switch (exp) {
                    // Saturating add: a huge relative value means "far in
                    // the future", not an overflow crash.
                    .relative_ms => |ms| store.clock.nowMs() +| ms,
                    .absolute_ms => |ms| ms,
                };
                try store.setWithOptions(s.key, s.value, .{ .expires_at_ms = deadline });
            } else {
                try store.setWithOptions(s.key, s.value, .{});
            }
            return .ok;
        },
        .get => |g| {
            if (store.get(g.key)) |v| {
                return .{ .bulk = v };
            } else {
                return .nil;
            }
        },
        .del => |d| {
            var count: i64 = 0;
            for (d.keys) |key| {
                if (store.remove(key)) count += 1;
            }
            return .{ .int = count };
        },
        .exists => |e| {
            var count: i64 = 0;
            for (e.keys) |key| {
                if (store.contains(key)) count += 1;
            }
            return .{ .int = count };
        },
        .ttl => |t| switch (store.ttl(t.key)) {
            .key_missing => return .{ .int = -2 },
            .no_expiry => return .{ .int = -1 },
            .remaining_ms => |ms| switch (t.unit) {
                // Redis rounds TTL seconds to the nearest second.
                .seconds => return .{ .int = @divTrunc(ms + 500, 1000) },
                .milliseconds => return .{ .int = ms },
            },
        },
        .expire => |e| {
            // Unlike SET, zero and negative values are accepted here (Redis
            // replies 1 and the key disappears via lazy expiry).
            const deadline = switch (e.expiry) {
                .relative_ms => |ms| store.clock.nowMs() +| ms,
                .absolute_ms => |ms| ms,
            };
            return .{ .int = if (store.expire(e.key, deadline)) 1 else 0 };
        },
        .persist => |p| {
            return .{ .int = if (store.persist(p.key)) 1 else 0 };
        },
        .invalid => |err| {
            return .{ .err = err };
        },
    };
}
