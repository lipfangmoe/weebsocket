const std = @import("std");
const ws = @import("../root.zig");
const utf8_validator = @import("./utf8_validator.zig");

pub const ReadHeaderError = error{
    EndOfStream,
    ReceivedCloseFrame,
    InvalidMessage,
    PayloadTooLong,
    UnexpectedReadFailure,
    UnexpectedControlFrameResponseFailure,
};
pub const StreamPayloadError = error{
    EndOfStream,
    PayloadTooLong,
    InvalidMessage,
    UnexpectedReadFailure,
    UnexpectedWriteFailure,
    InvalidUtf8,
} || std.Io.Writer.Error;
pub const StreamError = ReadHeaderError || StreamPayloadError;

pub const MessageReader = struct {
    underlying_reader: *std.Io.Reader,
    buf: []u8,
    reader_impl: ?ReaderImpl = null,
    control_frame_writer: *std.Io.Writer,
    controlFrameHandler: ws.message.ControlFrameHeaderHandlerFn,
    stream_error: ?StreamError = null,

    pub fn init(underlying_reader: *std.Io.Reader, controlFrameHandler: ws.message.ControlFrameHeaderHandlerFn, control_frame_writer: *std.Io.Writer, buf: []u8) MessageReader {
        return .{
            .underlying_reader = underlying_reader,
            .controlFrameHandler = controlFrameHandler,
            .control_frame_writer = control_frame_writer,
            .buf = buf,
        };
    }

    // reads headers from reader
    pub fn receiveHead(self: *MessageReader) ReadHeaderError!void {
        const header = try readUntilDataFrameHeader(self.controlFrameHandler, self.underlying_reader, self.control_frame_writer);
        if (header.asMostBasicHeader().opcode == .continuation) {
            ws.log.err("continuation frame found as initial frame, which is not allowed", .{});
            return error.InvalidMessage;
        }

        if (header.asMostBasicHeader().fin) {
            self.reader_impl = .{ .unfragmented = .init(self.underlying_reader, header, self.buf) };
        } else {
            self.reader_impl = .{ .fragmented = .init(self.underlying_reader, self.control_frame_writer, self.controlFrameHandler, header, self.buf) };
        }
    }

    pub fn reader(self: *MessageReader) *std.Io.Reader {
        if (self.reader_impl) |*payload_reader| {
            return switch (payload_reader.*) {
                .unfragmented => |*unfragmented| &unfragmented.interface,
                .fragmented => |*fragmented| &fragmented.interface,
            };
        } else {
            std.debug.panic("payloadReader() must be called after `waitForMessage`", .{});
        }
    }

    // if a reader error is ever encountered, this is a surefire way to get a more specific error than `error.ReadFailed`
    pub fn payloadReadError(self: *MessageReader) ?StreamError {
        if (self.stream_error) |stream_error| {
            return stream_error;
        }
        const reader_impl = self.reader_impl orelse return null;
        return reader_impl.err();
    }
};

pub const ReaderImpl = union(enum) {
    unfragmented: UnfragmentedPayloadReader,
    fragmented: FragmentedPayloadReader,

    /// Returns error if this is called on a message that is either invalid, or a control frame.
    pub fn getMessageType(self: ReaderImpl) ws.message.Type {
        const opcode = switch (self) {
            .fragmented => |frag| frag.first_header.asMostBasicHeader().opcode,
            .unfragmented => |unfrag| unfrag.frame_header.asMostBasicHeader().opcode,
        };
        return ws.message.Type.fromOpcode(opcode) catch std.debug.panic("getMessageType called on control frame header", .{});
    }

    pub fn payloadLen(self: ReaderImpl) ?usize {
        return switch (self) {
            .fragmented => null,
            .unfragmented => |unfrag| unfrag.frame_header.getPayloadLen() catch null,
        };
    }

    pub fn err(self: ReaderImpl) ?StreamError {
        return switch (self) {
            .fragmented => |frag| switch (frag.state) {
                .err => |errr| return errr,
                else => return null,
            },
            .unfragmented => |unfrag| switch (unfrag.state) {
                .err => |errr| return errr,
                else => return null,
            },
        };
    }
};

/// Represents an incoming message that may span multiple frames.
pub const FragmentedPayloadReader = struct {
    underlying_reader: *std.Io.Reader,
    control_frame_writer: *std.Io.Writer,
    controlFrameHandler: ws.message.ControlFrameHeaderHandlerFn,
    first_header: ws.message.frame.AnyFrameHeader,
    state: State,
    interface: std.Io.Reader,

    pub fn init(
        underlying_reader: *std.Io.Reader,
        control_frame_writer: *std.Io.Writer,
        controlFrameHandler: ws.message.ControlFrameHeaderHandlerFn,
        first_header: ws.message.frame.AnyFrameHeader,
        buf: []u8,
    ) FragmentedPayloadReader {
        return FragmentedPayloadReader{
            .underlying_reader = underlying_reader,
            .control_frame_writer = control_frame_writer,
            .controlFrameHandler = controlFrameHandler,
            .first_header = first_header,
            .state = .{ .in_payload = .{
                .header = first_header,
                .idx = 0,
                .prev_partial_codepoint_buf = .{ 0, 0, 0 },
                .prev_partial_codepoint_len = 0,
            } },
            .interface = .{ .buffer = buf, .seek = 0, .end = 0, .vtable = &.{ .stream = &streamFn } },
        };
    }

    fn streamFn(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *FragmentedPayloadReader = @alignCast(@fieldParentPtr("interface", reader));
        return self.stream(writer, limit) catch |err| {
            self.state = .{ .err = err };
            if (err == error.EndOfStream) {
                return error.EndOfStream;
            }
            return error.ReadFailed;
        };
    }

    fn stream(self: *FragmentedPayloadReader, writer: *std.Io.Writer, limit: std.Io.Limit) StreamError!usize {
        switch (self.state) {
            .waiting_for_next_header => |state| {
                const header = try readUntilDataFrameHeader(self.controlFrameHandler, self.underlying_reader, self.control_frame_writer);
                if (header.asMostBasicHeader().opcode != .continuation) {
                    ws.log.err("frame type {} found while reading fragmented message, should be .continuation", .{header.asMostBasicHeader().opcode});
                    return error.InvalidMessage;
                }
                self.state = .{
                    .in_payload = .{
                        .header = header,
                        .idx = 0,
                        .prev_partial_codepoint_buf = state.prev_partial_codepoint_buf,
                        .prev_partial_codepoint_len = state.prev_partial_codepoint_len,
                    },
                };
            },
            .err => |err| return err,
            .done => return error.EndOfStream,
            .in_payload => {},
        }

        // we are now guaranteed to be in state `.in_payload`
        const state = &self.state.in_payload;
        const payload_len = state.header.getPayloadLen() catch {
            return error.PayloadTooLong;
        };
        const remaining_bytes = payload_len - state.idx;
        if (remaining_bytes == 0) {
            return try handleEndOfFragment(&self.state);
        }
        var buf: [1000]u8 = undefined;
        var buf_writer = std.Io.Writer.fixed(&buf);
        const n = self.underlying_reader.stream(&buf_writer, limit.min(.limited(remaining_bytes)).min(.limited(buf.len))) catch |err| switch (err) {
            error.EndOfStream => {
                return try handleEndOfFragment(&self.state);
            },
            error.ReadFailed => {
                ws.log.err("Error while reading payload of unfragmented message: {}", .{err});
                return error.UnexpectedReadFailure;
            },
            error.WriteFailed => unreachable,
        };

        // if the opcode is .text, we need to validate that the read contains valid utf8 text
        if (self.first_header.asMostBasicHeader().opcode == .text) {
            var next_partial_codepoint_buf: [3]u8 = undefined;
            var next_partial_codepoint = std.ArrayList(u8).initBuffer(&next_partial_codepoint_buf);
            const prev_partial_codepoint = state.prev_partial_codepoint_buf[0..state.prev_partial_codepoint_len];
            utf8_validator.utf8ValidateStream(prev_partial_codepoint, buf_writer.buffered(), &next_partial_codepoint) catch |err| {
                ws.log.err("invalid utf8 encountered while decoding .text frame of fragmented message: utf8ValidateStream({x}, {x}) returned {}", .{ prev_partial_codepoint, buf_writer.buffered(), err });
                return error.InvalidUtf8;
            };
        }

        // masking
        if (state.header.asMostBasicHeader().mask) {
            const masking_key = state.header.getMaskingKey() orelse {
                ws.log.err("invalid state: mask bit is set but header does not have a masking key", .{});
                return error.InvalidMessage;
            };
            ws.message.mask_unmask(state.idx, masking_key, buf_writer.buffered());
        }
        state.idx += n;

        try writer.writeAll(buf_writer.buffered());
        return n;
    }

    fn handleEndOfFragment(state: *State) StreamError!usize {
        if (state.in_payload.header.asMostBasicHeader().fin) {
            if (state.in_payload.prev_partial_codepoint_len > 0) {
                return error.InvalidUtf8;
            }
            state.* = .done;
            return error.EndOfStream;
        }
        const prev_state = state.in_payload;
        state.* = .{
            .waiting_for_next_header = .{
                .prev_partial_codepoint_len = prev_state.prev_partial_codepoint_len,
                .prev_partial_codepoint_buf = prev_state.prev_partial_codepoint_buf,
            },
        };
        return 0;
    }

    pub const State = union(enum) {
        in_payload: struct {
            header: ws.message.frame.AnyFrameHeader,
            idx: usize,
            prev_partial_codepoint_buf: [3]u8,
            prev_partial_codepoint_len: u8,
        },
        waiting_for_next_header: struct {
            prev_partial_codepoint_buf: [3]u8,
            prev_partial_codepoint_len: u8,
        },
        err: StreamError,
        done: void,
    };
};

pub const UnfragmentedPayloadReader = struct {
    underlying_reader: *std.Io.Reader,
    frame_header: ws.message.frame.AnyFrameHeader,
    state: State,
    interface: std.Io.Reader,

    pub fn init(underlying_reader: *std.Io.Reader, frame_header: ws.message.frame.AnyFrameHeader, buffer: []u8) UnfragmentedPayloadReader {
        return .{
            .underlying_reader = underlying_reader,
            .frame_header = frame_header,
            .state = .{
                .ok = .{
                    .payload_idx = 0,
                    .prev_partial_codepoint_buf = .{ 0, 0, 0 },
                    .prev_partial_codepoint_len = 0,
                },
            },
            .interface = .{
                .buffer = buffer,
                .seek = 0,
                .end = 0,
                .vtable = &.{ .stream = &streamFn },
            },
        };
    }

    fn streamFn(interface: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *UnfragmentedPayloadReader = @alignCast(@fieldParentPtr("interface", interface));
        return self.stream(writer, limit) catch |err| {
            switch (err) {
                error.EndOfStream => return error.EndOfStream,
                else => return error.ReadFailed,
            }
        };
    }

    fn stream(self: *UnfragmentedPayloadReader, writer: *std.Io.Writer, limit: std.Io.Limit) StreamPayloadError!usize {
        const state = switch (self.state) {
            .err => |err| return err,
            .ok => |*ok| ok,
        };

        const payload_len = self.frame_header.getPayloadLen() catch {
            return error.PayloadTooLong;
        };

        const remaining_payload = payload_len - state.payload_idx;
        if (remaining_payload == 0) {
            if (state.prev_partial_codepoint_len > 0) {
                const prev_partial_codepoint = state.prev_partial_codepoint_buf[0..state.prev_partial_codepoint_len];
                ws.log.err("payload ended in the middle of a utf8 byte sequence: {x}, expected {} more bytes", .{ prev_partial_codepoint, std.unicode.utf8ByteSequenceLength(prev_partial_codepoint[0]) catch unreachable });
                return error.InvalidUtf8;
            }
            return error.EndOfStream;
        }

        var buf: [1000]u8 = undefined;
        var buf_writer = std.Io.Writer.fixed(&buf);
        const bytes_streamed = self.underlying_reader.stream(&buf_writer, limit.min(.limited(remaining_payload)).min(.limited(buf.len))) catch |err| switch (err) {
            error.EndOfStream => {
                if (state.prev_partial_codepoint_len > 0) {
                    const prev_partial_codepoint = state.prev_partial_codepoint_buf[0..state.prev_partial_codepoint_len];
                    ws.log.err("payload ended in the middle of a utf8 byte sequence: {x}, expected {} more bytes", .{ prev_partial_codepoint, std.unicode.utf8ByteSequenceLength(prev_partial_codepoint[0]) catch unreachable });
                    return error.InvalidUtf8;
                }
                return error.EndOfStream;
            },
            error.ReadFailed => {
                ws.log.err("Error while reading payload of unfragmented message: {}", .{err});
                return error.UnexpectedReadFailure;
            },
            error.WriteFailed => unreachable,
        };

        // masking
        if (self.frame_header.asMostBasicHeader().mask) {
            const masking_key = self.frame_header.getMaskingKey() orelse {
                ws.log.err("invalid state: mask bit is set but header does not have a masking key", .{});
                return error.InvalidMessage;
            };
            ws.message.mask_unmask(state.payload_idx, masking_key, buf_writer.buffered());
        }
        state.payload_idx += bytes_streamed;

        if (self.frame_header.asMostBasicHeader().opcode == .text) {
            var next_partial_codepoint_buf: [3]u8 = undefined;
            var next_partial_codepoint = std.ArrayList(u8).initBuffer(&next_partial_codepoint_buf);
            const prev_partial_codepoint = state.prev_partial_codepoint_buf[0..state.prev_partial_codepoint_len];
            utf8_validator.utf8ValidateStream(prev_partial_codepoint, buf_writer.buffered(), &next_partial_codepoint) catch |err| {
                ws.log.err("invalid utf8 encountered while decoding .text frame of unfragmented message: utf8ValidateStream({x}, {x}) returned {}", .{ prev_partial_codepoint, buf_writer.buffered(), err });
                return error.InvalidUtf8;
            };
            @memcpy(state.prev_partial_codepoint_buf[0..next_partial_codepoint.items.len], next_partial_codepoint.items);
            state.prev_partial_codepoint_len = next_partial_codepoint.items.len;
        }

        // this recursion has max depth of 1 since the buffer already contains `bytes_streamed` bytes
        try writer.writeAll(buf_writer.buffered());
        return bytes_streamed;
    }

    pub const State = union(enum) {
        ok: struct {
            payload_idx: usize = 0,
            prev_partial_codepoint_buf: [3]u8,
            prev_partial_codepoint_len: usize,
        },
        err: StreamPayloadError,
    };
};

/// loops through messages until a non-control frame is found, calling controlFrameHandler on each control frame.
fn readUntilDataFrameHeader(
    controlFrameHandler: ws.message.ControlFrameHeaderHandlerFn,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) ReadHeaderError!ws.message.frame.AnyFrameHeader {
    while (true) {
        const current_header = ws.message.frame.AnyFrameHeader.readFrom(reader) catch |err| return switch (err) {
            error.EndOfStream => error.EndOfStream,
            else => {
                ws.log.err("error occurred while parsing header: {}", .{err});
                return error.InvalidMessage;
            },
        };
        const basic_header = current_header.asMostBasicHeader();
        if (basic_header.rsv1 or basic_header.rsv2 or basic_header.rsv3) {
            ws.log.err("reserve bits set rsv123=0b{b}{b}{b}", .{ @intFromBool(basic_header.rsv1), @intFromBool(basic_header.rsv2), @intFromBool(basic_header.rsv3) });
            return error.InvalidMessage;
        }
        if (basic_header.opcode.isControlFrame()) {
            const control_frame_header: ws.message.frame.FrameHeader(.u16, false) = switch (current_header) {
                .u16_unmasked => |impl| impl,
                else => |impl| {
                    ws.log.err("recevied control frame had a header of an unexpected size: {}", .{impl});
                    return error.InvalidMessage;
                },
            };
            if (!control_frame_header.fin) {
                ws.log.err("peer gave us a control frame which is fragmented, which is not allowed", .{});
                return error.InvalidMessage;
            }

            var payload_buf: [125]u8 = undefined;
            var payload_buf_writer = std.Io.Writer.fixed(&payload_buf);
            reader.streamExact(&payload_buf_writer, control_frame_header.payload_len) catch |err| {
                ws.log.err("Unexpected read failure when reading payload from control frame: {}", .{err});
                return error.UnexpectedReadFailure;
            };

            controlFrameHandler(writer, control_frame_header, payload_buf_writer.buffered()) catch |err| return switch (err) {
                error.ReceivedCloseFrame => |err_cast| err_cast,
                error.WriteFailed => error.UnexpectedControlFrameResponseFailure,
            };
            continue;
        }
        if (!basic_header.opcode.isDataFrame()) {
            ws.log.err("peer gave us opcode {}, which is not a valid opcode", .{@intFromEnum(basic_header.opcode)});
            return error.InvalidMessage;
        }

        return current_header;
    }
}

// these tests come from the spec

test "A single-frame unmasked text message" {
    const bytes = [_]u8{ 0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f };
    var reader = std.Io.Reader.fixed(&bytes);
    var message_reader_buf: [100]u8 = undefined;
    var writer_buf: [100]u8 = undefined;
    var writer = std.Io.Writer.Discarding.init(&writer_buf);
    var message_reader = MessageReader.init(
        &reader,
        &panic_control_frame_handler,
        &writer.writer,
        &message_reader_buf,
    );
    try message_reader.receiveHead();
    var output: [100]u8 = undefined;
    const output_len = try message_reader.reader().readSliceShort(&output);

    try std.testing.expectEqualStrings("Hello", output[0..output_len]);
}

// technically server-to-client messages should never be masked, but maybe one day MessageReader will be re-used to make a Websocket Server...
test "A single-frame masked text message" {
    const bytes = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    var writer_buf: [100]u8 = undefined;
    var message_reader_buf: [100]u8 = undefined;
    var reader = std.Io.Reader.fixed(&bytes);
    var writer = std.Io.Writer.Discarding.init(&writer_buf);
    var message_reader = MessageReader.init(
        &reader,
        &panic_control_frame_handler,
        &writer.writer,
        &message_reader_buf,
    );
    try message_reader.receiveHead();
    var output: [100]u8 = undefined;
    const output_len = try message_reader.reader().readSliceShort(&output);

    try std.testing.expectEqualStrings("Hello", output[0..output_len]);
}

test "A fragmented unmasked text message" {
    const reader_buf = [_]u8{ 0x01, 0x03, 0x48, 0x65, 0x6c, 0x80, 0x02, 0x6c, 0x6f };
    var reader = std.Io.Reader.fixed(&reader_buf);
    var message_reader_buf: [100]u8 = undefined;
    var writer_buf: [100]u8 = undefined;
    var writer = std.Io.Writer.Discarding.init(&writer_buf);
    var message_reader = MessageReader.init(
        &reader,
        &panic_control_frame_handler,
        &writer.writer,
        &message_reader_buf,
    );
    try message_reader.receiveHead();
    var output: [100]u8 = undefined;
    const output_len = try message_reader.reader().readSliceShort(&output);

    try std.testing.expectEqualStrings("Hello", output[0..output_len]);
}

test "a long unfragmented unmasked message" {
    const header = ws.message.frame.AnyFrameHeader{ .u32_unmasked = .{
        .fin = true,
        .opcode = .text,
        .mask = false,
        .masking_key = void{},
        .payload_len = 126,
        .extended_payload_len = 10_000,
        .rsv1 = false,
        .rsv2 = false,
        .rsv3 = false,
    } };
    const payload: [10_000]u8 = .{42} ** 10_000;

    var full_message_writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    try header.writeTo(&full_message_writer.writer);
    try full_message_writer.writer.writeAll(&payload);
    defer full_message_writer.deinit();

    var reader = std.Io.Reader.fixed(full_message_writer.written());
    var message_reader_buf: [100]u8 = undefined;
    var writer_buf: [100]u8 = undefined;
    var writer = std.Io.Writer.Discarding.init(&writer_buf);
    var message_reader = MessageReader.init(
        &reader,
        &panic_control_frame_handler,
        &writer.writer,
        &message_reader_buf,
    );
    try message_reader.receiveHead();
    var output: [10_000]u8 = undefined;
    const output_len = try message_reader.reader().readSliceShort(&output);

    try std.testing.expectEqualSlices(u8, &payload, output[0..output_len]);
}

test "(not in spec) A fragmented unmasked text message interrupted with a control frame" {
    const incoming_bytes = [_]u8{
        // first fragment: "Hel"
        0x01, 0x03, 0x48, 0x65, 0x6c,
        // interrupted by control frame, PING "Hello"
        0x89, 0x05, 0x48, 0x65, 0x6c,
        0x6c, 0x6f,
        // second fragment: "lo"
        0x80, 0x02, 0x6c,
        0x6f,
    };
    var reader = std.Io.Reader.fixed(&incoming_bytes);
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();

    var message_reader_buf: [1000]u8 = undefined;
    var message_reader = MessageReader.init(
        &reader,
        &ws.message.controlFrameHandlerWithMask(.{ .fixed_mask = 0x37FA213D }),
        &writer.writer,
        &message_reader_buf,
    );
    try message_reader.receiveHead();

    var output: [100]u8 = undefined;
    const output_len = try message_reader.reader().readSliceShort(&output);

    try std.testing.expectEqualStrings("Hello", output[0..output_len]);
    try std.testing.expectEqualSlices(u8, &.{ 0x8a, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 }, writer.written());
}

fn panic_control_frame_handler(_: *std.Io.Writer, _: ws.message.frame.FrameHeader(.u16, false), _: []const u8) ws.message.ControlFrameHandlerError!void {
    @panic("nooo");
}
