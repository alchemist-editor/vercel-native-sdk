//! Pure, testable pieces of the guest-mac CLI: verb/flag parsing (every
//! verb addresses a named VM), DHCP lease matching (how `guest-mac ip`
//! finds a guest without any agent inside it — macOS's NAT DHCP server
//! records every lease in /var/db/dhcpd_leases), state-file parsing, and
//! the clone-identity helpers (fresh MAC, rewritten config).

const std = @import("std");

pub const Verb = enum {
    app,
    fetch,
    install,
    start,
    stop,
    status,
    ip,
    clone,
    help,
};

pub const default_cpus: u32 = 4;
/// 6 GB so two concurrent guests coexist with host builds on a 32 GB
/// host (the macOS license caps concurrency at two guests). A single
/// dedicated guest can take more via `--memory-gb 8`.
pub const default_memory_gb: u64 = 6;
pub const default_disk_gb: u64 = 90;
pub const default_share_tag = "repo";
pub const default_vm_name = "default";

/// Apple's macOS license permits this many macOS guests running
/// concurrently per host; `start` enforces it.
pub const max_running_vms: usize = 2;

pub const Command = struct {
    verb: Verb = .app,
    /// The VM every verb addresses (`--name`); `fetch` ignores it (the
    /// IPSW cache is shared across VMs).
    name: []const u8 = default_vm_name,
    /// Positional `clone <src> <dst>` names.
    clone_src: ?[]const u8 = null,
    clone_dst: ?[]const u8 = null,
    ipsw: ?[]const u8 = null,
    share: ?[]const u8 = null,
    tag: []const u8 = default_share_tag,
    cpus: u32 = default_cpus,
    memory_gb: u64 = default_memory_gb,
    disk_gb: u64 = default_disk_gb,
    force: bool = false,
    wait_seconds: u32 = 0,
};

pub const ParseError = error{
    UnknownVerb,
    UnknownFlag,
    MissingFlagValue,
    InvalidFlagValue,
    InvalidVmName,
    MissingArgument,
};

/// VM names become directory names under ~/.native/guest-mac/vms/ —
/// keep them boring: alphanumerics plus `.`/`_`/`-`, not starting with
/// `.` or `-` (no hidden dirs, nothing flag-shaped), at most 64 bytes.
pub fn isValidVmName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (name[0] == '.' or name[0] == '-') return false;
    for (name) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '.' and char != '_' and char != '-') return false;
    }
    return true;
}

pub fn parse(args: []const []const u8) ParseError!Command {
    var command: Command = .{};
    if (args.len == 0) return command;

    // A leading flag means the windowed app with options
    // (`guest-mac --name build-bot`); a bare word is a verb.
    var index: usize = 0;
    if (args[0][0] != '-') {
        command.verb = std.meta.stringToEnum(Verb, args[0]) orelse return error.UnknownVerb;
        index = 1;
    } else if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        return .{ .verb = .help };
    }

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (arg.len > 0 and arg[0] != '-') {
            // Positional arguments: only `clone <src> <dst>` takes them.
            if (command.verb != .clone) return error.UnknownFlag;
            if (!isValidVmName(arg)) return error.InvalidVmName;
            if (command.clone_src == null) {
                command.clone_src = arg;
            } else if (command.clone_dst == null) {
                command.clone_dst = arg;
            } else {
                return error.UnknownFlag;
            }
        } else if (std.mem.eql(u8, arg, "--force")) {
            command.force = true;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            // `start` is always headless from the CLI; the flag is accepted
            // so agent scripts can be explicit about intent.
        } else if (std.mem.eql(u8, arg, "--name")) {
            command.name = try flagValue(args, &index);
            if (!isValidVmName(command.name)) return error.InvalidVmName;
        } else if (std.mem.eql(u8, arg, "--ipsw")) {
            command.ipsw = try flagValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--share")) {
            command.share = try flagValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--tag")) {
            command.tag = try flagValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--cpus")) {
            command.cpus = try flagInt(u32, args, &index);
        } else if (std.mem.eql(u8, arg, "--memory-gb")) {
            command.memory_gb = try flagInt(u64, args, &index);
        } else if (std.mem.eql(u8, arg, "--disk-gb")) {
            command.disk_gb = try flagInt(u64, args, &index);
        } else if (std.mem.eql(u8, arg, "--wait")) {
            command.wait_seconds = try flagInt(u32, args, &index);
        } else {
            return error.UnknownFlag;
        }
    }
    if (command.verb == .clone) {
        if (command.clone_src == null or command.clone_dst == null) return error.MissingArgument;
        if (std.mem.eql(u8, command.clone_src.?, command.clone_dst.?)) return error.InvalidVmName;
    }
    return command;
}

fn flagValue(args: []const []const u8, index: *usize) ParseError![]const u8 {
    if (index.* + 1 >= args.len) return error.MissingFlagValue;
    index.* += 1;
    return args[index.*];
}

fn flagInt(comptime T: type, args: []const []const u8, index: *usize) ParseError!T {
    const value = try flagValue(args, index);
    return std.fmt.parseInt(T, value, 10) catch error.InvalidFlagValue;
}

pub const usage =
    \\guest-mac — in-repo macOS guest VMs for live-GUI agent work.
    \\
    \\Every verb below takes --name VM to address a named guest
    \\(default "default"); bundles live at ~/.native/guest-mac/vms/<name>/.
    \\
    \\  guest-mac [--name VM]    run the windowed host app (guest display + controls)
    \\  guest-mac fetch          resolve and download the latest supported macOS IPSW
    \\                           (the cache is shared by every VM)
    \\  guest-mac install        create a VM bundle and restore macOS onto it
    \\                           [--ipsw PATH] [--cpus N] [--memory-gb N] [--disk-gb N]
    \\  guest-mac clone SRC DST  copy-on-write clone of a stopped guest with a fresh
    \\                           machine identity and MAC [--cpus N] [--memory-gb N]
    \\  guest-mac start          boot a guest headless (stays in the foreground)
    \\                           [--share DIR] [--tag NAME] [--cpus N] [--memory-gb N]
    \\  guest-mac stop           gracefully stop a running guest [--force]
    \\  guest-mac status         report bundle/run state
    \\  guest-mac ip             print a guest's DHCP address [--wait SECONDS]
    \\
    \\At most two guests run concurrently (Apple's macOS license terms);
    \\`start` refuses a third. See tools/guest-mac/agents.md for the agent
    \\workflow and tools/guest-mac/README.md for provisioning.
    \\
;

// ---- DHCP lease parsing -----------------------------------------------------

/// Find the IPv4 address leased to `mac` in /var/db/dhcpd_leases content.
/// The leases file strips leading zeros per octet ("2" for "02") and
/// prefixes a hardware-type byte ("1,aa:bb:..."), so matching normalizes
/// both sides octet-by-octet instead of comparing strings.
pub fn leaseIpForMac(leases: []const u8, mac: []const u8) ?[]const u8 {
    const wanted = parseMac(mac) orelse return null;
    var current_ip: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, leases, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (std.mem.startsWith(u8, line, "{")) current_ip = null;
        if (std.mem.startsWith(u8, line, "ip_address=")) current_ip = line["ip_address=".len..];
        if (std.mem.startsWith(u8, line, "hw_address=")) {
            var value = line["hw_address=".len..];
            // Skip the "hardware type," prefix when present.
            if (std.mem.indexOfScalar(u8, value, ',')) |comma| value = value[comma + 1 ..];
            const found = parseMac(value) orelse continue;
            if (std.mem.eql(u8, &found, &wanted)) {
                if (current_ip) |ip| return ip;
            }
        }
    }
    return null;
}

fn parseMac(text: []const u8) ?[6]u8 {
    var octets: [6]u8 = undefined;
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \t"), ':');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (count >= 6) return null;
        octets[count] = std.fmt.parseInt(u8, part, 16) catch return null;
        count += 1;
    }
    if (count != 6) return null;
    return octets;
}

// ---- state-file parsing -----------------------------------------------------

pub const StateFile = struct {
    state: []const u8 = "",
    pid: i32 = 0,
};

/// Minimal parse of the engine's state.json ({"state":"running","pid":N}).
/// Flat, engine-authored JSON — field scanning keeps this dependency-free
/// for the CLI verbs that only need two values.
pub fn parseStateFile(content: []const u8) StateFile {
    var result: StateFile = .{};
    if (jsonStringValue(content, "\"state\"")) |value| result.state = value;
    if (jsonNumberValue(content, "\"pid\"")) |value| result.pid = value;
    return result;
}

/// The guest's persistent MAC address from the engine's config.json — the
/// key `guest-mac ip` matches against DHCP leases without touching the
/// Virtualization engine.
pub fn macFromConfig(content: []const u8) ?[]const u8 {
    return jsonStringValue(content, "\"mac_address\"");
}

/// The CPU count persisted in a bundle's config.json (clones inherit it).
pub fn cpusFromConfig(content: []const u8) ?u32 {
    const value = jsonNumberValue(content, "\"cpus\"") orelse return null;
    if (value <= 0) return null;
    return @intCast(value);
}

fn jsonStringValue(content: []const u8, key: []const u8) ?[]const u8 {
    const key_index = std.mem.indexOf(u8, content, key) orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, content, key_index + key.len, ':') orelse return null;
    const open = std.mem.indexOfScalarPos(u8, content, colon, '"') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, content, open + 1, '"') orelse return null;
    return content[open + 1 .. close];
}

fn jsonNumberValue(content: []const u8, key: []const u8) ?i32 {
    const key_index = std.mem.indexOf(u8, content, key) orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, content, key_index + key.len, ':') orelse return null;
    var start = colon + 1;
    while (start < content.len and (content[start] == ' ' or content[start] == '\t')) start += 1;
    var end = start;
    while (end < content.len and (std.ascii.isDigit(content[end]) or content[end] == '-')) end += 1;
    if (end == start) return null;
    return std.fmt.parseInt(i32, content[start..end], 10) catch null;
}

// ---- clone identity ---------------------------------------------------------

/// "aa:bb:cc:dd:ee:ff" — 17 bytes.
pub const mac_string_len: usize = 17;

/// A random locally-administered unicast MAC (second-lowest bit of the
/// first octet set, lowest cleared) — the same address class
/// VZMACAddress.randomLocallyAdministeredAddress draws from. A fresh MAC
/// per clone is what makes the host's DHCP server hand each VM its own
/// IP.
pub fn randomLocallyAdministeredMac(random: std.Random, buffer: *[mac_string_len]u8) []const u8 {
    var octets: [6]u8 = undefined;
    random.bytes(&octets);
    octets[0] = (octets[0] | 0x02) & 0xFE;
    return std.fmt.bufPrint(buffer, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
        octets[0], octets[1], octets[2], octets[3], octets[4], octets[5],
    }) catch unreachable;
}

/// Render a bundle config.json (the engine's flat shape) — used by
/// `clone` to give the copy a fresh MAC while carrying sizing over.
pub fn renderConfig(buffer: []u8, mac: []const u8, cpus: u32, memory_bytes: u64) ![]const u8 {
    return std.fmt.bufPrint(
        buffer,
        "{{\n  \"mac_address\" : \"{s}\",\n  \"cpus\" : {d},\n  \"memory_bytes\" : {d}\n}}\n",
        .{ mac, cpus, memory_bytes },
    );
}

// ---- tests ------------------------------------------------------------------

test "parse defaults to the app verb and the default VM" {
    const command = try parse(&.{});
    try std.testing.expectEqual(Verb.app, command.verb);
    try std.testing.expectEqualStrings(default_vm_name, command.name);
    try std.testing.expectEqual(default_cpus, command.cpus);
    try std.testing.expectEqual(default_memory_gb, command.memory_gb);
    try std.testing.expectEqual(default_disk_gb, command.disk_gb);
    try std.testing.expectEqualStrings(default_share_tag, command.tag);
}

test "parse reads verbs and flags" {
    const install = try parse(&.{ "install", "--ipsw", "/tmp/restore.ipsw", "--disk-gb", "120" });
    try std.testing.expectEqual(Verb.install, install.verb);
    try std.testing.expectEqualStrings("/tmp/restore.ipsw", install.ipsw.?);
    try std.testing.expectEqual(@as(u64, 120), install.disk_gb);

    const start = try parse(&.{ "start", "--headless", "--share", "/repo", "--tag", "src", "--cpus", "6" });
    try std.testing.expectEqual(Verb.start, start.verb);
    try std.testing.expectEqualStrings("/repo", start.share.?);
    try std.testing.expectEqualStrings("src", start.tag);
    try std.testing.expectEqual(@as(u32, 6), start.cpus);

    const stop = try parse(&.{ "stop", "--force" });
    try std.testing.expect(stop.force);

    const ip = try parse(&.{ "ip", "--wait", "90" });
    try std.testing.expectEqual(@as(u32, 90), ip.wait_seconds);
}

test "parse reads --name on every verb and flags-first means the windowed app" {
    const status = try parse(&.{ "status", "--name", "build-bot" });
    try std.testing.expectEqual(Verb.status, status.verb);
    try std.testing.expectEqualStrings("build-bot", status.name);

    const app_flagged = try parse(&.{ "--name", "build-bot" });
    try std.testing.expectEqual(Verb.app, app_flagged.verb);
    try std.testing.expectEqualStrings("build-bot", app_flagged.name);

    const start = try parse(&.{ "start", "--name", "b2", "--memory-gb", "8" });
    try std.testing.expectEqualStrings("b2", start.name);
    try std.testing.expectEqual(@as(u64, 8), start.memory_gb);
}

test "parse reads clone positionals and rejects incomplete or self clones" {
    const clone = try parse(&.{ "clone", "default", "build-bot" });
    try std.testing.expectEqual(Verb.clone, clone.verb);
    try std.testing.expectEqualStrings("default", clone.clone_src.?);
    try std.testing.expectEqualStrings("build-bot", clone.clone_dst.?);
    try std.testing.expectEqual(default_memory_gb, clone.memory_gb);

    try std.testing.expectError(error.MissingArgument, parse(&.{ "clone", "default" }));
    try std.testing.expectError(error.MissingArgument, parse(&.{"clone"}));
    try std.testing.expectError(error.InvalidVmName, parse(&.{ "clone", "default", "default" }));
    try std.testing.expectError(error.UnknownFlag, parse(&.{ "clone", "a", "b", "c" }));
    // Positionals belong to clone alone.
    try std.testing.expectError(error.UnknownFlag, parse(&.{ "start", "build-bot" }));
}

test "parse rejects unknown verbs, flags, and hostile VM names loudly" {
    try std.testing.expectError(error.UnknownVerb, parse(&.{"boot"}));
    try std.testing.expectError(error.UnknownFlag, parse(&.{ "start", "--wat" }));
    try std.testing.expectError(error.MissingFlagValue, parse(&.{ "install", "--ipsw" }));
    try std.testing.expectError(error.InvalidFlagValue, parse(&.{ "start", "--cpus", "four" }));
    try std.testing.expectError(error.InvalidVmName, parse(&.{ "start", "--name", "../escape" }));
    try std.testing.expectError(error.InvalidVmName, parse(&.{ "start", "--name", "has space" }));
    try std.testing.expectError(error.MissingFlagValue, parse(&.{ "start", "--name" }));
}

test "vm name validation is a directory-name allowlist" {
    try std.testing.expect(isValidVmName("default"));
    try std.testing.expect(isValidVmName("build-bot.2"));
    try std.testing.expect(isValidVmName("a"));
    try std.testing.expect(!isValidVmName(""));
    try std.testing.expect(!isValidVmName("."));
    try std.testing.expect(!isValidVmName(".."));
    try std.testing.expect(!isValidVmName(".hidden"));
    try std.testing.expect(!isValidVmName("-flag"));
    try std.testing.expect(!isValidVmName("a/b"));
    try std.testing.expect(!isValidVmName(std.mem.asBytes(&@as([65]["a".len]u8, @splat("a".*)))));
}

test "lease parsing matches zero-stripped octets and lease boundaries" {
    // Real /var/db/dhcpd_leases entries are tab-indented; Zig multiline
    // literals cannot hold raw tabs, so the fixture embeds them explicitly.
    const leases = "{\n" ++
        "\tname=other\n" ++
        "\tip_address=192.168.64.4\n" ++
        "\thw_address=1,aa:bb:cc:dd:ee:ff\n" ++
        "\tidentifier=1,aa:bb:cc:dd:ee:ff\n" ++
        "\tlease=0x69123456\n" ++
        "}\n" ++
        "{\n" ++
        "\tname=guest\n" ++
        "\tip_address=192.168.64.7\n" ++
        "\thw_address=1,ee:d8:26:2:d6:7\n" ++
        "\tidentifier=1,ee:d8:26:2:d6:7\n" ++
        "\tlease=0x69123457\n" ++
        "}\n";
    try std.testing.expectEqualStrings("192.168.64.7", leaseIpForMac(leases, "ee:d8:26:02:d6:07").?);
    try std.testing.expectEqualStrings("192.168.64.4", leaseIpForMac(leases, "AA:BB:CC:DD:EE:FF").?);
    try std.testing.expect(leaseIpForMac(leases, "00:11:22:33:44:55") == null);
    try std.testing.expect(leaseIpForMac(leases, "not-a-mac") == null);
}

test "config parsing reads the persistent MAC address and cpu count" {
    const config = "{\n  \"cpus\" : 4,\n  \"mac_address\" : \"ee:d8:26:02:d6:07\"\n}";
    try std.testing.expectEqualStrings("ee:d8:26:02:d6:07", macFromConfig(config).?);
    try std.testing.expectEqual(@as(u32, 4), cpusFromConfig(config).?);
    try std.testing.expect(macFromConfig("{}") == null);
    try std.testing.expect(cpusFromConfig("{}") == null);
}

test "state file parsing reads state and pid" {
    const parsed = parseStateFile("{\"pid\":4242,\"state\":\"running\"}");
    try std.testing.expectEqualStrings("running", parsed.state);
    try std.testing.expectEqual(@as(i32, 4242), parsed.pid);

    const empty = parseStateFile("{}");
    try std.testing.expectEqualStrings("", empty.state);
    try std.testing.expectEqual(@as(i32, 0), empty.pid);
}

test "clone identity is fresh: new MAC differs from the source, stays locally administered" {
    var prng = std.Random.DefaultPrng.init(42);
    var buffer_a: [mac_string_len]u8 = undefined;
    var buffer_b: [mac_string_len]u8 = undefined;
    const mac_a = randomLocallyAdministeredMac(prng.random(), &buffer_a);
    const mac_b = randomLocallyAdministeredMac(prng.random(), &buffer_b);

    // Well-formed, parseable, and in the locally-administered unicast class.
    const octets = parseMac(mac_a) orelse return error.TestUnexpectedResult;
    try std.testing.expect(octets[0] & 0x02 != 0); // locally administered
    try std.testing.expect(octets[0] & 0x01 == 0); // unicast
    try std.testing.expectEqual(mac_string_len, mac_a.len);

    // Distinct draws (the freshness property `clone` relies on).
    try std.testing.expect(!std.mem.eql(u8, mac_a, mac_b));
    const src_mac = "12:30:3c:1b:be:30";
    try std.testing.expect(!std.mem.eql(u8, mac_a, src_mac));
}

test "clone config rewrite carries cpus, takes the new MAC and memory" {
    const src_config = "{\n  \"memory_bytes\" : 8589934592,\n  \"cpus\" : 4,\n  \"mac_address\" : \"12:30:3c:1b:be:30\"\n}";
    var buffer: [256]u8 = undefined;
    const rendered = try renderConfig(&buffer, "0a:0b:0c:0d:0e:0f", cpusFromConfig(src_config).?, 6 << 30);
    try std.testing.expectEqualStrings("0a:0b:0c:0d:0e:0f", macFromConfig(rendered).?);
    try std.testing.expectEqual(@as(u32, 4), cpusFromConfig(rendered).?);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "6442450944") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "12:30:3c") == null);
}
