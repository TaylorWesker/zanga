const std = @import("std");
const Allocator = std.mem.Allocator;
const HTTPDownloader = @import("http_downloader.zig").HTTPDownloader;
const ArrayList = std.ArrayList;
const json = std.json;
const bufPrint = std.fmt.bufPrint;
const time = std.time;

const KB = @import("size_constant.zig").KB;
const MB = @import("size_constant.zig").MB;
const GB = @import("size_constant.zig").GB;

const RateLimiter = @import("rate_limiter.zig").RateLimiter;

pub const MangadexAPI = struct {
    const Self = @This();

    const MANGA_API_TEMPLATE = "https://api.mangadex.org/manga/{s}";
    const CHAPTER_API_TEMPLATE = "https://api.mangadex.org/manga/{s}/feed?order[chapter]=asc&translatedLanguage[]=en&limit=500&offset=0";
    const PAGE_API_TEMPLATE = "https://api.mangadex.org/at-home/server/{s}";
    const DOWNLOAD_PAGE_TEMPLATE = "{s}/data/{s}/{s}";

    const GLOBAL_MAX_REQUEST = 5;
    const PAGE_MAX_REQUEST = 39;

    pub const MangaJson = struct { data: struct { attributes: struct { title: struct {
        en: ?[]u8 = null,
        ja: ?[]u8 = null,
    } } } };

    pub const ChapterJson = struct { data: []struct { id: []u8, attributes: struct {
        chapter: ?[]u8 = null,
        title: ?[]u8 = null,
    } } };

    pub const PageJson = struct { baseUrl: []u8, chapter: struct {
        hash: []u8,
        data: [][]u8,
        dataSaver: [][]u8,
    } };

    allocator: Allocator,

    downloader: HTTPDownloader,

    manga_api_buffer: [MANGA_API_TEMPLATE.len - 3 + 36]u8 = undefined,
    chapter_api_buffer: [CHAPTER_API_TEMPLATE.len - 3 + 36]u8 = undefined,
    page_api_buffer: [PAGE_API_TEMPLATE.len - 3 + 36]u8 = undefined,
    // FIX(TW): dangerous, buffer might be too small.
    //          Make it dynamic ?
    download_page_buffer: [DOWNLOAD_PAGE_TEMPLATE.len + 1024]u8 = undefined,

    manga_json_buffer: ArrayList(u8),
    chapter_json_buffer: ArrayList(u8),
    page_json_buffer: ArrayList(u8),
    image_buffer: ArrayList(u8),

    global_limiter: RateLimiter(MangadexAPI.GLOBAL_MAX_REQUEST, time.ns_per_s) = .{},
    page_limiter: RateLimiter(MangadexAPI.PAGE_MAX_REQUEST, time.ns_per_min) = .{},

    pub fn init(allocator: Allocator) !Self {
        return .{
            .allocator = allocator,
            .downloader = try HTTPDownloader.init(allocator),
            .manga_json_buffer = try ArrayList(u8).initCapacity(allocator, 4 * KB),
            .chapter_json_buffer = try ArrayList(u8).initCapacity(allocator, 4 * KB),
            .page_json_buffer = try ArrayList(u8).initCapacity(allocator, 4 * KB),
            .image_buffer = try ArrayList(u8).initCapacity(allocator, 1 * MB),
        };
    }

    pub fn deinit(self: *Self) void {
        self.downloader.deinit();
        self.manga_json_buffer.deinit();
        self.chapter_json_buffer.deinit();
        self.page_json_buffer.deinit();
        self.image_buffer.deinit();
    }

    fn check_tss_and_wait(limiter_type: type, limiter: *limiter_type) void {
        const current_time = time.Instant.now() catch unreachable;
        if (!limiter.push_action(current_time))
            limiter.clear_out_of_periode(current_time);
        if (!limiter.push_action(current_time))
            limiter.wait_to_clear(current_time);
        _ = limiter.push_action(current_time);
    }

    fn check_global_tss_and_wait(self: *Self) void {
        MangadexAPI.check_tss_and_wait(@TypeOf(self.global_limiter), &self.global_limiter);
    }

    fn check_page_tss_and_wait(self: *Self) void {
        MangadexAPI.check_tss_and_wait(@TypeOf(self.page_limiter), &self.page_limiter);
    }

    pub fn getMangaInfo(self: *Self, id: []const u8) !json.Parsed(MangaJson) {
        const url = try bufPrint(&self.manga_api_buffer, MangadexAPI.MANGA_API_TEMPLATE, .{id});
        self.check_global_tss_and_wait();
        try self.downloader.download_from_url_reset(url, &self.manga_json_buffer);
        // return json.parseFromSlice(MangaJson, self.allocator, self.manga_json_buffer.items, .{ .ignore_unknown_fields = true }) catch |err| {
        //     std.log.err("{s}\n", .{self.manga_json_buffer.items});
        //     var f = try std.fs.cwd().createFile("crash_invalid.json", .{});
        //     try f.writeAll(self.chapter_json_buffer.items);
        //     return err;
        // };
        const input = self.manga_json_buffer.items;

        var scanner = json.Scanner.initCompleteInput(self.allocator, input);
        defer scanner.deinit();

        var diagnostics = std.json.Diagnostics{};
        scanner.enableDiagnostics(&diagnostics);

        const res = json.parseFromTokenSource(MangaJson, self.allocator, &scanner, .{ .ignore_unknown_fields = true }) catch |e| {
            // const res = json.parseFromSlice(ChapterJson, self.allocator, self.chapter_json_buffer.items, .{ .ignore_unknown_fields = true }) catch |e| {
            std.log.err("{s}\n", .{input});
            var f = try std.fs.cwd().createFile("crash_invalid.json", .{});
            try f.writeAll(input);
            std.log.err("{}:{}:{} '{s}'", .{ diagnostics.getLine(), diagnostics.getColumn(), diagnostics.getByteOffset(), input[diagnostics.getByteOffset() .. diagnostics.getByteOffset() + 10] });
            return e;
        };
        return res;
    }

    pub fn getChapterInfo(self: *Self, id: []const u8) !json.Parsed(ChapterJson) {
        const url = try bufPrint(&self.chapter_api_buffer, MangadexAPI.CHAPTER_API_TEMPLATE, .{id});
        self.check_global_tss_and_wait();
        try self.downloader.download_from_url_reset(url, &self.chapter_json_buffer);

        const input = self.chapter_json_buffer.items;

        var scanner = json.Scanner.initCompleteInput(self.allocator, input);
        defer scanner.deinit();

        var diagnostics = std.json.Diagnostics{};
        scanner.enableDiagnostics(&diagnostics);

        const res = json.parseFromTokenSource(ChapterJson, self.allocator, &scanner, .{ .ignore_unknown_fields = true }) catch |e| {
            // const res = json.parseFromSlice(ChapterJson, self.allocator, self.chapter_json_buffer.items, .{ .ignore_unknown_fields = true }) catch |e| {
            std.log.err("{s}\n", .{input});
            var f = try std.fs.cwd().createFile("crash_invalid.json", .{});
            try f.writeAll(input);
            std.log.err("{}:{}:{} '{s}'", .{ diagnostics.getLine(), diagnostics.getColumn(), diagnostics.getByteOffset(), input[diagnostics.getByteOffset() .. diagnostics.getByteOffset() + 10] });
            return e;
        };
        return res;
    }

    pub fn getPageInfo(self: *Self, id: []const u8) !json.Parsed(PageJson) {
        const url = try bufPrint(&self.page_api_buffer, MangadexAPI.PAGE_API_TEMPLATE, .{id});
        self.check_global_tss_and_wait();
        self.check_page_tss_and_wait();
        try self.downloader.download_from_url_reset(url, &self.page_json_buffer);
        // return json.parseFromSlice(PageJson, self.allocator, self.page_json_buffer.items, .{ .ignore_unknown_fields = true }) catch |err| {
        //     std.debug.print("{s}\n", .{self.page_json_buffer.items});
        //     return err;
        // };
        const input = self.page_json_buffer.items;

        var scanner = json.Scanner.initCompleteInput(self.allocator, input);
        defer scanner.deinit();

        var diagnostics = std.json.Diagnostics{};
        scanner.enableDiagnostics(&diagnostics);

        const res = json.parseFromTokenSource(PageJson, self.allocator, &scanner, .{ .ignore_unknown_fields = true }) catch |e| {
            // const res = json.parseFromSlice(ChapterJson, self.allocator, self.chapter_json_buffer.items, .{ .ignore_unknown_fields = true }) catch |e| {
            std.log.err("{s}\n", .{input});
            var f = try std.fs.cwd().createFile("crash_invalid.json", .{});
            try f.writeAll(input);
            std.log.err("{}:{}:{} '{s}'", .{ diagnostics.getLine(), diagnostics.getColumn(), diagnostics.getByteOffset(), input[diagnostics.getByteOffset() .. diagnostics.getByteOffset() + 10] });
            return e;
        };
        return res;
    }

    pub fn getPageImage(self: *Self, base_url: []const u8, hash: []const u8, filename: []const u8) ![]u8 {
        const url = try bufPrint(&self.download_page_buffer, MangadexAPI.DOWNLOAD_PAGE_TEMPLATE, .{ base_url, hash, filename });
        self.check_global_tss_and_wait();
        try self.downloader.download_from_url_reset(url, &self.image_buffer);
        return self.image_buffer.items;
    }
};
