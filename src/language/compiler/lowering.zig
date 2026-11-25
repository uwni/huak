//! Lowering a module graph in dependency order, and each unit through declarations, signatures, precedence, bodies and publication into the build.
const std = @import("std");
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const Type = bc.Type;
const Value = bc.Value;
const Span = source.Span;
const ModuleGraph = @import("../ModuleGraph.zig");
const precedence = @import("../precedence.zig");
const Diagnostic = source.Diagnostic;
const symbols = @import("symbols.zig");
const modules = @import("modules.zig");
const evaluation = @import("evaluation.zig");
const groups = @import("groups.zig");
const statements = @import("statements.zig");
const typst = @import("typst.zig");
const expressions = @import("expressions.zig");
const Compiler = @import("Compiler.zig");
const Context = @import("Context.zig");
const Environment = symbols.Environment;
const namedConstant = expressions.namedConstant;
const DefaultReferences = evaluation.DefaultReferences;
const definitelyReturns = statements.definitelyReturns;

pub const Build = struct {
    allocator: std.mem.Allocator,
    syntax_allocator: std.mem.Allocator,
    graph: *const ModuleGraph,
    functions: std.array_list.Managed(bc.Function),
    constants: std.array_list.Managed(Value),
    records: std.array_list.Managed(bc.Record),
    argument_bindings: std.array_list.Managed(bc.ArgumentBinding),
    argument_names: std.ArrayList([]const ?[]const u8) = .empty,
    parameters: std.array_list.Managed(bc.Parameter),
    names: std.array_list.Managed([]const u8),
    types: std.array_list.Managed(Type),
    readonly: std.array_list.Managed(bool),
    modules: []bc.Module,
    environments: []*Environment,
    outputs: []const bc.Output = &.{},
    precedence: precedence.Table,
};

fn compileUnit(build: *Build, unit: *ModuleGraph.Unit, module_index: u32, diagnostic: *?Diagnostic) !void {
    const memory = build.allocator;
    var compiler = try Compiler.init(memory, diagnostic, unit, module_index, build);
    try compiler.declarations.append(null);
    try symbols.declareRecords(&compiler);
    try modules.collectImportedSymbols(&compiler);
    for (unit.script.statements) |statement| if (statement.value == .function) {
        const function = statement.value.function;
        if (unit.resolver().namespace(0, function.name) != null) return compiler.fail(statement.span, "function '{s}' conflicts with an import namespace", .{function.name});
        if (unit.resolver().callable(0, function.name).member != null) return compiler.fail(statement.span, "function '{s}' conflicts with an imported binding", .{function.name});
        if (compiler.environment.functions.contains(function.name) or compiler.environment.records.contains(function.name) or namedConstant(function.name) != null) return compiler.fail(statement.span, "duplicate function '{s}'", .{function.name});
        const index = try compiler.narrow(compiler.declarations.items.len + compiler.function_base, statement.span);
        try compiler.environment.functions.put(memory, function.name, index);
        try compiler.declarations.append(statement);
    };
    // Resolve every signature before compiling bodies, including forward calls.
    // Local and imported calls then share the same bytecode function metadata.
    try compiler.output.append(.{ .name = "<script>", .code = &.{}, .parameters = &.{}, .result = .unit, .local_types = &.{}, .module = module_index });
    for (compiler.declarations.items[1..]) |declaration| {
        const statement = declaration.?;
        const function = statement.value.function;
        const parameters = try memory.alloc(Type, function.params.len);
        const parameter_names = try memory.alloc([]const u8, function.params.len);
        var defaults: []?Value = &.{};
        for (function.params) |parameter| if (parameter.default != null) {
            defaults = try memory.alloc(?Value, function.params.len);
            @memset(defaults, null);
            break;
        };
        var variadic: ?Type = null;
        for (function.params, parameters, parameter_names, 0..) |parameter, *kind, *parameter_name, parameter_index| {
            parameter_name.* = parameter.name;
            const declared = try compiler.typeOf(parameter.annotation);
            kind.* = if (parameter.variadic) .list else declared;
            if (parameter.variadic) variadic = declared;
            if (parameter.default) |expression| {
                var references: DefaultReferences = .{ .compiler = &compiler, .parameters = function.params };
                try ast.walk(&references, .{ .expression = expression });
                if (!references.dynamic) {
                    const value = try evaluation.constantValue(&compiler, expression, function.params);
                    try compiler.require(declared, value.valueType(), expression.span);
                    defaults[parameter_index] = value;
                }
            }
        }
        try compiler.output.append(.{ .name = function.name, .code = &.{}, .parameters = parameters, .parameter_names = parameter_names, .defaults = defaults, .variadic = variadic, .result = if (function.result) |annotation| try compiler.typeOf(annotation) else .unit, .local_types = &.{}, .span = statement.span, .module = module_index });
    }
    try symbols.declareExpressionDefaults(&compiler);
    try groups.collectPrecedence(&compiler);
    try symbols.collectGlobals(&compiler, unit.script.statements);
    var entry = Context.init(&compiler, true, .unit);
    if (unit.data) |data| {
        const span: Span = .{ .start = 0, .end = unit.source_text.len };
        const name = ModuleGraph.Unit.data_export;
        try symbols.declareGlobal(&compiler, name, data.valueType(), false, false, span);
        try entry.constant(data, span);
        _ = try entry.emit(.store_global, compiler.environment.globals.get(name).?.index, 0, span);
        try modules.exportName(&compiler, name, span, span, .value);
    }
    try symbols.collectLocals(&compiler, &entry, unit.script.statements);
    try statements.compileStatements(&compiler, &entry, unit.script.statements);
    try typst.checkTypstReads(&compiler, &entry);
    const finish = Span{ .start = unit.source_text.len, .end = unit.source_text.len };
    if (module_index == 0) {
        _ = try entry.emit(.halt, 0, 0, finish);
    } else {
        try entry.constant(.unit, finish);
        _ = try entry.emit(.return_value, 0, 0, finish);
    }
    compiler.output.items[0].code = try entry.code.toOwnedSlice();
    compiler.output.items[0].local_types = try entry.local_types.toOwnedSlice();
    for (compiler.declarations.items[1..], 1..) |declaration, index| {
        const statement = declaration.?;
        const function = statement.value.function;
        const result = compiler.output.items[index].result;
        var context = Context.init(&compiler, false, result);
        for (function.params, compiler.output.items[index].parameters) |parameter, kind| {
            try symbols.declareLocal(&compiler, &context, parameter.name, kind, false, parameter.span);
        }
        try symbols.collectLocals(&compiler, &context, function.body);
        try statements.compileStatements(&compiler, &context, function.body);
        try typst.checkTypstReads(&compiler, &context);
        if (result != .unit and !definitelyReturns(function.body)) return compiler.fail(statement.span, "function '{s}' may finish without returning {s}", .{ function.name, compiler.typeName(result) });
        try context.constant(.unit, statement.span);
        _ = try context.emit(.return_value, 0, 0, statement.span);
        compiler.output.items[index].code = try context.code.toOwnedSlice();
        compiler.output.items[index].local_types = try context.local_types.toOwnedSlice();
    }
    for (compiler.expression_defaults.items) |default| {
        var context = Context.init(&compiler, false, default.kind);
        var declarations: symbols.Declarations = .{ .compiler = &compiler, .context = &context };
        try ast.walk(&declarations, .{ .expression = default.expression });
        const actual = try expressions.compileExpression(&compiler, &context, default.expression);
        try compiler.require(default.kind, actual, default.expression.span);
        try typst.checkTypstReads(&compiler, &context);
        _ = try context.emit(.return_value, 0, 0, default.span);
        const index = default.function - compiler.function_base;
        compiler.output.items[index].code = try context.code.toOwnedSlice();
        compiler.output.items[index].local_types = try context.local_types.toOwnedSlice();
    }

    for (compiler.global_names.items) |local_name| {
        try build.names.append(if (module_index == 0) local_name else try std.fmt.allocPrint(memory, "{s}::{s}", .{ unit.name, local_name }));
    }
    try build.types.appendSlice(compiler.global_types.items);
    try build.readonly.appendSlice(compiler.readonly_globals.items);
    try build.functions.appendSlice(compiler.output.items);
    try build.constants.appendSlice(compiler.constants.items);
    try build.parameters.appendSlice(compiler.parameters.items);
    if (module_index == 0) {
        var outputs: std.ArrayList(bc.Output) = .empty;
        for (unit.headers.scopes[0].ordinary_names) |name| {
            const symbol = compiler.environment.globals.get(name.name) orelse continue;
            var duplicate = false;
            for (outputs.items) |output| if (std.mem.eql(u8, output.name, name.name)) {
                duplicate = true;
                break;
            };
            if (!duplicate) try outputs.append(memory, .{ .name = name.name, .global = symbol.index, .span = name.span });
        }
        var imported = unit.scopes[0].iterator();
        while (imported.next()) |symbol| {
            if (compiler.environment.globals.contains(symbol.key_ptr.*)) continue;
            const value = symbol.value_ptr.*.value orelse continue;
            if (value != .member) continue;
            const exposed = modules.memberExport(&compiler, value.member);
            if (exposed.target != .global) continue;
            const position = symbol.value_ptr.*.value_since;
            try outputs.append(memory, .{ .name = symbol.key_ptr.*, .global = exposed.target.global, .span = .{ .start = position, .end = position } });
        }
        std.mem.sort(bc.Output, outputs.items, {}, struct {
            fn lessThan(_: void, a: bc.Output, b: bc.Output) bool {
                return if (a.span.start != b.span.start) a.span.start < b.span.start else std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);
        if (compiler.default_output) |output| try outputs.append(memory, output);
        build.outputs = try outputs.toOwnedSlice(memory);
    }
    build.modules[module_index] = .{ .name = unit.name, .source_text = unit.source_text, .entry = compiler.function_base, .exports = try compiler.exports.toOwnedSlice() };
}

pub fn lowerGraph(graph: *const ModuleGraph, memory: std.mem.Allocator, syntax: std.mem.Allocator) !Build {
    const count = graph.units.items.len;
    var build: Build = .{ .allocator = memory, .syntax_allocator = syntax, .graph = graph, .functions = .init(memory), .constants = .init(memory), .records = .init(memory), .argument_bindings = .init(memory), .parameters = .init(memory), .names = .init(memory), .types = .init(memory), .readonly = .init(memory), .modules = try memory.alloc(bc.Module, count), .environments = try syntax.alloc(*Environment, count), .precedence = try precedence.Table.init(syntax) };
    for (graph.order.items) |index| try compileUnit(&build, graph.units.items[index], index, graph.diagnostic);
    return build;
}
