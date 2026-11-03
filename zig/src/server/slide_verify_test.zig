//! Scripted replies exercise each refusing sub-check and the actual learned event.
const std = @import("std");
const api = @import("engine_api");
const Server = @import("server.zig").Server;
const fixture = @import("slide_learn_path_test.zig");
const verify = @import("slide_verify.zig");
const receipt = @import("slide_verdict.zig");
const teach = @import("slide_lesson.zig");
const Cx = @import("errors.zig").Cx;
const t = std.testing;
pub const Stays = struct {
    pub fn check(_: @This()) bool {
        return false;
    }
};
const Failure = enum { none, plain, thinking, probes };
const Model = struct {
    failure: Failure,
    fn engine(m: *@This()) api.Engine {
        return .{ .ctx = m, .vtable = &.{ .info = info, .submit = submit, .cancel = cancel, .status = status, .memory = memory } };
    }
    fn info(_: *anyopaque) api.Info {
        return .{};
    }
    fn cancel(_: *anyopaque, _: api.Id) void {}
    fn status(_: *anyopaque, s: *api.Status, _: []u32) void {
        s.* = .{};
    }
    fn memory(_: *anyopaque, _: bool) ?api.Memory {
        return null;
    }
    fn submit(ctx: *anyopaque, id: api.Id, req: *const api.Request, sink: api.Sink) api.SubmitError!void {
        const m: *Model = @ptrCast(@alignCast(ctx));
        var text: [2048]u8 = undefined;
        const n = @min(text.len, req.prompt.len);
        for (req.prompt[0..n], text[0..n]) |v, *out| out.* = @intCast(v);
        const q = text[0..n];
        const held = std.mem.indexOf(u8, q, "held") != null;
        const probes = std.mem.indexOf(u8, q, "probe") != null;
        const failed = (m.failure == .plain and held and req.max_tokens < 320) or
            (m.failure == .thinking and held and req.max_tokens >= 320) or (m.failure == .probes and probes);
        const answer = if (held and req.max_tokens >= 320) (if (failed) "</think>I don't know." else "</think>blue") else if (failed) "I don't know." else if (held or probes) "blue" else "The ocean is large.";
        var ids: [64]u32 = undefined;
        for (answer, ids[0..answer.len]) |c, *out| out.* = c;
        sink.event(sink.ctx, id, &.{ .prefilled = 0 });
        sink.event(sink.ctx, id, &.{ .tokens = ids[0..answer.len] });
        sink.event(sink.ctx, id, &.{ .finished = .{ .reason = .stop } });
    }
};

test "Lesson repeat: every refusing recall sub-check has its own counts and reason" {
    for ([_]Failure{ .none, .plain, .thinking, .probes }) |failure| {
        var m: Model = .{ .failure = failure };
        var text: fixture.Text = .{};
        const srv = try Server.init(t.allocator, t.io, m.engine(), text.text(), .{ .served_name = "m", .model_ids = &.{"m"}, .use_drafts = false }, null);
        defer srv.deinit();
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var cx: Cx = .{ .a = a };
        const held: teach.Held = .{ .question = "What colour do I like (held)?", .answer = "blue", .short = "blue", .fact = 0 };
        const probes = [_]teach.Held{
            .{ .question = "What colour do I like (probe 1)?", .answer = "blue", .short = "blue", .fact = 0 },
            .{ .question = "What colour do I like (probe 2)?", .answer = "blue", .short = "blue", .fact = 0 },
            .{ .question = "What colour do I like (probe 3)?", .answer = "blue", .short = "blue", .fact = 0 },
            .{ .question = "What colour do I like (probe 4)?", .answer = "blue", .short = "blue", .fact = 0 },
        };
        const verdict = try verify.verify(srv, &cx, .{ .full = .{}, .facts = &.{"I like blue."}, .held = &.{held}, .probes = &probes, .checks = &.{}, .thinks = true }, true, Stays{});
        try t.expect(verdict.damage == null and verdict.took == null);
        try t.expectEqualSlices(bool, &.{failure == .none}, verdict.recalled);
        const c = verdict.counts[0];
        try t.expectEqual(@as(usize, 1), c.plain.asked);
        try t.expectEqual(@as(usize, 1), c.thinking.asked);
        try t.expectEqual(@as(usize, 4), c.probes.asked);
        try t.expectEqual(@as(usize, @intFromBool(failure != .plain)), c.plain.passed);
        try t.expectEqual(@as(usize, @intFromBool(failure != .thinking)), c.thinking.passed);
        try t.expectEqual(@as(usize, if (failure == .probes) 0 else 4), c.probes.passed);
        const why = receipt.message(a, null, verdict.recalled, verdict.counts);
        if (failure == .none) try t.expect(why == null) else {
            const name = switch (failure) {
                .plain => "held plain 0/1 FAIL",
                .thinking => "held thinking 0/1 FAIL",
                .probes => "probes 0/4 FAIL",
                .none => unreachable,
            };
            try t.expect(std.mem.indexOf(u8, why.?, name) != null);
        }
    }
}

test "Lesson repeat: a refused learned event names its last held and probe counts" {
    var m: fixture.Model = .{ .gives_up = "I like blue." };
    defer m.deinit();
    var text: fixture.Text = .{};
    const srv = try Server.init(t.allocator, t.io, m.engine(), text.text(), .{ .served_name = "m", .model_ids = &.{"m"}, .enable_thinking = false, .use_drafts = false }, null);
    defer srv.deinit();
    try fixture.learnOne(srv, "I like blue.", "held plain 0/2 FAIL");
    try t.expectEqual(@as(usize, 0), srv.teacher.lessons);
    try t.expect(!m.live[0]);
}
