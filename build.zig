const std = @import("std");

/// Vendored Zylix core (github.com/kotsutsumi/zylix). We import only the
/// virtual DOM module, which is self-contained.
const zylix_src = "/home/arnecronomica/Utilities/Projects/zylix/core/src";

/// NDK sysroot headers, needed so jni.zig can @cImport <jni.h>.
const ndk_include = "/home/arnecronomica/Android/Sdk/ndk/27.0.12077973/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zylix_native = b.createModule(.{
        .root_source_file = .{ .cwd_relative = zylix_src ++ "/vdom.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Unit tests: engine + view, native.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zylix", .module = zylix_native }},
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Native demo that prints the rendered view.
    const demo = b.addExecutable(.{
        .name = "timeato-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zylix", .module = zylix_native }},
        }),
    });
    const run_demo = b.addRunArtifact(demo);
    const demo_step = b.step("demo", "Run the native view demo");
    demo_step.dependOn(&run_demo.step);

    // WebAssembly build for the web shell.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .Debug else .ReleaseSmall;

    const zylix_wasm = b.createModule(.{
        .root_source_file = .{ .cwd_relative = zylix_src ++ "/vdom.zig" },
        .target = wasm_target,
        .optimize = wasm_optimize,
    });

    const wasm = b.addExecutable(.{
        .name = "timeato",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
            .imports = &.{.{ .name = "zylix", .module = zylix_wasm }},
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;

    const install_wasm = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    });
    const wasm_step = b.step("wasm", "Build Timeato for WebAssembly");
    wasm_step.dependOn(&install_wasm.step);

    // Android: one shared library per ABI holding the Zig core plus its JNI
    // bridge. The Kotlin shell loads it directly; no CMake or C involved.
    const android_abis = [_]struct { dir: []const u8, cpu: std.Target.Cpu.Arch }{
        .{ .dir = "arm64-v8a", .cpu = .aarch64 },
        .{ .dir = "x86_64", .cpu = .x86_64 },
    };
    const android_step = b.step("android", "Build the Android JNI library");
    for (android_abis) |abi| {
        const android_target = b.resolveTargetQuery(.{
            .cpu_arch = abi.cpu,
            .os_tag = .linux,
            .abi = .android,
        });
        const zylix_android = b.createModule(.{
            .root_source_file = .{ .cwd_relative = zylix_src ++ "/vdom.zig" },
            .target = android_target,
            .optimize = .ReleaseSmall,
        });
        const jni_module = b.createModule(.{
            .root_source_file = b.path("src/jni.zig"),
            .target = android_target,
            .optimize = .ReleaseSmall,
            .imports = &.{.{ .name = "zylix", .module = zylix_android }},
        });
        jni_module.addIncludePath(.{ .cwd_relative = ndk_include });
        const lib = b.addLibrary(.{
            .name = "timeato",
            .linkage = .dynamic,
            .root_module = jni_module,
        });
        const install_lib = b.addInstallArtifact(lib, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("android/{s}", .{abi.dir}) } },
        });
        android_step.dependOn(&install_lib.step);
    }
}
