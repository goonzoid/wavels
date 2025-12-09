const std = @import("std");

pub const FileList = struct {
    paths: []const []const u8,
    max_length: u16,
};

pub fn build(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    extensions: []const []const u8,
    recurse: bool,
) !FileList {
    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();

    var files = std.ArrayList([]const u8).empty;
    var max_length: u16 = 0;

    if (recurse) {
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next()) |we| {
            if (extensionMatches(we.basename, extensions)) {
                const path = try dotlessPath(allocator, dir_path, we.path);
                try files.append(allocator, path);
                max_length = @max(max_length, @as(u16, @intCast(path.len)));
            }
        }
    } else {
        var it = dir.iterate();
        while (try it.next()) |f| {
            if (extensionMatches(f.name, extensions)) {
                const path = try dotlessPath(allocator, dir_path, f.name);
                try files.append(allocator, path);
                max_length = @max(max_length, @as(u16, @intCast(path.len)));
            }
        }
    }

    return .{ .paths = files.items, .max_length = max_length };
}

pub fn buildFromArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    extensions: []const []const u8,
    recurse: bool,
    err_writer: *std.io.Writer,
) !FileList {
    var files = std.ArrayList([]const u8).empty;
    var max_length: u16 = 0;

    for (args) |path| {
        if (extensionMatches(path, extensions)) {
            max_length = @max(max_length, @as(u16, @intCast(path.len)));
            try files.append(allocator, path);
        } else if (try isDir(path)) {
            const dir_files = try build(allocator, path, extensions, recurse);
            max_length = @max(max_length, @as(u16, @intCast(dir_files.max_length)));
            try files.appendSlice(allocator, dir_files.paths);
        } else {
            try err_writer.print("{s} - unsupported file type", .{path});
        }
    }

    return .{ .paths = files.items, .max_length = max_length };
}

test extensionMatches {
    const extensions = [_][]const u8{ "txt", "TXT" };

    try std.testing.expectEqual(true, extensionMatches("f.txt", &extensions));
    try std.testing.expectEqual(true, extensionMatches("f.TXT", &extensions));
    try std.testing.expectEqual(false, extensionMatches("f.lol", &extensions));
}

fn extensionMatches(name: []const u8, extensions: []const []const u8) bool {
    if (std.mem.lastIndexOf(u8, name, ".")) |i| {
        const ext = name[i + 1 .. name.len];
        for (extensions) |e| {
            if (std.mem.eql(u8, ext, e)) return true;
        }
    }
    return false;
}

test dotlessPath {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    try std.testing.expectEqualStrings("a.file", try dotlessPath(allocator, ".", "a.file"));
    try std.testing.expectEqualStrings("dir/a.file", try dotlessPath(allocator, "dir", "a.file"));
    try std.testing.expectEqualStrings("./dir/a.file", try dotlessPath(allocator, "./dir", "a.file"));
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

test isDir {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("d");
    var f = try tmp.dir.createFile("f", .{});
    f.close();

    const tmp_path = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", &tmp.sub_path });
    const d_path = try std.fs.path.join(allocator, &.{ tmp_path, "d" });
    const f_path = try std.fs.path.join(allocator, &.{ tmp_path, "f" });

    try std.testing.expectEqual(true, try isDir(d_path));
    try std.testing.expectEqual(false, try isDir(f_path));
}

fn isDir(path: []const u8) !bool {
    const stat = try std.fs.cwd().statFile(path);
    return stat.kind == std.fs.File.Kind.directory;
}
