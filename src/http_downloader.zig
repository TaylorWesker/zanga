const std = @import("std");
const http = std.http;
const mem = std.mem;
const ArrayList = std.ArrayList;

const KB = @import("size_constant.zig").KB;
const MB = @import("size_constant.zig").MB;
const GB = @import("size_constant.zig").GB;

pub const HTTPDownloader = struct {
    const Self = @This();

    client: http.Client,

    pub fn init(allocator: mem.Allocator) !Self {
        // try headers.append("User-Agent", "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/27.0.1453.110 Safari/537.36");
        return .{
            .client = http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(downloader: *Self) void {
        downloader.client.deinit();
    }

    pub fn download_from_url_reset(downloader: *Self, url: []const u8, buffer: *ArrayList(u8)) !void {
        buffer.items.len = 0;
        try downloader.download_from_url_append(url, buffer);
    }

    pub fn download_from_url_append(downloader: *Self, url: []const u8, buffer: *ArrayList(u8)) !void {
        try buffer.ensureTotalCapacity(4 * KB);
        const uri = try std.Uri.parse(url);
        const header_buffer = [_]u8{0} ** 1024;
        const header_buffer_slice: []u8 = @constCast(&header_buffer);
        var request = try downloader.client.open(.GET, uri, .{ .server_header_buffer = header_buffer_slice });
        defer request.deinit();
        try request.send(.{});
        try request.wait();

        while (true) {
            const readed = try request.read(buffer.allocatedSlice()[buffer.items.len..]);
            buffer.items.len += readed;
            if (readed == 0) break;
            if (buffer.items.len == buffer.capacity) try buffer.ensureTotalCapacity(buffer.capacity * 2);
        }
    }
};
