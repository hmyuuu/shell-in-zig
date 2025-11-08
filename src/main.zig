const std = @import("std");

const Builtin = enum {
    exit,
    echo,
    type,
    pwd,
    hello,
};

/// Search PATH for an executable file
/// Returns the full path if found, null otherwise
fn whichCommand(allocator: std.mem.Allocator, command_name: []const u8) !?[]u8 {
    const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch |err| {
        if (err == error.EnvironmentVariableNotFound) return null;
        return err;
    };
    defer allocator.free(path_env);

    var path_iter = std.mem.splitSequence(u8, path_env, ":");
    while (path_iter.next()) |directory| {
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ directory, command_name });

        if (isExecutable(full_path)) {
            return full_path;
        } else {
            allocator.free(full_path);
        }
    }
    return null;
}

/// Check if a file exists and has execute permissions
fn isExecutable(file_path: []const u8) bool {
    const file = std.fs.openFileAbsolute(file_path, .{}) catch return false;
    defer file.close();

    const stat = file.stat() catch return false;

    // Check if any execute bit is set (user, group, or other)
    const execute_mask = 0o111;
    return (stat.mode & execute_mask) != 0;
}

/// Execute an external program with arguments
fn executeExternalProgram(
    allocator: std.mem.Allocator,
    executable_path: []const u8,
    command_name: []const u8,
    arg_iter: anytype,
) !void {
    // Collect arguments
    var args_buffer: [64][]const u8 = undefined;
    args_buffer[0] = command_name; // argv[0] is the command name
    var arg_count: usize = 1;

    while (arg_iter.next()) |arg| {
        args_buffer[arg_count] = arg;
        arg_count += 1;
    }

    // Convert to null-terminated strings for execve
    var argv_ptrs = try allocator.alloc(?[*:0]const u8, arg_count + 1);
    defer allocator.free(argv_ptrs);

    for (args_buffer[0..arg_count], 0..) |arg, i| {
        argv_ptrs[i] = try allocator.dupeZ(u8, arg);
    }
    argv_ptrs[arg_count] = null;

    const exe_path_z = try allocator.dupeZ(u8, executable_path);
    defer allocator.free(exe_path_z);

    // Fork and execute
    const pid = try std.posix.fork();
    if (pid == 0) {
        // Child process: replace with the target program
        std.posix.execveZ(exe_path_z, argv_ptrs[0..arg_count :null], @ptrCast(std.os.environ.ptr)) catch {
            std.process.exit(1);
        };
    } else {
        // Parent process: wait for child to complete
        _ = std.posix.waitpid(pid, 0);
    }

    // Clean up allocated strings
    for (0..arg_count) |i| {
        if (argv_ptrs[i]) |ptr| {
            allocator.free(std.mem.span(ptr));
        }
    }
}

/// Handle the 'exit' builtin command
fn handleExit(arg_iter: anytype) !void {
    const exit_code = if (arg_iter.next()) |code_str|
        try std.fmt.parseInt(u8, code_str, 10)
    else
        0;
    std.process.exit(exit_code);
}

/// Handle the 'echo' builtin command
fn handleEcho(stdout: anytype, arg_iter: anytype) !void {
    while (arg_iter.next()) |word| {
        try stdout.print("{s} ", .{word});
    }
    try stdout.print("\n", .{});
}

/// Handle the 'type' builtin command
fn handleType(stdout: anytype, allocator: std.mem.Allocator, arg_iter: anytype) !void {
    const target = arg_iter.next().?;

    // Check if it's a builtin
    if (std.meta.stringToEnum(Builtin, target)) |_| {
        try stdout.print("{s} is a shell builtin\n", .{target});
        return;
    }

    // Search in PATH
    if (try whichCommand(allocator, target)) |path| {
        defer allocator.free(path);
        try stdout.print("{s} is {s}\n", .{ target, path });
    } else {
        try stdout.print("{s}: not found\n", .{target});
    }
}

/// Handle the 'pwd' builtin command
fn handlePwd(stdout: anytype, allocator: std.mem.Allocator) !void {
    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    try stdout.print("{s}\n", .{cwd});
}

pub fn main() !void {
    // Setup buffered I/O
    var stdout_buffer: [512]u8 = @splat(0);
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stdin_buffer: [512]u8 = @splat(0);
    var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
    const stdin = &stdin_reader.interface;

    const allocator = std.heap.page_allocator;

    // Main REPL loop
    while (true) {
        try stdout.print("$ ", .{});
        try stdout.flush();

        const input = try stdin.takeDelimiterExclusive('\n');
        stdin.toss(1);

        var arg_iter = std.mem.splitSequence(u8, input, " ");
        const command_name = arg_iter.next().?;

        // Try to execute as builtin
        if (std.meta.stringToEnum(Builtin, command_name)) |builtin| {
            switch (builtin) {
                .exit => try handleExit(&arg_iter),
                .echo => try handleEcho(stdout, &arg_iter),
                .type => try handleType(stdout, allocator, &arg_iter),
                .pwd => try handlePwd(stdout, allocator),
                .hello => {
                    try stdout.print("Hello, World!\n", .{});
                    try stdout.flush();
                },
            }
            continue;
        }

        // Try to execute as external program
        if (try whichCommand(allocator, command_name)) |executable_path| {
            defer allocator.free(executable_path);
            try executeExternalProgram(allocator, executable_path, command_name, &arg_iter);
        } else {
            try stdout.print("{s}: command not found\n", .{command_name});
        }

        try stdout.flush();
    }
}
