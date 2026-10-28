const std = @import("std");
const ws = @import("weebsocket");

pub fn main(init: std.process.Init) !void {
    var client = ws.Client.init(init.io, init.gpa);
    defer client.deinit();

    const uri = std.Uri.parse("wss://example.com/") catch unreachable;
    var connection = try client.handshake(uri, null);
    defer connection.deinit(null);

    while (true) {
        var message = try connection.receiveMessage();
        const payload_reader = message.reader();
        const payload = try payload_reader.allocRemaining(init.gpa, .limited(10_000_000));
        defer init.gpa.free(payload);
        if (std.mem.eql(u8, payload, "foobar")) {
            // send a string
            const str = "got your message!";
            try connection.sendMessage(.text, str);

            const Data = struct { int: u32, string: []const u8 };
            const data: Data = .{ .int = 5, .string = "some value" };

            // low-level control over the buffer and payload writer
            var buf: [1000]u8 = undefined;
            var payload_writer = connection.writeMessageStreamUnknownLength(.text, &buf);
            try std.json.Stringify.value(data, .{}, &payload_writer.interface);
            try payload_writer.interface.flush();

            // a better way to do the above with `printMessage`
            try connection.printMessage(.text, "{f}", .{std.json.fmt(data, .{})});
        }
    }
}
