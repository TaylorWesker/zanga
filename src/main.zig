const std = @import("std");
const debug = std.debug;
const log = std.log;
const ArrayList = std.ArrayList;
const mem = std.mem;
const json = std.json;
const fs = std.fs;

const zig_cli = @import("zig-cli");
const rem = @import("rem");

const MangadexAPI = @import("mangadex_api.zig").MangadexAPI;
const zdl = @import("zdownloader.zig");
const ZDownloader = @import("zdownloader.zig").ZDownloader;
const Range = @import("zdownloader.zig").Range;
const HTTPDownloader = @import("http_downloader.zig").HTTPDownloader;

const KB = @import("size_constant.zig").KB;
const MB = @import("size_constant.zig").MB;
const GB = @import("size_constant.zig").GB;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var app_downloader: ZDownloader = undefined;

const ApiType = enum {
    mangadex,
    mangakarot,
    unknown,
};

fn get_url_type(url: []const u8) ApiType {
    const mangadex_id = extract_mangadex_id(url);
    if (mangadex_id != null) return .mangadex;
    if (is_mangakarot_id(url)) return .mangakarot;
    return .unknown;
}

fn get_id_type(id: []const u8) ApiType {
    if (is_mangadex_id(id)) return .mangadex;
    // /manga-ba979135
    if (is_mangakarot_id(id)) return .mangakarot;
    return .unknown;
}

fn is_mangakarot_id(id: []const u8) bool {
    const uri = std.Uri.parse(id) catch return false;
    switch (uri.host.?) {
        .raw => {
            if (std.mem.startsWith(u8, uri.host.?.raw, "ww7.mangakakalot.tv")) return true;
        },
        .percent_encoded => {
            if (std.mem.startsWith(u8, uri.host.?.percent_encoded, "ww7.mangakakalot.tv")) return true;
        },
    }
    return false;
}

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

const app = zig_cli.App{
    .command = zig_cli.Command{
        .name = "zanga",
        .description = zig_cli.Description{ .one_line = "A manga downloader" },
        .target = zig_cli.CommandTarget{
            .subcommands = &.{
                &zig_cli.Command{
                    .name = "init",
                    .description = zig_cli.Description{ .one_line = "initialize the zanga global config file" },
                    .target = zig_cli.CommandTarget{
                        .action = zig_cli.CommandAction{
                            .positional_args = zig_cli.PositionalArgs{
                                .args = &.{
                                    &init_posarg,
                                },
                            },
                            .exec = run_init,
                        },
                    },
                },
                &zig_cli.Command{
                    .name = "update",
                    .description = zig_cli.Description{ .one_line = "download all the latest chapter for all mangas in manga.list" },
                    .target = zig_cli.CommandTarget{
                        .action = zig_cli.CommandAction{
                            .exec = run_update,
                        },
                    },
                },
                &zig_cli.Command{
                    .name = "download",
                    .description = zig_cli.Description{ .one_line = "download manga from the url and optional range" },
                    .target = zig_cli.CommandTarget{
                        .action = zig_cli.CommandAction{
                            .positional_args = zig_cli.PositionalArgs{
                                .args = &.{ &download_posarg1, &download_posarg2 },
                                .first_optional_arg = &download_posarg2,
                            },
                            .exec = run_download,
                        },
                    },
                },
                &zig_cli.Command{
                    .name = "download2",
                    .description = zig_cli.Description{ .one_line = "download manga from the url and optional range" },
                    .target = zig_cli.CommandTarget{
                        .action = zig_cli.CommandAction{
                            .positional_args = zig_cli.PositionalArgs{
                                .args = &.{ &download_posarg1, &download_posarg2 },
                                .first_optional_arg = &download_posarg2,
                            },
                            .exec = run_download2,
                        },
                    },
                },
            },
        },
    },
};

const InitArgs = struct {
    download_path: []const u8 = "",
};
var init_args = InitArgs{};

var init_posarg = zig_cli.PositionalArg{
    .name = "download_path",
    .help = "the path where the scans will be downloaded",
    .value_ref = zig_cli.mkRef(&init_args.download_path),
};

fn run_init() !void {
    std.log.info("init command launched", .{});
    std.log.info("path provied is: '{s}'", .{init_args.download_path});

    try ZDownloader.setDownloadPath(init_args.download_path, gpa.allocator());
}

fn run_update() !void {
    std.log.info("update command launched", .{});

    app_downloader = try ZDownloader.init(gpa.allocator());

    for (app_downloader.manga_entries.entries.items) |e| {
        log.info("updatating {s}", .{e.manga_title});
        const t = get_id_type(e.manga_id);
        switch (t) {
            .mangadex => try app_downloader.downloadRangeMangadex(e.manga_id, .{ .begin = null, .end = null }),
            // .mangadex => {},
            .mangakarot => try app_downloader.downloadRangeMangakarot(e.manga_id, .{ .begin = null, .end = null }),
            .unknown => std.log.warn("{s} -> Is not a known ID", .{e.manga_id}),
        }
    }
}

const DowloadArgs = struct {
    url: []const u8 = "",
    range_str: []const u8 = "",
};
var download_args = DowloadArgs{};

var download_posarg1 = zig_cli.PositionalArg{
    .name = "url",
    .help = "url to the mangadex manga page",
    .value_ref = zig_cli.mkRef(&download_args.url),
};
var download_posarg2 = zig_cli.PositionalArg{
    .name = "range",
    .help = "range to be downloaded",
    .value_ref = zig_cli.mkRef(&download_args.range_str),
};

fn run_download() !void {
    std.log.info("download command launched", .{});

    const url = download_args.url;
    const range_str: []const u8 = download_args.range_str;

    std.log.info("url provided is: '{s}'", .{url});
    if (range_str.len != 0) {
        std.log.info("range provided is: '{s}'", .{range_str});
    }

    const manga_id = extract_mangadex_id(url) orelse {
        log.err("invalid ID provided '{s}'", .{url});
        return;
    };

    const range = try strToRange(range_str);

    app_downloader = try ZDownloader.init(gpa.allocator());
    defer app_downloader.deinit();
    try app_downloader.saveMangaEntries();

    const t = get_url_type(manga_id);
    switch (t) {
        .mangadex => try app_downloader.downloadRangeMangadex(manga_id, range),
        .mangakarot => try app_downloader.downloadRangeMangakarot(manga_id, range),
        .unknown => std.log.warn("{s} -> Is not a known ID", .{manga_id}),
    }

    try app_downloader.saveMangaEntries();
}

fn run_download2() !void {
    std.log.info("download command launched", .{});

    const url = download_args.url;
    const range_str: []const u8 = download_args.range_str;

    std.log.info("url provided is: '{s}'", .{url});
    if (range_str.len != 0) {
        std.log.info("range provided is: '{s}'", .{range_str});
    }

    // const manga_id = extract_mangadex_id(url) orelse {
    //     log.err("invalid ID provided '{s}'", .{url});
    //     return;
    // };

    const range = try strToRange(range_str);

    app_downloader = try ZDownloader.init(gpa.allocator());
    defer app_downloader.deinit();
    try app_downloader.saveMangaEntries();

    try app_downloader.downloadRangeMangakarot(url, range);
    try app_downloader.saveMangaEntries();
}

pub fn main() !void {
    try zig_cli.run(&app, gpa.allocator());
    // const url = "https://ww7.mangakakalot.tv/manga/manga-ba979135";
    // try zdl.handleMangaPage(url, gpa.allocator());
}
