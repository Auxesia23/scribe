//! P2 spec: engine semantics, independent of RESP bytes.
//!
//! These tests construct `engine.Command` values directly. The RESP codec is
//! tested separately in `resp_test.zig`.

const std = @import("std");
const engine = @import("engine.zig");
const Store = @import("store.zig").Store;
const Clock = @import("store.zig").Clock;

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
        .invalid_expire => |name| switch (actual) {
            .invalid_expire => |actual_name| try testing.expectEqualStrings(name, actual_name),
            else => return error.ErrorReplyMismatch,
        },
        .value_not_integer => switch (actual) {
            .value_not_integer => {},
            else => return error.ErrorReplyMismatch,
        },
        .syntax_error => switch (actual) {
            .syntax_error => {},
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

// P3: TTL semantics with an injected clock

const FakeClock = struct {
    now_ms: i64 = 0,

    fn nowMs(ctx: ?*anyopaque) i64 {
        const self: *FakeClock = @ptrCast(@alignCast(ctx.?));
        return self.now_ms;
    }

    fn clock(self: *FakeClock) Clock {
        return .{ .ctx = self, .now_ms_fn = nowMs };
    }
};

fn newTimedStore(clock: *FakeClock) Store {
    var store = newStore();
    store.clock = clock.clock();
    return store;
}

test "SET with a relative expiry stores the deadline" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try expectOk(try engine.execute(&store, .{ .set = .{
        .key = "k",
        .value = "v",
        .expire = .{ .relative_ms = 10_000 },
    } }));

    try expectInt(try engine.execute(&store, .{ .ttl = .{ .key = "k", .unit = .seconds } }), 10);
}

test "SET with an absolute expiry stores the deadline" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try expectOk(try engine.execute(&store, .{ .set = .{
        .key = "k",
        .value = "v",
        .expire = .{ .absolute_ms = 11_000 },
    } }));

    try expectInt(try engine.execute(&store, .{ .ttl = .{ .key = "k", .unit = .seconds } }), 10);
}

test "PTTL reports remaining milliseconds" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try expectOk(try engine.execute(&store, .{ .set = .{
        .key = "k",
        .value = "v",
        .expire = .{ .relative_ms = 500 },
    } }));

    try expectInt(try engine.execute(&store, .{ .ttl = .{ .key = "k", .unit = .milliseconds } }), 500);
}

test "SET with a zero relative expiry is an invalid expire error" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    const reply = try engine.execute(&store, .{ .set = .{
        .key = "k",
        .value = "v",
        .expire = .{ .relative_ms = 0 },
    } });
    try expectErr(reply, .{ .invalid_expire = "set" });
    try testing.expect(store.get("k") == null);
}

test "SET with a negative relative expiry is an invalid expire error" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    const reply = try engine.execute(&store, .{ .set = .{
        .key = "k",
        .value = "v",
        .expire = .{ .relative_ms = -100 },
    } });
    try expectErr(reply, .{ .invalid_expire = "set" });
}

test "SET with a non-positive absolute expiry is an invalid expire error" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    // Redis rejects `SET k v EXAT 0` / `PXAT 0` as "invalid expire time".
    const reply = try engine.execute(&store, .{ .set = .{
        .key = "k",
        .value = "v",
        .expire = .{ .absolute_ms = 0 },
    } });
    try expectErr(reply, .{ .invalid_expire = "set" });
}

test "SET with an absolute expiry in the past is stored and immediately gone" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    // Redis: `SET k v EXAT 1` replies OK and the key counts as expired.
    try expectOk(try engine.execute(&store, .{ .set = .{
        .key = "k",
        .value = "v",
        .expire = .{ .absolute_ms = 500 },
    } }));

    try expectNil(try engine.execute(&store, .{ .get = .{ .key = "k" } }));
    try expectInt(try engine.execute(&store, .{ .ttl = .{ .key = "k", .unit = .seconds } }), -2);
}

test "SET overwrite without expiry clears the deadline" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try expectOk(try engine.execute(&store, .{ .set = .{
        .key = "k",
        .value = "v",
        .expire = .{ .relative_ms = 10_000 },
    } }));
    try expectOk(try engine.execute(&store, .{ .set = .{ .key = "k", .value = "v2" } }));

    try expectInt(try engine.execute(&store, .{ .ttl = .{ .key = "k", .unit = .seconds } }), -1);
}

test "GET treats an expired key as missing" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try expectOk(try engine.execute(&store, .{ .set = .{
        .key = "k",
        .value = "v",
        .expire = .{ .relative_ms = 500 },
    } }));
    clock.now_ms = 2_000;

    try expectNil(try engine.execute(&store, .{ .get = .{ .key = "k" } }));
}

test "EXISTS treats an expired key as missing" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try expectOk(try engine.execute(&store, .{ .set = .{
        .key = "k",
        .value = "v",
        .expire = .{ .relative_ms = 500 },
    } }));
    clock.now_ms = 2_000;

    const keys = [_][]const u8{"k"};
    try expectInt(
        try engine.execute(&store, .{ .exists = .{ .keys = keys[0..] } }),
        0,
    );
}

test "TTL missing key is -2" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try expectInt(try engine.execute(&store, .{ .ttl = .{ .key = "nope", .unit = .seconds } }), -2);
}

test "TTL key without expiry is -1" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try expectOk(try engine.execute(&store, .{ .set = .{ .key = "k", .value = "v" } }));
    try expectInt(try engine.execute(&store, .{ .ttl = .{ .key = "k", .unit = .seconds } }), -1);
}

test "TTL rounds remaining milliseconds to the nearest second" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    // Redis computes TTL as (remaining_ms + 500) / 1000.
    try expectOk(try engine.execute(&store, .{ .set = .{
        .key = "k",
        .value = "v",
        .expire = .{ .relative_ms = 1_500 },
    } }));

    try expectInt(try engine.execute(&store, .{ .ttl = .{ .key = "k", .unit = .seconds } }), 2);
}

test "EXPIRE sets a deadline and returns 1" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try expectOk(try engine.execute(&store, .{ .set = .{ .key = "k", .value = "v" } }));
    try expectInt(
        try engine.execute(&store, .{ .expire = .{ .key = "k", .expiry = .{ .relative_ms = 10_000 } } }),
        1,
    );
    try expectInt(try engine.execute(&store, .{ .ttl = .{ .key = "k", .unit = .seconds } }), 10);
}

test "EXPIRE on a missing key returns 0" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try expectInt(
        try engine.execute(&store, .{ .expire = .{ .key = "nope", .expiry = .{ .relative_ms = 10_000 } } }),
        0,
    );
}

test "EXPIRE with zero deletes the key" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    // Redis: EXPIRE with a non-positive TTL deletes the key and replies 1.
    try expectOk(try engine.execute(&store, .{ .set = .{ .key = "k", .value = "v" } }));
    try expectInt(
        try engine.execute(&store, .{ .expire = .{ .key = "k", .expiry = .{ .relative_ms = 0 } } }),
        1,
    );

    try expectNil(try engine.execute(&store, .{ .get = .{ .key = "k" } }));
    try testing.expect(store.count() == 0);
}

test "EXPIRE with a negative value deletes the key" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try expectOk(try engine.execute(&store, .{ .set = .{ .key = "k", .value = "v" } }));
    try expectInt(
        try engine.execute(&store, .{ .expire = .{ .key = "k", .expiry = .{ .relative_ms = -100 } } }),
        1,
    );

    try expectNil(try engine.execute(&store, .{ .get = .{ .key = "k" } }));
}

test "EXPIRE on an already-expired key returns 0" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try expectOk(try engine.execute(&store, .{ .set = .{
        .key = "k",
        .value = "v",
        .expire = .{ .relative_ms = 500 },
    } }));
    clock.now_ms = 2_000;

    try expectInt(
        try engine.execute(&store, .{ .expire = .{ .key = "k", .expiry = .{ .relative_ms = 9_000 } } }),
        0,
    );
}

test "PERSIST removes the deadline and returns 1" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try expectOk(try engine.execute(&store, .{ .set = .{
        .key = "k",
        .value = "v",
        .expire = .{ .relative_ms = 10_000 },
    } }));
    try expectInt(try engine.execute(&store, .{ .persist = .{ .key = "k" } }), 1);

    try expectInt(try engine.execute(&store, .{ .ttl = .{ .key = "k", .unit = .seconds } }), -1);
    try expectBulk(try engine.execute(&store, .{ .get = .{ .key = "k" } }), "v");
}

test "PERSIST on a key without a deadline returns 0" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try expectOk(try engine.execute(&store, .{ .set = .{ .key = "k", .value = "v" } }));
    try expectInt(try engine.execute(&store, .{ .persist = .{ .key = "k" } }), 0);
}

test "PERSIST on a missing key returns 0" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try expectInt(try engine.execute(&store, .{ .persist = .{ .key = "nope" } }), 0);
}

test "SET with expiry propagates storage out-of-memory" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = Store.init(failing.allocator());
    defer store.deinit();
    store.clock = clock.clock();

    try testing.expectError(
        error.OutOfMemory,
        engine.execute(&store, .{ .set = .{
            .key = "k",
            .value = "v",
            .expire = .{ .relative_ms = 10_000 },
        } }),
    );
    try testing.expect(store.get("k") == null);
}
