const std = @import("std");
const builtin = @import("builtin");

/// A streamable way to validate UTF-8 byte sequences.
///
/// Returns an error if not a valid utf8-string, otherwise returns a final partial code-point (or empty if the entire stream is valid)
///
/// Adapted from utf8CountValidBytes.
pub fn utf8ValidateStream(prev_partial_codepoint: std.BoundedArray(u8, 3), str: []const u8) !std.BoundedArray(u8, 3) {
    if (prev_partial_codepoint.len > 0) { // TODO - set this block to be cold
        const codepoint_len = try std.unicode.utf8ByteSequenceLength(prev_partial_codepoint.get(0)); // 1-4
        const remaining_bytes_in_codepoint = codepoint_len - prev_partial_codepoint.len; // 1-3
        if (str.len < remaining_bytes_in_codepoint) {
            var new_partial_codepoint = std.BoundedArray(u8, 3){};
            new_partial_codepoint.appendSlice(prev_partial_codepoint.constSlice()) catch unreachable;
            new_partial_codepoint.appendSlice(str) catch unreachable;
            return new_partial_codepoint;
        }

        var byteseq = std.BoundedArray(u8, 4){};
        byteseq.appendSlice(prev_partial_codepoint.constSlice()) catch unreachable;
        byteseq.appendSlice(str[0..remaining_bytes_in_codepoint]) catch unreachable;
        _ = try std.unicode.utf8Decode(byteseq.constSlice());

        // note, even though recursion is used here, max depth is 1 since the recursive condition is arg0.len > 0.
        return utf8ValidateStream(.{}, str[remaining_bytes_in_codepoint..]);
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
                const partial_codepoint = std.BoundedArray(u8, 3).fromSlice(str[i..]) catch unreachable;
                return partial_codepoint;
            }

            switch (n) {
                1 => {}, // ASCII, no validation needed
                else => _ = try std.unicode.utf8Decode(str[i..][0..n]),
            }

            i += n;
        }
    }

    return std.BoundedArray(u8, 3){};
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

        const leftover = try utf8ValidateStream(.{}, str1);
        const expected_empty = try utf8ValidateStream(leftover, str2);

        try std.testing.expectEqualSlices(u8, &.{}, expected_empty.constSlice());
    }
}

test "random data (invalid utf8)" {
    const valid_str = "this is some valid utf8 and some non-ascii 우주 위 떠오른 characters too";
    const invalid_str = &.{ 0xdf, 0x23, 0x0b, 0x49, 0x61, 0x5d, 0x17 };
    var str = std.BoundedArray(u8, 100){};
    str.appendSlice(valid_str) catch unreachable;
    str.appendSlice(invalid_str) catch unreachable; // this probably has some funny code point in it that's bad

    for (0..str.len) |split| {
        const str1 = str.constSlice()[0..split];
        _ = str.constSlice()[split..];

        if (str1.len < valid_str.len + 2) {
            _ = try utf8ValidateStream(.{}, str1);
        } else {
            try std.testing.expectError(error.Utf8ExpectedContinuation, utf8ValidateStream(.{}, str1));
        }
    }
}
