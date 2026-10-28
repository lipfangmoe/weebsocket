const std = @import("std");
const ws = @import("../root.zig");
const frame = ws.message.frame;

rng: std.Random,
http_request: std.http.Client.Request,
amt_read_from_request: usize = 0,
peer_closing: bool = false,
self_closing: bool = false,

const Connection = @This();

pub fn init(http_request: std.http.Client.Request, rng: std.Random) Connection {
    return .{
        .rng = rng,
        .http_request = http_request,
    };
}

/// Flushes all data from the connection and closes the websocket.
pub fn fail(self: *Connection, payload: ?ClosePayload) void {
    ws.log.info("failing the websocket connection", .{});
    self.deinit(payload);
}

/// Sends a close request to the server, and returns an iterator of the remaining messages that the server sends.
pub fn deinitAndFlush(self: *Connection, payload: ?ClosePayload) FlushMessagesAfterCloseIterator {
    if (payload) |payload_nn| {
        if (payload_nn.reason.len > 123) {
            std.debug.panic("ClosePayload reason may not be longer than 123 bytes (len={})", .{payload_nn.reason.len});
        }
        ws.log.debug("deinitAndFlush({{ .status=.{s}, .payload='{s}' }})", .{ @tagName(payload_nn.status), payload_nn.reason });
        var buf: [200]u8 = undefined;
        var message_writer: ws.message.SingleFrameMessageWriter = .initControl(self.writer(), payload_nn.reason.len + 2, .close, .{ .rng = self.rng }, &buf);
        if (!payload_nn.status.isSendable()) {
            std.debug.panic("cannot send status {} over the wire", .{payload_nn.status});
        }
        message_writer.interface.writeInt(u16, @intFromEnum(payload_nn.status), .big) catch {
            const err = message_writer.state.err;
            ws.log.err("error occurred while writing close status: {}", .{err});
            self.forceDeinit();
            return FlushMessagesAfterCloseIterator{ .conn = null };
        };
        message_writer.interface.writeAll(payload_nn.reason) catch {
            const err = message_writer.state.err;
            ws.log.err("error occurred while writing close reason: {}", .{err});
            self.forceDeinit();
            return FlushMessagesAfterCloseIterator{ .conn = null };
        };
        message_writer.interface.flush() catch {
            const err = message_writer.state.err;
            ws.log.err("error occurred while writing close reason: {}", .{err});
            self.forceDeinit();
            return FlushMessagesAfterCloseIterator{ .conn = null };
        };
    } else {
        ws.log.debug("deinitAndFlush(null)", .{});
        var buf: [200]u8 = undefined;
        var message_writer: ws.message.SingleFrameMessageWriter = .initControl(self.writer(), 0, .close, .{ .rng = self.rng }, &buf);
        message_writer.interface.flush() catch {
            const err = message_writer.state.err;
            ws.log.err("error occurred while writing close header: {}", .{err});
            self.forceDeinit();
            return FlushMessagesAfterCloseIterator{ .conn = null };
        };
    }

    self.self_closing = true;

    return FlushMessagesAfterCloseIterator{ .conn = self };
}

/// Sends a close request to the server, and waits for a close response. `payload` is an optional byte sequence to send to the server.
pub fn deinit(self: *Connection, payload: ?ClosePayload) void {
    if (self.self_closing) {
        return;
    }

    ws.log.info("closing the websocket connection", .{});
    _ = self.deinitAndFlush(payload);
    self.forceDeinit();
}

/// It is highly recommended to call `deinit()` instead, but this function allows to terminate the HTTP connection immediately.
///
/// Frees all resources related to this connection, and immediately closes the TCP connection.
pub fn forceDeinit(self: *Connection) void {
    self.self_closing = true;

    // tell the stdlib that this connection should be closed rather than returned to a connection pool
    self.http_request.connection.?.closing = true;

    self.http_request.deinit();
}

/// Sends a PING control message to the server. The server should respond with PONG soon after. In order to receive the PONG, you must
/// have supplied the Connection object with a Control Frame Handler.
///
/// `payload` should contain at most 125 bytes
pub fn ping(self: *Connection, payload: ?[]u8) !void {
    const payload_nn = payload orelse &.{};
    std.debug.assert(payload_nn.len <= 125);

    var buf: [200]u8 = undefined;
    var message_writer = try ws.message.SingleFrameMessageWriter.initControl(self.writer(), payload_nn.len, .ping, .rng, &buf);
    try message_writer.interface.writeAll(payload_nn);
    try message_writer.interface.flush();
}

pub const ReceiveMessageError = error{
    ServerClosed,
    InvalidMessage,
    EndOfStream,
    Unknown,
};
pub const SendMessageError = error{
    ServerClosed,
    EndOfStream,
} || ws.message.writer2.Error;

/// Waits to receive a message.
pub fn receiveMessage(self: *Connection) ws.MessageReader {
    var buf: [8000]u8 = undefined;
    return .init(self.reader(), .default(.{ .rng = self.rng }, self.writer()), &buf);
}

/// Prints some bytes as a websocket message.
pub fn printMessage(self: *Connection, msg_type: ws.message.Type, comptime fmt: []const u8, args: anytype) SendMessageError!void {
    const len = std.fmt.count(fmt, args);

    var buf: [8000]u8 = undefined;
    var message_writer = self.initMessageWriter(msg_type, &buf, len);
    message_writer.interface.print(fmt, args) catch {
        return message_writer.state.err;
    };
}

/// Writes some bytes as a websocket message.
pub fn sendMessage(self: *Connection, msg_type: ws.message.Type, message: []const u8) SendMessageError!void {
    var buf: [8000]u8 = undefined;
    var message_writer = self.initMessageWriter(msg_type, &buf, message.len);
    message_writer.interface.writeAll(message) catch {
        return message_writer.state.err;
    };
    message_writer.interface.flush() catch {
        return message_writer.state.err;
    };
}

/// Creates writer which encodes the contents as a websocket payload and writes it to the underlying writer. Errors are accessible via `writer.state.err`
///
/// Don't forget to flush!
pub fn initMessageWriter(self: *Connection, msg_type: ws.message.Type, buf: []u8, message_length: usize) ws.message.SingleFrameMessageWriter {
    if (self.self_closing) {
        std.debug.panic("Trying to write message after closing self", .{});
    }
    return .init(self.writer(), message_length, msg_type, .{ .rng = self.rng }, buf);
}

/// Creates a MessageWriter, which writes a Websocket Frame Header, and then
/// returns a Writer which can be used to write the websocket payload.
///
/// This function should only be used when the length may be quite long, and calculating
/// the length of the buffer ahead-of-time would be difficult.
/// If possible, it's recommended to instead use self.sendMessage() or self.createMessageStream().
pub fn createMessageStreamUnknownLength(self: *Connection, msg_type: ws.message.Type, buf: []u8) ws.message.MultiFrameMessageWriter {
    if (self.self_closing) {
        std.debug.panic("Trying to write message after closing self", .{});
    }
    return .init(self.writer(), msg_type, .{ .rng = self.rng }, buf);
}

fn reader(self: *Connection) *std.Io.Reader {
    return self.http_request.connection.?.reader();
}

fn writer(self: *Connection) *std.Io.Writer {
    return self.http_request.connection.?.writer();
}

pub const ClosePayload = struct {
    status: CloseStatus,
    /// Max size is 123 bytes
    reason: []const u8,

    /// Max size for reason is 123 bytes.
    pub fn init(reason: []const u8) ClosePayload {
        return .{
            .status = .normal,
            .reason = reason,
        };
    }

    /// Max size for reason is 123 bytes.
    pub fn initWithStatus(status: CloseStatus, reason: []const u8) ClosePayload {
        return .{
            .status = status,
            .reason = reason,
        };
    }
};

pub const CloseStatus = enum(u16) {
    normal = 1000,
    going_away = 1001,
    protocol_error = 1002,
    cannot_accept = 1003,
    inconsistent_format = 1007,
    policy_violation = 1008,
    message_too_large = 1009,
    expected_extension = 1010,

    // not sendable over the wire
    no_status_code_present = 1005,
    closed_abnormally = 1006,
    invalid_tls_signature = 1015,
    _,

    pub fn isSendable(self: CloseStatus) bool {
        return switch (self) {
            .no_status_code_present,
            .closed_abnormally,
            .invalid_tls_signature,
            => false,

            .normal,
            .going_away,
            .protocol_error,
            .cannot_accept,
            .inconsistent_format,
            .policy_violation,
            .message_too_large,
            .expected_extension,
            => true,

            else => switch (@intFromEnum(self)) {
                0...999 => false,
                1000...2999 => false,
                3000...4999 => true,
                else => false,
            },
        };
    }
};

/// An iterator for messages sent after the Closing Handshake has started. Should continue to call `next()` until an error is encountered,
/// one should not stop calling next if `null` is encountered.
pub const FlushMessagesAfterCloseIterator = struct {
    conn: ?*Connection,

    pub fn next(self: *FlushMessagesAfterCloseIterator) error{ EndOfStream, Unknown }!?ws.message.MessageReader {
        if (self.conn) |conn| {
            return conn.receiveMessage() catch |err| {
                switch (err) {
                    error.ServerClosed => return null,
                    error.InvalidMessage => return null,
                    else => |errr| return errr,
                }
            };
        }
        return null;
    }
};

fn fmtCompactFn(data: []const u8, comptime _: []const u8, _: std.fmt.FormatOptions, fmt_writer: anytype) !void {
    if (data.len == 0) {
        return;
    }
    if (std.unicode.utf8ValidateSlice(data)) {
        try fmt_writer.print("{s}", .{data});
        return;
    }

    var char_count: usize = 1;
    var last_char: u8 = data[0];
    for (data[1..]) |char| {
        if (char == last_char) {
            char_count += 1;
            continue;
        }
        if (char_count == 1) {
            try fmt_writer.print("{x:0>2}, ", .{last_char});
        } else {
            try fmt_writer.print("{x:0>2}**{}, ", .{ last_char, char_count });
        }
        last_char = char;
        char_count = 1;
    }
    if (char_count == 1) {
        try fmt_writer.print("{x:0>2}", .{last_char});
    } else {
        try fmt_writer.print("{x:0>2}**{}", .{ last_char, char_count });
    }
}

fn fmtCompact(data: []const u8) std.fmt.Formatter(fmtCompactFn) {
    return .{ .data = data };
}
