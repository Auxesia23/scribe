//! Protocol-level tests for `protocol.zig`.
//!
//! The tests use in-memory readers and writers, so they do not require a
//! network socket.

const std = @import("std");
const Store = @import("store.zig").Store;
const protocol = @import("protocol.zig");

const testing = std.testing;

/// Executes one command and compares the complete reply.
fn expectReply(store: *Store, input: []const u8, expected: []const u8) !void {
    var r: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try protocol.execute(store, testing.allocator, &r, &out.writer);
    try testing.expectEqualStrings(expected, out.written());
}

/// Executes every command in `input` and compares the concatenated replies.
fn expectSession(store: *Store, input: []const u8, expected: []const u8) !void {
    var r: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    while (true) {
        protocol.execute(store, testing.allocator, &r, &out.writer) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
    }

    try testing.expectEqualStrings(expected, out.written());
}

/// Executes one command and expects a specific protocol error.
fn expectProtocolError(store: *Store, input: []const u8, expected: anyerror) !void {
    var r: std.Io.Reader = .fixed(input);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try testing.expectError(expected, protocol.execute(store, testing.allocator, &r, &out.writer));
}

// PING

test "PING: inline command" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectReply(&store, "PING\r\n", "+PONG\r\n");
}

test "PING: RESP array" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectReply(&store, "*1\r\n$4\r\nPING\r\n", "+PONG\r\n");
}

test "PING: case-insensitive command name" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectReply(&store, "pInG\r\n", "+PONG\r\n");
}

test "PING: message is echoed as a bulk string" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectReply(&store, "PING hello\r\n", "$5\r\nhello\r\n");
    try expectReply(&store, "*2\r\n$4\r\nPING\r\n$5\r\nhello\r\n", "$5\r\nhello\r\n");
}

test "PING: wrong arity is an error reply" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectReply(&store, "PING a b\r\n", "-ERR wrong number of arguments for 'ping' command\r\n");
}

// SET and GET

test "SET/GET: round trip via RESP" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectSession(
        &store,
        "*3\r\n$3\r\nSET\r\n$4\r\nname\r\n$4\r\njohn\r\n" ++
            "*2\r\n$3\r\nGET\r\n$4\r\nname\r\n",
        "+OK\r\n$4\r\njohn\r\n",
    );
}

test "SET/GET: round trip via inline commands" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectSession(&store, "SET name john\r\nGET name\r\n", "+OK\r\n$4\r\njohn\r\n");
}

test "GET: missing key returns nil bulk" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectReply(&store, "GET nope\r\n", "$-1\r\n");
}

test "SET: overwrite is visible to the next GET" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectSession(
        &store,
        "SET k v1\r\nSET k longer-value\r\nGET k\r\n",
        "+OK\r\n+OK\r\n$12\r\nlonger-value\r\n",
    );
}

test "SET: empty value is valid" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectSession(
        &store,
        "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$0\r\n\r\n" ++
            "*2\r\n$3\r\nGET\r\n$1\r\nk\r\n",
        "+OK\r\n$0\r\n\r\n",
    );
}

test "SET/GET: value is binary-safe" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const value = "\x00ab\r\n\xff"; // 6 bytes
    const input = "*3\r\n$3\r\nSET\r\n$3\r\nbin\r\n$6\r\n" ++ value ++ "\r\n" ++
        "*2\r\n$3\r\nGET\r\n$3\r\nbin\r\n";
    const expected = "+OK\r\n$6\r\n" ++ value ++ "\r\n";

    try expectSession(&store, input, expected);
}

// DEL and EXISTS

test "DEL: reports whether the key existed" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectSession(
        &store,
        "SET a 1\r\nSET b 2\r\nDEL a\r\nDEL a\r\nDEL b\r\nDEL b\r\n",
        "+OK\r\n+OK\r\n:1\r\n:0\r\n:1\r\n:0\r\n",
    );
}

test "DEL: multiple keys counts only the removed keys" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectSession(
        &store,
        "SET a 1\r\nSET b 2\r\nSET c 3\r\nDEL a b missing\r\nEXISTS a b c\r\n",
        "+OK\r\n+OK\r\n+OK\r\n:2\r\n:1\r\n",
    );
}

test "EXISTS: counts existing keys, duplicates count twice" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectSession(
        &store,
        "SET a 1\r\nEXISTS a\r\nEXISTS missing\r\nEXISTS a a missing\r\n",
        "+OK\r\n:1\r\n:0\r\n:2\r\n",
    );
}

test "DEL: missing argument is an arity error" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectReply(&store, "DEL\r\n", "-ERR wrong number of arguments for 'del' command\r\n");
}

test "EXISTS: missing argument is an arity error" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectReply(&store, "EXISTS\r\n", "-ERR wrong number of arguments for 'exists' command\r\n");
}

// Command parsing

test "SET: wrong arity variants" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectReply(&store, "SET k\r\n", "-ERR wrong number of arguments for 'set' command\r\n");
    try expectReply(&store, "SET k v extra\r\n", "-ERR wrong number of arguments for 'set' command\r\n");
}

test "GET: wrong arity" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectReply(&store, "GET k v\r\n", "-ERR wrong number of arguments for 'get' command\r\n");
}

test "unknown command: inline and RESP" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectReply(&store, "FLUSHALL\r\n", "-ERR unknown command 'FLUSHALL'\r\n");
    try expectReply(&store, "*1\r\n$4\r\nNOPE\r\n", "-ERR unknown command 'NOPE'\r\n");
}

test "command-level errors keep the session alive" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectSession(&store, "NOPE\r\nPING\r\n", "-ERR unknown command 'NOPE'\r\n+PONG\r\n");
}

test "empty inline command is an error reply" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectSession(&store, "\r\nPING\r\n", "-ERR empty command\r\n+PONG\r\n");
}

test "inline commands tolerate extra spaces" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectSession(&store, "SET   name   john\r\nGET   name\r\n", "+OK\r\n$4\r\njohn\r\n");
}

test "command names are case-insensitive in RESP" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectSession(
        &store,
        "*3\r\n$3\r\nsEt\r\n$1\r\nk\r\n$1\r\nv\r\n*2\r\n$3\r\ngEt\r\n$1\r\nk\r\n",
        "+OK\r\n$1\r\nv\r\n",
    );
}

// Store integration

test "protocol: commands mutate the store" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectReply(&store, "SET name john\r\n", "+OK\r\n");

    const value = store.get("name") orelse return error.MissingKey;
    try testing.expectEqualStrings("john", value);

    try expectReply(&store, "DEL name\r\n", ":1\r\n");
    try testing.expect(!store.contains("name"));
}

// Protocol errors

test "errors: clean EOF between commands is EndOfStream" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectProtocolError(&store, "", error.EndOfStream);
}

test "errors: EOF after a complete command is EndOfStream" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectSession(&store, "PING\r\n", "+PONG\r\n");
    try expectProtocolError(&store, "", error.EndOfStream);
}

test "errors: EOF while reading argc is Truncated" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectProtocolError(&store, "*2\r\n", error.Truncated);
}

test "errors: EOF while reading an argument header is Truncated" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectProtocolError(&store, "*2\r\n$4\r\nGET\r\n", error.Truncated);
}

test "errors: EOF in the middle of a bulk body is Truncated" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectProtocolError(&store, "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$5\r\nabc", error.Truncated);
}

test "errors: missing CRLF after a bulk body is BadProtocol" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectProtocolError(&store, "*1\r\n$4\r\nPINGxx", error.BadProtocol);
}

test "errors: non-bulk array element is BadProtocol" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectProtocolError(&store, "*1\r\nPING\r\n", error.BadProtocol);
}

test "errors: null bulk string as an argument is BadProtocol" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectProtocolError(&store, "*2\r\n$4\r\nGET\r\n$-1\r\n", error.BadProtocol);
}

test "errors: invalid argc values are BadProtocol" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectProtocolError(&store, "*0\r\n", error.BadProtocol);
    try expectProtocolError(&store, "*-1\r\n", error.BadProtocol);
    try expectProtocolError(&store, "*x\r\n", error.BadProtocol);
}

test "errors: missing '$' in the length line is BadProtocol" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    try expectProtocolError(&store, "*1\r\n$4PING\r\n", error.BadProtocol);
}

// Limits

test "limits: argc above max_args is BadProtocol" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    var buffer: [64]u8 = undefined;
    const input = try std.fmt.bufPrint(&buffer, "*{d}\r\n", .{protocol.max_args + 1});
    try expectProtocolError(&store, input, error.BadProtocol);
}

test "limits: bulk length above max_bulk_len is BadProtocol" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    var buffer: [64]u8 = undefined;
    const input = try std.fmt.bufPrint(
        &buffer,
        "*2\r\n$4\r\nGET\r\n${d}\r\n",
        .{protocol.max_bulk_len + 1},
    );
    try expectProtocolError(&store, input, error.BadProtocol);
}

test "limits: inline line above max_line_len is BadProtocol" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const long_line = try testing.allocator.alloc(u8, protocol.max_line_len + 2);
    defer testing.allocator.free(long_line);
    @memset(long_line[0..protocol.max_line_len], 'A');
    long_line[protocol.max_line_len] = '\r';
    long_line[protocol.max_line_len + 1] = '\n';

    try expectProtocolError(&store, long_line, error.BadProtocol);
}

// Argument ownership

test "RESP: arguments outlive reader buffer refills" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    var key_buffer: [64]u8 = undefined;
    @memset(key_buffer[0..], 'k');
    var value_buffer: [64]u8 = undefined;
    @memset(value_buffer[0..], 'v');

    const key: []const u8 = &key_buffer;
    const value: []const u8 = &value_buffer;

    const input = try std.fmt.allocPrint(
        testing.allocator,
        "*3\r\n$3\r\nSET\r\n${d}\r\n{s}\r\n${d}\r\n{s}\r\n",
        .{ key.len, key, value.len, value },
    );
    defer testing.allocator.free(input);

    var reader_buffer: [16]u8 = undefined;
    var chunked: std.testing.Reader = .init(&reader_buffer, &.{.{ .buffer = input }});
    chunked.artificial_limit = .limited(1);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try protocol.execute(&store, testing.allocator, &chunked.interface, &out.writer);

    try testing.expectEqualStrings("+OK\r\n", out.written());

    const stored = store.get(key) orelse return error.MissingKey;
    try testing.expectEqualSlices(u8, value, stored);
}
