const std = @import("std");
const ws = @import("../root.zig");

pub const WriteHeaderError = error{WriteFailed};
pub const WritePayloadError = error{ WriteFailed, PayloadTooLong, UnexpectedWriteFailure };
pub const WriteError = WriteHeaderError || WritePayloadError;

pub const MessageWriter = struct {
    pub const init = UnfragmentedPayloadWriter.init;
    pub const initUnknownLength = FragmentedMessageWriter.init;
};

pub const UnfragmentedPayloadWriter = struct {
    interface: std.Io.Writer,
    underlying_writer: *std.Io.Writer,
    frame_header: ws.message.frame.AnyFrameHeader,
    payload_bytes_written: usize,
    err: ?WritePayloadError = null,

    /// Creates a message writer with a known length, aka an Unfragmented Message.
    pub fn init(underlying_writer: *std.Io.Writer, message_len: usize, message_type: ws.message.Type, mask: ws.message.frame.Mask, buffer: []u8) WriteHeaderError!UnfragmentedPayloadWriter {
        const opcode = message_type.toOpcode();
        const frame_header = ws.message.frame.AnyFrameHeader.init(true, opcode, message_len, mask);
        try frame_header.writeTo(underlying_writer);
        return .initWithHeader(underlying_writer, frame_header, buffer);
    }

    pub fn initWithHeader(underlying_writer: *std.Io.Writer, frame_header: ws.message.frame.AnyFrameHeader, buffer: []u8) UnfragmentedPayloadWriter {
        return UnfragmentedPayloadWriter{
            .underlying_writer = underlying_writer,
            .frame_header = frame_header,
            .payload_bytes_written = 0,
            .interface = std.Io.Writer{
                .buffer = buffer,
                .vtable = &std.Io.Writer.VTable{ .drain = drain },
            },
        };
    }

    /// Creates a control message, which are internal to the websocket protocol and should be controlled by the library.
    /// Should only be used when creating a control message handler.
    pub fn initControl(
        underlying_writer: *std.Io.Writer,
        payload_len: usize,
        opcode: ws.message.frame.Opcode,
        mask: ws.message.frame.Mask,
        buffer: []u8,
    ) !UnfragmentedPayloadWriter {
        const frame_header = ws.message.frame.AnyFrameHeader.init(true, opcode, payload_len, mask);
        try frame_header.writeTo(underlying_writer);
        return .initWithHeader(underlying_writer, frame_header, buffer);
    }

    pub fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *UnfragmentedPayloadWriter = @alignCast(@fieldParentPtr("interface", writer));
        return drainInternal(self, data, splat) catch return error.WriteFailed;
    }

    pub fn drainInternal(self: *UnfragmentedPayloadWriter, data: []const []const u8, splat: usize) WriteError!usize {
        const payload_len = self.frame_header.getPayloadLen() catch std.debug.panic("overflow", .{});
        const remaining_bytes = payload_len - self.payload_bytes_written;

        if (remaining_bytes == 0) {
            const bytes_trying_to_write = self.interface.end + std.Io.Writer.countSplat(data, splat);
            if (bytes_trying_to_write > 0) {
                ws.log.err("attempted to call write when the payload is already fully written", .{});
                return error.WriteFailed;
            }
        }

        // do simple write if no mask
        if (!self.frame_header.asMostBasicHeader().mask) {
            const n = try self.underlying_writer.writeSplatHeaderLimit(self.interface.buffered(), data, splat, .limited(remaining_bytes));
            return self.interface.consume(n);
        }

        const masking_key = self.frame_header.getMaskingKey() orelse std.debug.panic("invalid state: mask bit is set but header does not have a masking key", .{});

        // mask while writing
        var masked_buf: [8000]u8 = undefined;
        const max_bytes = @min(remaining_bytes, masked_buf.len);
        var buf_writer = std.Io.Writer.fixed(&masked_buf);
        _ = try buf_writer.writeSplatHeaderLimit(self.interface.buffered(), data, splat, .limited(max_bytes));
        ws.message.mask_unmask(self.payload_bytes_written, masking_key, buf_writer.buffered());
        const n = try self.underlying_writer.write(buf_writer.buffered());

        self.payload_bytes_written += n;
        return self.interface.consume(n);
    }

    /// Writes entirely null bytes for the remainder of the payload
    pub fn discard(self: *UnfragmentedPayloadWriter) WritePayloadError!void {
        const payload_len = self.frame_header.getPayloadLen() catch return error.PayloadTooLong;
        const remaining_bytes = payload_len - self.payload_bytes_written;

        try self.interface.splatByteAll(0, remaining_bytes);
    }
};

/// Represents an outgoing message that may span multiple frames.
///
/// Don't forget to close!
pub const FragmentedMessageWriter = struct {
    interface: std.Io.Writer,
    underlying_writer: *std.Io.Writer,
    opcode: ws.message.frame.Opcode,
    mask: ws.message.frame.Mask,
    err: ?WritePayloadError = null,

    /// Creates a message which can be written to over multiple frames. aka a Fragmented Message.
    /// Be sure to call `close()` before any other messages can be sent.
    pub fn init(underlying_writer: *std.Io.Writer, message_type: ws.message.Type, mask: ws.message.frame.Mask, buffer: []u8) FragmentedMessageWriter {
        return FragmentedMessageWriter{
            .underlying_writer = underlying_writer,
            .opcode = message_type.toOpcode(),
            .mask = mask,
            .interface = std.Io.Writer{
                .buffer = buffer,
                .vtable = &std.Io.Writer.VTable{ .drain = drain },
            },
        };
    }

    pub fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FragmentedMessageWriter = @alignCast(@fieldParentPtr("interface", writer));

        // if there is no data to drain, do not write anything
        const payload_len = writer.buffered().len + std.Io.Writer.countSplat(data, splat);
        if (payload_len == 0) {
            return 0;
        }

        const frame_header = ws.message.frame.AnyFrameHeader.init(false, self.opcode, payload_len, self.mask);
        try frame_header.writeTo(self.underlying_writer);

        // make sure that all future frames are continuation frames
        self.opcode = .continuation;

        return try self.writePayloadFragment(data, splat, frame_header);
    }

    fn writePayloadFragment(self: *FragmentedMessageWriter, data: []const []const u8, splat: usize, frame_header: ws.message.frame.AnyFrameHeader) std.Io.Writer.Error!usize {
        const payload_len = frame_header.getPayloadLen() catch unreachable; // was created via usize, so cannot exceed usize

        // simple drain if no mask
        if (!frame_header.asMostBasicHeader().mask) {
            try self.underlying_writer.writeAll(self.interface.buffered());
            defer self.interface.end = 0;
            for (data[0 .. data.len - 1]) |datum| {
                try self.underlying_writer.writeAll(datum);
            }
            for (0..splat) |_| {
                try self.underlying_writer.writeAll(data[data.len - 1]);
            }
            return payload_len - self.interface.buffered().len;
        }

        const masking_key = frame_header.getMaskingKey() orelse std.debug.panic("invalid state: mask bit is set but header does not have a masking key", .{});

        ws.message.mask_unmask(0, masking_key, self.interface.buffered());
        try self.underlying_writer.writeAll(self.interface.buffered());
        defer self.interface.end = 0;
        var payload_idx: usize = self.interface.buffered().len;

        for (data[0 .. data.len - 1]) |datum| {
            var buf: [8000]u8 = undefined;
            var datum_idx: usize = 0;
            while (datum_idx < datum.len) : (datum_idx += 8000) {
                const src_slice = datum[datum_idx..@min(datum_idx + 8000, datum.len)];
                const dest_slice = buf[0..src_slice.len];
                @memcpy(dest_slice, src_slice);
                ws.message.mask_unmask(payload_idx, masking_key, dest_slice);
                try self.underlying_writer.writeAll(dest_slice);
                payload_idx += 8000;
            }
        }
        for (0..splat) |_| {
            const pattern = data[data.len - 1];
            var buf: [8000]u8 = undefined;
            var pattern_idx: usize = 0;
            while (pattern_idx < pattern.len) : (pattern_idx += 8000) {
                const src_slice = pattern[pattern_idx..@min(pattern_idx + 8000, pattern.len)];
                const dest_slice = buf[0..src_slice.len];
                @memcpy(dest_slice, src_slice);
                ws.message.mask_unmask(payload_idx, masking_key, dest_slice);
                try self.underlying_writer.writeAll(dest_slice);
                payload_idx += 8000;
            }
        }

        return payload_len - self.interface.buffered().len;
    }

    pub fn closeWithWrite(self: *FragmentedMessageWriter, bytes: []const u8) !void {
        const payload_len = self.interface.buffered().len + bytes.len;
        const frame_header = ws.message.frame.AnyFrameHeader.init(true, self.opcode, payload_len, self.mask);
        try frame_header.writeTo(self.underlying_writer);
        _ = try self.writePayloadFragment(&.{bytes}, 1, frame_header);
        try self.interface.flush();
    }

    pub fn close(self: *FragmentedMessageWriter) !void {
        try closeWithWrite(self, &.{});
    }
};

// these tests come from the spec

test "A single-frame unmasked text message" {
    const message_payload = "Hello";
    var output_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output_writer.deinit();
    var message_writer_buf: [100]u8 = undefined;
    var message_writer = try UnfragmentedPayloadWriter.init(&output_writer.writer, message_payload.len, .text, .unmasked, &message_writer_buf);
    try message_writer.interface.writeAll(message_payload);
    try message_writer.interface.flush();

    const expected = [_]u8{ 0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f };
    try std.testing.expectEqualSlices(u8, &expected, output_writer.written());
}

test "A single-frame masked text message" {
    const message_payload = "Hello";
    var output_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output_writer.deinit();
    var message_writer_buf: [100]u8 = undefined;
    var message_writer = try UnfragmentedPayloadWriter.init(&output_writer.writer, message_payload.len, .text, .{ .fixed_mask = 0x37fa213d }, &message_writer_buf);
    try message_writer.interface.writeAll(message_payload);
    try message_writer.interface.flush();

    const expected = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    try std.testing.expectEqualSlices(u8, &expected, output_writer.written());
}

test "A fragmented unmasked text message" {
    var output_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output_writer.deinit();
    var buf: [100]u8 = undefined;
    var message_writer = FragmentedMessageWriter.init(&output_writer.writer, .text, .unmasked, &buf);
    _ = try message_writer.interface.writeAll("Hel");
    try message_writer.interface.flush();
    _ = try message_writer.closeWithWrite("lo");

    const expected = [_]u8{ 0x01, 0x03, 0x48, 0x65, 0x6c, 0x80, 0x02, 0x6c, 0x6f };
    try std.testing.expectEqualSlices(u8, &expected, output_writer.written());
}

test "(not in spec) A fragmented unmasked text message interrupted with a masked control frame" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    var buf: [100]u8 = undefined;
    var message_writer = FragmentedMessageWriter.init(&output.writer, .text, .unmasked, &buf);

    _ = try message_writer.interface.writeAll("Hel");
    try message_writer.interface.flush();

    // simulate pong response in the middle of fragmented payload
    const pong_payload = "Hello";
    var pong_buf: [100]u8 = undefined;
    var pong = try UnfragmentedPayloadWriter.initControl(&output.writer, pong_payload.len, .pong, .{ .fixed_mask = 0x37fa213d }, &pong_buf);
    try pong.interface.writeAll(pong_payload);
    try pong.interface.flush();

    _ = try message_writer.closeWithWrite("lo");

    const expected = [_]u8{
        // first fragment: "Hel"
        0x01, 0x03, 0x48, 0x65, 0x6c,
        // interrupted by masked control frame, PONG "Hello"
        0x8a, 0x85, 0x37, 0xfa, 0x21,
        0x3d, 0x7f, 0x9f, 0x4d, 0x51,
        0x58,
        // second fragment: "lo"
        0x80, 0x02, 0x6c, 0x6f,
    };
    try std.testing.expectEqualSlices(u8, &expected, output.written());
}

test "example that messed me up" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    const close_reason = "invalid frame header";
    var buf: [100]u8 = undefined;
    var message_writer = try UnfragmentedPayloadWriter.initControl(&output.writer, close_reason.len + 2, .close, .{ .fixed_mask = 0xd585b161 }, &buf);
    try message_writer.interface.writeInt(u16, @intFromEnum(ws.Connection.CloseStatus.protocol_error), .big);
    try message_writer.interface.writeAll(close_reason);
    try message_writer.interface.flush();

    const expected = [_]u8{
        // header
        0x88, 0x96, 0xd5, 0x85, 0xb1, 0x61,
        // masked close reason
        0xd6, 0x6f,
        // message: "invalid frame header"
        0xD8, 0x0F, 0xA3, 0xE4,
        0xDD, 0x08, 0xB1, 0xA5, 0xD7, 0x13,
        0xB4, 0xE8, 0xD4, 0x41, 0xBD, 0xE0,
        0xD0, 0x05, 0xB0, 0xF7,
    };
    try std.testing.expectEqualSlices(u8, &expected, output.written());
}
