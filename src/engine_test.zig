//! P2 spec: engine semantics, independent of RESP bytes.
//!
//! These tests construct `engine.Command` values directly. The RESP codec is
//! tested separately in `resp_test.zig`.

const std = @import("std");
const engine = @import("engine.zig");
const Store = @import("store.zig").Store;

const testing = std.testing;

fn expectOk(reply: engine.Reply) !void {
    switch (reply) {
        .ok => {},
        else => return error.ExpectedOk,
    }
}

fn expectPong(reply: engine.Reply) !void {
    switch (reply) {
        .pong => {},
        else => return error.ExpectedPong,
    }
}

fn expectNil(reply: engine.Reply) !void {
    switch (reply) {
        .nil => {},
        else => return error.ExpectedNil,
    }
}

fn expectBulk(reply: engine.Reply, expected: []const u8) !void {
    switch (reply) {
        .bulk => |actual| try testing.expectEqualStrings(expected, actual),
        else => return error.ExpectedBulk,
    }
}

fn expectInt(reply: engine.Reply, expected: i64) !void {
    switch (reply) {
        .int => |actual| try testing.expectEqual(expected, actual),
        else => return error.ExpectedInt,
    }
}

fn expectErr(reply: engine.Reply, expected: engine.ErrorReply) !void {
    switch (reply) {
        .err => |actual| try expectErrorReply(actual, expected),
        else => return error.ExpectedErrorReply,
    }
}

fn expectErrorReply(actual: engine.ErrorReply, expected: engine.ErrorReply) !void {
    switch (expected) {
        .empty_command => switch (actual) {
            .empty_command => {},
            else => return error.ErrorReplyMismatch,
        },
        .unknown_command => |name| switch (actual) {
            .unknown_command => |actual_name| try testing.expectEqualStrings(name, actual_name),
            else => return error.ErrorReplyMismatch,
        },
        .wrong_arity => |name| switch (actual) {
            .wrong_arity => |actual_name| try testing.expectEqualStrings(name, actual_name),
            else => return error.ErrorReplyMismatch,
        },
    }
}

fn newStore() Store {
    return Store.init(testing.allocator);
}

test "PING without message returns pong" {
    var store = newStore();
    defer store.deinit();

    const reply = try engine.execute(&store, .{ .ping = .{} });
    try expectPong(reply);
}

test "PING with message echoes it as a bulk string" {
    var store = newStore();
    defer store.deinit();

    const reply = try engine.execute(&store, .{ .ping = .{ .message = "hello" } });
    try expectBulk(reply, "hello");
}

test "SET stores the key and value and returns ok" {
    var store = newStore();
    defer store.deinit();

    const reply = try engine.execute(&store, .{ .set = .{ .key = "name", .value = "john" } });
    try expectOk(reply);

    const stored = store.get("name") orelse return error.MissingKey;
    try testing.expectEqualStrings("john", stored);
}

test "SET is binary-safe" {
    var store = newStore();
    defer store.deinit();

    const value = "\x00ab\r\n\xff";
    const reply = try engine.execute(&store, .{ .set = .{ .key = "bin", .value = value } });
    try expectOk(reply);

    const stored = store.get("bin") orelse return error.MissingKey;
    try testing.expectEqualSlices(u8, value, stored);
}

test "GET returns the stored value" {
    var store = newStore();
    defer store.deinit();

    try expectOk(try engine.execute(&store, .{ .set = .{ .key = "name", .value = "john" } }));

    const reply = try engine.execute(&store, .{ .get = .{ .key = "name" } });
    try expectBulk(reply, "john");
}

test "GET missing key returns nil" {
    var store = newStore();
    defer store.deinit();

    const reply = try engine.execute(&store, .{ .get = .{ .key = "missing" } });
    try expectNil(reply);
}

test "SET overwrite is visible to GET" {
    var store = newStore();
    defer store.deinit();

    try expectOk(try engine.execute(&store, .{ .set = .{ .key = "k", .value = "v1" } }));
    try expectOk(try engine.execute(&store, .{ .set = .{ .key = "k", .value = "longer-value" } }));

    const reply = try engine.execute(&store, .{ .get = .{ .key = "k" } });
    try expectBulk(reply, "longer-value");
}

test "DEL removes only existing keys and returns the count" {
    var store = newStore();
    defer store.deinit();

    try expectOk(try engine.execute(&store, .{ .set = .{ .key = "a", .value = "1" } }));
    try expectOk(try engine.execute(&store, .{ .set = .{ .key = "b", .value = "2" } }));

    const keys = [_][]const u8{ "a", "missing", "b" };
    const reply = try engine.execute(&store, .{ .del = .{ .keys = keys[0..] } });
    try expectInt(reply, 2);

    try testing.expect(store.get("a") == null);
    try testing.expect(store.get("b") == null);
}

test "EXISTS counts duplicates and ignores missing keys" {
    var store = newStore();
    defer store.deinit();

    try expectOk(try engine.execute(&store, .{ .set = .{ .key = "a", .value = "1" } }));

    const keys = [_][]const u8{ "a", "a", "missing" };
    const reply = try engine.execute(&store, .{ .exists = .{ .keys = keys[0..] } });
    try expectInt(reply, 2);
}

test "unknown command is a structured error reply" {
    var store = newStore();
    defer store.deinit();

    const reply = try engine.execute(&store, .{ .invalid = .{ .unknown_command = "FLUSHALL" } });
    try expectErr(reply, .{ .unknown_command = "FLUSHALL" });
}

test "wrong arity is a structured error reply" {
    var store = newStore();
    defer store.deinit();

    const reply = try engine.execute(&store, .{ .invalid = .{ .wrong_arity = "ping" } });
    try expectErr(reply, .{ .wrong_arity = "ping" });
}

test "empty command is a structured error reply" {
    var store = newStore();
    defer store.deinit();

    const reply = try engine.execute(&store, .{ .invalid = .empty_command });
    try expectErr(reply, .empty_command);
}

test "SET propagates storage out-of-memory" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var store = Store.init(failing.allocator());
    defer store.deinit();

    try testing.expectError(
        error.OutOfMemory,
        engine.execute(&store, .{ .set = .{ .key = "name", .value = "john" } }),
    );
    try testing.expect(store.get("name") == null);
}
