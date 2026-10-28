const builtin = @import("builtin");
const std = @import("std");
const inputpkg = @import("../input.zig");
const global = @import("../global.zig");
const String = @import("../main_c.zig").String;

const Config = @import("Config.zig");
const c_get = @import("c_get.zig");
const edit = @import("edit.zig");
const Key = @import("key.zig").Key;

const log = std.log.scoped(.config);

/// Create a new configuration filled with the initial default values.
export fn ghostty_config_new() ?*Config {
    const result = global.alloc().create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = Config.default(global.alloc()) catch |err| {
        log.err("error creating config err={}", .{err});
        global.alloc().destroy(result);
        return null;
    };

    return result;
}

export fn ghostty_config_free(ptr: ?*Config) void {
    if (ptr) |v| {
        v.deinit();
        global.alloc().destroy(v);
    }
}

/// Deep clone the configuration.
export fn ghostty_config_clone(self: *Config) ?*Config {
    const result = global.alloc().create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = self.clone(global.alloc()) catch |err| {
        log.err("error cloning config err={}", .{err});
        global.alloc().destroy(result);
        return null;
    };

    return result;
}

/// Load the configuration from the CLI args.
export fn ghostty_config_load_cli_args(self: *Config) void {
    self.loadCliArgs(global.alloc()) catch |err| {
        log.err("error loading config err={}", .{err});
        recordLoadFailure(self, "error loading config from CLI arguments");
    };
}

/// Load the configuration from the default file locations. This
/// is usually done first. The default file locations are locations
/// such as the home directory.
export fn ghostty_config_load_default_files(self: *Config) void {
    self.loadDefaultFiles(global.alloc()) catch |err| {
        log.err("error loading config err={}", .{err});
        recordLoadFailure(self, "error loading the default configuration files");
    };
}

/// Load the configuration from a specific file path.
/// The path must be null-terminated.
export fn ghostty_config_load_file(self: *Config, path: [*:0]const u8) void {
    const path_slice = std.mem.span(path);
    self.loadFile(global.alloc(), path_slice) catch |err| {
        if (err == error.FileIsEmpty) return;
        log.err("error loading config from file path={s} err={}", .{ path_slice, err });
        recordLoadFailure(self, "error loading configuration file");
    };
}

/// Load the configuration from the user-specified configuration
/// file locations in the previously loaded configuration. This will
/// recursively continue to load up to a built-in limit.
export fn ghostty_config_load_recursive_files(self: *Config) void {
    self.loadRecursiveFiles(global.alloc()) catch |err| {
        log.err("error loading config err={}", .{err});
        recordLoadFailure(self, "error loading referenced configuration files");
    };
}

export fn ghostty_config_finalize(self: *Config) void {
    self.finalize() catch |err| {
        log.err("error finalizing config err={}", .{err});
        recordLoadFailure(self, "error finalizing the configuration");
    };
}

/// True when a load or finalize step failed outright, as opposed to a
/// recoverable per-line diagnostic. Such a config must not replace a
/// config that is already in effect.
export fn ghostty_config_load_failed(self: *Config) bool {
    return self._load_failed;
}

/// The paths this configuration was actually loaded from, including files
/// that failed to open and the default locations that were checked. The
/// returned buffer is owned by the caller and freed with ghostty_string_free.
export fn ghostty_config_load_paths(self: *Config) String {
    return loadPaths(self) catch |err| {
        log.err("error collecting config load paths err={}", .{err});
        return .empty;
    };
}

/// Remember that a load step failed. The existing void load API cannot
/// report the error, so it is recorded as a diagnostic and a sticky flag
/// that a reload can check before applying the config.
fn recordLoadFailure(self: *Config, comptime message: [:0]const u8) void {
    self._load_failed = true;
    const arena = &(self._arena orelse return);
    const alloc = arena.allocator();
    const diag: @import("../cli.zig").Diagnostic = .{ .message = message };
    self._diagnostics.append(alloc, diag) catch |err| {
        log.err("error recording config load failure err={}", .{err});
        return;
    };
    // Theme replay rebuilds diagnostics from the replay steps, so one that
    // is not recorded there disappears from the error window.
    self._replay_steps.append(alloc, .{ .diagnostic = diag }) catch |err| {
        log.err("error replaying config load failure err={}", .{err});
    };
}

fn loadPaths(self: *Config) !String {
    var arena: std.heap.ArenaAllocator = .init(global.alloc());
    defer arena.deinit();
    const alloc = arena.allocator();

    var joined: std.ArrayList(u8) = .empty;
    for (self._load_paths.items, 0..) |path, i| {
        if (i > 0) try joined.append(alloc, 0);
        try joined.appendSlice(alloc, path);
    }

    const owned = try global.alloc().dupeSentinel(u8, joined.items, 0);
    return .fromSlice(owned);
}

export fn ghostty_config_get(
    self: *Config,
    ptr: *anyopaque,
    key_str: [*]const u8,
    len: usize,
) bool {
    @setEvalBranchQuota(10_000);
    const key = std.meta.stringToEnum(Key, key_str[0..len]) orelse return false;
    return c_get.get(self, key, ptr);
}

export fn ghostty_config_trigger(
    self: *Config,
    str: [*]const u8,
    len: usize,
) inputpkg.Binding.Trigger.C {
    return config_trigger_(self, str[0..len]) catch |err| err: {
        log.err("error finding trigger err={}", .{err});
        break :err .{};
    };
}

fn config_trigger_(
    self: *Config,
    str: []const u8,
) !inputpkg.Binding.Trigger.C {
    const action = try inputpkg.Binding.Action.parse(str);
    const trigger: inputpkg.Binding.Trigger = self.keybind.set.getTrigger(action) orelse .{};
    return trigger.cval();
}

export fn ghostty_config_diagnostics_count(self: *Config) u32 {
    return @intCast(self._diagnostics.items().len);
}

/// Diagnostics whose source is not a command-line argument. A bad CLI
/// argument cannot be fixed by editing the configuration file, so a reload
/// must not reject the file because of one.
export fn ghostty_config_reload_diagnostics_count(self: *Config) u32 {
    var count: u32 = 0;
    for (self._diagnostics.items()) |diag| {
        if (diag.location != .cli) count += 1;
    }
    return count;
}

export fn ghostty_config_get_diagnostic(self: *Config, idx: u32) Diagnostic {
    const items = self._diagnostics.items();
    if (idx >= items.len) return .{};
    const message = self._diagnostics.precompute.messages.items[idx];
    return .{ .message = message.ptr };
}

export fn ghostty_config_open_path() String {
    const path = edit.openPath(global.alloc()) catch |err| {
        log.err("error opening config in editor err={}", .{err});
        return .empty;
    };

    return .fromSlice(path);
}

/// Sync with ghostty_diagnostic_s
const Diagnostic = extern struct {
    message: [*:0]const u8 = "",
};

test "ghostty_config_get: bool" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.maximize = true;

    var out = false;
    const key = "maximize";
    try testing.expect(ghostty_config_get(&cfg, &out, key, key.len));
    try testing.expect(out);
}

test "ghostty_config_get: enum" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"window-theme" = .dark;

    var out: [*:0]const u8 = undefined;
    const key = "window-theme";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    const str = std.mem.sliceTo(out, 0);
    try testing.expectEqualStrings("dark", str);
}

test "ghostty_config_get: optional null returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"unfocused-split-fill" = null;

    var out: Config.Color.C = undefined;
    const key = "unfocused-split-fill";
    try testing.expect(!ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
}

fn writeConfig(dir: *std.Io.Dir, name: []const u8, data: []const u8) ![:0]const u8 {
    const alloc = std.testing.allocator;
    try dir.writeFile(global.io(), .{ .sub_path = name, .data = data });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try dir.realPathFile(global.io(), name, &buf);
    return try alloc.dupeSentinel(u8, buf[0..len], 0);
}

fn listedPaths(cfg: *Config) ![]const u8 {
    const listed = try loadPaths(cfg);
    const ptr = listed.ptr orelse return "";
    return ptr[0..listed.len];
}

const CliArgs = struct {
    args: []const []const u8,
    index: usize = 0,

    pub fn next(self: *@This()) ?[]const u8 {
        if (self.index >= self.args.len) return null;
        defer self.index += 1;
        return self.args[self.index];
    }

    pub fn location(self: *const @This(), _: std.mem.Allocator) error{}!?@import("../cli.zig").Location {
        return .{ .cli = self.index };
    }
};

test "ghostty_config_load: a theme replay keeps a bad CLI argument as CLI" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const theme = try writeConfig(&tmp.dir, "theme", "background = #111111\n");
    defer alloc.free(theme);
    const text = try std.fmt.allocPrint(alloc, "theme = {s}\n", .{theme});
    defer alloc.free(text);
    const path = try writeConfig(&tmp.dir, "config", text);
    defer alloc.free(path);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    ghostty_config_load_file(&cfg, path.ptr);
    var args: CliArgs = .{ .args = &.{"--not-a-real-field=1"} };
    try cfg.loadIter(alloc, &args);
    ghostty_config_finalize(&cfg);

    try testing.expect(!ghostty_config_load_failed(&cfg));
    try testing.expect(ghostty_config_diagnostics_count(&cfg) > 0);
    try testing.expectEqual(@as(u32, 0), ghostty_config_reload_diagnostics_count(&cfg));
}

test "ghostty_config_load: a theme replay still counts a file error" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const theme = try writeConfig(&tmp.dir, "theme", "background = #111111\n");
    defer alloc.free(theme);
    const text = try std.fmt.allocPrint(alloc, "theme = {s}\nnot-a-real-field = 1\n", .{theme});
    defer alloc.free(text);
    const path = try writeConfig(&tmp.dir, "config", text);
    defer alloc.free(path);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    ghostty_config_load_file(&cfg, path.ptr);
    var args: CliArgs = .{ .args = &.{"--also-not-real=1"} };
    try cfg.loadIter(alloc, &args);
    ghostty_config_finalize(&cfg);

    try testing.expect(ghostty_config_reload_diagnostics_count(&cfg) > 0);
}

test "ghostty_config_load: a conditional state change keeps the load paths" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const extra = try writeConfig(&tmp.dir, "extra", "cursor-style = block\n");
    defer alloc.free(extra);
    const light = try writeConfig(&tmp.dir, "light", "background = #ffffff\n");
    defer alloc.free(light);
    const dark = try writeConfig(&tmp.dir, "dark", "background = #111111\n");
    defer alloc.free(dark);
    const text = try std.fmt.allocPrint(
        alloc,
        "config-file = {s}\ntheme = light:{s},dark:{s}\n",
        .{ extra, light, dark },
    );
    defer alloc.free(text);
    const root = try writeConfig(&tmp.dir, "config", text);
    defer alloc.free(root);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    try cfg.loadFile(alloc, root);
    try cfg.loadRecursiveFiles(alloc);
    try cfg.finalize();

    // A system appearance change rebuilds the config through this call.
    var switched = (try cfg.changeConditionalState(.{ .theme = .dark })).?;
    defer switched.deinit();

    const flat = try listedPaths(&switched);
    defer alloc.free(flat.ptr[0 .. flat.len + 1]);
    try testing.expect(std.mem.indexOf(u8, flat, root) != null);
    try testing.expect(std.mem.indexOf(u8, flat, extra) != null);
    try testing.expect(std.mem.indexOf(u8, flat, dark) != null);
}

test "ghostty_config_load: a theme named only on the CLI stays CLI" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeConfig(&tmp.dir, "config", "cursor-style = block\n");
    defer alloc.free(path);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    ghostty_config_load_file(&cfg, path.ptr);
    var args: CliArgs = .{ .args = &.{"--theme=ghostty-no-such-theme"} };
    try cfg.loadIter(alloc, &args);
    ghostty_config_finalize(&cfg);

    try testing.expect(!ghostty_config_load_failed(&cfg));
    try testing.expect(ghostty_config_diagnostics_count(&cfg) > 0);
    try testing.expectEqual(@as(u32, 0), ghostty_config_reload_diagnostics_count(&cfg));
}

test "ghostty_config_load: a theme named in a file survives a conditional change" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // Naming the theme in the file makes its origin a .file location, whose
    // path lives in the config's arena. A shallow copy of it would dangle
    // once that config is freed.
    const text = "theme = light:ghostty-no-such-light,dark:ghostty-no-such-dark\n";
    const root = try writeConfig(&tmp.dir, "config", text);
    defer alloc.free(root);

    var cfg = try Config.default(alloc);
    try cfg.loadFile(alloc, root);
    try cfg.finalize();
    try testing.expect(cfg._theme_location == .file);
    const source_path = switch (cfg._theme_location) {
        .file => |file| file.path,
        else => return error.TestUnexpectedResult,
    };

    var switched = (try cfg.changeConditionalState(.{ .theme = .dark })) orelse
        return error.TestUnexpectedResult;
    defer switched.deinit();

    // A shallow copy would still point into the freed config's arena, which
    // is what a later clone or theme diagnostic would read.
    cfg.deinit();
    const switched_path = switch (switched._theme_location) {
        .file => |file| file.path,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(switched_path.ptr != source_path.ptr);
    try testing.expectEqualStrings(root, switched_path);

    var cloned = try switched.clone(alloc);
    defer cloned.deinit();
    try testing.expect(cloned._theme_location == .file);

    // The theme could not be opened, so there is a diagnostic pointing at
    // the file that named it.
    var found = false;
    for (switched._diagnostics.items()) |diag| {
        switch (diag.location) {
            .file => |file| {
                try testing.expectEqualStrings(root, file.path);
                found = true;
            },
            else => {},
        }
    }
    try testing.expect(found);
}

test "ghostty_config_load: a bad CLI argument does not reject the file" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeConfig(&tmp.dir, "config", "cursor-style = block\n");
    defer alloc.free(path);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    ghostty_config_load_file(&cfg, path.ptr);
    var args: CliArgs = .{ .args = &.{"--not-a-real-field=1"} };
    try cfg.loadIter(alloc, &args);
    ghostty_config_finalize(&cfg);

    try testing.expect(!ghostty_config_load_failed(&cfg));
    try testing.expect(ghostty_config_diagnostics_count(&cfg) > 0);
    try testing.expectEqual(@as(u32, 0), ghostty_config_reload_diagnostics_count(&cfg));
}

test "ghostty_config_load: a file error still rejects alongside a bad CLI argument" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeConfig(&tmp.dir, "config", "not-a-real-field = 1\n");
    defer alloc.free(path);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    ghostty_config_load_file(&cfg, path.ptr);
    var args: CliArgs = .{ .args = &.{"--also-not-real=1"} };
    try cfg.loadIter(alloc, &args);
    ghostty_config_finalize(&cfg);

    try testing.expect(ghostty_config_reload_diagnostics_count(&cfg) > 0);
}

test "ghostty_config_load: loadFile still rejects an empty file" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeConfig(&tmp.dir, "config", "");
    defer alloc.free(path);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    try testing.expectError(error.FileIsEmpty, cfg.loadFile(alloc, path));
}

test "ghostty_config_load: empty explicit file is valid" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeConfig(&tmp.dir, "config", "");
    defer alloc.free(path);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    ghostty_config_load_file(&cfg, path.ptr);
    ghostty_config_finalize(&cfg);
    try testing.expect(!ghostty_config_load_failed(&cfg));
    try testing.expectEqual(@as(u32, 0), ghostty_config_diagnostics_count(&cfg));
    const flat = try listedPaths(&cfg);
    defer alloc.free(flat.ptr[0 .. flat.len + 1]);
    try testing.expect(std.mem.indexOf(u8, flat, path) != null);
}

test "ghostty_config_load: empty default candidate is valid" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try writeConfig(&tmp.dir, "config.ghostty", "");
    defer alloc.free(path);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    // Default locations are read through this entry point. A temp path keeps
    // the test off the user's config and away from template creation.
    // An empty file stays .error, the baseline result loadDefaultFiles uses
    // to decide the file exists.
    try testing.expectEqual(.@"error", cfg.loadOptionalFile(alloc, path));
    ghostty_config_finalize(&cfg);
    try testing.expect(!ghostty_config_load_failed(&cfg));
    try testing.expectEqual(@as(u32, 0), ghostty_config_diagnostics_count(&cfg));
    const flat = try listedPaths(&cfg);
    defer alloc.free(flat.ptr[0 .. flat.len + 1]);
    try testing.expect(std.mem.indexOf(u8, flat, path) != null);
    const file = try std.Io.Dir.openFileAbsolute(global.io(), path, .{});
    defer file.close(global.io());
    try testing.expectEqual(@as(u64, 0), (try file.stat(global.io())).size);
}

test "ghostty_config_load: empty referenced file is valid" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const extra = try writeConfig(&tmp.dir, "extra", "");
    defer alloc.free(extra);
    const text = try std.fmt.allocPrint(alloc, "config-file = {s}\n", .{extra});
    defer alloc.free(text);
    const root = try writeConfig(&tmp.dir, "config", text);
    defer alloc.free(root);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    ghostty_config_load_file(&cfg, root.ptr);
    ghostty_config_load_recursive_files(&cfg);
    ghostty_config_finalize(&cfg);
    try testing.expect(!ghostty_config_load_failed(&cfg));
    try testing.expectEqual(@as(u32, 0), ghostty_config_diagnostics_count(&cfg));
    const flat = try listedPaths(&cfg);
    defer alloc.free(flat.ptr[0 .. flat.len + 1]);
    try testing.expect(std.mem.indexOf(u8, flat, extra) != null);
}

test "ghostty_config_load_paths: records the files actually opened" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const extra = try writeConfig(&tmp.dir, "extra", "cursor-style = block\n");
    defer alloc.free(extra);
    const theme = try writeConfig(&tmp.dir, "theme", "background = #111111\n");
    defer alloc.free(theme);
    const text = try std.fmt.allocPrint(alloc, "config-file = {s}\ntheme = {s}\n", .{ extra, theme });
    defer alloc.free(text);
    const root = try writeConfig(&tmp.dir, "config", text);
    defer alloc.free(root);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    try cfg.loadFile(alloc, root);
    try cfg.loadRecursiveFiles(alloc);
    try cfg.finalize();
    try testing.expect(!cfg._load_failed);

    const flat = try listedPaths(&cfg);
    defer if (flat.len > 0) alloc.free(flat.ptr[0 .. flat.len + 1]);
    // The theme path is recorded before loadTheme replaces the config, so
    // this also pins that the replacement keeps what the load recorded.
    try testing.expect(std.mem.indexOf(u8, flat, root) != null);
    try testing.expect(std.mem.indexOf(u8, flat, extra) != null);
    try testing.expect(std.mem.indexOf(u8, flat, theme) != null);

    var cloned = try cfg.clone(alloc);
    defer cloned.deinit();
    const cloned_flat = try listedPaths(&cloned);
    defer if (cloned_flat.len > 0) alloc.free(cloned_flat.ptr[0 .. cloned_flat.len + 1]);
    try testing.expect(std.mem.indexOf(u8, cloned_flat, theme) != null);
}

test "ghostty_config_load_paths: an optional file is recorded even when absent" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPathFile(global.io(), ".", &dir_buf);
    const absent = try std.fs.path.join(alloc, &.{ dir_buf[0..dir_len], "absent" });
    defer alloc.free(absent);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    // loadDefaultFiles checks its candidates through loadOptionalFile, so
    // this is the path those checks record.
    try testing.expectEqual(.not_found, cfg.loadOptionalFile(alloc, absent));
    try testing.expect(!cfg._load_failed);

    const flat = try listedPaths(&cfg);
    defer if (flat.len > 0) alloc.free(flat.ptr[0 .. flat.len + 1]);
    try testing.expect(std.mem.indexOf(u8, flat, absent) != null);
}

test "ghostty_config_load_failed: an optional file that fails to open is a failure" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink(global.io(), "loop", "loop", .{});
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPathFile(global.io(), ".", &dir_buf);
    const loop = try std.fs.path.join(alloc, &.{ dir_buf[0..dir_len], "loop" });
    defer alloc.free(loop);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    // file_load.open maps every open error other than FileNotFound to
    // FileOpenFailed, and loadOptionalFile must record that as a failure.
    // A symlink pointing at itself is one such error.
    try testing.expectEqual(.@"error", cfg.loadOptionalFile(alloc, loop));
    try testing.expect(cfg._load_failed);

    const flat = try listedPaths(&cfg);
    defer if (flat.len > 0) alloc.free(flat.ptr[0 .. flat.len + 1]);
    try testing.expect(std.mem.indexOf(u8, flat, loop) != null);
}

test "ghostty_config_load_paths: a missing referenced file is still recorded" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPathFile(global.io(), ".", &dir_buf);
    const missing = try std.fs.path.join(alloc, &.{ dir_buf[0..dir_len], "extra" });
    defer alloc.free(missing);
    const text = try std.fmt.allocPrint(alloc, "config-file = {s}\n", .{missing});
    defer alloc.free(text);
    const root = try writeConfig(&tmp.dir, "config", text);
    defer alloc.free(root);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    try cfg.loadFile(alloc, root);
    try cfg.loadRecursiveFiles(alloc);

    const flat = try listedPaths(&cfg);
    defer if (flat.len > 0) alloc.free(flat.ptr[0 .. flat.len + 1]);
    try testing.expect(std.mem.indexOf(u8, flat, missing) != null);
}

test "ghostty_config_load_failed: theme finalization keeps the failure" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const theme = try writeConfig(&tmp.dir, "theme", "background = #111111\n");
    defer alloc.free(theme);
    const text = try std.fmt.allocPrint(alloc, "theme = {s}\n", .{theme});
    defer alloc.free(text);
    const root = try writeConfig(&tmp.dir, "config", text);
    defer alloc.free(root);

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    try cfg.loadFile(alloc, root);
    // A failure recorded before finalize must outlive the config rebuild
    // loadTheme does, since that rebuild is what a reload then inspects.
    recordLoadFailure(&cfg, "error loading configuration file");
    try cfg.finalize();
    try testing.expect(cfg._load_failed);
}

test "ghostty_config_load_failed: a failed load is recorded" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    try testing.expect(!ghostty_config_load_failed(&cfg));
    // Drive the recording directly. The exported load functions log the
    // underlying error first, and the test runner counts every error log
    // as a failure no matter what the test does with the log level.
    recordLoadFailure(&cfg, "error loading configuration file");
    try testing.expect(ghostty_config_load_failed(&cfg));
    try testing.expect(!cfg._diagnostics.empty());

    var cloned = try cfg.clone(alloc);
    defer cloned.deinit();
    try testing.expect(cloned._load_failed);
}

test "ghostty_config_get: unknown key returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var out = false;
    const key = "not-a-real-key";
    try testing.expect(!ghostty_config_get(&cfg, &out, key, key.len));
}

test "ghostty_config_get: optional string null returns true" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.title = null;

    var out: ?[*:0]const u8 = undefined;
    const key = "title";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    try testing.expect(out == null);
}

test "ghostty_config_get: float" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"background-opacity" = 0.42;

    var out: f64 = 0;
    const key = "background-opacity";
    try testing.expect(ghostty_config_get(&cfg, &out, key, key.len));
    try testing.expectApproxEqAbs(@as(f64, 0.42), out, 0.000001);
}

test "ghostty_config_get: struct cval conversion" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.background = .{ .r = 12, .g = 34, .b = 56 };

    var out: Config.Color.C = undefined;
    const key = "background";
    try testing.expect(ghostty_config_get(&cfg, @ptrCast(&out), key, key.len));
    try testing.expectEqual(@as(u8, 12), out.r);
    try testing.expectEqual(@as(u8, 34), out.g);
    try testing.expectEqual(@as(u8, 56), out.b);
}

test "ghostty_config_trigger: default keybind" {
    const testing = std.testing;

    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();

    // Default commands should be fetchable through config_trigger_
    {
        const trigger = try config_trigger_(&cfg, "open_config");
        try testing.expectEqual(.unicode, trigger.tag);
        try testing.expectEqual(@as(u32, ','), trigger.key.unicode);
    }
    {
        const trigger = try config_trigger_(&cfg, "reload_config");
        try testing.expectEqual(.unicode, trigger.tag);
        try testing.expectEqual(@as(u32, ','), trigger.key.unicode);
    }
    // Performable bindings are not tracked in the reverse map,
    // so config_trigger_ should return a default (empty) trigger.
    if (comptime builtin.target.os.tag.isDarwin()) {
        const next = try config_trigger_(&cfg, "navigate_search:next");
        try testing.expectEqual(.physical, next.tag);
        try testing.expectEqual(.unidentified, next.key.physical);

        const prev = try config_trigger_(&cfg, "navigate_search:previous");
        try testing.expectEqual(.physical, prev.tag);
        try testing.expectEqual(.unidentified, prev.key.physical);
    }
    {
        const trigger = try config_trigger_(&cfg, "adjust_selection:left");
        try testing.expectEqual(.physical, trigger.tag);
        try testing.expectEqual(.unidentified, trigger.key.physical);
    }
}
