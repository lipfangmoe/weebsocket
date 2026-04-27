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

/// Sends a close request to the server. Returns true if the connection is still open, so the client can drain remaining messages.
pub fn deinitAndFlush(self: *Connection, payload: ?ClosePayload) bool {
    if (payload) |payload_nn| {
        if (payload_nn.reason.len > 123) {
            std.debug.panic("ClosePayload reason may not be longer than 123 bytes. (len={})", .{payload_nn.reason.len});
        }
        var buf: [200]u8 = undefined;
        var message_writer: ws.SingleFrameMessageWriter = .initControl(self.writer(), payload_nn.reason.len + 2, .close, .{ .rng = self.rng }, &buf);
        if (!payload_nn.status.isSendable()) {
            std.debug.panic("cannot send status {} over the wire", .{payload_nn.status});
        }
        message_writer.interface.writeInt(u16, @intFromEnum(payload_nn.status), .big) catch {
            const err = message_writer.state.err;
            ws.log.err("error occurred while writing close status: {}", .{err});
            self.forceDeinit();
            return false;
        };
        message_writer.interface.writeAll(payload_nn.reason) catch {
            const err = message_writer.state.err;
            ws.log.err("error occurred while writing close reason: {}", .{err});
            self.forceDeinit();
            return false;
        };
        message_writer.interface.flush() catch {
            const err = message_writer.state.err;
            ws.log.err("error occurred while writing close reason: {}", .{err});
            self.forceDeinit();
            return false;
        };
    } else {
        var buf: [50]u8 = undefined;
        var control_message_writer: ws.SingleFrameMessageWriter = .initControl(self.writer(), 2, .close, .{ .rng = self.rng }, &buf);
        control_message_writer.interface.writeInt(u16, @intFromEnum(ws.message.ControlFrameHandler.CloseStatus.normal), .big) catch {
            std.debug.assert(control_message_writer.state == .err);

            ws.log.err("error occurred writing close reason: {}", .{control_message_writer.state.err});
            self.forceDeinit();
            return false;
        };
        control_message_writer.interface.flush() catch {
            std.debug.assert(control_message_writer.state == .err);

            ws.log.err("error occurred writing close reason: {}", .{control_message_writer.state.err});
            self.forceDeinit();
            return false;
        };
    }

    self.self_closing = true;

    return true;
}

/// Sends a close request to the server, and waits for a close response.
/// `payload` is an optional byte sequence to send to the server.
pub fn deinit(self: *Connection, io: std.Io, payload: ?ClosePayload) void {
    if (self.self_closing) {
        return;
    }

    const open = self.deinitAndFlush(payload);

    if (open) {
        const SelectT = union(enum) {
            timeout: error{Canceled}!void,
            drain: void,
        };
        var buf: [2]SelectT = undefined;
        var select: std.Io.Select(SelectT) = .init(io, &buf);
        select.async(.timeout, std.Io.sleep, .{ io, .fromSeconds(1), .awake });
        select.async(.drain, drainRemainingMessages, .{self});
        _ = select.await() catch {};
        _ = select.cancelDiscard();
        self.forceDeinit();
    }
}

pub fn drainRemainingMessages(self: *Connection) void {
    var buf: [8000]u8 = undefined;
    while (true) {
        var msg = self.receiveMessage(&buf);
        _ = msg.interface.discardRemaining() catch break;
    }
}

/// It is highly recommended to call `deinit()` instead, but this function allows to terminate the HTTP connection immediately.
///
/// Frees all resources related to this connection, and immediately closes the TCP connection.
pub fn forceDeinit(self: *Connection) void {
    self.self_closing = true;

    // tell the stdlib that this connection should be closed rather than returned to a connection pool
    if (self.http_request.connection) |conn| {
        conn.closing = true;
    }

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
    EndOfStream,
    Unknown,
} || ws.message.reader2.MessageReader.Error;
pub const ReceiveMessageAllocError = error{StreamTooLong} || ReceiveMessageError || std.mem.Allocator.Error;
pub const SendMessageError = error{
    ServerClosed,
    EndOfStream,
} || ws.message.writer.Error;

/// Waits to receive a message, returns a reader for the payload
pub fn receiveMessage(self: *Connection, buf: []u8) ws.MessageReader {
    return .init(self.reader(), .default(.{ .rng = self.rng }, self.writer()), buf);
}

/// Waits to receive a message, returns the payload content
pub fn receiveMessageAlloc(self: *Connection, allocator: std.mem.Allocator, limit: std.Io.Limit) ReceiveMessageAllocError![]u8 {
    var buf: [8000]u8 = undefined;
    const message_reader: ws.MessageReader = .init(self.reader(), .default(.{ .rng = self.rng }, self.writer()), &buf);
    return message_reader.interface.allocRemaining(allocator, limit) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ReadFailed => message_reader.state.err,
        error.StreamTooLong => error.StreamTooLong,
    };
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

pub fn connectionReaderError(self: *const Connection) ?std.http.Client.Connection.ReadError {
    return self.http_request.connection.?.getReadError();
}

pub fn connectionWriterError(self: *const Connection) ?std.http.Client.Connection.ReadError {
    return self.http_request.connection.?.getReadError();
}

pub const ClosePayload = struct {
    status: ws.message.ControlFrameHandler.CloseStatus,
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
    pub fn initWithStatus(status: ws.message.ControlFrameHandler.CloseStatus, reason: []const u8) ClosePayload {
        return .{
            .status = status,
            .reason = reason,
        };
    }
};
