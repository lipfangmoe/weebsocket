const std = @import("std");
const ws = @import("../root.zig");

pub const AnyMessageWriter = union(enum) {
    unfragmented: UnfragmentedMessageWriter,
    fragmented: FragmentedMessageWriter,

    /// Creates a single-shot message writer. Also known as an "unfragmented" message.
    pub fn init(underlying_writer: std.io.AnyWriter, message_len: usize, message_type: MessageType, mask: ws.message.frame.Mask) AnyMessageWriter {
        const opcode: ws.message.frame.Opcode = switch (message_type) {
            .text => .text,
            .binary => .binary,
        };
        return AnyMessageWriter{
            .unfragmented = UnfragmentedMessageWriter{
                .underlying_writer = underlying_writer,
                .frame_header = ws.message.frame.AnyFrameHeader.init(true, opcode, message_len, mask),
            },
        };
    }

    /// Creates a message which can be written to over multiple frames. Also known as a "fragmented" message.
    /// Must be closed before any other messages can be sent.
    pub fn initUnknownLength(underlying_writer: std.io.AnyWriter, message_type: MessageType, mask: ws.message.frame.Mask) AnyMessageWriter {
        const opcode: ws.message.frame.Opcode = switch (message_type) {
            .text => .text,
            .binary => .binary,
        };
        return AnyMessageWriter{
            .fragmented = FragmentedMessageWriter{
                .underlying_writer = underlying_writer,
                .opcode = opcode,
                .mask = mask,
            },
        };
    }

    /// Creates a control message, which are internal to the websocket protocol and should be controlled by the library.
    /// Should only be used for manually sending pings or creating a control message handler.
    pub fn initControl(underlying_writer: std.io.AnyWriter, message_len: usize, opcode: ws.message.frame.Opcode, mask: ws.message.frame.Mask) AnyMessageWriter {
        return AnyMessageWriter{
            .unfragmented = UnfragmentedMessageWriter{
                .underlying_writer = underlying_writer,
                .frame_header = ws.message.frame.AnyFrameHeader.init(true, opcode, message_len, mask),
            },
        };
    }

    pub fn payload_writer(self: *AnyMessageWriter) std.io.AnyWriter {
        const writer_impl = switch (self.*) {
            inline else => |*impl| impl.payload_writer(),
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
pub const FragmentedMessageWriter = struct {
    underlying_writer: std.io.AnyWriter,
    opcode: ws.message.frame.Opcode,
    mask: ws.message.frame.Mask,

    /// Writes data to the message as a single websocket frame
    pub fn write(self: *FragmentedMessageWriter, bytes: []const u8) anyerror!usize {
        const frame_header = ws.message.frame.AnyFrameHeader.init(false, self.opcode, bytes.len, self.mask);

        // make sure that all but the first frame are continuation frames
        self.opcode = .continuation;

        try self.writeAndMaybeMask(frame_header, bytes);

        return bytes.len;
    }

    pub fn closeWithWrite(self: *FragmentedMessageWriter, bytes: []const u8) !void {
        const frame_header = ws.message.frame.AnyFrameHeader.init(true, self.opcode, bytes.len, self.mask);

        try self.writeAndMaybeMask(frame_header, bytes);
    }

    fn writeAndMaybeMask(self: *FragmentedMessageWriter, frame_header: ws.message.frame.AnyFrameHeader, payload: []const u8) !void {
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
        const ptr: *FragmentedMessageWriter = @constCast(@alignCast(@ptrCast(ctx)));
        return write(ptr, bytes);
    }

    pub fn payload_writer(self: *FragmentedMessageWriter) std.io.AnyWriter {
        return std.io.AnyWriter{
            .context = @ptrCast(self),
            .writeFn = typeErasedWriteFn,
        };
    }

    pub fn close(self: *FragmentedMessageWriter) !void {
        try closeWithWrite(self, &.{});
    }
};

pub const UnfragmentedMessageWriter = struct {
    underlying_writer: std.io.AnyWriter,
    frame_header: ws.message.frame.AnyFrameHeader,
    header_written: bool = false,
    payload_bytes_written: usize = 0,

    /// Writes data to the message as a single websocket frame
    pub fn write(self: *UnfragmentedMessageWriter, bytes: []const u8) anyerror!usize {
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
        const ptr: *UnfragmentedMessageWriter = @constCast(@alignCast(@ptrCast(ctx)));
        return write(ptr, bytes);
    }

    pub fn payload_writer(self: *UnfragmentedMessageWriter) std.io.AnyWriter {
        return std.io.AnyWriter{
            .context = @ptrCast(self),
            .writeFn = typeErasedWriteFn,
        };
    }
};

pub const MessageType = enum { text, binary };
