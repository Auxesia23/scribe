//! In-memory key-value storage.
//!
//! Keys and values are copied on insertion and owned by the store. `get`
//! returns a borrowed slice that remains valid until the corresponding key is
//! modified, removed, or the store is cleared/deinitialized.

const std = @import("std");

pub const Store = struct {
    allocator: std.mem.Allocator,
    data: std.StringHashMap([]u8),

    /// Creates an empty store.
    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .allocator = allocator,
            .data = .init(allocator),
        };
    }

    /// Frees every stored key and value.
    pub fn deinit(self: *Store) void {
        var it = self.data.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.data.deinit();
    }

    /// Inserts or replaces a value. The key and value are copied.
    pub fn set(self: *Store, key: []const u8, value: []const u8) !void {
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        if (self.data.getPtr(key)) |value_ptr| {
            self.allocator.free(value_ptr.*);
            value_ptr.* = owned_value;
            return;
        }

        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);

        try self.data.put(owned_key, owned_value);
    }

    /// Returns a borrowed value, or null if the key is absent.
    pub fn get(self: *const Store, key: []const u8) ?[]const u8 {
        return self.data.get(key);
    }

    /// Returns the number of stored entries.
    pub fn count(self: *const Store) usize {
        return self.data.count();
    }

    /// Returns whether the key is present.
    pub fn contains(self: *const Store, key: []const u8) bool {
        return self.data.contains(key);
    }

    /// Removes all entries while keeping the store usable.
    pub fn clear(self: *Store) void {
        var it = self.data.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.data.clearRetainingCapacity();
    }

    /// Returns a caller-owned copy of the value, or null if the key is absent.
    ///
    /// The caller must free the returned slice with the store's allocator.
    pub fn getCopy(self: *const Store, key: []const u8) !?[]u8 {
        const value = self.data.get(key) orelse return null;
        return try self.allocator.dupe(u8, value);
    }

    /// Removes a key. Returns true if the key existed.
    pub fn remove(self: *Store, key: []const u8) bool {
        if (self.data.fetchRemove(key)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
            return true;
        }
        return false;
    }
};
