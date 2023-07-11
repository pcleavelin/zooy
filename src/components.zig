const ui = @import("lib.zig");

const raylib = ui.raylib;

pub const Grid = struct {
    fn MakeColumnHeader(ctx: *ui.UIContext, columns: [][]const u8) !void {
        _ = try ctx.PushBox("GridColumnHeader", .{ .drawBackground = true, .drawBorder = false }, .leftToRight, .fitToChildren);
        defer ctx.PopBox();

        try ctx.PushStyle(.{ //
            .color = raylib.WHITE, //
            .text_color = .{ .r = 0x18, .g = 0x90, .b = 0xff, .a = 0xff }, //
            .text_size = 12, //
            .text_padding = 12, //
        });
        defer ctx.PopStyle();

        for (columns) |column| {
            try MakeLabel(ctx, column, @as(i32, @intCast(columns.len)));
        }
    }

    pub fn MakeButton(ctx: *ui.UIContext, label: []const u8, items: i32) !bool {
        return try ctx.MakeBox(label, .{
            .clickable = true,
            .drawText = true,
        }, .leftToRight, .{ .percentOfParent = ui.Vec2{ .x = 1.0 / @as(f32, @floatFromInt(items)), .y = 1.0 } });
    }

    pub fn MakeFormattedLabel(ctx: *ui.UIContext, comptime str: []const u8, args: anytype, items: i32) !void {
        _ = try ctx.MakeFormattedLabelWithLayout(str, args, .{ .percentOfParent = ui.Vec2{ .x = 1.0 / @as(f32, @floatFromInt(items)), .y = 1.0 } });
    }

    pub fn MakeLabel(ctx: *ui.UIContext, label: []const u8, items: i32) !void {
        _ = try ctx.MakeLabelWithLayout(label, .{ .percentOfParent = ui.Vec2{ .x = 1.0 / @as(f32, @floatFromInt(items)), .y = 1.0 } });
    }

    pub fn MakeGrid(ctx: *ui.UIContext, comptime T: type, columns: [][]const u8, data: []T, MakeBody: *const fn (ctx: *ui.UIContext, data: *const T, size: i32) anyerror!void) !void {
        _ = try ctx.PushBox("GridContainer", .{ .drawBackground = true }, .topToBottom, .fill);
        defer ctx.PopBox();

        try MakeColumnHeader(ctx, columns);

        {
            try ctx.PushStyle(.{ //
                .color = raylib.WHITE, //
                .hover_color = .{ .r = 0x1a, .g = 0x7c, .b = 0xd3, .a = 0xff }, //
                .text_color = raylib.BLACK, //
                .text_size = 12, //
                .text_padding = 12, //
            });
            defer ctx.PopStyle();

            _ = try ctx.PushBox("Grid", .{ .drawBackground = true, .scrollable = true }, .topToBottom, .fill);
            defer ctx.PopBox();

            try ctx.PushStyle(.{ //
                .color = raylib.WHITE, //
                .hover_color = raylib.LIGHTGRAY, //
                .text_color = raylib.BLACK, //
                .text_size = 12, //
                .text_padding = 12, //
            });
            for (data) |item| {
                _ = try ctx.PushBox("GridItem", .{ .drawBackground = true, .drawBorder = false, .hoverable = true }, .leftToRight, .fitToChildren);
                defer ctx.PopBox();

                try MakeBody(ctx, &item, @as(i32, @intCast(columns.len)));
            }
            ctx.PopStyle();
        }
    }
};
