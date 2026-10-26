//! RESP2 wire codec.
//!
//! `readCommand` parses one command and maps it to an `engine.Command`.
//! `writeReply` encodes an `engine.Reply` as RESP2 bytes.
//!
//! Parsed argument bytes are owned by `ParsedCommand`; call `deinit` after the
//! command has been executed and its reply encoded.

const std = @import("std");
const engine = @import("engine.zig");

/// Maximum length of a RESP control line or an inline command.
pub const max_line_len: usize = 4096;

/// Maximum size of a single bulk-string argument.
pub const max_bulk_len: usize = 1024 * 1024;

/// Maximum number of arguments in one command.
pub const max_args: usize = 128;

/// Maximum total declared size of one command.
///
/// `max_args * max_bulk_len` alone would allow roughly 128 MiB, so the total
/// command size is bounded independently.
pub const max_command_len: usize = 8 * 1024 * 1024;

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

const ArgList = std.ArrayList([]const u8);

/// Parses one command at a time from a reader.
const Parser = struct {
    r: *std.Io.Reader,
    allocator: std.mem.Allocator,
    args: ArgList = .empty,

    fn init(r: *std.Io.Reader, allocator: std.mem.Allocator) Parser {
        return .{ .r = r, .allocator = allocator };
    }

    fn deinit(self: *Parser) void {
        for (self.args.items) |arg| self.allocator.free(arg);
        self.args.deinit(self.allocator);
        self.args = .empty;
    }

    /// Parses one command, or returns `null` when the stream ends cleanly
    /// between commands.
    fn next(self: *Parser) Error!?engine.Command {
        const first = self.r.peekByte() catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.EndOfStream => return null,
        };

        if (first == '*') {
            try self.parseRespArray();
        } else {
            try self.parseInline();
        }

        return self.mapCommand();
    }

    /// Maps parsed arguments to an engine command.
    ///
    /// Command-level errors (unknown command, wrong arity, empty command) are
    /// represented as `Command.invalid`, not as Zig errors.
    fn mapCommand(self: *const Parser) engine.Command {
        const args = self.args.items;

        if (args.len == 0) return .{ .invalid = .empty_command };

        const cmd = args[0];

        if (std.ascii.eqlIgnoreCase(cmd, "ping")) {
            if (args.len == 1) return .{ .ping = .{} };
            if (args.len == 2) return .{ .ping = .{ .message = args[1] } };
            return .{ .invalid = .{ .wrong_arity = "ping" } };
        }

        if (std.ascii.eqlIgnoreCase(cmd, "set")) {
            if (args.len != 3) return .{ .invalid = .{ .wrong_arity = "set" } };
            return .{ .set = .{ .key = args[1], .value = args[2] } };
        }

        if (std.ascii.eqlIgnoreCase(cmd, "get")) {
            if (args.len != 2) return .{ .invalid = .{ .wrong_arity = "get" } };
            return .{ .get = .{ .key = args[1] } };
        }

        if (std.ascii.eqlIgnoreCase(cmd, "del")) {
            if (args.len < 2) return .{ .invalid = .{ .wrong_arity = "del" } };
            return .{ .del = .{ .keys = args[1..] } };
        }

        if (std.ascii.eqlIgnoreCase(cmd, "exists")) {
            if (args.len < 2) return .{ .invalid = .{ .wrong_arity = "exists" } };
            return .{ .exists = .{ .keys = args[1..] } };
        }

        return .{ .invalid = .{ .unknown_command = cmd } };
    }

    /// Parses a whitespace-separated inline command.
    fn parseInline(self: *Parser) Error!void {
        const line = try self.readLine();

        var tokens = std.mem.tokenizeScalar(u8, line, ' ');
        while (tokens.next()) |token| {
            if (self.args.items.len == max_args) return error.BadProtocol;

            // Token slices point into the reader buffer, so own a copy before
            // the next read can refill that buffer.
            const owned = try self.allocator.dupe(u8, token);
            errdefer self.allocator.free(owned);
            try self.args.append(self.allocator, owned);
        }
    }

    /// Parses a RESP array of bulk strings.
    fn parseRespArray(self: *Parser) Error!void {
        const header = try self.readLine();
        if (header.len == 0 or header[0] != '*') return error.BadProtocol;

        const argc = try self.parseSize(header[1..], max_args);
        if (argc == 0) return error.BadProtocol;

        try self.args.ensureTotalCapacity(self.allocator, argc);

        var total_declared: usize = 0;

        for (0..argc) |_| {
            const length_line = try self.readLine();
            if (length_line.len == 0 or length_line[0] != '$') return error.BadProtocol;

            const len = try self.parseSize(length_line[1..], max_bulk_len);

            total_declared += len;
            if (total_declared > max_command_len) return error.BadProtocol;

            const body = try self.allocator.alloc(u8, len);
            errdefer self.allocator.free(body);

            self.r.readSliceAll(body) catch |err| switch (err) {
                error.EndOfStream => return error.Truncated,
                error.ReadFailed => return error.ReadFailed,
            };

            try self.expectCrlf();
            try self.args.append(self.allocator, body);
        }
    }

    /// Reads one line, excluding the trailing CRLF.
    ///
    /// The returned slice points into the reader's buffer and is only valid
    /// until the next read.
    fn readLine(self: *Parser) Error![]const u8 {
        const inclusive = self.r.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return error.Truncated,
            error.StreamTooLong => return error.BadProtocol,
            error.ReadFailed => return error.ReadFailed,
        };

        const line = inclusive[0 .. inclusive.len - 1];
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

/// One parsed command plus the argument storage it borrows from.
pub const ParsedCommand = struct {
    command: engine.Command,
    /// Heap-backed argument list. Keeping the list on the heap makes the
    /// slices stored in `command` stable after this struct is returned.
    args: ArgList = .empty,
    allocator: std.mem.Allocator,

    /// Releases storage owned by this parsed command.
    pub fn deinit(self: *ParsedCommand) void {
        for (self.args.items) |arg| self.allocator.free(arg);
        self.args.deinit(self.allocator);
        self.args = .empty;
    }
};

/// Reads exactly one command from `r`.
///
/// Returns `error.EndOfStream` when the peer closed the connection between
/// commands. Framing errors leave the stream in an undefined position; the
/// caller must close the connection.
pub fn readCommand(allocator: std.mem.Allocator, r: *std.Io.Reader) Error!ParsedCommand {
    var parser: Parser = .init(r, allocator);
    errdefer parser.deinit();

    const command = (try parser.next()) orelse return error.EndOfStream;

    return .{
        .command = command,
        .args = parser.args,
        .allocator = allocator,
    };
}

/// Writes one RESP2 reply. The writer is not flushed.
pub fn writeReply(w: *std.Io.Writer, reply: engine.Reply) Error!void {
    switch (reply) {
        .pong => try w.writeAll("+PONG\r\n"),
        .ok => try w.writeAll("+OK\r\n"),
        .nil => try w.writeAll("$-1\r\n"),
        .bulk => |bytes| {
            try w.print("${d}\r\n", .{bytes.len});
            try w.writeAll(bytes);
            try w.writeAll("\r\n");
        },
        .int => |n| {
            try w.print(":{d}\r\n", .{n});
        },
        .err => |err| switch (err) {
            .empty_command => try w.writeAll("-ERR empty command\r\n"),

            .unknown_command => |name| try w.print(
                "-ERR unknown command '{s}'\r\n",
                .{name},
            ),

            .wrong_arity => |name| try w.print(
                "-ERR wrong number of arguments for '{s}' command\r\n",
                .{name},
            ),
        },
    }
}
