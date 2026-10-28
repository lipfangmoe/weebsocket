const std = @import("std");
const ws = @import("./root.zig");

pub const frame = @import("./message/frame.zig");
pub const reader = @import("./message/reader.zig");
pub const writer = @import("./message/writer.zig");
pub const AnyMessageReader = reader.AnyMessageReader;
pub const AnyMessageWriter = writer.AnyMessageWriter;

pub const ControlFrameHeaderHandlerFn = *const ControlFrameHeaderHandlerFnBody;
pub const ControlFrameHeaderHandlerFnBody = fn (
    conn_writer: std.io.AnyWriter,
    header: frame.FrameHeader(.u16, false),
    payload: std.BoundedArray(u8, 125),
) anyerror!void;

pub const defaultControlFrameHandler: ControlFrameHeaderHandlerFnBody = controlFrameHandlerWithMask(.random_mask);

pub fn controlFrameHandlerWithMask(comptime mask: ws.message.frame.Mask) ControlFrameHeaderHandlerFnBody {
    const Struct = struct {
        pub fn handler(
            conn_writer: std.io.AnyWriter,
            frame_header: frame.FrameHeader(.u16, false),
            payload: std.BoundedArray(u8, 125),
        ) anyerror!void {
            const opcode: frame.Opcode = frame_header.opcode;
            std.debug.assert(opcode.isControlFrame());

            switch (opcode) {
                .ping => {
                    var received_payload = std.io.fixedBufferStream(payload.slice());
                    var control_message_writer = ws.message.AnyMessageWriter.initControl(conn_writer, frame_header.payload_len, .pong, mask);
                    const payload_writer = control_message_writer.payload_writer();
                    var fifo = std.fifo.LinearFifo(u8, .{ .Static = 1000 }).init();
                    try fifo.pump(received_payload.reader(), payload_writer);
                },
                .pong => {},
                .close => {
                    return error.Closing;
                },
                else => unreachable,
            }
        }
    };
    return Struct.handler;
}
