//! Rebuild only after the rejected fit is gone; retain the initial unrelated-answer guards on every attempt.
const std = @import("std");
const api = @import("engine_api");
const teach = @import("slide_lesson.zig");
const Server = @import("server.zig").Server;
const Cx = @import("errors.zig").Cx;

pub const limit = 2;

pub fn rebuild(srv: *Server, cx: *Cx, initial: teach.Plan, attempt: u32, gone: anytype) !?teach.Plan {
    if (attempt == 0 or attempt > limit) return error.WordingAttemptLimit;
    const source = initial.source orelse return null;
    const a = cx.a;
    const kept = try a.alloc(bool, initial.facts.len);
    @memset(kept, false);
    var next = (try teach.lessonAt(srv, cx, &srv.teacher, initial.facts, kept, initial.document, source.siblings, source.supplied, attempt, gone)) orelse return null;
    // Initial answers remain authoritative even if a new draw writes different nearby questions.
    var checks: std.ArrayList(teach.Check) = .empty;
    try checks.appendSlice(a, initial.checks);
    for (next.checks) |candidate| {
        for (checks.items) |old| {
            if (old.invents == candidate.invents and std.mem.eql(u8, old.question, candidate.question) and
                std.mem.eql(u8, old.before, candidate.before) and std.mem.eql(u8, old.thinking, candidate.thinking)) break;
        } else try checks.append(a, candidate);
    }
    next.checks = checks.items;
    next.full.keep = try preserve(a, initial.full.keep, next.full.keep);
    next.full.near = try preserve(a, initial.full.near, next.full.near);
    next.full.unasked = try preserve(a, initial.full.unasked, next.full.unasked);
    return next;
}

fn preserve(a: std.mem.Allocator, before: []const api.Example, after: []const api.Example) ![]const api.Example {
    var out: std.ArrayList(api.Example) = .empty;
    try out.appendSlice(a, before);
    for (after) |candidate| {
        for (out.items) |old| {
            if (old.start == candidate.start and old.decide == candidate.decide and old.subject == candidate.subject and
                old.value == candidate.value and old.context == candidate.context and std.mem.eql(u32, old.ids, candidate.ids)) break;
        } else try out.append(a, candidate);
    }
    return out.items;
}
