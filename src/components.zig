const ui = @import("lib.zig");

const raylib = ui.raylib;

pub const Grid = struct {
    fn MakeColumnHeader(columns: [][:0]const u8) !void {
        _ = try ui.PushBox("GridColumnHeader", .{ .drawBackground = true, .drawBorder = false }, .leftToRight, .fitToChildren);
        defer ui.PopBox();

        try ui.PushStyle(.{ //
            .color = raylib.WHITE, //
            .text_color = .{ .r = 0x18, .g = 0x90, .b = 0xff, .a = 0xff }, //
            .text_size = 10, //
            .text_padding = 12, //
        });
        defer ui.PopStyle();

        for (columns) |column| {
            try MakeLabel(column, @as(i32, @intCast(columns.len)));
        }
    }

    pub fn MakeButton(label: [:0]const u8, items: i32) !bool {
        return try ui.MakeBox(label, .{
            .clickable = true,
            .drawText = true,
        }, .leftToRight, .{ .percentOfParent = ui.Vec2{ .x = 1.0 / @as(f32, @floatFromInt(items)), .y = 1.0 } });
    }

    pub fn MakeLabel(label: [:0]const u8, items: i32) !void {
        _ = try ui.MakeLabelWithLayout(label, .{ .percentOfParent = ui.Vec2{ .x = 1.0 / @as(f32, @floatFromInt(items)), .y = 1.0 } });
    }

    pub fn MakeGrid(comptime T: type, columns: [][:0]const u8, data: []T, MakeBody: *const fn (data: *const T, size: i32) anyerror!void) !void {
        try MakeColumnHeader(columns);

        try ui.PushStyle(.{ //
            .color = raylib.WHITE, //
            .hover_color = raylib.LIGHTGRAY, //
            .text_color = raylib.BLACK, //
            .text_size = 10, //
            .text_padding = 12, //
        });
        for (data) |item| {
            _ = try ui.PushBox("GridItem", .{ .drawBackground = true, .drawBorder = false, .hoverable = true }, .leftToRight, .fitToChildren);
            defer ui.PopBox();

            try MakeBody(&item, @as(i32, @intCast(columns.len)));
        }
        defer ui.PopStyle();
    }
};
