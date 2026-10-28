const std = @import("std");
const ws = @import("../root.zig");

pub const AnyMessageReader = union(enum) {
    unfragmented: UnfragmentedMessageReader,
    fragmented: FragmentedMessageReader,

    pub fn readFrom(reader: std.io.AnyReader, controlFrameHandler: ws.message.ControlFrameHeaderHandlerFn, control_frame_writer: std.io.AnyWriter) !AnyMessageReader {
        // loop through messages until a non-control header is found
        const header = try readUntilDataFrameHeader(controlFrameHandler, reader, control_frame_writer);

        if (header.asMostBasicHeader().fin) {
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
                    .state = .{ .in_payload = .{ .header = header, .idx = 0, .payload_len = payload_len } },
                    .controlFrameHandler = controlFrameHandler,
                    .control_frame_writer = control_frame_writer,
                    .underlying_reader = reader,
                    .first_header = header,
                },
            };
        }
    }

    pub fn payloadReader(self: *AnyMessageReader) std.io.AnyReader {
        return switch (self.*) {
            inline else => |*impl| impl.payloadReader(),
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

    pub fn read(self: *FragmentedMessageReader, bytes: []u8) anyerror!usize {
        switch (self.state) {
            .waiting_for_next_header => {
                const header = try readUntilDataFrameHeader(self.controlFrameHandler, self.underlying_reader, self.control_frame_writer);

                const payload_len = header.getPayloadLen() catch return error.PayloadTooLong;
                self.state = .{ .in_payload = .{ .header = header, .idx = 0, .payload_len = payload_len } };
            },
            .done => return 0,
            else => {},
        }

        // at this point in the function, we are always in state == .in_payload
        const payload_state = self.state.in_payload;

        const remaining_bytes = self.state.in_payload.payload_len - self.state.in_payload.idx;
        const capped_bytes = bytes[0..@min(remaining_bytes, bytes.len)];
        const bytes_read = try self.underlying_reader.read(capped_bytes);

        // masking
        if (payload_state.header.asMostBasicHeader().mask) {
            const masking_key = payload_state.header.getMaskingKey() orelse return error.UnexpectedMaskBit;
            mask_unmask(payload_state.idx, masking_key, capped_bytes[0..bytes_read]);
        }

        if (bytes_read == remaining_bytes) {
            const is_final = payload_state.header.asMostBasicHeader().fin;
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

    pub fn payloadReader(self: *FragmentedMessageReader) std.io.AnyReader {
        return std.io.AnyReader{ .context = self, .readFn = typeErasedReadFn };
    }

    pub const State = union(enum) {
        in_payload: struct { header: ws.message.frame.AnyFrameHeader, idx: usize, payload_len: usize },
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

    pub fn payloadReader(self: *UnfragmentedMessageReader) std.io.AnyReader {
        return std.io.AnyReader{ .context = self, .readFn = typeErasedReadFn };
    }
};

/// loops through messages until a non-control frame is found, calling controlFrameHandler on each control frame.
fn readUntilDataFrameHeader(
    controlFrameHandler: ws.message.ControlFrameHeaderHandlerFn,
    reader: std.io.AnyReader,
    writer: std.io.AnyWriter,
) !ws.message.frame.AnyFrameHeader {
    while (true) {
        const current_header = try ws.message.frame.AnyFrameHeader.readFrom(reader);
        if (current_header.asMostBasicHeader().opcode.isControlFrame()) {
            const control_frame_header: ws.message.frame.FrameHeader(.u16, false) = switch (current_header) {
                .u16_unmasked => |impl| impl,
                else => return error.InvalidControlFrameHeader,
            };

            var payload = try std.BoundedArray(u8, 125).init(control_frame_header.payload_len);
            const n = try reader.readAll(payload.slice());
            if (n != control_frame_header.payload_len) {
                return error.UnexpectedEndOfStream;
            }
            try controlFrameHandler(writer, control_frame_header, payload);
            continue;
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

fn panic_control_frame_handler(_: std.io.AnyWriter, _: ws.message.frame.FrameHeader(.u16, false), _: std.BoundedArray(u8, 125)) anyerror!void {
    @panic("nooo");
}
