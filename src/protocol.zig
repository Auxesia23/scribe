//! RESP2 command parsing and dispatch for a small key-value server.
//!
//! `execute` reads one command from an `std.Io.Reader`, executes it against a
//! `Store`, and writes the reply to an `std.Io.Writer`. It is transport
//! agnostic: the same code is used by unit tests and by the TCP server.

const std = @import("std");
const Store = @import("store.zig").Store;

/// Maximum length of a RESP control line or an inline command.
pub const max_line_len: usize = 4096;

/// Maximum size of a single bulk-string argument.
pub const max_bulk_len: usize = 1024 * 1024;

/// Maximum number of arguments in one command.
pub const max_args: usize = 128;

/// Errors returned by the protocol layer.
pub const Error = error{
    /// The peer closed the connection between commands.
    EndOfStream,
    /// The connection ended in the middle of a command frame.
    Truncated,
    /// The input is malformed or violates a protocol limit.
    BadProtocol,
    ReadFailed,
    WriteFailed,
    OutOfMemory,
};

/// Arguments of a single parsed command.
///
/// Owns one allocation per argument. Parsers fill `items[0..len]`; the caller
/// must call `deinit` after the command has been dispatched.
const Args = struct {
    gpa: std.mem.Allocator,
    items: [max_args][]u8 = undefined,
    len: usize = 0,

    fn init(gpa: std.mem.Allocator) Args {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *Args) void {
        for (self.items[0..self.len]) |item| self.gpa.free(item);
        self.len = 0;
    }

    fn slice(self: *const Args) []const []u8 {
        return self.items[0..self.len];
    }
};

/// Reads commands from a byte stream.
const Parser = struct {
    r: *std.Io.Reader,
    gpa: std.mem.Allocator,

    fn init(r: *std.Io.Reader, gpa: std.mem.Allocator) Parser {
        return .{ .r = r, .gpa = gpa };
    }

    /// Parses one command into `args`.
    ///
    /// Returns `false` when the stream ends cleanly between commands. On
    /// error, every argument already copied is released by the parser.
    fn next(self: *Parser, args: *Args) Error!bool {
        const first = self.r.peekByte() catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.EndOfStream => return false,
        };

        if (first == '*') {
            try self.parseRespArray(args);
        } else {
            try self.parseInline(args);
        }

        return true;
    }

    /// Parses a whitespace-separated inline command.
    fn parseInline(self: *Parser, args: *Args) Error!void {
        const line = try self.readLine();

        errdefer args.deinit();

        var tokens = std.mem.tokenizeScalar(u8, line, ' ');
        while (tokens.next()) |token| {
            if (args.len == max_args) return error.BadProtocol;

            const owned = try args.gpa.dupe(u8, token);
            args.items[args.len] = owned;
            args.len += 1;
        }
    }

    /// Parses a RESP array of bulk strings.
    fn parseRespArray(self: *Parser, args: *Args) Error!void {
        const header = try self.readLine();
        if (header.len == 0 or header[0] != '*') return error.BadProtocol;

        const argc = try self.parseSize(header[1..], max_args);
        if (argc == 0) return error.BadProtocol;

        errdefer args.deinit();

        for (0..argc) |_| {
            const length_line = try self.readLine();
            if (length_line.len == 0 or length_line[0] != '$') return error.BadProtocol;

            const len = try self.parseSize(length_line[1..], max_bulk_len);

            const body = try args.gpa.alloc(u8, len);
            args.items[args.len] = body;
            args.len += 1;

            self.r.readSliceAll(body) catch |err| switch (err) {
                error.EndOfStream => return error.Truncated,
                error.ReadFailed => return error.ReadFailed,
            };

            try self.expectCrlf();
        }
    }

    /// Reads one line, excluding the trailing CRLF.
    ///
    /// The returned slice points into the reader's buffer and is only valid
    /// until the next read.
    fn readLine(self: *Parser) Error![]const u8 {
        const maybe_line = self.r.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.BadProtocol,
            error.ReadFailed => return error.ReadFailed,
        };
        const line = maybe_line orelse return error.Truncated;

        if (line.len > max_line_len) return error.BadProtocol;

        return std.mem.trimEnd(u8, line, "\r");
    }

    /// Parses a decimal size and rejects values above `max`.
    fn parseSize(self: *Parser, line: []const u8, max: usize) Error!usize {
        _ = self;

        if (line.len == 0) return error.BadProtocol;

        const size = std.fmt.parseInt(usize, line, 10) catch return error.BadProtocol;
        if (size > max) return error.BadProtocol;

        return size;
    }

    /// Consumes the CRLF that terminates a bulk string body.
    fn expectCrlf(self: *Parser) Error!void {
        var buf: [2]u8 = undefined;

        self.r.readSliceAll(&buf) catch |err| switch (err) {
            error.EndOfStream => return error.Truncated,
            error.ReadFailed => return error.ReadFailed,
        };

        if (!std.mem.eql(u8, &buf, "\r\n")) return error.BadProtocol;
    }
};

/// Executes parsed commands and writes RESP replies.
const Dispatcher = struct {
    store: *Store,
    w: *std.Io.Writer,

    /// Dispatches one command. Command-level failures are reported as RESP
    /// errors; only I/O and framing errors are returned.
    fn dispatch(self: Dispatcher, args: []const []u8) Error!void {
        if (args.len == 0) return self.writeErr("empty command", .{});

        const cmd = args[0];

        if (std.ascii.eqlIgnoreCase(cmd, "ping")) {
            if (args.len == 1) {
                try self.w.writeAll("+PONG\r\n");
                return;
            }
            if (args.len == 2) return self.writeBulk(args[1]);
            return self.writeErr("wrong number of arguments for '{s}' command", .{"ping"});
        }

        if (std.ascii.eqlIgnoreCase(cmd, "set")) {
            if (args.len != 3) return self.writeErr("wrong number of arguments for '{s}' command", .{"set"});
            try self.store.set(args[1], args[2]);
            try self.w.writeAll("+OK\r\n");
            return;
        }

        if (std.ascii.eqlIgnoreCase(cmd, "get")) {
            if (args.len != 2) return self.writeErr("wrong number of arguments for '{s}' command", .{"get"});
            const value = self.store.get(args[1]) orelse {
                try self.w.writeAll("$-1\r\n");
                return;
            };
            return self.writeBulk(value);
        }

        if (std.ascii.eqlIgnoreCase(cmd, "del")) {
            if (args.len < 2) return self.writeErr("wrong number of arguments for '{s}' command", .{"del"});
            var removed: usize = 0;
            for (args[1..]) |key| {
                if (self.store.remove(key)) removed += 1;
            }
            return self.writeInt(removed);
        }

        if (std.ascii.eqlIgnoreCase(cmd, "exists")) {
            if (args.len < 2) return self.writeErr("wrong number of arguments for '{s}' command", .{"exists"});
            var found: usize = 0;
            for (args[1..]) |key| {
                if (self.store.contains(key)) found += 1;
            }
            return self.writeInt(found);
        }

        return self.writeErr("unknown command '{s}'", .{cmd});
    }

    /// Writes an `-ERR` reply.
    fn writeErr(self: Dispatcher, comptime fmt: []const u8, fmt_args: anytype) Error!void {
        try self.w.writeAll("-ERR ");
        try self.w.print(fmt, fmt_args);
        try self.w.writeAll("\r\n");
    }

    /// Writes a bulk-string reply.
    fn writeBulk(self: Dispatcher, bytes: []const u8) Error!void {
        try self.w.print("${d}\r\n", .{bytes.len});
        try self.w.writeAll(bytes);
        try self.w.writeAll("\r\n");
    }

    /// Writes an integer reply.
    fn writeInt(self: Dispatcher, n: usize) Error!void {
        try self.w.print(":{d}\r\n", .{n});
    }
};

/// Parses and executes exactly one command.
///
/// The writer is not flushed; the server flushes once per command.
pub fn execute(
    store: *Store,
    scratch: std.mem.Allocator,
    r: *std.Io.Reader,
    w: *std.Io.Writer,
) Error!void {
    var parser: Parser = .init(r, scratch);
    var args: Args = .init(scratch);

    if (!try parser.next(&args)) return error.EndOfStream;
    defer args.deinit();

    return (Dispatcher{ .store = store, .w = w }).dispatch(args.slice());
}
