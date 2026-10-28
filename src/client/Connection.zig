const std = @import("std");
const ws = @import("../root.zig");
const frame = ws.message.frame;

http_request: std.http.Client.Request,
control_frame_handler: ws.message.ControlFrameHeaderHandlerFn,
closing: bool,

const Connection = @This();

pub fn init(http_request: std.http.Client.Request) Connection {
    return Connection{
        .http_request = http_request,
        .control_frame_handler = &ws.message.defaultControlFrameHandler,
        .closing = false,
    };
}

/// Sends a close request to the server, and returns an iterator of the remaining messages that the server sends.
///
/// Note: if including a payload, the first two bytes MUST be a status found in TerminationStatus.
pub fn deinitAndFlush(self: *Connection, payload: ?std.BoundedArray(u8, 125)) !FlushMessagesAfterCloseIterator {
    const payload_nn = payload orelse std.BoundedArray(u8, 125){};
    const conn_writer = self.http_request.writer();
    var message_writer = ws.message.AnyMessageWriter.initControl(conn_writer.any(), payload_nn.len, .close, .random_mask);
    try message_writer.payloadWriter().writeAll(payload_nn.slice());

    self.closing = true;

    return FlushMessagesAfterCloseIterator{ .conn = self };
}

/// Sends a close request to the server, and waits for a close response. `payload` is an optional byte sequence to send to the server.
pub fn deinit(self: *Connection, payload: ?std.BoundedArray(u8, 125)) void {
    var iterator = deinitAndFlush(self, payload) catch {
        self.forceDeinit();
        return;
    };

    // continuously call iterator.next() until an error (ie, error.Closing) is encountered.
    while (true) {
        _ = iterator.next() catch break orelse break;
    }
    self.forceDeinit();
}

/// It is highly recommended to call `close()` instead, but this function allows to terminate the HTTP connection immediately.
///
/// Frees all resources related to this connection, immediately closing the HTTP connection.
pub fn forceDeinit(self: *Connection) void {
    self.closing = true;
    self.http_request.deinit();
}

/// Sends a PING control message to the server. The server should respond with PONG soon after. In order to receive the PONG, you must
/// have supplied the Connection object with a Control Frame Handler.
pub fn ping(self: *Connection, payload: ?std.BoundedArray(u8, 125)) !void {
    const payload_nn = payload orelse std.BoundedArray(u8, 125){};
    const conn_writer = self.http_request.writer();
    var message_writer = ws.message.AnyMessageWriter.initControl(conn_writer.any(), payload_nn.len, .ping, .random_mask);
    try message_writer.payloadWriter().writeAll(payload_nn.slice());
}

pub fn readMessage(self: *Connection) !ws.MessageReader {
    return try ws.MessageReader.readFrom(
        self.http_request.reader().any(),
        self.control_frame_handler,
        self.http_request.writer().any(),
    );
}

/// Writes a byte string as a websocket message. `message` should be UTF-8 encoded.
pub fn writeMessageString(self: *Connection, message: []const u8) !void {
    var message_writer = try self.writeMessageStream(.text, message.len);
    try message_writer.payloadWriter().writeAll(message);
}

/// Writes a stream of bytes as a websocket message.
pub fn writeMessageStream(self: *Connection, msg_type: ws.message.writer.MessageType, length: usize) !ws.message.SingleFrameMessageWriter {
    if (self.closing) {
        return error.Closing;
    }
    return ws.MessageWriter.init(self.http_request.writer().any(), length, msg_type, .random_mask);
}

/// Creates a MessageWriter, which writes a Websocket Frame Header, and then
/// returns a Writer which can be used to write the websocket payload.
///
/// Each call to `write` will be written in its entirety to a new websocket frame. It is highly recommended
/// to wrap the returned writer in a `std.io.BufferedWriter` in order to prevent excessive websocket frame headers.
///
/// Also, you must call `.close()` on the MessageWriter when you are finished writing the message.
pub fn writeMessageStreamUnknownLength(self: *Connection, msg_type: ws.message.writer.MessageType) !ws.message.MultiFrameMessageWriter {
    if (self.closing) {
        return error.Closing;
    }
    return ws.MessageWriter.initUnknownLength(self.http_request.writer().any(), msg_type, .random_mask);
}

pub const MessagePayload = struct {
    payload: std.io.AnyReader,
    payload_len: ?usize,
    type: ws.message.writer.MessageType,
};

pub const TerminationStatus = enum(u16) {
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

    pub fn is_sendable(self: TerminationStatus) bool {
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

pub const FlushMessagesAfterCloseIterator = struct {
    conn: *Connection,

    pub fn next(self: *FlushMessagesAfterCloseIterator) !?ws.message.AnyMessageReader {
        while (self.conn.readMessage()) |msg| {
            return msg;
        } else |err| {
            if (err == error.Closing) {
                return null;
            }
            return err;
        }
        return null;
    }
};
