//! Test the actual sampled requests and full plans on a model whose wording order depends on the seed.
const std = @import("std");
const fixture = @import("slide_learn_path_test.zig");
const Server = @import("server.zig").Server;
const Cx = @import("errors.zig").Cx;
const asks = @import("slide_ask.zig");
const teach = @import("slide_lesson.zig");
const Stays = @import("slide_verify_test.zig").Stays;
const t = std.testing;

test "Lesson repeat: real wording requests keep content seeds and the prompt-seed override" {
    for ([_]bool{ false, true }) |prompt_seed| {
        var model: fixture.Model = .{ .seeded_questions = true, .probe_salt = -7 };
        defer model.deinit();
        var text: fixture.Text = .{};
        const srv = try Server.init(t.allocator, t.io, model.engine(), text.text(), .{ .served_name = "m", .model_ids = &.{"m"}, .enable_thinking = false, .use_drafts = false, .prompt_seed = prompt_seed, .seed_salt = -7 }, null);
        defer srv.deinit();
        var arena: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena.deinit();
        var cx: Cx = .{ .a = arena.allocator() };
        const draw: asks.Draw = .{ .fact = "I like blue.", .draw = 1 };
        const question = "Write 12 questions about the fact: I like blue.";
        const first = try asks.askWording(srv, &cx, null, question, 400, 0.9, draw, Stays{});
        const expected = if (prompt_seed) model.last_prompt_seed else draw.seed(-7);
        try t.expectEqual(expected, model.samples.items[0]);
        const again = try asks.askWording(srv, &cx, null, question, 400, 0.9, draw, Stays{});
        try t.expectEqual(expected, model.samples.items[1]);
        try t.expectEqualStrings(first.content, again.content);
        var next = draw;
        next.attempt += 1;
        _ = try asks.askWording(srv, &cx, null, question, 400, 0.9, next, Stays{});
        if (prompt_seed) try t.expectEqual(expected, model.samples.items[2]) else {
            try t.expectEqual(next.seed(-7), model.samples.items[2]);
            try t.expect(expected != model.samples.items[2]);
        }
    }
}

test "Lesson repeat: one content builds the same full plan wording for wording" {
    var model: fixture.Model = .{ .seeded_questions = true };
    defer model.deinit();
    var text: fixture.Text = .{};
    const srv = try Server.init(t.allocator, t.io, model.engine(), text.text(), .{ .served_name = "m", .model_ids = &.{"m"}, .enable_thinking = false, .use_drafts = false }, null);
    defer srv.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var cx: Cx = .{ .a = arena.allocator() };
    var kept = [_]bool{false};
    const first = (try teach.lesson(srv, &cx, &srv.teacher, &.{"I like blue."}, &kept, false, &.{}, &.{}, Stays{})).?;
    const samples = try cx.a.dupe(u64, model.samples.items);
    const again = (try teach.lesson(srv, &cx, &srv.teacher, &.{"I like blue."}, &kept, false, &.{}, &.{}, Stays{})).?;
    try t.expect(samples.len > 0);
    try t.expectEqualSlices(u64, samples, model.samples.items[samples.len..]);
    try t.expectEqualDeep(first, again);
}

test "Lesson repeat: the same lesson twice gives the same kept or refused verdict" {
    for ([_][]const u8{ "", "I like blue." }) |bad| {
        var first = try fixture.teachModel(.{ .seeded_questions = true, .gives_up = bad }, &.{"I like blue."});
        defer first.deinit();
        var again = try fixture.teachModel(.{ .seeded_questions = true, .gives_up = bad }, &.{"I like blue."});
        defer again.deinit();
        try t.expect(first.samples.items.len > 0);
        try t.expectEqualSlices(u64, first.samples.items, again.samples.items);
        try t.expectEqual(first.lessons, again.lessons);
        try t.expectEqual(first.live[0], again.live[0]);
        try t.expectEqual(bad.len == 0, first.live[0]);
    }
}
