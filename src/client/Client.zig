//! Server which listens for Websocket Handshakes.
//! Only need to call `deinit()` if created via `init(Address)`.
//! If you have an existing `std.net.Server`, it is okay to create this struct via struct initialization.

const std = @import("std");
const client = @import("../root.zig").client;
const b64_encoder = std.base64.standard.Encoder;

http_client: std.http.Client,

const Client = @This();

pub fn init(allocator: std.mem.Allocator) Client {
    const http_client = std.http.Client{ .allocator = allocator };
    return .{ .http_client = http_client };
}

pub fn handshake(
    self: *Client,
    uri: std.Uri,
    extra_headers: ?[]const std.http.Header,
) !client.Connection {
    var buf: [1000]u8 = undefined;
    const websocket_key = generateRandomWebsocketKey();

    var headers = std.BoundedArray(std.http.Header, 100){};
    headers.append(std.http.Header{ .name = "Upgrade", .value = "websocket" }) catch unreachable;
    headers.append(std.http.Header{ .name = "Sec-WebSocket-Key", .value = &websocket_key }) catch unreachable;
    headers.append(std.http.Header{ .name = "Sec-WebSocket-Version", .value = "13" }) catch unreachable;
    if (extra_headers) |extra| {
        try headers.appendSlice(extra);
    }
    var req = try self.http_client.open(.GET, uri, .{
        .server_header_buffer = &buf,
        .headers = .{
            .connection = .{ .override = "Upgrade" },
        },
        .extra_headers = headers.constSlice(),
    });
    errdefer req.deinit();

    try req.send();
    try req.wait();

    if (req.response.status != .switching_protocols) {
        std.log.err("expected status 101 SWITCHING PROTOCOLS, got {d} {s}", .{ @intFromEnum(req.response.status), req.response.status.phrase() orelse "{unknown}" });
        return error.NotWebsocketServer;
    }

    const expected_ws_accept = expectedWebsocketAcceptHeader(websocket_key);
    var upgrade_seen = false;
    var connection_seen = false;
    var accept_seen = false;
    var headers_iter = req.response.iterateHeaders();
    while (headers_iter.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "Upgrade")) {
            upgrade_seen = true;
            if (!std.ascii.eqlIgnoreCase(header.value, "websocket")) {
                std.log.err("Server did not respond with the correct 'Upgrade' header. Expected 'websocket' (not case-sensitive), found '{s}'", .{header.value});
                return error.NotWebsocketServer;
            }
        }
        if (std.ascii.eqlIgnoreCase(header.name, "Connection")) {
            connection_seen = true;
            if (!std.ascii.eqlIgnoreCase(header.value, "upgrade")) {
                std.log.err("Server did not respond with the correct 'Connection' header. Expected 'upgrade' (not case-sensitive), found '{s}'", .{header.value});
                return error.NotWebsocketServer;
            }
        }
        if (std.ascii.eqlIgnoreCase(header.name, "Sec-WebSocket-Accept")) {
            accept_seen = true;
            if (!std.mem.eql(u8, header.value, &expected_ws_accept)) {
                std.log.err("Server did not respond with the correct 'Sec-WebSocket-Accept' header. Expected '{s}', found '{s}'", .{ &expected_ws_accept, header.value });
                return error.NotWebsocketServer;
            }
        }
    }
    if (!upgrade_seen) {
        std.log.err("Server did not respond with an 'Upgrade' header.", .{});
        return error.NotWebsocketServer;
    }
    if (!connection_seen) {
        std.log.err("Server did not respond with an 'Connection' header.", .{});
        return error.NotWebsocketServer;
    }
    if (!accept_seen) {
        std.log.err("Server did not respond with an 'Upgrade' header.", .{});
        return error.NotWebsocketServer;
    }

    return client.Connection.init(req);
}

pub fn deinit(self: *Client) void {
    self.http_client.deinit();
}

fn generateRandomWebsocketKey() [b64_encoder.calcSize(16)]u8 {
    var rand = std.Random.DefaultPrng.init(@bitCast(std.time.microTimestamp()));
    var buf: [16]u8 = undefined;
    var out_buf: [b64_encoder.calcSize(16)]u8 = undefined;
    rand.random().bytes(&buf);
    _ = b64_encoder.encode(&out_buf, &buf);

    return out_buf;
}

fn expectedWebsocketAcceptHeader(key: [b64_encoder.calcSize(16)]u8) [b64_encoder.calcSize(20)]u8 {
    const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var concatted = std.BoundedArray(u8, key.len + ws_guid.len){};
    concatted.appendSlice(&key) catch unreachable;
    concatted.appendSlice(ws_guid) catch unreachable;

    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(concatted.constSlice());

    const digest = sha1.finalResult();
    var out_buf: [b64_encoder.calcSize(digest.len)]u8 = undefined;
    _ = b64_encoder.encode(&out_buf, &digest);

    return out_buf;
}

test "expected websocket accept header from spec" {
    try std.testing.expectEqual(
        "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=".*,
        expectedWebsocketAcceptHeader("dGhlIHNhbXBsZSBub25jZQ==".*),
    );
}
