const std = @import("std");
const ws = @import("../root.zig");

const ControlFrameHandler = @This();

mask_strategy: ws.message.frame.MaskStrategy,
conn_writer: *std.Io.Writer,
handlerFn: *const fn (
    self: *const ControlFrameHandler,
    header: ws.message.frame.FrameHeader(.u16, false),
    payload: []const u8,
) Error!void,

pub fn default(mask_strategy: ws.message.frame.MaskStrategy, conn_writer: *std.Io.Writer) ControlFrameHandler {
    return .{
        .mask_strategy = mask_strategy,
        .conn_writer = conn_writer,
        .handlerFn = &defaultControlFrameHandler,
    };
}

pub const Error = error{ ReceivedCloseFrame, InvalidMessage, WriteFailed, EndOfStream } || ws.message.writer.Error;

fn defaultControlFrameHandler(
    self: *const ControlFrameHandler,
    header: ws.message.frame.FrameHeader(.u16, false),
    payload: []const u8,
) Error!void {
    const opcode: ws.message.frame.Opcode = header.opcode;
    std.debug.assert(opcode.isControlFrame());

    switch (opcode) {
        .ping => {
            var buf: [300]u8 = undefined;
            var control_message_writer: ws.SingleFrameMessageWriter = .initControl(self.conn_writer, header.payload_len, .pong, self.mask_strategy, &buf);
            control_message_writer.interface.writeAll(payload) catch {
                std.debug.assert(control_message_writer.state == .err);

                ws.log.err("Error while writing pong payload: {}", .{control_message_writer.state.err});
                return control_message_writer.state.err;
            };
            control_message_writer.interface.flush() catch {
                std.debug.assert(control_message_writer.state == .err);

                ws.log.err("Error while writing pong payload: {}", .{control_message_writer.state.err});
                return control_message_writer.state.err;
            };
        },
        .pong => {},
        .close => {
            if (payload.len == 1) {
                return error.InvalidMessage;
            }
            if (payload.len > 2 and !std.unicode.utf8ValidateSlice(payload[2..])) {
                return error.InvalidMessage;
            }
            if (payload.len >= 2) {
                const status: CloseStatus = @enumFromInt(std.mem.readInt(u16, payload[0..2], .big));
                if (!status.isSendable()) {
                    return error.InvalidMessage;
                }
            }
            return error.ReceivedCloseFrame;
        },
        else => unreachable,
    }
}

pub const CloseStatus = enum(u16) {
    normal = 1000,
    going_away = 1001,
    protocol_error = 1002,
    cannot_accept = 1003,
    inconsistent_format = 1007,
    policy_violation = 1008,
    message_too_large = 1009,
    expected_extension = 1010,
    unexpected_condition = 1011,

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
            .unexpected_condition,
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
