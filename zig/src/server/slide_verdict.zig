//! Per-fact recall receipts; these describe the existing gate and never replace its decision.
const std = @import("std");

pub const Count = struct {
    passed: usize = 0,
    asked: usize = 0,

    pub fn add(c: *Count, back: bool) void {
        c.asked += 1;
        c.passed += @intFromBool(back);
    }
};
pub const Counts = struct { plain: Count = .{}, thinking: Count = .{}, probes: Count = .{} };

pub fn summary(a: std.mem.Allocator, counts: []const Counts) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (counts, 1..) |c, f| {
        if (f > 1) try out.appendSlice(a, "; ");
        try out.print(a, "fact {d}: held plain {d}/{d}{s}, held thinking {d}/{d}{s}, probes {d}/{d}{s}", .{
            f,                 c.plain.passed,                                            c.plain.asked,                                             if (c.plain.asked == 0 or c.plain.passed < c.plain.asked) " FAIL" else "",
            c.thinking.passed, c.thinking.asked,                                          if (c.thinking.passed < c.thinking.asked) " FAIL" else "", c.probes.passed,
            c.probes.asked,    if (2 * c.probes.passed < c.probes.asked) " FAIL" else "",
        });
    }
    return out.toOwnedSlice(a);
}

pub fn message(a: std.mem.Allocator, why: ?[]const u8, recalled: []const bool, counts: []const Counts) ?[]const u8 {
    if (std.mem.allEqual(bool, recalled, true) or counts.len == 0) return why;
    return std.fmt.allocPrint(a, "{s}; last recall checks: {s}", .{ why orelse "lesson refused", summary(a, counts) catch return why }) catch why;
}
