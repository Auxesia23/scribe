//! Unit tests for `Store`.

const std = @import("std");
const Store = @import("store.zig").Store;
const Clock = @import("store.zig").Clock;
const Item = @import("store.zig").Item;
const Ttl = @import("store.zig").Ttl;

const testing = std.testing;

// Updated for P3: `get`/`contains`/`count` become mutating once lazy expiry
// lands, so these helpers take `*Store`. A `*Store` also satisfies the
// current `*const` receivers, so the helpers compile before and after P3.

fn expectValue(store: *Store, key: []const u8, expected: []const u8) !void {
    const actual = store.get(key) orelse return error.MissingKey;
    try testing.expectEqualStrings(expected, actual);
}

fn expectMissing(store: *Store, key: []const u8) !void {
    try testing.expect(store.get(key) == null);
}

fn expectCount(store: *Store, expected: usize) !void {
    try testing.expectEqual(expected, store.count());
}

fn expectContains(store: *Store, key: []const u8, expected: bool) !void {
    try testing.expectEqual(expected, store.contains(key));
}

fn expectRemoved(store: *Store, key: []const u8, expected: bool) !void {
    try testing.expectEqual(expected, store.remove(key));
}

// Initialization and basic reads

test "init: new store is empty" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectMissing(&store, "anything");
    try expectContains(&store, "anything", false);
    try expectCount(&store, 0);
}

test "set + get: single entry" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.set("name", "john");
    try expectValue(&store, "name", "john");
}

test "get: missing key returns null" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.set("name", "john");
    try expectMissing(&store, "age");
}

test "set + get: multiple keys are independent" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.set("name", "john");
    try store.set("age", "23");
    try store.set("city", "jakarta");

    try expectValue(&store, "name", "john");
    try expectValue(&store, "age", "23");
    try expectValue(&store, "city", "jakarta");
}

// Overwrite semantics and ownership

test "set: overwrite replaces the value without adding an entry" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.set("age", "23");
    try expectValue(&store, "age", "23");
    try expectCount(&store, 1);

    try store.set("age", "23 years");
    try expectValue(&store, "age", "23 years");
    try expectCount(&store, 1);

    try store.set("age", "1");
    try expectValue(&store, "age", "1");
    try expectCount(&store, 1);
}

test "set: repeated overwrites do not leak or corrupt" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var buffer: [32]u8 = undefined;
        const value = try std.fmt.bufPrint(&buffer, "value-{d}", .{i});
        try store.set("counter", value);
    }

    try expectValue(&store, "counter", "value-199");
    try expectCount(&store, 1);
}

test "set: copies caller-owned key and value" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    var key_buffer: [4]u8 = "name".*;
    var value_buffer: [4]u8 = "john".*;

    try store.set(&key_buffer, &value_buffer);

    @memset(key_buffer[0..], 'x');
    @memset(value_buffer[0..], 'y');

    try expectValue(&store, "name", "john");
}

test "set + get: keys and values are binary-safe" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const key = "key with spaces\x00and a newline\n";
    const value = "\x00\x01\r\n\xff any byte is allowed";

    try store.set(key, value);
    try expectValue(&store, key, value);
}

test "set + get: empty value is valid" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.set("empty", "");
    try expectValue(&store, "empty", "");
    try expectCount(&store, 1);
    try expectContains(&store, "empty", true);
}

test "set + get: large value" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const big = try testing.allocator.alloc(u8, 16 * 1024);
    defer testing.allocator.free(big);
    for (big, 0..) |*byte, i| byte.* = @truncate(i);

    try store.set("big", big);

    const actual = store.get("big") orelse return error.MissingKey;
    try testing.expectEqualSlices(u8, big, actual);
}

// Removal

test "remove: existing key returns true and removes the entry" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.set("name", "john");
    try expectRemoved(&store, "name", true);

    try expectMissing(&store, "name");
    try expectContains(&store, "name", false);
    try expectCount(&store, 0);
}

test "remove: missing key returns false and leaves other entries intact" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.set("name", "john");
    try store.set("age", "23");

    try expectRemoved(&store, "city", false);

    try expectValue(&store, "name", "john");
    try expectValue(&store, "age", "23");
    try expectCount(&store, 2);
}

test "remove: only removes the requested entry" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.set("a", "1");
    try store.set("b", "2");
    try store.set("c", "3");

    try expectRemoved(&store, "b", true);

    try expectValue(&store, "a", "1");
    try expectMissing(&store, "b");
    try expectValue(&store, "c", "3");
    try expectCount(&store, 2);
}

test "remove: key can be reused after removal" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.set("name", "john");
    try expectRemoved(&store, "name", true);
    try expectMissing(&store, "name");

    try store.set("name", "jane");
    try expectValue(&store, "name", "jane");
    try expectCount(&store, 1);
}

test "remove: all entries until empty" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.set("a", "1");
    try store.set("b", "2");
    try store.set("c", "3");

    try expectRemoved(&store, "a", true);
    try expectRemoved(&store, "b", true);
    try expectRemoved(&store, "c", true);

    try expectCount(&store, 0);
    try expectMissing(&store, "a");
    try expectMissing(&store, "b");
    try expectMissing(&store, "c");
}

// Lookup helpers

test "contains: reflects store contents" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectContains(&store, "name", false);

    try store.set("name", "john");
    try expectContains(&store, "name", true);
    try expectContains(&store, "Name", false);
    try expectContains(&store, "nam", false);

    try store.set("name", "jane");
    try expectContains(&store, "name", true);

    try expectRemoved(&store, "name", true);
    try expectContains(&store, "name", false);
}

test "count: accurate after mixed operations" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectCount(&store, 0);

    try store.set("a", "1");
    try store.set("b", "2");
    try store.set("c", "3");
    try expectCount(&store, 3);

    try store.set("a", "one");
    try expectCount(&store, 3);

    try expectRemoved(&store, "missing", false);
    try expectCount(&store, 3);

    try expectRemoved(&store, "b", true);
    try expectCount(&store, 2);

    try store.set("d", "4");
    try expectCount(&store, 3);
}

// Clearing

test "clear: removes all entries and keeps the store usable" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.set("a", "1");
    try store.set("b", "2");
    try store.set("c", "3");

    store.clear();

    try expectCount(&store, 0);
    try expectMissing(&store, "a");
    try expectMissing(&store, "b");
    try expectMissing(&store, "c");
    try expectContains(&store, "a", false);

    try store.set("new", "value");
    try expectValue(&store, "new", "value");
    try expectCount(&store, 1);
}

test "clear: empty store does not error" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    store.clear();
    try expectCount(&store, 0);

    store.clear();
    try expectCount(&store, 0);

    try store.set("x", "1");
    try expectValue(&store, "x", "1");
}

// Destruction

test "deinit: frees all keys and values" {
    var store = Store.init(testing.allocator);

    try store.set("a", "one");
    try store.set("b", "two");
    try store.set("a", "one-more");

    store.deinit();
}

// Copies

test "getCopy: returns an independent copy" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.set("name", "john");

    const borrowed = store.get("name") orelse return error.MissingKey;
    const copy = (try store.getCopy("name")) orelse return error.ExpectedCopy;
    defer testing.allocator.free(copy);

    try testing.expect(copy.ptr != borrowed.ptr);
    try testing.expectEqualStrings("john", copy);
}

test "getCopy: copy stays valid after the key is removed" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.set("name", "john");

    const copy = (try store.getCopy("name")) orelse return error.ExpectedCopy;
    defer testing.allocator.free(copy);

    try expectRemoved(&store, "name", true);
    try testing.expectEqualStrings("john", copy);
}

test "getCopy: mutating the copy does not affect the store" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.set("name", "john");

    const copy = (try store.getCopy("name")) orelse return error.ExpectedCopy;
    defer testing.allocator.free(copy);

    copy[0] = 'J';

    try expectValue(&store, "name", "john");
    try testing.expectEqualStrings("John", copy);
}

test "getCopy: missing key returns null" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try testing.expect((try store.getCopy("missing")) == null);
}

test "getCopy: empty value is still non-null" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try store.set("empty", "");

    const copy = (try store.getCopy("empty")) orelse return error.ExpectedCopy;
    defer testing.allocator.free(copy);

    try testing.expectEqual(@as(usize, 0), copy.len);
}

// Allocation failures

test "OOM: failed first allocation leaves the store clean" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var store = Store.init(failing.allocator());
    defer store.deinit();

    try testing.expectError(error.OutOfMemory, store.set("name", "john"));

    try expectMissing(&store, "name");
    try expectCount(&store, 0);
}

test "OOM: failing to allocate the key frees the allocated value" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var store = Store.init(failing.allocator());
    defer store.deinit();

    try testing.expectError(error.OutOfMemory, store.set("name", "john"));

    try expectMissing(&store, "name");
    try expectCount(&store, 0);
}

// P3: expiry metadata and lazy expiration

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
    var store = Store.init(testing.allocator);
    store.clock = clock.clock();
    return store;
}

fn expectTtl(store_ptr: *Store, key: []const u8, expected: Ttl) !void {
    switch (expected) {
        .key_missing => switch (store_ptr.ttl(key)) {
            .key_missing => {},
            else => return error.TtlMismatch,
        },
        .no_expiry => switch (store_ptr.ttl(key)) {
            .no_expiry => {},
            else => return error.TtlMismatch,
        },
        .remaining_ms => |ms| switch (store_ptr.ttl(key)) {
            .remaining_ms => |actual| try testing.expectEqual(ms, actual),
            else => return error.TtlMismatch,
        },
    }
}

test "clock: default reads the system wall clock" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    // Any host running this test is past 2024-01-01 (Unix epoch ms).
    try testing.expect(store.clock.nowMs() > 1_704_067_200_000);
}

test "Item: carries exactly the D4 metadata fields" {
    const info = @typeInfo(Item).@"struct";
    try testing.expectEqual(@as(usize, 2), info.field_names.len);
    try testing.expectEqualStrings("value", info.field_names[0]);
    try testing.expectEqualStrings("expires_at_ms", info.field_names[1]);
}

test "setWithOptions: value without a deadline behaves like set" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try store.setWithOptions("k", "v", .{});
    try expectValue(&store, "k", "v");
    try expectCount(&store, 1);
    try expectTtl(&store, "k", .no_expiry);
}

test "setWithOptions: future deadline keeps the item readable" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try store.setWithOptions("k", "v", .{ .expires_at_ms = 2_000 });
    try expectValue(&store, "k", "v");
    try expectTtl(&store, "k", .{ .remaining_ms = 1_000 });
}

test "setWithOptions: binary-safe value with a deadline" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    const value = "\x00ab\r\n\xff";
    try store.setWithOptions("bin", value, .{ .expires_at_ms = 60_000 });

    const stored = store.get("bin") orelse return error.MissingKey;
    try testing.expectEqualSlices(u8, value, stored);
}

test "expiry boundary: deadline equal to now counts as expired" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try store.setWithOptions("k", "v", .{ .expires_at_ms = 1_000 });
    try expectMissing(&store, "k");
}

test "lazy expiry: get frees the item and reports it missing" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try store.setWithOptions("k", "v", .{ .expires_at_ms = 1_500 });
    clock.now_ms = 1_600;

    // The entry count dropping to zero is the observable proof that the
    // purge freed the item immediately (the leak check at deinit then only
    // proves there is nothing left to free).
    try expectMissing(&store, "k");
    try expectCount(&store, 0);
}

test "lazy expiry: contains treats an expired item as absent" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try store.setWithOptions("k", "v", .{ .expires_at_ms = 1_500 });
    clock.now_ms = 2_000;

    try expectContains(&store, "k", false);
}

test "lazy expiry: getCopy treats an expired item as absent" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try store.setWithOptions("k", "v", .{ .expires_at_ms = 1_500 });
    clock.now_ms = 2_000;

    try testing.expect((try store.getCopy("k")) == null);
    try expectCount(&store, 0);
}

test "lazy expiry: remove reports an expired item as missing" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try store.setWithOptions("k", "v", .{ .expires_at_ms = 1_500 });
    try store.set("other", "kept");
    clock.now_ms = 2_000;

    try expectRemoved(&store, "k", false);
    try expectCount(&store, 1);
    try expectValue(&store, "other", "kept");
}

test "lazy expiry: count purges every expired item" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try store.setWithOptions("a", "1", .{ .expires_at_ms = 1_500 });
    try store.set("b", "2");
    try store.setWithOptions("c", "3", .{ .expires_at_ms = 1_400 });
    clock.now_ms = 1_600;

    try expectCount(&store, 1);
    try expectValue(&store, "b", "2");
}

test "set: overwriting without options clears the deadline" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try store.setWithOptions("k", "v", .{ .expires_at_ms = 2_000 });
    try store.set("k", "v2");

    try expectTtl(&store, "k", .no_expiry);
    try expectValue(&store, "k", "v2");
}

test "setWithOptions: storing without a deadline clears a previous one" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try store.setWithOptions("k", "v", .{ .expires_at_ms = 2_000 });
    try store.setWithOptions("k", "v2", .{});

    try expectTtl(&store, "k", .no_expiry);
}

test "setWithOptions: re-setting replaces the deadline" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try store.setWithOptions("k", "v", .{ .expires_at_ms = 2_000 });
    try store.setWithOptions("k", "v2", .{ .expires_at_ms = 5_000 });

    try expectTtl(&store, "k", .{ .remaining_ms = 4_000 });
}

test "expire: sets the deadline on a live key" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try store.set("k", "v");
    try testing.expect(store.expire("k", 2_000));

    try expectTtl(&store, "k", .{ .remaining_ms = 1_000 });
    try expectValue(&store, "k", "v");
}

test "expire: missing key returns false" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try testing.expect(!store.expire("nope", 2_000));
    try expectCount(&store, 0);
}

test "expire: already-expired key returns false and is purged" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try store.setWithOptions("k", "v", .{ .expires_at_ms = 1_500 });
    clock.now_ms = 2_000;

    try testing.expect(!store.expire("k", 9_000));
    try expectCount(&store, 0);
}

test "expire: deadline in the past is accepted and purges on access" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try store.set("k", "v");

    // Redis semantics: EXPIRE with a non-positive TTL deletes the key and
    // replies 1; here the past deadline makes the key vanish lazily.
    try testing.expect(store.expire("k", clock.now_ms - 100));

    try expectMissing(&store, "k");
    try expectCount(&store, 0);
}

test "ttl: expired key counts as missing" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try store.setWithOptions("k", "v", .{ .expires_at_ms = 1_500 });
    clock.now_ms = 1_600;

    try expectTtl(&store, "k", .key_missing);
    try expectCount(&store, 0);
}

test "persist: removes the deadline and keeps the value" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try store.setWithOptions("k", "v", .{ .expires_at_ms = 2_000 });
    try testing.expect(store.persist("k"));

    try expectTtl(&store, "k", .no_expiry);
    try expectValue(&store, "k", "v");
}

test "persist: key without a deadline returns false" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try store.set("k", "v");
    try testing.expect(!store.persist("k"));
}

test "persist: missing key returns false" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try testing.expect(!store.persist("nope"));
}

test "persist: expired key returns false and is purged" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try store.setWithOptions("k", "v", .{ .expires_at_ms = 1_500 });
    clock.now_ms = 2_000;

    try testing.expect(!store.persist("k"));
    try expectCount(&store, 0);
}

test "OOM: setWithOptions failure leaves the store clean" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var store = Store.init(failing.allocator());
    defer store.deinit();

    try testing.expectError(
        error.OutOfMemory,
        store.setWithOptions("k", "v", .{ .expires_at_ms = 2_000 }),
    );

    try expectMissing(&store, "k");
    try expectCount(&store, 0);
}

test "deinit: frees items whose deadline passed without access" {
    var clock = FakeClock{ .now_ms = 1_000 };
    var store = newTimedStore(&clock);
    defer store.deinit();

    try store.setWithOptions("stale", "v", .{ .expires_at_ms = 1_500 });
    try store.set("fresh", "v");
    clock.now_ms = 9_000;

    // No lazy purge is triggered; the deferred deinit (with the
    // leak-checking allocator) must still free both items exactly once.
}
