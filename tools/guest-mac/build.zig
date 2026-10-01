const std = @import("std");
const native_sdk = @import("native_sdk");

// The standard app build (exe, run, test) plus what a VM host needs:
// the Virtualization.framework engine compiled in, and the binary ad-hoc
// signed with the com.apple.security.virtualization entitlement — nothing
// in Virtualization works unsigned, not even the restore-image catalog
// fetch. The sign step rewrites the emitted binary in place, so install
// and run are both ordered after it (the artifact zig caches is already
// signed; re-signing on rebuild is idempotent).
pub fn build(b: *std.Build) void {
    const artifacts = native_sdk.addAppArtifacts(b, b.dependency("native_sdk", .{}), .{ .name = "guest-mac" });

    const app_mod = artifacts.exe.root_module;
    // Dev tooling for the build host: the engine uses macOS 13 APIs
    // (VZMacTrackpadConfiguration and friends), so this one file compiles
    // against a 13.0 floor while the framework target stays at 11.0. The
    // sysroot flags mirror the framework's own ObjC compiles (addApp set
    // SDKROOT or `xcrun --show-sdk-path`).
    const flags: []const []const u8 = if (native_sdk.macosSdkPath(b)) |sysroot|
        &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC", "-mmacosx-version-min=13.0", "-isysroot", sysroot, b.fmt("-I{s}/usr/include", .{sysroot}) }
    else
        &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC", "-mmacosx-version-min=13.0" };
    app_mod.addCSourceFile(.{ .file = b.path("src/vm_host.m"), .flags = flags });
    native_sdk.linkMacosFramework(b, app_mod, "Virtualization", .{});

    // The test binary reaches the engine bindings through the app's real
    // dispatch paths (no VM is ever created in tests), so it links the
    // same engine. Tests run Debug while the exe runs ReleaseFast, so
    // this is usually a distinct module — guard against double-adding.
    const test_mod = artifacts.tests.root_module;
    if (test_mod != app_mod) {
        test_mod.addCSourceFile(.{ .file = b.path("src/vm_host.m"), .flags = flags });
        if (native_sdk.macosSdkPath(b)) |sysroot| {
            test_mod.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
            // -L is sysroot-prefixed when --sysroot is set, so this
            // resolves to <sdk>/usr/lib (where libobjc.tbd lives).
            test_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr/lib" }) });
        }
        native_sdk.linkMacosFramework(b, test_mod, "Virtualization", .{});
        native_sdk.linkMacosFramework(b, test_mod, "Foundation", .{});
        test_mod.linkSystemLibrary("objc", .{});
    }

    const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", "--entitlements" });
    sign.addFileArg(b.path("entitlements.plist"));
    sign.addFileArg(artifacts.exe.getEmittedBin());
    artifacts.install.step.dependOn(&sign.step);
    artifacts.run.step.dependOn(&sign.step);
}
