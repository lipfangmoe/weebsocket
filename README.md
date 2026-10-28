# weebsocket (WIP, not functional)

Zig Websocket Client (maybe Server one day)

## Add to your Project

To add this to your project, use the Zig Package Manager:

```bash
zig fetch --save 'https://github.com/deanveloper/weebsocket/archive/main.tgz' # todo - change to use tagged versions
```

## Usage

```rust
const std = @import("std");
const ws = @import("weebsocket");

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer gpa.deinit();
	var client = ws.Client(gpa.allocator());
	defer client.deinit();

	var connection = client.handshake(std.Uri.parse("wss://example.com/") catch unreachable, &.{});
	defer connection.deinit();
	
	while (try connection.readMessage()) |message| {
		const payload_reader = message.payloadReader();
		const payload = try payload_reader.readAllAlloc(gpa.allocator());
		defer gpa.allocator().free(payload);
		if (std.mem.eql(u8, payload.constSlice(), "foobar")) {
			try connection.writeMessageString("got your message!");

			const Data = struct { int: u32, string: []const u8 };
			var payload_writer = try connection.writeMessageStreamUnknownLength(.text);
			var buffered_writer = std.io.bufferedWriter(payload_writer.writer());
			try std.json.stringify(buffered_writer.writer(), Data{ .int = 5, .string = "some value" }, .{});
		}
	}
}
```
