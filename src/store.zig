//! In-memory key-value storage.
//!
//! Keys and values are copied on insertion and owned by the store. `get`
//! returns a borrowed slice that remains valid until the corresponding key is
//! modified, removed, or the store is cleared/deinitialized.

const std = @import("std");

/// Stored entry with optional expiry metadata (roadmap D4).
///
/// There is deliberately no `flags` field: the current scope is RESP-only
/// string values.
pub const Item = struct {
    value: []u8,
    /// Absolute deadline in milliseconds since the Unix epoch. `null` means
    /// the item never expires. An item whose deadline is not after the
    /// store clock's current time is treated as absent and is freed on
    /// access (lazy expiry).
    expires_at_ms: ?i64 = null,
};

/// Time source used for expiry checks.
///
/// The store never calls time functions directly. Callers keep the system
/// default or inject a deterministic clock (tests do). Each store operation
/// reads the clock at most once so one command observes one consistent time.
pub const Clock = struct {
    ctx: ?*anyopaque = null,
    now_ms_fn: *const fn (ctx: ?*anyopaque) i64 = systemNowMs,

    /// Returns the current time as milliseconds since the Unix epoch.
    pub fn nowMs(clock: Clock) i64 {
        return clock.now_ms_fn(clock.ctx);
    }
};

/// Milliseconds since the Unix epoch from the system wall clock.
///
/// Zig 0.17 removed `std.time.milliTimestamp`, and the `std.Io` clock needs
/// an `Io` instance the store does not own, so call `clock_gettime` directly
/// (the project is Linux-first anyway, see D5). Redis expiry is wall-clock
/// based, so REALTIME (not MONOTONIC) is required.
fn systemNowMs(_: ?*anyopaque) i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// Options accepted by `Store.setWithOptions`.
pub const SetOptions = struct {
    /// Absolute deadline in milliseconds since the Unix epoch. `null` stores
    /// the item without a deadline and clears any previous one.
    expires_at_ms: ?i64 = null,
};

/// Result of a TTL lookup, mirroring the three Redis reply states.
pub const Ttl = union(enum) {
    /// The key does not exist (an expired key counts as missing).
    key_missing,
    /// The key exists without a deadline.
    no_expiry,
    /// The key exists and this many milliseconds remain.
    remaining_ms: i64,
};

const Live = struct {
    item: *Item,
    now_ms: i64,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    data: std.StringHashMap(Item),
    /// Time source for lazy expiry checks. Defaults to the system wall
    /// clock; tests inject a deterministic one.
    clock: Clock = .{},

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
            self.allocator.free(entry.value_ptr.*.value);
        }
        self.data.deinit();
    }

    fn lookup(self: *Store, key: []const u8) ?Live {
        const item = self.data.getPtr(key) orelse return null;
        const now = self.clock.nowMs();

        if (item.expires_at_ms) |deadline| {
            if (deadline <= now) {
                const kv = self.data.fetchRemove(key).?;
                self.allocator.free(kv.value.value);
                self.allocator.free(kv.key);
                return null;
            }
        }
        return .{ .item = item, .now_ms = now };
    }

    /// Inserts or replaces a value. The key and value are copied.
    pub fn set(self: *Store, key: []const u8, value: []const u8) !void {
        try self.setWithOptions(key, value, .{});
    }

    /// Returns a borrowed value, or null if the key is absent.
    pub fn get(self: *Store, key: []const u8) ?[]const u8 {
        const live = self.lookup(key) orelse return null;
        return live.item.value;
    }

    /// Returns the number of stored entries.
    pub fn count(self: *Store) usize {
        const now = self.clock.nowMs();

        var expired: std.ArrayList([]const u8) = .empty;
        defer expired.deinit(self.allocator);

        var it = self.data.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.expires_at_ms) |deadline| {
                if (deadline <= now) {
                    expired.append(self.allocator, entry.key_ptr.*) catch continue;
                }
            }
        }

        for (expired.items) |key| {
            const kv = self.data.fetchRemove(key) orelse continue;
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.value);
        }

        return self.data.count();
    }

    /// Returns whether the key is present.
    pub fn contains(self: *Store, key: []const u8) bool {
        return self.lookup(key) != null;
    }

    /// Removes all entries while keeping the store usable.
    pub fn clear(self: *Store) void {
        var it = self.data.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*.value);
        }
        self.data.clearRetainingCapacity();
    }

    /// Returns a caller-owned copy of the value, or null if the key is absent.
    ///
    /// The caller must free the returned slice with the store's allocator.
    pub fn getCopy(self: *Store, key: []const u8) !?[]u8 {
        const live = self.lookup(key) orelse return null;
        return try self.allocator.dupe(u8, live.item.value);
    }

    /// Removes a key. Returns true if the key existed.
    pub fn remove(self: *Store, key: []const u8) bool {
        if (self.lookup(key) == null) return false;
        const kv = self.data.fetchRemove(key).?;
        self.allocator.free(kv.key);
        self.allocator.free(kv.value.value);
        return true;
    }

    /// P3 skeleton: like `set`, but applies explicit expiry options.
    ///
    /// Storing without a deadline (`options.expires_at_ms == null`) clears
    /// any deadline the key had, matching Redis SET without KEEPTTL.
    pub fn setWithOptions(self: *Store, key: []const u8, value: []const u8, options: SetOptions) !void {
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        if (self.data.getPtr(key)) |value_ptr| {
            self.allocator.free(value_ptr.*.value);
            value_ptr.*.value = owned_value;
            value_ptr.expires_at_ms = options.expires_at_ms;
            return;
        }

        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);

        try self.data.put(owned_key, .{ .expires_at_ms = options.expires_at_ms, .value = owned_value });
    }

    /// P3 skeleton: sets an absolute expiry deadline on an existing key.
    ///
    /// Returns false when the key is missing (an already-expired key counts
    /// as missing and is lazily freed). A deadline in the past is accepted:
    /// the key then counts as missing on the next access, which reproduces
    /// Redis "EXPIRE with a non-positive TTL deletes the key" semantics.
    pub fn expire(self: *Store, key: []const u8, expires_at_ms: i64) bool {
        const live = self.lookup(key) orelse return false;
        live.item.expires_at_ms = expires_at_ms;
        return true;
    }

    /// P3 skeleton: returns the expiry state of a key.
    ///
    /// Reads the clock exactly once: a key whose deadline has passed is
    /// lazily freed and reported as `key_missing`.
    pub fn ttl(self: *Store, key: []const u8) Ttl {
        const live = self.lookup(key) orelse return .key_missing;
        const deadline = live.item.expires_at_ms orelse return .no_expiry;
        return .{ .remaining_ms = deadline - live.now_ms };
    }

    /// P3 skeleton: removes the expiry deadline, keeping the value.
    ///
    /// Returns true only when the key existed and had a deadline.
    pub fn persist(self: *Store, key: []const u8) bool {
        const live = self.lookup(key) orelse return false;
        if (live.item.expires_at_ms == null) return false;
        live.item.expires_at_ms = null;
        return true;
    }
};
