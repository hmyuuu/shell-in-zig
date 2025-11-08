const std = @import("std");
const Builtin = enum {
    exit,
    echo,
    type,
    hello,
};

fn whichCommand(allocator: std.mem.Allocator, command: []const u8) !?[]u8 {
    const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            return null;
        }
        return err;
    };
    defer allocator.free(path_env);

    var path_iter = std.mem.splitSequence(u8, path_env, ":");
    while (path_iter.next()) |dir| {
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ dir, command });
        errdefer allocator.free(full_path);

        // Try to access the file to check if it exists and is accessible
        std.fs.accessAbsolute(full_path, .{ .mode = .read_only }) catch {
            allocator.free(full_path);
            continue;
        };

        // If we can access it, assume it's executable (simplified check)
        // In a real implementation, we'd check the executable bit
        return full_path;
    }
    return null;
}

pub fn main() !void {
    var stdout_buffer: [512]u8 = @splat(0);
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    var stdin_buffer: [512]u8 = @splat(0);
    var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
    const stdin = &stdin_reader.interface;

    while (true) {
        try stdout.print("$ ", .{});
        try stdout.flush();
        const input = try stdin.takeDelimiterExclusive('\n');
        stdin.toss(1);
        var arg_iter = std.mem.splitSequence(u8, input, " ");

        const command_str = arg_iter.next().?;
        const command_opt = std.meta.stringToEnum(Builtin, command_str);

        if (command_opt) |command| {
            switch (command) {
                .exit => {
                    const code = if (arg_iter.next()) |code_str|
                        try std.fmt.parseInt(u8, code_str, 10)
                    else
                        0;

                    std.process.exit(code);
                },
                .echo => {
                    while (true) {
                        const word = arg_iter.next();
                        if (word) |w| {
                            try stdout.print("{s} ", .{w});
                        } else {
                            break;
                        }
                    }
                    try stdout.print("\n", .{});
                },
                .type => {
                    const type_str = arg_iter.next().?;
                    const type_opt = std.meta.stringToEnum(Builtin, type_str);
                    if (type_opt) |_| {
                        try stdout.print("{s} is a shell builtin\n", .{type_str});
                    } else {
                        const allocator = std.heap.page_allocator;
                        if (try whichCommand(allocator, type_str)) |path| {
                            defer allocator.free(path);
                            try stdout.print("{s} is {s}\n", .{ type_str, path });
                        } else {
                            try stdout.print("{s}: not found\n", .{type_str});
                        }
                    }
                },
                .hello => {
                    try stdout.print("Hello, World!\n", .{});
                    try stdout.flush();
                },
            }
            continue;
        } else {
            try stdout.print("{s}: command not found\n", .{input});
        }

        try stdout.flush();
    }
}
