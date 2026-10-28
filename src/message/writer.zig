const std = @import("std");
const ws = @import("../root.zig");

pub const AnyMessageWriter = union(enum) {
    unfragmented: SingleFrameMessageWriter,
    fragmented: MultiFrameMessageWriter,

    pub fn wrap(message_writer: anytype) AnyMessageWriter {
        return switch (@TypeOf(message_writer)) {
            SingleFrameMessageWriter => .{ .unfragmented = message_writer },
            MultiFrameMessageWriter => .{ .fragmented = message_writer },
            else => |T| @compileError("only FragmentedMessageWriter or UnfragmentedMessageWriter may be passed to AnyMessageWriter.wrap(), got " ++ @typeName(T)),
        };
    }

    /// Creates a single-shot message writer. Also known as an "unfragmented" message.
    pub fn init(underlying_writer: std.io.AnyWriter, message_len: usize, message_type: MessageType, mask: ws.message.frame.Mask) SingleFrameMessageWriter {
        const opcode: ws.message.frame.Opcode = switch (message_type) {
            .text => .text,
            .binary => .binary,
        };
        return SingleFrameMessageWriter{
            .underlying_writer = underlying_writer,
            .frame_header = ws.message.frame.AnyFrameHeader.init(true, opcode, message_len, mask),
        };
    }

    /// Creates a message which can be written to over multiple frames. Also known as a "fragmented" message.
    /// Must be closed before any other messages can be sent.
    pub fn initUnknownLength(underlying_writer: std.io.AnyWriter, message_type: MessageType, mask: ws.message.frame.Mask) MultiFrameMessageWriter {
        const opcode: ws.message.frame.Opcode = switch (message_type) {
            .text => .text,
            .binary => .binary,
        };
        return MultiFrameMessageWriter{
            .underlying_writer = underlying_writer,
            .opcode = opcode,
            .mask = mask,
        };
    }

    /// Creates a control message, which are internal to the websocket protocol and should be controlled by the library.
    /// Should only be used for creating a control message handler.
    pub fn initControl(underlying_writer: std.io.AnyWriter, message_len: usize, opcode: ws.message.frame.Opcode, mask: ws.message.frame.Mask) SingleFrameMessageWriter {
        return SingleFrameMessageWriter{
            .underlying_writer = underlying_writer,
            .frame_header = ws.message.frame.AnyFrameHeader.init(true, opcode, message_len, mask),
        };
    }

    pub fn payloadWriter(self: *AnyMessageWriter) std.io.AnyWriter {
        const writer_impl = switch (self.*) {
            inline else => |*impl| impl.payloadWriter(),
        };
        return writer_impl;
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
    pub fn write(self: *MultiFrameMessageWriter, bytes: []const u8) anyerror!usize {
        const frame_header = ws.message.frame.AnyFrameHeader.init(false, self.opcode, bytes.len, self.mask);

        // make sure that all but the first frame are continuation frames
        self.opcode = .continuation;

        try self.writeAndMaybeMask(frame_header, bytes);

        return bytes.len;
    }

    pub fn closeWithWrite(self: *MultiFrameMessageWriter, bytes: []const u8) !void {
        const frame_header = ws.message.frame.AnyFrameHeader.init(true, self.opcode, bytes.len, self.mask);

        try self.writeAndMaybeMask(frame_header, bytes);
    }

    fn writeAndMaybeMask(self: *MultiFrameMessageWriter, frame_header: ws.message.frame.AnyFrameHeader, payload: []const u8) !void {
        try frame_header.writeTo(self.underlying_writer);

        // do simple case if no mask
        if (!frame_header.asMostBasicHeader().mask) {
            return try self.underlying_writer.writeAll(payload);
        }

        const masking_key = frame_header.getMaskingKey() orelse return error.UnexpectedMaskBit;

        // mask while writing
        var bytes_idx: usize = 0;
        var buf: [1000]u8 = undefined;
        while (bytes_idx < payload.len) {
            const src_slice = payload[bytes_idx..@min(bytes_idx + 1000, payload.len)];
            const dest_slice = buf[0..src_slice.len];
            @memcpy(dest_slice, src_slice);
            ws.message.reader.mask_unmask(bytes_idx, masking_key, dest_slice);
            try self.underlying_writer.writeAll(dest_slice);

            bytes_idx += 1000;
        }
    }

    fn typeErasedWriteFn(ctx: *const anyopaque, bytes: []const u8) anyerror!usize {
        const ptr: *MultiFrameMessageWriter = @constCast(@alignCast(@ptrCast(ctx)));
        return write(ptr, bytes);
    }

    pub fn payloadWriter(self: *MultiFrameMessageWriter) std.io.AnyWriter {
        return std.io.AnyWriter{
            .context = @ptrCast(self),
            .writeFn = typeErasedWriteFn,
        };
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
    header_written: bool = false,
    payload_bytes_written: usize = 0,

    /// Writes data to the message as a single websocket frame
    pub fn write(self: *SingleFrameMessageWriter, bytes: []const u8) anyerror!usize {
        if (!self.header_written) {
            try self.frame_header.writeTo(self.underlying_writer);
            self.header_written = true;
        }
        const remaining_bytes = try self.frame_header.getPayloadLen() - self.payload_bytes_written;
        if (remaining_bytes == 0) {
            return error.EndOfStream;
        }
        const capped_bytes = bytes[0..@min(bytes.len, remaining_bytes)];

        // do simple case if no mask
        if (!self.frame_header.asMostBasicHeader().mask) {
            const n = try self.underlying_writer.write(capped_bytes);
            self.payload_bytes_written += n;
            return n;
        }

        const masking_key = self.frame_header.getMaskingKey() orelse return error.UnexpectedMaskBit;

        // mask while writing
        var masked_bytes_buf: [1000]u8 = undefined;

        const src_slice = capped_bytes[0..@min(capped_bytes.len, 1000)];
        const masked_slice = masked_bytes_buf[0..src_slice.len];
        @memcpy(masked_slice, src_slice);
        ws.message.reader.mask_unmask(0, masking_key, masked_slice);

        const n = try self.underlying_writer.write(masked_slice);
        self.payload_bytes_written += n;
        return n;
    }

    fn typeErasedWriteFn(ctx: *const anyopaque, bytes: []const u8) anyerror!usize {
        const ptr: *SingleFrameMessageWriter = @constCast(@alignCast(@ptrCast(ctx)));
        return write(ptr, bytes);
    }

    pub fn payloadWriter(self: *SingleFrameMessageWriter) std.io.AnyWriter {
        return std.io.AnyWriter{
            .context = @ptrCast(self),
            .writeFn = typeErasedWriteFn,
        };
    }

    pub fn any(self: SingleFrameMessageWriter) AnyMessageWriter {
        return .{ .unfragmented = self };
    }
};

pub const MessageType = enum {
    /// Indicates that the message is a valid UTF-8 string.
    text,
    /// Indicates that the message is binary data with no guarantees about encoding.
    binary,
};

// these tests come from the spec

test "A single-frame unmasked text message" {
    const message_payload = "Hello";
    var output = std.BoundedArray(u8, 100){};
    var message = AnyMessageWriter.init(output.writer().any(), message_payload.len, .text, .unmasked);
    var payload_writer = message.payloadWriter();
    try payload_writer.writeAll(message_payload);

    const expected = [_]u8{ 0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f };
    try std.testing.expectEqualSlices(u8, &expected, output.constSlice());
}

test "A single-frame masked text message" {
    const message_payload = "Hello";
    var output = std.BoundedArray(u8, 100){};
    var message = AnyMessageWriter.init(output.writer().any(), message_payload.len, .text, .{ .fixed_mask = 0x37fa213d });
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
    var pong = AnyMessageWriter.initControl(output.writer().any(), pong_payload.len, .pong, .{ .fixed_mask = 0x37fa213d });
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
