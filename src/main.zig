const std = @import("std");
const Command = enum {
    exit,
    echo,
    hello,
};

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
        const command_opt = std.meta.stringToEnum(Command, command_str);

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
