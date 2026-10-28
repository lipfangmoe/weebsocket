const std = @import("std");
const ws = @import("../root.zig");

const ControlFrameHandler = @This();

mask_strategy: ws.message.frame.MaskStrategy,
conn_writer: *std.Io.Writer,
handlerFn: *const fn (
    self: *const ControlFrameHandler,
    header: ws.message.frame.FrameHeader(.u16, false),
    payload: []const u8,
) Error!void,

pub fn default(mask_strategy: ws.message.frame.MaskStrategy, conn_writer: *std.Io.Writer) ControlFrameHandler {
    return .{
        .mask_strategy = mask_strategy,
        .conn_writer = conn_writer,
        .handlerFn = &defaultControlFrameHandler,
    };
}

pub const Error = error{ ReceivedCloseFrame, WriteFailed, EndOfStream } || ws.message.writer2.Error;

fn defaultControlFrameHandler(
    self: *const ControlFrameHandler,
    header: ws.message.frame.FrameHeader(.u16, false),
    payload: []const u8,
) Error!void {
    const opcode: ws.message.frame.Opcode = header.opcode;
    std.debug.assert(opcode.isControlFrame());

    switch (opcode) {
        .ping => {
            var buf: [1000]u8 = undefined;
            var control_message_writer: ws.SingleFrameMessageWriter = .initControl(self.conn_writer, header.payload_len, .pong, self.mask_strategy, &buf);
            control_message_writer.interface.writeAll(payload) catch {
                std.debug.assert(control_message_writer.state == .err);

                ws.log.err("Error while writing pong payload: {}", .{control_message_writer.state.err});
                return control_message_writer.state.err;
            };
            control_message_writer.interface.flush() catch {
                std.debug.assert(control_message_writer.state == .err);

                ws.log.err("Error while writing pong payload: {}", .{control_message_writer.state.err});
                return control_message_writer.state.err;
            };
        },
        .pong => {},
        .close => {
            ws.log.debug("peer sent close frame with payload '{s}'", .{payload});
            return error.ReceivedCloseFrame;
        },
        else => unreachable,
    }
}
