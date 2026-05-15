const std = @import("std");

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

const log = std.log.scoped(.osc_rxvt_extension);

/// Parse OSC 777
pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };
    // ensure that we are sentinel terminated
    cap.writer.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = cap.trailing();
    const k = std.mem.indexOfScalar(u8, data, ';') orelse {
        parser.state = .invalid;
        return null;
    };
    const ext = data[0..k];
    if (!std.mem.eql(u8, ext, "notify")) {
        log.warn("unknown rxvt extension: {s}", .{ext});
        parser.state = .invalid;
        return null;
    }
    const t = std.mem.indexOfScalarPos(u8, data, k + 1, ';') orelse {
        log.warn("rxvt notify extension is missing the title", .{});
        parser.state = .invalid;
        return null;
    };
    data[t] = 0;
    const title = data[k + 1 .. t :0];

    // Find where the body ends and optional key=value pairs begin.
    // The body is the third semicolon-delimited field; everything after
    // the next semicolon (if any) is treated as key=value pairs.
    var body_end: usize = data.len - 1;
    var kv_start: ?usize = null;
    if (std.mem.indexOfScalarPos(u8, data, t + 1, ';')) |semi| {
        body_end = semi;
        data[semi] = 0;
        kv_start = semi + 1;
    }
    const body = data[t + 1 .. body_end :0];

    // Parse optional ;key=value pairs. We null-terminate each pair
    // in-place by overwriting the ';' separator (or relying on the
    // trailing sentinel for the last pair) so we can produce [:0] slices.
    var agent: ?[:0]const u8 = null;
    var state: ?[:0]const u8 = null;
    if (kv_start) |start| {
        // The region from kv_start to data.len-1 contains key=value
        // pairs separated by ';', followed by the trailing sentinel
        // byte at data[data.len-1] which is already 0.
        const kv_region = data[start .. data.len - 1];
        // Null-terminate each pair by replacing ';' with 0.
        for (kv_region) |*byte| {
            if (byte.* == ';') byte.* = 0;
        }
        // Now iterate over null-terminated segments.
        var pos: usize = 0;
        while (pos < kv_region.len) {
            const seg_start = pos;
            // Find the end of this segment (next 0 byte).
            while (pos < kv_region.len and kv_region[pos] != 0) : (pos += 1) {}
            const seg = kv_region[seg_start..pos];
            // Skip the null terminator.
            if (pos < kv_region.len) pos += 1;

            if (seg.len == 0) continue;

            if (std.mem.indexOfScalar(u8, seg, '=')) |eq| {
                const key = seg[0..eq];
                // The value runs from eq+1 to seg.len, and is
                // null-terminated at seg.ptr[seg.len] (the 0 byte
                // we wrote above, or the original trailing sentinel).
                const value: [:0]const u8 = data[start + seg_start + eq + 1 .. start + seg_start + seg.len :0];

                if (std.mem.eql(u8, key, "agent")) {
                    agent = value;
                } else if (std.mem.eql(u8, key, "state")) {
                    state = value;
                }
                // Unknown keys are silently ignored for forward compatibility.
            }
        }
    }

    parser.command = .{
        .show_desktop_notification = .{
            .title = title,
            .body = body,
            .agent = agent,
            .state = state,
        },
    };
    return &parser.command;
}

test "OSC: OSC 777 show desktop notification with title" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "777;notify;Title;Body";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings(cmd.show_desktop_notification.title, "Title");
    try testing.expectEqualStrings(cmd.show_desktop_notification.body, "Body");
    try testing.expect(cmd.show_desktop_notification.agent == null);
    try testing.expect(cmd.show_desktop_notification.state == null);
}

test "OSC: OSC 777 show desktop notification with agent and state" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "777;notify;Title;Body;agent=claude;state=waiting";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings(cmd.show_desktop_notification.title, "Title");
    try testing.expectEqualStrings(cmd.show_desktop_notification.body, "Body");
    try testing.expectEqualStrings(cmd.show_desktop_notification.agent.?, "claude");
    try testing.expectEqualStrings(cmd.show_desktop_notification.state.?, "waiting");
}

test "OSC: OSC 777 show desktop notification with only agent" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "777;notify;Title;Body;agent=codex";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings(cmd.show_desktop_notification.title, "Title");
    try testing.expectEqualStrings(cmd.show_desktop_notification.body, "Body");
    try testing.expectEqualStrings(cmd.show_desktop_notification.agent.?, "codex");
    try testing.expect(cmd.show_desktop_notification.state == null);
}

test "OSC: OSC 777 show desktop notification with unknown keys ignored" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "777;notify;Title;Body;foo=bar;agent=gemini;baz=qux";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings(cmd.show_desktop_notification.title, "Title");
    try testing.expectEqualStrings(cmd.show_desktop_notification.body, "Body");
    try testing.expectEqualStrings(cmd.show_desktop_notification.agent.?, "gemini");
    try testing.expect(cmd.show_desktop_notification.state == null);
}
