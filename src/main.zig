const std = @import("std");
const builtin = @import("builtin");
const clap = @import("clap");
const wav = @import("./wav.zig");

const version = "0.1.0";
const help_header_fmt =
    \\wavels {s}
    \\
    \\USAGE:
    \\    wavels [flags] [wav_file|directory ...]
    \\
    \\FLAGS:
    \\    -c, --count           show counts, grouped by sample rate, bit depth, and channel count
    \\    -r, --recurse         recursively list subdirectories
    \\    -h, --help            show this help info
    \\    -v, --version         show version info
    \\
;
// some duplication here, but it was the only way to get the help output
// to be printed without the "<str>..." part
const params = clap.parseParamsComptime(
    \\-c, --count
    \\-r, --recurse
    \\-h, --help
    \\-v, --version
    \\<str>...
);

pub fn main() !void {
    const stdout_file = std.io.getStdOut().writer();
    var stdout_bw = std.io.bufferedWriter(stdout_file);
    const stdout = stdout_bw.writer();
    const stderr = std.io.getStdErr().writer();

    const res = clap.parse(clap.Help, &params, clap.parsers.default, .{}) catch |err|
        switch (err) {
        error.InvalidArgument => {
            _ = try stderr.print(help_header_fmt, .{version});
            std.process.exit(1);
        },
        else => return err,
    };
    defer res.deinit();

    if (res.args.version != 0) {
        _ = try stdout.print(
            "wavels {s}\nbuilt with zig {s}",
            .{ version, builtin.zig_version_string },
        );
        std.process.exit(0);
    }
    if (res.args.help != 0) {
        _ = try stdout.print(help_header_fmt, .{version});
        std.process.exit(0);
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const recurse = res.args.recurse != 0;
    const files = switch (res.positionals.len) {
        0 => try getWavFiles(allocator, ".", recurse),
        else => try getWavFilesFromArgs(allocator, res.positionals, stderr, recurse),
    };
    const any_errors = switch (res.args.count) {
        0 => try showList(allocator, files, stdout, stderr),
        else => try showCounts(allocator, files, stdout, stderr),
    };

    try stdout_bw.flush();

    if (any_errors) std.process.exit(1);
}

const FileList = struct {
    paths: []const []const u8,
    max_length: u16,
};

fn getWavFilesFromArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stderr: anytype,
    recurse: bool,
) !FileList {
    var files = std.ArrayList([]const u8).init(allocator);
    var max_length: u16 = 0;
    for (args) |path| {
        if (hasWavExt(path)) {
            max_length = @max(max_length, @as(u16, @intCast(path.len)));
            try files.append(path);
        } else if (try isDir(path)) {
            const more_files = try getWavFiles(allocator, path, recurse);
            max_length = @max(max_length, @as(u16, @intCast(more_files.max_length)));
            try files.appendSlice(more_files.paths);
        } else {
            try stderr.print("{s} - unsupported file type", .{path});
        }
    }
    return .{ .paths = files.items, .max_length = max_length };
}

fn getWavFiles(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    recurse: bool,
) !FileList {
    var dir = try std.fs.cwd().openIterableDir(dir_path, .{});
    defer dir.close();

    var files = std.ArrayList([]const u8).init(allocator);
    var max_length: u16 = 0;

    if (recurse) {
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next()) |we| {
            if (hasWavExt(we.basename)) {
                const path = try dotlessPath(allocator, dir_path, we.path);
                max_length = @max(max_length, @as(u16, @intCast(path.len)));
                try files.append(path);
            }
        }
    } else {
        var it = dir.iterate();
        while (try it.next()) |f| {
            if (hasWavExt(f.name)) {
                const path = try dotlessPath(allocator, dir_path, f.name);
                max_length = @max(max_length, @as(u16, @intCast(path.len)));
                try files.append(path);
            }
        }
    }

    return .{ .paths = files.items, .max_length = max_length };
}

fn dotlessPath(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    filename: []const u8,
) ![]const u8 {
    if (std.mem.eql(u8, dir_path, ".")) {
        return try allocator.dupe(u8, filename);
    }
    return try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ dir_path, filename },
    );
}

fn isDir(path: []const u8) !bool {
    var dir = try std.fs.cwd().openDir(path, .{});
    defer dir.close();
    const stat = try dir.stat();
    return stat.kind == std.fs.File.Kind.directory;
}

const wavExtensions = [_][]const u8{ "wav", "WAV", "wave", "WAVE" };

fn hasWavExt(name: []const u8) bool {
    if (std.mem.lastIndexOf(u8, name, ".")) |i| {
        const ext = name[i + 1 .. name.len];
        for (wavExtensions) |w| {
            if (std.mem.eql(u8, ext, w)) return true;
        }
    }
    return false;
}

fn showList(
    allocator: std.mem.Allocator,
    files: FileList,
    stdout: anytype,
    stderr: anytype,
) !bool {
    var any_errors = false;
    for (files.paths) |file| {
        var err_info: [wav.max_err_info_size]u8 = undefined;
        const info = wav.readInfo(file, &err_info) catch |err| {
            any_errors = true;
            _ = try stderr.print("{s} {}: {s}\n", .{ file, err, err_info });
            continue;
        };

        _ = try stdout.print(
            "{s}{s} {d} khz {d} bit {s}\n",
            .{
                file,
                try padding(allocator, file, files.max_length),
                info.sample_rate,
                info.bit_depth,
                try channelCount(info.channels),
            },
        );
    }
    return any_errors;
}

fn padding(allocator: std.mem.Allocator, s: []const u8, total_length: u16) ![]const u8 {
    const ret = try allocator.alloc(u8, total_length - s.len);
    @memset(ret, 32);
    return ret;
}

fn showCounts(
    allocator: std.mem.Allocator,
    files: FileList,
    stdout: anytype,
    stderr: anytype,
) !bool {
    var any_errors = false;
    var counters = std.ArrayList(Counter).init(allocator);

    for (files.paths) |file| {
        var err_info: [wav.max_err_info_size]u8 = undefined;
        const info = wav.readInfo(file, &err_info) catch |err| {
            any_errors = true;
            _ = try stderr.print("{s} {}: {s}\n", .{ file, err, err_info });
            continue;
        };

        var counted = false;
        for (counters.items) |*counter| {
            if (counter.matches(info)) {
                counter.count += 1;
                counted = true;
                break;
            }
        }
        if (!counted) {
            var counter = Counter.init(info);
            try counters.append(counter);
        }
    }

    for (counters.items) |counter| {
        _ = try stdout.print(
            "{d}\t{d} khz {d} bit {s}\n",
            .{
                counter.count,
                counter.sample_rate,
                counter.bit_depth,
                try channelCount(counter.channels),
            },
        );
    }
    return any_errors;
}

const Counter = struct {
    count: u32,
    sample_rate: u32,
    bit_depth: u16,
    channels: u16,

    fn init(info: wav.WavInfo) @This() {
        return .{
            .count = 1,
            .sample_rate = info.sample_rate,
            .bit_depth = info.bit_depth,
            .channels = info.channels,
        };
    }

    fn matches(self: @This(), other: wav.WavInfo) bool {
        return self.sample_rate == other.sample_rate and
            self.bit_depth == other.bit_depth and
            self.channels == other.channels;
    }
};

fn channelCount(count: u16) ![]const u8 {
    return switch (count) {
        1 => "mono",
        2 => "stereo",
        else => |c| blk: {
            // max wav channel count is 65535
            // "65535 channels" is 14 bytes
            var buf: [14]u8 = undefined;
            const result = try std.fmt.bufPrint(&buf, "{d} channels", .{c});
            break :blk result;
        },
    };
}
