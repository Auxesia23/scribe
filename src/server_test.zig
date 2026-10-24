//! TCP-level tests for `server.zig`.
//!
//! Every test opens real loopback sockets and compares exact reply bytes.
//! Each session connects before the server thread is spawned, and a watchdog
//! shuts the client down if the server stops responding, so a broken
//! implementation fails instead of hanging the suite.

const std = @import("std");
const Store = @import("store.zig").Store;
const Server = @import("server.zig").Server;

const testing = std.testing;

const host = "127.0.0.1";
const watchdog_timeout_ms: i64 = 2000;
const watchdog_poll_ms: i64 = 10;

/// A client connection with a watchdog.
///
/// Must be initialized as a local variable and opened through a pointer:
/// `reader`/`writer` keep slices into `rbuf`/`wbuf`, so the struct must not be
/// copied after `open`.
const Session = struct {
    io: std.Io = undefined,
    stream: std.Io.net.Stream = undefined,
    reader: std.Io.net.Stream.Reader = undefined,
    writer: std.Io.net.Stream.Writer = undefined,
    rbuf: [8 * 1024]u8 = undefined,
    wbuf: [8 * 1024]u8 = undefined,
    watchdog: ?std.Thread = null,
    /// True while the watchdog is allowed to fire.
    armed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set when the watchdog actually shut the connection down, so failures
    /// can say "server stopped responding" instead of a confusing EOF.
    fired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    opened: bool = false,

    fn open(self: *Session, io: std.Io, port: u16) !void {
        var addr = try std.Io.net.IpAddress.parse(host, port);

        self.io = io;
        self.armed.store(false, .release);
        self.fired.store(false, .release);

        self.stream = try addr.connect(io, .{ .mode = .stream });
        errdefer self.stream.close(io);

        self.reader = self.stream.reader(io, &self.rbuf);
        self.writer = self.stream.writer(io, &self.wbuf);

        self.armed.store(true, .release);
        self.watchdog = try std.Thread.spawn(.{}, Session.watch, .{self});
        self.opened = true;
    }

    /// Idempotent: tests close sessions early and also defer `deinit`.
    fn deinit(self: *Session) void {
        if (!self.opened) return;

        self.armed.store(false, .release);
        if (self.watchdog) |thread| thread.join();
        self.watchdog = null;

        self.stream.close(self.io);
        self.opened = false;
    }

    // No `SO_RCVTIMEO` here: in Zig 0.17 a blocking read that gets `EAGAIN`
    // panics with "programmer bug caused syscall error: AGAIN".
    fn watch(self: *Session) void {
        var waited_ms: i64 = 0;
        while (waited_ms < watchdog_timeout_ms) : (waited_ms += watchdog_poll_ms) {
            self.io.sleep(.fromMilliseconds(watchdog_poll_ms), .awake) catch return;
            if (!self.armed.load(.acquire)) return;
        }

        if (!self.armed.load(.acquire)) return;

        self.fired.store(true, .release);
        self.stream.shutdown(self.io, .both) catch {};
    }

    fn send(self: *Session, bytes: []const u8) !void {
        try self.writer.interface.writeAll(bytes);
        try self.writer.interface.flush();
    }

    /// Reads exactly `expected.len` bytes and compares them.
    ///
    /// Reading an exact length keeps pipelined replies unambiguous: the next
    /// `expect` starts where this one stopped. Surplus bytes from the server
    /// would desynchronize the following expectation.
    fn expect(self: *Session, expected: []const u8) !void {
        const buf = try testing.allocator.alloc(u8, expected.len);
        defer testing.allocator.free(buf);

        self.reader.interface.readSliceAll(buf) catch |err| {
            if (self.fired.load(.acquire)) return error.ServerStoppedResponding;
            return err;
        };

        try testing.expectEqualStrings(expected, buf);
    }

    /// Asserts that the server closed this connection.
    ///
    /// A clean FIN gives `EndOfStream`; an RST (for example when the server
    /// closes with unread input buffered) gives `ReadFailed`. Both mean the
    /// connection is gone.
    fn expectClosed(self: *Session) !void {
        _ = self.reader.interface.peekByte() catch |err| {
            if (self.fired.load(.acquire)) return error.ServerStoppedResponding;
            switch (err) {
                error.EndOfStream, error.ReadFailed => return,
            }
        };

        return error.ExpectedConnectionClosed;
    }
};

fn newStore() Store {
    return Store.init(testing.allocator);
}

// Binding

test "init: binds an ephemeral port and reports it" {
    const io = testing.io;

    var store = newStore();
    defer store.deinit();

    var server = try Server.init(testing.allocator, io, &store, .{ .port = 0 });
    defer server.deinit();

    try testing.expect(server.port() != 0);
}

test "init: reports the requested port and rejects an invalid bind address" {
    const io = testing.io;

    var store = newStore();
    defer store.deinit();

    // Learn a free port from the OS, then bind it explicitly.
    var first = try Server.init(testing.allocator, io, &store, .{ .port = 0 });
    const picked = first.port();
    try testing.expect(picked != 0);
    first.deinit();

    var second = try Server.init(testing.allocator, io, &store, .{ .port = picked });
    defer second.deinit();
    try testing.expectEqual(picked, second.port());

    // Parsing the bind address must fail loudly.
    if (Server.init(testing.allocator, io, &store, .{ .bind = "not-an-ip" })) |bogus| {
        var owned = bogus;
        owned.deinit();
        return error.ExpectedInitFailure;
    } else |_| {}
}

// Basic commands over TCP

test "serve: answers PING over TCP" {
    const io = testing.io;

    var store = newStore();
    defer store.deinit();

    var server = try Server.init(testing.allocator, io, &store, .{ .port = 0 });
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, Server.serve, .{&server});

    var session: Session = .{};
    defer {
        session.deinit();
        server.stop();
        thread.join();
    }

    try session.open(io, server.port());
    try session.send("*1\r\n$4\r\nPING\r\n");
    try session.expect("+PONG\r\n");
}

test "serve: answers inline commands" {
    const io = testing.io;

    var store = newStore();
    defer store.deinit();

    var server = try Server.init(testing.allocator, io, &store, .{ .port = 0 });
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, Server.serve, .{&server});

    var session: Session = .{};
    defer {
        session.deinit();
        server.stop();
        thread.join();
    }

    try session.open(io, server.port());

    // The inline form is what a human would type over telnet.
    try session.send("PING\r\n");
    try session.expect("+PONG\r\n");
}

test "serve: SET then GET on the same connection" {
    const io = testing.io;

    var store = newStore();
    defer store.deinit();

    var server = try Server.init(testing.allocator, io, &store, .{ .port = 0 });
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, Server.serve, .{&server});

    var session: Session = .{};
    defer {
        session.deinit();
        server.stop();
        thread.join();
    }

    try session.open(io, server.port());

    try session.send("*3\r\n$3\r\nSET\r\n$4\r\nname\r\n$4\r\njohn\r\n");
    try session.expect("+OK\r\n");

    try session.send("*2\r\n$3\r\nGET\r\n$4\r\nname\r\n");
    try session.expect("$4\r\njohn\r\n");
}

test "serve: pipelined commands are answered in order" {
    const io = testing.io;

    var store = newStore();
    defer store.deinit();

    var server = try Server.init(testing.allocator, io, &store, .{ .port = 0 });
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, Server.serve, .{&server});

    var session: Session = .{};
    defer {
        session.deinit();
        server.stop();
        thread.join();
    }

    try session.open(io, server.port());

    // Three commands in a single write. The server must not assume that one
    // read equals one command.
    try session.send("*1\r\n$4\r\nPING\r\n" ++
        "*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1\r\n1\r\n" ++
        "*2\r\n$3\r\nGET\r\n$1\r\na\r\n");

    try session.expect("+PONG\r\n");
    try session.expect("+OK\r\n");
    try session.expect("$1\r\n1\r\n");
}

test "serve: binary value round-trips" {
    const io = testing.io;

    var store = newStore();
    defer store.deinit();

    var server = try Server.init(testing.allocator, io, &store, .{ .port = 0 });
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, Server.serve, .{&server});

    var session: Session = .{};
    defer {
        session.deinit();
        server.stop();
        thread.join();
    }

    try session.open(io, server.port());

    const value = "hi\r\nthere\x00!"; // 11 bytes, contains CRLF and NUL

    try session.send("*3\r\n$3\r\nSET\r\n$3\r\nbin\r\n$11\r\n" ++ value ++ "\r\n");
    try session.expect("+OK\r\n");

    try session.send("*2\r\n$3\r\nGET\r\n$3\r\nbin\r\n");
    try session.expect("$11\r\n" ++ value ++ "\r\n");
}

test "serve: value larger than the connection buffer round-trips" {
    const io = testing.io;

    var store = newStore();
    defer store.deinit();

    var server = try Server.init(testing.allocator, io, &store, .{ .port = 0 });
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, Server.serve, .{&server});

    var session: Session = .{};
    defer {
        session.deinit();
        server.stop();
        thread.join();
    }

    try session.open(io, server.port());

    const value = try testing.allocator.alloc(u8, 100_000);
    defer testing.allocator.free(value);
    @memset(value, 'x');

    var len_buf: [32]u8 = undefined;
    const len_header = try std.fmt.bufPrint(&len_buf, "${d}\r\n", .{value.len});

    const set_cmd = try std.mem.concat(testing.allocator, u8, &.{
        "*3\r\n$3\r\nSET\r\n$3\r\nbig\r\n",
        len_header,
        value,
        "\r\n",
    });
    defer testing.allocator.free(set_cmd);

    try session.send(set_cmd);
    try session.expect("+OK\r\n");

    const expected = try std.mem.concat(testing.allocator, u8, &.{
        len_header,
        value,
        "\r\n",
    });
    defer testing.allocator.free(expected);

    try session.send("*2\r\n$3\r\nGET\r\n$3\r\nbig\r\n");
    try session.expect(expected);
}

// Command-level errors keep the connection open

test "serve: unknown command keeps the connection open" {
    const io = testing.io;

    var store = newStore();
    defer store.deinit();

    var server = try Server.init(testing.allocator, io, &store, .{ .port = 0 });
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, Server.serve, .{&server});

    var session: Session = .{};
    defer {
        session.deinit();
        server.stop();
        thread.join();
    }

    try session.open(io, server.port());

    try session.send("NOPE\r\n");
    try session.expect("-ERR unknown command 'NOPE'\r\n");

    // The session must still be usable.
    try session.send("*1\r\n$4\r\nPING\r\n");
    try session.expect("+PONG\r\n");
}

test "serve: arity error keeps the connection open" {
    const io = testing.io;

    var store = newStore();
    defer store.deinit();

    var server = try Server.init(testing.allocator, io, &store, .{ .port = 0 });
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, Server.serve, .{&server});

    var session: Session = .{};
    defer {
        session.deinit();
        server.stop();
        thread.join();
    }

    try session.open(io, server.port());

    try session.send("GET\r\n");
    try session.expect("-ERR wrong number of arguments for 'get' command\r\n");

    try session.send("PING\r\n");
    try session.expect("+PONG\r\n");
}

// Framing errors close only the offending connection

test "serve: malformed array header closes only that connection" {
    const io = testing.io;

    var store = newStore();
    defer store.deinit();

    var server = try Server.init(testing.allocator, io, &store, .{ .port = 0 });
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, Server.serve, .{&server});

    var bad: Session = .{};
    var good: Session = .{};
    defer {
        bad.deinit();
        good.deinit();
        server.stop();
        thread.join();
    }

    try bad.open(io, server.port());
    // Announces more arguments than `protocol.max_args` allows.
    try bad.send("*99999999\r\n");
    try bad.expectClosed();
    bad.deinit();

    try good.open(io, server.port());
    try good.send("*1\r\n$4\r\nPING\r\n");
    try good.expect("+PONG\r\n");
}

test "serve: oversized bulk length closes only that connection" {
    const io = testing.io;

    var store = newStore();
    defer store.deinit();

    var server = try Server.init(testing.allocator, io, &store, .{ .port = 0 });
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, Server.serve, .{&server});

    var bad: Session = .{};
    var good: Session = .{};
    defer {
        bad.deinit();
        good.deinit();
        server.stop();
        thread.join();
    }

    try bad.open(io, server.port());
    // 2,000,000 bytes is above `protocol.max_bulk_len` (1 MiB).
    try bad.send("*2\r\n$2000000\r\n");
    try bad.expectClosed();
    bad.deinit();

    try good.open(io, server.port());
    try good.send("*1\r\n$4\r\nPING\r\n");
    try good.expect("+PONG\r\n");
}

test "serve: truncated frame closes only that connection" {
    const io = testing.io;

    var store = newStore();
    defer store.deinit();

    var server = try Server.init(testing.allocator, io, &store, .{ .port = 0 });
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, Server.serve, .{&server});

    var bad: Session = .{};
    var good: Session = .{};
    defer {
        bad.deinit();
        good.deinit();
        server.stop();
        thread.join();
    }

    try bad.open(io, server.port());
    // Promises two arguments but only sends one, then disconnects.
    try bad.send("*2\r\n$3\r\nGET\r\n");
    bad.deinit();

    try good.open(io, server.port());
    try good.send("*1\r\n$4\r\nPING\r\n");
    try good.expect("+PONG\r\n");
}

test "serve: a client that disconnects immediately does not stop the server" {
    const io = testing.io;

    var store = newStore();
    defer store.deinit();

    var server = try Server.init(testing.allocator, io, &store, .{ .port = 0 });
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, Server.serve, .{&server});

    var silent: Session = .{};
    var good: Session = .{};
    defer {
        silent.deinit();
        good.deinit();
        server.stop();
        thread.join();
    }

    // Accepted, then closed before sending a single byte.
    try silent.open(io, server.port());
    silent.deinit();

    try good.open(io, server.port());
    try good.send("*1\r\n$4\r\nPING\r\n");
    try good.expect("+PONG\r\n");
}

// Shared state and shutdown

test "serve: state is shared between connections" {
    const io = testing.io;

    var store = newStore();
    defer store.deinit();

    var server = try Server.init(testing.allocator, io, &store, .{ .port = 0 });
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, Server.serve, .{&server});

    var first: Session = .{};
    var second: Session = .{};
    defer {
        first.deinit();
        second.deinit();
        server.stop();
        thread.join();
    }

    try first.open(io, server.port());
    try first.send("*3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$3\r\nabc\r\n");
    try first.expect("+OK\r\n");
    first.deinit();

    try second.open(io, server.port());
    try second.send("*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n");
    try second.expect("$3\r\nabc\r\n");
}

test "serve: stop() returns from the accept loop" {
    const io = testing.io;

    var store = newStore();
    defer store.deinit();

    var server = try Server.init(testing.allocator, io, &store, .{ .port = 0 });
    defer server.deinit();

    const thread = try std.Thread.spawn(.{}, Server.serve, .{&server});

    var session: Session = .{};
    defer {
        session.deinit();
        server.stop();
        thread.join();
    }

    try session.open(io, server.port());
    try session.send("*1\r\n$4\r\nPING\r\n");
    try session.expect("+PONG\r\n");

    session.deinit();

    // `stop` must wake the blocked `accept`; `thread.join()` below would hang
    // otherwise. The defer above joins exactly once.
    server.stop();
}
