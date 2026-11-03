//! Refitting outputs cannot satisfy the fresh-detector control; failed attempts and lost guards still refuse.
const std = @import("std");
const api = @import("engine_api");
const fixture = @import("slide_learn_path_test.zig");
const Server = @import("server.zig").Server;
const Cx = @import("errors.zig").Cx;
const teach = @import("slide_lesson.zig");
const redraw = @import("slide_redraw.zig");
const Stays = @import("slide_verify_test.zig").Stays;
const t = std.testing;

test "Lesson repeat: a refused draw is dropped and new detector rows can keep the next draw" {
    var model = try fixture.teachModel(.{ .seeded_questions = true, .accept_after = 2 }, &.{"I like blue."});
    defer model.deinit();
    try t.expectEqual(@as(usize, 1), model.lessons);
    try t.expect(model.live[0]);
    try t.expectEqual(@as(usize, 2), model.starts);
    try t.expectEqual(@as(usize, 0), model.continuations);
    try t.expect(model.drops > 0);
    try t.expectEqual(@as(usize, 0), model.sampled_while_open);
    try t.expectEqual(@as(usize, 2), model.detector_fingerprints.items.len);
    try t.expect(model.detector_fingerprints.items[0] != model.detector_fingerprints.items[1]);
}

test "Lesson repeat: a planted bad lesson refuses after bounded fresh draws and leaves nothing kept" {
    var model = try fixture.teachModel(.{ .seeded_questions = true, .gives_up = "I like blue." }, &.{"I like blue."});
    defer model.deinit();
    try t.expectEqual(@as(usize, redraw.limit + 1), model.starts);
    try t.expectEqual(@as(usize, 2), model.continuations);
    try t.expectEqual(@as(usize, 0), model.lessons);
    try t.expectEqual(@as(usize, 0), model.trained.items.len);
    try t.expectEqual(@as(usize, 0), model.sampled_while_open);
    try t.expect(!model.live[0]);
}

test "Lesson repeat: an unsuccessful drop never starts another draw" {
    var model = try fixture.teachModel(.{ .seeded_questions = true, .accept_after = 2, .refuse_drop = true }, &.{"I like blue."});
    defer model.deinit();
    try t.expectEqual(@as(usize, 1), model.starts);
    try t.expectEqual(@as(usize, 0), model.continuations);
    try t.expectEqual(@as(usize, 0), model.lessons);
    try t.expect(!model.live[0]);
}

test "Lesson repeat: a re-draw preserves the initial leak and training guards" {
    var model: fixture.Model = .{ .seeded_questions = true };
    defer model.deinit();
    var text: fixture.Text = .{};
    const srv = try Server.init(t.allocator, t.io, model.engine(), text.text(), .{ .served_name = "m", .model_ids = &.{"m"}, .enable_thinking = false, .use_drafts = false }, null);
    defer srv.deinit();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var cx: Cx = .{ .a = arena.allocator() };
    var kept = [_]bool{false};
    var initial = (try teach.lesson(srv, &cx, &srv.teacher, &.{"I like blue."}, &kept, false, &.{}, &.{}, Stays{})).?;
    const guard: teach.Check = .{ .question = "What is my private code?", .before = "unknown", .thinking = "unchanged", .invents = true };
    initial.checks = &.{guard};
    const ex: api.Example = .{ .ids = &.{ 197, 198 }, .start = 1, .decide = 0 };
    initial.full.keep = &.{ex};
    initial.full.near = &.{ex};
    initial.full.unasked = &.{ex};
    const next = (try redraw.rebuild(srv, &cx, initial, 1, Stays{})).?;
    try t.expectEqualDeep(guard, next.checks[0]);
    try t.expectEqualDeep(ex, next.full.keep[0]);
    try t.expectEqualDeep(ex, next.full.near[0]);
    try t.expectEqualDeep(ex, next.full.unasked[0]);
    try t.expectError(error.WordingAttemptLimit, redraw.rebuild(srv, &cx, initial, 0, Stays{}));
    try t.expectError(error.WordingAttemptLimit, redraw.rebuild(srv, &cx, initial, redraw.limit + 1, Stays{}));
}

test "Lesson repeat: prompt-seed keeps the old output-only retry sequence" {
    var model: fixture.Model = .{ .seeded_questions = true, .accept_after = 2 };
    defer model.deinit();
    var text: fixture.Text = .{};
    const srv = try Server.init(t.allocator, t.io, model.engine(), text.text(), .{ .served_name = "m", .model_ids = &.{"m"}, .enable_thinking = false, .use_drafts = false, .prompt_seed = true }, null);
    defer srv.deinit();
    try fixture.learnOne(srv, "I like blue.", "held plain 0/2 FAIL");
    try t.expectEqual(@as(usize, 1), model.starts);
    try t.expectEqual(@as(usize, 4), model.continuations);
    try t.expectEqual(@as(usize, 0), srv.teacher.lessons);
    try t.expect(!model.live[0]);
}
