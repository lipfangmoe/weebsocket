const std = @import("std");
const ws = @import("../root.zig");

pub const Error = error{ Overflow, EndOfStream, UnderlyingWriteFailed } || std.Io.Cancelable;

pub const MessageWriter = struct {
    pub const init = UnfragmentedMessageWriter.init;
    pub const initUnknownLength = FragmentedMessageWriter.init;
};

/// Represents an outgoing message which will only span one frame. Errors can be found in `.state.err`.
///
/// Noteworthy that the flush implementation of this writer will *also* flush the underlying writer (aka the websocket buffer).
pub const UnfragmentedMessageWriter = struct {
    interface: std.Io.Writer,
    underlying_writer: *std.Io.Writer,
    header: ws.message.frame.AnyFrameHeader,
    state: State = .writing_header,

    /// Creates a message writer with a known length, aka an Unfragmented Message.
    pub fn init(underlying_writer: *std.Io.Writer, message_len: usize, message_type: ws.message.Type, mask_strategy: ws.message.frame.MaskStrategy, buffer: []u8) UnfragmentedMessageWriter {
        const opcode = message_type.toOpcode();
        const header = ws.message.frame.AnyFrameHeader.init(true, opcode, message_len, mask_strategy);
        return .initWithHeader(underlying_writer, header, buffer);
    }

    pub fn initWithHeader(underlying_writer: *std.Io.Writer, header: ws.message.frame.AnyFrameHeader, buffer: []u8) UnfragmentedMessageWriter {
        return UnfragmentedMessageWriter{
            .underlying_writer = underlying_writer,
            .header = header,
            .interface = .{
                .buffer = buffer,
                .vtable = &.{ .drain = drainFn, .flush = flushFn },
            },
        };
    }

    /// Creates a control message, which are internal to the websocket protocol and should be controlled by the library.
    /// Should only be used when creating a control message handler.
    pub fn initControl(
        underlying_writer: *std.Io.Writer,
        payload_len: usize,
        opcode: ws.message.frame.Opcode,
        mask_strategy: ws.message.frame.MaskStrategy,
        buffer: []u8,
    ) UnfragmentedMessageWriter {
        const frame_header = ws.message.frame.AnyFrameHeader.init(true, opcode, payload_len, mask_strategy);
        return .initWithHeader(underlying_writer, frame_header, buffer);
    }

    fn drainFn(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *UnfragmentedMessageWriter = @alignCast(@fieldParentPtr("interface", writer));
        return drain(self, data, splat) catch |err| {
            self.state = .{ .err = err };
            return error.WriteFailed;
        };
    }

    fn drain(self: *UnfragmentedMessageWriter, data: []const []const u8, splat: usize) Error!usize {
        return switch (self.state) {
            .writing_header => try self.writeHeader(),
            .writing_payload => try self.writePayload(data, splat),
            .complete => if (self.interface.buffered().len + std.Io.Writer.countSplat(data, splat) > 0)
                return error.EndOfStream
            else
                0,
            .err => |err| return err,
        };
    }

    fn flushFn(writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *UnfragmentedMessageWriter = @alignCast(@fieldParentPtr("interface", writer));
        try self.interface.defaultFlush();
        try self.underlying_writer.flush();
    }

    fn writeHeader(self: *UnfragmentedMessageWriter) Error!usize {
        std.debug.assert(self.state == .writing_header);

        self.header.writeTo(self.underlying_writer) catch return error.UnderlyingWriteFailed;
        self.state = .{ .writing_payload = 0 };

        return 0;
    }

    fn writePayload(self: *UnfragmentedMessageWriter, data: []const []const u8, splat: usize) Error!usize {
        std.debug.assert(self.state == .writing_payload);
        const payload_len = try self.header.getPayloadLen();
        const n = try payloadDrain(&self.interface, self.underlying_writer, payload_len, self.state.writing_payload, self.header.getMaskingKey(), data, splat);
        self.state.writing_payload += n;
        const consumed_from_data = self.interface.consume(n);

        if (self.state.writing_payload == payload_len) {
            self.state = .complete;
        }
        return consumed_from_data;
    }

    pub const State = union(enum) {
        writing_header: void,
        writing_payload: u64, // u64 is how many bytes have been written
        complete: void,
        err: Error,
    };
};

/// Represents an outgoing message that may span multiple frames. Errors can be found in `.state.err`.
///
/// Noteworthy that the flush implementation of this writer will *also* flush the underlying writer (aka the websocket buffer)
pub const FragmentedMessageWriter = struct {
    interface: std.Io.Writer,
    underlying_writer: *std.Io.Writer,
    opcode: ws.message.frame.Opcode,
    mask_strategy: ws.message.frame.MaskStrategy,
    state: State,

    pub fn init(underlying_writer: *std.Io.Writer, message_type: ws.message.Type, mask_strategy: ws.message.frame.MaskStrategy, buffer: []u8) FragmentedMessageWriter {
        return .{
            .interface = .{
                .buffer = buffer,
                .vtable = &.{ .drain = drainFn, .flush = flush },
            },
            .underlying_writer = underlying_writer,
            .opcode = message_type.toOpcode(),
            .mask_strategy = mask_strategy,
            .state = .{ .waiting_for_begin_header_fragment = .{ .is_first = true } },
        };
    }

    pub fn beginPayloadFragment(self: *FragmentedMessageWriter, len: usize, final: bool) std.Io.Writer.Error!void {
        try self.interface.flush();
        std.debug.assert(self.state == .waiting_for_begin_header_fragment);

        const is_first = self.state.waiting_for_begin_header_fragment.is_first;
        const opcode = if (is_first) self.opcode else .continuation;
        const header: ws.message.frame.AnyFrameHeader = .init(final, opcode, len, self.mask_strategy);
        self.state = .{ .writing_header = header };
    }

    fn drainFn(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FragmentedMessageWriter = @alignCast(@fieldParentPtr("interface", writer));
        return drain(self, data, splat) catch |err| {
            self.state = .{ .err = err };
            return error.WriteFailed;
        };
    }

    fn drain(self: *FragmentedMessageWriter, data: []const []const u8, splat: usize) Error!usize {
        return switch (self.state) {
            .waiting_for_begin_header_fragment => 0,
            .writing_header => try self.writeHeader(),
            .writing_payload => try self.writePayload(data, splat),
            .complete => if (self.interface.buffered().len + std.Io.Writer.countSplat(data, splat) > 0)
                error.EndOfStream
            else
                0,
            .err => |err| return err,
        };
    }

    fn flush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *FragmentedMessageWriter = @alignCast(@fieldParentPtr("interface", writer));
        try self.interface.defaultFlush();
        try self.underlying_writer.flush();
    }

    fn writeHeader(self: *FragmentedMessageWriter) Error!usize {
        std.debug.assert(self.state == .writing_header);
        const header = self.state.writing_header;

        header.writeTo(self.underlying_writer) catch return error.UnderlyingWriteFailed;
        self.state = .{ .writing_payload = .{ .header = header, .written = 0 } };

        return 0;
    }

    fn writePayload(self: *FragmentedMessageWriter, data: []const []const u8, splat: usize) Error!usize {
        std.debug.assert(self.state == .writing_payload);

        const payload_len = try self.state.writing_payload.header.getPayloadLen();
        if (self.state.writing_payload.written == payload_len) {
            return error.EndOfStream;
        }

        const written = try payloadDrain(&self.interface, self.underlying_writer, payload_len, self.state.writing_payload.written, self.state.writing_payload.header.getMaskingKey(), data, splat);
        const consued_from_data = self.interface.consume(written);
        self.state.writing_payload.written += written;

        if (self.state.writing_payload.written == payload_len) {
            if (self.state.writing_payload.header.asMostBasicHeader().fin) {
                self.state = .complete;
            } else {
                self.state = .{ .waiting_for_begin_header_fragment = .{ .is_first = false } };
            }
        }

        return consued_from_data;
    }

    pub const State = union(enum) {
        waiting_for_begin_header_fragment: struct { is_first: bool },
        writing_header: ws.message.frame.AnyFrameHeader,
        writing_payload: struct { header: ws.message.frame.AnyFrameHeader, written: u64 },
        complete: void,
        err: Error,
    };
};

fn payloadDrain(
    self_interface: *std.Io.Writer,
    underlying_writer: *std.Io.Writer,
    payload_len: usize,
    written: usize,
    masking_key: ?[4]u8,
    data: []const []const u8,
    splat: usize,
) Error!usize {
    const payload_remaining_bytes = payload_len - written;

    if (payload_remaining_bytes == 0) {
        const bytes_trying_to_write = self_interface.end + std.Io.Writer.countSplat(data, splat);
        if (bytes_trying_to_write > 0) {
            return error.EndOfStream;
        }
    }

    // TODO - writeSplatHeaderLimit does not work well with fixed writer

    // do simple write if no mask
    if (masking_key == null) {
        return myWriteSplatHeaderLimit(underlying_writer, self_interface.buffered(), data, splat, .limited(payload_remaining_bytes)) catch return error.UnderlyingWriteFailed;
    }

    // mask while writing
    var masked_buf: [8000]u8 = undefined;
    const max_bytes = @min(payload_remaining_bytes, masked_buf.len);
    var buf_writer = std.Io.Writer.fixed(&masked_buf);

    _ = myWriteSplatHeaderLimit(underlying_writer, self_interface.buffered(), data, splat, .limited(max_bytes)) catch unreachable;
    ws.message.mask_unmask(written, masking_key.?, buf_writer.buffered());
    return underlying_writer.write(buf_writer.buffered()) catch return error.UnderlyingWriteFailed;
}

fn myWriteSplatHeaderLimit(w: *std.Io.Writer, header: []const u8, data: []const []const u8, splat: usize, limit: std.Io.Limit) std.Io.Writer.Error!usize {
    if (header.len > 0) {
        return try w.write(limit.sliceConst(header));
    }
    if (data.len > 0) {
        if (data.len > 1 and data[0].len > 0) {
            return try w.write(limit.sliceConst(data[0]));
        }
        if (data.len == 1) {
            var written: usize = 0;
            for (0..splat) |_| {
                const reduced_limit = limit.subtract(written) orelse break;
                const n = try w.write(reduced_limit.sliceConst(data[0]));
                written += n;
                if (n != data[0].len) {
                    break;
                }
            }

            return written;
        }
    }
    return 0;
}

// these tests come from the spec

test "A single-frame unmasked text message" {
    const message_payload = "Hello";
    var output_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output_writer.deinit();
    var message_writer_buf: [100]u8 = undefined;
    var message_writer: UnfragmentedMessageWriter = .init(&output_writer.writer, message_payload.len, .text, .unmasked, &message_writer_buf);
    try message_writer.interface.writeAll(message_payload);
    try message_writer.interface.flush();

    const expected = [_]u8{ 0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f };
    try std.testing.expectEqualSlices(u8, &expected, output_writer.written());
}

test "A single-frame masked text message" {
    const message_payload = "Hello";
    var output_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output_writer.deinit();
    var message_writer_buf: [100]u8 = undefined;
    var message_writer: UnfragmentedMessageWriter = .init(&output_writer.writer, message_payload.len, .text, .{ .fixed = 0x37fa213d }, &message_writer_buf);
    try message_writer.interface.writeAll(message_payload);
    try message_writer.interface.flush();

    const expected = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    try std.testing.expectEqualSlices(u8, &expected, output_writer.written());
}

test "A fragmented unmasked text message" {
    var output_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output_writer.deinit();
    var buf: [100]u8 = undefined;
    var message_writer: FragmentedMessageWriter = .init(&output_writer.writer, .text, .unmasked, &buf);

    try message_writer.beginPayloadFragment(3, false);
    try message_writer.interface.writeAll("Hel");

    try message_writer.beginPayloadFragment(2, true);
    try message_writer.interface.writeAll("lo");

    try message_writer.interface.flush();

    const expected = [_]u8{ 0x01, 0x03, 0x48, 0x65, 0x6c, 0x80, 0x02, 0x6c, 0x6f };
    try std.testing.expectEqualSlices(u8, &expected, output_writer.written());
}

test "(not in spec) A fragmented unmasked text message interrupted with a masked control frame" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var buf: [100]u8 = undefined;
    var message_writer: FragmentedMessageWriter = .init(&output.writer, .text, .unmasked, &buf);

    try message_writer.beginPayloadFragment(3, false);
    try message_writer.interface.writeAll("Hel");
    try message_writer.interface.flush();

    // simulate pong response in the middle of fragmented payload
    const pong_payload = "Hello";
    var pong_buf: [100]u8 = undefined;
    var pong: UnfragmentedMessageWriter = .initControl(&output.writer, pong_payload.len, .pong, .{ .fixed = 0x37fa213d }, &pong_buf);
    try pong.interface.writeAll(pong_payload);
    try pong.interface.flush();

    try message_writer.beginPayloadFragment(2, true);
    try message_writer.interface.writeAll("lo");
    try message_writer.interface.flush();

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

test "(not in spec) example that messed me up" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const close_reason = "invalid frame header";
    var buf: [100]u8 = undefined;
    var message_writer: UnfragmentedMessageWriter = .initControl(&output.writer, close_reason.len + 2, .close, .{ .fixed = 0xd585b161 }, &buf);
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
