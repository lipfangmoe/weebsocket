const std = @import("std");
const ws = @import("./root.zig");

pub const frame = @import("./message/frame.zig");
pub const reader = @import("./message/reader.zig");
pub const writer = @import("./message/writer.zig");

pub const MessageReader = reader.MessageReader;
pub const SingleFrameMessageReader = reader.UnfragmentedPayloadReader;
pub const MultiFrameMessageReader = reader.FragmentedPayloadReader;

pub const MessageWriter = writer.MessageWriter;
pub const SingleFrameMessageWriter = writer.UnfragmentedPayloadWriter;
pub const MultiFrameMessageWriter = writer.FragmentedMessageWriter;

pub const Type = enum {
    /// Indicates that the message is a valid UTF-8 string.
    text,
    /// Indicates that the message is binary data with no guarantees about encoding.
    binary,

    pub fn toOpcode(self: Type) ws.message.frame.Opcode {
        return switch (self) {
            .text => .text,
            .binary => .binary,
        };
    }

    /// returns error.UnexpectedOpcode if called on a control frame header.
    pub fn fromOpcode(opcode: ws.message.frame.Opcode) !Type {
        return switch (opcode) {
            .text => .text,
            .binary => .binary,
            else => error.UnexpectedOpcode,
        };
    }
};
pub const ControlFrameHandlerError = error{ ReceivedCloseFrame, WriteFailed };
pub const ControlFrameHeaderHandlerFn = *const ControlFrameHeaderHandlerFnBody;
pub const ControlFrameHeaderHandlerFnBody = fn (
    mask_strategy: frame.MaskStrategy,
    conn_writer: *std.Io.Writer,
    header: frame.FrameHeader(.u16, false),
    payload: []const u8,
) ControlFrameHandlerError!void;

pub fn defaultControlFrameHandler(
    mask_strategy: ws.message.frame.MaskStrategy,
    conn_writer: *std.Io.Writer,
    header: frame.FrameHeader(.u16, false),
    payload: []const u8,
) ControlFrameHandlerError!void {
    const opcode: frame.Opcode = header.opcode;
    std.debug.assert(opcode.isControlFrame());

    switch (opcode) {
        .ping => {
            var buf: [1000]u8 = undefined;
            var control_message_writer = SingleFrameMessageWriter.initControl(conn_writer, header.payload_len, .pong, mask_strategy, &buf) catch |err| {
                ws.log.err("Error while writing pong header: {}", .{err});
                return error.WriteFailed;
            };
            control_message_writer.interface.writeAll(payload) catch |err| {
                ws.log.err("Error while writing pong payload: {}", .{err});
                return error.WriteFailed;
            };
            control_message_writer.interface.flush() catch |err| {
                ws.log.err("Error while writing pong payload: {}", .{err});
                return error.WriteFailed;
            };
        },
        .pong => {},
        .close => {
            ws.log.debug("peer sent close frame with payload '{s}'", .{payload});
            return error.ReceivedCloseFrame;
        },
        else => unreachable,
    }
}

/// toggles the bytes between masked/unmasked form.
pub fn mask_unmask(payload_start: usize, masking_key: [4]u8, bytes: []u8) void {
    for (payload_start.., bytes) |payload_idx, *transformed_octet| {
        const original_octet = transformed_octet.* ^ masking_key[payload_idx % 4];
        transformed_octet.* = original_octet;
    }
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("./message/utf8_validator.zig");
}
