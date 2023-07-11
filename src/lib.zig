const std = @import("std");

// TODO: abstract raylib away to allow for consumers to use whatever they want.
// I'm also rexporting here because the zig build system hurts
pub const raylib = @import("raylib");
pub const components = @import("components.zig");

pub const UIContext = struct {
    const Self = @This();
    const scroll_speed: f32 = 1.125;

    box_allocator: std.mem.Allocator,

    // Double-buffered allocator to hold per-frame heap-data
    current_frame_allocator: usize = 0,
    frame_allocators: [2]std.heap.ArenaAllocator,

    root_box: ?*UI_Box = null,
    current_box: ?*UI_Box = null,
    current_style: std.ArrayList(UI_Style) = undefined,

    hot: ?*UI_Box = null,
    active: ?*UI_Box = null,

    pushing_box: bool = false,
    popping_box: bool = false,

    // PLEASE DON'T DO THIS
    font20: raylib.Font = undefined,
    font10: raylib.Font = undefined,

    // TODO: do this better
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    mouse_scroll: f32 = 0,
    mouse_released: bool = false,
    mouse_hovering_clickable: bool = false,

    pub fn init(allocator: std.mem.Allocator, font20: raylib.Font, font10: raylib.Font) Self {
        return .{
            .box_allocator = allocator,
            .frame_allocators = .{
                std.heap.ArenaAllocator.init(allocator),
                std.heap.ArenaAllocator.init(allocator),
            },
            .current_style = std.ArrayList(UI_Style).init(allocator),
            .font20 = font20,
            .font10 = font10,
        };
    }

    fn frame_allocator(self: *Self) std.mem.Allocator {
        return self.frame_allocators[self.current_frame_allocator].allocator();
    }

    fn swap_frame_allocators(self: *Self) void {
        self.current_frame_allocator = (self.current_frame_allocator + 1) % self.frame_allocators.len;
    }

    pub fn NewFrame(self: *Self, width: i32, height: i32, mouse_x: i32, mouse_y: i32, mouse_scroll: f32, mouse_released: bool) !void {
        self.current_box = self.root_box;
        self.pushing_box = false;
        self.popping_box = false;
        self.mouse_hovering_clickable = false;
        self.current_style.clearRetainingCapacity();
        // TODO: really shouldn't be necessary?
        try self.current_style.append(.{});

        if (self.root_box) |box| {
            box.computed_size.x = @floatFromInt(width);
            box.computed_size.y = @floatFromInt(height);
        }

        self.mouse_x = mouse_x;
        self.mouse_y = mouse_y;
        self.mouse_scroll = mouse_scroll;
        self.mouse_released = mouse_released;

        //std.debug.print("frame allocator[0] capacity: {d} - ", .{self.frame_allocators[0].queryCapacity()});
        //std.debug.print("frame allocator[1] capacity: {d}\n", .{self.frame_allocators[1].queryCapacity()});
        _ = self.frame_allocators[self.current_frame_allocator].reset(.{ .retain_with_limit = 500_000 });
    }

    fn CountChildren(box: *UI_Box) u32 {
        var count: u32 = 0;
        var b = box.first;

        while (b) |child| {
            count += 1;

            // TODO: um, somehow need to trim stale tree nodes
            if (b == box.last) break;
            b = child.next;
        }

        return count;
    }

    fn CountSiblings(box: *UI_Box) u32 {
        var count: u32 = 0;
        var b = box;
        if (b.parent) |p| {
            if (b == p.last) return 0;
        }

        while (b.next) |next| {
            count += 1;

            if (b.parent) |p| {
                if (b == p.last) {
                    break;
                }
            }

            b = next;
        }

        return count;
    }

    fn TestBoxHover(self: *Self, box: *UI_Box) bool {
        return @as(f32, @floatFromInt(self.mouse_x)) >= box.computed_pos.x and @as(f32, @floatFromInt(self.mouse_x)) <= box.computed_pos.x + box.computed_size.x and @as(f32, @floatFromInt(self.mouse_y)) >= box.computed_pos.y and @as(f32, @floatFromInt(self.mouse_y)) <= box.computed_pos.y + box.computed_size.y;
    }

    fn TestBoxClick(self: *Self, box: *UI_Box) bool {
        return self.mouse_released and self.TestBoxHover(box);
    }

    fn ScrollBox(self: *Self, box: *UI_Box) void {
        if (self.TestBoxHover(box)) {
            if (box.scroll_top == null) {
                box.scroll_top = box.first;
            }

            if (box.scroll_top) |top| {
                if ((self.mouse_scroll > 0 and top.prev != null) or (self.mouse_scroll < 0 and top.next != null) or box.scroll_fract != 0) {
                    box.scroll_fract -= self.mouse_scroll * scroll_speed;
                }
            }

            const n = std.math.modf(box.scroll_fract);
            box.scroll_fract = n.fpart;

            if (n.ipart > 0) {
                var index = n.ipart;
                var child = box.scroll_top;
                while (child) |c| {
                    if (index <= 0) break;

                    if (c.next) |next| {
                        child = next;
                    }

                    index -= 1;
                }

                box.scroll_top = child;
            } else if (box.scroll_fract < 0.0) {
                box.scroll_fract = 1 + box.scroll_fract;

                var index = -n.ipart;
                var child = box.scroll_top;
                while (child) |c| {
                    if (c.prev) |prev| {
                        child = prev;
                    }

                    if (index <= 0) break;

                    index -= 1;
                }

                box.scroll_top = child;
            }
        }
    }

    fn TestBoxInteraction(self: *Self, box: *UI_Box) bool {
        if (box.flags.clickable) {
            return self.TestBoxClick(box);
        }
        if (box.flags.scrollable) {
            self.ScrollBox(box);
        }

        return false;
    }

    pub fn DeleteBoxChildren(self: *Self, box: *UI_Box, should_destroy: bool) void {
        var child = box.first;
        while (child) |c| {
            child = c.next;
            self.DeleteBoxChildren(c, true);
        }

        if (should_destroy) {
            self.box_allocator.destroy(box);
        }
    }

    pub fn MakeBox(self: *Self, str: []const u8, flags: UI_Flags, direction: UI_Direction, layout: UI_Layout) anyerror!bool {
        const label = try std.fmt.allocPrintZ(self.frame_allocator(), "{s}", .{str});
        return try self._MakeBox(label, flags, direction, layout);
    }

    pub fn PushBox(self: *Self, str: []const u8, flags: UI_Flags, direction: UI_Direction, layout: UI_Layout) anyerror!bool {
        const label = try std.fmt.allocPrintZ(self.frame_allocator(), "{s}", .{str});
        return try self._PushBox(label, flags, direction, layout);
    }

    // TODO: remove all footguns by compressing code
    fn _MakeBox(self: *Self, label: [:0]const u8, flags: UI_Flags, direction: UI_Direction, layout: UI_Layout) anyerror!bool {
        //std.debug.print("making box '{s}'...", .{label});

        // TODO: Please remove this state machine, there should be a way to do it without it
        self.popping_box = false;

        if (self.pushing_box) {
            const box = try self._PushBox(label, flags, direction, layout);
            self.pushing_box = false;

            return box;
        }

        if (self.current_box) |box| {
            if (box.next) |next| {
                // Attempt to re-use cache
                if (std.mem.eql(u8, next.label, label)) {
                    //std.debug.print("using cache for '{s}'\n", .{next.label});
                    next.flags = flags;
                    next.direction = direction;
                    next.label = @constCast(label);
                    if (next.parent) |parent| {
                        parent.last = next;
                    }
                    self.current_box = next;
                } else {
                    // Invalid cache, delete next sibling while retaining the following one
                    //std.debug.print("make_box: invalidating cache for '{s}' when making new box '{s}'\n", .{ next.label, label });
                    const following_sibling = next.next;
                    self.DeleteBoxChildren(next, false);

                    next.* = UI_Box{
                        .label = @constCast(label),
                        .flags = flags,
                        .direction = direction,
                        .style = self.current_style.getLast(),
                        .layout = layout,

                        .first = null,
                        .last = null,
                        .next = following_sibling,
                        .prev = box,
                        .parent = box.parent,
                        .computed_pos = Vec2{ .x = 0, .y = 0 },
                        .computed_size = Vec2{ .x = 0, .y = 0 },
                    };

                    self.current_box = next;
                    if (next.parent) |parent| {
                        parent.last = next;
                    }
                }
            } else {
                // No existing cache, create new box
                //std.debug.print("make_box: allocating new box: {s}\n", .{label});
                var new_box = try self.box_allocator.create(UI_Box);
                new_box.* = UI_Box{
                    .label = @constCast(label),
                    .flags = flags,
                    .direction = direction,
                    .style = self.current_style.getLast(),
                    .layout = layout,

                    .first = null,
                    .last = null,
                    .next = null,
                    .prev = box,
                    .parent = box.parent,
                    .computed_pos = Vec2{ .x = 0, .y = 0 },
                    .computed_size = Vec2{ .x = 0, .y = 0 },
                };

                box.next = new_box;
                self.current_box = new_box;
                if (new_box.parent) |parent| {
                    parent.last = new_box;
                }
            }
        } else {
            //std.debug.print("make_box: allocating new box: {s}\n", .{label});
            var new_box = try self.box_allocator.create(UI_Box);
            new_box.* = UI_Box{
                .label = @constCast(label),
                .flags = flags,
                .direction = direction,
                .style = self.current_style.getLast(),
                .layout = layout,

                .first = null,
                .last = null,
                .next = null,
                .prev = null,
                .parent = null,
                .computed_pos = Vec2{ .x = 0, .y = 0 },
                .computed_size = Vec2{ .x = 0, .y = 0 },
            };

            self.current_box = new_box;
        }

        if (self.current_box) |box| {
            return self.TestBoxInteraction(box);
        }

        return false;
    }

    pub fn _PushBox(self: *Self, label: [:0]const u8, flags: UI_Flags, direction: UI_Direction, layout: UI_Layout) anyerror!bool {
        //std.debug.print("pushing box '{s}'...", .{label});

        // TODO: Please remove this state machine, there should be a way to do it without it
        if (self.popping_box) {
            const box = try self._MakeBox(label, flags, direction, layout);
            self.pushing_box = true;

            return box;
        }
        if (!self.pushing_box) {
            self.pushing_box = true;
        }

        if (self.current_box) |box| {
            // Attempt to re-use cache
            if (box.first) |first| {
                // check if the same
                if (std.mem.eql(u8, first.label, label)) {
                    //std.debug.print("using cache for '{s}'\n", .{first.label});
                    first.flags = flags;
                    first.direction = direction;
                    first.label = @constCast(label);
                    self.current_box = first;

                    if (first.parent) |parent| {
                        parent.last = first;
                    }
                } else {
                    // Invalid cache
                    //std.debug.print("push_box: invalidating cache for '{s}' when making new box '{s}'\n", .{ first.label, label });
                    const following_sibling = first.next;
                    self.DeleteBoxChildren(first, false);

                    first.* = UI_Box{
                        .label = @constCast(label),
                        .flags = flags,
                        .direction = direction,
                        .style = self.current_style.getLast(),
                        .layout = layout,

                        .first = null,
                        .last = null,
                        .next = following_sibling,
                        .prev = null,
                        .parent = self.current_box,
                        .computed_pos = Vec2{ .x = 0, .y = 0 },
                        .computed_size = Vec2{ .x = 0, .y = 0 },
                    };

                    self.current_box = first;
                    if (first.parent) |parent| {
                        parent.last = first;
                    }
                }
            } else {
                //std.debug.print("push_box: allocating new box: {s}\n", .{label});
                var new_box = try self.box_allocator.create(UI_Box);
                new_box.* = UI_Box{
                    .label = @constCast(label),
                    .flags = flags,
                    .direction = direction,
                    .style = self.current_style.getLast(),
                    .layout = layout,

                    .first = null,
                    .last = null,
                    .next = null,
                    .prev = null,
                    .parent = self.current_box,
                    .computed_pos = Vec2{ .x = 0, .y = 0 },
                    .computed_size = Vec2{ .x = 0, .y = 0 },
                };

                box.first = new_box;
                self.current_box = new_box;
                if (new_box.parent) |parent| {
                    parent.last = new_box;
                }
            }
        } else {
            self.pushing_box = false;
            return try self._MakeBox(label, flags, direction, layout);
        }

        if (self.current_box) |box| {
            return self.TestBoxInteraction(box);
        }

        return false;
    }

    pub fn PopBox(self: *Self) void {
        //std.debug.print("popping box...", .{});
        if (self.current_box) |box| {
            //if (box.parent) |parent| {
            //current_box = parent.last;
            //return;
            //}
            if (box.parent) |p| {
                p.last = self.current_box;
            }
            self.current_box = box.parent;
            self.popping_box = true;
            return;
        }

        //std.debug.print("couldn't pop box\n", .{});
    }

    pub fn PushStyle(self: *Self, style: UI_Style) !void {
        try self.current_style.append(style);
    }

    pub fn PopStyle(self: *Self) void {
        _ = self.current_style.popOrNull();
    }

    pub fn MakeButtonWithLayout(self: *Self, str: []const u8, layout: UI_Layout) !bool {
        // TODO: replace with frame allocator
        const label = try std.fmt.allocPrintZ(self.frame_allocator(), "{s}", .{str});
        return try self._MakeBox(label, .{
            .clickable = true,
            .hoverable = true,
            .drawText = true,
            .drawBackground = true,
        }, .leftToRight, layout);
    }

    pub fn MakeButton(self: *Self, label: []const u8) !bool {
        return try self.MakeButtonWithLayout(label, .fitToText);
    }

    pub fn MakeFormattedLabelWithLayout(self: *Self, comptime str: []const u8, args: anytype, layout: UI_Layout) !void {
        // TODO: replace with frame allocator
        const label = try std.fmt.allocPrintZ(self.frame_allocator(), str, args);
        _ = try self._MakeBox(label, .{
            .drawText = true,
        }, .leftToRight, layout);
    }

    pub fn MakeLabelWithLayout(self: *Self, str: []const u8, layout: UI_Layout) !void {
        // TODO: replace with frame allocator
        const label = try std.fmt.allocPrintZ(self.frame_allocator(), "{s}", .{str});
        _ = try self._MakeBox(label, .{
            .drawText = true,
        }, .leftToRight, layout);
    }

    pub fn MakeLabelInt(self: *Self, value: anytype) !void {
        // TODO: replace with frame allocator
        const label = try std.fmt.allocPrintZ(self.frame_allocator(), "{d}", .{value});
        _ = try self.MakeLabelWithLayout(label, .fitToText);
    }

    pub fn MakeLabel(self: *Self, str: []const u8) !void {
        // TODO: replace with frame allocator
        const label = try std.fmt.allocPrintZ(self.frame_allocator(), "{s}", .{str});
        _ = try self.MakeLabelWithLayout(label, .fitToText);
    }

    fn ComputeChildrenSize(box: *UI_Box) Vec2 {
        var total_size = Vec2{ .x = 0, .y = 0 };

        // TODO: make this block an iterator
        const children = CountChildren(box);
        if (children > 0) {
            var child = box.first;
            while (child) |c| {
                const child_size = ComputeLayout(c);

                switch (box.direction) {
                    .leftToRight => {
                        total_size.x += child_size.x;

                        // only grab max size for this direction
                        if (child_size.y > total_size.y) {
                            total_size.y = child_size.y;
                        }
                    },
                    .topToBottom => {
                        total_size.y += child_size.y;

                        // only grab max size for this direction
                        if (child_size.x > total_size.x) {
                            total_size.x = child_size.x;
                        }
                    },
                    .rightToLeft, .bottomToTop => {},
                }

                if (child == box.last) break;

                child = c.next;
            }
        }

        return total_size;
    }

    fn ComputeSiblingSize(box: *UI_Box) Vec2 {
        // TODO: get _all_ sibling sizes
        //       (not just the _next_ ones, but also don't forget to not infinitly recurse)
        // get siblings size so we know to big to get
        var total_sibling_size = Vec2{ .x = 0, .y = 0 };
        var n = box.next;

        const direction = if (box.parent) |p| p.direction else box.direction;
        while (n) |next| {
            const sibling_size = ComputeLayout(next);

            switch (direction) {
                .leftToRight => {
                    total_sibling_size.x += sibling_size.x;
                    if (sibling_size.y > total_sibling_size.y) {
                        total_sibling_size.y = sibling_size.y;
                    }
                },
                .topToBottom => {
                    total_sibling_size.y += sibling_size.y;
                    if (sibling_size.x > total_sibling_size.x) {
                        total_sibling_size.x = sibling_size.x;
                    }
                },
                .rightToLeft, .bottomToTop => {},
            }

            if (box.parent) |p| {
                if (next == p.last) break;
            }

            n = next.next;
        }

        return total_sibling_size;
    }

    pub fn ComputeLayout(box: *UI_Box) Vec2 {
        if (box.parent) |p| {
            box.computed_size = p.computed_size;

            if (box.prev) |prev| {
                box.computed_pos = Vec2{ .x = switch (p.direction) {
                    .leftToRight => prev.computed_pos.x + prev.computed_size.x,
                    .topToBottom => prev.computed_pos.x,
                    .rightToLeft, .bottomToTop => unreachable,
                }, .y = switch (p.direction) {
                    .leftToRight => prev.computed_pos.y,
                    .topToBottom => prev.computed_pos.y + prev.computed_size.y,
                    .rightToLeft, .bottomToTop => unreachable,
                } };
            } else {
                box.computed_pos = p.computed_pos;
            }
        }

        var compute_children = blk: {
            switch (box.layout) {
                .fitToText => {
                    box.computed_size = Vec2{
                        .x = @floatFromInt(raylib.MeasureText(box.label, box.style.text_size) + box.style.text_padding * 2),
                        .y = @floatFromInt(box.style.text_size + box.style.text_padding * 2),
                    };

                    //_ = ComputeChildrenSize(box);
                    break :blk true;
                },
                .fitToChildren => {
                    // TODO: chicken before the egg :sigh:
                    box.computed_size = ComputeChildrenSize(box);
                    //box.computed_size = total_size;

                    break :blk false;
                },
                .fill => {
                    const total_sibling_size = ComputeSiblingSize(box);
                    if (box.parent) |p| {
                        if (p.layout == .fitToChildren) {
                            //box.layout = .fitToText;
                        }

                        if (std.mem.eql(u8, "GridContainer", box.label)) {
                            const calculated_size = p.computed_size.y - total_sibling_size.y - (box.computed_pos.y - p.computed_pos.y);
                            std.debug.print("Grid sibling size: {d}, {d}, '{s}'_height: {d}, calculated height: {d}\n", .{ total_sibling_size.x, total_sibling_size.y, p.label, p.computed_size.y, calculated_size });
                        }

                        box.computed_size = Vec2{
                            .x = switch (p.direction) {
                                .leftToRight => p.computed_size.x - total_sibling_size.x - (box.computed_pos.x - p.computed_pos.x),
                                .topToBottom => if (total_sibling_size.x == 0) p.computed_size.x else total_sibling_size.x,
                                //.topToBottom => 0, //p.computed_size.x,
                                .rightToLeft, .bottomToTop => unreachable,
                            },
                            .y = switch (p.direction) {
                                .leftToRight => if (total_sibling_size.y == 0) p.computed_size.y else total_sibling_size.y,
                                //.leftToRight => 0, //p.computed_size.y,
                                .topToBottom => p.computed_size.y - total_sibling_size.y - (box.computed_pos.y - p.computed_pos.y),
                                .rightToLeft, .bottomToTop => unreachable,
                            },
                        };
                    }

                    //_ = ComputeChildrenSize(box);
                    break :blk true;
                },
                .percentOfParent => |size| {
                    //const total_sibling_size = ComputeSiblingSize(box);

                    // TODO: fix chicken and egg problem of needing to know the parent's computed size
                    if (box.parent) |p| {
                        box.computed_size = Vec2{
                            .x = switch (p.direction) { //
                                .leftToRight => p.computed_size.x * size.x,
                                .topToBottom => p.computed_size.x, //if (total_sibling_size.x == 0) @floatFromInt(raylib.MeasureText(box.label, box.style.text_size) + box.style.text_padding * 2) else total_sibling_size.x,
                                .rightToLeft, .bottomToTop => unreachable,
                            },
                            .y = switch (p.direction) {
                                .leftToRight => @floatFromInt(box.style.text_size + box.style.text_padding * 2),
                                .topToBottom => p.computed_size.y * size.y,
                                .rightToLeft, .bottomToTop => unreachable,
                            },
                        };
                    }

                    //_ = ComputeChildrenSize(box);
                    break :blk true;
                },
                .exactSize => |size| {
                    box.computed_size = size;
                    break :blk true;
                },
                .floating => |layout| {
                    box.computed_pos = .{ .x = 0, .y = 0 };
                    switch (layout) {
                        .fitToText => {
                            box.computed_size = Vec2{
                                .x = @floatFromInt(raylib.MeasureText(box.label, box.style.text_size) + box.style.text_padding * 2),
                                .y = @floatFromInt(box.style.text_size + box.style.text_padding * 2),
                            };
                        },
                        .fitToChildren => {
                            box.computed_size = ComputeChildrenSize(box);
                        },
                        .exactSize => |size| {
                            box.computed_size = size;
                        },
                    }
                    _ = ComputeChildrenSize(box);

                    return .{ .x = 0, .y = 0 };
                },
            }
        };

        if (box.parent) |p| {
            if (p.scroll_top) |top| {
                if (box == top) {
                    // TODO: switch on direction
                    box.computed_pos.x = p.computed_pos.x;
                    box.computed_pos.y = p.computed_pos.y - p.scroll_fract * box.computed_size.y;
                }
                // TODO: figure check and egg problem
                //_ = ComputeChildrenSize(box);
                compute_children = true;
            }
        }

        // TODO: this is what is causing the columns to shrink, something to do with the parent size changing between the previous call in .fitToChildren and this one
        if (compute_children) {
            _ = ComputeChildrenSize(box);
        }

        return box.computed_size;
    }

    pub fn DrawUI(self: *Self, box: *UI_Box) void {
        const is_hovering = self.TestBoxHover(box);
        if (box.flags.clickable and is_hovering) {
            self.mouse_hovering_clickable = true;
        }

        const pos_x: i32 = @intFromFloat(box.computed_pos.x);
        const pos_y: i32 = @intFromFloat(box.computed_pos.y);

        if (box.layout != .floating) {
            if (box.parent) |p| {
                const parent_pos_x: i32 = @intFromFloat(p.computed_pos.x);
                const parent_pos_y: i32 = @intFromFloat(p.computed_pos.y);
                const parent_size_x: i32 = @intFromFloat(p.computed_size.x);
                const parent_size_y: i32 = @intFromFloat(p.computed_size.y);

                raylib.BeginScissorMode(parent_pos_x, parent_pos_y, parent_size_x, parent_size_y);
            }
        }
        if (box.flags.drawBackground) {
            const color = if (box.flags.hoverable and is_hovering) box.style.hover_color else box.style.color;

            raylib.DrawRectangle( //
                pos_x, //
                pos_y, //
                @intFromFloat(box.computed_size.x), //
                @intFromFloat(box.computed_size.y), //
                color //
            );
        }
        if (box.flags.drawBorder) {
            raylib.DrawRectangleLines( //
                pos_x, //
                pos_y, //
                @intFromFloat(box.computed_size.x), //
                @intFromFloat(box.computed_size.y), //
                box.style.border_color //
            );
        }
        //  DrawTextEx(Font font, const char *text, Vector2 position, float fontSize, float spacing, Color tint)
        if (box.flags.drawText) {
            var bb: f32 = 0;
            var color: raylib.Color = box.style.text_color;
            if (box.parent) |p| {
                if (p.scroll_top != null and p.scroll_top == box) {
                    bb = 36;
                    color = raylib.RED;
                }
            }
            raylib.DrawTextEx( //
                if (box.style.text_size == 20) self.font20 else if (box.style.text_size == 12) self.font10 else self.font10, //
                box.label, //
                .{
                .x = box.computed_pos.x + @as(f32, @floatFromInt(box.style.text_padding)), //
                .y = box.computed_pos.y - bb + @as(f32, @floatFromInt(box.style.text_padding)), //
            }, //
                @as(f32, @floatFromInt(box.style.text_size)), //
                1.0, color //
            );
        }
        if (box.layout != .floating) {
            if (box.parent) |_| {
                raylib.EndScissorMode();
            }
        }

        // draw children
        const children = CountChildren(box);
        if (children > 0) {
            var child = blk: {
                if (box.flags.scrollable) {
                    if (box.scroll_top) |top| {
                        break :blk top;
                    }
                }

                break :blk box.first;
            };

            var child_size: f32 = 0;
            // TODO: replace with non-raylib function, also figure out why this doesn't clip text drawn with `DrawText`
            while (child) |c| {
                self.DrawUI(c);

                if (child == box.last) break;

                if (box.flags.scrollable) {
                    switch (box.direction) {
                        .leftToRight => {
                            child_size += c.computed_size.x;
                            // TODO: don't multiply this by two, use the last child size or something
                            if (child_size > box.computed_size.x + c.computed_size.x) break;
                        },
                        .rightToLeft, .bottomToTop => unreachable,
                        .topToBottom => {
                            child_size += c.computed_size.y;
                            // TODO: don't multiply this by two, use the last child size or something
                            if (child_size > box.computed_size.y + c.computed_size.y) break;
                        },
                    }
                }

                child = c.next;
            }
        }
    }

    pub fn Draw(self: *Self) void {
        if (self.root_box) |box| {
            _ = ComputeLayout(box);
            self.DrawUI(box);
        }

        self.swap_frame_allocators();
    }
};

pub const UI_Flags = packed struct {
    clickable: bool = false,
    hoverable: bool = false,
    scrollable: bool = false,
    drawText: bool = false,
    drawBorder: bool = false,
    drawBackground: bool = false,
};

pub const FloatingLayout = union(enum) {
    fitToText,
    fitToChildren,
    exactSize: Vec2,
};

pub const UI_Layout = union(enum) {
    fitToText,
    fitToChildren,
    fill,
    percentOfParent: Vec2,
    exactSize: Vec2,
    floating: FloatingLayout,
};

pub const UI_Direction = enum {
    leftToRight,
    rightToLeft,
    topToBottom,
    bottomToTop,
};

// TODO: don't couple to raylib
pub const UI_Style = struct {
    color: raylib.Color = raylib.LIGHTGRAY,
    hover_color: raylib.Color = raylib.WHITE,
    border_color: raylib.Color = raylib.DARKGRAY,

    text_color: raylib.Color = raylib.BLACK,
    text_size: i32 = 20,
    text_padding: i32 = 8,
};

pub const Vec2 = struct {
    x: f32,
    y: f32,
};

pub const UI_Box = struct {
    /// the first child
    first: ?*UI_Box,
    last: ?*UI_Box,

    /// the next sibling
    next: ?*UI_Box,
    prev: ?*UI_Box,

    parent: ?*UI_Box,

    /// the assigned features
    flags: UI_Flags,
    direction: UI_Direction,
    style: UI_Style,
    layout: UI_Layout,

    /// the label
    label: [:0]u8,

    /// the final computed position and size of this primitive (in pixels)
    computed_pos: Vec2,
    computed_size: Vec2,

    // whether or not this primitive is currently being interacted with
    //active: bool = false,
    // whether or not this primitive is *about* to be interacted with
    //hot: bool = false,

    // specific scrollable settings
    scroll_fract: f32 = 0,
    scroll_top: ?*UI_Box = null,
};
