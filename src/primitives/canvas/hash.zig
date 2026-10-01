const geometry = @import("geometry");
const drawing_model = @import("drawing.zig");

const Affine = drawing_model.Affine;
const Color = drawing_model.Color;
const PathElement = drawing_model.PathElement;
const Radius = drawing_model.Radius;

const resource_hash_offset: u64 = 14695981039346656037;
const resource_hash_prime: u64 = 1099511628211;

pub fn resourceHashTag(tag: []const u8) u64 {
    return resourceHashBytes(resource_hash_offset, tag);
}

pub fn resourceHashBytes(initial: u64, bytes: []const u8) u64 {
    var hash = initial;
    for (bytes) |byte| hash = resourceHashU8(hash, byte);
    return hash;
}

pub fn resourceHashU8(hash: u64, value: u8) u64 {
    return (hash ^ value) *% resource_hash_prime;
}

pub fn resourceHashU32(hash: u64, value: u32) u64 {
    var next = hash;
    next = resourceHashU8(next, @intCast(value & 0xff));
    next = resourceHashU8(next, @intCast((value >> 8) & 0xff));
    next = resourceHashU8(next, @intCast((value >> 16) & 0xff));
    next = resourceHashU8(next, @intCast((value >> 24) & 0xff));
    return next;
}

pub fn resourceHashU64(hash: u64, value: u64) u64 {
    var next = hash;
    next = resourceHashU32(next, @intCast(value & 0xffff_ffff));
    next = resourceHashU32(next, @intCast((value >> 32) & 0xffff_ffff));
    return next;
}

pub fn resourceHashUsize(hash: u64, value: usize) u64 {
    return resourceHashU64(hash, @intCast(value));
}

pub fn resourceHashEnum(hash: u64, value: anytype) u64 {
    return resourceHashU64(hash, @intCast(value));
}

pub fn resourceHashF32(hash: u64, value: f32) u64 {
    const bits: u32 = @bitCast(value);
    return resourceHashU32(hash, bits);
}

pub fn resourceHashPoint(hash: u64, point: geometry.PointF) u64 {
    return resourceHashF32(resourceHashF32(hash, point.x), point.y);
}

pub fn resourceHashRect(hash: u64, rect: geometry.RectF) u64 {
    var next = resourceHashF32(hash, rect.x);
    next = resourceHashF32(next, rect.y);
    next = resourceHashF32(next, rect.width);
    next = resourceHashF32(next, rect.height);
    return next;
}

pub fn resourceHashOptionalRect(hash: u64, rect: ?geometry.RectF) u64 {
    if (rect) |value| return resourceHashRect(resourceHashU8(hash, 1), value);
    return resourceHashU8(hash, 0);
}

pub fn resourceHashOptionalObjectId(hash: u64, id: ?u64) u64 {
    if (id) |value| return resourceHashU64(resourceHashU8(hash, 1), value);
    return resourceHashU8(hash, 0);
}

pub fn resourceHashAffine(hash: u64, matrix: Affine) u64 {
    var next = resourceHashF32(hash, matrix.a);
    next = resourceHashF32(next, matrix.b);
    next = resourceHashF32(next, matrix.c);
    next = resourceHashF32(next, matrix.d);
    next = resourceHashF32(next, matrix.tx);
    next = resourceHashF32(next, matrix.ty);
    return next;
}

pub fn resourceHashRadius(hash: u64, radius: Radius) u64 {
    var next = resourceHashF32(hash, radius.top_left);
    next = resourceHashF32(next, radius.top_right);
    next = resourceHashF32(next, radius.bottom_right);
    next = resourceHashF32(next, radius.bottom_left);
    return next;
}

pub fn resourceHashColor(hash: u64, color: Color) u64 {
    var next = resourceHashF32(hash, color.r);
    next = resourceHashF32(next, color.g);
    next = resourceHashF32(next, color.b);
    next = resourceHashF32(next, color.a);
    return next;
}

pub fn resourceHashPath(hash: u64, elements: []const PathElement) u64 {
    var next = resourceHashUsize(resourceHashBytes(hash, "path"), elements.len);
    for (elements) |element| {
        next = resourceHashEnum(next, @backingInt(element.verb));
        next = resourceHashPoint(next, element.points[0]);
        next = resourceHashPoint(next, element.points[1]);
        next = resourceHashPoint(next, element.points[2]);
    }
    return next;
}
