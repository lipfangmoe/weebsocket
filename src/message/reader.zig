const std = @import("std");
const ws = @import("../root.zig");
const utf8_validator = @import("./utf8_validator.zig");

pub const AnyMessageReader = union(enum) {
    unfragmented: UnfragmentedMessageReader,
    fragmented: FragmentedMessageReader,

    pub const ReadHeaderError = error{
        EndOfStream,
        ReceivedCloseFrame,
        InvalidMessage,
        PayloadTooLong,
        UnexpectedReadFailure,
        UnexpectedControlFrameResponseFailure,
    };
    pub const ReadPayloadError = error{
        PayloadTooLong,
        UnexpectedReadFailure,
        InvalidUtf8,
    };
    pub const ReadError = ReadHeaderError || ReadPayloadError;

    pub fn readFrom(reader: std.io.AnyReader, controlFrameHandler: ws.message.ControlFrameHeaderHandlerFn, control_frame_writer: std.io.AnyWriter) ReadHeaderError!AnyMessageReader {
        const header = try readUntilDataFrameHeader(controlFrameHandler, reader, control_frame_writer);
        if (header.asMostBasicHeader().opcode == .continuation) {
            std.log.err("continuation frame found as initial frame, which is not allowed", .{});
            return error.InvalidMessage;
        }

        if (header.asMostBasicHeader().fin) {
            return .{
                .unfragmented = UnfragmentedMessageReader{
                    .underlying_reader = reader,
                    .frame_header = header,
                },
            };
        } else {
            const payload_len = header.getPayloadLen() catch return error.PayloadTooLong;
            return .{
                .fragmented = FragmentedMessageReader{
                    .state = .{ .in_payload = .{ .header = header, .idx = 0, .payload_len = payload_len, .prev_partial_codepoint = .{} } },
                    .controlFrameHandler = controlFrameHandler,
                    .control_frame_writer = control_frame_writer,
                    .underlying_reader = reader,
                    .first_header = header,
                },
            };
        }
    }

    /// Returns error if this is called on a message that is either invalid, or a control frame.
    pub fn getMessageType(self: AnyMessageReader) ws.message.Type {
        const opcode = switch (self) {
            .fragmented => |frag| frag.first_header.asMostBasicHeader().opcode,
            .unfragmented => |unfrag| unfrag.frame_header.asMostBasicHeader().opcode,
        };
        return ws.message.Type.fromOpcode(opcode) catch std.debug.panic("getMessageType called on control frame header", .{});
    }

    const Reader = std.io.GenericReader(*AnyMessageReader, ReadError, read);
    fn read(self: *AnyMessageReader, buffer: []u8) ReadError!usize {
        return switch (self.*) {
            inline else => |*impl| impl.payloadReader().read(buffer),
        };
    }

    pub fn payloadReader(self: *AnyMessageReader) Reader {
        return Reader{ .context = self };
    }

    pub fn payloadLen(self: AnyMessageReader) ?usize {
        return switch (self) {
            .fragmented => null,
            .unfragmented => |unfrag| unfrag.frame_header.getPayloadLen() catch null,
        };
    }
};

/// Represents an incoming message that may span multiple frames.
pub const FragmentedMessageReader = struct {
    underlying_reader: std.io.AnyReader,
    control_frame_writer: std.io.AnyWriter,
    controlFrameHandler: ws.message.ControlFrameHeaderHandlerFn,
    first_header: ws.message.frame.AnyFrameHeader,
    state: State,

    pub fn read(self: *FragmentedMessageReader, bytes: []u8) AnyMessageReader.ReadError!usize {
        switch (self.state) {
            .waiting_for_next_header => |state| {
                const header = readUntilDataFrameHeader(self.controlFrameHandler, self.underlying_reader, self.control_frame_writer) catch |err| {
                    self.state = .{ .err = err };
                    return err;
                };
                if (header.asMostBasicHeader().opcode != .continuation) {
                    std.log.err("frame type {} found while reading fragmented message, should be .continuation", .{header.asMostBasicHeader().opcode});
                    self.state = .{ .err = error.InvalidMessage };
                    return error.InvalidMessage;
                }

                const payload_len = header.getPayloadLen() catch {
                    self.state = .{ .err = error.PayloadTooLong };
                    return error.PayloadTooLong;
                };
                self.state = .{ .in_payload = .{ .header = header, .idx = 0, .payload_len = payload_len, .prev_partial_codepoint = state.prev_partial_codepoint } };
            },
            .err => |err| return err,
            .done => return 0,
            .in_payload => {},
        }

        // at this point in the function, we are always in state == .in_payload
        const payload_state = self.state.in_payload;

        const remaining_bytes = self.state.in_payload.payload_len - self.state.in_payload.idx;
        const capped_bytes = bytes[0..@min(remaining_bytes, bytes.len)];
        if (capped_bytes.len == 0) {
            const is_final = payload_state.header.asMostBasicHeader().fin;
            if (is_final) {
                if (payload_state.prev_partial_codepoint.len > 0) {
                    self.state = .{ .err = error.InvalidUtf8 };
                    return error.InvalidUtf8;
                } else {
                    self.state = .done;
                    return self.read(bytes);
                }
            } else {
                self.state = .{ .waiting_for_next_header = .{ .prev_partial_codepoint = payload_state.prev_partial_codepoint } };
                return self.read(bytes);
            }
        }

        const bytes_read = self.underlying_reader.read(capped_bytes) catch |err| {
            std.log.err("unexpected error occurred while reading fragmented payload: {}", .{err});
            self.state = .{ .err = error.UnexpectedReadFailure };
            return error.UnexpectedReadFailure;
        };

        if (self.first_header.asMostBasicHeader().opcode == .text) {
            self.state.in_payload.prev_partial_codepoint = utf8_validator.utf8ValidateStream(
                self.state.in_payload.prev_partial_codepoint,
                capped_bytes[0..bytes_read],
            ) catch |err| {
                std.log.err("invalid utf8 encountered while decoding .text frame of fragmented message: utf8ValidateStream({x:2>0}, {x:2>0}) returned {}", .{ self.state.in_payload.prev_partial_codepoint.constSlice(), capped_bytes, err });
                self.state = .{ .err = error.InvalidUtf8 };
                return error.InvalidUtf8;
            };
        }

        // masking
        if (payload_state.header.asMostBasicHeader().mask) {
            const masking_key = payload_state.header.getMaskingKey() orelse std.debug.panic("invalid state: mask bit is set but header does not have a masking key", .{});
            mask_unmask(payload_state.idx, masking_key, capped_bytes[0..bytes_read]);
        }

        self.state.in_payload.idx += bytes_read;
        return bytes_read;
    }

    const Reader = std.io.GenericReader(*FragmentedMessageReader, AnyMessageReader.ReadError, read);
    pub fn payloadReader(self: *FragmentedMessageReader) Reader {
        return Reader{ .context = self };
    }

    pub const State = union(enum) {
        in_payload: struct {
            header: ws.message.frame.AnyFrameHeader,
            idx: usize,
            payload_len: usize,
            prev_partial_codepoint: std.BoundedArray(u8, 3),
        },
        waiting_for_next_header: struct { prev_partial_codepoint: std.BoundedArray(u8, 3) },
        err: AnyMessageReader.ReadError,
        done: void,
    };
};

pub const UnfragmentedMessageReader = struct {
    underlying_reader: std.io.AnyReader,
    frame_header: ws.message.frame.AnyFrameHeader,
    state: State = .{ .ok = .{ .payload_idx = 0, .prev_partial_codepoint = .{} } },

    const Reader = std.io.GenericReader(*UnfragmentedMessageReader, AnyMessageReader.ReadPayloadError, read);

    pub fn read(self: *UnfragmentedMessageReader, bytes: []u8) AnyMessageReader.ReadPayloadError!usize {
        const state = switch (self.state) {
            .err => |err| return err,
            .ok => |ok| ok,
        };
        const payload_len = self.frame_header.getPayloadLen() catch {
            self.state = .{ .err = error.PayloadTooLong };
            return error.PayloadTooLong;
        };
        const remaining_bytes = payload_len - state.payload_idx;
        const capped_bytes = bytes[0..@min(remaining_bytes, bytes.len)];
        if (capped_bytes.len == 0) {
            return 0;
        }

        const bytes_read = self.underlying_reader.read(capped_bytes) catch |err| return {
            std.log.err("Error while reading payload of unfragmented message: {}", .{err});
            self.state = .{ .err = error.UnexpectedReadFailure };
            return error.UnexpectedReadFailure;
        };

        if (self.frame_header.asMostBasicHeader().opcode == .text) {
            const partial_codepoint = utf8_validator.utf8ValidateStream(state.prev_partial_codepoint, capped_bytes[0..bytes_read]) catch |err| {
                std.log.err("invalid utf8 encountered while decoding .text frame of unfragmented message: utf8ValidateStream({x:2>0}, {x:2>0}) returned {}", .{ state.prev_partial_codepoint.constSlice(), capped_bytes, err });
                self.state = .{ .err = error.InvalidUtf8 };
                return error.InvalidUtf8;
            };
            if (bytes_read == remaining_bytes and partial_codepoint.len > 0) {
                std.log.err("payload ended in the middle of a utf8 byte sequence: {x}, expected {} more bytes", .{ partial_codepoint.constSlice(), std.unicode.utf8ByteSequenceLength(partial_codepoint.get(0)) catch unreachable });
                self.state = .{ .err = error.InvalidUtf8 };
                return error.InvalidUtf8;
            }
            self.state.ok.prev_partial_codepoint = partial_codepoint;
        }

        if (self.frame_header.asMostBasicHeader().mask) {
            const masking_key = self.frame_header.getMaskingKey() orelse std.debug.panic("invalid state: mask bit is set but header does not have a masking key", .{});
            mask_unmask(state.payload_idx, masking_key, capped_bytes[0..bytes_read]);
        }

        self.state.ok.payload_idx += bytes_read;
        return bytes_read;
    }

    pub fn payloadReader(self: *UnfragmentedMessageReader) Reader {
        return Reader{ .context = self };
    }

    pub const State = union(enum) {
        ok: struct {
            payload_idx: usize = 0,
            prev_partial_codepoint: std.BoundedArray(u8, 3) = .{},
        },
        err: AnyMessageReader.ReadPayloadError,
    };
};

/// loops through messages until a non-control frame is found, calling controlFrameHandler on each control frame.
fn readUntilDataFrameHeader(
    controlFrameHandler: ws.message.ControlFrameHeaderHandlerFn,
    reader: std.io.AnyReader,
    writer: std.io.AnyWriter,
) AnyMessageReader.ReadHeaderError!ws.message.frame.AnyFrameHeader {
    while (true) {
        const current_header = ws.message.frame.AnyFrameHeader.readFrom(reader) catch |err| return switch (err) {
            error.EndOfStream => error.EndOfStream,
            else => {
                std.log.err("error occurred while parsing header: {}", .{err});
                return error.InvalidMessage;
            },
        };
        const basic_header = current_header.asMostBasicHeader();
        if (basic_header.rsv1 or basic_header.rsv2 or basic_header.rsv3) {
            std.log.err("reserve bits set rsv123=0b{b}{b}{b}", .{ @intFromBool(basic_header.rsv1), @intFromBool(basic_header.rsv2), @intFromBool(basic_header.rsv3) });
            return error.InvalidMessage;
        }
        if (basic_header.opcode.isControlFrame()) {
            const control_frame_header: ws.message.frame.FrameHeader(.u16, false) = switch (current_header) {
                .u16_unmasked => |impl| impl,
                else => |impl| {
                    std.log.err("recevied control frame had a header of an unexpected size: {}", .{impl});
                    return error.InvalidMessage;
                },
            };
            std.log.debug("control frame: {}", .{control_frame_header});
            if (!control_frame_header.fin) {
                std.log.err("peer gave us a control frame which is fragmented, which is not allowed", .{});
                return error.InvalidMessage;
            }

            var payload = std.BoundedArray(u8, 125).init(control_frame_header.payload_len) catch return error.InvalidMessage;
            const n = reader.readAll(payload.slice()) catch |err| {
                std.log.err("Unexpected read failure when reading payload from control frame: {}", .{err});
                return error.UnexpectedReadFailure;
            };

            if (n != control_frame_header.payload_len) {
                return error.EndOfStream;
            }
            std.log.debug("control frame payload: '{s}'", .{payload.constSlice()});
            controlFrameHandler(writer, control_frame_header, payload) catch |err| return switch (err) {
                error.ReceivedCloseFrame => |err_cast| err_cast,
                error.EndOfStream, error.UnexpectedWriteFailure => error.UnexpectedControlFrameResponseFailure,
            };
            continue;
        }
        if (!basic_header.opcode.isDataFrame()) {
            std.log.err("peer gave us opcode {}, which is not a valid opcode", .{@intFromEnum(basic_header.opcode)});
            return error.InvalidMessage;
        }

        return current_header;
    }
}

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
    var message = try AnyMessageReader.readFrom(
        stream.reader().any(),
        &panic_control_frame_handler,
        std.io.null_writer.any(),
    );
    var payload_reader = message.payloadReader();
    const output = try payload_reader.readBoundedBytes(100);

    try std.testing.expectEqualStrings("Hello", output.constSlice());
}

// technically server-to-client messages should never be masked, but maybe one day MessageReader will be re-used to make a Websocket Server...
test "A single-frame masked text message" {
    const bytes = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    var stream = std.io.fixedBufferStream(&bytes);
    var message = try AnyMessageReader.readFrom(
        stream.reader().any(),
        &panic_control_frame_handler,
        std.io.null_writer.any(),
    );
    var payload_reader = message.payloadReader();
    const output = try payload_reader.readBoundedBytes(100);

    try std.testing.expectEqualStrings("Hello", output.constSlice());
}

test "A fragmented unmasked text message" {
    const bytes = [_]u8{ 0x01, 0x03, 0x48, 0x65, 0x6c, 0x80, 0x02, 0x6c, 0x6f };
    var stream = std.io.fixedBufferStream(&bytes);
    var message = try AnyMessageReader.readFrom(
        stream.reader().any(),
        &panic_control_frame_handler,
        std.io.null_writer.any(),
    );
    var payload_reader = message.payloadReader();
    const output = try payload_reader.readBoundedBytes(100);

    try std.testing.expectEqualStrings("Hello", output.constSlice());
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
    var outgoing_bytes: [20]u8 = undefined;
    var incoming_stream = std.io.fixedBufferStream(&incoming_bytes);
    var outgoing_stream = std.io.fixedBufferStream(&outgoing_bytes);
    var message = try AnyMessageReader.readFrom(
        incoming_stream.reader().any(),
        &ws.message.controlFrameHandlerWithMask(.{ .fixed_mask = 0x37FA213D }),
        outgoing_stream.writer().any(),
    );
    var payload_reader = message.payloadReader();
    const output = try payload_reader.readBoundedBytes(1000);

    try std.testing.expectEqualStrings("Hello", output.constSlice());
    try std.testing.expectEqualSlices(u8, &.{ 0x8a, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 }, outgoing_stream.getWritten());
}

fn panic_control_frame_handler(_: std.io.AnyWriter, _: ws.message.frame.FrameHeader(.u16, false), _: std.BoundedArray(u8, 125)) ws.message.ControlFrameHandlerError!void {
    @panic("nooo");
}
