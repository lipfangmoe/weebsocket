const std = @import("std");
const testing = std.testing;

pub const client = @import("./client.zig");
pub const message = @import("./message.zig");

pub const Connection = client.Connection;
pub const Client = client.Client;
pub const MessageReader = message.MessageReader;

pub const SingleFrameMessageWriter = message.SingleFrameMessageWriter;
pub const MultiFrameMessageWriter = message.MultiFrameMessageWriter;

pub const log = std.log.scoped(.weebsocket);

test {
    _ = client;
    _ = message;
}
