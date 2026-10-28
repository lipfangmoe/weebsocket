const std = @import("std");
const ws = @import("../root.zig");

pub const AnyMessageWriter = union(enum) {
    unfragmented: UnfragmentedMessageWriter,
    fragmented: FragmentedMessageWriter,

    /// Creates a message from a slice of bytes. Also known as an "unfragmented" message.
    pub fn init(writer: std.io.AnyWriter, message: []const u8, message_type: MessageType, masked: bool) AnyMessageWriter {
        const opcode: ws.message.frame.Opcode = switch (message_type) {
            .text => .text,
            .binary => .binary,
        };
        return AnyMessageWriter{
            .unfragmented = UnfragmentedMessageWriter{
                .underlying_writer = writer,
                .frame_header = ws.message.frame.AnyFrameHeader.init(true, opcode, message.len, masked),
            },
        };
    }

    /// Creates a message which can be written to over multiple frames. Also known as a "fragmented" message.
    pub fn initWriter(writer: std.io.AnyWriter, message_type: MessageType, masked: bool) AnyMessageWriter {
        const opcode: ws.message.frame.Opcode = switch (message_type) {
            .text => .text,
            .binary => .binary,
        };
        return AnyMessageWriter{
            .fragmented = FragmentedMessageWriter{
                .underlying_writer = writer,
                .opcode = opcode,
                .masked = masked,
            },
        };
    }

    /// Creates a control message, which are internal to the websocket protocol and should be controlled by the library.
    /// Should only be used for manually sending pings or creating a control message handler.
    pub fn initControl(writer: std.io.AnyWriter, opcode: ws.message.frame.Opcode, payload: []const u8) AnyMessageWriter {
        return AnyMessageWriter{
            .unfragmented = UnfragmentedMessageWriter{
                .underlying_writer = writer,
                .frame_header = ws.message.frame.AnyFrameHeader.init(true, opcode, payload.len, false),
            },
        };
    }
};

/// Represents an outgoing message that may span multiple frames.
pub const FragmentedMessageWriter = struct {
    underlying_writer: std.io.AnyWriter,
    opcode: ws.message.frame.Opcode,
    masked: bool,

    /// Writes data to the message as a single websocket frame
    pub fn write(self: *FragmentedMessageWriter, bytes: []const u8) anyerror!usize {
        const frame_header = ws.message.frame.AnyFrameHeader.init(false, self.opcode, bytes.len, self.masked);

        // make sure that all but the first frame are continuation frames
        self.opcode = ws.message.frame.Opcode.continuation;

        try frame_header.writeTo(self.underlying_writer);
        try self.underlying_writer.writeAll(bytes);

        return bytes.len;
    }

    pub fn closeWithWrite(self: *FragmentedMessageWriter, bytes: []const u8) !void {
        const frame_header = ws.message.frame.AnyFrameHeader.init(true, self.opcode, bytes.len, self.masked);

        try frame_header.writeTo(self.underlying_writer);
        try self.underlying_writer.writeAll(bytes);
    }

    fn typeErasedWriteFn(ctx: *const anyopaque, bytes: []const u8) anyerror!usize {
        const ptr: *FragmentedMessageWriter = @constCast(@alignCast(@ptrCast(ctx)));
        return write(ptr.*, bytes);
    }

    pub inline fn writer(self: *FragmentedMessageWriter) std.io.AnyWriter {
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

    /// Writes data to the message as a single websocket frame
    pub fn write(self: *FragmentedMessageWriter, bytes: []const u8) anyerror!usize {
        const frame_header = ws.message.frame.AnyFrameHeader.init(false, self.opcode, bytes.len, self.masked);

        try frame_header.writeTo(self.underlying_writer);
        try self.underlying_writer.writeAll(bytes);

        return bytes.len;
    }

    fn typeErasedWriteFn(ctx: *const anyopaque, bytes: []const u8) anyerror!usize {
        const ptr: *FragmentedMessageWriter = @constCast(@alignCast(@ptrCast(ctx)));
        return write(ptr, bytes);
    }

    pub fn writer(self: *FragmentedMessageWriter) std.io.AnyWriter {
        return std.io.AnyWriter{
            .context = @ptrCast(self),
            .writeFn = typeErasedWriteFn,
        };
    }
};

pub const MessageType = enum { text, binary };
