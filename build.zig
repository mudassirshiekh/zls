const std = @import("std");
const builtin = @import("builtin");
const SemaCases = @import("tests/SemaCases.zig");

const zls_version = std.SemanticVersion{ .major = 0, .minor = 12, .patch = 0 };

/// document the latest breaking change that caused a change to the string below:
/// std.heap: add runtime safety for calling `stackFallback(N).get` multiple times
const min_zig_string = "0.12.0-dev.2138+828d23956";

const Build = blk: {
    const current_zig = builtin.zig_version;
    const min_zig = std.SemanticVersion.parse(min_zig_string) catch unreachable;
    if (current_zig.order(min_zig) == .lt) {
        @compileError(std.fmt.comptimePrint("Your Zig version v{} does not meet the minimum build requirement of v{}", .{ current_zig, min_zig }));
    }
    break :blk std.Build;
};

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const single_threaded = b.option(bool, "single-threaded", "Build a single threaded Executable");
    const pie = b.option(bool, "pie", "Build a Position Independent Executable");
    const enable_tracy = b.option(bool, "enable_tracy", "Whether tracy should be enabled.") orelse false;
    const coverage = b.option(bool, "generate_coverage", "Generate coverage data with kcov") orelse false;
    const coverage_output_dir = b.option([]const u8, "coverage_output_dir", "Output directory for coverage data") orelse b.pathJoin(&.{ b.install_prefix, "kcov" });
    const test_filter = b.option([]const u8, "test-filter", "Skip tests that do not match filter");
    const data_version = b.option([]const u8, "data_version", "The Zig version your compiler is.") orelse "master";
    const data_version_path = b.option([]const u8, "version_data_path", "Manually specify zig language reference file");
    const override_version_data_file_path = b.option([]const u8, "version_data_file_path", "Relative path to version data file (if none, will be named with timestamp)");
    const use_llvm = b.option(bool, "use_llvm", "Use Zig's llvm code backend");

    const version_string = v: {
        const version_string = b.fmt("{d}.{d}.{d}", .{ zls_version.major, zls_version.minor, zls_version.patch });
        const build_root_path = b.build_root.path orelse ".";

        var code: u8 = undefined;
        const git_describe_untrimmed = b.runAllowFail(&[_][]const u8{
            "git", "-C", build_root_path, "describe", "--match", "*.*.*", "--tags",
        }, &code, .Ignore) catch break :v version_string;

        const git_describe = std.mem.trim(u8, git_describe_untrimmed, " \n\r");

        switch (std.mem.count(u8, git_describe, "-")) {
            0 => {
                // Tagged release version (e.g. 0.10.0).
                std.debug.assert(std.mem.eql(u8, git_describe, version_string)); // tagged release must match version string
                break :v version_string;
            },
            2 => {
                // Untagged development build (e.g. 0.10.0-dev.216+34ce200).
                var it = std.mem.splitScalar(u8, git_describe, '-');
                const tagged_ancestor = it.first();
                const commit_height = it.next().?;
                const commit_id = it.next().?;

                const ancestor_ver = try std.SemanticVersion.parse(tagged_ancestor);
                std.debug.assert(zls_version.order(ancestor_ver) == .gt); // zls version must be greater than its previous version
                std.debug.assert(std.mem.startsWith(u8, commit_id, "g")); // commit hash is prefixed with a 'g'

                break :v b.fmt("{s}-dev.{s}+{s}", .{ version_string, commit_height, commit_id[1..] });
            },
            else => {
                std.debug.print("Unexpected 'git describe' output: '{s}'\n", .{git_describe});
                std.process.exit(1);
            },
        }
    };

    const exe_options = b.addOptions();
    exe_options.addOption(std.log.Level, "log_level", b.option(std.log.Level, "log_level", "The Log Level to be used.") orelse .info);
    exe_options.addOption(bool, "enable_failing_allocator", b.option(bool, "enable_failing_allocator", "Whether to use a randomly failing allocator.") orelse false);
    exe_options.addOption(u32, "enable_failing_allocator_likelihood", b.option(u32, "enable_failing_allocator_likelihood", "The chance that an allocation will fail is `1/likelihood`") orelse 256);
    exe_options.addOption(bool, "use_gpa", b.option(bool, "use_gpa", "Good for debugging") orelse (optimize == .Debug));
    exe_options.addOption([]const u8, "version_string", version_string);
    exe_options.addOption(std.SemanticVersion, "version", try std.SemanticVersion.parse(version_string));
    exe_options.addOption([]const u8, "min_zig_string", min_zig_string);

    const build_options = b.addOptions();
    const build_options_module = build_options.createModule();
    build_options.addOption(bool, "enable_tracy", enable_tracy);
    build_options.addOption(bool, "enable_tracy_allocation", b.option(bool, "enable_tracy_allocation", "Enable using TracyAllocator to monitor allocations.") orelse enable_tracy);
    build_options.addOption(bool, "enable_tracy_callstack", b.option(bool, "enable_tracy_callstack", "Enable callstack graphs.") orelse enable_tracy);
    build_options.addOption([]const u8, "version_string", version_string);
    build_options.addOption(std.SemanticVersion, "version", try std.SemanticVersion.parse(version_string));

    const global_cache_path = try b.cache_root.join(b.allocator, &.{"zls"});
    b.cache_root.handle.makePath(global_cache_path) catch |err| {
        std.debug.panic("unable to make tmp path '{s}': {}", .{ global_cache_path, err });
    };

    const test_options = b.addOptions();
    const test_options_module = test_options.createModule();
    test_options.addOption([]const u8, "zig_exe_path", b.zig_exe);
    test_options.addOption([]const u8, "global_cache_path", global_cache_path);

    const exe_options_module = exe_options.createModule();
    const known_folders_module = b.dependency("known_folders", .{}).module("known-folders");
    const diffz_module = b.dependency("diffz", .{}).module("diffz");

    const exe = b.addExecutable(.{
        .name = "zls",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
        .single_threaded = single_threaded,
    });
    exe.use_llvm = use_llvm;
    exe.use_lld = use_llvm;
    exe.pie = pie;
    b.installArtifact(exe);

    exe.root_module.addImport("exe_options", exe_options_module);
    exe.root_module.addImport("build_options", build_options_module);
    exe.root_module.addImport("known-folders", known_folders_module);
    exe.root_module.addImport("diffz", diffz_module);

    if (enable_tracy) {
        const client_cpp = "src/tracy/public/TracyClient.cpp";

        // On mingw, we need to opt into windows 7+ to get some features required by tracy.
        const tracy_c_flags: []const []const u8 = if (target.result.isMinGW())
            &[_][]const u8{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined", "-D_WIN32_WINNT=0x601" }
        else
            &[_][]const u8{ "-DTRACY_ENABLE=1", "-fno-sanitize=undefined" };

        exe.addIncludePath(.{ .path = "src/tracy" });
        exe.addCSourceFile(.{
            .file = .{ .path = client_cpp },
            .flags = tracy_c_flags,
        });
        exe.linkLibCpp();
        exe.linkLibC();

        if (target.result.os.tag == .windows) {
            exe.linkSystemLibrary("dbghelp");
            exe.linkSystemLibrary("ws2_32");
        }
    }

    const gen_exe = b.addExecutable(.{
        .name = "zls_gen",
        .root_source_file = .{ .path = "src/config_gen/config_gen.zig" },
        .target = b.host,
        .single_threaded = true,
    });

    const gen_cmd = b.addRunArtifact(gen_exe);
    gen_cmd.addArgs(&.{
        "--readme-path",
        b.pathFromRoot("README.md"),
        "--generate-config-path",
        b.pathFromRoot("src/Config.zig"),
        "--generate-schema-path",
        b.pathFromRoot("schema.json"),
    });
    if (b.args) |args| gen_cmd.addArgs(args);

    const gen_step = b.step("gen", "Regenerate config files");
    gen_step.dependOn(&gen_cmd.step);

    const gen_version_data_cmd = b.addRunArtifact(gen_exe);
    gen_version_data_cmd.addArgs(&.{ "--generate-version-data", data_version });
    if (data_version_path) |path| {
        gen_version_data_cmd.addArg("--langref_path");
        gen_version_data_cmd.addFileArg(.{ .cwd_relative = path });
    }
    const version_data_file_name = if (data_version_path != null)
        b.fmt("version_data_{s}.zig", .{data_version})
    else blk: {
        // invalidate version data periodically from cache because the website content may change
        // setting `has_side_effects` would also be possible but that would always force a re-run
        const timestamp = @divFloor(std.time.timestamp(), std.time.s_per_day);
        break :blk b.fmt("version_data_{s}_{d}.zig", .{ data_version, timestamp });
    };
    gen_version_data_cmd.addArg("--generate-version-data-path");
    const version_data_path: std.Build.LazyPath = if (override_version_data_file_path) |path|
        .{ .cwd_relative = path }
    else
        gen_version_data_cmd.addOutputFileArg(version_data_file_name);
    const version_data_module = b.addModule("version_data", .{ .root_source_file = version_data_path });
    exe.root_module.addImport("version_data", version_data_module);

    const zls_module = b.addModule("zls", .{
        .root_source_file = .{ .path = "src/zls.zig" },
        .imports = &.{
            .{ .name = "known-folders", .module = known_folders_module },
            .{ .name = "diffz", .module = diffz_module },
            .{ .name = "build_options", .module = build_options_module },
            .{ .name = "version_data", .module = version_data_module },
        },
    });

    const test_step = b.step("test", "Run all the tests");
    test_step.dependOn(b.getInstallStep());

    var tests = b.addTest(.{
        .root_source_file = .{ .path = "tests/tests.zig" },
        .target = target,
        .optimize = optimize,
        .filter = test_filter,
        .single_threaded = single_threaded,
    });
    tests.use_llvm = use_llvm;
    tests.use_lld = use_llvm;

    tests.root_module.addImport("zls", zls_module);
    tests.root_module.addImport("build_options", build_options_module);
    tests.root_module.addImport("test_options", test_options_module);
    test_step.dependOn(&b.addRunArtifact(tests).step);

    var src_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/zls.zig" },
        .target = target,
        .optimize = optimize,
        .filter = test_filter,
        .single_threaded = single_threaded,
    });
    src_tests.use_llvm = use_llvm;
    src_tests.use_lld = use_llvm;
    src_tests.root_module.addImport("build_options", build_options_module);
    src_tests.root_module.addImport("test_options", test_options_module);
    test_step.dependOn(&b.addRunArtifact(src_tests).step);

    var cases: SemaCases = .{ .allocator = b.allocator };
    try cases.addCasesFromDir(b.pathFromRoot("tests/sema"), .{ .ignore_annotation = false });
    try cases.addCasesFromDir(b.pathFromRoot("src"), .{ .ignore_annotation = true });

    // TODO zig_lib_dir is not being resolved
    if (b.zig_lib_dir) |dir_path| {
        try cases.addCasesFromDir(dir_path.getPath(b), .{ .ignore_annotation = true });
    }
    const sema_test = cases.lowerToBuild(b, test_step, target);
    sema_test.root_module.addImport("zls", zls_module);
    sema_test.root_module.addImport("build_options", build_options_module);

    if (coverage) {
        const include_pattern = b.fmt("--include-pattern=/src", .{});
        const exclude_pattern = b.fmt("--exclude-pattern=/src/stage2", .{});
        const args = &[_]std.Build.Step.Run.Arg{
            .{ .bytes = b.dupe("kcov") },
            .{ .bytes = b.dupe("--collect-only") },
            .{ .bytes = b.dupe(include_pattern) },
            .{ .bytes = b.dupe(exclude_pattern) },
            .{ .bytes = b.dupe(coverage_output_dir) },
        };

        var tests_run = b.addRunArtifact(tests);
        var src_tests_run = b.addRunArtifact(src_tests);
        tests_run.has_side_effects = true;
        src_tests_run.has_side_effects = true;

        tests_run.argv.insertSlice(0, args) catch @panic("OOM");
        src_tests_run.argv.insertSlice(0, args) catch @panic("OOM");

        var merge_step = std.Build.Step.Run.create(b, "merge kcov");
        merge_step.has_side_effects = true;
        merge_step.addArgs(&.{
            "kcov",
            "--merge",
            coverage_output_dir,
            b.pathJoin(&.{ coverage_output_dir, "test" }),
        });
        merge_step.step.dependOn(&b.addRemoveDirTree(coverage_output_dir).step);
        merge_step.step.dependOn(&tests_run.step);
        merge_step.step.dependOn(&src_tests_run.step);
        test_step.dependOn(&merge_step.step);
    }
}
