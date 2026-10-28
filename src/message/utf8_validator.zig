const std = @import("std");
const builtin = @import("builtin");

/// A streamable way to validate UTF-8 byte sequences.
///
/// Returns an error if not a valid utf8-string. `next_partial_codepoint` should be an empty ArrayList initialized with [3]u8.
///
/// Adapted from utf8CountValidBytes.
pub fn utf8ValidateStream(prev_partial_codepoint: []const u8, str: []const u8, next_partial_codepoint: *std.ArrayList(u8)) !void {
    if (prev_partial_codepoint.len > 0) {
        @branchHint(.cold);
        const codepoint_len = try std.unicode.utf8ByteSequenceLength(prev_partial_codepoint[0]); // 1-4
        const remaining_bytes_in_codepoint = codepoint_len - prev_partial_codepoint.len; // 1-3
        if (str.len < remaining_bytes_in_codepoint) {
            @branchHint(.cold);
            try next_partial_codepoint.appendSliceBounded(prev_partial_codepoint);
            errdefer next_partial_codepoint.clearRetainingCapacity();
            try next_partial_codepoint.appendSliceBounded(str);
            return;
        }

        var byteseq_buf: [4]u8 = undefined;
        var byteseq = std.ArrayList(u8).initBuffer(&byteseq_buf);
        try byteseq.appendSliceBounded(prev_partial_codepoint);
        try byteseq.appendSliceBounded(str[0..remaining_bytes_in_codepoint]);
        _ = try std.unicode.utf8Decode(byteseq.items);

        // even though recursion is used here, max depth is 1 since the recursive condition is arg0.len > 0.
        try utf8ValidateStream(&.{}, str[remaining_bytes_in_codepoint..], next_partial_codepoint);
        return;
    }

    const N = @sizeOf(usize);
    const MASK = 0x80 * (std.math.maxInt(usize) / 0xff);

    var i: usize = 0;
    while (i < str.len) {
        // Fast path for ASCII sequences
        while (i + N <= str.len) : (i += N) {
            const v = std.mem.readInt(usize, str[i..][0..N], builtin.cpu.arch.endian());
            if (v & MASK != 0) break;
        }

        if (i < str.len) {
            const n = try std.unicode.utf8ByteSequenceLength(str[i]);
            if (i + n > str.len) {
                try next_partial_codepoint.appendSliceBounded(str[i..]);
                return;
            }

            switch (n) {
                1 => {}, // ASCII, no validation needed
                else => _ = try std.unicode.utf8Decode(str[i..][0..n]),
            }

            i += n;
        }
    }

    return;
}

test "tokyo calling - aratashi gakko (valid utf8)" {
    const str =
        \\Tokyo Calling
        \\都市は almost falling
        \\まるで 悪夢で見た 最悪の story
    ;

    for (0..str.len) |split| {
        const str1 = str[0..split];
        const str2 = str[split..];

        var leftover_buf: [4]u8 = undefined;
        var leftover = std.ArrayList(u8).initBuffer(&leftover_buf);
        try utf8ValidateStream(&.{}, str1, &leftover);
        var expected_empty_buf: [4]u8 = undefined;
        var expected_empty = std.ArrayList(u8).initBuffer(&expected_empty_buf);
        try utf8ValidateStream(leftover.items, str2, &expected_empty);

        try std.testing.expectEqualSlices(u8, &.{}, expected_empty.items);
    }
}

test "random data (invalid utf8)" {
    const valid_str = "this is some valid utf8 and some non-ascii 우주 위 떠오른 characters too";
    const invalid_str = &.{ 0xdf, 0x23, 0x0b, 0x49, 0x61, 0x5d, 0x17 };
    var str_buf: [100]u8 = undefined;
    var str = std.ArrayList(u8).initBuffer(&str_buf);
    str.appendSliceBounded(valid_str) catch unreachable;
    str.appendSliceBounded(invalid_str) catch unreachable; // this probably has some funny code point in it that's bad

    for (0..str.items.len) |split| {
        const str1 = str.items[0..split];
        _ = str.items[split..];

        if (str1.len < valid_str.len + 2) {
            var buf: [3]u8 = undefined;
            var next_partial_codepoint = std.ArrayList(u8).initBuffer(&buf);
            _ = try utf8ValidateStream(&.{}, str1, &next_partial_codepoint);
        } else {
            var buf: [3]u8 = undefined;
            var next_partial_codepoint = std.ArrayList(u8).initBuffer(&buf);
            try std.testing.expectError(error.Utf8ExpectedContinuation, utf8ValidateStream(&.{}, str1, &next_partial_codepoint));
        }
    }
}
