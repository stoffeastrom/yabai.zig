const std = @import("std");
const c = @import("../platform/c.zig");

pub const Point = struct {
    x: f64 = 0,
    y: f64 = 0,

    pub fn init(x: f64, y: f64) Point {
        return .{ .x = x, .y = y };
    }

    pub fn fromCG(p: c.CGPoint) Point {
        return .{ .x = p.x, .y = p.y };
    }

    pub fn toCG(self: Point) c.CGPoint {
        return .{ .x = self.x, .y = self.y };
    }

    pub fn add(self: Point, other: Point) Point {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub fn sub(self: Point, other: Point) Point {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }

    pub fn eql(self: Point, other: Point) bool {
        return self.x == other.x and self.y == other.y;
    }
};

pub const Size = struct {
    width: f64 = 0,
    height: f64 = 0,

    pub fn init(width: f64, height: f64) Size {
        return .{ .width = width, .height = height };
    }

    pub fn fromCG(s: c.c.CGSize) Size {
        return .{ .width = s.width, .height = s.height };
    }

    pub fn toCG(self: Size) c.c.CGSize {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn eql(self: Size, other: Size) bool {
        return self.width == other.width and self.height == other.height;
    }
};

pub const Rect = struct {
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,

    pub fn init(x: f64, y: f64, width: f64, height: f64) Rect {
        return .{ .x = x, .y = y, .width = width, .height = height };
    }

    pub fn fromCG(r: c.CGRect) Rect {
        return .{
            .x = r.origin.x,
            .y = r.origin.y,
            .width = r.size.width,
            .height = r.size.height,
        };
    }

    pub fn toCG(self: Rect) c.CGRect {
        return .{
            .origin = .{ .x = self.x, .y = self.y },
            .size = .{ .width = self.width, .height = self.height },
        };
    }

    pub fn origin(self: Rect) Point {
        return .{ .x = self.x, .y = self.y };
    }

    pub fn size(self: Rect) Size {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn center(self: Rect) Point {
        return .{
            .x = self.x + self.width / 2,
            .y = self.y + self.height / 2,
        };
    }

    pub fn maxX(self: Rect) f64 {
        return self.x + self.width;
    }

    pub fn maxY(self: Rect) f64 {
        return self.y + self.height;
    }

    pub fn contains(self: Rect, point: Point) bool {
        return point.x >= self.x and point.x < self.maxX() and
            point.y >= self.y and point.y < self.maxY();
    }

    pub fn intersects(self: Rect, other: Rect) bool {
        return self.x < other.maxX() and self.maxX() > other.x and
            self.y < other.maxY() and self.maxY() > other.y;
    }

    pub fn intersection(self: Rect, other: Rect) ?Rect {
        if (!self.intersects(other)) return null;

        const x = @max(self.x, other.x);
        const y = @max(self.y, other.y);
        const max_x = @min(self.maxX(), other.maxX());
        const max_y = @min(self.maxY(), other.maxY());

        return .{
            .x = x,
            .y = y,
            .width = max_x - x,
            .height = max_y - y,
        };
    }

    pub fn union_(self: Rect, other: Rect) Rect {
        const x = @min(self.x, other.x);
        const y = @min(self.y, other.y);
        const max_x = @max(self.maxX(), other.maxX());
        const max_y = @max(self.maxY(), other.maxY());

        return .{
            .x = x,
            .y = y,
            .width = max_x - x,
            .height = max_y - y,
        };
    }

    pub fn inset(self: Rect, dx: f64, dy: f64) Rect {
        return .{
            .x = self.x + dx,
            .y = self.y + dy,
            .width = self.width - 2 * dx,
            .height = self.height - 2 * dy,
        };
    }

    pub fn eql(self: Rect, other: Rect) bool {
        return self.x == other.x and self.y == other.y and
            self.width == other.width and self.height == other.height;
    }

    pub fn area(self: Rect) f64 {
        return self.width * self.height;
    }
};

// Tests
test "Point operations" {
    const p1 = Point.init(10, 20);
    const p2 = Point.init(5, 10);

    try std.testing.expectEqual(Point.init(15, 30), p1.add(p2));
    try std.testing.expectEqual(Point.init(5, 10), p1.sub(p2));
    try std.testing.expect(p1.eql(Point.init(10, 20)));
}

test "Rect contains point" {
    const r = Rect.init(0, 0, 100, 100);

    try std.testing.expect(r.contains(Point.init(50, 50)));
    try std.testing.expect(r.contains(Point.init(0, 0)));
    try std.testing.expect(!r.contains(Point.init(100, 100)));
    try std.testing.expect(!r.contains(Point.init(-1, 50)));
}

test "Rect intersection" {
    const r1 = Rect.init(0, 0, 100, 100);
    const r2 = Rect.init(50, 50, 100, 100);
    const r3 = Rect.init(200, 200, 50, 50);

    try std.testing.expect(r1.intersects(r2));
    try std.testing.expect(!r1.intersects(r3));

    const inter = r1.intersection(r2).?;
    try std.testing.expectEqual(@as(f64, 50), inter.x);
    try std.testing.expectEqual(@as(f64, 50), inter.y);
    try std.testing.expectEqual(@as(f64, 50), inter.width);
    try std.testing.expectEqual(@as(f64, 50), inter.height);
}

test "Rect inset" {
    const r = Rect.init(0, 0, 100, 100);
    const inset_r = r.inset(10, 20);

    try std.testing.expectEqual(@as(f64, 10), inset_r.x);
    try std.testing.expectEqual(@as(f64, 20), inset_r.y);
    try std.testing.expectEqual(@as(f64, 80), inset_r.width);
    try std.testing.expectEqual(@as(f64, 60), inset_r.height);
}

test "CG conversion roundtrip" {
    const r = Rect.init(10, 20, 100, 200);
    const cg = r.toCG();
    const back = Rect.fromCG(cg);

    try std.testing.expect(r.eql(back));
}

test "Rect center" {
    const r = Rect.init(0, 0, 100, 200);
    const c_ = r.center();
    try std.testing.expectEqual(@as(f64, 50), c_.x);
    try std.testing.expectEqual(@as(f64, 100), c_.y);
}

test "Rect maxX maxY" {
    const r = Rect.init(10, 20, 100, 200);
    try std.testing.expectEqual(@as(f64, 110), r.maxX());
    try std.testing.expectEqual(@as(f64, 220), r.maxY());
}

test "Rect union" {
    const r1 = Rect.init(0, 0, 50, 50);
    const r2 = Rect.init(100, 100, 50, 50);
    const u = r1.union_(r2);

    try std.testing.expectEqual(@as(f64, 0), u.x);
    try std.testing.expectEqual(@as(f64, 0), u.y);
    try std.testing.expectEqual(@as(f64, 150), u.width);
    try std.testing.expectEqual(@as(f64, 150), u.height);
}

test "Rect area" {
    const r = Rect.init(0, 0, 100, 200);
    try std.testing.expectEqual(@as(f64, 20000), r.area());
}

test "Rect intersection returns null for non-overlapping" {
    const r1 = Rect.init(0, 0, 50, 50);
    const r2 = Rect.init(100, 100, 50, 50);
    try std.testing.expectEqual(@as(?Rect, null), r1.intersection(r2));
}

test "Size operations" {
    const s1 = Size.init(100, 200);
    const s2 = Size.init(100, 200);
    const s3 = Size.init(50, 100);

    try std.testing.expect(s1.eql(s2));
    try std.testing.expect(!s1.eql(s3));
}

test "Point CG conversion roundtrip" {
    const p = Point.init(10, 20);
    const cg = p.toCG();
    const back = Point.fromCG(cg);
    try std.testing.expect(p.eql(back));
}

test "Size CG conversion roundtrip" {
    const s = Size.init(100, 200);
    const cg = s.toCG();
    const back = Size.fromCG(cg);
    try std.testing.expect(s.eql(back));
}

test "Rect origin and size" {
    const r = Rect.init(10, 20, 100, 200);
    try std.testing.expect(r.origin().eql(Point.init(10, 20)));
    try std.testing.expect(r.size().eql(Size.init(100, 200)));
}
