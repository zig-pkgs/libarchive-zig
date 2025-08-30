const PrivateData = struct {
    pub const out_block_size = 64 * 1024;

    gpa: mem.Allocator,
    compress: std.compress.xz.Decompress,
    reader: Filter.Reader,
    writer: std.Io.Writer,

    pub fn init(handle: *c.archive_read_filter, gpa: mem.Allocator) !*PrivateData {
        const buffer = try gpa.alloc(u8, out_block_size);
        errdefer gpa.free(buffer);
        const private_data = try gpa.create(PrivateData);
        errdefer gpa.destroy(private_data);

        private_data.* = .{
            .gpa = gpa,
            .writer = .fixed(buffer),
            .reader = .init(.{ .handle = handle }),
            .compress = undefined,
        };
        private_data.compress = try .init(&private_data.reader.interface, gpa, &.{});

        return private_data;
    }

    pub fn deinit(self: *PrivateData) void {
        const gpa = self.gpa;
        self.compress.deinit();
        gpa.free(self.writer.buffer);
        gpa.destroy(self);
    }
};

export fn archive_read_support_format_rar5(a: [*c]c.archive) c_int {
    _ = a;
    return c.ARCHIVE_FATAL;
}

fn archive_read_support_compression_xz(a: [*c]c.archive) callconv(.c) c_int {
    return archive_read_support_filter_xz(a);
}

fn archive_read_support_compression_lzip(a: [*c]c.archive) callconv(.c) c_int {
    return archive_read_support_filter_lzip(a);
}

fn archive_read_support_compression_lzma(a: [*c]c.archive) callconv(.c) c_int {
    return archive_read_support_filter_lzma(a);
}

fn xzBidderBid(
    self: [*c]c.archive_read_filter_bidder,
    filter: [*c]c.archive_read_filter,
) callconv(.c) c_int {
    _ = self;
    var f: Filter = .{ .handle = filter };
    const data = f.read(6) catch return 0;
    if (data.len < 6) return 0;
    if (!mem.eql(u8, data[0..6], "\xFD\x37\x7A\x58\x5A\x00")) {
        return 0;
    }
    return 48;
}

fn xzBidderInit(self: [*c]c.archive_read_filter) callconv(.c) c_int {
    self.*.code = c.ARCHIVE_FILTER_XZ;
    self.*.name = "xz";
    self.*.vtable = &xz_read_vtable;
    self.*.data = PrivateData.init(self, std.heap.c_allocator) catch {
        return -1;
    };
    return c.ARCHIVE_OK;
}

const xz_bidder_vtable: c.archive_read_filter_bidder_vtable = .{
    .bid = &xzBidderBid,
    .init = &xzBidderInit,
};

fn xzFilterRead(self: [*c]c.archive_read_filter, p: [*c]?*const anyopaque) callconv(.c) isize {
    var data: *PrivateData = @ptrCast(@alignCast(self.*.data));
    var offset: usize = 0;
    _ = data.writer.consumeAll();
    offset += data.compress.reader.stream(&data.writer, .unlimited) catch |err| switch (err) {
        error.WriteFailed, error.EndOfStream => 0,
        else => |e| {
            std.log.err("{t}", .{e});
            return c.ARCHIVE_FAILED;
        },
    };
    data.writer.flush() catch unreachable;
    if (offset == 0) {
        p.* = null;
    } else {
        p.* = data.writer.buffer.ptr;
    }
    return @intCast(offset);
}

fn xzFilterClose(self: [*c]c.archive_read_filter) callconv(.c) c_int {
    var data: *PrivateData = @ptrCast(@alignCast(self.*.data));
    data.deinit();
    return c.ARCHIVE_OK;
}

const xz_read_vtable: c.archive_read_filter_vtable = .{
    .read = &xzFilterRead,
    .close = &xzFilterClose,
};

export fn archive_read_support_filter_xz(_a: [*c]c.archive) c_int {
    const a: [*c]c.archive_read = @ptrCast(@alignCast(_a));
    if (c.__archive_read_register_bidder(
        a,
        null,
        "xz",
        &xz_bidder_vtable,
    ) != c.ARCHIVE_OK)
        return c.ARCHIVE_FATAL;

    return c.ARCHIVE_OK;
}

export fn archive_read_support_filter_lzip(_a: [*c]c.archive) c_int {
    _ = _a;
    return c.ARCHIVE_FATAL;
}

export fn archive_read_support_filter_lzma(_a: [*c]c.archive) c_int {
    _ = _a;
    return c.ARCHIVE_FATAL;
}

comptime {
    if (c.ARCHIVE_VERSION_NUMBER < 4000000) {
        @export(&archive_read_support_compression_xz, .{
            .name = "archive_read_support_compression_xz",
        });
        @export(&archive_read_support_compression_lzip, .{
            .name = "archive_read_support_compression_lzip",
        });
        @export(&archive_read_support_compression_lzma, .{
            .name = "archive_read_support_compression_lzma",
        });
    }
}

const std = @import("std");
const mem = std.mem;
const Filter = @import("Filter.zig");
const c = @import("c");
