const std = @import("std");

// TODO: abstract raylib away to allow for consumers to use whatever they want.
// I'm also rexporting here because the zig build system hurts
pub const raylib = @import("raylib");

// TODO: don't just make these public
pub var box_allocator: std.mem.Allocator = undefined;

pub var root_box: ?*UI_Box = null;
pub var current_box: ?*UI_Box = null;
pub var current_style: std.ArrayList(UI_Style) = undefined;

pub var pushing_box: bool = false;
pub var popping_box: bool = false;

pub var mouse_x: i32 = 0;
pub var mouse_y: i32 = 0;
pub var mouse_released: bool = false;
pub var mouse_hovering_clickable: bool = false;

pub const UI_Flags = packed struct(u5) {
    clickable: bool = false,
    hoverable: bool = false,
    drawText: bool = false,
    drawBorder: bool = false,
    drawBackground: bool = false,
};

pub const UI_Layout = union(enum) { fitToText, fitToChildren, fill, exactSize: Vec2 };

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

    /// the label?
    label: [:0]const u8,

    /// the final computed position and size of this primitive (in pixels)
    computed_pos: Vec2,
    computed_size: Vec2,
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
    return @intToFloat(f32, mouse_x) >= box.computed_pos.x and @intToFloat(f32, mouse_x) <= box.computed_pos.x + box.computed_size.x and @intToFloat(f32, mouse_y) >= box.computed_pos.y and @intToFloat(f32, mouse_y) <= box.computed_pos.y + box.computed_size.y;
}

fn TestBoxClick(box: *UI_Box) bool {
    return mouse_released and TestBoxHover(box);
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
                std.debug.print("make_box: invalidating cache for '{s}' when making new box '{s}'\n", .{ next.label, label });
                const following_sibling = next.next;
                DeleteBoxChildren(next, false);

                next.* = UI_Box{
                    .label = label,
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
            std.debug.print("make_box: allocating new box: {s}\n", .{label});
            var new_box = try box_allocator.create(UI_Box);
            new_box.* = UI_Box{
                .label = label,
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
        std.debug.print("make_box: allocating new box: {s}\n", .{label});
        var new_box = try box_allocator.create(UI_Box);
        new_box.* = UI_Box{
            .label = label,
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
                std.debug.print("push_box: invalidating cache for '{s}' when making new box '{s}'\n", .{ first.label, label });
                const following_sibling = first.next;
                DeleteBoxChildren(first, false);

                first.* = UI_Box{
                    .label = label,
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
            std.debug.print("push_box: allocating new box: {s}\n", .{label});
            var new_box = try box_allocator.create(UI_Box);
            new_box.* = UI_Box{
                .label = label,
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

pub fn MakeButton(label: [:0]const u8) !bool {
    return try MakeBox(label, .{
        .clickable = true,
        .hoverable = true,
        .drawText = true,
        .drawBackground = true,
    }, .leftToRight, .fitToText);
}

pub fn MakeLabel(label: [:0]const u8) !void {
    _ = try MakeBox(label, .{
        .drawText = true,
    }, .leftToRight, .fitToText);
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

    switch (box.layout) {
        .fitToText => {
            box.computed_size = Vec2{
                .x = @intToFloat(f32, raylib.MeasureText(box.label, box.style.text_size) + box.style.text_padding * 2),
                .y = @intToFloat(f32, box.style.text_size + box.style.text_padding * 2),
            };
        },
        .fitToChildren => {
            box.computed_size = total_size;
        },
        .fill => {
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

            if (box.parent) |p| {
                box.computed_size = Vec2{
                    .x = switch (p.direction) {
                        .leftToRight => p.computed_size.x - total_sibling_size.x - box.computed_pos.x,
                        .topToBottom => total_sibling_size.x,
                        .rightToLeft, .bottomToTop => unreachable,
                    },
                    .y = switch (p.direction) {
                        .leftToRight => total_sibling_size.y,
                        .topToBottom => p.computed_size.y - total_sibling_size.y - box.computed_pos.y,
                        .rightToLeft, .bottomToTop => unreachable,
                    },
                };
            } else {
                // TODO: somehow need to get these values
                box.computed_size = Vec2{ .x = 1280, .y = 720 };
            }
        },
        .exactSize => |_| unreachable,
    }

    return box.computed_size;
}

pub fn DrawUI(box: *UI_Box) void {
    if (box.flags.drawBackground) {
        const is_hovering = TestBoxHover(box);
        const color = if (box.flags.hoverable and is_hovering) box.style.hover_color else box.style.color;

        if (box.flags.clickable and is_hovering) {
            mouse_hovering_clickable = true;
        }

        raylib.DrawRectangle( //
            @floatToInt(i32, box.computed_pos.x), //
            @floatToInt(i32, box.computed_pos.y), //
            @floatToInt(i32, box.computed_size.x), //
            @floatToInt(i32, box.computed_size.y), //
            color //
        );
    }
    if (box.flags.drawBorder) {
        raylib.DrawRectangleLines( //
            @floatToInt(i32, box.computed_pos.x), //
            @floatToInt(i32, box.computed_pos.y), //
            @floatToInt(i32, box.computed_size.x), //
            @floatToInt(i32, box.computed_size.y), //
            box.style.border_color //
        );
    }
    if (box.flags.drawText) {
        raylib.DrawText( //
            box.label, //
            @floatToInt(i32, box.computed_pos.x) + box.style.text_padding, //
            @floatToInt(i32, box.computed_pos.y) + box.style.text_padding, //
            box.style.text_size, //
            box.style.text_color //
        );
    }

    // draw children
    const children = CountChildren(box);
    if (children > 0) {
        var child = box.first;
        while (child) |c| {
            DrawUI(c);

            if (child == box.last) break;

            child = c.next;
        }
    }
}
