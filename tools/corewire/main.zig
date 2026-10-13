//! corewire — the contract-sidecar shim generator.
//!
//!   corewire --sidecar core.contract.json --out core_shim.zig
//!   corewire --sidecar core.contract.json --facade core_facade.ts --profile core_profile.json --effective-sidecar effective.contract.json
//!   corewire --sidecar core.contract.json --check
//!
//! Reads the JSON contract sidecar a core-mode compile emits beside the
//! compiled object, validates it (schema rules V1-V14, teaching
//! refusals with exact field paths on stderr), and writes the Zig
//! mirror module the app wiring imports (see emit.zig for what the
//! mirror carries). `--facade` writes the TypeScript projection,
//! `--profile` the library-mode compiler profile that builds it
//! (scriptc-compiled emit_profile.ts). `--check` validates and stops — the checker-tier
//! entry point.
//!
//! The build stages the output beside tools/corewire/shim_rt.zig and
//! tools/corewire/core_abi.zig; the generated module imports both
//! relatively, the way transpiler output imports its staged rt.zig.

const std = @import("std");
const sidecar_mod = @import("sidecar.zig");
const invocation_mod = @import("invocation.zig");
const service_contract_mod = @import("service_contract.zig");
const filesystem = @import("filesystem_coordination.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const invocation = try invocation_mod.plan(arena, args);
    if (invocation.exit_code != 0) {
        try stderr.writeAll(invocation.@"error");
        try stderr.flush();
        std.process.exit(invocation.exit_code);
    }
    if (invocation.mode == .service) return serviceProjection(init, args, invocation, stderr);
    const input = args[invocation.input.?];
    var facade_path: ?[]const u8 = null;
    var profile_path: ?[]const u8 = null;
    for (invocation.outputs) |out| switch (out.kind) {
        .mirror => {},
        .facade => facade_path = args[out.path_index],
        .profile => profile_path = args[out.path_index],
        .effective => {},
        else => unreachable,
    };
    // Distinct paths only: the projections must not overwrite each
    // other, and no output may destroy the input contract. Compared
    // lexically normalized (cwd-resolved, `.`/`..` folded) — filesystem
    // identities beyond spelling (symlinks, hard links) stay the
    // caller's responsibility.
    const input_resolved = try filesystem.canonicalSpelling(init.io, arena, input);
    // The staging PREFIX spellings join the checked set: outputs land
    // by rename from exclusively-created `<path>.corewire-tmp.<nonce>`
    // files, and a sidecar sitting on the prefix spelling is close
    // enough to a claimed name to refuse outright.
    const paths = try filesystem.aliasPaths(arena, invocation, args);
    const resolved = try arena.alloc([]const u8, paths.len);
    for (paths, 0..) |path, path_index| resolved[path_index] = try filesystem.canonicalSpelling(init.io, arena, path);
    var canonical_paths: std.ArrayList([]const u8) = .empty;
    for (resolved) |path| try canonical_paths.append(arena, path);
    const identities = try arena.alloc([]const bool, canonical_paths.items.len);
    for (canonical_paths.items, 0..) |path, i| {
        const row = try arena.alloc(bool, canonical_paths.items.len + 1);
        @memset(row, false);
        row[0] = try filesystem.sameExistingFile(init.io, arena, path, input_resolved);
        for (canonical_paths.items[i + 1 ..], i + 1..) |other, j| row[j + 1] = try filesystem.sameExistingFile(init.io, arena, path, other);
        identities[i] = row;
    }
    const alias_diagnostic = try invocation_mod.aliases(arena, input_resolved, canonical_paths.items, identities);
    if (alias_diagnostic.len != 0) {
        try stderr.writeAll(alias_diagnostic);
        try stderr.flush();
        std.process.exit(2);
    }

    const source = std.Io.Dir.cwd().readFileAlloc(init.io, input, arena, .limited(sidecar_mod.max_sidecar_bytes)) catch |err| {
        try stderr.print("corewire: cannot read {s}: {t}\n", .{ input, err });
        try stderr.flush();
        std.process.exit(1);
    };

    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = sidecar_mod.read(arena, source, &diags) catch |err| switch (err) {
        error.Refused => {
            try diags.write(input, stderr);
            try stderr.flush();
            std.process.exit(1);
        },
        error.OutOfMemory => return err,
    };

    // OS-relative entry facts are computed here; compiled coordination
    // decides when to enforce them, after mirror/facade admission.
    var entry: invocation_mod.Entry = .{};
    if (facade_path != null and profile_path != null) {
        const profile_dir = std.fs.path.dirname(profile_path.?) orelse ".";
        entry = try profileRelativeEntry(init, profile_dir, facade_path.?);
    } else if (facade_path) |path| {
        const name = std.fs.path.basename(path);
        entry = .{ .text = if (std.unicode.utf8ValidateSlice(name)) name else "", .utf8 = std.unicode.utf8ValidateSlice(name), .bytes = name };
    }
    const result = try invocation_mod.core(arena, parsed, invocation, args, entry, source);
    for (result.diagnostics) |diagnostic| diags.flag(diagnostic.path, "{s}", .{diagnostic.message});
    if (result.exit_code != 0) {
        if (result.@"error".len != 0) try stderr.writeAll(result.@"error") else try diags.write(input, stderr);
        try stderr.flush();
        std.process.exit(result.exit_code);
    }
    // Warnings (unknown additive fields) surface even on success.
    try diags.write(input, stderr);
    try stderr.flush();

    const code = try filesystem.execute(init, stderr, invocation, args, result, null);
    if (code != 0) std.process.exit(code);
}

/// The service contract is a distinct schema from core.contract.json. Keep
/// its projection mode explicit so neither reader can accidentally accept a
/// document from the other class.
fn serviceProjection(init: std.process.Init, args: []const []const u8, invocation: invocation_mod.Plan, stderr: *std.Io.Writer) !void {
    const sidecar_path = args[invocation.input.?];
    const arena = init.arena.allocator();
    const source = std.Io.Dir.cwd().readFileAlloc(init.io, sidecar_path, arena, .limited(service_contract_mod.max_bytes)) catch |err| {
        try stderr.print("corewire: cannot read {s}: {t}\n", .{ sidecar_path, err });
        try stderr.flush();
        std.process.exit(1);
    };
    const contract = service_contract_mod.read(arena, source, stderr) catch |err| switch (err) {
        error.InvalidContract => {
            try stderr.flush();
            std.process.exit(1);
        },
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.WriteFailed,
    };
    const code = try filesystem.execute(init, stderr, invocation, args, null, contract);
    if (code != 0) std.process.exit(code);
    try stderr.flush();
}

/// The facade path as the profile's entry spelling: relative to the
/// profile file's directory (the compilation root a profile consumer
/// resolves against), POSIX separators. A pair that cannot relate
/// (distinct roots) refuses with a teaching — a wrong spelling would
/// point the consumer at a file that does not exist.
fn profileRelativeEntry(init: std.process.Init, profile_dir: []const u8, facade_path: []const u8) !invocation_mod.Entry {
    const arena = init.arena.allocator();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.Io.Dir.cwd().realPath(init.io, &buffer) catch 0;
    const cwd: []const u8 = if (cwd_len == 0) "." else buffer[0..cwd_len];
    const related = try std.fs.path.relative(arena, cwd, init.environ_map, profile_dir, facade_path);
    const posix = try arena.dupe(u8, related);
    if (std.fs.path.sep == std.fs.path.sep_windows) for (posix) |*char| {
        if (char.* == std.fs.path.sep_windows) char.* = std.fs.path.sep_posix;
    };
    const valid = std.unicode.utf8ValidateSlice(posix);
    return .{ .text = if (valid) posix else "", .bytes = posix, .utf8 = valid, .unrelated = related.len == 0 or std.fs.path.isAbsolute(related), .facade_path = facade_path, .profile_directory = profile_dir };
}
