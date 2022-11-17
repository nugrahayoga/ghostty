const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");

/// The messages that can be sent to an IO thread.
///
/// This is not a tiny structure (~40 bytes at the time of writing this comment),
/// but the messages are IO thread sends are also very few. At the current size
/// we can queue 26,000 messages before consuming a MB of RAM.
pub const Message = union(enum) {
    /// Represents a write request. Magic number comes from the largest
    /// other union value. It can be upped if we add a larger union member
    /// in the future.
    pub const WriteReq = MessageData(u8, 38);

    /// Resize the window.
    resize: struct {
        /// The grid size for the given screen size with padding applied.
        grid_size: renderer.GridSize,

        /// The full screen (drawable) size. This does NOT include padding.
        /// This should be sent on to the renderer.
        screen_size: renderer.ScreenSize,

        /// The padding, so that the terminal implementation can subtract
        /// this to send to the pty.
        padding: renderer.Padding,
    },

    /// Write where the data fits in the union.
    write_small: WriteReq.Small,

    /// Write where the data pointer is stable.
    write_stable: WriteReq.Stable,

    /// Write where the data is allocated and must be freed.
    write_alloc: WriteReq.Alloc,

    /// Return a write request for the given data. This will use
    /// write_small if it fits or write_alloc otherwise. This should NOT
    /// be used for stable pointers which can be manually set to write_stable.
    pub fn writeReq(alloc: Allocator, data: anytype) !Message {
        return switch (try WriteReq.init(alloc, data)) {
            .stable => unreachable,
            .small => |v| Message{ .write_small = v },
            .alloc => |v| Message{ .write_alloc = v },
        };
    }
};

/// Creates a union that can be used to accomodate data that fit within an array,
/// are a stable pointer, or require deallocation. This is helpful for thread
/// messaging utilities.
pub fn MessageData(comptime Elem: type, comptime small_size: comptime_int) type {
    return union(enum) {
        pub const Self = @This();

        pub const Small = struct {
            pub const Max = small_size;
            pub const Array = [Max]Elem;
            data: Array,
            len: u8,
        };

        pub const Alloc = struct {
            alloc: Allocator,
            data: []Elem,
        };

        pub const Stable = []const Elem;

        /// A small write where the data fits into this union size.
        small: Small,

        /// A stable pointer so we can just pass the slice directly through.
        /// This is useful i.e. for const data.
        stable: Stable,

        /// Allocated and must be freed with the provided allocator. This
        /// should be rarely used.
        alloc: Alloc,

        /// Initializes the union for a given data type. This will
        /// attempt to fit into a small value if possible, otherwise
        /// will allocate and put into alloc.
        ///
        /// This can't and will never detect stable pointers.
        pub fn init(alloc: Allocator, data: anytype) !Self {
            switch (@typeInfo(@TypeOf(data))) {
                .Pointer => |info| {
                    assert(info.size == .Slice);
                    assert(info.child == Elem);

                    // If it fits in our small request, do that.
                    if (data.len <= Small.Max) {
                        var buf: Small.Array = undefined;
                        std.mem.copy(Elem, &buf, data);
                        return Self{
                            .small = .{
                                .data = buf,
                                .len = @intCast(u8, data.len),
                            },
                        };
                    }

                    // Otherwise, allocate
                    var buf = try alloc.dupe(Elem, data);
                    errdefer alloc.free(buf);
                    return Self{
                        .alloc = .{
                            .alloc = alloc,
                            .data = buf,
                        },
                    };
                },

                else => unreachable,
            }
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}

test {
    // Ensure we don't grow our IO message size without explicitly wanting to.
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 40), @sizeOf(Message));
}

test "MessageData init small" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Data = MessageData(u8, 10);
    const input = "hello!";
    const io = try Data.init(alloc, @as([]const u8, input));
    try testing.expect(io == .small);
}

test "MessageData init alloc" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Data = MessageData(u8, 10);
    const input = "hello! " ** 100;
    const io = try Data.init(alloc, @as([]const u8, input));
    try testing.expect(io == .alloc);
    io.alloc.alloc.free(io.alloc.data);
}