const std = @import("std");

pub const WavInfo = struct {
    sample_rate: u32,
    bit_depth: u16,
    channels: u16,
};

const WavHeaderError = error{
    ShortRead,
    InvalidChunkID,
    InvalidFormat,
    InvalidSubchunk1Start,
};

const hdr_size: usize = 36;
const ro_flag = std.fs.File.OpenFlags{ .mode = std.fs.File.OpenMode.read_only };

pub fn readInfo(path: []const u8) !WavInfo {
    const f = try std.fs.cwd().openFile(path, ro_flag);
    defer f.close();

    var buf: [hdr_size]u8 = undefined;
    const read = try f.readAll(&buf);
    if (read < hdr_size) {
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

    return .{
        .channels = std.mem.bytesToValue(u16, buf[22..24]),
        .sample_rate = std.mem.bytesToValue(u32, buf[24..28]),
        .bit_depth = std.mem.bytesToValue(u16, buf[34..36]),
    };
}
