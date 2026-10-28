const std = @import("std");
const ws = @import("../root.zig");
const frame = ws.message.frame;

http_request: std.http.Client.Request,
control_frame_handler: *const fn (
    self: *Connection,
    frame.AnyFrameHeader,
    []const u8,
) std.io.AnyReader.Error!void,
closing: bool,

const Connection = @This();

pub fn init(http_request: std.http.Client.Request) Connection {
    return Connection{
        .http_request = http_request,
        .control_frame_handler = &default_control_frame_handler,
        .closing = false,
    };
}

/// Sends a close request to the server, and returns an iterator of the remaining messages that the server sends.
///
/// Note: if including a payload, the first two bytes MUST be a status found in TerminationStatus.
pub fn closeAndFlush(self: *Connection, payload: ?[]const u8) !FlushMessagesAfterCloseIterator {
    const writer = self.http_request.writer();
    try self.writeMessage(ws.message.AnyMessageWriter.initControl(writer.any(), .close, payload orelse &.{}));
    self.closing = true;

    return FlushMessagesAfterCloseIterator{ .conn = self };
}

/// Sends a close request to the server, and waits for a close response. `payload` is an optional byte sequence to send to the server.
pub fn close(self: *Connection, payload: ?[]const u8) void {
    var iterator = closeAndFlush(self, payload) catch {
        self.deinit_force();
        return;
    };

    // continuously call iterator.next() until an error (ie, error.Closing) is encountered.
    while (true) {
        _ = iterator.next() catch break orelse break;
    }
    self.deinit_force();
}

/// It is HIGHLY RECOMMENDED to call `close()` instead.
///
/// Frees all resources related to this connection, immediately closing the HTTP connection.
pub fn deinit_force(self: *Connection) void {
    self.http_request.deinit();
}

pub fn readMessage(self: *Connection) !ws.message.AnyMessageReader {
    _ = self;
    @panic("TODO");
}

pub fn writeMessage(self: *Connection, message: ws.message.AnyMessageWriter) !void {
    if (self.closing) {
        return error.Closing;
    }
    _ = message;
    @panic("TODO");
}

fn default_control_frame_handler(
    self: *Connection,
    frame_header: frame.AnyFrameHeader,
    frame_payload: []const u8, // control frames are always unfragmented
) anyerror!void {
    const opcode: frame.Opcode = switch (frame_header) {
        inline else => |header| header.opcode,
    };
    std.debug.assert(opcode.is_control_frame());

    const writer = self.http_request.writer();
    switch (opcode) {
        .ping => {
            try self.writeMessage(ws.message.AnyMessageWriter.initControl(writer.any(), .pong, frame_payload));
        },
        .pong => {},
        .close => {
            return error.Closing;
        },
        else => unreachable,
    }
}

pub const ClosePayload = struct {
    status: ?TerminationStatus,
    remaining_bytes: []const u8,
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
