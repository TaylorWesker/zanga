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
    headers: http.Headers,

    pub fn init(allocator: mem.Allocator) !Self {
        const headers = http.Headers.init(allocator);
        // try headers.append("User-Agent", "Mozilla/5.0 (Windows NT 6.1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/27.0.1453.110 Safari/537.36");
        return .{
            .client = http.Client{ .allocator = allocator },
            .headers = headers,
        };
    }

    pub fn deinit(downloader: *Self) void {
        downloader.client.deinit();
        downloader.headers.deinit();
    }

    pub fn download_from_url_reset(downloader: *Self, url: []const u8, buffer: *ArrayList(u8)) !void {
        buffer.items.len = 0;
        try downloader.download_from_url_append(url, buffer);
    }

    pub fn download_from_url_append(downloader: *Self, url: []const u8, buffer: *ArrayList(u8)) !void {
        try buffer.ensureTotalCapacity(4 * KB);
        const uri = try std.Uri.parse(url);
        var request = try downloader.client.open(.GET, uri, downloader.headers, .{});
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
