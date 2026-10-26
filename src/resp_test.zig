//! P2 spec: RESP2 codec and the new engine/codec pipeline.
//!
//! Intended pipeline:
//!
//!     resp.readCommand(&arena, reader) -> engine.Command
//!     engine.execute(store, command) -> Reply
//!     resp.writeReply(writer, reply) -> bytes
//!     arena.reset(...)
//!
//! A `Reply` may borrow bytes from the store or from the command arena, so it
//! must be encoded before the arena is reset.

const std = @import("std");
const engine = @import("engine.zig");
const resp = @import("resp.zig");
const Store = @import("store.zig").Store;

const testing = std.testing;

fn newStore() Store {
    return Store.init(testing.allocator);
}

fn expectWritten(reply: engine.Reply, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try resp.writeReply(&out.writer, reply);
    try testing.expectEqualStrings(expected, out.written());
}

const TestCommand = struct {
    arena: std.heap.ArenaAllocator,
    command: engine.Command,

    fn deinit(self: *TestCommand) void {
        self.arena.deinit();
    }
};

fn read(input: []const u8) !TestCommand {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    errdefer arena.deinit();

    var r: std.Io.Reader = .fixed(input);
    const command = try resp.readCommand(&arena, &r);

    return .{ .arena = arena, .command = command };
}

fn expectReadError(input: []const u8, expected: anyerror) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var r: std.Io.Reader = .fixed(input);
    try testing.expectError(expected, resp.readCommand(&arena, &r));
}

fn expectSession(store: *Store, input: []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var r: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    while (true) {
        const command = resp.readCommand(&arena, &r) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        const reply = try engine.execute(store, command);
        try resp.writeReply(&out.writer, reply);

        _ = arena.reset(.retain_capacity);
    }

    try testing.expectEqualStrings(expected, out.written());
}

fn expectInvalidArity(input: []const u8, name: []const u8) !void {
    var parsed = try read(input);
    defer parsed.deinit();

    switch (parsed.command) {
        .invalid => |err| switch (err) {
            .wrong_arity => |actual| try testing.expectEqualStrings(name, actual),
            else => return error.ExpectedWrongArity,
        },
        else => return error.ExpectedInvalidCommand,
    }
}

// writeReply

test "writeReply: simple strings" {
    try expectWritten(.pong, "+PONG\r\n");
    try expectWritten(.ok, "+OK\r\n");
}

test "writeReply: nil bulk" {
    try expectWritten(.nil, "$-1\r\n");
}

test "writeReply: bulk strings are binary-safe" {
    try expectWritten(.{ .bulk = "hello" }, "$5\r\nhello\r\n");
    try expectWritten(.{ .bulk = "" }, "$0\r\n\r\n");
    try expectWritten(.{ .bulk = "a\x00b\r\nc" }, "$6\r\na\x00b\r\nc\r\n");
}

test "writeReply: integers" {
    try expectWritten(.{ .int = 42 }, ":42\r\n");
    try expectWritten(.{ .int = 0 }, ":0\r\n");
    try expectWritten(.{ .int = -1 }, ":-1\r\n");
}

test "writeReply: error replies" {
    try expectWritten(.{ .err = .empty_command }, "-ERR empty command\r\n");
    try expectWritten(
        .{ .err = .{ .unknown_command = "FLUSHALL" } },
        "-ERR unknown command 'FLUSHALL'\r\n",
    );
    try expectWritten(
        .{ .err = .{ .wrong_arity = "ping" } },
        "-ERR wrong number of arguments for 'ping' command\r\n",
    );
}

// readCommand: command mapping

test "readCommand: inline PING" {
    var parsed = try read("PING\r\n");
    defer parsed.deinit();

    switch (parsed.command) {
        .ping => |ping| try testing.expect(ping.message == null),
        else => return error.ExpectedPing,
    }
}

test "readCommand: RESP PING" {
    var parsed = try read("*1\r\n$4\r\nPING\r\n");
    defer parsed.deinit();

    switch (parsed.command) {
        .ping => |ping| try testing.expect(ping.message == null),
        else => return error.ExpectedPing,
    }
}

test "readCommand: command names are case-insensitive" {
    var parsed = try read("*1\r\n$4\r\npInG\r\n");
    defer parsed.deinit();

    switch (parsed.command) {
        .ping => |ping| try testing.expect(ping.message == null),
        else => return error.ExpectedPing,
    }
}

test "readCommand: PING message" {
    var parsed = try read("PING hello\r\n");
    defer parsed.deinit();

    switch (parsed.command) {
        .ping => |ping| try testing.expectEqualStrings("hello", ping.message.?),
        else => return error.ExpectedPing,
    }
}

test "readCommand: RESP SET" {
    var parsed = try read("*3\r\n$3\r\nSET\r\n$4\r\nname\r\n$4\r\njohn\r\n");
    defer parsed.deinit();

    switch (parsed.command) {
        .set => |set| {
            try testing.expectEqualStrings("name", set.key);
            try testing.expectEqualStrings("john", set.value);
        },
        else => return error.ExpectedSet,
    }
}

test "readCommand: inline SET tolerates extra spaces" {
    var parsed = try read("SET   name   john\r\n");
    defer parsed.deinit();

    switch (parsed.command) {
        .set => |set| {
            try testing.expectEqualStrings("name", set.key);
            try testing.expectEqualStrings("john", set.value);
        },
        else => return error.ExpectedSet,
    }
}

test "readCommand: DEL keeps every key" {
    var parsed = try read("DEL a b missing\r\n");
    defer parsed.deinit();

    switch (parsed.command) {
        .del => |del| {
            try testing.expectEqual(@as(usize, 3), del.keys.len);
            try testing.expectEqualStrings("a", del.keys[0]);
            try testing.expectEqualStrings("b", del.keys[1]);
            try testing.expectEqualStrings("missing", del.keys[2]);
        },
        else => return error.ExpectedDel,
    }
}

test "readCommand: EXISTS keeps every key" {
    var parsed = try read("EXISTS a a missing\r\n");
    defer parsed.deinit();

    switch (parsed.command) {
        .exists => |exists| {
            try testing.expectEqual(@as(usize, 3), exists.keys.len);
            try testing.expectEqualStrings("a", exists.keys[0]);
            try testing.expectEqualStrings("a", exists.keys[1]);
            try testing.expectEqualStrings("missing", exists.keys[2]);
        },
        else => return error.ExpectedExists,
    }
}

test "readCommand: unknown command preserves its spelling" {
    var parsed = try read("FLUSHALL\r\n");
    defer parsed.deinit();

    switch (parsed.command) {
        .invalid => |err| switch (err) {
            .unknown_command => |name| try testing.expectEqualStrings("FLUSHALL", name),
            else => return error.ExpectedUnknownCommand,
        },
        else => return error.ExpectedInvalidCommand,
    }
}

test "readCommand: unknown RESP command preserves its spelling" {
    var parsed = try read("*2\r\n$4\r\nNOPE\r\n$3\r\narg\r\n");
    defer parsed.deinit();

    switch (parsed.command) {
        .invalid => |err| switch (err) {
            .unknown_command => |name| try testing.expectEqualStrings("NOPE", name),
            else => return error.ExpectedUnknownCommand,
        },
        else => return error.ExpectedInvalidCommand,
    }
}

test "readCommand: wrong arity uses the canonical command name" {
    try expectInvalidArity("PING a b\r\n", "ping");
    try expectInvalidArity("SET k\r\n", "set");
    try expectInvalidArity("SET k v extra\r\n", "set");
    try expectInvalidArity("GET k v\r\n", "get");
    try expectInvalidArity("DEL\r\n", "del");
    try expectInvalidArity("EXISTS\r\n", "exists");
}

test "readCommand: empty inline command" {
    var parsed = try read("\r\n");
    defer parsed.deinit();

    switch (parsed.command) {
        .invalid => |err| switch (err) {
            .empty_command => {},
            else => return error.ExpectedEmptyCommand,
        },
        else => return error.ExpectedInvalidCommand,
    }
}

test "readCommand: binary bulk argument" {
    const value = "\x00ab\r\n\xff"; // 6 bytes
    var parsed = try read("*3\r\n$3\r\nSET\r\n$3\r\nbin\r\n$6\r\n" ++ value ++ "\r\n");
    defer parsed.deinit();

    switch (parsed.command) {
        .set => |set| try testing.expectEqualSlices(u8, value, set.value),
        else => return error.ExpectedSet,
    }
}

// readCommand: error contract

test "readCommand: empty input is EndOfStream" {
    try expectReadError("", error.EndOfStream);
}

test "readCommand: clean EOF after a complete command is EndOfStream" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var r: std.Io.Reader = .fixed("PING\r\n");
    _ = try resp.readCommand(&arena, &r);

    try testing.expectError(error.EndOfStream, resp.readCommand(&arena, &r));
}

test "readCommand: EOF while reading argc is Truncated" {
    try expectReadError("*2\r\n", error.Truncated);
}

test "readCommand: EOF while reading an argument header is Truncated" {
    try expectReadError("*2\r\n$4\r\nGET\r\n", error.Truncated);
}

test "readCommand: EOF in the middle of a bulk body is Truncated" {
    try expectReadError("*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$5\r\nabc", error.Truncated);
}

test "readCommand: inline command without newline is Truncated" {
    try expectReadError("PING", error.Truncated);
}

test "readCommand: missing CRLF after a bulk body is BadProtocol" {
    try expectReadError("*1\r\n$4\r\nPINGxx", error.BadProtocol);
}

test "readCommand: non-bulk array element is BadProtocol" {
    try expectReadError("*1\r\nPING\r\n", error.BadProtocol);
}

test "readCommand: null bulk string as an argument is BadProtocol" {
    try expectReadError("*2\r\n$4\r\nGET\r\n$-1\r\n", error.BadProtocol);
}

test "readCommand: invalid argc values are BadProtocol" {
    try expectReadError("*0\r\n", error.BadProtocol);
    try expectReadError("*-1\r\n", error.BadProtocol);
    try expectReadError("*x\r\n", error.BadProtocol);
}

test "readCommand: missing '$' in the length line is BadProtocol" {
    try expectReadError("*1\r\n$4PING\r\n", error.BadProtocol);
}

// readCommand: limits

test "limits: argc above max_args is BadProtocol" {
    var buffer: [64]u8 = undefined;
    const input = try std.fmt.bufPrint(&buffer, "*{d}\r\n", .{resp.max_args + 1});
    try expectReadError(input, error.BadProtocol);
}

test "limits: bulk length above max_bulk_len is BadProtocol" {
    var buffer: [64]u8 = undefined;
    const input = try std.fmt.bufPrint(
        &buffer,
        "*2\r\n$4\r\nGET\r\n${d}\r\n",
        .{resp.max_bulk_len + 1},
    );
    try expectReadError(input, error.BadProtocol);
}

test "limits: inline line above max_line_len is BadProtocol" {
    const long_line = try testing.allocator.alloc(u8, resp.max_line_len + 2);
    defer testing.allocator.free(long_line);
    @memset(long_line[0..resp.max_line_len], 'A');
    long_line[resp.max_line_len] = '\r';
    long_line[resp.max_line_len + 1] = '\n';

    try expectReadError(long_line, error.BadProtocol);
}

test "limits: declared command size above max_command_len is BadProtocol" {
    const argc = resp.max_command_len / resp.max_bulk_len + 1;
    try testing.expect(argc <= resp.max_args);

    var input: std.Io.Writer.Allocating = .init(testing.allocator);
    defer input.deinit();

    // A streaming parser must read each body before it can see the next
    // header. Fill all but the last argument so the parser can reach the final
    // header; that header alone must exceed max_command_len and be rejected
    // before its body is read.
    var header_buffer: [32]u8 = undefined;
    try input.writer.writeAll(try std.fmt.bufPrint(&header_buffer, "*{d}\r\n", .{argc}));

    for (0..argc - 1) |_| {
        try input.writer.writeAll(
            try std.fmt.bufPrint(&header_buffer, "${d}\r\n", .{resp.max_bulk_len}),
        );
        try input.writer.splatByteAll('x', resp.max_bulk_len);
        try input.writer.writeAll("\r\n");
    }

    // Header for the last argument, deliberately without a body.
    try input.writer.writeAll(
        try std.fmt.bufPrint(&header_buffer, "${d}\r\n", .{resp.max_bulk_len}),
    );

    try expectReadError(input.written(), error.BadProtocol);
}

// Argument ownership

test "readCommand: arguments outlive reader buffer refills" {
    var input_buffer: [64]u8 = undefined;
    const input = try std.fmt.bufPrint(
        &input_buffer,
        "*3\r\n$3\r\nSET\r\n$4\r\nname\r\n$4\r\njohn\r\n",
        .{},
    );

    var reader_buffer: [8]u8 = undefined;
    var chunked: std.testing.Reader = .init(&reader_buffer, &.{.{ .buffer = input }});
    chunked.artificial_limit = .limited(1);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const command = try resp.readCommand(&arena, &chunked.interface);

    // Invalidate the source buffer; parsed arguments must be copied into the
    // arena.
    @memset(input_buffer[0..], 'x');

    switch (command) {
        .set => |set| {
            try testing.expectEqualStrings("name", set.key);
            try testing.expectEqualStrings("john", set.value);
        },
        else => return error.ExpectedSet,
    }
}

// End-to-end pipeline (readCommand + execute + writeReply)

test "session: PING over inline and RESP" {
    var store = newStore();
    defer store.deinit();

    try expectSession(&store, "PING\r\n*1\r\n$4\r\nPING\r\n", "+PONG\r\n+PONG\r\n");
}

test "session: SET/GET round trip via RESP" {
    var store = newStore();
    defer store.deinit();

    try expectSession(
        &store,
        "*3\r\n$3\r\nSET\r\n$4\r\nname\r\n$4\r\njohn\r\n" ++
            "*2\r\n$3\r\nGET\r\n$4\r\nname\r\n",
        "+OK\r\n$4\r\njohn\r\n",
    );
}

test "session: SET/GET round trip via inline commands" {
    var store = newStore();
    defer store.deinit();

    try expectSession(&store, "SET name john\r\nGET name\r\n", "+OK\r\n$4\r\njohn\r\n");
}

test "session: GET missing key returns nil" {
    var store = newStore();
    defer store.deinit();

    try expectSession(&store, "GET nope\r\n", "$-1\r\n");
}

test "session: SET overwrite is visible to the next GET" {
    var store = newStore();
    defer store.deinit();

    try expectSession(
        &store,
        "SET k v1\r\nSET k longer-value\r\nGET k\r\n",
        "+OK\r\n+OK\r\n$12\r\nlonger-value\r\n",
    );
}

test "session: empty value is valid" {
    var store = newStore();
    defer store.deinit();

    try expectSession(
        &store,
        "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$0\r\n\r\n" ++
            "*2\r\n$3\r\nGET\r\n$1\r\nk\r\n",
        "+OK\r\n$0\r\n\r\n",
    );
}

test "session: binary value round-trips" {
    var store = newStore();
    defer store.deinit();

    const value = "\x00ab\r\n\xff"; // 6 bytes
    const input = "*3\r\n$3\r\nSET\r\n$3\r\nbin\r\n$6\r\n" ++ value ++ "\r\n" ++
        "*2\r\n$3\r\nGET\r\n$3\r\nbin\r\n";
    const expected = "+OK\r\n$6\r\n" ++ value ++ "\r\n";

    try expectSession(&store, input, expected);
}

test "session: DEL and EXISTS" {
    var store = newStore();
    defer store.deinit();

    try expectSession(
        &store,
        "SET a 1\r\nSET b 2\r\nSET c 3\r\nDEL a b missing\r\nEXISTS a b c\r\n",
        "+OK\r\n+OK\r\n+OK\r\n:2\r\n:1\r\n",
    );
}

test "session: repeated DEL counts only existing keys" {
    var store = newStore();
    defer store.deinit();

    try expectSession(&store, "SET a 1\r\nDEL a\r\nDEL a\r\n", "+OK\r\n:1\r\n:0\r\n");
}

test "session: unknown command keeps the connection usable" {
    var store = newStore();
    defer store.deinit();

    try expectSession(&store, "NOPE\r\nPING\r\n", "-ERR unknown command 'NOPE'\r\n+PONG\r\n");
}

test "session: arity error keeps the connection usable" {
    var store = newStore();
    defer store.deinit();

    try expectSession(
        &store,
        "GET\r\nPING\r\n",
        "-ERR wrong number of arguments for 'get' command\r\n+PONG\r\n",
    );
}

test "session: empty inline command keeps the connection usable" {
    var store = newStore();
    defer store.deinit();

    try expectSession(&store, "\r\nPING\r\n", "-ERR empty command\r\n+PONG\r\n");
}

test "session: command names are case-insensitive in RESP" {
    var store = newStore();
    defer store.deinit();

    try expectSession(
        &store,
        "*3\r\n$3\r\nsEt\r\n$1\r\nk\r\n$1\r\nv\r\n*2\r\n$3\r\ngEt\r\n$1\r\nk\r\n",
        "+OK\r\n$1\r\nv\r\n",
    );
}

test "session: pipelined commands are answered in order" {
    var store = newStore();
    defer store.deinit();

    try expectSession(
        &store,
        "*1\r\n$4\r\nPING\r\n" ++
            "*3\r\n$3\r\nSET\r\n$1\r\na\r\n$1\r\n1\r\n" ++
            "*2\r\n$3\r\nGET\r\n$1\r\na\r\n",
        "+PONG\r\n+OK\r\n$1\r\n1\r\n",
    );
}
