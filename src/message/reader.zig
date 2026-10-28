const std = @import("std");
const ws = @import("../root.zig");

pub const AnyMessageReader = union(enum) {
    unfragmented: UnfragmentedMessageReader,
    fragmented: FragmentedMessageReader,

    pub fn readFrom(reader: std.io.AnyReader) !AnyMessageReader {
        const header = try ws.message.frame.AnyFrameHeader.readFrom(reader);
        const basic_header = header.asMostBasicHeader();

        if (basic_header.fin) {
            return .{
                .unfragmented = UnfragmentedMessageReader{
                    .underlying_reader = reader,
                    .payload_idx = 0,
                    .frame_header = header,
                },
            };
        } else {
            const payload_len = header.getPayloadLen() catch return error.PayloadTooLong;
            return .{
                .fragmented = FragmentedMessageReader{
                    .state = .{ .in_payload = .{ .idx = 0, .payload_len = payload_len } },
                    .underlying_reader = reader,
                    .first_header = header,
                    .current_header = header,
                },
            };
        }
    }
};

/// Represents an incoming message that may span multiple frames.
pub const FragmentedMessageReader = struct {
    state: State,
    underlying_reader: std.io.AnyReader,
    first_header: ws.message.frame.AnyFrameHeader,
    current_header: ws.message.frame.AnyFrameHeader,

    pub fn read(self: *FragmentedMessageReader, bytes: []u8) anyerror!usize {
        switch (self.state) {
            .waiting_for_next_header => {
                const header = try ws.message.frame.AnyFrameHeader.readFrom(self.underlying_reader);
                self.current_header = header;
                const payload_len = header.getPayloadLen() catch return error.PayloadTooLong;
                self.state = .{ .in_payload = .{ .idx = 0, .payload_len = payload_len } };
            },
            .done => return 0,
            else => {},
        }

        // at this point in the function, we are always in state == .in_payload

        const remaining_bytes = self.state.in_payload.payload_len - self.state.in_payload.idx;
        const capped_bytes = bytes[0..@min(remaining_bytes, bytes.len)];
        const bytes_read = try self.underlying_reader.read(capped_bytes);

        // masking
        if (self.current_header.asMostBasicHeader().mask) {
            const masking_key = self.current_header.getMaskingKey() orelse return error.UnexpectedMaskBit;
            mask_unmask(self.state.in_payload.idx, masking_key, capped_bytes[0..bytes_read]);
        }

        if (bytes_read == remaining_bytes) {
            const is_final = self.current_header.asMostBasicHeader().fin;
            self.state = if (is_final) .done else .waiting_for_next_header;
        } else {
            self.state.in_payload.idx += bytes_read;
        }
        return bytes_read;
    }

    fn typeErasedReadFn(ctx: *const anyopaque, bytes: []u8) anyerror!usize {
        const self: *FragmentedMessageReader = @constCast(@alignCast(@ptrCast(ctx)));
        return read(self, bytes);
    }

    pub fn reader(self: *FragmentedMessageReader) std.io.AnyReader {
        return std.io.AnyReader{ .context = self, .readFn = typeErasedReadFn };
    }

    pub const State = union(enum) {
        in_payload: struct { idx: usize, payload_len: usize },
        waiting_for_next_header: void,
        done: void,
    };
};

pub const UnfragmentedMessageReader = struct {
    underlying_reader: std.io.AnyReader,
    payload_idx: usize,
    frame_header: ws.message.frame.AnyFrameHeader,

    pub fn read(self: *UnfragmentedMessageReader, bytes: []u8) !usize {
        const remaining_bytes = try self.frame_header.getPayloadLen() - self.payload_idx;
        const capped_bytes = bytes[0..@min(remaining_bytes, bytes.len)];
        const bytes_read = try self.underlying_reader.read(capped_bytes);

        if (self.frame_header.asMostBasicHeader().mask) {
            const masking_key = self.frame_header.getMaskingKey() orelse return error.UnexpectedMaskBit;
            mask_unmask(self.payload_idx, masking_key, capped_bytes[0..bytes_read]);
        }

        self.payload_idx += bytes_read;
        return bytes_read;
    }

    fn typeErasedReadFn(ctx: *const anyopaque, bytes: []u8) anyerror!usize {
        const self: *UnfragmentedMessageReader = @constCast(@alignCast(@ptrCast(ctx)));
        return read(self, bytes);
    }

    pub fn reader(self: *UnfragmentedMessageReader) std.io.AnyReader {
        return std.io.AnyReader{ .context = self, .readFn = typeErasedReadFn };
    }
};

/// toggles the bytes between masked/unmasked form.
pub fn mask_unmask(payload_start: usize, masking_key: [4]u8, bytes: []u8) void {
    for (payload_start.., bytes) |payload_idx, *transformed_octet| {
        const original_octet = transformed_octet.* ^ masking_key[payload_idx % 4];
        transformed_octet.* = original_octet;
    }
}

// these tests come from the spec

test "A single-frame unmasked text message" {
    const bytes = [_]u8{ 0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f };
    var stream = std.io.fixedBufferStream(&bytes);
    var message = try AnyMessageReader.readFrom(stream.reader().any());
    var payload_reader = switch (message) {
        inline else => |*impl| impl.reader(),
    };
    const output = try payload_reader.readBoundedBytes(100);

    try std.testing.expectEqualStrings("Hello", output.constSlice());
}

test "A single-frame masked text message" {
    const bytes = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    var stream = std.io.fixedBufferStream(&bytes);
    var message = try AnyMessageReader.readFrom(stream.reader().any());
    var payload_reader = switch (message) {
        inline else => |*impl| impl.reader(),
    };
    const output = try payload_reader.readBoundedBytes(100);

    try std.testing.expectEqualStrings("Hello", output.constSlice());
}

test "A fragmented unmasked text message" {
    const bytes = [_]u8{ 0x01, 0x03, 0x48, 0x65, 0x6c, 0x80, 0x02, 0x6c, 0x6f };
    var stream = std.io.fixedBufferStream(&bytes);
    var message = try AnyMessageReader.readFrom(stream.reader().any());
    var payload_reader = switch (message) {
        inline else => |*impl| impl.reader(),
    };
    const output = try payload_reader.readBoundedBytes(100);

    try std.testing.expectEqualStrings("Hello", output.constSlice());
}
