const std = @import("std");
const builtin = @import("builtin");

/// A streamable way to validate UTF-8 byte sequences.
///
/// Returns an error if not a valid utf8-string. `next_partial_codepoint` should be an empty ArrayList initialized with [3]u8.
///
/// Adapted from utf8CountValidBytes.
pub fn utf8ValidateStream(prev_partial_codepoint: []const u8, _str: []const u8, next_partial_codepoint: *std.ArrayList(u8)) !void {
    std.debug.assert(prev_partial_codepoint.len < 4);
    std.debug.assert(next_partial_codepoint.capacity == 3);

    var str = _str;
    if (prev_partial_codepoint.len > 0) {
        @branchHint(.cold);
        var first_codepoint_buf: [4]u8 = undefined;
        var first_codepoint: std.ArrayList(u8) = .initBuffer(&first_codepoint_buf);
        const codepoint_len = try std.unicode.utf8ByteSequenceLength(prev_partial_codepoint[0]);
        const remaining_bytes_in_codepoint = codepoint_len - prev_partial_codepoint.len;
        if (_str.len < remaining_bytes_in_codepoint) {
            @branchHint(.cold);
            next_partial_codepoint.appendSliceBounded(prev_partial_codepoint) catch unreachable;
            next_partial_codepoint.appendSliceBounded(_str) catch unreachable;
            return;
        }
        first_codepoint.appendSliceBounded(prev_partial_codepoint) catch unreachable;
        first_codepoint.appendSliceBounded(_str[0..remaining_bytes_in_codepoint]) catch unreachable;
        if (!std.unicode.utf8ValidateSlice(first_codepoint.items)) {
            return error.InvalidFirstCodepoint;
        }
        str = _str[remaining_bytes_in_codepoint..];
    }

    while (str.len > 0) {
        // TODO - redo fast path for ascii-only strings by reading multiple characters as a single usize and skipping them if they are all ascii

        const codepoint_len = try std.unicode.utf8ByteSequenceLength(str[0]);
        if (codepoint_len == 1) {
            @branchHint(.likely);
            str = str[1..];
            continue;
        }

        if (str.len < codepoint_len) {
            @branchHint(.unlikely);
            next_partial_codepoint.appendSliceBounded(str) catch unreachable;
            return;
        }

        _ = try std.unicode.utf8Decode(str[0..codepoint_len]);
        str = str[codepoint_len..];
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

        var leftover_buf: [3]u8 = undefined;
        var leftover = std.ArrayList(u8).initBuffer(&leftover_buf);
        try utf8ValidateStream(&.{}, str1, &leftover);
        var expected_empty_buf: [3]u8 = undefined;
        var expected_empty = std.ArrayList(u8).initBuffer(&expected_empty_buf);
        try utf8ValidateStream(leftover.items, str2, &expected_empty);

        try std.testing.expectEqualSlices(u8, &.{}, expected_empty.items);
    }
}

test "autobahn 6.2.3" {
    if (true) {
        // see https://github.com/crossbario/autobahn-testsuite/issues/145
        return error.SkipZigTest;
    }
    const str = "Hello-\xb5@\xdf\xf6\xe4\xfc\xe0\xe1-UTF-8!!";

    for (0..str.len) |split| {
        const str1 = str[0..split];
        const str2 = str[split..];

        var leftover_buf: [3]u8 = undefined;
        var leftover = std.ArrayList(u8).initBuffer(&leftover_buf);
        try utf8ValidateStream(&.{}, str1, &leftover);

        var expected_empty_buf: [3]u8 = undefined;
        var expected_empty = std.ArrayList(u8).initBuffer(&expected_empty_buf);
        try utf8ValidateStream(leftover.items, str2, &expected_empty);

        try std.testing.expectEqualSlices(u8, &.{}, expected_empty.items);
    }
}

test "autobahn 6.2.4" {
    const str = "\xce\xba\xe1\xbd\xb9\xcf\x83\xce\xbc\xce\xb5";

    for (0..str.len) |split| {
        const str1 = str[0..split];
        const str2 = str[split..];

        var leftover_buf: [3]u8 = undefined;
        var leftover = std.ArrayList(u8).initBuffer(&leftover_buf);
        try utf8ValidateStream(&.{}, str1, &leftover);

        var expected_empty_buf: [3]u8 = undefined;
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
