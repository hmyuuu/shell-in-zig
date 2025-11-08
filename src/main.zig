const std = @import("std");

const Builtin = enum {
    exit,
    echo,
    type,
    pwd,
    cd,
    hello,
};

/// Search PATH for an executable file
/// Returns the full path if found, null otherwise
fn findExecInPath(alloc: std.mem.Allocator, cmd_name: []const u8) !?[]u8 {
    const path_env = std.process.getEnvVarOwned(alloc, "PATH") catch |err| {
        if (err == error.EnvironmentVariableNotFound) return null;
        return err;
    };
    defer alloc.free(path_env);

    var path_iter = std.mem.splitSequence(u8, path_env, ":");
    while (path_iter.next()) |dir| {
        const full_path = try std.fs.path.join(alloc, &[_][]const u8{ dir, cmd_name });

        if (isExec(full_path)) {
            return full_path;
        } else {
            alloc.free(full_path);
        }
    }
    return null;
}

/// Check if a file exists and has execute permissions
fn isExec(file_path: []const u8) bool {
    const file = std.fs.openFileAbsolute(file_path, .{}) catch return false;
    defer file.close();

    const stat = file.stat() catch return false;

    // Check if any execute bit is set (user, group, or other)
    const exec_mask = 0o111;
    return (stat.mode & exec_mask) != 0;
}

/// Execute an external program with arguments
fn execExtProg(
    alloc: std.mem.Allocator,
    exec_path: []const u8,
    cmd_name: []const u8,
    arg_iter: anytype,
) !void {
    // Collect arguments
    var args_buf: [64][]const u8 = undefined;
    args_buf[0] = cmd_name; // argv[0] is the command name
    var arg_count: usize = 1;

    while (arg_iter.next()) |arg| {
        args_buf[arg_count] = arg;
        arg_count += 1;
    }

    // Convert to null-terminated strings for execve
    var argv_ptrs = try alloc.alloc(?[*:0]const u8, arg_count + 1);
    defer alloc.free(argv_ptrs);

    for (args_buf[0..arg_count], 0..) |arg, i| {
        argv_ptrs[i] = try alloc.dupeZ(u8, arg);
    }
    argv_ptrs[arg_count] = null;

    const exec_path_z = try alloc.dupeZ(u8, exec_path);
    defer alloc.free(exec_path_z);

    // Fork and execute
    const pid = try std.posix.fork();
    if (pid == 0) {
        // Child process: replace with the target program
        std.posix.execveZ(exec_path_z, argv_ptrs[0..arg_count :null], @ptrCast(std.os.environ.ptr)) catch {
            std.process.exit(1);
        };
    } else {
        // Parent process: wait for child to complete
        _ = std.posix.waitpid(pid, 0);
    }

    // Clean up allocated strings
    for (0..arg_count) |i| {
        if (argv_ptrs[i]) |ptr| {
            alloc.free(std.mem.span(ptr));
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
fn handleType(stdout: anytype, alloc: std.mem.Allocator, arg_iter: anytype) !void {
    const target = arg_iter.next().?;

    // Check if it's a builtin
    if (std.meta.stringToEnum(Builtin, target)) |_| {
        try stdout.print("{s} is a shell builtin\n", .{target});
        return;
    }

    // Search in PATH
    if (try findExecInPath(alloc, target)) |path| {
        defer alloc.free(path);
        try stdout.print("{s} is {s}\n", .{ target, path });
    } else {
        try stdout.print("{s}: not found\n", .{target});
    }
}

/// Handle the 'pwd' builtin command
fn handlePwd(stdout: anytype, alloc: std.mem.Allocator) !void {
    const cwd = try std.process.getCwdAlloc(alloc);
    defer alloc.free(cwd);
    try stdout.print("{s}\n", .{cwd});
}

/// Handle the 'cd' builtin command
fn handleCd(stdout: anytype, alloc: std.mem.Allocator, arg_iter: anytype) !void {
    const target = arg_iter.next() orelse {
        // No argument provided, go to home directory
        if (std.process.getEnvVarOwned(alloc, "HOME")) |home| {
            defer alloc.free(home);
            changeDirWithError(stdout, home);
        } else |_| {
            try stdout.print("cd: HOME not set\n", .{});
        }
        return;
    };

    // Handle ~ expansion
    if (std.mem.startsWith(u8, target, "~")) {
        if (std.process.getEnvVarOwned(alloc, "HOME")) |home| {
            defer alloc.free(home);

            if (target.len == 1) {
                // Just "~"
                changeDirWithError(stdout, home);
            } else {
                // "~/path"
                const rest = target[1..];
                const full_path = try std.fs.path.join(alloc, &[_][]const u8{ home, rest });
                defer alloc.free(full_path);
                changeDirWithError(stdout, full_path);
            }
        } else |_| {
            try stdout.print("cd: HOME not set\n", .{});
        }
        return;
    }

    // Handle regular paths (absolute or relative)
    changeDirWithError(stdout, target);
}

/// Change directory and print error if it fails
fn changeDirWithError(stdout: anytype, path: []const u8) void {
    const path_z = std.heap.page_allocator.dupeZ(u8, path) catch {
        stdout.print("cd: {s}: Memory error\n", .{path}) catch {};
        return;
    };
    defer std.heap.page_allocator.free(path_z);

    std.posix.chdir(path_z) catch {
        stdout.print("cd: {s}: No such file or directory\n", .{path}) catch {};
    };
}

pub fn main() !void {
    // Setup buffered I/O
    var stdout_buf: [512]u8 = @splat(0);
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buf);
    const stdout = &stdout_writer.interface;

    var stdin_buf: [512]u8 = @splat(0);
    var stdin_reader = std.fs.File.stdin().readerStreaming(&stdin_buf);
    const stdin = &stdin_reader.interface;

    const alloc = std.heap.page_allocator;

    // Main REPL loop
    while (true) {
        try stdout.print("$ ", .{});
        try stdout.flush();

        const input = try stdin.takeDelimiterExclusive('\n');
        stdin.toss(1);

        var arg_iter = std.mem.splitSequence(u8, input, " ");
        const cmd_name = arg_iter.next().?;

        // Try to execute as builtin
        if (std.meta.stringToEnum(Builtin, cmd_name)) |builtin| {
            switch (builtin) {
                .exit => try handleExit(&arg_iter),
                .echo => try handleEcho(stdout, &arg_iter),
                .type => try handleType(stdout, alloc, &arg_iter),
                .pwd => try handlePwd(stdout, alloc),
                .cd => try handleCd(stdout, alloc, &arg_iter),
                .hello => {
                    try stdout.print("Hello, World!\n", .{});
                    try stdout.flush();
                },
            }
            continue;
        }

        // Try to execute as external program
        if (try findExecInPath(alloc, cmd_name)) |exec_path| {
            defer alloc.free(exec_path);
            try execExtProg(alloc, exec_path, cmd_name, &arg_iter);
        } else {
            try stdout.print("{s}: command not found\n", .{cmd_name});
        }

        try stdout.flush();
    }
}
