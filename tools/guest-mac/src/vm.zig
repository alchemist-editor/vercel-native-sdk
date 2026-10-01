//! Zig bindings for the guest-mac VM engine (src/vm_host.m, Apple
//! Virtualization.framework behind a C ABI). The `Engine` wrapper owns the
//! host handle and funnels every engine event into an `Events` accumulator
//! the CLI loop and the UI app both poll from the main thread. Also home
//! to the named-VM path layout (~/.native/guest-mac/vms/<name>/), the
//! legacy-bundle migration, the running-VM census behind the two-guest
//! cap, and the copy-on-write file clone `guest-mac clone` uses.

const std = @import("std");
const cli = @import("cli.zig");

pub const State = enum(c_int) {
    no_bundle = 0,
    fetching = 1,
    installing = 2,
    stopped = 3,
    starting = 4,
    running = 5,
    stopping = 6,
    err = 7,

    pub fn name(self: State) []const u8 {
        return switch (self) {
            .no_bundle => "no-bundle",
            .fetching => "fetching",
            .installing => "installing",
            .stopped => "stopped",
            .starting => "starting",
            .running => "running",
            .stopping => "stopping",
            .err => "error",
        };
    }
};

pub const EventKind = enum(c_int) {
    state_changed = 0,
    download_progress = 1,
    install_progress = 2,
    log = 3,
    err = 4,
};

const Host = opaque {};
const EventCallback = *const fn (context: ?*anyopaque, event_kind: c_int, state: c_int, progress: f64, message: [*]const u8, message_len: usize) callconv(.c) void;

extern fn guest_mac_vm_create(bundle_dir: [*]const u8, bundle_dir_len: usize, cache_dir: [*]const u8, cache_dir_len: usize) ?*Host;
extern fn guest_mac_vm_destroy(host: *Host) void;
extern fn guest_mac_vm_set_callback(host: *Host, callback: EventCallback, context: ?*anyopaque) void;
extern fn guest_mac_vm_state(host: *Host) c_int;
extern fn guest_mac_vm_fetch_restore_image(host: *Host) c_int;
extern fn guest_mac_vm_install(host: *Host, ipsw_path: [*]const u8, ipsw_path_len: usize, cpus: u32, memory_bytes: u64, disk_bytes: u64) c_int;
extern fn guest_mac_vm_configure(host: *Host, share_dir: [*]const u8, share_dir_len: usize, share_tag: [*]const u8, share_tag_len: usize, cpus: u32, memory_bytes: u64) c_int;
extern fn guest_mac_vm_start(host: *Host) c_int;
extern fn guest_mac_vm_request_stop(host: *Host) c_int;
extern fn guest_mac_vm_force_stop(host: *Host) c_int;
extern fn guest_mac_vm_mac_address(host: *Host, buffer: [*]u8, buffer_len: usize) usize;
extern fn guest_mac_vm_display_view(host: *Host) ?*anyopaque;
extern fn guest_mac_vm_pump_main_loop(seconds: f64) void;
extern fn guest_mac_vm_write_fresh_machine_identifier(path: [*]const u8, path_len: usize) c_int;

fn stateFromInt(value: c_int) State {
    if (value < 0 or value > @backingInt(State.err)) return .err;
    return @fromBackingInt(@intCast(value));
}

pub fn pumpMainLoop(seconds: f64) void {
    guest_mac_vm_pump_main_loop(seconds);
}

/// Write a brand-new VZMacMachineIdentifier to `path` — the unique
/// hardware identity a cloned bundle must NOT share with its source.
pub fn writeFreshMachineIdentifier(path: []const u8) bool {
    return guest_mac_vm_write_fresh_machine_identifier(path.ptr, path.len) != 0;
}

/// Accumulated engine events, polled from the main thread (engine
/// callbacks are delivered on the main queue, so no locking).
pub const Events = struct {
    state: State = .no_bundle,
    download_progress: f64 = 0,
    install_progress: f64 = 0,
    /// Last log/state/error message, truncated to the buffer.
    message: [512]u8 = @splat(0),
    message_len: usize = 0,
    /// Cache path reported by fetch ("ipsw:<path>" log messages).
    ipsw_path: [512]u8 = @splat(0),
    ipsw_path_len: usize = 0,
    failed: bool = false,
    log_to_stderr: bool = false,

    pub fn lastMessage(self: *const Events) []const u8 {
        return self.message[0..self.message_len];
    }

    pub fn ipswPath(self: *const Events) ?[]const u8 {
        if (self.ipsw_path_len == 0) return null;
        return self.ipsw_path[0..self.ipsw_path_len];
    }

    pub fn record(self: *Events, kind: EventKind, state: State, progress: f64, message: []const u8) void {
        self.state = state;
        switch (kind) {
            .download_progress => self.download_progress = progress,
            .install_progress => self.install_progress = progress,
            .state_changed, .log, .err => {
                self.message_len = @min(message.len, self.message.len);
                @memcpy(self.message[0..self.message_len], message[0..self.message_len]);
                if (kind == .err) self.failed = true;
                if (std.mem.startsWith(u8, message, "ipsw:")) {
                    const path = message["ipsw:".len..];
                    self.ipsw_path_len = @min(path.len, self.ipsw_path.len);
                    @memcpy(self.ipsw_path[0..self.ipsw_path_len], path[0..self.ipsw_path_len]);
                }
                if (self.log_to_stderr and message.len > 0) {
                    std.debug.print("guest-mac: {s}\n", .{message});
                }
            },
        }
    }
};

fn eventTrampoline(context: ?*anyopaque, event_kind: c_int, state: c_int, progress: f64, message: [*]const u8, message_len: usize) callconv(.c) void {
    const events: *Events = @ptrCast(@alignCast(context.?));
    if (event_kind < 0 or event_kind > @backingInt(EventKind.err)) return;
    if (state < 0 or state > @backingInt(State.err)) return;
    const kind: EventKind = @fromBackingInt(@intCast(event_kind));
    const state_value: State = @fromBackingInt(@intCast(state));
    events.record(kind, state_value, progress, message[0..message_len]);
}

pub const Engine = struct {
    host: *Host,
    events: *Events,

    pub fn create(bundle_dir: []const u8, cache_dir: []const u8, events: *Events) !Engine {
        const host = guest_mac_vm_create(bundle_dir.ptr, bundle_dir.len, cache_dir.ptr, cache_dir.len) orelse return error.EngineUnavailable;
        guest_mac_vm_set_callback(host, eventTrampoline, events);
        events.state = stateFromInt(guest_mac_vm_state(host));
        return .{ .host = host, .events = events };
    }

    pub fn destroy(self: Engine) void {
        guest_mac_vm_destroy(self.host);
    }

    pub fn state(self: Engine) State {
        return stateFromInt(guest_mac_vm_state(self.host));
    }

    pub fn fetchRestoreImage(self: Engine) !void {
        if (guest_mac_vm_fetch_restore_image(self.host) == 0) return error.FetchFailed;
    }

    pub fn install(self: Engine, ipsw_path: []const u8, cpus: u32, memory_bytes: u64, disk_bytes: u64) !void {
        if (guest_mac_vm_install(self.host, ipsw_path.ptr, ipsw_path.len, cpus, memory_bytes, disk_bytes) == 0) return error.InstallFailed;
    }

    pub fn configure(self: Engine, share_dir: []const u8, share_tag: []const u8, cpus: u32, memory_bytes: u64) !void {
        if (guest_mac_vm_configure(self.host, share_dir.ptr, share_dir.len, share_tag.ptr, share_tag.len, cpus, memory_bytes) == 0) return error.ConfigureFailed;
    }

    pub fn start(self: Engine) !void {
        if (guest_mac_vm_start(self.host) == 0) return error.StartFailed;
    }

    pub fn requestStop(self: Engine) !void {
        if (guest_mac_vm_request_stop(self.host) == 0) return error.StopFailed;
    }

    pub fn forceStop(self: Engine) !void {
        if (guest_mac_vm_force_stop(self.host) == 0) return error.StopFailed;
    }

    pub fn macAddress(self: Engine, buffer: []u8) ?[]const u8 {
        const len = guest_mac_vm_mac_address(self.host, buffer.ptr, buffer.len);
        if (len == 0) return null;
        return buffer[0..len];
    }

    /// The engine's VZVirtualMachineView (an NSView*), ready for
    /// `Runtime.adoptViewSurface`. Null before `configure`.
    pub fn displayView(self: Engine) ?*anyopaque {
        return guest_mac_vm_display_view(self.host);
    }
};

// ---- host helpers (libc-backed; this tool always links libc) -----------------

pub fn homeDir() ?[]const u8 {
    const value = std.c.getenv("HOME") orelse return null;
    const text = std.mem.span(value);
    return if (text.len == 0) null else text;
}

pub fn currentDir(buffer: []u8) ?[]const u8 {
    const ptr = std.c.getcwd(buffer.ptr, buffer.len) orelse return null;
    return std.mem.span(@as([*:0]u8, @ptrCast(ptr)));
}

fn pathZ(buffer: *[1024]u8, path: []const u8) ?[*:0]const u8 {
    if (path.len == 0 or path.len >= buffer.len) return null;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    return buffer[0..path.len :0];
}

pub fn fileExists(path: []const u8) bool {
    var buffer: [1024]u8 = undefined;
    const path_z = pathZ(&buffer, path) orelse return false;
    return std.c.access(path_z, 0) == 0;
}

pub fn makeDir(path: []const u8) bool {
    var buffer: [1024]u8 = undefined;
    const path_z = pathZ(&buffer, path) orelse return false;
    if (std.c.mkdir(path_z, 0o755) == 0) return true;
    return fileExists(path);
}

pub fn readFileInto(path: []const u8, buffer: []u8) ?[]const u8 {
    var path_buffer: [1024]u8 = undefined;
    const path_z = pathZ(&path_buffer, path) orelse return null;
    const fd = std.c.open(path_z, .{});
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var total: usize = 0;
    while (total < buffer.len) {
        const amount = std.c.read(fd, buffer.ptr + total, buffer.len - total);
        if (amount <= 0) break;
        total += @intCast(amount);
    }
    return buffer[0..total];
}

pub fn writeFile(path: []const u8, bytes: []const u8) bool {
    var path_buffer: [1024]u8 = undefined;
    const path_z = pathZ(&path_buffer, path) orelse return false;
    const fd = std.c.open(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    var total: usize = 0;
    while (total < bytes.len) {
        const amount = std.c.write(fd, bytes.ptr + total, bytes.len - total);
        if (amount <= 0) return false;
        total += @intCast(amount);
    }
    return true;
}

pub fn processAlive(pid: i32) bool {
    return std.c.kill(pid, @fromBackingInt(@intCast(0))) == 0;
}

// ---- named-VM locations -------------------------------------------------------

// Durable state lives under ~/.native — one predictable home for toolkit
// state (VM bundles survive reinstalls); re-downloadable caches stay in the
// platform cache dir. Bundles are named: vms/<name>/, with the pre-multi-VM
// layout (a single bundle at vm/) migrated to vms/default on first run.
pub const vms_dir_suffix = ".native/guest-mac/vms";
pub const legacy_bundle_dir_suffix = ".native/guest-mac/vm";
pub const cache_dir_suffix = "Library/Caches/native-sdk/guest-mac";
pub const dhcpd_leases_path = "/var/db/dhcpd_leases";

pub const Paths = struct {
    bundle_dir: [512]u8 = @splat(0),
    bundle_dir_len: usize = 0,
    cache_dir: [512]u8 = @splat(0),
    cache_dir_len: usize = 0,

    pub fn bundleDir(self: *const Paths) []const u8 {
        return self.bundle_dir[0..self.bundle_dir_len];
    }

    pub fn cacheDir(self: *const Paths) []const u8 {
        return self.cache_dir[0..self.cache_dir_len];
    }

    pub fn stateFilePath(self: *const Paths, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}/state.json", .{self.bundleDir()});
    }
};

/// Paths for the named VM: bundle at `<home>/.native/guest-mac/vms/<name>`.
/// One honest exception: while the legacy single bundle still sits at
/// `vm/` (its guest was running when migration would have moved it —
/// see `migrateLegacyBundle`), "default" keeps resolving there so
/// status/ip/stop stay truthful about the live guest.
pub fn resolvePaths(home: []const u8, name: []const u8) !Paths {
    var paths: Paths = .{};
    const bundle = try std.fmt.bufPrint(&paths.bundle_dir, "{s}/{s}/{s}", .{ home, vms_dir_suffix, name });
    paths.bundle_dir_len = bundle.len;
    if (std.mem.eql(u8, name, cli.default_vm_name) and !fileExists(paths.bundleDir())) {
        var legacy_buffer: [512]u8 = undefined;
        const legacy = try std.fmt.bufPrint(&legacy_buffer, "{s}/{s}", .{ home, legacy_bundle_dir_suffix });
        if (fileExists(legacy)) {
            @memcpy(paths.bundle_dir[0..legacy.len], legacy);
            paths.bundle_dir_len = legacy.len;
        }
    }
    const cache = try std.fmt.bufPrint(&paths.cache_dir, "{s}/{s}", .{ home, cache_dir_suffix });
    paths.cache_dir_len = cache.len;
    return paths;
}

// ---- legacy migration ---------------------------------------------------------

pub const Migration = enum {
    /// No legacy bundle — nothing to do.
    none,
    /// Legacy bundle renamed to vms/default.
    migrated,
    /// vms/default already exists; the legacy dir was left untouched.
    kept_existing,
    /// The legacy guest is RUNNING (live owner pid) — moving the bundle
    /// under it would detach its state channel. Deferred; "default"
    /// resolves to the legacy path until it stops.
    deferred_running,
    /// The rename failed (permissions, cross-device...). Left in place;
    /// "default" keeps resolving to the legacy path.
    failed,
};

/// Move a pre-multi-VM bundle (`<home>/.native/guest-mac/vm`) to
/// `vms/default`. A rename, never a copy — the provisioned guest disk
/// must survive intact. Refuses while the legacy guest is running.
pub fn migrateLegacyBundle(legacy_dir: []const u8, vms_dir: []const u8, default_dir: []const u8) Migration {
    if (!fileExists(legacy_dir)) return .none;
    if (fileExists(default_dir)) return .kept_existing;
    if (livePidForBundle(legacy_dir) != null) return .deferred_running;
    if (!makeDir(vms_dir)) return .failed;
    var legacy_buffer: [1024]u8 = undefined;
    var default_buffer: [1024]u8 = undefined;
    const legacy_z = pathZ(&legacy_buffer, legacy_dir) orelse return .failed;
    const default_z = pathZ(&default_buffer, default_dir) orelse return .failed;
    if (std.c.rename(legacy_z, default_z) != 0) return .failed;
    return .migrated;
}

/// Migrate for a home dir and report the outcome (main calls this once
/// per invocation, before any verb touches paths).
pub fn migrateLegacyForHome(home: []const u8) Migration {
    var legacy_buffer: [512]u8 = undefined;
    var vms_buffer: [512]u8 = undefined;
    var default_buffer: [512]u8 = undefined;
    const legacy = std.fmt.bufPrint(&legacy_buffer, "{s}/{s}", .{ home, legacy_bundle_dir_suffix }) catch return .failed;
    const vms = std.fmt.bufPrint(&vms_buffer, "{s}/{s}", .{ home, vms_dir_suffix }) catch return .failed;
    const default_dir = std.fmt.bufPrint(&default_buffer, "{s}/{s}/{s}", .{ home, vms_dir_suffix, cli.default_vm_name }) catch return .failed;
    return migrateLegacyBundle(legacy, vms, default_dir);
}

// ---- running-VM census (the two-guest cap) -------------------------------------

/// The live owner pid recorded in a bundle's state.json, or null when
/// the bundle is not running (no file, no pid, stopped/error state, or
/// a dead owner).
pub fn livePidForBundle(bundle_dir: []const u8) ?i32 {
    var path_buffer: [600]u8 = undefined;
    const state_path = std.fmt.bufPrint(&path_buffer, "{s}/state.json", .{bundle_dir}) catch return null;
    var content_buffer: [1024]u8 = undefined;
    const content = readFileInto(state_path, &content_buffer) orelse return null;
    const parsed = cli.parseStateFile(content);
    if (parsed.pid <= 0) return null;
    if (std.mem.eql(u8, parsed.state, "stopped") or std.mem.eql(u8, parsed.state, "error")) return null;
    if (!processAlive(parsed.pid)) return null;
    return parsed.pid;
}

pub const max_tracked_vms: usize = 32;

pub const RunningVm = struct {
    name_storage: [64]u8 = @splat(0),
    name_len: usize = 0,
    pid: i32 = 0,

    pub fn name(self: *const RunningVm) []const u8 {
        return self.name_storage[0..self.name_len];
    }
};

/// Every VM with a live owner pid: vms/<name>/state.json across the vms
/// dir, plus the legacy `vm/` bundle (counted as "default") while it
/// still exists. This census is what `start` checks against the
/// two-concurrent-guests cap.
pub fn listRunningVms(vms_dir: []const u8, legacy_dir: ?[]const u8, out: []RunningVm) usize {
    var count: usize = 0;
    var dir_buffer: [1024]u8 = undefined;
    if (pathZ(&dir_buffer, vms_dir)) |vms_z| {
        if (std.c.opendir(vms_z)) |dir| {
            defer _ = std.c.closedir(dir);
            while (std.c.readdir(dir)) |entry| {
                if (count >= out.len) break;
                const entry_name = entry.name[0..entry.namlen];
                if (std.mem.eql(u8, entry_name, ".") or std.mem.eql(u8, entry_name, "..")) continue;
                if (entry_name.len > out[count].name_storage.len) continue;
                var bundle_buffer: [1024]u8 = undefined;
                const bundle = std.fmt.bufPrint(&bundle_buffer, "{s}/{s}", .{ vms_dir, entry_name }) catch continue;
                const pid = livePidForBundle(bundle) orelse continue;
                out[count] = .{ .pid = pid, .name_len = entry_name.len };
                @memcpy(out[count].name_storage[0..entry_name.len], entry_name);
                count += 1;
            }
        }
    }
    if (legacy_dir) |legacy| {
        if (count < out.len and !nameListed(out[0..count], cli.default_vm_name)) {
            if (livePidForBundle(legacy)) |pid| {
                out[count] = .{ .pid = pid, .name_len = cli.default_vm_name.len };
                @memcpy(out[count].name_storage[0..cli.default_vm_name.len], cli.default_vm_name);
                count += 1;
            }
        }
    }
    return count;
}

fn nameListed(vms: []const RunningVm, name: []const u8) bool {
    for (vms) |entry| {
        if (std.mem.eql(u8, entry.name(), name)) return true;
    }
    return false;
}

/// Running VMs other than `exclude` — the number the two-guest cap
/// compares against when starting `exclude` itself.
pub fn countOtherRunning(vms: []const RunningVm, exclude: []const u8) usize {
    var count: usize = 0;
    for (vms) |entry| {
        if (!std.mem.eql(u8, entry.name(), exclude)) count += 1;
    }
    return count;
}

// ---- copy-on-write clone --------------------------------------------------------

extern "c" fn arc4random_buf(buffer: *anyopaque, length: usize) void;

/// A libc-sourced random seed (arc4random) for the clone's fresh MAC.
pub fn randomSeed() u64 {
    var seed: u64 = undefined;
    arc4random_buf(&seed, @sizeOf(u64));
    return seed;
}

extern "c" fn clonefile(src: [*:0]const u8, dst: [*:0]const u8, flags: u32) c_int;
extern "c" fn copyfile(from: [*:0]const u8, to: [*:0]const u8, state: ?*anyopaque, flags: u32) c_int;
const copyfile_all: u32 = 0x0F; // COPYFILE_ACL | COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_DATA
const copyfile_excl: u32 = 1 << 17; // fail instead of clobbering an existing destination

pub const CloneMethod = enum { cloned, copied };

/// APFS copy-on-write clone (`clonefile`, the `cp -c` primitive) — a
/// 19 GB Disk.img clones in milliseconds and shares blocks until either
/// side writes. Falls back to a full `copyfile` when the filesystem
/// cannot clone (non-APFS, cross-volume), reporting which happened.
pub fn cloneOrCopyFile(src: []const u8, dst: []const u8) !CloneMethod {
    var src_buffer: [1024]u8 = undefined;
    var dst_buffer: [1024]u8 = undefined;
    const src_z = pathZ(&src_buffer, src) orelse return error.CloneFailed;
    const dst_z = pathZ(&dst_buffer, dst) orelse return error.CloneFailed;
    if (clonefile(src_z, dst_z, 0) == 0) return .cloned;
    if (copyfile(src_z, dst_z, null, copyfile_all | copyfile_excl) == 0) return .copied;
    return error.CloneFailed;
}

// ---- tests -----------------------------------------------------------------------

test "paths resolve per VM name under the caller's home" {
    const paths = try resolvePaths("/Users/dev", "default");
    try std.testing.expectEqualStrings("/Users/dev/.native/guest-mac/vms/default", paths.bundleDir());
    try std.testing.expectEqualStrings("/Users/dev/Library/Caches/native-sdk/guest-mac", paths.cacheDir());
    var buffer: [600]u8 = undefined;
    try std.testing.expectEqualStrings("/Users/dev/.native/guest-mac/vms/default/state.json", try paths.stateFilePath(&buffer));

    const named = try resolvePaths("/Users/dev", "build-bot");
    try std.testing.expectEqualStrings("/Users/dev/.native/guest-mac/vms/build-bot", named.bundleDir());
}

test "default resolves to the legacy bundle only while it exists unmigrated" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [256]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});

    // No bundles at all: the vms/<name> path, even though it does not exist.
    var expected_buffer: [512]u8 = undefined;
    const fresh = try resolvePaths(home, "default");
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&expected_buffer, "{s}/.native/guest-mac/vms/default", .{home}),
        fresh.bundleDir(),
    );

    // A legacy bundle and no vms/default: default falls back to it.
    try tmp.dir.createDirPath(io, ".native/guest-mac/vm");
    const legacy = try resolvePaths(home, "default");
    try std.testing.expectEqualStrings(
        try std.fmt.bufPrint(&expected_buffer, "{s}/.native/guest-mac/vm", .{home}),
        legacy.bundleDir(),
    );
    // Other names never fall back.
    const named = try resolvePaths(home, "build-bot");
    try std.testing.expect(std.mem.endsWith(u8, named.bundleDir(), "/vms/build-bot"));

    // Once vms/default exists it wins.
    try tmp.dir.createDirPath(io, ".native/guest-mac/vms/default");
    const migrated = try resolvePaths(home, "default");
    try std.testing.expect(std.mem.endsWith(u8, migrated.bundleDir(), "/vms/default"));
}

test "legacy migration renames to vms/default, defers while running, keeps existing" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buffer: [256]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    var legacy_buffer: [512]u8 = undefined;
    var vms_buffer: [512]u8 = undefined;
    var default_buffer: [512]u8 = undefined;
    const legacy = try std.fmt.bufPrint(&legacy_buffer, "{s}/vm", .{base});
    const vms = try std.fmt.bufPrint(&vms_buffer, "{s}/vms", .{base});
    const default_dir = try std.fmt.bufPrint(&default_buffer, "{s}/vms/default", .{base});

    // Nothing to migrate.
    try std.testing.expectEqual(Migration.none, migrateLegacyBundle(legacy, vms, default_dir));

    // A stopped legacy bundle migrates whole (disk marker travels).
    try tmp.dir.createDirPath(io, "vm");
    try tmp.dir.writeFile(io, .{ .sub_path = "vm/Disk.img", .data = "disk-bytes" });
    try tmp.dir.writeFile(io, .{ .sub_path = "vm/state.json", .data = "{\"state\":\"stopped\",\"pid\":123}" });
    try std.testing.expectEqual(Migration.migrated, migrateLegacyBundle(legacy, vms, default_dir));
    try std.testing.expect(!fileExists(legacy));
    var disk_buffer: [600]u8 = undefined;
    const disk = try std.fmt.bufPrint(&disk_buffer, "{s}/Disk.img", .{default_dir});
    try std.testing.expect(fileExists(disk));

    // Re-running is a no-op that keeps the migrated bundle.
    try tmp.dir.createDirPath(io, "vm");
    try std.testing.expectEqual(Migration.kept_existing, migrateLegacyBundle(legacy, vms, default_dir));
    try std.testing.expect(fileExists(legacy));

    // A RUNNING legacy guest (live owner pid — this test process) is
    // never moved out from under its owner.
    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    var base2_buffer: [256]u8 = undefined;
    const base2 = try std.fmt.bufPrint(&base2_buffer, ".zig-cache/tmp/{s}", .{tmp2.sub_path[0..]});
    var legacy2_buffer: [512]u8 = undefined;
    var vms2_buffer: [512]u8 = undefined;
    var default2_buffer: [512]u8 = undefined;
    const legacy2 = try std.fmt.bufPrint(&legacy2_buffer, "{s}/vm", .{base2});
    const vms2 = try std.fmt.bufPrint(&vms2_buffer, "{s}/vms", .{base2});
    const default2 = try std.fmt.bufPrint(&default2_buffer, "{s}/vms/default", .{base2});
    try tmp2.dir.createDirPath(io, "vm");
    var state_buffer: [96]u8 = undefined;
    const running_state = try std.fmt.bufPrint(&state_buffer, "{{\"state\":\"running\",\"pid\":{d}}}", .{std.c.getpid()});
    try tmp2.dir.writeFile(io, .{ .sub_path = "vm/state.json", .data = running_state });
    try std.testing.expectEqual(Migration.deferred_running, migrateLegacyBundle(legacy2, vms2, default2));
    try std.testing.expect(fileExists(legacy2));
    try std.testing.expect(!fileExists(default2));
}

test "the running census counts live owner pids and the cap excludes the started VM" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buffer: [256]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    var vms_buffer: [512]u8 = undefined;
    const vms = try std.fmt.bufPrint(&vms_buffer, "{s}/vms", .{base});

    var state_buffer: [96]u8 = undefined;
    const live_state = try std.fmt.bufPrint(&state_buffer, "{{\"state\":\"running\",\"pid\":{d}}}", .{std.c.getpid()});

    // alpha: running (live pid — this test process).
    try tmp.dir.createDirPath(io, "vms/alpha");
    try tmp.dir.writeFile(io, .{ .sub_path = "vms/alpha/state.json", .data = live_state });
    // beta: state says running but the owner is dead — not counted.
    try tmp.dir.createDirPath(io, "vms/beta");
    try tmp.dir.writeFile(io, .{ .sub_path = "vms/beta/state.json", .data = "{\"state\":\"running\",\"pid\":8888888}" });
    // gamma: stopped with a live pid — not counted (stale file).
    try tmp.dir.createDirPath(io, "vms/gamma");
    var stopped_buffer: [96]u8 = undefined;
    const stopped_state = try std.fmt.bufPrint(&stopped_buffer, "{{\"state\":\"stopped\",\"pid\":{d}}}", .{std.c.getpid()});
    try tmp.dir.writeFile(io, .{ .sub_path = "vms/gamma/state.json", .data = stopped_state });
    // delta: no state file at all.
    try tmp.dir.createDirPath(io, "vms/delta");

    var out: [max_tracked_vms]RunningVm = undefined;
    var count = listRunningVms(vms, null, &out);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("alpha", out[0].name());
    try std.testing.expectEqual(@as(i32, std.c.getpid()), out[0].pid);

    // A running LEGACY bundle joins the census as "default".
    try tmp.dir.createDirPath(io, "vm");
    try tmp.dir.writeFile(io, .{ .sub_path = "vm/state.json", .data = live_state });
    var legacy_buffer: [512]u8 = undefined;
    const legacy = try std.fmt.bufPrint(&legacy_buffer, "{s}/vm", .{base});
    count = listRunningVms(vms, legacy, &out);
    try std.testing.expectEqual(@as(usize, 2), count);

    // The cap counts OTHER running guests: restarting one of the two
    // running VMs is fine; a third name is over the cap.
    try std.testing.expectEqual(@as(usize, 1), countOtherRunning(out[0..count], "alpha"));
    try std.testing.expectEqual(@as(usize, 1), countOtherRunning(out[0..count], "default"));
    try std.testing.expectEqual(@as(usize, 2), countOtherRunning(out[0..count], "epsilon"));
}

test "clone copies bytes with a CoW clone when the filesystem supports it" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var base_buffer: [256]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    try tmp.dir.writeFile(io, .{ .sub_path = "src.img", .data = "guest-disk-bytes" });

    var src_buffer: [512]u8 = undefined;
    var dst_buffer: [512]u8 = undefined;
    const src = try std.fmt.bufPrint(&src_buffer, "{s}/src.img", .{base});
    const dst = try std.fmt.bufPrint(&dst_buffer, "{s}/dst.img", .{base});
    _ = try cloneOrCopyFile(src, dst);
    const copied = try tmp.dir.readFileAlloc(io, "dst.img", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("guest-disk-bytes", copied);

    // An existing destination is refused (clonefile and copyfile with
    // no overwrite flags both fail) — clone never clobbers a bundle.
    try std.testing.expectError(error.CloneFailed, cloneOrCopyFile(src, dst));
}

test "events accumulator tracks progress, messages, and the fetched ipsw path" {
    var events: Events = .{};
    events.record(.state_changed, .fetching, 0, "resolving latest supported restore image");
    try std.testing.expectEqual(State.fetching, events.state);
    events.record(.download_progress, .fetching, 0.5, "");
    try std.testing.expectEqual(@as(f64, 0.5), events.download_progress);
    events.record(.log, .no_bundle, 1, "ipsw:/tmp/cache/restore.ipsw");
    try std.testing.expectEqualStrings("/tmp/cache/restore.ipsw", events.ipswPath().?);
    try std.testing.expect(!events.failed);
    events.record(.err, .err, 0, "boom");
    try std.testing.expect(events.failed);
    try std.testing.expectEqualStrings("boom", events.lastMessage());
}

/// Repo root for the virtio-fs share: nearest ancestor with `.git`,
/// even when launched from a subdirectory (like this tool's own). `.git`
/// wins over the NEAREST build.zig.zon: nested packages (tools/*,
/// examples/*) carry their own zon but are not the repo. Falls back to the
/// outermost build.zig.zon seen, then the cwd itself.
pub fn repoRootOrCwd(buffer: *[512]u8) []const u8 {
    const cwd = currentDir(buffer) orelse return ".";
    var outermost_zon: ?[]const u8 = null;
    var dir = cwd;
    while (dir.len > 1) {
        var probe_buffer: [600]u8 = undefined;
        if (std.fmt.bufPrint(&probe_buffer, "{s}/.git", .{dir})) |probe| {
            if (fileExists(probe)) return dir;
        } else |_| {}
        if (std.fmt.bufPrint(&probe_buffer, "{s}/build.zig.zon", .{dir})) |probe| {
            if (fileExists(probe)) outermost_zon = dir;
        } else |_| {}
        dir = std.fs.path.dirname(dir) orelse break;
    }
    return outermost_zon orelse cwd;
}
