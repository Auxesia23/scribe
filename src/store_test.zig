//! Unit tests for `Store`.

const std = @import("std");
const Store = @import("store.zig").Store;

const testing = std.testing;

fn expectValue(store: *const Store, key: []const u8, expected: []const u8) !void {
    const actual = store.get(key) orelse return error.MissingKey;
    try testing.expectEqualStrings(expected, actual);
}

fn expectMissing(store: *const Store, key: []const u8) !void {
    try testing.expect(store.get(key) == null);
}

fn expectCount(store: *const Store, expected: usize) !void {
    try testing.expectEqual(expected, store.count());
}

fn expectContains(store: *const Store, key: []const u8, expected: bool) !void {
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
