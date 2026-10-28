# weebsocket

Zig Websocket Client (maybe Server one day). Does not implement any WebSocket extensions at the moment.

## Features

- Zero-alloc after initial handshake
- API somewhat reminescent of `std.http`
- Passes all autobahn tests (except compression)
  - Compression one day...?

## Add to your Project

To add this to your project, use the Zig Package Manager:

```bash
zig fetch --save 'https://github.com/deanveloper/weebsocket/archive/refs/tags/v0.1.0.tar.gz'
```

## Usage

```rust
const std = @import("std");
const ws = @import("./root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer gpa.deinit();
    var client = ws.Client.init(gpa.allocator());
    defer client.deinit();

    const uri = std.Uri.parse("wss://example.com/") catch unreachable;
    var connection = try client.handshake(uri, null);
    defer connection.deinit(null);

    while (connection.readMessage()) |message| {
        const payload_reader = message.payloadReader();
        const payload = try payload_reader.readAllAlloc(gpa.allocator(), 10_000_000);
        defer gpa.allocator().free(payload);
        if (std.mem.eql(u8, payload.constSlice(), "foobar")) {
            try connection.writeMessageString("got your message!");

            const Data = struct { int: u32, string: []const u8 };
            var payload_writer = try connection.writeMessageStreamUnknownLength(.text);
            var buffered_writer = std.io.bufferedWriter(payload_writer.writer());
            try std.json.stringify(buffered_writer.writer(), Data{ .int = 5, .string = "some value" }, .{});
            try buffered_writer.flush();
        }
    } else |err| {
        return err;
    }
}
```

## Special Thanks

- https://github.com/karlseguin/websocket.zig
	- Being the original Websocket API that I looked at. Was very nice, but wanted something that had a closer API to the new `std.http` library
	- Also, used the code from this as a framework for autobahn tests :)
- https://github.com/crossbario/autobahn-testsuite
    - Integration testing suite for websocket clients
	- Solved a lot of bugs!