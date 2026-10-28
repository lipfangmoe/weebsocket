const std = @import("std");
const ws = @import("../root.zig");

pub const AnyMessageWriter = union(enum) {
    unfragmented: SingleFrameMessageWriter,
    fragmented: MultiFrameMessageWriter,

    pub const WriteHeaderError = error{ EndOfStream, UnexpectedWriteFailure };
    pub const WritePayloadError = error{ EndOfStream, PayloadTooLong, UnexpectedWriteFailure };
    pub const WriteError = WriteHeaderError || WritePayloadError;

    /// Creates a message writer with a known length. Also known as an "unfragmented" message.
    pub fn init(underlying_writer: std.io.AnyWriter, message_len: usize, message_type: ws.message.Type, mask: ws.message.frame.Mask) WriteHeaderError!SingleFrameMessageWriter {
        const opcode = message_type.toOpcode();
        const frame_header = ws.message.frame.AnyFrameHeader.init(true, opcode, message_len, mask);
        frame_header.writeTo(underlying_writer) catch |err| return switch (err) {
            error.EndOfStream => error.EndOfStream,
            else => {
                std.log.err("unexpected write failure while writing frame header: {}", .{err});
                return error.UnexpectedWriteFailure;
            },
        };
        return SingleFrameMessageWriter{
            .underlying_writer = underlying_writer,
            .frame_header = frame_header,
        };
    }

    /// Creates a message which can be written to over multiple frames. Also known as a "fragmented" message.
    /// Must be closed before any other messages can be sent.
    pub fn initUnknownLength(underlying_writer: std.io.AnyWriter, message_type: ws.message.Type, mask: ws.message.frame.Mask) MultiFrameMessageWriter {
        return MultiFrameMessageWriter{
            .underlying_writer = underlying_writer,
            .opcode = message_type.toOpcode(),
            .mask = mask,
        };
    }

    /// Creates a control message, which are internal to the websocket protocol and should be controlled by the library.
    /// Should only be used for creating a control message handler.
    pub fn initControl(
        underlying_writer: std.io.AnyWriter,
        payload_len: usize,
        opcode: ws.message.frame.Opcode,
        mask: ws.message.frame.Mask,
    ) !SingleFrameMessageWriter {
        const frame_header = ws.message.frame.AnyFrameHeader.init(true, opcode, payload_len, mask);
        try frame_header.writeTo(underlying_writer);
        return SingleFrameMessageWriter{
            .underlying_writer = underlying_writer,
            .frame_header = frame_header,
        };
    }

    const Writer = std.io.GenericWriter(*AnyMessageWriter, WriteError, write);
    fn write(self: *AnyMessageWriter, bytes: []const u8) WriteError!usize {
        return switch (self.*) {
            inline else => |*impl| impl.payloadWriter().write(bytes),
        };
    }

    pub fn payloadWriter(self: *AnyMessageWriter) Writer {
        return Writer{ .context = self };
    }

    pub fn close(self: *AnyMessageWriter) !void {
        switch (self.*) {
            .fragmented => |*frag| try frag.close(),
            .unfragmented => {},
        }
    }
};

/// Represents an outgoing message that may span multiple frames. Each call to write() will send a websocket frame, so
/// it's a good idea to wrap this in a std.io.BufferedWriter
pub const MultiFrameMessageWriter = struct {
    underlying_writer: std.io.AnyWriter,
    opcode: ws.message.frame.Opcode,
    mask: ws.message.frame.Mask,

    /// Writes data to the message as a single websocket frame
    pub fn write(self: *MultiFrameMessageWriter, bytes: []const u8) AnyMessageWriter.WriteError!usize {
        const frame_header = ws.message.frame.AnyFrameHeader.init(false, self.opcode, bytes.len, self.mask);

        // make sure that all but the first frame are continuation frames
        self.opcode = .continuation;

        try self.writeAndMaybeMask(frame_header, bytes);

        return bytes.len;
    }

    fn writeAndMaybeMask(self: *MultiFrameMessageWriter, frame_header: ws.message.frame.AnyFrameHeader, payload: []const u8) AnyMessageWriter.WriteError!void {
        frame_header.writeTo(self.underlying_writer) catch |err| return switch (err) {
            error.EndOfStream => error.EndOfStream,
            else => {
                std.log.err("Unexpected write failure while writing frame header for fragmented message: {}", .{err});
                return error.UnexpectedWriteFailure;
            },
        };

        // do simple case if no mask
        if (!frame_header.asMostBasicHeader().mask) {
            return self.underlying_writer.writeAll(payload) catch |err| return switch (err) {
                error.EndOfStream => error.EndOfStream,
                else => {
                    std.log.err("Unexpected write failure while writing payload for fragmented message: {}", .{err});
                    return error.UnexpectedWriteFailure;
                },
            };
        }

        const masking_key = frame_header.getMaskingKey() orelse std.debug.panic("invalid state: mask bit is set but header does not have a masking key", .{});

        // mask while writing
        var bytes_idx: usize = 0;
        var buf: [8000]u8 = undefined;
        while (bytes_idx < payload.len) {
            const src_slice = payload[bytes_idx..@min(bytes_idx + 8000, payload.len)];
            const dest_slice = buf[0..src_slice.len];
            @memcpy(dest_slice, src_slice);
            ws.message.reader.mask_unmask(bytes_idx, masking_key, dest_slice);
            self.underlying_writer.writeAll(dest_slice) catch |err| return switch (err) {
                error.EndOfStream => error.EndOfStream,
                else => {
                    std.log.err("Unexpected write failure while writing payload for fragmented message: {}", .{err});
                    return error.UnexpectedWriteFailure;
                },
            };

            bytes_idx += 8000;
        }
    }

    const Writer = std.io.GenericWriter(*MultiFrameMessageWriter, AnyMessageWriter.WriteError, write);
    pub fn payloadWriter(self: *MultiFrameMessageWriter) Writer {
        return Writer{ .context = self };
    }

    pub fn closeWithWrite(self: *MultiFrameMessageWriter, bytes: []const u8) !void {
        const frame_header = ws.message.frame.AnyFrameHeader.init(true, self.opcode, bytes.len, self.mask);

        try self.writeAndMaybeMask(frame_header, bytes);
    }

    pub fn close(self: *MultiFrameMessageWriter) !void {
        try closeWithWrite(self, &.{});
    }

    pub fn any(self: MultiFrameMessageWriter) AnyMessageWriter {
        return .{ .fragmented = self };
    }
};

pub const SingleFrameMessageWriter = struct {
    underlying_writer: std.io.AnyWriter,
    frame_header: ws.message.frame.AnyFrameHeader,
    payload_bytes_written: usize = 0,

    /// Writes data to the message as a single websocket frame
    pub fn write(self: *SingleFrameMessageWriter, bytes: []const u8) AnyMessageWriter.WritePayloadError!usize {
        const payload_len = self.frame_header.getPayloadLen() catch return error.PayloadTooLong;
        const remaining_bytes = payload_len - self.payload_bytes_written;

        const capped_bytes = bytes[0..@min(bytes.len, remaining_bytes)];
        if (capped_bytes.len == 0) {
            return error.EndOfStream;
        }

        // do simple case if no mask
        if (!self.frame_header.asMostBasicHeader().mask) {
            const n = self.underlying_writer.write(capped_bytes) catch |err| return switch (err) {
                error.EndOfStream => error.EndOfStream,
                else => {
                    std.log.err("Unexpected write failure while writing payload for unfragmented message: {}", .{err});
                    return error.UnexpectedWriteFailure;
                },
            };
            self.payload_bytes_written += n;
            return n;
        }

        const masking_key = self.frame_header.getMaskingKey() orelse std.debug.panic("invalid state: mask bit is set but header does not have a masking key", .{});

        // mask while writing
        var masked_bytes_buf: [1000]u8 = undefined;

        const src_slice = capped_bytes[0..@min(capped_bytes.len, 1000)];
        const masked_slice = masked_bytes_buf[0..src_slice.len];
        @memcpy(masked_slice, src_slice);
        ws.message.reader.mask_unmask(self.payload_bytes_written, masking_key, masked_slice);

        const n = self.underlying_writer.write(masked_slice) catch |err| return switch (err) {
            error.EndOfStream => error.EndOfStream,
            else => {
                std.log.err("Unexpected write failure while writing payload for unfragmented message: {}", .{err});
                return error.UnexpectedWriteFailure;
            },
        };
        self.payload_bytes_written += n;

        return n;
    }

    /// Writes entirely null bytes for the remainder of the payload
    pub fn discard(self: *SingleFrameMessageWriter) AnyMessageWriter.WritePayloadError!void {
        const payload_len = self.frame_header.getPayloadLen() catch return error.PayloadTooLong;
        const remaining_bytes = payload_len - self.payload_bytes_written;

        try self.payloadWriter().writeByteNTimes(0, remaining_bytes);
    }

    const Writer = std.io.GenericWriter(*SingleFrameMessageWriter, AnyMessageWriter.WritePayloadError, write);
    pub fn payloadWriter(self: *SingleFrameMessageWriter) Writer {
        return Writer{ .context = self };
    }

    pub fn any(self: SingleFrameMessageWriter) AnyMessageWriter {
        return .{ .unfragmented = self };
    }
};

// these tests come from the spec

test "A single-frame unmasked text message" {
    const message_payload = "Hello";
    var output = std.BoundedArray(u8, 100){};
    var message = try AnyMessageWriter.init(output.writer().any(), message_payload.len, .text, .unmasked);
    var payload_writer = message.payloadWriter();
    try payload_writer.writeAll(message_payload);

    const expected = [_]u8{ 0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f };
    try std.testing.expectEqualSlices(u8, &expected, output.constSlice());
}

test "A single-frame masked text message" {
    const message_payload = "Hello";
    var output = std.BoundedArray(u8, 100){};
    var message = try AnyMessageWriter.init(output.writer().any(), message_payload.len, .text, .{ .fixed_mask = 0x37fa213d });
    var payload_writer = message.payloadWriter();
    try payload_writer.writeAll(message_payload);

    const expected = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    try std.testing.expectEqualSlices(u8, &expected, output.constSlice());
}

test "A fragmented unmasked text message" {
    var output = std.BoundedArray(u8, 100){};
    var message = AnyMessageWriter.initUnknownLength(output.writer().any(), .text, .unmasked);
    _ = try message.payloadWriter().write("Hel");
    _ = try message.closeWithWrite("lo");

    const expected = [_]u8{ 0x01, 0x03, 0x48, 0x65, 0x6c, 0x80, 0x02, 0x6c, 0x6f };
    try std.testing.expectEqualSlices(u8, &expected, output.constSlice());
}

test "(not in spec) A fragmented unmasked text message interrupted with a masked control frame" {
    var output = std.BoundedArray(u8, 100){};
    var message = AnyMessageWriter.initUnknownLength(output.writer().any(), .text, .unmasked);

    _ = try message.payloadWriter().write("Hel");

    // simulate pong response in the middle of fragmented payload
    const pong_payload = "Hello";
    var pong = try AnyMessageWriter.initControl(output.writer().any(), pong_payload.len, .pong, .{ .fixed_mask = 0x37fa213d });
    try pong.payloadWriter().writeAll(pong_payload);

    _ = try message.closeWithWrite("lo");

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
    try std.testing.expectEqualSlices(u8, &expected, output.constSlice());
}

test "example that messed me up" {
    var output = std.BoundedArray(u8, 100){};
    const close_reason = "invalid frame header";
    var message = try AnyMessageWriter.initControl(output.writer().any(), close_reason.len + 2, .close, .{ .fixed_mask = 0xd585b161 });
    try message.payloadWriter().writeInt(u16, @intFromEnum(ws.Connection.CloseStatus.protocol_error), .big);
    try message.payloadWriter().writeAll(close_reason);

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
    try std.testing.expectEqualSlices(u8, &expected, output.constSlice());
}
