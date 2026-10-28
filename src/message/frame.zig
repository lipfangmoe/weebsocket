const std = @import("std");

pub const AnyFrameHeader = union(enum) {
    u16_unmasked: FrameHeader(.u16, false),
    u32_unmasked: FrameHeader(.u32, false),
    u80_unmasked: FrameHeader(.u80, false),
    u16_masked: FrameHeader(.u16, true),
    u32_masked: FrameHeader(.u32, true),
    u80_masked: FrameHeader(.u80, true),

    pub fn init(final: bool, opcode: Opcode, payload_len: u64, mask: Mask) AnyFrameHeader {
        if (payload_len <= 125) {
            return if (mask.getMask() != null)
                .{ .u16_masked = FrameHeader(.u16, true).init(final, opcode, @intCast(payload_len), mask) }
            else
                .{ .u16_unmasked = FrameHeader(.u16, false).init(final, opcode, @intCast(payload_len), mask) };
        }
        if (payload_len <= std.math.maxInt(u16)) {
            return if (mask.getMask() != null)
                .{ .u32_masked = FrameHeader(.u32, true).init(final, opcode, @intCast(payload_len), mask) }
            else
                .{ .u32_unmasked = FrameHeader(.u32, false).init(final, opcode, @intCast(payload_len), mask) };
        }
        return if (mask.getMask() != null)
            .{ .u80_masked = FrameHeader(.u80, true).init(final, opcode, @intCast(payload_len), mask) }
        else
            .{ .u80_unmasked = FrameHeader(.u80, false).init(final, opcode, @intCast(payload_len), mask) };
    }

    pub fn readFrom(reader: std.io.AnyReader) !AnyFrameHeader {
        const underlying_int = try reader.readInt(u16, .big);
        const u16_unmasked: FrameHeader(.u16, false) = @bitCast(underlying_int);
        if (u16_unmasked.payload_len == 126) {
            const extended_payload_len = try reader.readInt(u16, .big);

            if (u16_unmasked.mask) {
                const masking_key = try reader.readInt(u32, .big);
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
            const extended_payload_len = try reader.readInt(u64, .big);

            if (u16_unmasked.mask) {
                const masking_key = try reader.readInt(u32, .big);
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
            const masking_key = try reader.readInt(u32, .big);
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

    pub fn writeTo(self: AnyFrameHeader, writer: std.io.AnyWriter) !void {
        switch (self) {
            inline else => |header| {
                const BackingInt = @typeInfo(@TypeOf(header)).Struct.backing_integer.?;
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
                .masking_key = void{},
                .extended_payload_len = void{},
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
};

pub fn FrameHeader(comptime size: FrameHeaderSize, comptime has_masking_key: bool) type {
    const PayloadLenArgT = switch (size) {
        .u16 => u7,
        .u32 => u16,
        .u80 => u64,
    };
    return packed struct {
        /// The XOR mask to put on the payload
        masking_key: if (has_masking_key) u32 else void,
        /// If payload_len is set to 126 or 127, this is the true payload length.
        extended_payload_len: switch (size) {
            .u16 => void,
            .u32 => u16,
            .u80 => u64,
        },
        /// The length of the payload of the frame. If set to 126 or 127, extended_payload_len is the true payload length.
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

        const Self = @This();

        pub fn init(final: bool, opcode: Opcode, payload_len: PayloadLenArgT, mask: Mask) Self {
            const masking_key = if (has_masking_key)
                mask.getMask() orelse std.debug.panic("header type {} does not allow for masking key, but mask type {s} was provided", .{ @TypeOf(Self), @tagName(mask) })
            else
                void{};
            const payload_len_field = switch (size) {
                .u16 => payload_len,
                .u32 => 126,
                .u80 => 127,
            };
            const extended_payload_len_field = switch (size) {
                .u16 => void{},
                inline else => payload_len,
            };
            return Self{
                .fin = final,
                .rsv1 = false,
                .rsv2 = false,
                .rsv3 = false,
                .opcode = opcode,
                .mask = has_masking_key,
                .payload_len = payload_len_field,
                .extended_payload_len = extended_payload_len_field,
                .masking_key = masking_key,
            };
        }

        pub fn getPayloadLen(self: Self) u64 {
            return switch (size) {
                .u16 => self.payload_len,
                inline else => self.extended_payload_len,
            };
        }
    };
}

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

pub const Mask = union(enum) {
    unmasked: void,
    random_mask: void,
    fixed_mask: u32,

    pub fn getMask(self: Mask) ?u32 {
        return switch (self) {
            .unmasked => null,
            .random_mask => std.crypto.random.int(u32),
            .fixed_mask => |fixed| fixed,
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
    var stream = std.io.fixedBufferStream(&example_bytes);

    const frame_header = (try AnyFrameHeader.readFrom(stream.reader().any())).u16_unmasked;
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
    var stream = std.io.fixedBufferStream(&example_bytes);

    const frame_header = (try AnyFrameHeader.readFrom(stream.reader().any())).u32_unmasked;
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
    var stream = std.io.fixedBufferStream(&example_bytes);

    const frame_header = (try AnyFrameHeader.readFrom(stream.reader().any())).u80_masked;
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
    var stream = std.io.fixedBufferStream(&buf);

    const any_frame_header = AnyFrameHeader.init(true, .close, 42, .unmasked);

    const expected: [2]u8 = .{ 0b10001000, 0b00101010 };
    try any_frame_header.writeTo(stream.writer().any());
    try std.testing.expectEqual(expected, buf);
}

test "write u32 unmasked" {
    var buf: [4]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    const any_frame_header = AnyFrameHeader.init(true, .close, 0xAAFF, .unmasked);

    const expected: [4]u8 = .{ 0b10001000, 0b01111110, 0xAA, 0xFF };
    try any_frame_header.writeTo(stream.writer().any());
    try std.testing.expectEqual(expected, buf);
}

test "write u80 masked" {
    var buf: [10 + 4]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    const any_frame_header = AnyFrameHeader.init(true, .close, 0xA1A2A3A4A5A6A7A8, .{ .fixed_mask = 0xB1B2B3B4 });

    // mask is cryptographically random, cannot test it
    const expected_u80: [10 + 4]u8 = .{ 0b10001000, 0b11111111, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xB1, 0xB2, 0xB3, 0xB4 };
    try any_frame_header.writeTo(stream.writer().any());
    try std.testing.expectEqual(expected_u80, buf);
}
