const std = @import("std");

// TODO: abstract raylib away to allow for consumers to use whatever they want.
// I'm also rexporting here because the zig build system hurts
pub const raylib = @import("raylib");
pub const components = @import("components.zig");

// TODO: don't just make these public
pub var box_allocator: std.mem.Allocator = undefined;

pub var root_box: ?*UI_Box = null;
pub var current_box: ?*UI_Box = null;
pub var current_style: std.ArrayList(UI_Style) = undefined;

pub var pushing_box: bool = false;
pub var popping_box: bool = false;

// PLEASE DON'T DO THIS
pub var font20: raylib.Font = undefined;
pub var font10: raylib.Font = undefined;

pub var mouse_x: i32 = 0;
pub var mouse_y: i32 = 0;
// TODO: do this better
pub var mouse_scroll: f32 = 0;
pub var mouse_released: bool = false;
pub var mouse_hovering_clickable: bool = false;

const scroll_speed: f32 = 1.125;

pub const UI_Flags = packed struct(u6) {
    clickable: bool = false,
    hoverable: bool = false,
    scrollable: bool = false,
    drawText: bool = false,
    drawBorder: bool = false,
    drawBackground: bool = false,
};

pub const UI_Layout = union(enum) {
    fitToText,
    fitToChildren,
    fill,
    percentOfParent: Vec2,
    exactSize: Vec2,
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
    active: bool = false,
    // whether or not this primitive is *about* to be interacted with
    hot: bool = false,

    // specific scrollable settings
    scroll_fract: f32 = 0,
    scroll_top: ?*UI_Box = null,
};

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

fn TestBoxHover(box: *UI_Box) bool {
    return @as(f32, @floatFromInt(mouse_x)) >= box.computed_pos.x and @as(f32, @floatFromInt(mouse_x)) <= box.computed_pos.x + box.computed_size.x and @as(f32, @floatFromInt(mouse_y)) >= box.computed_pos.y and @as(f32, @floatFromInt(mouse_y)) <= box.computed_pos.y + box.computed_size.y;
}

fn TestBoxClick(box: *UI_Box) bool {
    return mouse_released and TestBoxHover(box);
}

fn ScrollBox(box: *UI_Box) void {
    if (TestBoxHover(box)) {
        if (box.scroll_top == null) {
            box.scroll_top = box.first;
        }

        if (box.scroll_top) |top| {
            if ((mouse_scroll > 0 and top.prev != null) or (mouse_scroll < 0 and top.next != null) or box.scroll_fract != 0) {
                box.scroll_fract -= mouse_scroll * scroll_speed;
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

pub fn DeleteBoxChildren(box: *UI_Box, should_destroy: bool) void {
    if (box.first) |child| {
        DeleteBoxChildren(child, true);
    } else if (should_destroy) {
        box_allocator.destroy(box);
    }
}

// TODO: remove all footguns by compressing code
pub fn MakeBox(label: [:0]const u8, flags: UI_Flags, direction: UI_Direction, layout: UI_Layout) anyerror!bool {
    //std.debug.print("making box '{s}'...", .{label});

    // TODO: Please remove this state machine, there should be a way to do it without it
    popping_box = false;

    if (pushing_box) {
        const box = try PushBox(label, flags, direction, layout);
        pushing_box = false;

        return box;
    }

    if (current_box) |box| {
        if (box.next) |next| {
            // Attempt to re-use cache
            if (std.mem.eql(u8, next.label, label)) {
                //std.debug.print("using cache for '{s}'\n", .{next.label});
                next.flags = flags;
                next.direction = direction;
                if (next.parent) |parent| {
                    parent.last = next;
                }
                current_box = next;
            } else {
                // Invalid cache, delete next sibling while retaining the following one
                //std.debug.print("make_box: invalidating cache for '{s}' when making new box '{s}'\n", .{ next.label, label });
                const following_sibling = next.next;
                DeleteBoxChildren(next, false);

                next.* = UI_Box{
                    .label = @constCast(label),
                    .flags = flags,
                    .direction = direction,
                    .style = current_style.getLast(),
                    .layout = layout,

                    .first = null,
                    .last = null,
                    .next = following_sibling,
                    .prev = box,
                    .parent = box.parent,
                    .computed_pos = Vec2{ .x = 0, .y = 0 },
                    .computed_size = Vec2{ .x = 0, .y = 0 },
                };

                current_box = next;
                if (next.parent) |parent| {
                    parent.last = next;
                }
            }
        } else {
            // No existing cache, create new box
            //std.debug.print("make_box: allocating new box: {s}\n", .{label});
            var new_box = try box_allocator.create(UI_Box);
            new_box.* = UI_Box{
                .label = @constCast(label),
                .flags = flags,
                .direction = direction,
                .style = current_style.getLast(),
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
            current_box = new_box;
            if (new_box.parent) |parent| {
                parent.last = new_box;
            }
        }
    } else {
        //std.debug.print("make_box: allocating new box: {s}\n", .{label});
        var new_box = try box_allocator.create(UI_Box);
        new_box.* = UI_Box{
            .label = @constCast(label),
            .flags = flags,
            .direction = direction,
            .style = current_style.getLast(),
            .layout = layout,

            .first = null,
            .last = null,
            .next = null,
            .prev = null,
            .parent = null,
            .computed_pos = Vec2{ .x = 0, .y = 0 },
            .computed_size = Vec2{ .x = 0, .y = 0 },
        };

        current_box = new_box;
    }

    if (current_box) |box| {
        if (box.flags.clickable) {
            return TestBoxClick(box);
        }
        if (box.flags.scrollable) {
            ScrollBox(box);
        }
    }

    return false;
}

pub fn PushBox(label: [:0]const u8, flags: UI_Flags, direction: UI_Direction, layout: UI_Layout) anyerror!bool {
    //std.debug.print("pushing box '{s}'...", .{label});

    // TODO: Please remove this state machine, there should be a way to do it without it
    if (popping_box) {
        const box = try MakeBox(label, flags, direction, layout);
        pushing_box = true;

        return box;
    }
    if (!pushing_box) {
        pushing_box = true;
    }

    if (current_box) |box| {
        // Attempt to re-use cache
        if (box.first) |first| {
            // check if the same
            if (std.mem.eql(u8, first.label, label)) {
                //std.debug.print("using cache for '{s}'\n", .{first.label});
                first.flags = flags;
                first.direction = direction;
                current_box = first;

                if (first.parent) |parent| {
                    parent.last = first;
                }
            } else {
                // Invalid cache
                //std.debug.print("push_box: invalidating cache for '{s}' when making new box '{s}'\n", .{ first.label, label });
                const following_sibling = first.next;
                DeleteBoxChildren(first, false);

                first.* = UI_Box{
                    .label = @constCast(label),
                    .flags = flags,
                    .direction = direction,
                    .style = current_style.getLast(),
                    .layout = layout,

                    .first = null,
                    .last = null,
                    .next = following_sibling,
                    .prev = null,
                    .parent = current_box,
                    .computed_pos = Vec2{ .x = 0, .y = 0 },
                    .computed_size = Vec2{ .x = 0, .y = 0 },
                };

                current_box = first;
                if (first.parent) |parent| {
                    parent.last = first;
                }
            }
        } else {
            //std.debug.print("push_box: allocating new box: {s}\n", .{label});
            var new_box = try box_allocator.create(UI_Box);
            new_box.* = UI_Box{
                .label = @constCast(label),
                .flags = flags,
                .direction = direction,
                .style = current_style.getLast(),
                .layout = layout,

                .first = null,
                .last = null,
                .next = null,
                .prev = null,
                .parent = current_box,
                .computed_pos = Vec2{ .x = 0, .y = 0 },
                .computed_size = Vec2{ .x = 0, .y = 0 },
            };

            box.first = new_box;
            current_box = new_box;
            if (new_box.parent) |parent| {
                parent.last = new_box;
            }
        }
    } else {
        pushing_box = false;
        return try MakeBox(label, flags, direction, layout);
    }

    if (current_box) |box| {
        if (box.flags.clickable) {
            return TestBoxClick(box);
        }
    }

    return false;
}

pub fn PopBox() void {
    //std.debug.print("popping box...", .{});
    if (current_box) |box| {
        //if (box.parent) |parent| {
        //current_box = parent.last;
        //return;
        //}
        if (box.parent) |p| {
            p.last = current_box;
        }
        current_box = box.parent;
        popping_box = true;
        return;
    }

    //std.debug.print("couldn't pop box\n", .{});
}

pub fn PushStyle(style: UI_Style) !void {
    try current_style.append(style);
}

pub fn PopStyle() void {
    _ = current_style.popOrNull();
}

pub fn MakeButtonWithLayout(label: [:0]const u8, layout: UI_Layout) !bool {
    return try MakeBox(label, .{
        .clickable = true,
        .hoverable = true,
        .drawText = true,
        .drawBackground = true,
    }, .leftToRight, layout);
}

pub fn MakeButton(label: [:0]const u8) !bool {
    return try MakeButtonWithLayout(label, .fitToText);
}

pub fn MakeLabelWithLayout(label: [:0]const u8, layout: UI_Layout) !void {
    _ = try MakeBox(label, .{
        .drawText = true,
    }, .leftToRight, layout);
}

pub fn MakeLabel(label: [:0]const u8) !void {
    _ = try MakeLabelWithLayout(label, .fitToText);
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
    while (n) |next| {
        const sibling_size = ComputeLayout(next);

        switch (box.direction) {
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
                    box.computed_size = Vec2{
                        .x = switch (p.direction) {
                            .leftToRight => p.computed_size.x - total_sibling_size.x - box.computed_pos.x,
                            .topToBottom => if (total_sibling_size.x == 0) p.computed_size.x else total_sibling_size.x,
                            .rightToLeft, .bottomToTop => unreachable,
                        },
                        .y = switch (p.direction) {
                            .leftToRight => if (total_sibling_size.y == 0) p.computed_size.y else total_sibling_size.y,
                            .topToBottom => p.computed_size.y - total_sibling_size.y - box.computed_pos.y,
                            .rightToLeft, .bottomToTop => unreachable,
                        },
                    };
                } else {
                    // TODO: somehow need to get these values
                    //box.computed_size = Vec2{ .x = 1280, .y = 720 };
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
            .exactSize => |_| unreachable,
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

pub fn DrawUI(box: *UI_Box) void {
    const is_hovering = TestBoxHover(box);
    if (box.flags.clickable and is_hovering) {
        mouse_hovering_clickable = true;
    }

    const pos_x: i32 = @intFromFloat(box.computed_pos.x);
    const pos_y: i32 = @intFromFloat(box.computed_pos.y);
    const size_x: i32 = @intFromFloat(box.computed_size.x);
    const size_y: i32 = @intFromFloat(box.computed_size.y);

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
            if (box.style.text_size == 20) font20 else if (box.style.text_size == 12) font10 else font10, //
            box.label, //
            .{
            .x = box.computed_pos.x + @as(f32, @floatFromInt(box.style.text_padding)), //
            .y = box.computed_pos.y - bb + @as(f32, @floatFromInt(box.style.text_padding)), //
        }, //
            @as(f32, @floatFromInt(box.style.text_size)), //
            1.0, color //
        );
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
        raylib.BeginScissorMode(pos_x, pos_y, size_x, size_y);
        while (child) |c| {
            DrawUI(c);

            if (child == box.last) break;

            if (box.flags.scrollable) {
                switch (box.direction) {
                    .leftToRight => {
                        child_size += c.computed_size.x;
                        // TODO: don't multiply this by two, use the last child size or something
                        if (child_size > box.computed_size.x * 2) break;
                    },
                    .rightToLeft, .bottomToTop => unreachable,
                    .topToBottom => {
                        child_size += c.computed_size.y;
                        // TODO: don't multiply this by two, use the last child size or something
                        if (child_size > box.computed_size.y * 2) break;
                    },
                }
            }

            child = c.next;
        }
        raylib.EndScissorMode();
    }
}
