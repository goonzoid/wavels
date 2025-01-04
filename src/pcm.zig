const std = @import("std");
const builtin = @import("builtin");

const native_endian = builtin.cpu.arch.endian();

pub const PCMInfo = struct {
    sample_rate: u32,
    bit_depth: u16,
    channels: u16,
};

pub const max_err_info_size = 4;
const PCMReadError = error{
    ShortRead,
    InvalidChunkID,
    InvalidFORMChunkFormat,
    InvalidRIFFChunkFormat,
};

const Format = enum {
    wav,
    aiff,
};

const ChunkID = enum(u32) {
    // these are reversed, because endianness
    fmt = 0x20746d66, // " tmf"
    bext = 0x74786562, // "txeb"
    id3 = 0x20336469, // " 3di"
    fake = 0x656b6146, // "ekaF"
    junk = 0x4b4e554a, // "knuj"
    COMM = 0x4D4D4F43, // "MMOC"
    COMT = 0x544D4F43, // "TMOC"
    INST = 0x54534E49, // "TSNI"
    MARK = 0x4B52414D, // "KRAM"
    unknown = 0x0,
};

// This used to be a packed u64 struct, which allowed us to use @bitCast
// when parsing chunk info. It may or may not have been faster, but was
// worse for debugging. Might be worth profiling at some point.
const ChunkInfo = struct {
    id_int: u32,
    size: u32,

    fn id(self: @This()) ChunkID {
        return std.meta.intToEnum(ChunkID, self.id_int) catch ChunkID.unknown;
    }
};

// use max_err_info_size to ensure err_info will always have capacity for any error info
// TODO: this is likely broken on big endian systems
pub fn readInfo(path: []const u8, err_info: ?[]u8) !PCMInfo {
    // void the err_info so we don't report nonsense if we have an unanticipated error
    if (err_info) |ei| {
        @memcpy(ei, "void");
    }
    // populate ei with a dummy buffer if no err_info was provided
    const ei: []u8 = err_info orelse @constCast(&std.mem.zeroes([max_err_info_size]u8));

    const ro_flag = comptime std.fs.File.OpenFlags{ .mode = std.fs.File.OpenMode.read_only };
    const f = try std.fs.cwd().openFile(path, ro_flag);
    defer f.close();

    switch (try getFormat(f, ei)) {
        Format.wav => return readWavHeader(f, ei),
        Format.aiff => return readAiffHeader(f, ei),
    }
}

// TODO: the calls to nextChunkInfo in readWavHeader and readAiffHeader may
// have the wrong reverse_size_field parameter on big endian systems... still
// getting my head around that so need to test it out!

fn readWavHeader(f: std.fs.File, err_info: []u8) !PCMInfo {
    while (true) {
        const chunk_info = try nextChunkInfo(f, false);
        switch (chunk_info.id()) {
            ChunkID.fmt => return readFmtChunk(f),
            ChunkID.bext,
            ChunkID.id3,
            ChunkID.fake,
            ChunkID.junk,
            => try evenSeek(f, chunk_info.size),
            ChunkID.COMM,
            ChunkID.COMT,
            ChunkID.INST,
            ChunkID.MARK,
            ChunkID.unknown,
            => {
                @memcpy(err_info[0..4], &std.mem.toBytes(chunk_info.id_int));
                return PCMReadError.InvalidChunkID;
            },
        }
    }
}

fn readAiffHeader(f: std.fs.File, err_info: []u8) !PCMInfo {
    while (true) {
        const chunk_info = try nextChunkInfo(f, true);
        switch (chunk_info.id()) {
            ChunkID.COMM => return readCOMMChunk(f),
            ChunkID.COMT,
            ChunkID.INST,
            ChunkID.MARK,
            => try evenSeek(f, chunk_info.size),
            ChunkID.fmt,
            ChunkID.bext,
            ChunkID.id3,
            ChunkID.fake,
            ChunkID.junk,
            ChunkID.unknown,
            => {
                @memcpy(err_info[0..4], &std.mem.toBytes(chunk_info.id_int));
                return PCMReadError.InvalidChunkID;
            },
        }
    }
}

fn evenSeek(f: std.fs.File, offset: u32) !void {
    const o: i64 = if (offset & 1 == 1) offset + 1 else offset;
    try f.seekBy(o);
}

// NOTE: each of these functions assumes that the file offset is in the correct
// place (e.g. 0 for the RIFF chunk, or at the start of a new chunk for nextChunkInfo)

fn getFormat(f: std.fs.File, err_info: []u8) !Format {
    const chunk_size: u32 = comptime 12;
    var buf: [chunk_size]u8 = undefined;
    const read = try f.readAll(&buf);
    if (read < chunk_size) {
        return PCMReadError.ShortRead;
    }

    // TODO: there's probably a more elegant way to write the rest of this function
    var format: Format = undefined;

    if (std.mem.eql(u8, buf[0..4], "RIFF")) {
        if (!std.mem.eql(u8, buf[8..12], "WAVE")) {
            @memcpy(err_info[0..4], buf[8..12]);
            return PCMReadError.InvalidRIFFChunkFormat;
        }
        format = Format.wav;
    } else if (std.mem.eql(u8, buf[0..4], "FORM")) {
        if (!std.mem.eql(u8, buf[8..12], "AIFF")) {
            @memcpy(err_info[0..4], buf[8..12]);
            return PCMReadError.InvalidFORMChunkFormat;
        }
        format = Format.aiff;
    } else {
        @memcpy(err_info[0..4], buf[0..4]);
        return PCMReadError.InvalidChunkID;
    }

    return format;
}

fn nextChunkInfo(f: std.fs.File, reverse_size_field: bool) !ChunkInfo {
    const size = @sizeOf(ChunkInfo);
    var buf: [size]u8 = undefined;
    const read = try f.readAll(&buf);
    if (read < size) {
        return PCMReadError.ShortRead;
    }
    if (reverse_size_field) std.mem.reverse(u8, buf[4..8]);
    return .{
        .id_int = std.mem.bytesToValue(u32, buf[0..4]),
        .size = std.mem.bytesToValue(u32, buf[4..8]),
    };
}

// TODO: the buffer sizes below should work in most cases, but may
// break for some data. We should respect the chunk's size field.

// TODO: confirm that readAll is only reading exactly what we need

fn readFmtChunk(f: std.fs.File) !PCMInfo {
    const min_chunk_size: usize = comptime 16;
    var buf: [min_chunk_size]u8 = undefined;
    const read = try f.readAll(&buf);
    if (read < min_chunk_size) {
        return PCMReadError.ShortRead;
    }
    return .{
        .channels = std.mem.bytesToValue(u16, buf[2..4]),
        .sample_rate = std.mem.bytesToValue(u32, buf[4..8]),
        .bit_depth = std.mem.bytesToValue(u16, buf[14..16]),
    };
}

fn readCOMMChunk(f: std.fs.File) !PCMInfo {
    const min_chunk_size: usize = comptime 18;
    var buf: [min_chunk_size]u8 = undefined;
    const read = try f.readAll(&buf);
    if (read < min_chunk_size) {
        return PCMReadError.ShortRead;
    }

    if (native_endian == std.builtin.Endian.little) {
        std.mem.reverse(u8, buf[0..2]);
        std.mem.reverse(u8, buf[6..8]);
        std.mem.reverse(u8, buf[8..18]);
    }

    return .{
        .channels = std.mem.bytesToValue(u16, buf[0..2]),
        .sample_rate = @intFromFloat(std.mem.bytesToValue(f80, buf[8..18])),
        .bit_depth = std.mem.bytesToValue(u16, buf[6..8]),
    };
}
