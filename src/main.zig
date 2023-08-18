const std = @import("std");
const builtin = @import("builtin");

fn writeUsage(f: *const std.fs.File) !void {
    _ = try f.writer().print(
        "TODO: print usage...\ncompiled with zig {s}\n",
        .{builtin.zig_version_string},
    );
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    const stdout = std.io.getStdOut();

    if (args.len <= 1 or
        std.mem.eql(u8, args[1], "-h") or
        std.mem.eql(u8, args[1], "--help"))
    {
        try writeUsage(&stdout);
        std.process.exit(0);
    }

    const out_writer = stdout.writer();
    const err_writer = std.io.getStdErr().writer();
    for (args[1..]) |arg| {
        if (readWavInfo(arg)) |info| {
            _ = try out_writer.print("{s}: {}\n", .{ arg, info });
        } else |err| {
            _ = try err_writer.print("{s}: {}\n", .{ arg, err });
        }
    }
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
    ) std.os.WriteError!void {
        return writer.print(
            "{d} channels {d} khz {d} bit",
            .{ value.channels, value.sample_rate, value.bit_depth },
        );
    }
};

const WavHeaderError = error{
    ShortRead,
    InvalidChunkID,
    InvalidFormat,
    InvalidSubchunk1Start,
};

const headerBufSize: usize = 36;

fn readWavInfo(path: []const u8) !WavInfo {
    const f = try std.fs.cwd().openFile(path, ro_flag);
    var buf: [headerBufSize]u8 = undefined;

    const read = try f.readAll(&buf);
    if (read < headerBufSize) {
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
