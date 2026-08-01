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

pub fn stripNewLine(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\n')
        line[0 .. line.len - 1]
    else
        line;
}

pub const Line = struct {
    hash: u64,
    str: []const u8,
};

pub fn hashLine(comptime caseInsensitive: bool, s: []const u8) u64 {
    return if (caseInsensitive)
        regent.hash.hashString(s)
    else
        std.hash_map.hashString(s);
}

pub fn makeLine(comptime caseInsensitive: bool, s: []const u8) Line {
    return .{ .hash = hashLine(caseInsensitive, s), .str = s };
}

pub fn LineContext(comptime caseInsensitive: bool) type {
    return struct {
        pub fn hash(_: @This(), l: Line) u64 {
            return l.hash;
        }

        pub fn eql(_: @This(), a: Line, b: Line) bool {
            if (a.hash != b.hash) return false;
            return if (caseInsensitive)
                regent.hash.eqlString(a.str, b.str)
            else
                std.mem.eql(u8, a.str, b.str);
        }
    };
}

pub const frontloadHashBytes = 256 << 10;

pub fn frontLoadHashEntries(comptime Map: type) Map.Size {
    const slotBytes = @sizeOf(Map.KV) + 1;
    const slots = std.math.floorPowerOfTwo(usize, frontloadHashBytes / slotBytes);
    return @intCast(slots * std.hash_map.default_max_load_percentage / 100);
}

pub fn StrSet(comptime caseInsensitive: bool) type {
    return std.HashMapUnmanaged(
        Line,
        u32,
        LineContext(caseInsensitive),
        std.hash_map.default_max_load_percentage,
    );
}

pub const HashCapacityEstimator = struct {
    fileSize: u64,
    lines: u64 = 0,
    bytes: u64 = 0,

    pub const triggerPercent = 75;

    pub fn hint(self: *@This(), lineLen: usize, count: usize, capacity: usize) ?u32 {
        if (self.fileSize == 0) return null;
        self.lines += 1;
        self.bytes += lineLen;

        if (count * 100 < capacity * triggerPercent) return null;

        const avg = @max(1, self.bytes / self.lines);
        const est = self.fileSize / avg +| 1;

        // hash is growing based on unique entries not lines, so we need a ratio
        // that accounts for uniqueness and byte utilization, this ratio
        // takes the est we made base on lines and potentially re-balances it based on count
        const seen = @min(@as(u64, @intCast(count)), self.lines);
        const unique: u64 = @intCast(@divTrunc(
            @as(u128, est) * @as(u128, seen),
            @as(u128, self.lines),
        ));

        const target = @max(unique, count +| count / 2);

        return std.math.cast(u32, target) orelse std.math.maxInt(u32);
    }
};

pub fn rebaseLines(
    comptime caseInsensitive: bool,
    lhs: *StrSet(caseInsensitive),
    lhsInLine: *std.ArrayListUnmanaged(Line),
    oldBase: [*]const u8,
    newBase: [*]const u8,
) void {
    var it = lhs.keyIterator();
    while (it.next()) |key| {
        key.str.ptr = newBase + (@intFromPtr(key.str.ptr) - @intFromPtr(oldBase));
    }
    for (lhsInLine.items) |*l| {
        l.str.ptr = newBase + (@intFromPtr(l.str.ptr) - @intFromPtr(oldBase));
    }
}

// lhs always pays top memory price for its lines (whole file and maybe growth factor padding)
pub fn populateLhs(
    comptime caseInsensitive: bool,
    comptime sorted: bool,
    allocator: std.mem.Allocator,
    fstream: *regent.fs.FileStream(.read),
    lhs: *StrSet(caseInsensitive),
    lhsInLine: *std.ArrayListUnmanaged(Line),
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

    var estimator: HashCapacityEstimator = .{ .fileSize = @intCast(@max(0, fstream.stat.size)) };
    try lhs.ensureTotalCapacity(allocator, frontLoadHashEntries(@TypeOf(lhs.*)));
    if (!sorted) try lhsInLine.ensureTotalCapacity(allocator, 128 << 10);

    while (true) {
        if (fstream.bufferType == .full) {
            // this is technically super bad, but we are guaranteed to never expand on full
            const line = (try fstream.readLineRetained(
                allocator,
                @constCast(&@as(std.ArrayList(u8), .empty)),
            )) orelse break;

            const key = makeLine(caseInsensitive, stripNewLine(line));
            if (estimator.hint(line.len, lhs.count(), lhs.capacity())) |cap|
                try lhs.ensureTotalCapacity(allocator, cap);
            try lhs.put(allocator, key, 0);
            if (!sorted) try lhsInLine.append(allocator, key);
        } else {
            const oldBase: [*]const u8 = resizeable.items.ptr;
            const line = (try fstream.readLineRetained(allocator, &resizeable)) orelse break;

            // rebase is needed on expansion
            if (resizeable.items.ptr != oldBase)
                rebaseLines(caseInsensitive, lhs, lhsInLine, oldBase, resizeable.items.ptr);

            const key = makeLine(caseInsensitive, stripNewLine(line));
            if (estimator.hint(line.len, lhs.count(), lhs.capacity())) |cap|
                try lhs.ensureTotalCapacity(allocator, cap);
            try lhs.put(allocator, key, 0);
            if (!sorted) try lhsInLine.append(allocator, key);
        }
    }
}

pub fn operate(
    comptime caseInsensitive: bool,
    comptime sorted: bool,
    mode: SetMode,
    context: regent.ergo.Context,
    fc: *regent.fs.FileCursor(.read),
    lhs: *StrSet(caseInsensitive),
    lhsInLine: *std.ArrayListUnmanaged(Line),
) !void {
    // We arent using lhs's buffer because it's occupied with lhs's entries through readLineRetained
    // further expansions would be expensive
    var resizeableBuff: std.ArrayListAlignedUnmanaged(u8, regent.fs.oDirectAlignment) = try .initCapacity(
        context.allocator,
        regent.fs.BufferConfig.defaultReaderConfig.fileBufferSize,
    );
    defer resizeableBuff.deinit(context.allocator);

    var generation: u32 = 0;

    while (true) {
        var rhStream = try fc.nextUnmanaged(context) orelse break;
        rhStream.setBuffer(regent.fs.oDirectAlignment, resizeableBuff.allocatedSlice());
        defer rhStream.close(context);

        generation += 1;

        while (true) {
            // readLineRetained is used here purely as a way to amortize buffer growth and keep the buffer big for subsequent reads
            const line = (try rhStream.readLineRetained(context.allocator, &resizeableBuff)) orelse break;
            const key = makeLine(caseInsensitive, stripNewLine(line));
            switch (mode) {
                // 2x copy, but that's necessary, unless we keep all files in mem which is extremely wasteful
                .@"union" => {
                    const gop = try lhs.getOrPut(context.allocator, key);
                    if (!gop.found_existing) {
                        gop.key_ptr.str = try context.allocator.dupe(u8, key.str);
                        gop.value_ptr.* = 0;
                        if (!sorted) try lhsInLine.append(context.allocator, gop.key_ptr.*);
                    }
                },
                .intersection => {
                    if (lhs.getPtr(key)) |stamp| stamp.* = generation;
                },
                // All items inside here are inside lhs retained buffer and dont need to be freed
                .subtraction => _ = lhs.remove(key),
            }
        }

        switch (mode) {
            .intersection => {
                var it = lhs.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* != generation)
                        // all items inside here are handled inside lhs retained buffer and dont need to be freed
                        lhs.removeByPtr(entry.key_ptr);
                }
            },
            .@"union", .subtraction => {},
        }
    }
}

fn writeSortedKeys(
    comptime caseInsensitive: bool,
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    lhs: *const StrSet(caseInsensitive),
) !void {
    const all: [][]const u8 = try allocator.alloc([]const u8, lhs.count());
    defer allocator.free(all);

    var it = lhs.keyIterator();
    var i: usize = 0;
    while (it.next()) |key| : (i += 1) all[i] = key.str;

    try regent.sort.multiKeyQuickSort(allocator, all);

    for (all) |key| {
        try w.writeAll(key);
        try w.writeByte('\n');
    }
    try w.flush();
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

    // this guy has a simple deinit because it doesnt retain anything that isnt in lhs
    var lhsInLine: std.ArrayListUnmanaged(Line) = .empty;
    defer lhsInLine.deinit(context.allocator);

    // this guy as keys with 2 lifecycles, one based on lhsStream buffer (retained first left-hand side read)
    // subsequent dupes for right hand side on union new lines
    var lhs: StrSet(caseInsensitive) = .empty;
    defer {
        if (mode == .@"union") {
            var it = lhs.keyIterator();
            const lhsBuf = lhsStream.stream.interface.buffer;
            const lhsBufstart = lhsBuf.ptr;
            const lhsBufEnd = lhsBuf[lhsBuf.len - 1 ..].ptr;

            while (it.next()) |key| {
                if (@intFromPtr(key.str.ptr) > @intFromPtr(lhsBufEnd) or @intFromPtr(key.str.ptr) < @intFromPtr(lhsBufstart)) {
                    context.allocator.free(key.str);
                }
            }
        }
        lhs.deinit(context.allocator);
    }

    if (sorted) {
        try populateLhs(
            caseInsensitive,
            true,
            context.allocator,
            &lhsStream,
            &lhs,
            &lhsInLine,
        );

        try operate(
            caseInsensitive,
            true,
            mode,
            context,
            &fc,
            &lhs,
            &lhsInLine,
        );
    } else {
        try populateLhs(
            caseInsensitive,
            false,
            context.allocator,
            &lhsStream,
            &lhs,
            &lhsInLine,
        );

        try operate(
            caseInsensitive,
            false,
            mode,
            context,
            &fc,
            &lhs,
            &lhsInLine,
        );
    }

    if (sorted) {
        try writeSortedKeys(caseInsensitive, context.allocator, global.stdoutW, &lhs);
    } else {
        for (lhsInLine.items) |l| {
            // containers reuse stored hash, no re-hashing is needed
            if (lhs.contains(l)) {
                try global.stdoutW.writeAll(l.str);
                try global.stdoutW.writeByte('\n');
            }
        }
        try global.stdoutW.flush();
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

    var lhs: StrSet(true) = .empty;
    defer lhs.deinit(testing.allocator);

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

    var lhsInLine: std.ArrayListUnmanaged(Line) = .empty;
    defer lhsInLine.deinit(testing.allocator);

    try populateLhs(
        true,
        false,
        testing.allocator,
        &lhsStream,
        &lhs,
        &lhsInLine,
    );

    for (@as([]const []const u8, &.{
        "aaaaaaaaaaaaaaaaaaaaaa",
        "bbbbbbbbbbbbbbbbbbbbb",
        "cccccccccccccccccccc",
    })) |line| {
        try testing.expect(lhs.contains(makeLine(true, line)));
    }
    try testing.expectEqual(3, lhs.size);

    for (@as([]const []const u8, content), lhsInLine.items) |expect, line| {
        try testing.expectEqualStrings(stripNewLine(expect), line.str);
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

    var lhs: StrSet(true) = .empty;
    defer lhs.deinit(testing.allocator);

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

    var lhsInLine: std.ArrayListUnmanaged(Line) = .empty;
    defer lhsInLine.deinit(testing.allocator);

    try populateLhs(
        true,
        false,
        testing.allocator,
        &lhsStream,
        &lhs,
        &lhsInLine,
    );

    try testing.expectEqual(3, lhs.size);
    for (@as([]const []const u8, &.{
        "aaaaaaa",
        "aaaa",
        "bb",
    })) |line| {
        try testing.expect(lhs.contains(makeLine(true, line)));
    }

    for (@as([]const []const u8, content), lhsInLine.items) |expect, line| {
        try testing.expectEqualStrings(stripNewLine(expect), line.str);
    }
    try testing.expectEqual(content.len, lhsInLine.items.len);
    try testing.expectEqual(28, lhsStream.stream.interface.buffer.len);
}

test "stripNewLine" {
    try testing.expectEqualStrings("", stripNewLine(""));
    try testing.expectEqualStrings("", stripNewLine("\n"));
    try testing.expectEqualStrings("a", stripNewLine("a"));
    try testing.expectEqualStrings("a", stripNewLine("a\n"));
    // this is an opportunistic strip
    try testing.expectEqualStrings("a\n", stripNewLine("a\n\n"));
}

fn tmpFilePath(allocator: std.mem.Allocator, tmp: *const testing.TmpDir, name: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

fn populateFromFile(
    comptime caseInsensitive: bool,
    tmp: *const std.testing.TmpDir,
    name: []const u8,
    lhs: *StrSet(caseInsensitive),
    lhsInLine: *std.ArrayListUnmanaged(Line),
    bufferType: regent.fs.BufferType,
) !regent.fs.FileStream(.read) {
    const context: regent.ergo.Context = .{ .io = testing.io, .allocator = testing.allocator };
    const f = try tmp.dir.openFile(testing.io, name, .{ .mode = .read_only });
    errdefer f.close(testing.io);

    var stream = try regent.fs.FileStream(.read).openStreamWithConfig(
        context,
        f,
        .{},
        bufferType,
        if (bufferType == .byte) .initSame(1) else .defaultReaderConfig,
        null,
    );
    errdefer stream.deinit(context);

    try populateLhs(
        caseInsensitive,
        false,
        testing.allocator,
        &stream,
        lhs,
        lhsInLine,
    );

    return stream;
}

fn closeStream(stream: *regent.fs.FileStream(.read)) void {
    const context: regent.ergo.Context = .{ .io = testing.io, .allocator = testing.allocator };
    stream.deinit(context);
    stream.close(context);
}

fn fuzzReference(
    allocator: std.mem.Allocator,
    mode: SetMode,
    files: []const []const []const u8,
) !std.StringHashMapUnmanaged(void) {
    var ref: std.StringHashMapUnmanaged(void) = .empty;
    errdefer ref.deinit(allocator);

    for (files[0]) |line| try ref.put(allocator, line, {});

    for (files[1..]) |rhs| {
        switch (mode) {
            .@"union" => for (rhs) |line| try ref.put(allocator, line, {}),
            .subtraction => for (rhs) |line| {
                _ = ref.remove(line);
            },
            .intersection => {
                var present: std.StringHashMapUnmanaged(void) = .empty;
                defer present.deinit(allocator);
                for (rhs) |line| try present.put(allocator, line, {});

                var it = ref.keyIterator();
                while (it.next()) |key| {
                    if (!present.contains(key.*)) ref.removeByPtr(key);
                }
            },
        }
    }
    return ref;
}

test "fuzz set operations against reference" {
    var tmpDir = testing.tmpDir(.{});
    defer tmpDir.cleanup();

    var seedBuf: [@sizeOf(u64)]u8 = undefined;
    std.Io.random(testing.io, &seedBuf);
    var prng = std.Random.DefaultPrng.init(@bitCast(seedBuf));

    const rng = prng.random();

    for (0..8) |round| {
        var roundArena = std.heap.ArenaAllocator.init(testing.allocator);
        defer roundArena.deinit();
        const roundAlloc = roundArena.allocator();

        const numFiles = rng.intRangeAtMost(usize, 2, 4);
        var files: [][]const []const u8 = try roundAlloc.alloc([]const []const u8, numFiles);
        var names: [][]const u8 = try roundAlloc.alloc([]const u8, numFiles);

        for (0..numFiles) |fi| {
            const numLines = rng.intRangeAtMost(usize, 0, 2000);
            const lines = try roundAlloc.alloc([]const u8, numLines);
            var content: std.ArrayListUnmanaged(u8) = .empty;

            for (lines) |*line| {
                const len = rng.uintAtMost(usize, 2000);
                const buf = try roundAlloc.alloc(u8, len);

                for (0..len) |i| buf[i] = 'a' + rng.uintLessThan(u8, 'z' - 'a' + 1);
                line.* = buf;

                try content.appendSlice(roundAlloc, buf);
                try content.append(roundAlloc, '\n');
            }

            // drop tailing null-lines for las line
            if (numLines > 0 and lines[numLines - 1].len > 0 and rng.uintLessThan(u8, 5) == 0)
                _ = content.pop();

            names[fi] = try std.fmt.allocPrint(roundAlloc, "r{d}f{d}", .{ round, fi });
            _ = try makeFile(tmpDir.dir, testing.io, names[fi], &.{content.items});
            files[fi] = lines;
        }

        for (std.meta.tags(SetMode)) |mode| {
            var ref = try fuzzReference(testing.allocator, mode, files);
            defer ref.deinit(testing.allocator);

            var lhsStream: regent.fs.FileStream(.read) = undefined;
            defer closeStream(&lhsStream);

            var lhsInLine: std.ArrayListUnmanaged(Line) = .empty;
            defer lhsInLine.deinit(testing.allocator);
            var lhs: StrSet(false) = .empty;
            defer {
                if (mode == .@"union") {
                    var it = lhs.keyIterator();
                    const lhsBuf = lhsStream.stream.interface.buffer;
                    const lhsBufstart = lhsBuf.ptr;
                    const lhsBufEnd = lhsBuf[lhsBuf.len - 1 ..].ptr;

                    while (it.next()) |key| {
                        if (@intFromPtr(key.str.ptr) > @intFromPtr(lhsBufEnd) or @intFromPtr(key.str.ptr) < @intFromPtr(lhsBufstart)) {
                            testing.allocator.free(key.str);
                        }
                    }
                }
                lhs.deinit(testing.allocator);
            }

            const bufferType: regent.fs.BufferType = if (rng.boolean()) .byte else .full;
            lhsStream = try populateFromFile(
                false,
                &tmpDir,
                names[0],
                &lhs,
                &lhsInLine,
                bufferType,
            );

            const rhsPaths = try roundAlloc.alloc([]const u8, numFiles - 1);
            for (rhsPaths, names[1..]) |*p, name| {
                p.* = try tmpFilePath(roundAlloc, &tmpDir, name);
            }

            var fc = regent.fs.FileCursor(.read).initWithConfig(rhsPaths, .{ .recursive = false });
            defer fc.deinit();

            const context: regent.ergo.Context = .{ .io = testing.io, .allocator = testing.allocator };
            try operate(
                false,
                true,
                mode,
                context,
                &fc,
                &lhs,
                &lhsInLine,
            );

            try testing.expectEqual(ref.count(), lhs.size);
            var it = ref.keyIterator();
            while (it.next()) |key| {
                try testing.expect(lhs.contains(makeLine(false, key.*)));
            }
            var lit = lhs.keyIterator();
            while (lit.next()) |key| {
                try testing.expect(ref.contains(key.str));
            }
        }
    }
}
