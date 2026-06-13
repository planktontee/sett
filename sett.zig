const std = @import("std");
const builtin = @import("builtin");
const regent = @import("regent");
const zcasp = @import("zcasp");

pub const SetMode = enum {
    @"union",
    intersection,
    subtraction,
};

pub const Args = struct {
    mode: SetMode = .intersection,
    @"ignore-case": bool = false,

    pub const Short = .{
        .m = .mode,
        .i = .@"ignore-case",
    };

    pub const Help: zcasp.help.HelpData(@This()) = .{
        .usage = &.{"sett <options> <file1> <file2> <...fileN>?"},
        .description = "Cli to run set operations on a chain of files. Output order is sorted by default.",
        .examples = &.{
            "sett file1 file2",
            "sett -m union file1 file2",
        },
        .positionalsDescription = .{
            .reminder = "Files to operate on.",
        },
        .optionsDescription = &.{
            .{ .field = .mode, .description = "Set operation mode. Supported values: " ++ zcasp.help.enumValueHint(SetMode) ++ "." },
            .{ .field = .@"ignore-case", .description = "Ignores case for set operation." },
        },
    };
};

const ArgsResponse = zcasp.spec.SpecResponseWithConfig(Args, zcasp.help.HelpConf{
    .backwardsBranchesQuote = 1000000,
    .simpleTypes = true,
    .headerDelimiter = "",
}, true);

const Global = struct {
    context: regent.ergo.Context = undefined,
    stdoutStream: regent.fs.FileStream(.write) = undefined,
    stderrStream: regent.fs.FileStream(.write) = undefined,
    stdoutW: *std.Io.Writer = undefined,
    stderrW: *std.Io.Writer = undefined,

    pub fn deinit(self: *const @This()) void {
        var stderrS = self.stderrStream;
        stderrS.deinit(self.context);
        var stdoutS = self.stdoutStream;
        stdoutS.deinit(self.context);
    }
};

var global: *const Global = undefined;
const DebugAlloc = std.heap.DebugAllocator(.{});

pub fn main(init: std.process.Init.Minimal) u8 {
    const result = if (builtin.mode == .Debug) r: {
        var da: DebugAlloc = .{};
        const allocator = da.allocator();

        break :r trampMain(init, allocator);
    } else regent.trampoline.stackTrampoline(
        @typeInfo(@TypeOf(trampMain)).@"fn".return_type.?,
        u6,
        init,
        trampMain,
        1,
    );

    // TODO: define behaviour for classes of errors
    const finalCode: u8 = result catch |e| r: {
        std.log.err("Error: {s}\n", .{@errorName(e)});
        break :r 1;
    };

    if (builtin.mode == .Debug) {
        var da: *DebugAlloc = @ptrCast(@alignCast(global.context.allocator.ptr));

        switch (da.deinit()) {
            .leak,
            => std.log.err("Leaks detected!\n", .{}),
            .ok,
            => {},
        }
    }

    return finalCode;
}

pub fn trampMain(init: std.process.Init.Minimal, optAlloc: ?std.mem.Allocator) !u8 {
    const allocator = if (optAlloc) |alloc|
        alloc
    else
        std.heap.smp_allocator;

    var g: Global = .{
        .context = .{
            .allocator = allocator,
            .io = std.Io.Threaded.global_single_threaded.io(),
        },
    };

    g.stdoutStream = try regent.fs.FileStream(.write).openStream(
        g.context,
        std.Io.File.stdout(),
    );
    g.stdoutW = &g.stdoutStream.stream.interface;
    g.stderrStream = try regent.fs.FileStream(.write).openStream(
        g.context,
        std.Io.File.stderr(),
    );
    g.stderrW = &g.stderrStream.stream.interface;
    global = &g;
    defer global.deinit();

    var argsRes: ArgsResponse = .init(allocator);
    defer argsRes.deinit();

    if (argsRes.parseArgs(init.args)) |parseError| {
        try global.stderrW.print("Last opt <{?s}>, Last token <{?s}>. ", .{ parseError.lastOpt, parseError.lastToken });
        if (parseError.message) |message| try global.stderrW.writeAll(message);
        try global.stderrW.flush();
        return parseError.err;
    }

    if (argsRes.options.@"ignore-case")
        try runSetOperation(true, argsRes.options.mode, argsRes.positionals.reminder)
    else
        try runSetOperation(false, argsRes.options.mode, argsRes.positionals.reminder);

    return 0;
}

pub const RunSetOperationError = error{MissingPathsToCompare};

// TODO:
// 1. debug mode (right/left arrow) for union
pub fn runSetOperation(comptime caseInsentitive: bool, mode: SetMode, rawPaths: ?[]const []const u8) !void {
    const StrSet = std.HashMap(
        []const u8,
        void,
        if (caseInsentitive) regent.hash.StringInsensitiveContext else std.hash_map.StringContext,
        std.hash_map.default_max_load_percentage,
    );

    if (rawPaths == null or rawPaths.?.len < 1) return RunSetOperationError.MissingPathsToCompare;
    const paths = if (rawPaths.?.len >= 2)
        rawPaths.?
    else
        &[_][]const u8{ "-", rawPaths.?[0] };

    const headpContext: regent.ergo.Context = .{
        .allocator = if (builtin.mode == .Debug) global.context.allocator else std.heap.smp_allocator,
        .io = global.context.io,
    };

    var fc = regent.fs.FileCursor(.read).initWithConfig(paths, .{ .recursive = false });
    defer fc.deinit();

    var lhs: StrSet = .init(headpContext.allocator);
    defer lhs.deinit();

    var first = try fc.next(global.context) orelse
        return RunSetOperationError.MissingPathsToCompare;

    {
        defer {
            first.close(headpContext);
            first.deinit(headpContext);
        }
        var r: *std.Io.Reader = &first.stream.interface;
        while (true) {
            const line = (try r.takeDelimiter('\n')) orelse break;
            try lhs.put(try headpContext.allocator.dupe(u8, line), {});
        }
    }

    {
        var rhs: StrSet = .init(headpContext.allocator);
        defer rhs.deinit();

        while (true) {
            var rhStream = try fc.next(global.context) orelse break;
            defer {
                rhs.clearRetainingCapacity();
                rhStream.close(headpContext);
                rhStream.deinit(headpContext);
            }

            var r: *std.Io.Reader = &rhStream.stream.interface;
            while (true) {
                const line = (try r.takeDelimiter('\n')) orelse break;
                if (line.len == 0) continue;
                switch (mode) {
                    .@"union" => {
                        if (!lhs.contains(line))
                            try lhs.put(try headpContext.allocator.dupe(u8, line), {});
                    },
                    .intersection => try rhs.put(line, {}),
                    // It's possible to shrink the old file buffer in these cases
                    // I dont know if it's worth it
                    .subtraction => {
                        if (lhs.remove(line))
                            headpContext.allocator.free(line);
                    },
                }
            }

            switch (mode) {
                .intersection => {
                    var it = lhs.keyIterator();
                    while (it.next()) |key| {
                        const s = key.*;
                        if (!rhs.contains(s))
                            if (lhs.remove(s))
                                headpContext.allocator.free(s);
                    }
                },
                .@"union", .subtraction => {},
            }
        }
    }

    var all: [][]const u8 = try headpContext.allocator.alloc([]const u8, lhs.count());
    defer headpContext.allocator.free(all);

    var it = lhs.keyIterator();
    var i: usize = 0;
    while (it.next()) |key| : (i += 1) all[i] = key.*;

    std.mem.sortUnstable([]const u8, all, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    for (all) |key| {
        var data: [2][]const u8 = .{
            key,
            "\n",
        };
        try global.stdoutW.writeVecAll(&data);
    }
    try global.stdoutW.flush();

    for (all) |key| headpContext.allocator.free(key);
}
