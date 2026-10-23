//! Entry point for the scribe server.

const std = @import("std");
const Store = @import("store.zig").Store;

pub fn main(init: std.process.Init) !void {
    var store = Store.init(init.gpa);
    defer store.deinit();
}
