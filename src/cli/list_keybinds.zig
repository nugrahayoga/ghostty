const std = @import("std");
const builtin = @import("builtin");
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const Arena = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const configpkg = @import("../config.zig");
const Config = configpkg.Config;
const vaxis = @import("vaxis");
const input = @import("../input.zig");
const tui = @import("tui.zig");
const Binding = input.Binding;

pub const Options = struct {
    /// If `true`, print out the default keybinds instead of the ones configured
    /// in the config file.
    default: bool = false,

    /// If `true`, print out documentation about the action associated with the
    /// keybinds.
    docs: bool = false,

    /// If `true`, print without formatting even if printing to a tty
    plain: bool = false,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `list-keybinds` command is used to list all the available keybinds for
/// Ghostty.
///
/// When executed without any arguments this will list the current keybinds
/// loaded by the config file. If no config file is found or there aren't any
/// changes to the keybinds it will print out the default ones configured for
/// Ghostty
///
/// Flags:
///
///   * `--default`: will print out all the default keybinds
///
///   * `--docs`: currently does nothing, intended to print out documentation
///     about the action associated with the keybinds
///
///   * `--plain`: will disable formatting and make the output more
///     friendly for Unix tooling. This is default when not printing to a tty.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    var config = if (opts.default) try Config.default(alloc) else try Config.load(alloc);
    defer config.deinit();

    var buffer: [1024]u8 = undefined;
    const stdout: std.fs.File = .stdout();
    var stdout_writer = stdout.writer(&buffer);
    const writer = &stdout_writer.interface;

    if (tui.can_pretty_print and !opts.plain and stdout.isTty()) {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        return prettyPrint(arena.allocator(), config.keybind);
    } else {
        try config.keybind.formatEntryDocs(
            configpkg.entryFormatter("keybind", writer),
            opts.docs,
        );
    }

    // Don't forget to flush!
    try writer.flush();
    return 0;
}

const TriggerNode = struct {
    data: Binding.Trigger,
    node: std.SinglyLinkedList.Node = .{},

    pub fn get(node: *std.SinglyLinkedList.Node) *TriggerNode {
        return @fieldParentPtr("node", node);
    }
};

const ChordBinding = struct {
    triggers: std.SinglyLinkedList,
    action: Binding.Action,

    // Order keybinds based on various properties
    //    1. Longest chord sequence
    //    2. Most active modifiers
    //    3. Alphabetically by active modifiers
    //    4. Trigger key order
    // These properties propagate through chorded keypresses
    //
    // Adapted from Binding.lessThan
    pub fn lessThan(_: void, lhs: ChordBinding, rhs: ChordBinding) bool {
        const lhs_len = lhs.triggers.len();
        const rhs_len = rhs.triggers.len();

        std.debug.assert(lhs_len != 0);
        std.debug.assert(rhs_len != 0);

        if (lhs_len != rhs_len) {
            return lhs_len > rhs_len;
        }

        const lhs_count: usize = blk: {
            var count: usize = 0;
            var maybe_trigger = lhs.triggers.first;
            while (maybe_trigger) |node| : (maybe_trigger = node.next) {
                const trigger: *TriggerNode = .get(node);
                if (trigger.data.mods.super) count += 1;
                if (trigger.data.mods.ctrl) count += 1;
                if (trigger.data.mods.shift) count += 1;
                if (trigger.data.mods.alt) count += 1;
            }
            break :blk count;
        };
        const rhs_count: usize = blk: {
            var count: usize = 0;
            var maybe_trigger = rhs.triggers.first;
            while (maybe_trigger) |node| : (maybe_trigger = node.next) {
                const trigger: *TriggerNode = .get(node);
                if (trigger.data.mods.super) count += 1;
                if (trigger.data.mods.ctrl) count += 1;
                if (trigger.data.mods.shift) count += 1;
                if (trigger.data.mods.alt) count += 1;
            }

            break :blk count;
        };

        if (lhs_count != rhs_count)
            return lhs_count > rhs_count;

        {
            var l_trigger = lhs.triggers.first;
            var r_trigger = rhs.triggers.first;
            while (l_trigger != null and r_trigger != null) {
                const l_int = TriggerNode.get(l_trigger.?).data.mods.int();
                const r_int = TriggerNode.get(r_trigger.?).data.mods.int();

                if (l_int != r_int) {
                    return l_int > r_int;
                }

                l_trigger = l_trigger.?.next;
                r_trigger = r_trigger.?.next;
            }
        }

        var l_trigger = lhs.triggers.first;
        var r_trigger = rhs.triggers.first;

        while (l_trigger != null and r_trigger != null) {
            const lhs_key: c_int = blk: {
                switch (TriggerNode.get(l_trigger.?).data.key) {
                    .physical => |key| break :blk @intFromEnum(key),
                    .unicode => |key| break :blk @intCast(key),
                }
            };
            const rhs_key: c_int = blk: {
                switch (TriggerNode.get(r_trigger.?).data.key) {
                    .physical => |key| break :blk @intFromEnum(key),
                    .unicode => |key| break :blk @intCast(key),
                }
            };

            l_trigger = l_trigger.?.next;
            r_trigger = r_trigger.?.next;

            if (l_trigger == null or r_trigger == null) {
                return lhs_key < rhs_key;
            }

            if (lhs_key != rhs_key) {
                return lhs_key < rhs_key;
            }
        }

        // The previous loop will always return something on its final iteration so we cannot
        // reach this point
        unreachable;
    }
};

fn prettyPrint(alloc: Allocator, keybinds: Config.Keybinds) !u8 {
    // Set up vaxis
    var buf: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(&buf);
    defer tty.deinit();
    var vx = try vaxis.init(alloc, .{});
    const writer = tty.writer();
    defer vx.deinit(alloc, writer);

    // We know we are ghostty, so let's enable mode 2027. Vaxis normally does this but you need an
    // event loop to auto-enable it.
    vx.caps.unicode = .unicode;
    try writer.writeAll(vaxis.ctlseqs.unicode_set);
    defer writer.writeAll(vaxis.ctlseqs.unicode_reset) catch {};

    const winsize: vaxis.Winsize = switch (builtin.os.tag) {
        // We use some default, it doesn't really matter for what
        // we're doing because we don't do any wrapping.
        .windows => .{
            .rows = 24,
            .cols = 120,
            .x_pixel = 1024,
            .y_pixel = 768,
        },

        else => try vaxis.Tty.getWinsize(tty.fd),
    };
    try vx.resize(alloc, writer, winsize);

    const win = vx.window();

    // Generate a list of bindings, recursively traversing chorded keybindings
    var iter = keybinds.set.bindings.iterator();
    const bindings, const widest_chord = try iterateBindings(alloc, &iter, &win);

    std.mem.sort(ChordBinding, bindings, {}, ChordBinding.lessThan);

    // Set up styles for each modifier
    const super_style: vaxis.Style = .{ .fg = .{ .index = 1 } };
    const ctrl_style: vaxis.Style = .{ .fg = .{ .index = 2 } };
    const alt_style: vaxis.Style = .{ .fg = .{ .index = 3 } };
    const shift_style: vaxis.Style = .{ .fg = .{ .index = 4 } };

    // Print the list
    for (bindings) |bind| {
        win.clear();

        var result: vaxis.Window.PrintResult = .{ .col = 0, .row = 0, .overflow = false };
        var maybe_trigger = bind.triggers.first;
        while (maybe_trigger) |node| : (maybe_trigger = node.next) {
            const trigger: *TriggerNode = .get(node);

            if (trigger.data.mods.super) {
                result = win.printSegment(.{ .text = "super", .style = super_style }, .{ .col_offset = result.col });
                result = win.printSegment(.{ .text = " + " }, .{ .col_offset = result.col });
            }
            if (trigger.data.mods.ctrl) {
                result = win.printSegment(.{ .text = "ctrl ", .style = ctrl_style }, .{ .col_offset = result.col });
                result = win.printSegment(.{ .text = " + " }, .{ .col_offset = result.col });
            }
            if (trigger.data.mods.alt) {
                result = win.printSegment(.{ .text = "alt  ", .style = alt_style }, .{ .col_offset = result.col });
                result = win.printSegment(.{ .text = " + " }, .{ .col_offset = result.col });
            }
            if (trigger.data.mods.shift) {
                result = win.printSegment(.{ .text = "shift", .style = shift_style }, .{ .col_offset = result.col });
                result = win.printSegment(.{ .text = " + " }, .{ .col_offset = result.col });
            }
            const key = switch (trigger.data.key) {
                .physical => |k| try std.fmt.allocPrint(alloc, "{t}", .{k}),
                .unicode => |c| try std.fmt.allocPrint(alloc, "{u}", .{c}),
            };
            result = win.printSegment(.{ .text = key }, .{ .col_offset = result.col });

            // Print a separator between chorded keys
            if (trigger.node.next != null) {
                result = win.printSegment(.{ .text = "  >  ", .style = .{ .bold = true, .fg = .{ .index = 6 } } }, .{ .col_offset = result.col });
            }
        }

        const action = try std.fmt.allocPrint(alloc, "{f}", .{bind.action});
        // If our action has an argument, we print the argument in a different color
        if (std.mem.indexOfScalar(u8, action, ':')) |idx| {
            _ = win.print(&.{
                .{ .text = action[0..idx] },
                .{ .text = action[idx .. idx + 1], .style = .{ .dim = true } },
                .{ .text = action[idx + 1 ..], .style = .{ .fg = .{ .index = 5 } } },
            }, .{ .col_offset = widest_chord + 3 });
        } else {
            _ = win.printSegment(.{ .text = action }, .{ .col_offset = widest_chord + 3 });
        }
        try vx.prettyPrint(writer);
    }
    try writer.flush();
    return 0;
}

fn iterateBindings(
    alloc: Allocator,
    iter: anytype,
    win: *const vaxis.Window,
) !struct { []ChordBinding, u16 } {
    var widest_chord: u16 = 0;
    var bindings: std.ArrayList(ChordBinding) = .empty;
    while (iter.next()) |bind| {
        const width = blk: {
            var buf: std.Io.Writer.Allocating = .init(alloc);
            const t = bind.key_ptr.*;

            if (t.mods.super) try buf.writer.print("super + ", .{});
            if (t.mods.ctrl) try buf.writer.print("ctrl  + ", .{});
            if (t.mods.alt) try buf.writer.print("alt   + ", .{});
            if (t.mods.shift) try buf.writer.print("shift + ", .{});

            switch (t.key) {
                .physical => |k| try buf.writer.print("{t}", .{k}),
                .unicode => |c| try buf.writer.print("{u}", .{c}),
            }

            break :blk win.gwidth(buf.written());
        };

        switch (bind.value_ptr.*) {
            .leader => |leader| {

                // Recursively iterate on the set of bindings for this leader key
                var n_iter = leader.bindings.iterator();
                const sub_bindings, const max_width = try iterateBindings(alloc, &n_iter, win);

                // Prepend the current keybind onto the list of sub-binds
                for (sub_bindings) |*nb| {
                    const prepend_node = try alloc.create(TriggerNode);
                    prepend_node.* = .{ .data = bind.key_ptr.* };
                    nb.triggers.prepend(&prepend_node.node);
                }

                // Add the longest sub-bind width to the current bind width along with a padding
                // of 5 for the '  >  ' spacer
                widest_chord = @max(widest_chord, width + max_width + 5);
                try bindings.appendSlice(alloc, sub_bindings);
            },
            .leaf => |leaf| {
                const node = try alloc.create(TriggerNode);
                node.* = .{ .data = bind.key_ptr.* };

                widest_chord = @max(widest_chord, width);
                try bindings.append(alloc, .{
                    .triggers = .{ .first = &node.node },
                    .action = leaf.action,
                });
            },
        }
    }

    return .{ try bindings.toOwnedSlice(alloc), widest_chord };
}
