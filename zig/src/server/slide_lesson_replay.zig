//! Earlier document answers retained by each new lesson.
const std = @import("std");
const api = @import("engine_api");
const Server = @import("server.zig").Server;
const Cx = @import("errors.zig").Cx;
const Teacher = @import("slide_teacher.zig").Teacher;
const example = @import("slide_ask.zig").example;
const log = @import("log.zig");
const replayed = 24;

/// Earlier learned answers about the subject `fact` names, the latest `replayed` of them, into `keep`.
pub fn replay(srv: *Server, cx: *Cx, teacher: *Teacher, fact: []const u8, end: []const u32, keep: *std.ArrayList(api.Example)) !void {
    var n: usize = 0;
    var i = teacher.told.items.len;
    while (i > 0 and n < replayed) : (i -= 1) {
        const t = teacher.told.items[i - 1];
        if (std.ascii.findIgnoreCase(fact, t.subject) == null) continue;
        try keep.append(cx.a, try example(srv, cx, cx.a, null, t.question, t.answer, end));
        n += 1;
    }
    if (n > 0) log.line("slide: {d} answers of earlier facts about its subject are replayed for it to keep", .{n});
}
