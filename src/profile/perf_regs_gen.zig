//! Emit the host perf user-register checks from records.perfFile.
//! scheduling-decode compiles records.zig alone, so this file is the one
//! that imports it. The numbers are not copied here.

const std = @import("std");
const records = @import("records.zig");

fn writeFile(w: *std.Io.Writer, file: records.PerfFile) !void {
    try w.print("#define XODB_PERF_USER_REGS_LIMIT {d}\n", .{file.limit});
    try w.print("#define XODB_PERF_USER_REGS_REQUIRED ((1ULL << {d}) | (1ULL << {d}))\n", .{ file.sp, file.pc });
}

pub fn render(w: *std.Io.Writer) !void {
    const arm = records.perfFile(records.machine_aarch64) orelse return error.MissingPerfFile;
    const loong = records.perfFile(records.machine_loongarch64) orelse return error.MissingPerfFile;
    const riscv = records.perfFile(records.machine_riscv64) orelse return error.MissingPerfFile;
    const x86 = records.perfFile(records.machine_x86_64) orelse return error.MissingPerfFile;
    try w.writeAll(
        \\/* Generated from records.perfFile. Do not edit.
        \\ * aarch64, loongarch64 and riscv64 use their own files.
        \\ * The #else is x86-64.
        \\ */
        \\#ifndef XODB_PERF_REGS_H
        \\#define XODB_PERF_REGS_H
        \\
    );
    try w.writeAll("#if defined(__aarch64__)\n");
    try writeFile(w, arm);
    try w.writeAll("#elif defined(__loongarch__)\n");
    try writeFile(w, loong);
    try w.writeAll("#elif defined(__riscv) && __riscv_xlen == 64\n");
    try writeFile(w, riscv);
    try w.writeAll("#else\n");
    try writeFile(w, x86);
    try w.writeAll("#endif\n#endif\n");
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.BadUsage;
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try render(&w);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = buf[0..w.end] });
}

fn section(text: []const u8, start: []const u8, end: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, text, start).?;
    const rest = text[at + start.len ..];
    return rest[0 .. std.mem.indexOf(u8, rest, end).?];
}

fn expectFile(text: []const u8, file: records.PerfFile) !void {
    var limit: [80]u8 = undefined;
    var bits: [96]u8 = undefined;
    const limit_line = try std.fmt.bufPrint(&limit, "#define XODB_PERF_USER_REGS_LIMIT {d}\n", .{file.limit});
    const bits_line = try std.fmt.bufPrint(&bits, "#define XODB_PERF_USER_REGS_REQUIRED ((1ULL << {d}) | (1ULL << {d}))\n", .{ file.sp, file.pc });
    try std.testing.expect(std.mem.indexOf(u8, text, limit_line) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, bits_line) != null);
}

test "host register header follows every native perfFile and keeps the x86 else" {
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try render(&w);
    const text = buf[0..w.end];
    try expectFile(section(text, "#if defined(__aarch64__)\n", "#elif defined(__loongarch__)\n"), records.perfFile(records.machine_aarch64).?);
    try expectFile(section(text, "#elif defined(__loongarch__)\n", "#elif defined(__riscv) && __riscv_xlen == 64\n"), records.perfFile(records.machine_loongarch64).?);
    try expectFile(section(text, "#elif defined(__riscv) && __riscv_xlen == 64\n", "#else\n"), records.perfFile(records.machine_riscv64).?);
    try expectFile(section(text, "#else\n", "#endif\n"), records.perfFile(records.machine_x86_64).?);
    const riscv = records.perfFile(records.machine_riscv64).?;
    try std.testing.expectEqual(@as(u64, 5), (@as(u64, 1) << riscv.sp) | (@as(u64, 1) << riscv.pc));
    const x86 = records.perfFile(records.machine_x86_64).?;
    try std.testing.expectEqual(@as(u64, 384), (@as(u64, 1) << x86.sp) | (@as(u64, 1) << x86.pc));
}
