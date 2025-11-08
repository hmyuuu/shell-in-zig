const std = @import("std");

pub fn main() !void {
    var stdout_buffer: [512]u8 = @splat(0);
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    var stdin_buffer: [512]u8 = @splat(0);
    var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
    const stdin = &stdin_reader.interface;

    try stdout.print("$ ", .{});
    try stdout.flush();

    const input = try stdin.takeDelimiterExclusive('\n');
    try stdout.print("{s}: command not found\n", .{input});
    try stdout.flush();
}
