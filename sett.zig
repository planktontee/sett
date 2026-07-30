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
    sorted: bool = false,

    pub const Short = .{
        .m = .mode,
        .i = .@"ignore-case",
        .s = .sorted,
    };

    pub const Help: zcasp.help.HelpData(@This()) = .{
        .usage = &.{"sett <options> <file1> <file2> <...fileN>?"},
        .description = "Cli to run set operations on a chain of files. Output order is line order, unless --sorted is used.",
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
            .{ .field = .sorted, .description = "Sorts output." },
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
};

var global: Global = undefined;
const DebugAlloc = std.heap.DebugAllocator(.{});

pub fn main(init: std.process.Init.Minimal) u8 {
    const result = if (builtin.mode == .Debug) r: {
        var da: DebugAlloc = .{};
        const allocator = da.allocator();

        break :r trampMain(.{ allocator, init });
    } else regent.trampoline.stackTrampoline(
        u6,
        1,
        trampMain,
        .{ null, init },
    );

    const finalCode: u8 = result catch |e| r: {
        const tagIn: bool = inline for (std.meta.tags(ArgsResponse.Error)) |tag| {
            if (tag == e) break true;
        } else false;
        if (!tagIn) std.log.err("{s}\n", .{@errorName(e)});

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

pub fn trampMain(args: struct { ?std.mem.Allocator, std.process.Init.Minimal }) !u8 {
    const optAlloc, const init = args;
    const allocator = if (optAlloc) |alloc| r: {
        if (builtin.mode == .Debug) break :r alloc;

        const fba: *std.heap.FixedBufferAllocator = @ptrCast(@alignCast(alloc.ptr));
        var pfba: regent.mem.PromotingSfba = .{
            .fallback_allocator = std.heap.smp_allocator,
            .fixed_buffer_allocator = fba.*,
        };
        break :r pfba.allocator();
    } else std.heap.smp_allocator;

    global.context = .{
        .allocator = allocator,
        .io = std.Io.Threaded.global_single_threaded.io(),
    };

    global.stdoutStream = try regent.fs.FileStream(.write).openStream(
        global.context,
        std.Io.File.stdout(),
    );
    var stdoutS = global.stdoutStream;
    defer stdoutS.deinit(global.context);

    global.stdoutW = &global.stdoutStream.stream.interface;
    global.stderrStream = try regent.fs.FileStream(.write).openStream(
        global.context,
        std.Io.File.stderr(),
    );
    global.stderrW = &global.stderrStream.stream.interface;
    var stderrS = global.stderrStream;
    defer stderrS.deinit(global.context);

    var argsRes: ArgsResponse = .init(allocator);
    defer argsRes.deinit();

    if (argsRes.parseArgs(init.args)) |parseError| {
        try global.stderrW.print("Last opt <{?s}>, Last token <{?s}>. ", .{ parseError.lastOpt, parseError.lastToken });
        if (parseError.message) |message| try global.stderrW.writeAll(message);
        try global.stderrW.flush();
        return parseError.err;
    }

    if (argsRes.options.@"ignore-case")
        try runSetOperation(true, &argsRes)
    else
        try runSetOperation(false, &argsRes);

    return 0;
}

pub const RunSetOperationError = error{MissingPathsToCompare};

// lhs always pays top memory price for its lines (whole file and maybe growth factor padding)
pub fn populateLhs(
    comptime caseInsensitive: bool,
    comptime sorted: bool,
    allocator: std.mem.Allocator,
    arenaContext: regent.ergo.Context,
    fstream: *regent.fs.FileStream(.read),
    lhs: *StrSet(caseInsensitive),
    lhsInLine: *std.ArrayListUnmanaged([]const u8),
) !void {
    const r: *std.Io.Reader = &fstream.stream.interface;
    const initialBuffer = r.buffer;
    // This alignment could technically be off, based on what's inside fstream
    var resizeable: std.ArrayListAlignedUnmanaged(u8, regent.fs.bufferAlignment) = .initBuffer(@alignCast(r.buffer));
    errdefer resizeable.deinit(allocator);
    defer {
        if (fstream.bufferType == .full) {
            r.buffer = initialBuffer;
            r.seek = initialBuffer.len - 1;
            r.end = r.seek;
        } else {
            // this ensures it can be freed later as part of fstream, owning resizeable's internals
            const newB = resizeable.allocatedSlice();
            r.seek = r.seek + newB.len - r.buffer.len;
            r.end = r.seek;
            r.buffer = newB;
        }
    }

    while (true) {
        if (fstream.bufferType == .full) {
            // this is technically super bad, but we are guaranteed to never expand on full
            const line = (try fstream.readLineRetained(
                allocator,
                @constCast(&@as(std.ArrayList(u8), .empty)),
            )) orelse break;

            try lhs.put(arenaContext.allocator, line, {});
            if (!sorted) try lhsInLine.append(arenaContext.allocator, line);
        } else {
            const line = (try fstream.readLineRetained(allocator, &resizeable)) orelse break;

            try lhs.put(arenaContext.allocator, line, {});
            if (!sorted) try lhsInLine.append(arenaContext.allocator, line);
        }
    }
}

pub fn operate(
    comptime caseInsensitive: bool,
    comptime sorted: bool,
    mode: SetMode,
    context: regent.ergo.Context,
    lhsArena: std.mem.Allocator,
    fc: *regent.fs.FileCursor(.read),
    lhs: *StrSet(caseInsensitive),
    lhsInLine: *std.ArrayListUnmanaged([]const u8),
) !void {
    var rhs: @TypeOf(lhs.*) = .empty;
    defer rhs.deinit(context.allocator);

    var resizeableBuff: std.ArrayListAlignedUnmanaged(u8, regent.fs.oDirectAlignment) = try .initCapacity(
        context.allocator,
        regent.fs.BufferConfig.defaultReaderConfig.fileBufferSize,
    );
    defer resizeableBuff.deinit(context.allocator);

    while (true) {
        var rhStream = try fc.nextUnmanaged(context) orelse break;
        rhStream.setBuffer(regent.fs.oDirectAlignment, resizeableBuff.allocatedSlice());
        defer {
            rhs.clearRetainingCapacity();
            rhStream.close(context);
        }

        var rhsArena = std.heap.ArenaAllocator.init(context.allocator);
        const rhsArenaAlloc = rhsArena.allocator();
        defer rhsArena.deinit();

        while (true) {
            // readLineRetained is used here purely as a way to amortize buffer growth and keep the buffer big for subsequent reads
            const line = (try rhStream.readLineRetained(context.allocator, &resizeableBuff)) orelse break;
            switch (mode) {
                // 2x copy, but that's necessary, unless we keep all files in mem which is extremely wasteful
                .@"union" => {
                    if (!lhs.contains(line)) {
                        const dupedLine = try lhsArena.dupe(u8, line);
                        try lhs.put(lhsArena, dupedLine, {});
                        if (!sorted) try lhsInLine.append(lhsArena, dupedLine);
                    }
                },
                // 2x copy, but that's necessary, unless we keep all files in mem which is extremely wasteful
                .intersection => {
                    if (!rhs.contains(line))
                        try rhs.put(context.allocator, try rhsArenaAlloc.dupe(u8, line), {});
                },
                // It's possible to shrink the old file buffer in these cases
                // I dont know if it's worth it
                // freeing is handled by lhsArena
                .subtraction => _ = lhs.remove(line),
            }
        }

        switch (mode) {
            .intersection => {
                var it = lhs.keyIterator();
                while (it.next()) |key| {
                    const s = key.*;
                    if (!rhs.contains(s))
                        // freeing is handled by lhsArena
                        _ = lhs.remove(s);
                }
                // freeing rhs copies is handled by rhsArena
            },
            .@"union", .subtraction => {},
        }
    }
}

pub fn StrSet(comptime caseInsensitive: bool) type {
    return std.HashMapUnmanaged(
        []const u8,
        void,
        if (caseInsensitive) regent.hash.StringInsensitiveContext else std.hash_map.StringContext,
        std.hash_map.default_max_load_percentage,
    );
}

pub fn runSetOperation(comptime caseInsensitive: bool, args: *const ArgsResponse) !void {
    const mode = args.options.mode;
    const rawPaths = args.positionals.reminder;
    const sorted = args.options.sorted;

    if (rawPaths == null or rawPaths.?.len < 1) return RunSetOperationError.MissingPathsToCompare;
    const paths = if (rawPaths.?.len >= 2)
        rawPaths.?
    else
        &[_][]const u8{ "-", rawPaths.?[0] };

    const context: regent.ergo.Context = global.context;

    var fc = regent.fs.FileCursor(.read).initWithConfig(paths, .{ .recursive = false });
    defer fc.deinit();

    var arena = std.heap.ArenaAllocator.init(context.allocator);
    const lhsArena = arena.allocator();
    defer arena.deinit();

    const arenaContext: regent.ergo.Context = .{ .io = context.io, .allocator = lhsArena };

    // lhs and lhsInLine and copied file lines will stay inside the Arena because all of them have the
    // same lifecycle and are only 'disposable' together
    var lhs: StrSet(caseInsensitive) = .empty;
    defer lhs.deinit(lhsArena);

    // Sorted can be done with set and a double buffer copy (file -> buffer -> set) on a much smaller
    // buffer. Order aware operation has to go over the entire file and the set later to decide to print.
    // so it better leverages a full buffer.
    // Reminder ultimately FileStream may decide .full is impossible for streaming
    const lhsBufferType: regent.fs.BufferType = if (sorted) .byte else .full;
    var lhsStream = try fc.nextWithConfig(
        context,
        .{},
        lhsBufferType,
        .defaultReaderConfig,
    ) orelse return RunSetOperationError.MissingPathsToCompare;
    defer {
        lhsStream.deinit(context);
        lhsStream.close(context);
    }

    var lhsInLine: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lhsInLine.deinit(lhsArena);

    if (sorted) {
        try populateLhs(
            caseInsensitive,
            true,
            context.allocator,
            arenaContext,
            &lhsStream,
            &lhs,
            &lhsInLine,
        );

        try operate(
            caseInsensitive,
            true,
            mode,
            context,
            lhsArena,
            &fc,
            &lhs,
            &lhsInLine,
        );
    } else {
        try populateLhs(
            caseInsensitive,
            false,
            context.allocator,
            arenaContext,
            &lhsStream,
            &lhs,
            &lhsInLine,
        );

        try operate(
            caseInsensitive,
            false,
            mode,
            context,
            lhsArena,
            &fc,
            &lhs,
            &lhsInLine,
        );
    }

    if (sorted) {
        var all: [][]const u8 = try context.allocator.alloc([]const u8, lhs.count());
        defer context.allocator.free(all);

        var it = lhs.keyIterator();
        var i: usize = 0;
        while (it.next()) |key| : (i += 1) all[i] = key.*;

        std.mem.sortUnstable([]const u8, all, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        for (all) |key| {
            try global.stdoutW.writeAll(key);
            if (key[key.len - 1] != '\n')
                try global.stdoutW.writeByte('\n');
        }
        try global.stdoutW.flush();

        // Final freeing is done by lhsArena
    } else {
        for (lhsInLine.items) |l| {
            if (lhs.contains(l)) {
                try global.stdoutW.writeAll(l);
                if (l[l.len - 1] != '\n')
                    try global.stdoutW.writeByte('\n');
            }
        }
        try global.stdoutW.flush();
        // Final freeing is done by lhsArena
    }
}

const testing = std.testing;

fn makeFile(
    dir: std.Io.Dir,
    io: std.Io,
    name: []const u8,
    content: []const []const u8,
) !std.Io.File {
    const f = try dir.createFile(io, name, .{ .read = true });
    errdefer f.close(io);

    var buf: [regent.fs.BufferConfig.defaultWriterConfig.fileBufferSize]u8 = undefined;

    var fw = f.writer(testing.io, &buf);
    const w = &fw.interface;

    for (content) |line| {
        try w.writeAll(line);
    }
    try w.flush();

    return f;
}

test "populateLhs for byte resizes to track lines" {
    var tmpDir = testing.tmpDir(.{});
    defer tmpDir.cleanup();

    const content = &.{
        // 23
        "aaaaaaaaaaaaaaaaaaaaaa\n",
        // 22
        "bbbbbbbbbbbbbbbbbbbbb\n",
        "bbbbbbbbbbbbbbbbbbbbb\n",
        // 21
        "cccccccccccccccccccc\n",
    };
    const f = try makeFile(tmpDir.dir, testing.io, "resizeByte", content);
    defer f.close(testing.io);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const arenaAlloc = arena.allocator();

    var lhs: StrSet(true) = .empty;
    defer lhs.deinit(arenaAlloc);

    const context: regent.ergo.Context = .{ .io = testing.io, .allocator = testing.allocator };

    var lhsStream = try regent.fs.FileStream(.read).openStreamWithConfig(
        context,
        f,
        .{},
        .byte,
        .initSame(1),
        null,
    );
    defer lhsStream.deinit(context);

    var lhsInLine: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lhsInLine.deinit(arenaAlloc);

    try populateLhs(
        true,
        false,
        testing.allocator,
        .{ .io = testing.io, .allocator = arenaAlloc },
        &lhsStream,
        &lhs,
        &lhsInLine,
    );

    for (@as([]const []const u8, &.{
        "aaaaaaaaaaaaaaaaaaaaaa\n",
        "bbbbbbbbbbbbbbbbbbbbb\n",
        "cccccccccccccccccccc\n",
    })) |line| {
        try testing.expect(lhs.contains(line));
    }
    try testing.expectEqual(3, lhs.size);

    for (@as([]const []const u8, content), lhsInLine.items) |expect, line| {
        try testing.expectEqualStrings(expect, line);
    }
    try testing.expectEqual(content.len, lhsInLine.items.len);
    // buffer actually grows to be file-sized by growth factor
    try testing.expectEqual(131, lhsStream.stream.interface.buffer.len);
}

test "populateLhs for full doesnt resize" {
    var tmpDir = testing.tmpDir(.{});
    defer tmpDir.cleanup();

    const content = &.{
        // 8
        "aaaaaaa\n",
        // 5
        "aaaa\n",
        "aaaaaaa\n",
        "aaaa\n",
        "bb",
    };
    const f = try makeFile(tmpDir.dir, testing.io, "resizeFull", content);
    defer f.close(testing.io);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const arenaAlloc = arena.allocator();

    var lhs: StrSet(true) = .empty;
    defer lhs.deinit(arenaAlloc);

    const context: regent.ergo.Context = .{ .io = testing.io, .allocator = testing.allocator };

    var lhsStream = try regent.fs.FileStream(.read).openStreamWithConfig(
        context,
        f,
        .{},
        .full,
        .defaultReaderConfig,
        null,
    );
    defer lhsStream.deinit(context);

    var lhsInLine: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lhsInLine.deinit(arenaAlloc);

    try populateLhs(
        true,
        false,
        testing.allocator,
        .{ .io = testing.io, .allocator = arenaAlloc },
        &lhsStream,
        &lhs,
        &lhsInLine,
    );

    try testing.expectEqual(3, lhs.size);
    for (@as([]const []const u8, &.{
        "aaaaaaa\n",
        "aaaa\n",
        "bb",
    })) |line| {
        try testing.expect(lhs.contains(line));
    }

    for (@as([]const []const u8, content), lhsInLine.items) |expect, line| {
        try testing.expectEqualStrings(expect, line);
    }
    try testing.expectEqual(content.len, lhsInLine.items.len);
    try testing.expectEqual(28, lhsStream.stream.interface.buffer.len);
}
