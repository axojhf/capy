const std = @import("std");
const capy = @import("capy");
const Atom = capy.Atom;

pub usingnamespace capy.cross_platform;

/// Convert from degrees to radians.
fn deg2rad(theta: f32) f32 {
    return theta / 180.0 * std.math.pi;
}

pub const MapViewer_Impl = struct {
    pub usingnamespace capy.internal.All(MapViewer_Impl);

    // Required fields for all components.

    // The peer of the component is a widget in the backend we use, corresponding
    // to our component. For example here, using `capy.backend.Canvas` creates
    // a GtkDrawingBox on GTK+, a custom canvas on win32, a <canvas> element on
    // the web, etc.
    peer: ?capy.backend.Canvas = null,
    // .Handlers and .Atoms are implemented by `capy.internal.All(MapViewer_Impl)`
    widget_data: MapViewer_Impl.WidgetData = .{},

    // Our own component state.
    tileCache: std.AutoHashMap(TilePosition, Tile),
    pendingRequests: std.AutoHashMap(TilePosition, capy.http.HttpResponse),
    pendingSearchRequest: ?capy.http.HttpResponse = null,
    centerX: f32 = 0,
    centerY: f32 = 0,
    camZoom: u5 = 4,
    isDragging: bool = false,
    lastMouseX: i32 = 0,
    lastMouseY: i32 = 0,
    allocator: Atom(std.mem.Allocator) = Atom(std.mem.Allocator).of(capy.internal.lasting_allocator),

    const TilePosition = struct {
        zoom: u5,
        x: i32,
        y: i32,

        /// 'lon' and 'lat' are in degrees
        pub fn fromLonLat(zoom: u5, lon: f32, lat: f32) TilePosition {
            const n = std.math.pow(f32, 2, @as(f32, @floatFromInt(zoom)));
            const x = n * ((lon + 180) / 360);
            const lat_rad = deg2rad(lat);
            const y = n * (1 - (std.math.ln(std.math.tan(lat_rad) + (1.0 / std.math.cos(lat_rad))) / std.math.pi)) / 2;
            return TilePosition{ .zoom = zoom, .x = @as(i32, @intFromFloat(x)), .y = @as(i32, @intFromFloat(y)) };
        }
    };

    const Tile = struct { data: capy.ImageData };

    pub fn init(config: MapViewer_Impl.Config) MapViewer_Impl {
        var viewer = MapViewer_Impl.init_events(MapViewer_Impl{
            .tileCache = std.AutoHashMap(TilePosition, Tile).init(config.allocator),
            .pendingRequests = std.AutoHashMap(TilePosition, capy.http.HttpResponse).init(config.allocator),
            .allocator = Atom(std.mem.Allocator).of(config.allocator),
        });
        viewer.centerTo(2.3200, 48.8589);
        viewer.setName(config.name);
        return viewer;
    }

    // Implementation Methods
    pub fn getTile(self: *MapViewer_Impl, pos: TilePosition) ?Tile {
        const modTileXY = std.math.powi(i32, 2, pos.zoom) catch unreachable;
        const actual_pos = TilePosition{
            .zoom = pos.zoom,
            .x = @mod(pos.x, modTileXY),
            .y = @mod(pos.y, modTileXY),
        };
        if (self.tileCache.get(actual_pos)) |tile| {
            return tile;
        } else {
            if (self.pendingRequests.get(actual_pos) == null) {
                var buf: [2048]u8 = undefined;
                const url = std.fmt.bufPrint(&buf, "https://tile.openstreetmap.org/{}/{}/{}.png", .{ actual_pos.zoom, actual_pos.x, actual_pos.y }) catch unreachable;
                const request = capy.http.HttpRequest.get(url);
                const response = request.send() catch unreachable;
                self.pendingRequests.put(actual_pos, response) catch unreachable;
            }
            return null;
        }
    }

    pub fn centerTo(self: *MapViewer_Impl, lon: f32, lat: f32) void {
        const n = std.math.pow(f32, 2, @as(f32, @floatFromInt(self.camZoom)));
        const x = n * ((lon + 180) / 360);
        const lat_rad = deg2rad(lat);
        const y = n * (1 - (std.math.ln(std.math.tan(lat_rad) + (1.0 / std.math.cos(lat_rad))) / std.math.pi)) / 2;
        self.centerX = x * 256;
        self.centerY = y * 256;
    }

    pub fn search(self: *MapViewer_Impl, query: []const u8) !void {
        var buf: [2048]u8 = undefined;
        const encoded_query = try std.Uri.escapeQuery(capy.internal.scratch_allocator, query);
        defer capy.internal.scratch_allocator.free(encoded_query);
        const url = try std.fmt.bufPrint(&buf, "https://nominatim.openstreetmap.org/search?q={s}&format=jsonv2", .{encoded_query});

        const request = capy.http.HttpRequest.get(url);
        const response = try request.send();
        self.pendingSearchRequest = response;
    }

    pub fn checkRequests(self: *MapViewer_Impl) !void {
        if (self.pendingSearchRequest) |*response| {
            if (response.isReady()) {
                try response.checkError();
                // Read the body of the HTTP response and store it in memory
                const contents = try response.reader().readAllAlloc(capy.internal.scratch_allocator, std.math.maxInt(usize));
                defer capy.internal.scratch_allocator.free(contents);

                const value = try std.json.parseFromSlice(std.json.Value, capy.internal.scratch_allocator, contents, .{});
                defer value.deinit();

                const root = value.value.array;
                if (root.items.len > 0) { // if there's at least one result
                    const firstResult = root.items[0].object;
                    const lon = try std.fmt.parseFloat(f32, firstResult.get("lon").?.string);
                    const lat = try std.fmt.parseFloat(f32, firstResult.get("lat").?.string);

                    self.centerTo(lon, lat);
                }
                self.pendingSearchRequest = null;
                self.requestDraw() catch unreachable;
            }
        }

        var iterator = self.pendingRequests.keyIterator();
        while (iterator.next()) |key| {
            const response = self.pendingRequests.getPtr(key.*).?;
            if (response.isReady()) {
                // Read the body of the HTTP response and store it in memory
                const contents = try response.reader().readAllAlloc(capy.internal.scratch_allocator, std.math.maxInt(usize));
                defer capy.internal.scratch_allocator.free(contents);

                if (capy.ImageData.fromBuffer(capy.internal.lasting_allocator, contents)) |imageData| {
                    try self.tileCache.put(key.*, .{ .data = imageData });
                } else |err| switch (err) {
                    error.InvalidData => {
                        std.log.err("Invalid data at {}: {s}", .{ key.*, contents });
                    },
                    else => return err,
                }
                response.deinit();
                self.pendingRequests.removeByPtr(key);
                self.requestDraw() catch unreachable;
                break;
            }
        }
    }

    // Component Methods (drawing, showing, ...)

    // Here we'll draw ourselves the content of the map
    // It works because in MapViewer() function, we do addDrawHandler(MapViewer.draw)
    pub fn draw(self: *MapViewer_Impl, ctx: *capy.DrawContext) !void {
        const width = self.getWidth();
        const height = self.getHeight();
        ctx.clear(0, 0, width, height);

        const camX = @as(i32, @intFromFloat(self.centerX)) - @as(i32, @intCast(width / 2));
        const camY = @as(i32, @intFromFloat(self.centerY)) - @as(i32, @intCast(height / 2));
        var x: i32 = @divFloor(camX, 256);
        while (x < @divFloor(camX + @as(i32, @intCast(width)) + 255, 256)) : (x += 1) {
            var y: i32 = @divFloor(camY, 256);
            while (y < @divFloor(camY + @as(i32, @intCast(height)) + 255, 256)) : (y += 1) {
                self.drawTile(ctx, TilePosition{ .x = x, .y = y, .zoom = self.camZoom }, camX, camY);
            }
        }
    }

    fn drawTile(self: *MapViewer_Impl, ctx: *capy.DrawContext, pos: TilePosition, camX: i32, camY: i32) void {
        const x = -camX + pos.x * 256;
        const y = -camY + pos.y * 256;
        if (self.getTile(pos)) |tile| {
            ctx.image(x, y, 256, 256, tile.data);
        } else {
            var layout = capy.DrawContext.TextLayout.init();
            defer layout.deinit();
            var buf: [100]u8 = undefined;
            ctx.text(x, y, layout, std.fmt.bufPrint(&buf, "T{d},{d}@{d}", .{ pos.x, pos.y, pos.zoom }) catch unreachable);
        }
    }

    fn mouseButton(self: *MapViewer_Impl, button: capy.MouseButton, pressed: bool, x: i32, y: i32) !void {
        if (button == .Left) {
            self.isDragging = pressed;
            self.lastMouseX = x;
            self.lastMouseY = y;
        }
    }

    fn mouseMoved(self: *MapViewer_Impl, x: i32, y: i32) !void {
        if (self.isDragging) {
            // TODO: smooth move
            self.centerX -= @as(f32, @floatFromInt(x - self.lastMouseX));
            self.centerY -= @as(f32, @floatFromInt(y - self.lastMouseY));

            self.lastMouseX = x;
            self.lastMouseY = y;
            self.requestDraw() catch unreachable;
        }
    }

    fn mouseScroll(self: *MapViewer_Impl, dx: f32, dy: f32) !void {
        _ = dx;
        if (dy > 0 and self.camZoom > 0) {
            self.camZoom -|= 2 * @as(u5, @intFromFloat(dy));
            self.centerX /= 4 * dy;
            self.centerY /= 4 * dy;
        } else if (dy < 0 and self.camZoom < 18) {
            self.camZoom +|= 2 * @as(u5, @intFromFloat(-dy));
            self.centerX *= 4 * -dy;
            self.centerY *= 4 * -dy;
        }
        if (self.camZoom > 18) {
            self.camZoom = 18;
        }
        std.log.info("zoom: {d}, pos: {d}, {d}", .{ self.camZoom, self.centerX, self.centerY });
        self.requestDraw() catch unreachable;
    }

    // All components have this method, which is automatically called
    // when Capy needs to create the native peers of your widget.
    pub fn show(self: *MapViewer_Impl) !void {
        if (self.peer == null) {
            self.peer = try capy.backend.Canvas.create();
            try self.show_events();
        }
    }

    pub fn getPreferredSize(self: *MapViewer_Impl, available: capy.Size) capy.Size {
        _ = self;
        _ = available;
        return capy.Size{ .width = 500.0, .height = 200.0 };
    }
};

pub fn MapViewer(config: MapViewer_Impl.Config) !MapViewer_Impl {
    var map_viewer = MapViewer_Impl.init(config);
    _ = try map_viewer.addDrawHandler(&MapViewer_Impl.draw);
    _ = try map_viewer.addMouseButtonHandler(&MapViewer_Impl.mouseButton);
    _ = try map_viewer.addMouseMotionHandler(&MapViewer_Impl.mouseMoved);
    _ = try map_viewer.addScrollHandler(&MapViewer_Impl.mouseScroll);
    return map_viewer;
}

pub fn main() !void {
    try capy.backend.init();

    var window = try capy.Window.init();
    try window.set(
        capy.Column(.{}, .{
            capy.Row(.{}, .{
                capy.Expanded(capy.TextField(.{ .name = "location-input" })),
                capy.Button(.{ .label = "Go!", .onclick = onGo }),
            }),
            capy.Expanded(MapViewer(.{ .name = "map-viewer" })),
        }),
    );
    window.setTitle("OpenStreetMap Viewer");
    window.show();

    while (capy.stepEventLoop(.Asynchronous)) {
        const root = window.getChild().?.as(capy.Container_Impl);
        const viewer = root.getChildAs(MapViewer_Impl, "map-viewer").?;
        try viewer.checkRequests();
    }
}

fn onGo(self_ptr: *anyopaque) !void {
    const self = @as(*capy.Button_Impl, @ptrCast(@alignCast(self_ptr))); // due to ZIG BUG
    const root = self.getRoot().?.as(capy.Container_Impl);
    const viewer = root.getChildAs(MapViewer_Impl, "map-viewer").?;
    const input = root.getChildAs(capy.TextField_Impl, "location-input").?;
    try viewer.search(input.get("text"));
}
