const std = @import("std");

pub const AnyFrameHeader = union(enum) {
    unmasked_short: UnmaskedShortHeader,
    unmasked_medium: UnmaskedMediumHeader,
    unmasked_long: UnmaskedLongHeader,
    masked_short: MaskedShortHeader,
    masked_medium: MaskedMediumHeader,
    masked_long: MaskedLongHeader,

    pub fn init(final: bool, opcode: Opcode, payload_len: u64, mask_strategy: MaskStrategy) AnyFrameHeader {
        const common_payload_len: u7 = switch (payload_len) {
            0...125 => @intCast(payload_len),
            126...std.math.maxInt(u16) => 126,
            else => 127,
        };

        const common_header: CommonHeader = .{
            .payload_len = common_payload_len,
            .mask = mask_strategy != .unmasked,
            .opcode = opcode,
            .rsv3 = false,
            .rsv2 = false,
            .rsv1 = false,
            .fin = final,
        };

        // zig fmt: off
        return 
            if (mask_strategy.getMask()) |masking_key|
                switch (payload_len) {
                    0...125 => .{ .masked_short = .{ .common = common_header, .masking_key = masking_key } },
                    126...std.math.maxInt(u16) => .{ .masked_medium = .{ .common = common_header, .masking_key = masking_key, .extended_payload_len = @intCast(payload_len) } },
                    else => .{ .masked_long = .{ .common = common_header, .masking_key = masking_key, .extended_payload_len = payload_len } },
                }
            else switch (payload_len) {
                0...125 => .{ .unmasked_short = .{ .common = common_header } },
                126...std.math.maxInt(u16) => .{ .unmasked_medium = .{ .common = common_header, .extended_payload_len = @intCast(payload_len) } },
                else => .{ .unmasked_long = .{ .common = common_header, .extended_payload_len = payload_len } },
            };
        // zig fmt: on
    }

    pub fn readFrom(reader: *std.Io.Reader) error{ ReadFailed, EndOfStream }!AnyFrameHeader {
        const underlying_int = try reader.takeInt(u16, .big);
        const common_header: CommonHeader = @bitCast(underlying_int);

        if (common_header.payload_len == 126) {
            const extended_payload_len = try reader.takeInt(u16, .big);

            if (common_header.mask) {
                const masking_key = try reader.takeInt(u32, .big);
                return .{ .masked_medium = .{
                    .masking_key = masking_key,
                    .extended_payload_len = extended_payload_len,
                    .common = common_header,
                } };
            } else {
                return .{ .unmasked_medium = .{
                    .extended_payload_len = extended_payload_len,
                    .common = common_header,
                } };
            }
        }
        if (common_header.payload_len == 127) {
            const extended_payload_len = try reader.takeInt(u64, .big);

            if (common_header.mask) {
                const masking_key = try reader.takeInt(u32, .big);
                return .{ .masked_long = .{
                    .masking_key = masking_key,
                    .extended_payload_len = extended_payload_len,
                    .common = common_header,
                } };
            } else {
                return .{ .unmasked_long = .{
                    .extended_payload_len = extended_payload_len,
                    .common = common_header,
                } };
            }
        }

        if (common_header.mask) {
            const masking_key = try reader.takeInt(u32, .big);
            return .{ .masked_short = .{ .masking_key = masking_key, .common = common_header } };
        } else {
            return .{ .unmasked_short = .{ .common = common_header } };
        }
    }

    pub fn writeTo(self: AnyFrameHeader, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            inline else => |header| {
                const BackingInt = @typeInfo(@TypeOf(header)).@"struct".backing_integer.?;
                try writer.writeInt(BackingInt, @bitCast(header), .big);
            },
        }
    }

    pub fn getPayloadLen(self: AnyFrameHeader) error{Overflow}!u64 {
        return switch (self) {
            inline .masked_short,
            .unmasked_short,
            => |head| head.common.payload_len,
            inline .masked_medium,
            .masked_long,
            .unmasked_medium,
            .unmasked_long,
            => |head| head.extended_payload_len,
        };
    }

    /// Returns the masking key as [4]u8, or null if there is no masking key.
    pub fn getMaskingKey(self: AnyFrameHeader) ?[4]u8 {
        const masking_key_int: u32 = switch (self) {
            inline .masked_short, .masked_medium, .masked_long => |head| head.masking_key,
            else => return null,
        };

        return [4]u8{
            @truncate((masking_key_int >> 24)),
            @truncate((masking_key_int >> 16)),
            @truncate((masking_key_int >> 8)),
            @truncate(masking_key_int),
        };
    }

    pub fn common(self: AnyFrameHeader) CommonHeader {
        return switch (self) {
            inline else => |impl| impl.common,
        };
    }

    pub fn format(self: AnyFrameHeader, out: *std.Io.Writer) !void {
        switch (self) {
            inline else => |impl| try impl.format(out),
        }
    }
};

pub const CommonHeader = packed struct(u16) {
    /// The length of the payload of the frame. If set to 126 (for u32) or 127 (for u80), extended_payload_len is the true payload length.
    payload_len: u7,
    /// Defines whether or not a mask should be included
    mask: bool,
    /// Defines the interpretation of the payload data
    opcode: Opcode,
    /// MUST be 0
    rsv3: bool,
    /// MUST be 0
    rsv2: bool,
    /// MUST be 0
    rsv1: bool,
    /// whether this is the final fragment in a message
    fin: bool,

    pub fn format(self: CommonHeader, w: *std.Io.Writer) !void {
        try w.print("fin={},op={},mask={},payload_len={}", .{ self.fin, self.opcode, self.mask, self.payload_len });
    }
};
pub const UnmaskedShortHeader = packed struct(u16) {
    common: CommonHeader,

    pub fn format(self: UnmaskedShortHeader, w: *std.Io.Writer) !void {
        try w.print("UnmaskedShortHeader({f})", .{self.common});
    }
};
pub const UnmaskedMediumHeader = packed struct(u32) {
    extended_payload_len: u16,
    common: CommonHeader,

    pub fn format(self: UnmaskedMediumHeader, w: *std.Io.Writer) !void {
        try w.print("UnmaskedMediumHeader({f},extended_payload_len={})", .{ self.common, self.extended_payload_len });
    }
};
pub const UnmaskedLongHeader = packed struct(u80) {
    extended_payload_len: u64,
    common: CommonHeader,

    pub fn format(self: UnmaskedLongHeader, w: *std.Io.Writer) !void {
        try w.print("UnmaskedLongHeader({f},extended_payload_len={})", .{ self.common, self.extended_payload_len });
    }
};
pub const MaskedShortHeader = packed struct(u48) {
    masking_key: u32,
    common: CommonHeader,

    pub fn format(self: MaskedShortHeader, w: *std.Io.Writer) !void {
        try w.print("MaskedShortHeader({f},masking_key={})", .{ self.common, self.masking_key });
    }
};
pub const MaskedMediumHeader = packed struct(u64) {
    masking_key: u32,
    extended_payload_len: u16,
    common: CommonHeader,

    pub fn format(self: MaskedMediumHeader, w: *std.Io.Writer) !void {
        try w.print("MaskedMediumHeader({f},extended_payload_len={},masking_key={})", .{ self.common, self.extended_payload_len, self.masking_key });
    }
};
pub const MaskedLongHeader = packed struct(u112) {
    masking_key: u32,
    extended_payload_len: u64,
    common: CommonHeader,

    pub fn format(self: MaskedLongHeader, w: *std.Io.Writer) !void {
        try w.print("MaskedLongHeader({f},extended_payload_len={},masking_key={})", .{ self.common, self.extended_payload_len, self.masking_key });
    }
};

pub const Opcode = enum(u4) {
    // data frames
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,

    // control frames
    close = 0x8,
    ping = 0x9,
    pong = 0xA,

    _,

    pub fn isDataFrame(self: Opcode) bool {
        return switch (self) {
            .continuation, .text, .binary => true,
            .close, .ping, .pong => false,
            _ => false,
        };
    }

    pub fn isControlFrame(self: Opcode) bool {
        return switch (self) {
            .continuation, .text, .binary => false,
            .close, .ping, .pong => true,
            _ => false,
        };
    }
};

pub const MaskStrategy = union(enum) {
    unmasked: void,
    rng: std.Random,
    fixed: u32,

    pub fn getMask(self: MaskStrategy) ?u32 {
        return switch (self) {
            .unmasked => null,
            .rng => |rng| rng.int(u32),
            .fixed => |fixed| fixed,
        };
    }
};

pub const FrameHeaderSize = enum {
    u16,
    u32,
    u80,
};

test "read u16 unmasked" {
    const example_bytes: [2]u8 = .{ 0b10001000, 0b00101010 };
    var stream = std.Io.Reader.fixed(&example_bytes);
    const any = try AnyFrameHeader.readFrom(&stream);
    const common = any.unmasked_short.common;
    try std.testing.expectEqual(true, common.fin);
    try std.testing.expectEqual(false, common.rsv1);
    try std.testing.expectEqual(false, common.rsv2);
    try std.testing.expectEqual(false, common.rsv3);
    try std.testing.expectEqual(Opcode.close, common.opcode);
    try std.testing.expectEqual(false, common.mask);
    try std.testing.expectEqual(42, common.payload_len);
    try std.testing.expectEqual(42, any.getPayloadLen());
}

test "read u32 unmasked" {
    const example_bytes: [4]u8 = .{ 0b10001000, 0b01111110, 0xAA, 0xFF };
    var stream = std.Io.Reader.fixed(&example_bytes);
    const any = try AnyFrameHeader.readFrom(&stream);
    const medium = any.unmasked_medium;
    const common = medium.common;
    try std.testing.expectEqual(true, common.fin);
    try std.testing.expectEqual(false, common.rsv1);
    try std.testing.expectEqual(false, common.rsv2);
    try std.testing.expectEqual(false, common.rsv3);
    try std.testing.expectEqual(Opcode.close, common.opcode);
    try std.testing.expectEqual(false, common.mask);
    try std.testing.expectEqual(126, common.payload_len);
    try std.testing.expectEqual(0xAAFF, medium.extended_payload_len);
    try std.testing.expectEqual(0xAAFF, any.getPayloadLen());
}

test "read u80 masked" {
    const example_bytes: [10 + 4]u8 = .{ 0b10001000, 0b11111111, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xB1, 0xB2, 0xB3, 0xB4 };
    var stream = std.Io.Reader.fixed(&example_bytes);
    const any = try AnyFrameHeader.readFrom(&stream);
    const long = any.masked_long;
    const common = long.common;
    try std.testing.expectEqual(true, common.fin);
    try std.testing.expectEqual(false, common.rsv1);
    try std.testing.expectEqual(false, common.rsv2);
    try std.testing.expectEqual(false, common.rsv3);
    try std.testing.expectEqual(Opcode.close, common.opcode);
    try std.testing.expectEqual(true, common.mask);
    try std.testing.expectEqual(127, common.payload_len);
    try std.testing.expectEqual(0xA1A2A3A4A5A6A7A8, long.extended_payload_len);
    try std.testing.expectEqual(0xA1A2A3A4A5A6A7A8, any.getPayloadLen());
    try std.testing.expectEqual(0xB1B2B3B4, long.masking_key);
}

test "write u16 unmasked" {
    var buf: [2]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);

    const any_frame_header = AnyFrameHeader.init(true, .close, 42, .unmasked);

    const expected: [2]u8 = .{ 0b10001000, 0b00101010 };
    try any_frame_header.writeTo(&stream);
    try std.testing.expectEqual(expected, buf);
}

test "write u32 unmasked" {
    var buf: [4]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    const any_frame_header = AnyFrameHeader.init(true, .close, 0xAAFF, .unmasked);

    const expected: [4]u8 = .{ 0b10001000, 0b01111110, 0xAA, 0xFF };
    try any_frame_header.writeTo(&writer);
    try std.testing.expectEqual(expected, buf);
}

test "write u80 masked" {
    var buf: [10 + 4]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);

    const any_frame_header = AnyFrameHeader.init(true, .close, 0xA1A2A3A4A5A6A7A8, .{ .fixed = 0xB1B2B3B4 });

    const expected_u80: [10 + 4]u8 = .{ 0b10001000, 0b11111111, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xB1, 0xB2, 0xB3, 0xB4 };
    try any_frame_header.writeTo(&stream);
    try std.testing.expectEqual(expected_u80, buf);
}
