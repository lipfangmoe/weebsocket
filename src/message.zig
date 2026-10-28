const std = @import("std");
const ws = @import("./root.zig");

pub const frame = @import("./message/frame.zig");
pub const reader = @import("./message/reader.zig");
pub const writer = @import("./message/writer.zig");

pub const AnyMessageReader = reader.AnyMessageReader;
pub const AnyMessageWriter = writer.AnyMessageWriter;

pub const SingleFrameMessageWriter = writer.SingleFrameMessageWriter;
pub const MultiFrameMessageWriter = writer.MultiFrameMessageWriter;

pub const SingleFrameMessageReader = reader.UnfragmentedMessageReader;
pub const MultiFrameMessageReader = reader.FragmentedMessageReader;

pub const Type = enum {
    /// Indicates that the message is a valid UTF-8 string.
    text,
    /// Indicates that the message is binary data with no guarantees about encoding.
    binary,

    pub fn toOpcode(self: Type) ws.message.frame.Opcode {
        return switch (self) {
            .text => .text,
            .binary => .binary,
        };
    }

    /// returns error.UnexpectedOpcode if called on a control frame header.
    pub fn fromOpcode(opcode: ws.message.frame.Opcode) !Type {
        return switch (opcode) {
            .text => .text,
            .binary => .binary,
            else => error.UnexpectedOpcode,
        };
    }
};
pub const ControlFrameHandlerError = error{ ReceivedCloseFrame, UnexpectedWriteFailure, EndOfStream };
pub const ControlFrameHeaderHandlerFn = *const ControlFrameHeaderHandlerFnBody;
pub const ControlFrameHeaderHandlerFnBody = fn (
    conn_writer: std.io.AnyWriter,
    header: frame.FrameHeader(.u16, false),
    payload: std.BoundedArray(u8, 125),
) ControlFrameHandlerError!void;

pub const defaultControlFrameHandler: ControlFrameHeaderHandlerFnBody = controlFrameHandlerWithMask(.random_mask);

pub fn controlFrameHandlerWithMask(comptime mask: ws.message.frame.Mask) ControlFrameHeaderHandlerFnBody {
    const Struct = struct {
        pub fn handler(
            conn_writer: std.io.AnyWriter,
            frame_header: frame.FrameHeader(.u16, false),
            payload: std.BoundedArray(u8, 125),
        ) ControlFrameHandlerError!void {
            const opcode: frame.Opcode = frame_header.opcode;
            std.debug.assert(opcode.isControlFrame());

            switch (opcode) {
                .ping => {
                    std.log.debug("ping received, attempting to write pong", .{});
                    var control_message_writer = ws.message.AnyMessageWriter.initControl(conn_writer, frame_header.payload_len, .pong, mask) catch |err| return switch (err) {
                        error.EndOfStream => error.EndOfStream,
                        else => {
                            std.log.err("Error while writing pong header: {}", .{err});
                            return error.UnexpectedWriteFailure;
                        },
                    };
                    const payload_writer = control_message_writer.payloadWriter();
                    payload_writer.writeAll(payload.constSlice()) catch |err| return switch (err) {
                        error.EndOfStream => error.EndOfStream,
                        else => {
                            std.log.err("Error while writing pong payload: {}", .{err});
                            return error.UnexpectedWriteFailure;
                        },
                    };
                },
                .pong => {},
                .close => {
                    std.log.debug("peer sent close frame with payload '{s}'", .{payload.constSlice()});
                    return error.ReceivedCloseFrame;
                },
                else => unreachable,
            }
        }
    };
    return Struct.handler;
}
