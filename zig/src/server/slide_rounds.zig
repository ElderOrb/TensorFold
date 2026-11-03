//! A checked lesson's bounded rounds and fresh wording attempts.
const std = @import("std");
const api = @import("engine_api");
const Server = @import("server.zig").Server;
const Allocator = std.mem.Allocator;
const errors = @import("errors.zig");
const teach = @import("slide_lesson.zig");
const check = @import("slide_verify.zig");
const receipt = @import("slide_verdict.zig");
const recheck = @import("slide_recheck.zig");
const log = @import("log.zig");
const retry = @import("slide_redraw.zig");
const slide = @import("slide.zig");
const run = slide.run;
const runReported = slide.runReported;
const words = slide.words;
const now = slide.now;
const seconds = slide.seconds;
const earlierLost = slide.earlierLost;
const afterTakeOut = slide.afterTakeOut;
const takeOut = slide.takeOut;
const Out = slide.Out;

const give_up = 5;

/// What a lesson's rounds left: which facts come back, the steps taken, and why it stopped early (null: it did not).
pub const Rounds = struct { recalled: []bool, counts: []const receipt.Counts = &.{}, plan: ?teach.Plan = null, steps: u32 = 0, why: ?[]const u8 = null };

/// A lesson in checked rounds until its fact comes back, then the facts before it asked again (slide_recheck.zig).
pub fn rounds(srv: *Server, a: Allocator, cx: *errors.Cx, initial: teach.Plan, gone: anytype, id: u32, o: *Out) Rounds {
    var plan = initial;
    var out: Rounds = .{ .recalled = a.alloc(bool, plan.facts.len) catch &.{} };
    @memset(out.recalled, false);
    var routed: u32 = 0;
    var repaired: u32 = 0;
    // the facts learned before, as they stood when this lesson began: what its checks find forgotten is against these
    const before = srv.slide.earlier(a, id) catch |e| {
        out.why = words(cx, e);
        return out;
    };
    var committed = false;
    defer if (!committed) takeOut(srv, a, &out, id, out.why orelse "taken out: its full commit gate did not pass");
    var asked_after = false; // the facts before it were asked again after its take-out: their verdicts are current
    // a lesson not kept leaves the facts before it as it found them, so their verdicts go back to what they were
    defer if (!asked_after and !std.mem.allEqual(bool, out.recalled, true)) srv.slide.restoreChecks(before);
    var unchecked = false; // the lesson was fitted again after its last check
    var streak: u32 = 0; // rounds in a row whose held-out questions came back when asked
    var fresh = true;
    var redraws: u32 = 0;
    var ever = false; // a round whose held-out questions all came back when asked
    for (0..teach.rounds + teach.reroutes + recheck.repairs) |round| {
        const began = now(srv);
        var request = plan.full;
        request.more = !fresh;
        var held = false;
        srv.slide.round(id, @intCast(round + 1));
        o.stage(id, "initializing");
        switch (runReported(srv, a, &request, id, o)) {
            .learned => |l| {
                out.steps += l.steps;
                held = l.recalled;
            },
            .failed => |message| {
                out.why = message;
                return out;
            },
            .refused => |err| {
                out.why = words(cx, err);
                return out;
            },
            .none => {
                out.why = "the learner returned no fitted lesson";
                return out;
            },
        }
        fresh = false;
        const learned = seconds(srv, began);
        unchecked = false;
        const checked = now(srv);
        srv.slide.phase(id, .checking);
        o.stage(id, "checking");
        const verdict = check.verify(srv, cx, plan, held or round + 1 >= teach.rounds, gone) catch |e| check.Verdict{ .recalled = out.recalled, .damage = words(cx, e) };
        out.counts = verdict.counts;
        srv.slide.checked(id, verdict.damage == null and std.mem.allEqual(bool, verdict.recalled, true));
        log.line("slide: round {d}: {d} steps ({d:.1} s learning, {d:.1} s checking); the held-out answers {s} token for token, and {s} when asked; {s}", .{ round + 1, out.steps, learned, seconds(srv, checked), if (held) "come back" else "do not come back", if (std.mem.allEqual(bool, verdict.recalled, true)) "come back" else "do not come back", receipt.summary(a, verdict.counts) catch "recall counts unavailable" });
        if (verdict.took) |took| {
            if (routed == teach.reroutes) {
                _ = run(srv, a, &.{ .drop = true }, 0);
                srv.slide.placed(id, &.{});
                out.why = std.fmt.allocPrint(a, "taken out: it kept answering questions about something else, last \"{s}\"", .{took.question}) catch "taken out: it kept answering questions about something else";
                @memset(out.recalled, false);
                return out;
            }
            routed += 1;
            const back = teach.routed(srv, cx, took) catch |e| {
                out.why = words(cx, e);
                return out;
            };
            switch (runReported(srv, a, &.{ .unasked = &.{back.prompt}, .kept = &.{back.kept}, .reroute = true }, id, o)) {
                .failed => |message| {
                    out.why = message;
                    return out;
                },
                else => {},
            }
            log.line("slide: \"{s}\" is handed back to the lesson, its answer to stay as it was", .{took.question});
            srv.slide.note(id, std.fmt.allocPrint(a, "handed back to the lesson: \"{s}\"", .{took.question}) catch "");
            continue;
        }
        if (verdict.damage) |why| {
            _ = run(srv, a, &.{ .undo = true }, 0);
            srv.slide.placed(id, &.{});
            @memset(out.recalled, false); // the undo took the whole fact out: nothing of it is kept
            out.why = std.fmt.allocPrint(a, "round {d} taken back: {s}", .{ round + 1, why }) catch why;
            return out;
        }
        @memcpy(out.recalled, verdict.recalled);
        streak = if (std.mem.allEqual(bool, out.recalled, true)) streak + 1 else 0;
        ever = ever or streak > 0;
        // rounds that never once brought the fact back when asked do not start to: give up rather than learn on
        if (!ever and round + 1 >= give_up) break;
        if (!std.mem.allEqual(bool, out.recalled, true) and redraws < retry.limit and
            !srv.config.prompt_seed and plan.source != null)
        {
            switch (runReported(srv, a, &.{ .drop = true }, id, o)) {
                .none => {},
                .failed => |why| {
                    out.why = why;
                    return out;
                },
                else => {
                    out.why = "the refused fit could not be taken out before new wordings";
                    return out;
                },
            }
            srv.slide.placed(id, &.{});
            @memset(out.recalled, false);
            redraws += 1;
            o.stage(id, "writing");
            plan = (retry.rebuild(srv, cx, initial, redraws, gone) catch |err| {
                out.why = words(cx, err);
                return out;
            }) orelse {
                out.why = "the refused lesson could not supply a new clean wording plan";
                return out;
            };
            out.plan = plan;
            srv.slide.asked(id, slide.expected(a, plan));
            fresh = true;
            streak = 0;
            log.line("slide: fact {d}: refused fit taken out; wordings redrawn, attempt {d}/{d}", .{ id, redraws, retry.limit });
            continue;
        }
        // done once its answers come back token for token, or come back when asked two rounds running
        if ((held or streak >= 2) and std.mem.allEqual(bool, out.recalled, true) and round + 1 >= teach.min_rounds) {
            const lost = earlierLost(srv, cx, o, id, before, gone) catch |e| {
                takeOut(srv, a, &out, id, std.fmt.allocPrint(a, "taken out: the facts learned before could not be asked again ({s})", .{words(cx, e)}) catch "taken out");
                return out;
            };
            if (lost.len == 0) {
                if (srv.config.slide_drift_gate) {
                    if (@import("slide_metrics.zig").candidate(srv, cx, plan, id, gone)) |why| {
                        takeOut(srv, a, &out, id, why);
                        return out;
                    }
                }
                committed = true;
                // a diagnostic: every kept lesson taken out again, to see the facts before it come back as they were
                if (std.c.getenv("TF_SLIDE_TAKE_OUT_CHECK") != null) {
                    takeOut(srv, a, &out, id, "taken out to check that a take-out puts the facts before it back (TF_SLIDE_TAKE_OUT_CHECK)");
                    afterTakeOut(srv, cx, o, id, before, &.{}, gone);
                    asked_after = true;
                }
                return out;
            }
            const who = recheck.names(a, lost) catch "an earlier fact";
            if (repaired < recheck.repairs) {
                const back = recheck.keeps(srv, cx, lost) catch |e| {
                    takeOut(srv, a, &out, id, words(cx, e));
                    return out;
                };
                if (back.kept.len > 0) {
                    repaired += 1;
                    log.line("slide: fact {d}'s lesson made the model forget {s}: fitted again with their held-out answers kept as they were (repair {d} of {d})", .{ id, who, repaired, recheck.repairs });
                    o.event("repair", .{ .id = id, .message = std.fmt.allocPrint(a, "it made the model forget {s}: fitted again with their answers kept", .{who}) catch who });
                    switch (runReported(srv, a, &.{ .unasked = back.prompts, .kept = back.kept, .reroute = true }, id, o)) {
                        .failed => |message| {
                            takeOut(srv, a, &out, id, message);
                            return out;
                        },
                        else => {},
                    }
                    unchecked = true;
                    continue;
                }
            }
            takeOut(srv, a, &out, id, if (repaired > 0) std.fmt.allocPrint(a, "taken out: it made the model forget {s}, still after {d} repairs", .{ who, repaired }) catch who else std.fmt.allocPrint(a, "taken out: it made the model forget {s}", .{who}) catch who);
            // the facts asked once more with it out, as they will be saved: the ones it made forget are back
            afterTakeOut(srv, cx, o, id, before, lost, gone);
            asked_after = true;
            return out;
        }
    }
    // it never came back when asked, or was fitted again and never checked: nothing of it stays in the model
    if (unchecked) {
        takeOut(srv, a, &out, id, "taken out: its last repair was never checked");
        afterTakeOut(srv, cx, o, id, before, &.{}, gone);
        asked_after = true;
        return out;
    }
    if (!committed) {
        if (std.mem.allEqual(bool, out.recalled, true)) out.why = "lesson refused: no stable fully checked round";
        _ = run(srv, a, &.{ .drop = true }, 0);
        srv.slide.placed(id, &.{});
        @memset(out.recalled, false);
    }
    return out;
}
