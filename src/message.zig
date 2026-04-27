const std = @import("std");
const ws = @import("./root.zig");

pub const frame = @import("./message/frame.zig");
pub const reader = @import("./message/reader.zig");
pub const writer = @import("./message/writer.zig");
pub const ControlFrameHandler = @import("./message/ControlFrameHandler.zig");

pub const MessageReader = reader.MessageReader;

pub const SingleFrameMessageWriter = writer.UnfragmentedMessageWriter;
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
