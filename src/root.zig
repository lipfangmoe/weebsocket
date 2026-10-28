const std = @import("std");
const testing = std.testing;

pub const client = @import("./client.zig");

test {
    std.testing.refAllDeclsRecursive(@This());
}
