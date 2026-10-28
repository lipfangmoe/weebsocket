const std = @import("std");
const ws = @import("../root.zig");
const frame = ws.message.frame;

http_request: std.http.Client.Request,
control_frame_handler: ws.message.ControlFrameHeaderHandlerFn,
amt_read_from_request: usize = 0,
peer_closing: bool = false,
self_closing: bool = false,

const Connection = @This();

pub fn init(http_request: std.http.Client.Request) Connection {
    return Connection{
        .http_request = http_request,
        .control_frame_handler = &ws.message.defaultControlFrameHandler,
    };
}

/// Flushes all data from the connection and closes the websocket.
pub fn fail(self: *Connection, payload: ?ClosePayload) void {
    std.log.info("failing the websocket connection", .{});
    self.deinit(payload);
}

/// Sends a close request to the server, and returns an iterator of the remaining messages that the server sends.
pub fn deinitAndFlush(self: *Connection, payload: ?ClosePayload) FlushMessagesAfterCloseIterator {
    if (payload) |payload_nn| {
        std.log.debug("deinitAndFlush({{ .status=.{s}, .payload='{s}' }})", .{ @tagName(payload_nn.status), payload_nn.reason.constSlice() });
        var message_writer = ws.message.AnyMessageWriter.initControl(self.writer(), payload_nn.reason.len + 2, .close, .random_mask) catch |err| {
            std.log.err("error while writing close header: {}", .{err});
            self.forceDeinit();
            return FlushMessagesAfterCloseIterator{ .conn = null };
        };
        if (!payload_nn.status.isSendable()) {
            std.debug.panic("cannot send status {} over the wire", .{payload_nn.status});
        }
        message_writer.payloadWriter().writeInt(u16, @intFromEnum(payload_nn.status), .big) catch |err| {
            std.log.err("error occurred while writing close status: {}", .{err});
            self.forceDeinit();
            return FlushMessagesAfterCloseIterator{ .conn = null };
        };
        message_writer.payloadWriter().writeAll(payload_nn.reason.constSlice()) catch |err| {
            std.log.err("error occurred while writing close reason: {}", .{err});
            self.forceDeinit();
            return FlushMessagesAfterCloseIterator{ .conn = null };
        };
    } else {
        std.log.debug("deinitAndFlush(null)", .{});
        _ = ws.message.AnyMessageWriter.initControl(self.writer(), 0, .close, .random_mask) catch |err| {
            std.log.err("error while writing close header: {}", .{err});
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

    std.log.info("closing the websocket connection", .{});
    _ = self.deinitAndFlush(payload);
    _ = self.http_request.connection.?.reader().any().discard() catch |err| {
        std.log.err("error while discarding stream after WS failed: {}", .{err});
    };

    self.forceDeinit();
}

/// It is highly recommended to call `deinit()` instead, but this function allows to terminate the HTTP connection immediately.
///
/// Frees all resources related to this connection, and immediately closes the TCP connection.
pub fn forceDeinit(self: *Connection) void {
    self.self_closing = true;
    self.http_request.deinit();
}

/// Sends a PING control message to the server. The server should respond with PONG soon after. In order to receive the PONG, you must
/// have supplied the Connection object with a Control Frame Handler.
pub fn ping(self: *Connection, payload: ?std.BoundedArray(u8, 125)) !void {
    const payload_nn = payload orelse std.BoundedArray(u8, 125){};
    var message_writer = try ws.message.AnyMessageWriter.initControl(self.writer(), payload_nn.len, .ping, .random_mask);
    try message_writer.payloadWriter().writeAll(payload_nn.slice());
}

pub const ReadMessageError = error{
    ServerClosed,
    InvalidMessage,
    EndOfStream,
    Unknown,
};
pub const WriteMessageError = error{
    ServerClosed,
    EndOfStream,
    Unknown,
};

pub fn readMessage(self: *Connection) ReadMessageError!ws.MessageReader {
    std.log.debug("BEGIN readMessage()", .{});
    const msg = ws.MessageReader.readFrom(self.reader(), self.control_frame_handler, self.writer()) catch |err| {
        return switch (err) {
            error.ReceivedCloseFrame => {
                self.peer_closing = true;
                return error.ServerClosed;
            },
            error.InvalidMessage => {
                self.fail(ClosePayload.initWithStatus(.protocol_error, "invalid message received"));
                return error.InvalidMessage;
            },
            error.EndOfStream => error.EndOfStream,
            else => {
                std.log.err("internal error: {}", .{err});
                return error.Unknown;
            },
        };
    };
    std.log.debug("END   readMessage()", .{});
    return msg;
}

/// Prints some bytes as a websocket message.
pub fn printMessage(self: *Connection, msg_type: ws.message.Type, comptime fmt: []const u8, args: anytype) !void {
    std.log.debug("BEGIN printMessage({}, {s})", .{ msg_type, fmt });

    const len = std.fmt.count(fmt, args);

    var message_writer = try self.writeMessageStream(msg_type, len);
    try std.fmt.format(try message_writer.payloadWriter(), fmt, args);

    std.log.debug("END   printMessage({}, {s})", .{ msg_type, fmt });
}

/// Writes some bytes as a websocket message.
pub fn writeMessage(self: *Connection, msg_type: ws.message.Type, message: []const u8) WriteMessageError!void {
    std.log.debug("BEGIN writeMessage({}, {s})", .{ msg_type, message });

    var message_writer = try self.writeMessageStream(msg_type, message.len);
    message_writer.payloadWriter().writeAll(message) catch |err| return switch (err) {
        error.EndOfStream => error.EndOfStream,
        else => {
            std.log.err("internal error: {}", .{err});
            return error.Unknown;
        },
    };

    std.log.debug("END   writeMessage({}, {s})", .{ msg_type, message });
}

/// Writes a stream of bytes as a websocket message.
pub fn writeMessageStream(self: *Connection, msg_type: ws.message.Type, length: usize) WriteMessageError!ws.message.SingleFrameMessageWriter {
    if (self.self_closing) {
        std.debug.panic("Trying to write message after closing self", .{});
    }
    return ws.MessageWriter.init(self.writer(), length, msg_type, .random_mask) catch |err| return switch (err) {
        error.EndOfStream => error.EndOfStream,
        else => error.Unknown,
    };
}

/// Creates a MessageWriter, which writes a Websocket Frame Header, and then
/// returns a Writer which can be used to write the websocket payload.
///
/// Each call to `write` will be written in its entirety to a new websocket frame. It is highly recommended
/// to wrap the returned writer in a `std.io.BufferedWriter` in order to prevent excessive websocket frame headers.
///
/// Also, you must call `.close()` on the MessageWriter when you are finished writing the message.
pub fn writeMessageStreamUnknownLength(self: *Connection, msg_type: ws.message.Type) ws.message.MultiFrameMessageWriter {
    if (self.self_closing) {
        std.debug.panic("Trying to write message after closing self", .{});
    }
    return ws.MessageWriter.initUnknownLength(self.writer(), msg_type, .random_mask);
}

fn read(self_erased: *const anyopaque, bytes: []u8) anyerror!usize {
    var self: *Connection = @constCast(@alignCast(@ptrCast(self_erased)));
    const n = try self.http_request.connection.?.read(bytes);
    std.log.debug("read(len: {}): {}", .{ n, fmtCompact(bytes[0..n]) });
    return n;
}
fn write(self_erased: *const anyopaque, bytes: []const u8) anyerror!usize {
    var self: *Connection = @constCast(@alignCast(@ptrCast(self_erased)));
    const n = try self.http_request.connection.?.write(bytes);
    std.log.debug("write(len: {}): {}", .{ n, fmtCompact(bytes[0..n]) });
    try self.http_request.connection.?.flush();
    return n;
}

// always read from buffered reader
fn reader(self: *Connection) std.io.AnyReader {
    return std.io.AnyReader{
        .context = @ptrCast(self),
        .readFn = read,
    };
}

// always write to unbuffered writer because otherwise we don't know when we need to flush
fn writer(self: *Connection) std.io.AnyWriter {
    return std.io.AnyWriter{
        .context = @ptrCast(self),
        .writeFn = write,
    };
}

pub const ClosePayload = struct {
    status: CloseStatus,
    reason: std.BoundedArray(u8, 123),

    /// Max size for reason is 123 bytes.
    pub fn init(reason: []const u8) ClosePayload {
        return .{
            .status = .normal,
            .reason = std.BoundedArray(u8, 123).fromSlice(reason) catch unreachable,
        };
    }

    /// Max size for reason is 123 bytes.
    pub fn initWithStatus(status: CloseStatus, reason: []const u8) ClosePayload {
        return .{
            .status = status,
            .reason = std.BoundedArray(u8, 123).fromSlice(reason) catch unreachable,
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

    pub fn next(self: *FlushMessagesAfterCloseIterator) !?ws.message.AnyMessageReader {
        if (self.conn) |conn| {
            return conn.readMessage() catch |err| {
                switch (err) {
                    error.ServerClosed => return null,
                    error.InvalidMessage => return null,
                    else => return err,
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
