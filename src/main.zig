const std = @import("std");
const raylib = @import("raylib");

const UI_Flags = packed struct(u4) {
    clickable: bool = false,
    drawText: bool = false,
    drawBorder: bool = false,
    drawBackground: bool = false,
};

const UI_Direction = enum {
    leftToRight,
    rightToLeft,
    topToBottom,
    bottomToTop,
};

const UI_Layout = enum {};

const Vec2 = struct {
    x: f32,
    y: f32,
};

/// the most (and only) basic primitive
const UI_Box = struct {
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

    /// the label?
    label: [:0]const u8,

    /// the final computed position and size of this primitive
    computed_pos: Vec2,
    computed_size: Vec2,
};

var box_allocator: std.mem.Allocator = undefined;
var root_box: ?*UI_Box = null;
var current_box: ?*UI_Box = null;
var pushing_box: bool = false;
var popping_box: bool = false;
var mouse_x: i32 = 0;
var mouse_y: i32 = 0;
var mouse_released: bool = false;

fn DeleteBoxChildren(box: *UI_Box, should_destroy: bool) void {
    if (box.first) |child| {
        DeleteBoxChildren(child, true);
    } else if (should_destroy) {
        box_allocator.destroy(box);
    }
}

fn MakeBox(label: [:0]const u8, flags: UI_Flags, direction: UI_Direction) anyerror!bool {
    //std.debug.print("making box '{s}'...", .{label});
    popping_box = false;

    if (pushing_box) {
        const box = try PushBox(label, flags, direction);
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
                //const following_sibling = next.next;
                DeleteBoxChildren(next, false);

                next.* = UI_Box{
                    .label = label,
                    .flags = flags,
                    .direction = direction,

                    .first = null,
                    .last = null,
                    // TODO: don't keep this null
                    .next = null,
                    .prev = null,
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
                .label = label,
                .flags = flags,
                .direction = direction,

                .first = null,
                .last = null,
                .next = null,
                .prev = null,
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
            .label = label,
            .flags = flags,
            .direction = direction,

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

fn PushBox(label: [:0]const u8, flags: UI_Flags, direction: UI_Direction) anyerror!bool {
    //std.debug.print("pushing box '{s}'...", .{label});

    if (popping_box) {
        const box = try MakeBox(label, flags, direction);
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
                //const following_sibling = first.next;
                DeleteBoxChildren(first, false);

                first.* = UI_Box{
                    .label = label,
                    .flags = flags,
                    .direction = direction,

                    .first = null,
                    .last = null,
                    // TODO: don't keep this null
                    .next = null,
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
                .label = label,
                .flags = flags,
                .direction = direction,

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
        return try MakeBox(label, flags, direction);
    }

    if (current_box) |box| {
        if (box.flags.clickable) {
            return TestBoxClick(box);
        }
    }

    return false;
}

fn PopBox() void {
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

fn TestBoxClick(box: *UI_Box) bool {
    return mouse_released and @intToFloat(f32, mouse_x) >= box.computed_pos.x and @intToFloat(f32, mouse_x) <= box.computed_pos.x + box.computed_size.x and @intToFloat(f32, mouse_y) >= box.computed_pos.y and @intToFloat(f32, mouse_y) <= box.computed_pos.y + box.computed_size.y;
}

fn MakeButton(label: [:0]const u8) !bool {
    return try MakeBox(label, .{
        .clickable = true,
        .drawText = true,
        .drawBorder = true,
        .drawBackground = true,
    }, .leftToRight);
}

fn MakeLabel(label: [:0]const u8) !bool {
    return try MakeBox(label, .{
        .drawText = true,
    }, .leftToRight);
}

fn CountChildren(box: *UI_Box) u32 {
    var count: u32 = 0;
    var b = box.first;

    while (b) |child| {
        count += 1;

        // TODO: um, somehow need to trim currently unused tree nodes
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
                //std.debug.print("count siblings last askdhfksahdfklhsdaklfhf\n", .{});
                break;
            }
        }

        b = next;
    }

    return count;
}

fn DrawUI(box: *UI_Box, parent: ?*UI_Box, parent_pos: Vec2, parent_size: Vec2) void {
    //DrawRectangle(int posX, int posY, int width, int height, Color color

    //std.debug.print("\n\ndrawing {s}\n", .{box.label});

    const num_siblings = if (parent) |p| (CountChildren(p) - 1) else 0;
    //std.debug.print("num_siblings {d}\n", .{num_siblings});

    //const num_children = CountChildren(box);
    //std.debug.print("num_children {d}\n", .{num_children});

    const num_siblings_after_me = CountSiblings(box);
    //std.debug.print("num_siblings_after_me  {d}\n", .{num_siblings_after_me});

    const my_index = num_siblings - num_siblings_after_me;
    //std.debug.print("num_index {d}\n", .{my_index});

    if (parent) |p| {
        box.computed_size = Vec2{
            .x = switch (p.direction) {
                .leftToRight => parent_size.x / (@intToFloat(f32, num_siblings) + 1),
                .rightToLeft => unreachable,
                .topToBottom => parent_size.x,
                .bottomToTop => unreachable,
            },
            .y = switch (p.direction) {
                .leftToRight => parent_size.y,
                .rightToLeft => unreachable,
                .topToBottom => parent_size.y / (@intToFloat(f32, num_siblings) + 1),
                .bottomToTop => unreachable,
            },
        };
    } else {
        box.computed_size = Vec2{
            .x = parent_size.x,
            .y = parent_size.y,
        };
    }

    if (parent) |p| {
        box.computed_pos = Vec2{
            .x = switch (p.direction) {
                .leftToRight => box.computed_size.x * @intToFloat(f32, my_index) + parent_pos.x,
                .rightToLeft => unreachable,
                .topToBottom => parent_pos.x,
                .bottomToTop => unreachable,
            },
            .y = switch (p.direction) {
                .leftToRight => parent_pos.y,
                .rightToLeft => unreachable,
                .topToBottom => box.computed_size.y * @intToFloat(f32, my_index) + parent_pos.y,
                .bottomToTop => unreachable,
            },
        };
    } else {
        box.computed_pos = Vec2{
            .x = parent_pos.x,
            .y = parent_pos.y,
        };
    }

    if (box.flags.drawBackground) {
        raylib.DrawRectangle(@floatToInt(i32, box.computed_pos.x), @floatToInt(i32, box.computed_pos.y), @floatToInt(i32, box.computed_size.x), @floatToInt(i32, box.computed_size.y), raylib.DARKGRAY);
    }
    if (box.flags.drawBorder) {
        raylib.DrawRectangleLines(@floatToInt(i32, box.computed_pos.x), @floatToInt(i32, box.computed_pos.y), @floatToInt(i32, box.computed_size.x), @floatToInt(i32, box.computed_size.y), raylib.BLUE);
    }
    if (box.flags.drawText) {
        raylib.DrawText(box.label, @floatToInt(i32, box.computed_pos.x), @floatToInt(i32, box.computed_pos.y), 20, raylib.RED);
    }

    // draw children
    var child = box.first;
    while (child) |c| {
        DrawUI(c, box, box.computed_pos, box.computed_size);

        if (child == box.last) break;

        child = c.next;
    }
}

pub fn main() !void {
    raylib.InitWindow(800, 600, "Zooy Test");
    raylib.SetConfigFlags(raylib.ConfigFlags{ .FLAG_WINDOW_RESIZABLE = true });
    raylib.SetTargetFPS(60);

    defer raylib.CloseWindow();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    box_allocator = gpa.allocator();

    _ = try PushBox("RootContainer", .{}, .leftToRight);
    root_box = current_box;

    //std.debug.print("Starting main loop\n", .{});
    var other_button_shown = false;
    var show_buttons = true;
    var dir: UI_Direction = .topToBottom;
    while (!raylib.WindowShouldClose()) {
        current_box = root_box;
        pushing_box = false;
        popping_box = false;

        mouse_x = raylib.GetMouseX();
        mouse_y = raylib.GetMouseY();
        mouse_released = raylib.IsMouseButtonReleased(raylib.MouseButton.MOUSE_BUTTON_LEFT);

        raylib.BeginDrawing();
        defer raylib.EndDrawing();

        raylib.ClearBackground(raylib.BLACK);

        if (show_buttons) {
            _ = try PushBox("ButtonArray", .{}, dir);
            defer PopBox();

            if (try MakeButton("Show Labels")) {
                other_button_shown = !other_button_shown;
            }
            if (try MakeButton("Switch Direction")) {
                if (dir == .topToBottom) {
                    dir = .leftToRight;
                } else {
                    dir = .topToBottom;
                }
            }
        }

        if (other_button_shown) {
            _ = try PushBox("TextArray", .{}, dir);
            defer PopBox();

            _ = try MakeLabel("This is some text");
            _ = try MakeLabel("So is this");

            if (show_buttons) {
                if (try MakeButton("Remove Buttons")) {
                    show_buttons = false;
                }
            } else {
                if (try MakeButton("Show Buttons")) {
                    show_buttons = true;
                }
            }
        }

        if (root_box) |box| {
            //std.debug.print("====== STARTING DRAWING =====\n", .{});
            DrawUI(box, null, .{ .x = 0, .y = 0 }, .{ .x = 800, .y = 600 });
        }
    }
}
