//! Content-keyed sampled lesson wordings, independent of thread order and fresh OS randomness.
const std = @import("std");

pub const Draw = struct {
    fact: []const u8,
    attempt: u32 = 0,
    draw: u32 = 0,

    pub fn seed(d: Draw, salt: i64) u64 {
        var hash = std.hash.Wyhash.init(0x6c6573736f6e);
        hash.update(d.fact);
        var bytes: [16]u8 = undefined;
        std.mem.writeInt(i64, bytes[0..8], salt, .little);
        std.mem.writeInt(u32, bytes[8..12], d.attempt, .little);
        std.mem.writeInt(u32, bytes[12..16], d.draw, .little);
        hash.update(&bytes);
        return hash.final() & 0x7fff_ffff_ffff_ffff;
    }
};

test "Lesson repeat: content seeds distinguish salt, fact, attempt and draw" {
    const first = (Draw{ .fact = "I like blue." }).seed(0);
    try std.testing.expectEqual(first, (Draw{ .fact = "I like blue." }).seed(0));
    for ([_]u64{ (Draw{ .fact = "I like tea." }).seed(0), (Draw{ .fact = "I like blue.", .attempt = 1 }).seed(0), (Draw{ .fact = "I like blue.", .draw = 1 }).seed(0), (Draw{ .fact = "I like blue." }).seed(-1) }) |other|
        try std.testing.expect(other != first and other <= std.math.maxInt(i64));
}
