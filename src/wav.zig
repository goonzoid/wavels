const std = @import("std");

pub const WavInfo = struct {
    sample_rate: u32,
    bit_depth: u16,
    channels: u16,
};

pub const max_err_info_size = 4;
const WavHeaderError = error{
    ShortRead,
    InvalidRIFFChunkID,
    InvalidRIFFChunkFormat,
    InvalidChunkID,
};

const ChunkID = enum(u32) {
    // these are reversed, because endianness
    fmt = 0x20746d66, // " tmf"
    bext = 0x74786562, // "txeb"
    id3 = 0x20336469, // " 3di"
    fake = 0x656b6146, // "ekaF"
    junk = 0x4b4e554a, // "knuj"
    unknown = 0x0,
};

const ChunkInfo = packed struct(u64) {
    id_int: u32,
    size: u32,

    fn id(self: @This()) ChunkID {
        return std.meta.intToEnum(ChunkID, self.id_int) catch ChunkID.unknown;
    }
};

// use max_err_info_size to ensure err_info will always have capacity for any error info
// WARNING: this is likely broken on big endian systems
pub fn readFile(path: []const u8, err_info: ?[]u8) !WavInfo {
    const ro_flag = comptime std.fs.File.OpenFlags{ .mode = std.fs.File.OpenMode.read_only };
    const f = try std.fs.cwd().openFile(path, ro_flag);
    defer f.close();

    return readInfo(f.reader(), err_info);
}

pub fn readInfo(reader: anytype, err_info: ?[]u8) !WavInfo {
    // void the err_info so we don't report nonsense if we have an unanticipated error
    if (err_info) |ei| {
        @memcpy(ei, "void");
    }
    // populate ei with a dummy buffer if no err_info was provided
    const ei: []u8 = err_info orelse @constCast(&std.mem.zeroes([max_err_info_size]u8));

    var br = std.io.bufferedReader(reader);
    const r = br.reader();

    // the RIFF chunk is a special case since the size is
    // fixed, and not included in the chunk itself
    try validateRIFFChunk(r, ei);

    while (true) {
        const chunk_info = try nextChunkInfo(r);
        switch (chunk_info.id()) {
            ChunkID.fmt => return readFmtChunk(r),
            ChunkID.bext,
            ChunkID.id3,
            ChunkID.fake,
            ChunkID.junk,
            => try evenSeek(r, chunk_info.size),
            ChunkID.unknown => {
                @memcpy(ei[0..4], &std.mem.toBytes(chunk_info.id_int));
                return WavHeaderError.InvalidChunkID;
            },
        }
    }
}

fn evenSeek(r: anytype, offset: u32) !void {
    const o: u64 = if (offset & 1 == 1) offset + 1 else offset;
    try r.skipBytes(o, .{ .buf_size = 512 }); // TODO: what is this options struct doing?
}

// NOTE: each of these functions assumes that the file offset is in the correct
// place (e.g. 0 for the RIFF chunk, or at the start of a new chunk for nextChunkInfo)

fn validateRIFFChunk(r: anytype, err_info: []u8) !void {
    const riff_chunk_size: usize = comptime 12;
    var buf: [riff_chunk_size]u8 = undefined;
    const read = try r.read(&buf);
    if (read < riff_chunk_size) {
        return WavHeaderError.ShortRead;
    }
    if (!std.mem.eql(u8, buf[0..4], "RIFF")) {
        @memcpy(err_info[0..4], buf[0..4]);
        return WavHeaderError.InvalidRIFFChunkID;
    }
    if (!std.mem.eql(u8, buf[8..12], "WAVE")) {
        @memcpy(err_info[0..4], buf[8..12]);
        return WavHeaderError.InvalidRIFFChunkFormat;
    }
}

fn nextChunkInfo(r: anytype) !ChunkInfo {
    const size = @sizeOf(ChunkInfo);
    var buf: [size]u8 = undefined;
    var read = try r.read(&buf);
    if (read < size) {
        return WavHeaderError.ShortRead;
    }
    return @bitCast(buf);
}

fn readFmtChunk(r: anytype) !WavInfo {
    // fmt chunks can be > 16, but this is enough to get the fields we need
    const min_chunk_size: usize = comptime 16;
    var buf: [min_chunk_size]u8 = undefined;
    const read = try r.read(&buf);
    if (read < min_chunk_size) {
        return WavHeaderError.ShortRead;
    }
    return .{
        .channels = std.mem.bytesToValue(u16, buf[2..4]),
        .sample_rate = std.mem.bytesToValue(u32, buf[4..8]),
        .bit_depth = std.mem.bytesToValue(u16, buf[14..16]),
    };
}
