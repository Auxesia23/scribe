//! TCP transport for the key-value server.
//!
//! This is the only module that knows about `std.Io.net`. The protocol layer
//! only receives a `std.Io.Reader` and a `std.Io.Writer`.
//!
//! Errors are connection-scoped: `EndOfStream` and framing errors close one
//! connection and leave the server running. Only listener failures abort
//! `serve`.

const std = @import("std");
const Store = @import("store.zig").Store;
const protocol = @import("protocol.zig");

pub const Config = struct {
    /// Address to bind.
    bind: []const u8 = "127.0.0.1",
    /// Port to listen on. `0` lets the OS choose; see `Server.port`.
    port: u16 = 6379,
};

pub const Server = struct {
    // Scratch allocator passed to `protocol.execute`. It must be thread-safe
    // once connections are served concurrently.
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *Store,
    listener: std.Io.net.Server,
    // Cleared by `stop` to end the accept loop. Atomic because `stop` may be
    // called from another thread.
    running: std.atomic.Value(bool),

    /// Binds and starts listening. The server is considered running until
    /// `stop` is called.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, store: *Store, config: Config) !Server {
        const addr = try std.Io.net.IpAddress.parse(config.bind, config.port);
        const listener = try addr.listen(io, .{ .reuse_address = true });
        return .{
            .allocator = allocator,
            .io = io,
            .store = store,
            .listener = listener,
            .running = std.atomic.Value(bool).init(true),
        };
    }

    /// Releases the listening socket.
    pub fn deinit(self: *Server) void {
        self.listener.deinit(self.io);
    }

    /// Returns the port the server listens on, resolving port 0.
    pub fn port(self: *const Server) u16 {
        return self.listener.socket.address.getPort();
    }

    /// Accepts and serves connections until `stop` is called.
    ///
    /// Connections are handled one at a time. The read buffer must be larger
    /// than `protocol.max_line_len`, otherwise `takeDelimiter` cannot see the
    /// delimiter and legal input is rejected as `BadProtocol`.
    pub fn serve(self: *Server) !void {
        defer self.running.store(false, .release);
        while (self.running.load(.acquire)) {
            const stream = self.listener.accept(self.io) catch |err| switch (err) {
                error.SocketNotListening => return,
                error.ConnectionAborted => continue,
                else => return err,
            };
            defer stream.close(self.io);

            var read_buf: [8 * 1024]u8 = undefined;
            var write_buf: [4 * 1024]u8 = undefined;
            var r = stream.reader(self.io, &read_buf);
            var w = stream.writer(self.io, &write_buf);

            while (true) {
                protocol.execute(self.store, self.allocator, &r.interface, &w.interface) catch |err| switch (err) {
                    error.EndOfStream,
                    error.Truncated,
                    error.BadProtocol,
                    error.ReadFailed,
                    error.WriteFailed,
                    error.OutOfMemory,
                    => break,
                };
                w.interface.flush() catch break;
            }
        }
    }

    /// Ends the accept loop. Safe to call from another thread and more than
    /// once.
    ///
    /// Shutting down the listening socket is what wakes a blocked `accept`;
    /// closing it would not.
    pub fn stop(self: *Server) void {
        self.running.store(false, .release);
        var as_stream: std.Io.net.Stream = .{ .socket = self.listener.socket };
        as_stream.shutdown(self.io, .both) catch {};
    }
};
