const std = @import("std");

pub const WavInfo = struct {
    sample_rate: u32,
    bit_depth: u16,
    channels: u16,
};

const WavHeaderError = error{
    ShortRead,
    InvalidRIFFChunkID,
    InvalidRIFFChunkFormat,
    InvalidFmtChunkID,
};

const ro_flag = std.fs.File.OpenFlags{ .mode = std.fs.File.OpenMode.read_only };

const riff_chunk_size: usize = 12;
const chunk_start_size: usize = 8;
const fmt_chunk_size: usize = 16;

// WARNING: this may well be broken on big endian systems
pub fn readInfo(path: []const u8) !WavInfo {
    const f = try std.fs.cwd().openFile(path, ro_flag);
    defer f.close();

    try validateRIFFChunk(f);

    var chunk_start: [chunk_start_size]u8 = undefined;

    // there must be a nicer way to do this, but let's make this more complete
    // first and then do some profiling
    while (true) {
        var read = try f.readAll(&chunk_start);
        if (read < chunk_start_size) {
            return WavHeaderError.ShortRead;
        }

        if (std.mem.eql(u8, chunk_start[0..4], "fmt ")) {
            return readFmtChunk(f);
        } else if (std.mem.eql(u8, chunk_start[0..4], "JUNK")) {
            try f.seekBy(@as(i64, std.mem.bytesToValue(u32, chunk_start[4..8])));
        } else {
            return WavHeaderError.InvalidFmtChunkID;
        }
    }
}

// this function assumes that f has not yet been read, and therefore the offset
// is at the start of the file
// TODO: optionally print debug output when we see invalid data
fn validateRIFFChunk(f: std.fs.File) !void {
    var buf: [riff_chunk_size]u8 = undefined;
    const read = try f.readAll(&buf);
    if (read < riff_chunk_size) {
        return WavHeaderError.ShortRead;
    }
    if (!std.mem.eql(u8, buf[0..4], "RIFF")) {
        return WavHeaderError.InvalidRIFFChunkID;
    }
    if (!std.mem.eql(u8, buf[8..12], "WAVE")) {
        return WavHeaderError.InvalidRIFFChunkFormat;
    }
}

// this function assumes that f is already at the correct offset for the start
// of the fmt chunk data
fn readFmtChunk(f: std.fs.File) !WavInfo {
    var buf: [fmt_chunk_size]u8 = undefined;
    const read = try f.readAll(&buf);
    if (read < fmt_chunk_size) {
        return WavHeaderError.ShortRead;
    }
    return .{
        .channels = std.mem.bytesToValue(u16, buf[2..4]),
        .sample_rate = std.mem.bytesToValue(u32, buf[4..8]),
        .bit_depth = std.mem.bytesToValue(u16, buf[14..16]),
    };
}
