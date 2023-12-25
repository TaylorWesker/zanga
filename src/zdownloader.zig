const std = @import("std");
const builtin = @import("builtin");
const log = std.log;
const mem = std.mem;
const fs = std.fs;
const debug = std.debug;

const MangadexAPI = @import("mangadex_api.zig").MangadexAPI;

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
    var b = it.next() orelse return error.InvalidRangeFormat;
    var e = it.next() orelse return error.InvalidRangeFormat;
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
        var arena_alloc = std.heap.ArenaAllocator.init(allocator);
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
        var allocator = self.allocator.allocator();

        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.manga_title, entry_name)) {
                var id_copy = try allocator.alloc(u8, new_id.len);

                @memcpy(id_copy, new_id);
                e.manga_id = id_copy;
            }
        }
    }

    fn addEntryCopyName(self: *Self, entry: MangaEntry) !void {
        var allocator = self.allocator.allocator();

        var title_copy = try allocator.alloc(u8, entry.manga_title.len);

        @memcpy(title_copy, entry.manga_title);

        try self.entries.append(MangaEntry{
            .manga_title = title_copy,
            .manga_id = entry.manga_id,
            .downloaded_range = entry.downloaded_range,
        });
    }

    fn addEntryCopyParams(self: *Self, entry: MangaEntry) !void {
        var allocator = self.allocator.allocator();

        var title_copy = try allocator.alloc(u8, entry.manga_title.len);

        var id_copy = try allocator.alloc(u8, entry.manga_id.len);

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
        var home_path: []const u8 = "";
        if (builtin.os.tag == .linux) {
            home_path = env.get("HOME") orelse blk: {
                log.warn("no HOME variable found", .{});
                break :blk "";
            };
        } else if (builtin.os.tag == .windows) {
            home_path = env.get("APPDATA") orelse blk: {
                log.warn("no APPDATA variable found", .{});
                break :blk "";
            };
        }

        var config_dir = try fs.openDirAbsolute(home_path, .{});
        var program_config_dir = try config_dir.makeOpenPath("zmanga-dl", .{});
        config_dir.close();

        var config_file = try program_config_dir.createFile("config.ini", .{ .read = true, .truncate = false });
        program_config_dir.close();

        return config_file;
    }

    fn openOrCreateConfigFileWrite(env: std.process.EnvMap) !std.fs.File {
        var home_path: []const u8 = "";
        if (builtin.os.tag == .linux) {
            home_path = env.get("HOME") orelse blk: {
                log.warn("no HOME variable found", .{});
                break :blk "";
            };
        } else if (builtin.os.tag == .windows) {
            home_path = env.get("APPDATA") orelse blk: {
                log.warn("no APPDATA variable found", .{});
                break :blk "";
            };
        }

        var config_dir = try fs.openDirAbsolute(home_path, .{});
        var program_config_dir = try config_dir.makeOpenPath("zmanga-dl", .{});
        config_dir.close();

        var config_file = try program_config_dir.createFile("config.ini", .{ .read = true, .truncate = true });
        program_config_dir.close();

        return config_file;
    }

    fn getDownloadPath(ini_content: []const u8) ?[]const u8 {
        var ret: ?[]const u8 = null;

        var ini = std.Ini{ .bytes = ini_content };
        var it = ini.iterateSection("\n[paths]\n");
        var path_section = it.next() orelse "";

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

        var home_path: []const u8 = "";
        if (builtin.os.tag == .linux) {
            home_path = env.get("HOME") orelse blk: {
                log.warn("no HOME variable found", .{});
                break :blk "";
            };
        } else if (builtin.os.tag == .windows) {
            home_path = env.get("APPDATA") orelse blk: {
                log.warn("no APPDATA variable found", .{});
                break :blk "";
            };
        }
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
            var downloaded_range = try strToRange(downloaded_range_str);
            try ret.addEntryCopyName(.{
                .manga_title = manga_title,
                .manga_id = manga_id,
                .downloaded_range = downloaded_range,
            });
        }

        return ret;
    }

    fn rangeFromMangaDir(source_dir: fs.Dir, manga_dir_path: []const u8) !Range {
        var dir = try source_dir.openIterableDir(manga_dir_path, .{});
        var dir_it = dir.iterate();

        var ret = Range{
            .begin = null,
            .end = null,
        };

        while (try dir_it.next()) |entry| {
            if (entry.kind != .directory) continue;
            var name = entry.name;
            var val: f32 = try std.fmt.parseFloat(f32, name);
            var ival: u16 = @intFromFloat(val);
            if (ret.begin == null) {
                ret.begin = ival;
            } else {
                if (ret.begin.? > ival) {
                    ret.begin = ival;
                } else {
                    if (ret.end == null) {
                        ret.end = ival;
                    } else if (ret.end.? < ival) ret.end = ival;
                }
            }
        }

        return ret;
    }

    fn scanDownloadDir(manga_list: *MangaCollection, download_path: []const u8) !void {
        var dir = try fs.openIterableDirAbsolute(download_path, .{});
        var dir_it = dir.iterate();

        while (try dir_it.next()) |entry| {
            var manga_name = entry.name;
            if (entry.kind == .directory) {
                var range = try rangeFromMangaDir(dir.dir, manga_name);
                var new_entry = MangaEntry{ .manga_title = manga_name, .manga_id = "undefined", .downloaded_range = range };

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

        var config_content = try config_file.readToEndAlloc(allocator, 500 * KB);

        var download_path = getDownloadPath(config_content) orelse blk: {
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

        var manga_list_content = try manga_list_file.readToEndAlloc(allocator, 500 * KB);

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
            var begin = e.downloaded_range.begin orelse 0;
            var end = e.downloaded_range.end orelse 0;
            try w.print("{s} --- {s} --- {}-{}\n", .{ e.manga_title, e.manga_id, begin, end });
        }
    }

    pub fn downloadRange(self: *Self, manga_id: []const u8, base_range: Range) !void {
        var api = &self.mangadex_api;

        var range = base_range;

        var manga_info = try api.getMangaInfo(manga_id);
        defer manga_info.deinit();

        var chapter_info = try api.getChapterInfo(manga_id);
        defer chapter_info.deinit();

        var manga_title = manga_info.value.data.attributes.title.en;

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
                var fbegin: f32 = @floatFromInt(begin);
                if (chap_value < fbegin) {
                    chapter_progress.completeOne();
                    continue;
                }
            }
            if (range.end) |end| {
                var fend: f32 = @floatFromInt(end);
                if (chap_value > fend) break;
            }

            var chapter_dir = try manga_dir.makeOpenPath(d.attributes.chapter orelse "", .{});

            var page_info = try api.getPageInfo(d.id);
            defer page_info.deinit();

            var chaps = page_info.value.chapter;
            var page_name_data: [1024]u8 = undefined;
            var page_progress = chapter_progress.start("Pages", chaps.data.len);
            for (1.., chaps.data) |i, p| {
                var image = try api.getPageImage(page_info.value.baseUrl, chaps.hash, p);
                var start = mem.lastIndexOfScalar(u8, p, '.') orelse unreachable;
                var ext = p[start..];
                var page_name = try std.fmt.bufPrint(&page_name_data, "{}{s}", .{ i, ext });
                var f = try chapter_dir.createFile(page_name, .{});
                try f.writeAll(image);
                f.close();
                page_progress.completeOne();
            }
            page_progress.end();
        }

        chapter_progress.end();
    }
};
