const std = @import("std");
const builtin = @import("builtin");
const clap = @import("clap");

const wav = @import("./wav.zig");

const version = "0.1.0";
const help_header_fmt =
    \\wavels {s}
    \\
    \\USAGE:
    \\    wavels [flags] [wav_file ...]
    \\
    \\FLAGS:
    \\    -c, --count           show counts, grouped by sample rate, bit depth, and channel count
    \\    -h, --help            show this help info
    \\    -v, --version         show version info
    \\
;
// some duplication here, but it was the only way to get the help output
// to be printed without the "<str>..." part
const params = clap.parseParamsComptime(
    \\-c, --count
    \\-h, --help
    \\-v, --version
    \\<str>...
);

pub fn main() !void {
    const stdout = std.io.getStdOut();
    const stderr = std.io.getStdErr();

    const res = clap.parse(clap.Help, &params, clap.parsers.default, .{}) catch |err|
        switch (err) {
        error.InvalidArgument => {
            _ = try stderr.writer().print(help_header_fmt, .{version});
            std.process.exit(1);
        },
        else => return err,
    };
    defer res.deinit();

    if (res.args.version != 0) {
        _ = try stdout.writer().print(
            "wavels {s}\nbuilt with zig {s}",
            .{ version, builtin.zig_version_string },
        );
        std.process.exit(0);
    }
    if (res.args.help != 0) {
        _ = try stdout.writer().print(help_header_fmt, .{version});
        std.process.exit(0);
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const files: []const []const u8 = switch (res.positionals.len) {
        0 => try getFiles(allocator),
        else => res.positionals,
    };

    var any_errors = if (res.args.count != 0)
        try showCounts(allocator, files, stdout, stderr)
    else
        try showList(files, stdout, stderr);

    if (any_errors) std.process.exit(1);
}

fn getFiles(allocator: std.mem.Allocator) ![]const []const u8 {
    var dir = try std.fs.cwd().openIterableDir(".", .{});
    defer dir.close();
    var it = dir.iterate();

    var files = std.ArrayList([]const u8).init(allocator);
    while (try it.next()) |f| {
        if (hasWavExt(f.name)) {
            const n = try allocator.dupe(u8, f.name);
            try files.append(n);
        }
    }
    return files.items;
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
    files: []const []const u8,
    stdout: std.fs.File,
    stderr: std.fs.File,
) !bool {
    var any_errors = false;
    for (files) |file| {
        if (wav.readInfo(file)) |info| {
            _ = try stdout.writer().print(
                "{s}\t{d} khz {d} bit {s}\n",
                .{ file, info.sample_rate, info.bit_depth, try channelCount(info.channels) },
            );
        } else |err| {
            any_errors = true;
            _ = try stderr.writer().print("{s}: {}\n", .{ file, err });
        }
    }
    return any_errors;
}

fn showCounts(
    allocator: std.mem.Allocator,
    files: []const []const u8,
    stdout: std.fs.File,
    stderr: std.fs.File,
) !bool {
    var any_errors = false;
    var counters = std.ArrayList(*Counter).init(allocator);

    for (files) |file| {
        if (wav.readInfo(file)) |info| {
            var counted = false;
            for (counters.items) |counter| {
                if (counter.matches(info)) {
                    counter.count += 1;
                    counted = true;
                    break;
                }
            }
            if (!counted) {
                var counter = Counter.init(info);
                try counters.append(&counter);
            }
        } else |err| {
            any_errors = true;
            _ = try stderr.writer().print("{s}: {}\n", .{ file, err });
        }
    }

    for (counters.items) |counter| {
        _ = try stdout.writer().print(
            "{d}\t{d} khz {d} bit {s}\n",
            .{ counter.count, counter.sample_rate, counter.bit_depth, try channelCount(counter.channels) },
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
