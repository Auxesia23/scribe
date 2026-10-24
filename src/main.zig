//! Entry point for the scribe server.

const std = @import("std");
const Store = @import("store.zig").Store;
const Server = @import("server.zig").Server;

pub fn main(init: std.process.Init) !void {
    var store = Store.init(init.gpa);
    defer store.deinit();

    var server = try Server.init(init.gpa, init.io, &store, .{});
    defer server.deinit();

    try server.serve();
}
