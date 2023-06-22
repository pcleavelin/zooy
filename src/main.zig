const std = @import("std");
const raylib = @import("raylib");

const UI_Flags = enum(u32) {
    nothing = 0,
    clickable = (1 << 0),
    drawText = (1 << 1),
    drawBorder = (1 << 2),
};

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
    flags: u32,

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

fn DeleteBoxChildren(box: *UI_Box, should_destroy: bool) void {
    if (box.first) |child| {
        DeleteBoxChildren(child, true);
    } else if (should_destroy) {
        box_allocator.destroy(box);
    }
}

fn MakeBox(label: [:0]const u8, flags: UI_Flags) anyerror!*UI_Box {
    std.debug.print("making box '{s}'...", .{label});
    popping_box = false;

    if (pushing_box) {
        const box = try PushBox(label, flags);
        pushing_box = false;

        return box;
    }

    if (current_box) |box| {
        if (box.next) |next| {
            // Attempt to re-use cache
            if (std.mem.eql(u8, next.label, label)) {
                std.debug.print("using cache for '{s}'\n", .{next.label});
                next.flags = @enumToInt(flags);
                if (next.parent) |parent| {
                    parent.last = next;
                }
                current_box = next;
                return next;
            } else {
                // Invalid cache, delete next sibling while retaining the following one
                std.debug.print("make_box: invalidating cache for '{s}' when making new box '{s}'\n", .{ next.label, label });
                const following_sibling = next.next;
                DeleteBoxChildren(next, false);

                next.* = UI_Box{
                    .label = label,
                    .flags = @enumToInt(flags),

                    .first = null,
                    .last = null,
                    .next = following_sibling,
                    .prev = null,
                    .parent = box.parent,
                    .computed_pos = Vec2{ .x = 0, .y = 0 },
                    .computed_size = Vec2{ .x = 0, .y = 0 },
                };

                current_box = next;
                if (next.parent) |parent| {
                    parent.last = next;
                }

                return next;
            }
        } else {
            // No existing cache, create new box
            std.debug.print("make_box: allocating new box: {s}\n", .{label});
            var new_box = try box_allocator.create(UI_Box);
            new_box.* = UI_Box{
                .label = label,
                .flags = @enumToInt(flags),

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

            return new_box;
        }
    } else {
        std.debug.print("make_box: allocating new box: {s}\n", .{label});
        var new_box = try box_allocator.create(UI_Box);
        new_box.* = UI_Box{
            .label = label,
            .flags = @enumToInt(flags),

            .first = null,
            .last = null,
            .next = null,
            .prev = null,
            .parent = null,
            .computed_pos = Vec2{ .x = 0, .y = 0 },
            .computed_size = Vec2{ .x = 0, .y = 0 },
        };

        current_box = new_box;
        return new_box;
    }
}

fn PushBox(label: [:0]const u8, flags: UI_Flags) anyerror!*UI_Box {
    std.debug.print("pushing box '{s}'...", .{label});

    if (popping_box) {
        const box = try MakeBox(label, flags);
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
                std.debug.print("using cache for '{s}'\n", .{first.label});
                first.flags = @enumToInt(flags);
                current_box = first;

                if (first.parent) |parent| {
                    parent.last = first;
                }
                return first;
            } else {
                // Invalid cache
                std.debug.print("push_box: invalidating cache for '{s}' when making new box '{s}'\n", .{ first.label, label });
                const following_sibling = first.next;
                DeleteBoxChildren(first, false);

                first.* = UI_Box{
                    .label = label,
                    .flags = @enumToInt(flags),

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
                return first;
            }
        } else {
            std.debug.print("push_box: allocating new box: {s}\n", .{label});
            var new_box = try box_allocator.create(UI_Box);
            new_box.* = UI_Box{
                .label = label,
                .flags = @enumToInt(flags),

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
            return new_box;
        }
    } else {
        pushing_box = false;
        return try MakeBox(label, flags);
    }
}

fn PopBox() void {
    std.debug.print("popping box...", .{});
    if (current_box) |box| {
        //if (box.parent) |parent| {
        //current_box = parent.last;
        //return;
        //}
        current_box = box.parent;
        popping_box = true;
        return;
    }

    std.debug.print("couldn't pop box\n", .{});
}

fn TestBoxClick(box: *UI_Box, mouse_x: f32, mouse_y: f32, mouse_clicked: bool) bool {
    return mouse_clicked and mouse_x >= box.computed_pos.x and mouse_x <= box.computed_pos.x + box.computed_size.x and mouse_y >= box.computed_pos.y and mouse_y <= box.computed_pos.y + box.computed_size.y;
}

fn MakeButton(label: [:0]const u8) !bool {
    var box = try MakeBox(label, UI_Flags.clickable);

    const mouse_x = 0;
    const mouse_y = 0;
    const mouse_clicked = false;

    return TestBoxClick(box, mouse_x, mouse_y, mouse_clicked);
}

fn CountChildren(box: *UI_Box) u32 {
    var count: u32 = 0;
    var b = box.first;

    while (b) |child| {
        count += 1;

        b = child.next;
    }

    return count;
}

fn CountSiblings(box: *UI_Box) u32 {
    var count: u32 = 0;
    var b = box;

    while (b.next) |next| {
        count += 1;

        b = next;
    }

    return count;
}

fn DrawUI(box: *UI_Box, parent: ?*UI_Box, parent_pos: Vec2, parent_size: Vec2) void {
    //DrawRectangle(int posX, int posY, int width, int height, Color color

    std.debug.print("\n\ndrawing {s}\n", .{box.label});

    const num_siblings = if (parent) |p| (CountChildren(p) - 1) else 0;
    std.debug.print("num_siblings {d}\n", .{num_siblings});

    const num_children = CountChildren(box);
    std.debug.print("num_children {d}\n", .{num_children});

    const num_siblings_after_me = CountSiblings(box);
    std.debug.print("num_siblings_after_me  {d}\n", .{num_siblings_after_me});

    const my_index = num_siblings - num_siblings_after_me;
    std.debug.print("num_index {d}\n", .{my_index});

    box.computed_size = Vec2{
        .x = parent_size.x / (@intToFloat(f32, num_siblings) + 1),
        .y = parent_size.y,
        //.y = parent_size.y / (@intToFloat(f32, num_siblings) + 1),
    };
    box.computed_pos = Vec2{
        .x = box.computed_size.x * @intToFloat(f32, my_index) + parent_pos.x,
        .y = parent_pos.y + 12,
        //.y = box.computed_size.y * @intToFloat(f32, my_index) + parent_pos.y,
    };

    raylib.DrawRectangleLines(@floatToInt(i32, box.computed_pos.x), @floatToInt(i32, box.computed_pos.y), @floatToInt(i32, box.computed_size.x), @floatToInt(i32, box.computed_size.y), raylib.BLUE);
    raylib.DrawText(box.label, @floatToInt(i32, box.computed_pos.x), @floatToInt(i32, box.computed_pos.y), 10, raylib.RED);

    // draw children
    var child = box.first;
    while (child) |c| {
        DrawUI(c, box, box.computed_pos, box.computed_size);

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

    root_box = try PushBox("RootContainer", UI_Flags.nothing);

    std.debug.print("Starting main loop\n", .{});
    var ran = false;
    while (!raylib.WindowShouldClose()) {
        current_box = root_box;
        pushing_box = false;
        popping_box = false;

        raylib.BeginDrawing();
        defer raylib.EndDrawing();

        raylib.ClearBackground(raylib.BLACK);

        _ = try PushBox("ButtonArray", UI_Flags.nothing);
        if (try MakeButton("click me")) {
            std.debug.print("button clicked", .{});
        }
        if (try MakeButton("click me 2")) {
            std.debug.print("button 2 clicked", .{});
        }
        PopBox();

        _ = try PushBox("TextArray", UI_Flags.nothing);
        _ = try MakeBox("This is some text", UI_Flags.nothing);
        _ = try MakeBox("So is this", UI_Flags.nothing);
        PopBox();

        if (root_box) |box| {
            DrawUI(box, null, .{ .x = 0, .y = 0 }, .{ .x = 800, .y = 600 });
        }

        // raylib.DrawFPS(10, 10);

        //raylib.DrawText("Hello Zooy", 100, 100, 20, raylib.YELLOW);

        //if (ran) break;
        ran = true;
    }
}
