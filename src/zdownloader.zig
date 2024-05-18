const std = @import("std");
const builtin = @import("builtin");
const log = std.log;
const mem = std.mem;
const fs = std.fs;
const debug = std.debug;

const rem = @import("rem");
const mangakarot_api = @import("mangakarot_api.zig");

const MangadexAPI = @import("mangadex_api.zig").MangadexAPI;
const HTTPDownloader = @import("http_downloader.zig").HTTPDownloader;

const KB = @import("size_constant.zig").KB;
const MB = @import("size_constant.zig").MB;
const GB = @import("size_constant.zig").GB;

pub const Range = struct {
    begin: ?u16,
    end: ?u16,
};

fn strToRange(str: []const u8) !Range {
    var ret = Range{ .begin = null, .end = null };

    if (str.len == 0) return ret;

    var it = mem.splitScalar(u8, str, '-');
    const b = it.next() orelse return error.InvalidRangeFormat;
    const e = it.next() orelse return error.InvalidRangeFormat;
    if (it.next() != null) return error.InvalidRangeFormat;

    if (b.len != 0) {
        ret.begin = try std.fmt.parseInt(u16, b, 10);
    }

    if (e.len != 0) {
        ret.end = try std.fmt.parseInt(u16, e, 10);
    }

    return ret;
}

pub const MangaEntry = struct {
    manga_title: []const u8,
    manga_id: []const u8,
    downloaded_range: Range,
};

const MangaCollection = struct {
    const Self = @This();

    allocator: std.heap.ArenaAllocator,
    strings_arena: []u8,
    entries: std.ArrayList(MangaEntry),

    fn init(allocator: mem.Allocator) Self {
        const arena_alloc = std.heap.ArenaAllocator.init(allocator);
        return .{
            .allocator = arena_alloc,
            .strings_arena = undefined,
            .entries = std.ArrayList(MangaEntry).init(allocator),
        };
    }

    fn deinit(self: *Self) void {
        self.allocator.deinit();
        self.entries.deinit();
    }

    fn entryExistName(self: *Self, entry_name: []const u8) bool {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.manga_title, entry_name)) return true;
        }

        return false;
    }

    fn getEntryByName(self: *Self, entry_name: []const u8) ?MangaEntry {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.manga_title, entry_name)) return e;
        }

        return null;
    }

    fn updateEntryRangeByName(self: *Self, entry_name: []const u8, new_range: Range) void {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.manga_title, entry_name)) e.downloaded_range = new_range;
        }
    }

    fn updateEntryIdByNameCopy(self: *Self, entry_name: []const u8, new_id: []const u8) !void {
        const allocator = self.allocator.allocator();

        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.manga_title, entry_name)) {
                const id_copy = try allocator.alloc(u8, new_id.len);

                @memcpy(id_copy, new_id);
                e.manga_id = id_copy;
            }
        }
    }

    fn addEntryCopyName(self: *Self, entry: MangaEntry) !void {
        const allocator = self.allocator.allocator();

        const title_copy = try allocator.alloc(u8, entry.manga_title.len);

        @memcpy(title_copy, entry.manga_title);

        try self.entries.append(MangaEntry{
            .manga_title = title_copy,
            .manga_id = entry.manga_id,
            .downloaded_range = entry.downloaded_range,
        });
    }

    fn addEntryCopyParams(self: *Self, entry: MangaEntry) !void {
        const allocator = self.allocator.allocator();

        const title_copy = try allocator.alloc(u8, entry.manga_title.len);

        const id_copy = try allocator.alloc(u8, entry.manga_id.len);

        @memcpy(title_copy, entry.manga_title);
        @memcpy(id_copy, entry.manga_id);

        try self.entries.append(MangaEntry{
            .manga_title = title_copy,
            .manga_id = id_copy,
            .downloaded_range = entry.downloaded_range,
        });
    }
};

pub const ZDownloader = struct {
    const Self = @This();

    download_path: []const u8,

    mangadex_api: MangadexAPI,

    config_content: []const u8,

    manga_list_content: []const u8,

    manga_entries: MangaCollection,

    allocator: mem.Allocator,

    fn openOrCreateConfigFile(env: std.process.EnvMap) !std.fs.File {
        const var_name = switch (builtin.os.tag) {
            .linux => "HOME",
            .windows => "APPDATA",
            else => @compileError("Targer not supported"),
        };
        const home_path = env.get(var_name) orelse blk: {
            log.warn("no " ++ var_name ++ " variable found", .{});
            break :blk "";
        };

        var config_dir = try fs.openDirAbsolute(home_path, .{});
        var program_config_dir = try config_dir.makeOpenPath("zmanga-dl", .{});
        config_dir.close();

        const config_file = try program_config_dir.createFile("config.ini", .{ .read = true, .truncate = false });
        program_config_dir.close();

        return config_file;
    }

    fn openOrCreateConfigFileWrite(env: std.process.EnvMap) !std.fs.File {
        const var_name = switch (builtin.os.tag) {
            .linux => "HOME",
            .windows => "APPDATA",
            else => @compileError("Targer not supported"),
        };
        const home_path = env.get(var_name) orelse blk: {
            log.warn("no " ++ var_name ++ " variable found", .{});
            break :blk "";
        };

        var config_dir = try fs.openDirAbsolute(home_path, .{});
        var program_config_dir = try config_dir.makeOpenPath("zmanga-dl", .{});
        config_dir.close();

        const config_file = try program_config_dir.createFile("config.ini", .{ .read = true, .truncate = true });
        program_config_dir.close();

        return config_file;
    }

    fn getDownloadPath(ini_content: []const u8) ?[]const u8 {
        var ret: ?[]const u8 = null;

        const ini = std.Ini{ .bytes = ini_content };
        var it = ini.iterateSection("\n[paths]\n");
        const path_section = it.next() orelse "";

        var var_it = std.mem.tokenizeScalar(u8, path_section, '\n');

        while (var_it.next()) |v| {
            var part_it = mem.tokenizeScalar(u8, v, '=');
            var key = part_it.next() orelse unreachable;
            var value = part_it.next() orelse unreachable;
            key = mem.trim(u8, key, " ");
            value = mem.trim(u8, value, " ");
            value = mem.trim(u8, value, "\"");
            if (std.mem.eql(u8, key, "scan_dir")) {
                ret = value;
                break;
            }
        }

        return ret;
    }

    pub fn setDownloadPath(download_path: []const u8, allocator: std.mem.Allocator) !void {
        var env = try std.process.getEnvMap(allocator);
        defer env.deinit();

        var conf_file = try Self.openOrCreateConfigFileWrite(env);
        var w = conf_file.writer();
        _ = try w.writeAll("[paths]\n");
        try w.print("scan_dir = \"{s}\"", .{download_path});

        const var_name = switch (builtin.os.tag) {
            .linux => "HOME",
            .windows => "APPDATA",
            else => @compileError("Targer not supported"),
        };
        const home_path = env.get(var_name) orelse blk: {
            log.warn("no " ++ var_name ++ " variable found", .{});
            break :blk "";
        };

        if (builtin.os.tag == .linux) {
            std.log.info("saved at '{s}/config.ini'", .{home_path});
        } else if (builtin.os.tag == .windows) {
            std.log.info("saved at '{s}\\config.ini'", .{home_path});
        }
    }

    fn initMangaList(content: []const u8, allocator: std.mem.Allocator) !MangaCollection {
        var ret = MangaCollection.init(allocator);

        var line_it = std.mem.tokenizeScalar(u8, content, '\n');

        while (line_it.next()) |line| {
            var it = std.mem.tokenizeSequence(u8, line, "---");
            var manga_title = it.next() orelse return error.InvalidLineFormat;
            manga_title = mem.trim(u8, manga_title, " ");

            var manga_id = it.next() orelse return error.InvalidLineFormat;
            manga_id = mem.trim(u8, manga_id, " ");
            var downloaded_range_str = it.next() orelse return error.InvalidLineFormat;
            downloaded_range_str = mem.trim(u8, downloaded_range_str, " ");
            const downloaded_range = try strToRange(downloaded_range_str);
            try ret.addEntryCopyName(.{
                .manga_title = manga_title,
                .manga_id = manga_id,
                .downloaded_range = downloaded_range,
            });
        }

        return ret;
    }

    fn rangeFromMangaDir(source_dir: fs.Dir, manga_dir_path: []const u8) !Range {
        var dir = try source_dir.openDir(manga_dir_path, .{ .iterate = true });
        var dir_it = dir.iterate();

        var ret = Range{
            .begin = null,
            .end = null,
        };

        while (try dir_it.next()) |entry| {
            if (entry.kind != .directory) continue;
            const name = entry.name;
            const val: f32 = try std.fmt.parseFloat(f32, name);
            const ival: u16 = @intFromFloat(val);
            // if (ret.begin == null) {
            //     ret.begin = ival;
            // } else {
            //     if (ret.begin.? > ival) {
            //         ret.begin = ival;
            //     } else {
            //         if (ret.end == null) {
            //             ret.end = ival;
            //         } else if (ret.end.? < ival) ret.end = ival;
            //     }
            // }
            if (ret.begin) |begin| {
                if (begin > ival) {
                    ret.begin = ival;
                } else {
                    if (ret.end) |end| {
                        if (end < ival) ret.end = ival;
                    } else ret.end = ival;
                }
            } else {
                ret.begin = ival;
            }
        }

        return ret;
    }

    fn scanDownloadDir(manga_list: *MangaCollection, download_path: []const u8) !void {
        var dir = try fs.openDirAbsolute(download_path, .{ .iterate = true });
        var dir_it = dir.iterate();

        while (try dir_it.next()) |entry| {
            const manga_name = entry.name;
            if (entry.kind == .directory) {
                const range = try rangeFromMangaDir(dir, manga_name);
                const new_entry = MangaEntry{ .manga_title = manga_name, .manga_id = "undefined", .downloaded_range = range };

                if (manga_list.entryExistName(new_entry.manga_title)) {
                    manga_list.updateEntryRangeByName(new_entry.manga_title, range);
                    continue;
                }
                try manga_list.addEntryCopyName(new_entry);
            }
        }
    }

    pub fn init(allocator: std.mem.Allocator) !Self {
        var env = try std.process.getEnvMap(allocator);
        defer env.deinit();

        var config_file = try openOrCreateConfigFile(env);
        defer config_file.close();

        const config_content = try config_file.readToEndAlloc(allocator, 500 * KB);

        const download_path = getDownloadPath(config_content) orelse blk: {
            log.warn("No download path present in config.ini", .{});
            break :blk "scan";
        };

        var download_dir = fs.openDirAbsolute(download_path, .{}) catch |e| {
            log.err("unable to open folder '{s}'", .{download_path});
            return e;
        };
        var manga_list_file = download_dir.createFile("mangas.list", .{ .read = true, .truncate = false }) catch |e| {
            log.err("unable to open file 'mangas.list'", .{});
            return e;
        };
        defer manga_list_file.close();

        const manga_list_content = try manga_list_file.readToEndAlloc(allocator, 500 * KB);

        var manga_entries = try initMangaList(manga_list_content, allocator);
        try scanDownloadDir(&manga_entries, download_path);

        return .{
            .download_path = download_path,
            .mangadex_api = try MangadexAPI.init(allocator),
            .config_content = config_content,
            .manga_list_content = manga_list_content,
            .manga_entries = manga_entries,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.config_content);
        self.mangadex_api.deinit();
    }

    pub fn saveMangaEntries(self: Self) !void {
        var download_dir = try fs.openDirAbsolute(self.download_path, .{});
        var manga_list_file = try download_dir.openFile("mangas.list", .{ .mode = .write_only });

        var w = manga_list_file.writer();

        for (self.manga_entries.entries.items) |e| {
            const begin = e.downloaded_range.begin orelse 0;
            const end = e.downloaded_range.end orelse 0;
            try w.print("{s} --- {s} --- {}-{}\n", .{ e.manga_title, e.manga_id, begin, end });
        }
    }

    pub fn downloadRangeMangadex(self: *Self, manga_id: []const u8, base_range: Range) !void {
        var api = &self.mangadex_api;

        var range = base_range;

        var manga_info = try api.getMangaInfo(manga_id);
        defer manga_info.deinit();

        var chapter_info = try api.getChapterInfo(manga_id);
        defer chapter_info.deinit();

        const manga_title = if (manga_info.value.data.attributes.title.en) |v| v else manga_info.value.data.attributes.title.ja.?;

        debug.print("{s}\n", .{manga_title});

        log.info("Checking Entry existance", .{});
        if (self.manga_entries.getEntryByName(manga_title)) |e| {
            log.info("Entry exists, updating range", .{});
            range.begin = e.downloaded_range.end;
            try self.manga_entries.updateEntryIdByNameCopy(manga_title, manga_id);
        } else {
            log.info("Entry not existant", .{});
            try self.manga_entries.addEntryCopyParams(MangaEntry{
                .manga_title = manga_title,
                .manga_id = manga_id,
                .downloaded_range = .{ .begin = null, .end = null },
            });
        }

        var download_dir = try fs.openDirAbsolute(self.download_path, .{});
        var manga_dir = try download_dir.makeOpenPath(manga_title, .{});
        download_dir.close();

        var progress_bar = std.Progress{};

        var chapter_progress = progress_bar.start("Chapters ", chapter_info.value.data.len);

        for (chapter_info.value.data) |d| {
            var chap_value: f32 = 0;
            if (d.attributes.chapter) |chap| {
                chap_value = try std.fmt.parseFloat(f32, chap);
            }
            if (range.begin) |begin| {
                const fbegin: f32 = @floatFromInt(begin);
                if (chap_value < fbegin) {
                    chapter_progress.completeOne();
                    continue;
                }
            }
            if (range.end) |end| {
                const fend: f32 = @floatFromInt(end);
                if (chap_value > fend) break;
            }

            var chapter_dir = try manga_dir.makeOpenPath(d.attributes.chapter orelse "", .{});

            var page_info = try api.getPageInfo(d.id);
            defer page_info.deinit();

            const chaps = page_info.value.chapter;
            var page_name_data: [1024]u8 = undefined;
            var page_progress = chapter_progress.start("Pages", chaps.data.len);
            for (1.., chaps.data) |i, p| {
                const image = try api.getPageImage(page_info.value.baseUrl, chaps.hash, p);
                const start = mem.lastIndexOfScalar(u8, p, '.') orelse unreachable;
                const ext = p[start..];
                const page_name = try std.fmt.bufPrint(&page_name_data, "{}{s}", .{ i, ext });
                var f = try chapter_dir.createFile(page_name, .{});
                try f.writeAll(image);
                f.close();
                page_progress.completeOne();
            }
            page_progress.end();
        }

        chapter_progress.end();
    }

    pub fn downloadRangeMangakarot(self: *Self, url: []const u8, base_range: Range) !void {
        const lidx = std.mem.lastIndexOfScalar(u8, url, '/');
        if (lidx == null) return error.invalidURL;

        const manga_id = url[lidx.?..];
        std.debug.print("{s}\n", .{manga_id});

        var range = base_range;

        const manga_title = "unimplemented";

        debug.print("{s}\n", .{manga_title});

        log.info("Checking Entry existance", .{});
        if (self.manga_entries.getEntryByName(manga_title)) |e| {
            log.info("Entry exists, updating range", .{});
            range.begin = e.downloaded_range.end;
            try self.manga_entries.updateEntryIdByNameCopy(manga_title, manga_id);
        } else {
            log.info("Entry not existant", .{});
            try self.manga_entries.addEntryCopyParams(MangaEntry{
                .manga_title = manga_title,
                .manga_id = manga_id,
                .downloaded_range = .{ .begin = null, .end = null },
            });
        }

        var download_dir = try fs.openDirAbsolute(self.download_path, .{});
        const manga_dir = try download_dir.makeOpenPath(manga_title, .{});
        download_dir.close();

        var progress_bar = std.Progress{};

        var chapter_url: [128]u8 = undefined;
        @memset(&chapter_url, 0);
        const end_path = try std.fmt.bufPrint(&chapter_url, "/chapter{s}", .{manga_id});

        const chapter_elems = try mangakarot_api.getChapterPages(url, self.allocator);
        var n_chapters: usize = 0;
        for (chapter_elems) |el| {
            if (el.element_type == .html_a) {
                if (el.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "href" })) |src| {
                    if (std.mem.startsWith(u8, src, end_path)) {
                        n_chapters += 1;
                    }
                }
            }
        }

        var chapter_progress = progress_bar.start("Chapters ", n_chapters);

        const uri = try std.Uri.parse(url);
        var url_next: [1024]u8 = undefined;
        @memset(&url_next, 0);

        for (chapter_elems) |d| {
            if (d.element_type != .html_a) continue;
            const link = d.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "href" }) orelse continue;
            if (!std.mem.startsWith(u8, link, end_path)) {
                continue;
            }

            const dash_index = std.mem.lastIndexOfScalar(u8, link, '-') orelse unreachable;

            const chap_number = link[dash_index + 1 ..];

            // std.debug.print("{s}\n", .{chap_number});

            const chap_value: f32 = try std.fmt.parseFloat(f32, chap_number);
            if (range.begin) |begin| {
                const fbegin: f32 = @floatFromInt(begin);
                if (chap_value < fbegin) {
                    chapter_progress.completeOne();
                    continue;
                }
            }
            if (range.end) |end| {
                const fend: f32 = @floatFromInt(end);
                if (chap_value > fend) break;
            }

            const chapter_dir = try manga_dir.makeOpenPath(chap_number, .{});

            const s: []u8 = switch (uri.host.?) {
                .raw => try std.fmt.bufPrint(&url_next, "https://{s}{s}", .{ uri.host.?.raw, link }),
                .percent_encoded => try std.fmt.bufPrint(&url_next, "https://{s}{s}", .{ uri.host.?.percent_encoded, link }),
            };
            const pages = try mangakarot_api.getChapterImages(s, &self.mangadex_api.downloader, self.allocator);
            // var page_progress = chapter_progress.start("Pages", chaps.data.len);
            var i: usize = 1;
            var name_buffer: [128]u8 = undefined;
            for (pages) |el| {
                if (el.element_type == .html_img) {
                    if (el.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "data-src" })) |src| {
                        const s2 = try std.fmt.bufPrint(&url_next, "{s}", .{src});
                        _ = s2;
                        // std.debug.print("{}.jpg: {s} {s}\n", .{ i, s2, chap_number });
                        try self.mangadex_api.downloader.download_from_url_reset(src, &self.mangadex_api.image_buffer);
                        const image = self.mangadex_api.image_buffer.items;
                        const page_name = try std.fmt.bufPrint(&name_buffer, "{}.jpg", .{i});
                        var f = try chapter_dir.createFile(page_name, .{});
                        try f.writeAll(image);
                        f.close();
                        // page_progress.completeOne();
                        i += 1;
                    }
                }
            }

            // page_progress.end();
        }

        chapter_progress.end();
    }
};
