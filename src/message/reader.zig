const std = @import("std");
const ws = @import("../root.zig");
const utf8_validator = @import("./utf8_validator.zig");

pub const MessageReader = struct {
    interface: std.Io.Reader,
    underlying_reader: *std.Io.Reader,
    control_frame_handler: ws.message.ControlFrameHandler,
    state: State,

    pub fn init(reader: *std.Io.Reader, control_frame_handler: ws.message.ControlFrameHandler, buffer: []u8) MessageReader {
        return .{
            .interface = .{ .buffer = buffer, .seek = 0, .end = 0, .vtable = &.{ .stream = &streamFn } },
            .underlying_reader = reader,
            .control_frame_handler = control_frame_handler,
            .state = .waiting_for_first_header,
        };
    }

    /// gets the header pertaining to this message
    pub fn getHeader(self: *MessageReader) GetHeaderError!ws.message.frame.AnyFrameHeader {
        return switch (self.state) {
            .waiting_for_first_header => {
                _ = self.streamHeader() catch |err| {
                    self.state = .{ .err = err };
                    return err;
                };
                return try self.getHeader();
            },
            .waiting_for_next_header => |s| s.first_header,
            .reading_unfragmented_payload => |s| s.header,
            .reading_fragmented_payload => |s| s.first_header,
            .complete => error.NoLongerAvailable,
            .err => error.NoLongerAvailable,
        };
    }

    fn streamFn(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *MessageReader = @alignCast(@fieldParentPtr("interface", r));

        return self.stream(w, limit) catch |err| {
            if (err == error.EndOfFrame) {
                self.state = .complete;
                return error.EndOfStream;
            }

            self.state = .{ .err = err };
            // an actual EndOfFrame is equivalent to ReadError's EndOfStream, but an EndOfStream is a ReadError with reason EndOfStream,
            // since the stream should *never* end in the middle of a frame.
            return switch (self.state.err) {
                error.EndOfFrame => unreachable,
                error.UnderlyingWriteFailed => error.WriteFailed,
                else => error.ReadFailed,
            };
        };
    }

    fn stream(self: *MessageReader, w: *std.Io.Writer, limit: std.Io.Limit) Error!usize {
        return switch (self.state) {
            .waiting_for_first_header => try self.streamHeader(),
            .waiting_for_next_header => try self.streamHeader(),
            .reading_unfragmented_payload => try self.streamPayload(w, limit),
            .reading_fragmented_payload => try self.streamPayloadFragmented(w, limit),
            .complete => return error.EndOfFrame,
            .err => |err| return err,
        };
    }

    fn streamHeader(self: *MessageReader) Error!usize {
        std.debug.assert(self.state == .waiting_for_first_header or self.state == .waiting_for_next_header);

        const header = try readUntilDataFrameHeader(self.underlying_reader, self.control_frame_handler);
        const basic_header = header.asMostBasicHeader();

        // first header may never be a continuation header
        if (self.state == .waiting_for_first_header and basic_header.opcode == .continuation) {
            return error.InvalidMessage;
        }

        // subsequent fragmented headers must be continuation headers
        if (self.state == .waiting_for_next_header and basic_header.opcode != .continuation) {
            return error.InvalidMessage;
        }

        if (basic_header.fin) {
            self.state = switch (self.state) {
                .waiting_for_first_header => .{ .reading_unfragmented_payload = .{
                    .header = header,
                    .bytes_read = 0,
                    .prev_partial_codepoint_buf = undefined,
                    .prev_partial_codepoint_len = 0,
                } },
                .waiting_for_next_header => |s| .{ .reading_fragmented_payload = .{
                    .first_header = s.first_header,
                    .header = header,
                    .bytes_read = 0,
                    .prev_partial_codepoint_buf = s.prev_partial_codepoint_buf,
                    .prev_partial_codepoint_len = s.prev_partial_codepoint_len,
                } },
                else => unreachable,
            };
        } else {
            self.state = switch (self.state) {
                .waiting_for_first_header => .{ .reading_fragmented_payload = .{
                    .first_header = header,
                    .header = header,
                    .bytes_read = 0,
                    .prev_partial_codepoint_buf = undefined,
                    .prev_partial_codepoint_len = 0,
                } },
                .waiting_for_next_header => |s| .{ .reading_fragmented_payload = .{
                    .first_header = s.first_header,
                    .header = header,
                    .bytes_read = 0,
                    .prev_partial_codepoint_buf = s.prev_partial_codepoint_buf,
                    .prev_partial_codepoint_len = s.prev_partial_codepoint_len,
                } },
                else => unreachable,
            };
        }

        return 0;
    }

    fn streamPayloadFragmented(self: *MessageReader, w: *std.Io.Writer, limit: std.Io.Limit) Error!usize {
        std.debug.assert(self.state == .reading_fragmented_payload);

        const prev_state = self.state.reading_fragmented_payload;
        return self.streamPayload(w, limit) catch |err| switch (err) {
            error.EndOfFrame => {
                if (prev_state.header.asMostBasicHeader().fin) {
                    self.state = .complete;
                } else {
                    self.state = .{ .waiting_for_next_header = .{
                        .first_header = prev_state.first_header,
                        .prev_partial_codepoint_buf = prev_state.prev_partial_codepoint_buf,
                        .prev_partial_codepoint_len = prev_state.prev_partial_codepoint_len,
                    } };
                }
                return 0;
            },
            else => return err,
        };
    }

    fn streamPayload(self: *MessageReader, w: *std.Io.Writer, limit: std.Io.Limit) Error!usize {
        std.debug.assert(self.state == .reading_unfragmented_payload or self.state == .reading_fragmented_payload);

        const header = switch (self.state) {
            .reading_unfragmented_payload => |unfrag| unfrag.header,
            .reading_fragmented_payload => |frag| frag.header,
            else => unreachable,
        };
        const is_text = switch (self.state) {
            .reading_unfragmented_payload => header.asMostBasicHeader().opcode == .text,
            .reading_fragmented_payload => |frag| frag.first_header.asMostBasicHeader().opcode == .text,
            else => unreachable,
        };
        const payload_len = header.getPayloadLen() catch return error.PayloadTooLong;
        const bytes_read = switch (self.state) {
            .reading_unfragmented_payload => |unfrag| unfrag.bytes_read,
            .reading_fragmented_payload => |frag| frag.bytes_read,
            else => unreachable,
        };
        const prev_partial_codepoint = switch (self.state) {
            .reading_unfragmented_payload => |unfrag| unfrag.prev_partial_codepoint_buf[0..unfrag.prev_partial_codepoint_len],
            .reading_fragmented_payload => |frag| frag.prev_partial_codepoint_buf[0..frag.prev_partial_codepoint_len],
            else => unreachable,
        };
        const is_final_frame = switch (self.state) {
            .reading_unfragmented_payload => true,
            .reading_fragmented_payload => |frag| frag.header.asMostBasicHeader().fin,
            else => unreachable,
        };

        const remaining_bytes = payload_len - bytes_read;
        if (remaining_bytes == 0) {
            if (prev_partial_codepoint.len > 0 and is_final_frame) {
                ws.log.err("payload ended with incomplete utf8 character: {x}", .{prev_partial_codepoint});
                return error.InvalidUtf8;
            }
            return error.EndOfFrame;
        }
        const read_limit = limit.min(.limited(remaining_bytes));

        var buf: [8000]u8 = undefined;
        const readable = read_limit.slice(&buf);
        const n = self.underlying_reader.readSliceShort(readable) catch {
            return error.UnderlyingReadFailed;
        };
        const partial_payload = readable[0..n];

        // unmask payload
        if (header.asMostBasicHeader().mask) {
            const masking_key = header.getMaskingKey() orelse {
                ws.log.err("invalid header: mask bit is set but header does not have a masking key", .{});
                return error.InvalidMessage;
            };
            ws.message.mask_unmask(bytes_read, masking_key, partial_payload);
        }

        // validate [end of last payload ++ beginning of this payload] are valid utf8
        var next_partial_codepoint_buf: [3]u8 = undefined;
        var next_partial_codepoint_len: usize = 0;
        if (is_text) {
            var next_partial_codepoint = std.ArrayList(u8).initBuffer(&next_partial_codepoint_buf);
            utf8_validator.utf8ValidateStream(prev_partial_codepoint, partial_payload, &next_partial_codepoint) catch |err| {
                ws.log.err("invalid utf8 encountered while decoding .text frame of fragmented message: utf8ValidateStream({x},{x}) returned {}", .{ prev_partial_codepoint, partial_payload, err });
                return error.InvalidUtf8;
            };
            next_partial_codepoint_len = next_partial_codepoint.items.len;
        }

        self.state = switch (self.state) {
            .reading_unfragmented_payload => |unfrag| .{ .reading_unfragmented_payload = .{
                .header = unfrag.header,
                .prev_partial_codepoint_buf = next_partial_codepoint_buf,
                .prev_partial_codepoint_len = next_partial_codepoint_len,
                .bytes_read = unfrag.bytes_read + partial_payload.len,
            } },
            .reading_fragmented_payload => |frag| .{ .reading_fragmented_payload = .{
                .first_header = frag.first_header,
                .header = frag.header,
                .prev_partial_codepoint_buf = next_partial_codepoint_buf,
                .prev_partial_codepoint_len = next_partial_codepoint_len,
                .bytes_read = frag.bytes_read + partial_payload.len,
            } },
            else => unreachable,
        };

        w.writeAll(partial_payload) catch return error.UnderlyingWriteFailed;
        return partial_payload.len;
    }
    pub const Error = error{
        InvalidMessage,
        UnderlyingReadFailed,
        UnderlyingWriteFailed,
        UnderlyingControlFrameWriteFailed,
        PayloadTooLong,
        EndOfStream,
        EndOfFrame,
        InvalidUtf8,
        ReceivedCloseFrame,
    } || std.Io.Cancelable;

    pub const GetHeaderError = error{NoLongerAvailable} || Error;

    pub const State = union(enum) {
        waiting_for_first_header: void,
        reading_unfragmented_payload: struct {
            header: ws.message.frame.AnyFrameHeader,
            prev_partial_codepoint_buf: [3]u8,
            prev_partial_codepoint_len: usize,
            bytes_read: usize,
        },
        reading_fragmented_payload: struct {
            first_header: ws.message.frame.AnyFrameHeader,
            header: ws.message.frame.AnyFrameHeader,
            prev_partial_codepoint_buf: [3]u8,
            prev_partial_codepoint_len: usize,
            bytes_read: usize,
        },
        waiting_for_next_header: struct {
            first_header: ws.message.frame.AnyFrameHeader,
            prev_partial_codepoint_buf: [3]u8,
            prev_partial_codepoint_len: usize,
        },
        complete: void,
        err: Error,

        pub fn format(self: State, w: *std.Io.Writer) !void {
            switch (self) {
                .waiting_for_first_header => try w.print("(waiting_for_first_header)", .{}),
                .reading_unfragmented_payload => |s| try w.print("(reading_fragmented_payload: read={}/{} codepoint='{x}')", .{ s.bytes_read, s.header.asMostBasicHeader().getPayloadLen(), s.prev_partial_codepoint_buf[0..s.prev_partial_codepoint_len] }),
                .reading_fragmented_payload => |s| try w.print("(reading_fragmented_payload: read={}/{} codepoint='{x}')", .{ s.bytes_read, s.header.asMostBasicHeader().getPayloadLen(), s.prev_partial_codepoint_buf[0..s.prev_partial_codepoint_len] }),
                .waiting_for_next_header => |s| try w.print("(waiting_for_next_header: codepoint='{x}')", .{s.prev_partial_codepoint_buf[0..s.prev_partial_codepoint_len]}),
                .complete => try w.print("(complete)", .{}),
                .err => |err| try w.print("(err: {})", .{err}),
            }
        }
    };
};

fn readUntilDataFrameHeader(
    underlying_reader: *std.Io.Reader,
    control_frame_handler: ws.message.ControlFrameHandler,
) MessageReader.Error!ws.message.frame.AnyFrameHeader {
    while (true) {
        const current_header = ws.message.frame.AnyFrameHeader.readFrom(underlying_reader) catch |err| return switch (err) {
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
                ws.log.err("peer sent a control frame which is fragmented, which is not allowed", .{});
                return error.InvalidMessage;
            }

            var payload_buf: [125]u8 = undefined;
            const payload = payload_buf[0..control_frame_header.payload_len];
            underlying_reader.readSliceAll(payload) catch |err| switch (err) {
                error.ReadFailed => return error.UnderlyingReadFailed,
                error.EndOfStream => return error.EndOfStream,
            };

            control_frame_handler.handlerFn(&control_frame_handler, control_frame_header, payload) catch |err| return switch (err) {
                error.ReceivedCloseFrame => error.ReceivedCloseFrame,
                error.InvalidMessage => error.InvalidMessage,
                error.Canceled => error.Canceled,
                error.EndOfStream, error.EndOfFrame, error.UnderlyingWriteFailed, error.Overflow, error.WriteFailed => error.UnderlyingControlFrameWriteFailed,
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
    var message_reader: MessageReader = .init(
        &reader,
        panic_control_frame_handler,
        &message_reader_buf,
    );
    var output: [100]u8 = undefined;
    const output_len = try message_reader.interface.readSliceShort(&output);

    try std.testing.expectEqualStrings("Hello", output[0..output_len]);
}

// technically server-to-client messages should never be masked, but maybe one day MessageReader will be re-used to make a Websocket Server...
test "A single-frame masked text message" {
    const bytes = [_]u8{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    var message_reader_buf: [100]u8 = undefined;
    var reader = std.Io.Reader.fixed(&bytes);
    var message_reader: MessageReader = .init(
        &reader,
        panic_control_frame_handler,
        &message_reader_buf,
    );
    var output: [100]u8 = undefined;
    const output_len = try message_reader.interface.readSliceShort(&output);

    try std.testing.expectEqualStrings("Hello", output[0..output_len]);
}

test "A fragmented unmasked text message" {
    const reader_buf = [_]u8{ 0x01, 0x03, 0x48, 0x65, 0x6c, 0x80, 0x02, 0x6c, 0x6f };
    var reader = std.Io.Reader.fixed(&reader_buf);
    var message_reader_buf: [100]u8 = undefined;
    var message_reader: MessageReader = .init(
        &reader,
        panic_control_frame_handler,
        &message_reader_buf,
    );
    var output: [100]u8 = undefined;
    const output_len = try message_reader.interface.readSliceShort(&output);

    try std.testing.expectEqualStrings("Hello", output[0..output_len]);
}

test "a long unfragmented unmasked message" {
    const header: ws.message.frame.AnyFrameHeader = .{ .u32_unmasked = .{
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
    var message_reader: MessageReader = .init(
        &reader,
        panic_control_frame_handler,
        &message_reader_buf,
    );
    var output: [10_000]u8 = undefined;
    const output_len = try message_reader.interface.readSliceShort(&output);

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

    const control_frame_handler: ws.message.ControlFrameHandler = .default(.{ .fixed = 0x37FA213D }, &writer.writer);

    var message_reader_buf: [1000]u8 = undefined;
    var message_reader: MessageReader = .init(
        &reader,
        control_frame_handler,
        &message_reader_buf,
    );

    var output: [100]u8 = undefined;
    const output_len = try message_reader.interface.readSliceShort(&output);

    try std.testing.expectEqualStrings("Hello", output[0..output_len]);
    try std.testing.expectEqualSlices(u8, &.{ 0x8a, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 }, writer.written());
}

const panic_control_frame_handler: ws.message.ControlFrameHandler = .{
    .conn_writer = undefined,
    .mask_strategy = undefined,
    .handlerFn = panicControlFrameHandlerFn,
};

fn panicControlFrameHandlerFn(_: *const ws.message.ControlFrameHandler, _: ws.message.frame.FrameHeader(.u16, false), _: []const u8) ws.message.ControlFrameHandler.Error!void {
    @panic("nooo");
}
