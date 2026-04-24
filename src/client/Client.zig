//! Server which listens for Websocket Handshakes.
//! Only need to call `deinit()` if created via `init()`.
//! If you have an existing `std.http.Client`, it is okay to create this struct via struct initialization.

const std = @import("std");
const ws = @import("../root.zig");
const client = ws.client;
const b64_encoder = std.base64.standard.Encoder;

rng: std.Random.IoSource,
http_client: std.http.Client,

const Client = @This();

pub fn init(io: std.Io, allocator: std.mem.Allocator) Client {
    const http_client = std.http.Client{ .io = io, .allocator = allocator };
    const rng = std.Random.IoSource{ .io = io };
    return .{ .rng = rng, .http_client = http_client };
}

const HandshakeError = error{ NotWebsocketServer, OutOfMemory, HttpRequestError } || std.Io.Cancelable;

pub fn handshake(
    self: *Client,
    uri: std.Uri,
    extra_headers: ?[]const std.http.Header,
) HandshakeError!client.Connection {
    const rio: std.Random.IoSource = .{ .io = self.http_client.io };
    const websocket_key = generateRandomWebsocketKey(rio.interface());

    var headers_buf: [100]std.http.Header = undefined;
    var headers = std.ArrayList(std.http.Header).initBuffer(&headers_buf);

    headers.appendBounded(std.http.Header{ .name = "Upgrade", .value = "websocket" }) catch unreachable;
    headers.appendBounded(std.http.Header{ .name = "Sec-WebSocket-Key", .value = &websocket_key }) catch unreachable;
    headers.appendBounded(std.http.Header{ .name = "Sec-WebSocket-Version", .value = "13" }) catch unreachable;
    if (extra_headers) |extra| {
        try headers.appendSliceBounded(extra);
    }
    var req = self.http_client.request(.GET, uri, .{
        .headers = .{
            .connection = .{ .override = "Upgrade" },
        },
        .extra_headers = headers.items,
    }) catch return error.HttpRequestError;
    errdefer req.deinit();

    req.sendBodiless() catch |err| switch (err) {
        error.WriteFailed => switch (req.connection.?.stream_writer.err.?) {
            error.Canceled => return error.Canceled,
            else => return error.HttpRequestError,
        },
    };

    const response = req.receiveHead(&.{}) catch |err| switch (err) {
        error.ReadFailed => switch (req.connection.?.getReadError().?) {
            error.Canceled => return error.Canceled,
            else => return error.HttpRequestError,
        },
        error.WriteFailed => switch (req.connection.?.stream_writer.err.?) {
            error.Canceled => return error.Canceled,
            else => return error.HttpRequestError,
        },
        else => return error.HttpRequestError,
    };

    if (response.head.status != .switching_protocols) {
        ws.log.err("expected status 101 SWITCHING PROTOCOLS, got {d} {s}", .{ @intFromEnum(response.head.status), response.head.status.phrase() orelse "unknown" });
        return error.NotWebsocketServer;
    }

    const expected_ws_accept = expectedWebsocketAcceptHeader(websocket_key);
    var upgrade_seen = false;
    var connection_seen = false;
    var accept_seen = false;
    var headers_iter = response.head.iterateHeaders();
    while (headers_iter.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "Upgrade")) {
            upgrade_seen = true;
            if (!std.ascii.eqlIgnoreCase(header.value, "websocket")) {
                ws.log.err("Server did not respond with the correct 'Upgrade' header. Expected 'websocket' (not case-sensitive), found '{s}'", .{header.value});
                return error.NotWebsocketServer;
            }
        }
        if (std.ascii.eqlIgnoreCase(header.name, "Connection")) {
            connection_seen = true;
            if (!std.ascii.eqlIgnoreCase(header.value, "upgrade")) {
                ws.log.err("Server did not respond with the correct 'Connection' header. Expected 'upgrade' (not case-sensitive), found '{s}'", .{header.value});
                return error.NotWebsocketServer;
            }
        }
        if (std.ascii.eqlIgnoreCase(header.name, "Sec-WebSocket-Accept")) {
            accept_seen = true;
            if (!std.mem.eql(u8, header.value, &expected_ws_accept)) {
                ws.log.err("Server did not respond with the correct 'Sec-WebSocket-Accept' header. Expected '{s}', found '{s}'", .{ &expected_ws_accept, header.value });
                return error.NotWebsocketServer;
            }
        }
    }
    if (!upgrade_seen) {
        ws.log.err("Server did not respond with an 'Upgrade' header.", .{});
        return error.NotWebsocketServer;
    }
    if (!connection_seen) {
        ws.log.err("Server did not respond with an 'Connection' header.", .{});
        return error.NotWebsocketServer;
    }
    if (!accept_seen) {
        ws.log.err("Server did not respond with an 'Upgrade' header.", .{});
        return error.NotWebsocketServer;
    }

    return client.Connection.init(req, self.rng.interface());
}

pub fn deinit(self: *Client) void {
    self.http_client.deinit();
}

fn generateRandomWebsocketKey(rng: std.Random) [b64_encoder.calcSize(16)]u8 {
    var buf: [16]u8 = undefined;
    var out_buf: [b64_encoder.calcSize(16)]u8 = undefined;
    rng.bytes(&buf);
    _ = b64_encoder.encode(&out_buf, &buf);

    return out_buf;
}

fn expectedWebsocketAcceptHeader(key: [b64_encoder.calcSize(16)]u8) [b64_encoder.calcSize(20)]u8 {
    const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var buf: [key.len + ws_guid.len]u8 = undefined;
    var concatted = std.ArrayList(u8).initBuffer(&buf);
    concatted.appendSliceBounded(&key) catch unreachable;
    concatted.appendSliceBounded(ws_guid) catch unreachable;

    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(concatted.items);

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
