const std = @import("std");
const builtin = @import("builtin");
const clap = @import("clap");

const file_list = @import("./file_list.zig");
const pcm = @import("./pcm.zig");

test {
    std.testing.refAllDecls(@This());
}

const version = "0.1.0";
const help_header_fmt =
    \\wavels {s}
    \\
    \\USAGE:
    \\    wavels [flags] [wav_or_aiff_file|directory ...]
    \\
    \\FLAGS:
    \\    -c, --count           show counts, grouped by sample rate, bit depth, and channel count
    \\    -r, --recurse         recursively list subdirectories
    \\    -d, --debug           print debug info to stderr
    \\    -h, --help            show this help info
    \\    -v, --version         show version info
    \\
;
// some duplication here, but it was the only way to get the help output
// to be printed without the "<str>..." part
const params = clap.parseParamsComptime(
    \\-c, --count
    \\-r, --recurse
    \\-d, --debug
    \\-h, --help
    \\-v, --version
    \\<str>...
);

const extensions = [_][]const u8{
    "aif",
    "AIF",
    "aiff",
    "AIFF",
    "wav",
    "WAV",
    "wave",
    "WAVE",
};

const unreadable_or_unsupported = "unreadable or unsupported";

pub fn main() !void {
    const stdout_file = std.io.getStdOut().writer();
    var stdout_bw = std.io.bufferedWriter(stdout_file);
    const stdout = stdout_bw.writer();
    const stderr = std.io.getStdErr().writer();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const res = clap.parse(clap.Help, &params, clap.parsers.default, .{ .allocator = allocator }) catch |err|
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
        try stdout_bw.flush();
        std.process.exit(0);
    }
    if (res.args.help != 0) {
        _ = try stdout.print(help_header_fmt, .{version});
        try stdout_bw.flush();
        std.process.exit(0);
    }

    const err_writer = if (res.args.debug != 0) stderr.any() else std.io.null_writer.any();

    const recurse = res.args.recurse != 0;

    const files = switch (res.positionals.len) {
        0 => try file_list.build(
            allocator,
            ".",
            &extensions,
            recurse,
        ),
        else => try file_list.buildFromArgs(
            allocator,
            res.positionals,
            &extensions,
            recurse,
            err_writer, // TODO: this should probably NOT respect the debug flag
        ),
    };

    const any_errors = switch (res.args.count) {
        0 => try showList(allocator, files, stdout, err_writer),
        else => try showCounts(allocator, files, stdout, err_writer),
    };

    try stdout_bw.flush();

    if (any_errors) std.process.exit(1);
}

fn showList(
    allocator: std.mem.Allocator,
    files: file_list.FileList,
    stdout: anytype,
    err_writer: std.io.AnyWriter,
) !bool {
    var any_errors = false;
    for (files.paths) |file| {
        var err_info: [pcm.max_err_info_size]u8 = undefined;
        const info = pcm.readInfo(file, &err_info) catch |err| {
            any_errors = true;
            _ = try err_writer.print("{s} {}: {s}\n", .{ file, err, err_info });
            _ = try stdout.print("{s}{s}{s}\n", .{
                file,
                try padding(allocator, file, files.max_length),
                unreadable_or_unsupported,
            });
            continue;
        };

        _ = try stdout.print("{s}{s}{d} khz {d} bit {s}\n", .{
            file,
            try padding(allocator, file, files.max_length),
            info.sample_rate,
            info.bit_depth,
            try channelCount(info.channels),
        });
    }
    return any_errors;
}

fn padding(allocator: std.mem.Allocator, s: []const u8, total_length: u16) ![]const u8 {
    const ret = try allocator.alloc(u8, total_length - s.len + 1);
    @memset(ret, 32);
    return ret;
}

fn showCounts(
    allocator: std.mem.Allocator,
    files: file_list.FileList,
    stdout: anytype,
    err_writer: std.io.AnyWriter,
) !bool {
    var counters = std.ArrayList(Counter).init(allocator);
    var err_counter = Counter.initNull();

    for (files.paths) |file| {
        var err_info: [pcm.max_err_info_size]u8 = undefined;
        const info = pcm.readInfo(file, &err_info) catch |err| {
            err_counter.count += 1;
            _ = try err_writer.print("{s} {}: {s}\n", .{ file, err, err_info });
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
            const counter = Counter.init(info);
            try counters.append(counter);
        }
    }

    for (counters.items) |counter| {
        _ = try stdout.print("{d}\t{d} khz {d} bit {s}\n", .{
            counter.count,
            counter.sample_rate,
            counter.bit_depth,
            try channelCount(counter.channels),
        });
    }
    if (err_counter.count > 0) {
        _ = try stdout.print("{d}\t{s}\n", .{
            err_counter.count,
            unreadable_or_unsupported,
        });
        return true;
    }
    return false;
}

const Counter = struct {
    count: u32,
    sample_rate: u32,
    bit_depth: u16,
    channels: u16,

    fn init(info: pcm.PCMInfo) @This() {
        return .{
            .count = 1,
            .sample_rate = info.sample_rate,
            .bit_depth = info.bit_depth,
            .channels = info.channels,
        };
    }

    fn initNull() @This() {
        return .{
            .count = 0,
            .sample_rate = 0,
            .bit_depth = 0,
            .channels = 0,
        };
    }

    fn matches(self: @This(), other: pcm.PCMInfo) bool {
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
