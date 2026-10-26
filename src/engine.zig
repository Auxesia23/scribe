//! Command semantics for the key-value engine.
//!
//! This module is transport agnostic: it never touches protocol bytes. The RESP
//! codec maps parsed arguments to `Command` values and encodes `Reply` values.
//!
//! `Reply` may borrow bytes from the `Store` or from a parsed command. Callers
//! must encode the reply before the next command runs or before the parsed
//! command is deinitialized.

const Store = @import("store.zig").Store;

pub const Command = union(enum) {
    ping: struct { message: ?[]const u8 = null },
    set: struct { key: []const u8, value: []const u8 },
    get: struct { key: []const u8 },
    del: struct { keys: []const []const u8 },
    exists: struct { keys: []const []const u8 },
    /// A protocol-level command error (unknown command, wrong arity, empty).
    invalid: ErrorReply,
};

pub const ErrorReply = union(enum) {
    empty_command,
    unknown_command: []const u8,
    wrong_arity: []const u8,
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
            try store.set(s.key, s.value);
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
        .invalid => |err| {
            return .{ .err = err };
        },
    };
}
