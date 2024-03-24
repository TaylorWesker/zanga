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
        std.log.info("{s}", .{url});
        _ = try downloader.client.fetch(.{ .location = .{ .url = url }, .method = .GET, .response_storage = .{ .dynamic = buffer }, .max_append_size = 10 * MB, .keep_alive = false });
    }
};
