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

    // The body may itself contain ';', so only trailing `;agent=...` and
    // `;state=...` fields are split off. Anything else keeps the body intact,
    // matching plain OSC 777 behavior.
    const rest = data[t + 1 .. data.len - 1];
    var body_end = rest.len;
    var agent: ?[:0]const u8 = null;
    var state: ?[:0]const u8 = null;
    while (std.mem.lastIndexOfScalar(u8, rest[0..body_end], ';')) |semi| {
        const field = rest[semi + 1 .. body_end];
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse break;
        const key = field[0..eq];
        // data[t + 1 + body_end] is already 0: the trailing sentinel on the
        // first pass, the ';' overwritten below on later passes.
        const value = data[t + 1 + semi + 1 + eq + 1 .. t + 1 + body_end :0];
        if (std.mem.eql(u8, key, "agent")) {
            if (agent == null) agent = value;
        } else if (std.mem.eql(u8, key, "state")) {
            if (state == null) state = value;
        } else break;
        data[t + 1 + semi] = 0;
        body_end = semi;
    }
    const body = data[t + 1 .. t + 1 + body_end :0];

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

test "OSC: OSC 777 show desktop notification body keeps semicolons" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "777;notify;Build;done; 3 warnings";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings(cmd.show_desktop_notification.title, "Build");
    try testing.expectEqualStrings(cmd.show_desktop_notification.body, "done; 3 warnings");
    try testing.expect(cmd.show_desktop_notification.agent == null);
    try testing.expect(cmd.show_desktop_notification.state == null);
}

test "OSC: OSC 777 show desktop notification body with semicolons and agent" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "777;notify;Title;a;b=c;d;agent=claude";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings(cmd.show_desktop_notification.body, "a;b=c;d");
    try testing.expectEqualStrings(cmd.show_desktop_notification.agent.?, "claude");
    try testing.expect(cmd.show_desktop_notification.state == null);
}

test "OSC: OSC 777 show desktop notification unknown trailing key stays in body" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "777;notify;Title;Body;url=https://x?a=b";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings(cmd.show_desktop_notification.body, "Body;url=https://x?a=b");
    try testing.expect(cmd.show_desktop_notification.agent == null);
}
