const std = @import("std");

pub fn referenceBlurKernel(output: []f32, kernel_radius: i64, radius: f32) []const f32 {
    const kernel_width: usize = @intCast(kernel_radius * 2 + 1);
    var index: usize = 0;
    var dy: i64 = -kernel_radius;
    while (dy <= kernel_radius) : (dy += 1) {
        var dx: i64 = -kernel_radius;
        while (dx <= kernel_radius) : (dx += 1) {
            output[index] = referenceBlurWeight(dx, dy, radius);
            index += 1;
        }
    }
    return output[0 .. kernel_width * kernel_width];
}

pub fn referenceBlurSampleWithKernel(source: []const u8, width: usize, height: usize, x: i64, y: i64, kernel_radius: i64, kernel: []const f32) [4]u8 {
    const width_i: i64 = @intCast(width);
    const height_i: i64 = @intCast(height);
    const kernel_width: usize = @intCast(kernel_radius * 2 + 1);
    var premultiplied = @as([3]f32, @splat(0));
    var alpha_total: f32 = 0;
    var weight_total: f32 = 0;

    var dy: i64 = -kernel_radius;
    while (dy <= kernel_radius) : (dy += 1) {
        const sample_y = y + dy;
        if (sample_y < 0 or sample_y >= height_i) continue;

        var dx: i64 = -kernel_radius;
        while (dx <= kernel_radius) : (dx += 1) {
            const sample_x = x + dx;
            if (sample_x < 0 or sample_x >= width_i) continue;

            const kernel_y: usize = @intCast(dy + kernel_radius);
            const kernel_x: usize = @intCast(dx + kernel_radius);
            const weight = kernel[kernel_y * kernel_width + kernel_x];
            const sample_index = (@as(usize, @intCast(sample_y)) * width + @as(usize, @intCast(sample_x))) * 4;
            const alpha = @as(f32, @floatFromInt(source[sample_index + 3])) / 255.0;
            premultiplied[0] += (@as(f32, @floatFromInt(source[sample_index + 0])) / 255.0) * alpha * weight;
            premultiplied[1] += (@as(f32, @floatFromInt(source[sample_index + 1])) / 255.0) * alpha * weight;
            premultiplied[2] += (@as(f32, @floatFromInt(source[sample_index + 2])) / 255.0) * alpha * weight;
            alpha_total += alpha * weight;
            weight_total += weight;
        }
    }

    return referenceBlurOutput(premultiplied, alpha_total, weight_total);
}

pub fn referenceBlurSample(source: []const u8, width: usize, height: usize, x: i64, y: i64, kernel_radius: i64, radius: f32) [4]u8 {
    const width_i: i64 = @intCast(width);
    const height_i: i64 = @intCast(height);
    var premultiplied = @as([3]f32, @splat(0));
    var alpha_total: f32 = 0;
    var weight_total: f32 = 0;

    var dy: i64 = -kernel_radius;
    while (dy <= kernel_radius) : (dy += 1) {
        const sample_y = y + dy;
        if (sample_y < 0 or sample_y >= height_i) continue;

        var dx: i64 = -kernel_radius;
        while (dx <= kernel_radius) : (dx += 1) {
            const sample_x = x + dx;
            if (sample_x < 0 or sample_x >= width_i) continue;

            const weight = referenceBlurWeight(dx, dy, radius);
            const sample_index = (@as(usize, @intCast(sample_y)) * width + @as(usize, @intCast(sample_x))) * 4;
            const alpha = @as(f32, @floatFromInt(source[sample_index + 3])) / 255.0;
            premultiplied[0] += (@as(f32, @floatFromInt(source[sample_index + 0])) / 255.0) * alpha * weight;
            premultiplied[1] += (@as(f32, @floatFromInt(source[sample_index + 1])) / 255.0) * alpha * weight;
            premultiplied[2] += (@as(f32, @floatFromInt(source[sample_index + 2])) / 255.0) * alpha * weight;
            alpha_total += alpha * weight;
            weight_total += weight;
        }
    }

    return referenceBlurOutput(premultiplied, alpha_total, weight_total);
}

fn referenceBlurOutput(premultiplied: [3]f32, alpha_total: f32, weight_total: f32) [4]u8 {
    if (weight_total <= 0) return .{ 0, 0, 0, 0 };
    const alpha = alpha_total / weight_total;
    if (alpha <= 0) return .{ 0, 0, 0, 0 };
    const unpremultiply = 1 / (weight_total * alpha);
    return .{
        colorChannelToByte(premultiplied[0] * unpremultiply),
        colorChannelToByte(premultiplied[1] * unpremultiply),
        colorChannelToByte(premultiplied[2] * unpremultiply),
        colorChannelToByte(alpha),
    };
}

fn referenceBlurWeight(dx: i64, dy: i64, radius: f32) f32 {
    const sigma = @max(radius, 0.5);
    const x = @as(f32, @floatFromInt(dx));
    const y = @as(f32, @floatFromInt(dy));
    return @exp(-(x * x + y * y) / (2 * sigma * sigma));
}

fn colorChannelToByte(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255.0));
}
