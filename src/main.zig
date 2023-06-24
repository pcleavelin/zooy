const std = @import("std");
const raylib = @import("raylib");
const ui = @import("lib.zig");

pub fn main() !void {
    raylib.InitWindow(1280, 720, "Zooy Test");
    raylib.SetConfigFlags(raylib.ConfigFlags{ .FLAG_WINDOW_RESIZABLE = true });
    raylib.SetTargetFPS(60);

    defer raylib.CloseWindow();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    ui.box_allocator = gpa.allocator();

    ui.current_style = @TypeOf(ui.current_style).init(ui.box_allocator);
    try ui.current_style.append(.{ .hover_color = raylib.WHITE });

    _ = try ui.PushBox("RootContainer", .{}, .leftToRight);
    ui.root_box = ui.current_box;

    //std.debug.print("Starting main loop\n", .{});
    var other_button_shown = false;
    var show_buttons = true;
    var dir: ui.UI_Direction = .topToBottom;
    while (!raylib.WindowShouldClose()) {
        ui.current_box = ui.root_box;
        ui.pushing_box = false;
        ui.popping_box = false;
        ui.current_style.clearRetainingCapacity();
        try ui.current_style.append(.{ .hover_color = raylib.WHITE });

        ui.mouse_x = raylib.GetMouseX();
        ui.mouse_y = raylib.GetMouseY();
        ui.mouse_released = raylib.IsMouseButtonReleased(raylib.MouseButton.MOUSE_BUTTON_LEFT);

        raylib.BeginDrawing();
        defer raylib.EndDrawing();

        raylib.ClearBackground(raylib.BLACK);

        if (show_buttons) {
            _ = try ui.PushBox("ButtonArray", .{}, dir);
            defer ui.PopBox();

            if (try ui.MakeButton("Show Labels")) {
                other_button_shown = !other_button_shown;
            }
            if (try ui.MakeButton("Switch Direction")) {
                if (dir == .topToBottom) {
                    dir = .leftToRight;
                } else {
                    dir = .topToBottom;
                }
            }
        }

        if (other_button_shown) {
            _ = try ui.PushBox("TextArray", .{}, dir);
            defer ui.PopBox();

            _ = try ui.MakeLabel("This is some text");

            {
                try ui.PushStyle(.{ .hover_color = raylib.SKYBLUE });
                defer ui.PopStyle();

                for (0..20) |_| {
                    _ = try ui.MakeButton("So is this");
                }
            }

            try ui.PushStyle(.{ .hover_color = raylib.GREEN });
            if (show_buttons) {
                if (try ui.MakeButton("Remove Buttons")) {
                    show_buttons = false;
                }
            } else {
                if (try ui.MakeButton("Show Buttons")) {
                    show_buttons = true;
                }
            }
            ui.PopStyle();
        }

        if (ui.root_box) |box| {
            //std.debug.print("====== STARTING DRAWING =====\n", .{});
            ui.DrawUI(box, null, 0, 0, .{ .x = 0, .y = 0 }, .{ .x = 1280, .y = 720 });
        }

        raylib.DrawFPS(0, 600 - 20);
    }
}
