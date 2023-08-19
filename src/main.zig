const std = @import("std");
const builtin = @import("builtin");
const clap = @import("clap");

const version = "0.1.0";
const help_header_fmt =
    \\wavels {s}
    \\
    \\USAGE:
    \\    wavels [flags] [wav_file ...]
    \\
    \\FLAGS:
    \\    -h, --help             display this help info
    \\    -v, --version          display version info
    \\
;
// some duplication here, but it was the only way to get the help output
// to be printed without the "<str>..." part
const params = clap.parseParamsComptime(
    \\-h, --help
    \\-v, --version
    \\<str>...
);

pub fn main() !void {
    const out_writer = std.io.getStdOut().writer();
    const err_writer = std.io.getStdErr().writer();

    const res = clap.parse(clap.Help, &params, clap.parsers.default, .{}) catch |err|
        switch (err) {
        error.InvalidArgument => {
            _ = try err_writer.print(help_header_fmt, .{version});
            std.process.exit(1);
        },
        else => return err,
    };
    defer res.deinit();

    if (res.args.version != 0) {
        _ = try out_writer.print(
            "wavels {s}\nbuilt with zig {s}",
            .{ version, builtin.zig_version_string },
        );
        std.process.exit(0);
    }
    if (res.args.help != 0) {
        _ = try out_writer.print(help_header_fmt, .{version});
        std.process.exit(0);
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const files: []const []const u8 = switch (res.positionals.len) {
        0 => try getFileList(allocator),
        else => res.positionals,
    };

    var any_errors = false;
    for (files) |file| {
        if (readWavInfo(file)) |info| {
            _ = try out_writer.print("{s}: {}\n", .{ file, info });
        } else |err| {
            any_errors = true;
            _ = try err_writer.print("{s}: {}\n", .{ file, err });
        }
    }
    if (any_errors) std.process.exit(1);
}

fn getFileList(allocator: std.mem.Allocator) ![]const []const u8 {
    var dir = try std.fs.cwd().openIterableDir(".", .{});
    defer dir.close();

    var files = std.ArrayList([]const u8).init(allocator);
    var it = dir.iterate();
    while (try it.next()) |f| {
        const len = f.name.len;
        if (len >= 5 and std.mem.eql(u8, f.name[len - 4 .. len], ".wav")) {
            const n = try allocator.dupe(u8, f.name);
            try files.append(n);
        }
    }
    return files.items;
}

const ro_flag = std.fs.File.OpenFlags{ .mode = std.fs.File.OpenMode.read_only };

const WavInfo = struct {
    sample_rate: u32,
    bit_depth: u16,
    channels: u16,

    pub fn format(
        value: @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const channel_count = switch (value.channels) {
            1 => "mono",
            2 => "stereo",
            else => |count| blk: {
                // max wav channel count is 65535
                // "65535 channels" is 14 bytes
                var buf: [14]u8 = undefined;
                const result = try std.fmt.bufPrint(&buf, "{d} channels", .{count});
                break :blk result;
            },
        };
        return writer.print(
            "{s} {d} khz {d} bit",
            .{ channel_count, value.sample_rate, value.bit_depth },
        );
    }
};

const WavHeaderError = error{
    ShortRead,
    InvalidChunkID,
    InvalidFormat,
    InvalidSubchunk1Start,
};

const hdrSize: usize = 36;

fn readWavInfo(path: []const u8) !WavInfo {
    const f = try std.fs.cwd().openFile(path, ro_flag);
    defer f.close();

    var buf: [hdrSize]u8 = undefined;
    const read = try f.readAll(&buf);
    if (read < hdrSize) {
        return WavHeaderError.ShortRead;
    }

    if (!std.mem.eql(u8, buf[0..4], "RIFF")) {
        return WavHeaderError.InvalidChunkID;
    }
    if (!std.mem.eql(u8, buf[8..12], "WAVE")) {
        return WavHeaderError.InvalidFormat;
    }
    // Subchunk1ID ("fmt "), Subchunk1Size (16, 4 bytes), AudioFormat (1, 2 bytes)
    if (!std.mem.eql(u8, buf[12..22], "fmt \x10\x00\x00\x00\x01\x00")) {
        return WavHeaderError.InvalidSubchunk1Start;
    }

    return WavInfo{
        .channels = std.mem.bytesToValue(u16, buf[22..24]),
        .sample_rate = std.mem.bytesToValue(u32, buf[24..28]),
        .bit_depth = std.mem.bytesToValue(u16, buf[34..36]),
    };
}
