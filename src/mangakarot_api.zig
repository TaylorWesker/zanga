const std = @import("std");
const rem = @import("rem");
const HTTPDownloader = @import("http_downloader.zig").HTTPDownloader;

pub fn utf8DecodeStringLen(string: []const u8) usize {
    var i: usize = 0;
    var decoded_len: usize = 0;
    while (i < string.len) {
        i += std.unicode.utf8ByteSequenceLength(string[i]) catch unreachable;
        decoded_len += 1;
    }
    return decoded_len;
}

pub fn utf8DecodeStringComptime(comptime string: []const u8) [utf8DecodeStringLen(string)]u21 {
    var result: [utf8DecodeStringLen(string)]u21 = undefined;
    if (result.len == 0) return result;
    var decoded_it = std.unicode.Utf8View.initComptime(string).iterator();
    var i: usize = 0;
    while (decoded_it.nextCodepoint()) |codepoint| {
        result[i] = codepoint;
        i += 1;
    }
    return result;
}

pub fn utf8DecodeString(string: []const u8, buffer: []u21) ![]u21 {
    var ret = buffer;
    var decoded_it = (try std.unicode.Utf8View.init(string)).iterator();
    var i: usize = 0;
    while (decoded_it.nextCodepoint()) |codepoint| {
        ret[i] = codepoint;
        i += 1;
    }
    ret.len = i;

    return ret;
}

pub fn getChapterImages(site_url: []const u8, dler: *HTTPDownloader, allocator: std.mem.Allocator) ![]*rem.Dom.Element {
    // std.debug.print("{s}\n", .{site_url});
    var arr = std.ArrayList(u8).init(allocator);
    var arr_utf8 = std.ArrayList(u21).init(allocator);

    try dler.download_from_url_reset(site_url, &arr);

    const utf_len = utf8DecodeStringLen(arr.items);
    try arr_utf8.ensureTotalCapacity(utf_len);

    const decoded = try utf8DecodeString(arr.items, arr_utf8.allocatedSlice());

    var dom = rem.Dom{ .allocator = allocator };

    var parser = try rem.Parser.init(&dom, decoded, allocator, .report, false);
    defer parser.deinit();

    try parser.run();
    // const errors = parser.errors();

    // if (errors.len != 0) {
    //     for (errors) |e| {
    //         std.debug.print("{any}\n", .{e});
    //     }
    // }

    return dom.all_elements.items;
}
pub fn handleChapterPage(site_url: []const u8, dler: *HTTPDownloader, allocator: std.mem.Allocator) !void {
    const elems = getChapterImages(site_url, dler, allocator);

    var url_next: [1024]u8 = undefined;
    @memset(&url_next, 0);
    var i: usize = 1;
    for (elems) |el| {
        if (el.element_type == .html_img) {
            if (el.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "data-src" })) |src| {
                const s = try std.fmt.bufPrint(&url_next, "{s}", .{src});
                std.debug.print("{}.jpg: {s}\n", .{ i, s });
                i += 1;
            }
        }
    }
}

pub fn getChapterPages(url: []const u8, allocator: std.mem.Allocator) ![]*rem.Dom.Element {
    var dler = try HTTPDownloader.init(allocator);
    var arr = std.ArrayList(u8).init(allocator);
    var arr_utf8 = std.ArrayList(u21).init(allocator);

    try dler.download_from_url_reset(url, &arr);
    // std.debug.print("{s}\n", .{arr.items});

    const utf_len = utf8DecodeStringLen(arr.items);
    try arr_utf8.ensureTotalCapacity(utf_len);

    const decoded = try utf8DecodeString(arr.items, arr_utf8.allocatedSlice());

    // std.debug.print("{}\n", .{decoded.len});

    var dom = rem.Dom{ .allocator = allocator };

    var parser = try rem.Parser.init(&dom, decoded, allocator, .report, false);
    defer parser.deinit();

    try parser.run();
    // const errors = parser.errors();

    // if (errors.len != 0) {
    //     for (errors) |e| {
    //         std.debug.print("{any}\n", .{e});
    //     }
    // }

    return dom.all_elements.items;
}

pub fn handleMangaPage(url: []const u8, allocator: std.mem.Allocator) !void {
    var dler = try HTTPDownloader.init(allocator);
    const elems = try getChapterPages(url, allocator);

    const lidx = std.mem.lastIndexOfScalar(u8, url, '/');
    if (lidx == null) return error.invalidURL;

    const manga_id = url[lidx.?..];
    // std.debug.print("{s}\n", .{manga_id});

    var chapter_url: [128]u8 = undefined;
    @memset(&chapter_url, 0);
    const end_path = try std.fmt.bufPrint(&chapter_url, "/chapter{s}", .{manga_id});
    const uri = try std.Uri.parse(url);
    var url_next: [1024]u8 = undefined;
    @memset(&url_next, 0);
    for (elems) |el| {
        if (el.element_type == .html_a) {
            if (el.getAttribute(.{ .prefix = .none, .namespace = .none, .local_name = "href" })) |src| {
                if (std.mem.startsWith(u8, src, end_path)) {
                    const s = try std.fmt.bufPrint(&url_next, "https://{s}{s}", .{ uri.host.?, src });
                    try handleChapterPage(s, &dler, allocator);
                }
            }
        }
    }
}
