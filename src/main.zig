const std = @import("std");
const debug = std.debug;
const log = std.log;
const ArrayList = std.ArrayList;
const mem = std.mem;
const json = std.json;
const fs = std.fs;

const zig_cli = @import("zig-cli");

const MangadexAPI = @import("mangadex_api.zig").MangadexAPI;
const ZDownloader = @import("zdownloader.zig").ZDownloader;
const Range = @import("zdownloader.zig").Range;

const KB = @import("size_constant.zig").KB;
const MB = @import("size_constant.zig").MB;
const GB = @import("size_constant.zig").GB;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var app_downloader: ZDownloader = undefined;

fn is_mangadex_id(s: []const u8) bool {
    if (s.len != 36) return false;

    const dash_indexs = [_]u8{ 8, 13, 18, 23 };

    inline for (dash_indexs) |i| {
        if (s.ptr[i] != '-') return false;
    }

    return true;
}

fn extract_mangadex_id(s: []const u8) ?[]const u8 {
    var r: ?[]const u8 = null;

    var it = mem.tokenizeScalar(u8, s, '/');
    while (it.next()) |part| {
        if (is_mangadex_id(part)) {
            r = part;
            break;
        }
    }

    return r;
}

const AppConfig = struct {
    scan_dir: []const u8,
};

const AppParam = struct {
    manga_id: []const u8,
    range: Range,
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

const app = zig_cli.App{
    .name = "zanga",
    .subcommands = &.{
        &zig_cli.Command{
            .name = "init",
            .help = "initialize the zanga global config file",
            .action = run_init,
        },
        &zig_cli.Command{
            .name = "update",
            .help = "download all the latest chapter for all mangas in manga.list",
            .action = run_update,
        },
        &zig_cli.Command{
            .name = "download",
            .help = "download manga from the url and optional range",
            .action = run_download,
        },
    },
};

fn run_init(args: []const []const u8) !void {
    std.log.info("init command launched", .{});
    if (args.len != 1) {
        return error.InvalidArguments;
    }
    std.log.info("path provied is: '{s}'", .{args[0]});

    try ZDownloader.setDownloadPath(args[0], gpa.allocator());
}

fn run_update(args: []const []const u8) !void {
    std.log.info("update command launched", .{});
    if (args.len != 0) {
        return error.InvalidArguments;
    }

    app_downloader = try ZDownloader.init(gpa.allocator());

    for (app_downloader.manga_entries.entries.items) |e| {
        log.info("updatating {s}", .{e.manga_title});
        try app_downloader.downloadRange(e.manga_id, .{ .begin = null, .end = null });
    }
}

fn run_download(args: []const []const u8) !void {
    std.log.info("download command launched", .{});
    if (args.len != 1 and args.len != 2) {
        return error.InvalidArguments;
    }

    var url = args[0];
    var range_str: []const u8 = "";

    std.log.info("url provided is: '{s}'", .{url});
    if (args.len == 2) {
        range_str = args[1];
        std.log.info("range provided is: '{s}'", .{range_str});
    }

    var manga_id = extract_mangadex_id(url) orelse {
        log.err("invalid ID provided '{s}'", .{url});
        return;
    };

    var range = try strToRange(range_str);

    app_downloader = try ZDownloader.init(gpa.allocator());
    defer app_downloader.deinit();
    try app_downloader.saveMangaEntries();

    try app_downloader.downloadRange(manga_id, range);
    try app_downloader.saveMangaEntries();
}

pub fn main() !void {
    try zig_cli.run(&app, gpa.allocator());
    // var args = try std.process.argsWithAllocator(gpa.allocator());
    // _ = args.skip();

    // log.info("download path is: '{s}'", .{app_downloader.download_path});

    // try app_downloader.saveMangaEntries();

    // log.info("Downloader initialized !", .{});

    // var url = args.next() orelse {
    //     log.err("no url provided", .{});
    //     return;
    // };

    // var range_str = args.next() orelse "";

    // var manga_id = extract_mangadex_id(url) orelse {
    //     log.err("invalid ID provided '{s}'", .{url});
    //     return;
    // };

    // var range = try strToRange(range_str);

    // try app_downloader.downloadRange(manga_id, range);

    // try app_downloader.saveMangaEntries();
}
