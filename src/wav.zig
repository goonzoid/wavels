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
    InvalidChunkID,
};

// WARNING: this is likely broken on big endian systems
pub fn readInfo(path: []const u8) !WavInfo {
    const f = try std.fs.cwd().openFile(path, ro_flag);
    defer f.close();

    // the RIFF chunk is a special case since the size is
    // fixed, and not included in the chunk itself
    try validateRIFFChunk(f);

    while (true) {
        const chunk_info = try nextChunkInfo(f);
        switch (chunk_info.id) {
            fmt => return readFmtChunk(f),
            junk => try f.seekBy(@as(i64, chunk_info.size)),
            else => return WavHeaderError.InvalidChunkID,
        }
    }
}

const ro_flag = std.fs.File.OpenFlags{ .mode = std.fs.File.OpenMode.read_only };

const riff_chunk_size: usize = 12;
const fmt_chunk_size: usize = 16;

const ChunkInfo = packed struct {
    id: u32,
    size: u32,
};

// TODO: can these be an enum?
const fmt = 0x20746d66;
const junk = 0x4b4e554a;

// NOTE: each of these functions assumes that the file offset is in the correct
// place (e.g. 0 for the RIFF chunk, or at the start of a new chunk for nextChunkInfo)

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

fn nextChunkInfo(f: std.fs.File) !ChunkInfo {
    const size = @sizeOf(ChunkInfo);
    var buf: [size]u8 = undefined;
    var read = try f.readAll(&buf);
    if (read < size) {
        return WavHeaderError.ShortRead;
    }
    return @bitCast(buf);
}

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
