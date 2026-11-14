//! Human-readable inspection of the instructions actually executed by the VM.
const std = @import("std");
const bc = @import("huak").language.bytecode;

pub fn write(program: *const bc.Program, writer: *std.Io.Writer) !void {
    try writer.print("program {s}\n", .{program.name});
    for (program.parameters) |parameter| {
        try writer.print("param {s}: {s} (global {d}){s}\n", .{ parameter.name, typeName(program, parameter.kind), parameter.global, if (parameter.default != null) " = default" else " required" });
    }
    for (program.records, 0..) |record, index| {
        try writer.print("struct {d} {s}\n", .{ index, record.name });
        for (record.fields) |field| try writer.print("  {s}: {s}{s}\n", .{ field.name, typeName(program, field.kind), if (field.default_function != null) " = default" else "" });
    }
    for (program.groups, 0..) |group, index| {
        const module_name = if (group.module < program.modules.len) program.modules[group.module].name else "builtin";
        try writer.print("precedence {d} {s} associativity {s} [{s}]\n", .{ index, group.name, @tagName(group.associativity), module_name });
    }
    for (program.outputs) |output| try writer.print("output {s} (global {d})\n", .{ output.name, output.global });
    for (program.exports) |exported| {
        switch (exported.target) {
            .global => |index| try writer.print("export {s} (global {d})\n", .{ exported.name, index }),
            .function => |index| try writer.print("export {s} (function {d})\n", .{ exported.name, index }),
            .block => |index| try writer.print("export {s} (block in {s})\n", .{ exported.name, program.modules[index].name }),
            .builtin => |id| try writer.print("export {s} (builtin {s})\n", .{ exported.name, @tagName(id) }),
            .precedence => |index| try writer.print("export {s} (precedence {d})\n", .{ exported.name, index }),
            .record => |index| try writer.print("export {s} (struct {d})\n", .{ exported.name, index }),
            .namespace => |index| try writer.print("export {s} (namespace {s})\n", .{ exported.name, program.modules[index].name }),
        }
        for (exported.mixfix, 0..) |optional, index| if (optional) |form| {
            try writer.print("  mixfix({s}) {s}{s}", .{ exported.name, if (index != 0) "_ " else "", form.head });
            for (form.parts) |part| try writer.print(" {s}", .{part orelse "_"});
            try writer.print(" in precedence {d}\n", .{form.group});
        };
    }
    for (program.functions, 0..) |function, index| {
        const module_name = if (function.module < program.modules.len) program.modules[function.module].name else program.name;
        try writer.print("\nfn {d} {s} -> {s} [{s}]\n", .{ index, function.name, typeName(program, function.result), module_name });
        for (function.code, 0..) |instruction, address| {
            const source_module = if (instruction.module == std.math.maxInt(u32)) function.module else instruction.module;
            const origin = if (source_module < program.modules.len) program.modules[source_module].source_text else program.source_text;
            const diagnostic: bc.source.Diagnostic = .{ .span = instruction.span };
            const position = diagnostic.position(origin);
            // A Typst operand counts its captured pairs and tells whether the
            // code uses `huak` as a whole value.
            const captures: ?bc.TypstCaptures = if (instruction.op == .typst or instruction.op == .typst_module) instruction.typstCaptures() else null;
            const operand = if (captures) |typst| typst.pairs else instruction.b;
            const whole = if (captures) |typst| typst.whole else false;
            try writer.print("  {d:0>5} {s: <20} {d} {d}{s}  ; {d}:{d}\n", .{ address, @tagName(instruction.op), instruction.a, operand, if (whole) " huak" else "", position.line, position.column });
        }
    }
}

fn typeName(program: *const bc.Program, kind: bc.Type) []const u8 {
    if (kind.recordIndex()) |index| if (index < program.records.len) return program.records[index].name;
    return kind.name();
}
