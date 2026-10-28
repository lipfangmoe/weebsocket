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

        const common: CommonHeader = .{
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
                    0...125 => .{ .masked_short = .{ .common = common, .masking_key = masking_key } },
                    126...std.math.maxInt(u16) => .{ .masked_medium = .{ .common = common, .masking_key = masking_key, .extended_payload_len = @intCast(payload_len) } },
                    else => .{ .masked_long = .{ .common = common, .masking_key = masking_key, .extended_payload_len = payload_len } },
                }
            else switch (payload_len) {
                0...125 => .{ .unmasked_short = .{ .common = common } },
                126...std.math.maxInt(u16) => .{ .unmasked_medium = .{ .common = common, .extended_payload_len = @intCast(payload_len) } },
                else => .{ .unmasked_long = .{ .common = common, .extended_payload_len = payload_len } },
            };
        // zig fmt: on
    }

    pub fn readFrom(reader: *std.Io.Reader) error{ ReadFailed, EndOfStream }!AnyFrameHeader {
        const underlying_int = try reader.takeInt(u16, .big);
        const u16_unmasked: FrameHeader(.u16, false) = @bitCast(underlying_int);
        if (u16_unmasked.payload_len == 126) {
            const extended_payload_len = try reader.takeInt(u16, .big);

            if (u16_unmasked.mask) {
                const masking_key = try reader.takeInt(u32, .big);
                return .{
                    .u32_masked = FrameHeader(.u32, true){
                        .masking_key = masking_key,
                        .extended_payload_len = extended_payload_len,
                        .payload_len = u16_unmasked.payload_len,
                        .mask = u16_unmasked.mask,
                        .opcode = u16_unmasked.opcode,
                        .rsv3 = u16_unmasked.rsv3,
                        .rsv2 = u16_unmasked.rsv2,
                        .rsv1 = u16_unmasked.rsv1,
                        .fin = u16_unmasked.fin,
                    },
                };
            } else {
                return .{
                    .u32_unmasked = FrameHeader(.u32, false){
                        .masking_key = void{},
                        .extended_payload_len = extended_payload_len,
                        .payload_len = u16_unmasked.payload_len,
                        .mask = u16_unmasked.mask,
                        .opcode = u16_unmasked.opcode,
                        .rsv3 = u16_unmasked.rsv3,
                        .rsv2 = u16_unmasked.rsv2,
                        .rsv1 = u16_unmasked.rsv1,
                        .fin = u16_unmasked.fin,
                    },
                };
            }
        }
        if (u16_unmasked.payload_len == 127) {
            const extended_payload_len = try reader.takeInt(u64, .big);

            if (u16_unmasked.mask) {
                const masking_key = try reader.takeInt(u32, .big);
                return .{
                    .u80_masked = FrameHeader(.u80, true){
                        .masking_key = masking_key,
                        .extended_payload_len = extended_payload_len,
                        .payload_len = u16_unmasked.payload_len,
                        .mask = u16_unmasked.mask,
                        .opcode = u16_unmasked.opcode,
                        .rsv3 = u16_unmasked.rsv3,
                        .rsv2 = u16_unmasked.rsv2,
                        .rsv1 = u16_unmasked.rsv1,
                        .fin = u16_unmasked.fin,
                    },
                };
            } else {
                return .{
                    .u80_unmasked = FrameHeader(.u80, false){
                        .masking_key = void{},
                        .extended_payload_len = extended_payload_len,
                        .payload_len = u16_unmasked.payload_len,
                        .mask = u16_unmasked.mask,
                        .opcode = u16_unmasked.opcode,
                        .rsv3 = u16_unmasked.rsv3,
                        .rsv2 = u16_unmasked.rsv2,
                        .rsv1 = u16_unmasked.rsv1,
                        .fin = u16_unmasked.fin,
                    },
                };
            }
        }

        if (u16_unmasked.mask) {
            const masking_key = try reader.takeInt(u32, .big);
            return .{
                .u16_masked = FrameHeader(.u16, true){
                    .masking_key = masking_key,
                    .extended_payload_len = void{},
                    .payload_len = u16_unmasked.payload_len,
                    .mask = u16_unmasked.mask,
                    .opcode = u16_unmasked.opcode,
                    .rsv3 = u16_unmasked.rsv3,
                    .rsv2 = u16_unmasked.rsv2,
                    .rsv1 = u16_unmasked.rsv1,
                    .fin = u16_unmasked.fin,
                },
            };
        } else {
            return .{ .u16_unmasked = u16_unmasked };
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

    pub fn getPayloadLen(self: AnyFrameHeader) error{Overflow}!usize {
        return switch (self) {
            inline else => |impl| std.math.cast(usize, impl.getPayloadLen()) orelse return error.Overflow,
        };
    }

    /// Returns the masking key as [4]u8, or null if there is no masking key.
    pub fn getMaskingKey(self: AnyFrameHeader) ?[4]u8 {
        const masking_key_int: u32 = switch (self) {
            inline else => |impl| if (@TypeOf(impl.masking_key) != void) impl.masking_key else return null,
        };

        return [4]u8{
            @truncate((masking_key_int >> 24)),
            @truncate((masking_key_int >> 16)),
            @truncate((masking_key_int >> 8)),
            @truncate(masking_key_int),
        };
    }

    pub fn asMostBasicHeader(self: AnyFrameHeader) FrameHeader(.u16, false) {
        return switch (self) {
            inline else => |impl| FrameHeader(.u16, false){
                .masking_key = {},
                .extended_payload_len = {},
                .payload_len = impl.payload_len,
                .mask = impl.mask,
                .opcode = impl.opcode,
                .rsv3 = impl.rsv3,
                .rsv2 = impl.rsv2,
                .rsv1 = impl.rsv1,
                .fin = impl.fin,
            },
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
};
pub const UnmaskedShortHeader = packed struct(u16) {
    common: CommonHeader,
};
pub const UnmaskedMediumHeader = packed struct(u32) {
    extended_payload_len: u16,
    common: CommonHeader,
};
pub const UnmaskedLongHeader = packed struct(u64) {
    extended_payload_len: u64,
    common: CommonHeader,
};
pub const MaskedShortHeader = packed struct(u64) {
    masking_key: u32,
    common: CommonHeader,
};
pub const MaskedMediumHeader = packed struct(u96) {
    masking_key: u32,
    extended_payload_len: u16,
    common: CommonHeader,
};
pub const MaskedLongHeader = packed struct(u128) {
    masking_key: u32,
    extended_payload_len: u64,
    common: CommonHeader,
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
    const frame_header = (try AnyFrameHeader.readFrom(&stream)).u16_unmasked;
    try std.testing.expectEqual(true, frame_header.fin);
    try std.testing.expectEqual(false, frame_header.rsv1);
    try std.testing.expectEqual(false, frame_header.rsv2);
    try std.testing.expectEqual(false, frame_header.rsv3);
    try std.testing.expectEqual(Opcode.close, frame_header.opcode);
    try std.testing.expectEqual(false, frame_header.mask);
    try std.testing.expectEqual(42, frame_header.payload_len);
    try std.testing.expectEqual(42, frame_header.getPayloadLen());
}

test "read u32 unmasked" {
    const example_bytes: [4]u8 = .{ 0b10001000, 0b01111110, 0xAA, 0xFF };
    var stream = std.Io.Reader.fixed(&example_bytes);
    const frame_header = (try AnyFrameHeader.readFrom(&stream)).u32_unmasked;
    try std.testing.expectEqual(true, frame_header.fin);
    try std.testing.expectEqual(false, frame_header.rsv1);
    try std.testing.expectEqual(false, frame_header.rsv2);
    try std.testing.expectEqual(false, frame_header.rsv3);
    try std.testing.expectEqual(Opcode.close, frame_header.opcode);
    try std.testing.expectEqual(false, frame_header.mask);
    try std.testing.expectEqual(126, frame_header.payload_len);
    try std.testing.expectEqual(0xAAFF, frame_header.extended_payload_len);
    try std.testing.expectEqual(0xAAFF, frame_header.getPayloadLen());
}

test "read u80 masked" {
    const example_bytes: [10 + 4]u8 = .{ 0b10001000, 0b11111111, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xB1, 0xB2, 0xB3, 0xB4 };
    var stream = std.Io.Reader.fixed(&example_bytes);
    const frame_header = (try AnyFrameHeader.readFrom(&stream)).u80_masked;
    try std.testing.expectEqual(true, frame_header.fin);
    try std.testing.expectEqual(false, frame_header.rsv1);
    try std.testing.expectEqual(false, frame_header.rsv2);
    try std.testing.expectEqual(false, frame_header.rsv3);
    try std.testing.expectEqual(Opcode.close, frame_header.opcode);
    try std.testing.expectEqual(true, frame_header.mask);
    try std.testing.expectEqual(127, frame_header.payload_len);
    try std.testing.expectEqual(0xA1A2A3A4A5A6A7A8, frame_header.extended_payload_len);
    try std.testing.expectEqual(0xA1A2A3A4A5A6A7A8, frame_header.getPayloadLen());
    try std.testing.expectEqual(0xB1B2B3B4, frame_header.masking_key);
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
