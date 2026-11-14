//! Name/type resolution and lowering to a compact, linear instruction stream.
const std = @import("std");
const ast = @import("ast.zig");
const Parser = @import("Parser.zig");
const source = @import("source.zig");
const bc = @import("bytecode.zig");
const builtin = @import("builtin.zig");
const Type = bc.Type;
const Value = bc.Value;
const Span = source.Span;
const ModuleGraph = @import("ModuleGraph.zig");
const optimizer = @import("optimizer.zig");
const precedence = @import("precedence.zig");
const units = @import("../drawing/units.zig");
const numeric = @import("numeric.zig");
const task_plan = @import("tasks/plan.zig");
pub const ResolvedSource = ModuleGraph.ResolvedSource;
pub const ImportResolver = ModuleGraph.ImportResolver;
pub const SourceParser = Parser.SourceParser;
pub const CompileOptions = struct {
    source_parser: anyerror!?SourceParser = null,
    import_resolver: ?ImportResolver = null,
    optimize: bool = true,
};
const Build = struct {
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
pub const Diagnostic = source.Diagnostic;

const Symbol = struct { index: u32, kind: Type, readonly: bool = false, inferable: bool = false, available_after: usize = 0 };
const Names = std.StringHashMapUnmanaged(Symbol);
const Binding = struct { symbol: Symbol, local: bool, declaration: usize = 0, module: ?u32 = null, initializer: ?u32 = null };
/// A Huak value read by Typst code or a `typ.show` path, resolved where the
/// read compiles, which may be inside a template expansion. Its environment
/// is the reading module.
const TypstRead = struct { binding: Binding, environment: *Environment, name: []const u8, span: Span, show: bool };
const unreadable_typst_value = "Typst code reads huak.{s}, which names no readable Huak value here";
const unsupported_typst_value = "Typst code can read numeric, bool, string, length, color, and typ.module values from huak; huak.{s} has type {s}";
const unreadable_show = "typ.show needs a readable typ.module value, found '{s}'";
const unsupported_show = "typ.show needs a typ.module value; '{s}' has type {s}";
const CallableTarget = struct { target: CallTarget, module: ?u32 = null, initializer: ?u32 = null };
const CallTarget = @FieldType(bc.Export, "target");
const ExpressionDefault = struct { expression: *ast.Expr, function: u32, kind: Type, span: Span };
const CallParameters = struct {
    names: []const []const u8,
    kinds: []const Type,
    defaults: []const ?Value = &.{},
    default_functions: []const ?u32 = &.{},
    minimum: usize,
    variadic: ?Type = null,
    native_defaults: bool = false,
};
const Loop = struct {
    breaks: std.array_list.Managed(u32),
    continues: std.array_list.Managed(u32),
    stack_depth: usize,
};
/// Compile-time return destination; block expressions use ordinary local slots
/// and branches, without allocating a runtime scope or call frame.
const ReturnBlock = struct {
    slot: u32,
    kind: ?Type = null,
    stack_depth: usize,
    exits: std.ArrayList(u32) = .empty,
};
const Expansion = struct {
    parent: ?*Expansion,
    definition: *ModuleGraph.Unit,
    definition_body: Span,
    definition_locals: std.AutoHashMapUnmanaged(usize, Symbol),
    insertion_position: usize,
    environment: *Environment,
    scope: Parser.ScopeId,
    locals: std.AutoHashMapUnmanaged(usize, Symbol),
    body: []const *ast.Stmt,
    insertion_parent: ?*Expansion,
    inserted: bool = false,
};
const Context = struct {
    compiler: *Compiler,
    code: std.array_list.Managed(bc.Instruction),
    locals: std.AutoHashMapUnmanaged(usize, Symbol) = .{},
    local_types: std.array_list.Managed(Type),
    loops: std.array_list.Managed(*Loop),
    entry: bool,
    result: Type,
    block_depth: usize = 0,
    stack_depth: usize = 0,
    return_block: ?*ReturnBlock = null,
    expansion: ?*Expansion = null,
    insertion: ?*Expansion = null,
    /// Huak values read by Typst code in this body, checked again once its
    /// forward declarations are inferred.
    typst_reads: std.ArrayList(TypstRead) = .empty,

    fn init(compiler: *Compiler, entry: bool, result: Type) Context {
        return .{ .compiler = compiler, .code = .init(compiler.allocator), .local_types = .init(compiler.allocator), .loops = .init(compiler.allocator), .entry = entry, .result = result };
    }
    fn emit(self: *Context, op: bc.Op, a: u32, b: u32, span: Span) !u32 {
        const index = try self.compiler.narrow(self.code.items.len, span);
        const instruction: bc.Instruction = .{ .op = op, .a = a, .b = b, .span = span, .module = self.compiler.environment.module_index };
        const effect = instruction.stackEffect();
        std.debug.assert(self.stack_depth >= effect.consumed);
        self.stack_depth = self.stack_depth - effect.consumed + effect.produced;
        try self.code.append(instruction);
        return index;
    }
    fn patch(self: *Context, instruction: u32, destination: usize) !void {
        self.code.items[instruction].a = try self.compiler.narrow(destination, self.code.items[instruction].span);
    }
    fn constant(self: *Context, value: Value, span: Span) !void {
        const index = try self.compiler.addConstant(value, span);
        _ = try self.emit(.constant, index, 0, span);
    }
    fn resolve(self: *Context, name: []const u8, span: Span) ?Binding {
        const compiler = self.compiler;
        const unit = compiler.environment.unit;
        const readable_ = unit.resolverAt(span.start).readable(unit.scopeAt(span.start), name);
        // The inserted statements share the template's block. Their direct
        // declarations are also visible to its postlude, by declaration identity.
        var active = self.expansion;
        while (active) |scope| : (active = scope.parent) {
            if (scope.definition != unit or span.start < scope.definition_body.start or span.start >= scope.definition_body.end) continue;
            if (readable_) |readable| if (readable == .ordinary and readable.ordinary.scope != 0) break;
            for (scope.environment.unit.headers.scopes[scope.scope].ordinary_names) |declared| {
                if (!std.mem.eql(u8, name, declared.name)) continue;
                var symbol = scope.locals.get(declared.span.start) orelse continue;
                symbol.kind = self.local_types.items[symbol.index];
                symbol.inferable = false;
                symbol.available_after = if (scope.inserted) 0 else std.math.maxInt(usize);
                return .{ .symbol = symbol, .local = true };
            }
        }
        if (readable_) |readable| switch (readable) {
            .ordinary => |ordinary| {
                if (ordinary.module) |module| {
                    var expansion = self.expansion;
                    while (expansion) |scope| : (expansion = scope.parent) {
                        if (scope.definition.index != module) continue;
                        if (scope.definition_locals.get(ordinary.span.start)) |declared| {
                            var symbol = declared;
                            symbol.kind = self.local_types.items[symbol.index];
                            symbol.inferable = false;
                            symbol.available_after = if (declared.available_after <= scope.insertion_position) 0 else std.math.maxInt(usize);
                            return .{ .symbol = symbol, .local = true };
                        }
                    }
                    return null;
                }
                if (ordinary.scope == 0) {
                    if (compiler.environment.globals.get(name)) |symbol| return .{ .symbol = symbol, .local = false };
                } else if (self.locals.get(ordinary.span.start)) |symbol| {
                    return .{ .symbol = symbol, .local = true, .declaration = ordinary.span.start };
                }
            },
            .imported => |target| {
                if (target == .namespace) return null;
                const exposed = compiler.memberExport(target.member);
                const index = exposed.target.global;
                return .{ .symbol = .{ .index = index, .kind = compiler.build.types.items[index], .readonly = true }, .local = false, .module = target.member.module, .initializer = target.member.initializer };
            },
        };
        return null;
    }
    fn temporary(self: *Context, kind: Type, span: Span) !u32 {
        const index = try self.compiler.narrow(self.local_types.items.len, span);
        try self.local_types.append(kind);
        return index;
    }
    fn load(self: *Context, binding: anytype, span: Span) !void {
        if (binding.local and span.start < binding.symbol.available_after)
            return self.compiler.fail(span, "local variable used before its declaration is complete", .{});
        if (binding.module) |module| try self.checkImport(module, binding.initializer, span);
        _ = try self.emit(if (binding.local) .load_local else .load_global, binding.symbol.index, 0, span);
    }
    fn checkImport(self: *Context, module: u32, initializer: ?u32, span: Span) !void {
        if (initializer) |owner| if (owner != module) {
            _ = try self.emit(.check_module, owner, 0, span);
        };
        _ = try self.emit(.check_module, module, 0, span);
    }
    fn store(self: *Context, binding: anytype, span: Span) !void {
        _ = try self.emit(if (binding.local) .store_local else .store_global, binding.symbol.index, 0, span);
    }
};

const Environment = struct {
    globals: Names = .{},
    functions: std.StringHashMapUnmanaged(u32) = .{},
    records: std.StringHashMapUnmanaged(u32) = .{},
    group_names: std.StringHashMapUnmanaged(u32) = .{},
    unit: *ModuleGraph.Unit,
    module_index: u32,
};

const Compiler = struct {
    environment: *Environment,
    allocator: std.mem.Allocator,
    diagnostic: *?Diagnostic,
    global_names: std.array_list.Managed([]const u8),
    global_types: std.array_list.Managed(Type),
    readonly_globals: std.array_list.Managed(bool),
    declarations: std.array_list.Managed(?*ast.Stmt),
    expression_defaults: std.ArrayList(ExpressionDefault) = .empty,
    output: std.array_list.Managed(bc.Function),
    constants: std.array_list.Managed(Value),
    parameters: std.array_list.Managed(bc.Parameter),
    exports: std.array_list.Managed(bc.Export),
    export_names: std.StringHashMapUnmanaged(void) = .{},
    default_output: ?bc.Output = null,
    expression_depth: usize = 0,
    build: *Build,
    global_base: u32,
    function_base: u32,
    constant_base: u32,

    fn init(allocator: std.mem.Allocator, diagnostic: *?Diagnostic, unit: *ModuleGraph.Unit, module_index: u32, build: *Build) !Compiler {
        const environment = try build.syntax_allocator.create(Environment);
        environment.* = .{ .unit = unit, .module_index = module_index };
        build.environments[module_index] = environment;
        return .{ .environment = environment, .allocator = allocator, .diagnostic = diagnostic, .global_names = .init(allocator), .global_types = .init(allocator), .readonly_globals = .init(allocator), .declarations = .init(build.syntax_allocator), .output = .init(allocator), .constants = .init(allocator), .parameters = .init(allocator), .exports = .init(allocator), .build = build, .global_base = @intCast(build.names.items.len), .function_base = @intCast(build.functions.items.len), .constant_base = @intCast(build.constants.items.len) };
    }

    fn fail(self: *Compiler, span: Span, comptime format: []const u8, args: anytype) error{LanguageError} {
        const detail = Diagnostic.set(self.diagnostic, span, format, args);
        detail.setSource(self.environment.unit.name, self.environment.unit.source_text);
        return error.LanguageError;
    }
    fn narrow(self: *Compiler, value: usize, span: Span) !u32 {
        return std.math.cast(u32, value) orelse self.fail(span, "program exceeds bytecode index capacity", .{});
    }
    fn typeOf(self: *Compiler, annotation: ast.Annotation) !Type {
        if (Type.parse(annotation.name)) |kind| return kind;
        if (std.mem.lastIndexOfScalar(u8, annotation.name, '.')) |dot| {
            const owner = self.imported(annotation.name[0..dot], annotation.span) orelse return self.fail(annotation.span, "unknown type namespace '{s}'", .{annotation.name[0..dot]});
            const exposed = try self.importedExport(owner, annotation.name[dot + 1 ..], annotation.span);
            if (exposed.target == .record) return Type.record(exposed.target.record);
        } else if (self.environment.unit.resolverAt(annotation.span.start).typeSymbol(self.environment.unit.scopeAt(annotation.span.start), annotation.name)) |member| {
            if (member.module == self.environment.module_index) {
                if (self.environment.records.get(member.name)) |index| return Type.record(index);
            } else {
                const exposed = self.memberExport(member);
                if (exposed.target == .record) return Type.record(exposed.target.record);
            }
        }
        return self.fail(annotation.span, "unknown type '{s}'", .{annotation.name});
    }
    fn typeName(self: *const Compiler, kind: Type) []const u8 {
        if (kind.recordIndex()) |index| if (index < self.build.records.items.len) return self.build.records.items[index].name;
        return kind.name();
    }
    fn parameterType(self: *Compiler, parameter: @FieldType(@FieldType(ast.Stmt, "value"), "parameter")) !Type {
        if (parameter.annotation) |annotation| return self.typeOf(annotation);
        return (try self.constantValue(parameter.default.?, null)).valueType();
    }
    fn require(self: *Compiler, expected: Type, actual: Type, span: Span) !void {
        // An object handle may refer to a picture. The VM checks its concrete
        // kind when assigning the typed slot or entering the function.
        if (expected == .picture and actual == .object) return;
        if (!Type.accepts(expected, actual)) return self.fail(span, "expected {s}, found {s}", .{ self.typeName(expected), self.typeName(actual) });
    }
    fn addConstant(self: *Compiler, value: Value, span: Span) !u32 {
        const index = try self.narrow(self.constants.items.len + self.constant_base, span);
        try self.constants.append(value);
        return index;
    }
    fn declareGlobal(self: *Compiler, name: []const u8, kind: Type, readonly: bool, inferable: bool, span: Span) !void {
        if (self.environment.globals.contains(name)) return self.fail(span, "duplicate declaration '{s}'", .{name});
        const index = try self.narrow(self.global_names.items.len + self.global_base, span);
        try self.environment.globals.put(self.allocator, name, .{ .index = index, .kind = kind, .readonly = readonly, .inferable = inferable });
        try self.global_names.append(name);
        try self.global_types.append(kind);
        try self.readonly_globals.append(readonly);
    }
    fn collectGlobals(self: *Compiler, statements: []const *ast.Stmt) !void {
        var visitor: Declarations = .{ .compiler = self };
        try ast.walkStatements(&visitor, statements);
    }
    fn collectLocals(self: *Compiler, context: *Context, statements: []const *ast.Stmt) !void {
        var visitor: Declarations = .{ .compiler = self, .context = context };
        try ast.walkStatements(&visitor, statements);
    }
    const Declarations = struct {
        compiler: *Compiler,
        context: ?*Context = null,

        fn declare(self: *Declarations, name: []const u8, kind: Type, readonly: bool, inferable: bool, span: Span) !void {
            const global = self.compiler.environment.unit.scopeAt(span.start) == 0;
            if (self.context) |context| {
                if (context.entry and global) return;
                try self.compiler.declareLocal(context, name, kind, inferable, span);
            } else if (global) try self.compiler.declareGlobal(name, kind, readonly, inferable, span);
        }
        pub fn enter(self: *Declarations, node: ast.Node) !bool {
            if (node != .statement) return true;
            const statement = node.statement;
            switch (statement.value) {
                .function, .structure, .expand_block => return false,
                .assignment => |value| if (value.declaration) {
                    try self.declare(value.name, if (value.annotation) |annotation| try self.compiler.typeOf(annotation) else .any, false, value.annotation == null, statement.span);
                },
                .parameter => |value| if (self.context == null) {
                    try self.declare(value.name, try self.compiler.parameterType(value), true, false, statement.span);
                },
                .exported => |value| if (value.value != null) {
                    try self.declare(value.names[0].name, .any, false, true, statement.span);
                },
                .for_loop => |value| if (self.context) |context| {
                    try self.compiler.declareLocal(context, value.name, .any, true, value.name_span);
                },
                else => {},
            }
            return true;
        }
    };
    fn declareLocal(self: *Compiler, context: *Context, name: []const u8, kind: Type, inferable: bool, span: Span) !void {
        if (context.locals.contains(span.start)) return self.fail(span, "duplicate declaration '{s}'", .{name});
        const index = try context.temporary(kind, span);
        try context.locals.put(self.allocator, span.start, .{ .index = index, .kind = kind, .inferable = inferable, .available_after = span.end });
    }

    fn declareRecords(self: *Compiler) !void {
        for (self.environment.unit.script.statements) |statement| {
            if (statement.value != .structure) continue;
            const structure = statement.value.structure;
            if (self.environment.records.contains(structure.name) or Type.parse(structure.name) != null)
                return self.fail(statement.span, "duplicate or builtin type '{s}'", .{structure.name});
            const index = try self.narrow(self.build.records.items.len, statement.span);
            try self.environment.records.put(self.allocator, structure.name, index);
            try self.build.records.append(.{ .name = structure.name, .module = self.environment.module_index, .fields = &.{} });
        }
        for (self.environment.unit.script.statements) |statement| {
            if (statement.value != .structure) continue;
            const structure = statement.value.structure;
            const fields = try self.allocator.alloc(bc.RecordField, structure.fields.len);
            for (structure.fields, fields, 0..) |field, *destination, index| {
                for (structure.fields[0..index]) |previous| if (std.mem.eql(u8, previous.name, field.name))
                    return self.fail(field.span, "duplicate field '{s}'", .{field.name});
                destination.* = .{ .name = field.name, .kind = try self.typeOf(field.annotation), .span = field.span };
            }
            self.build.records.items[self.environment.records.get(structure.name).?].fields = fields;
        }
    }

    fn declareExpressionDefaults(self: *Compiler) !void {
        for (self.environment.unit.script.statements) |statement| {
            if (statement.value != .structure) continue;
            const structure = statement.value.structure;
            const record_index = self.environment.records.get(structure.name).?;
            for (structure.fields, 0..) |field, index| {
                const expression = field.default orelse continue;
                const function = try self.narrow(self.output.items.len + self.function_base, field.span);
                const kind = self.build.records.items[record_index].fields[index].kind;
                @constCast(self.build.records.items[record_index].fields)[index].default_function = function;
                try self.output.append(.{
                    .module = self.environment.module_index,
                    .name = try std.fmt.allocPrint(self.allocator, "<{s}.{s} default>", .{ structure.name, field.name }),
                    .code = &.{},
                    .parameters = &.{},
                    .result = kind,
                    .local_types = &.{},
                    .span = field.span,
                });
                try self.expression_defaults.append(self.allocator, .{ .expression = expression, .function = function, .kind = kind, .span = field.span });
            }
        }
        // Function defaults use the same expression functions as struct fields.
        // Literal defaults remain immutable Program values and need no call.
        for (self.declarations.items[1..], 1..) |declaration, function_index| {
            const function = declaration.?.value.function;
            for (function.params, 0..) |param, parameter_index| {
                const expression = param.default orelse continue;
                if (self.output.items[function_index].defaults[parameter_index] != null) continue;
                if (self.output.items[function_index].default_functions.len == 0) {
                    const slots = try self.allocator.alloc(?u32, function.params.len);
                    @memset(slots, null);
                    self.output.items[function_index].default_functions = slots;
                }
                const index: u32 = @intCast(self.output.items.len + self.function_base);
                const kind = self.output.items[function_index].parameters[parameter_index];
                @constCast(self.output.items[function_index].default_functions)[parameter_index] = index;
                try self.output.append(.{ .module = self.environment.module_index, .name = try std.fmt.allocPrint(self.allocator, "<{s}.{s} default>", .{ function.name, param.name }), .code = &.{}, .parameters = &.{}, .result = kind, .local_types = &.{}, .span = param.span });
                try self.expression_defaults.append(self.allocator, .{ .expression = expression, .function = index, .kind = kind, .span = param.span });
            }
        }
    }

    fn recordField(self: *Compiler, kind: Type, name: []const u8, span: Span) !?usize {
        const record_index = kind.recordIndex() orelse return null;
        if (record_index >= self.build.records.items.len) return self.fail(span, "invalid struct type", .{});
        const record = self.build.records.items[record_index];
        for (record.fields, 0..) |field, index| if (std.mem.eql(u8, field.name, name)) return index;
        return self.fail(span, "type {s} has no field '{s}'", .{ record.name, name });
    }

    fn imported(self: *const Compiler, alias: []const u8, span: Span) ?u32 {
        return self.build.graph.resolveNamespaceAt(self.environment.unit, self.environment.unit.scopeAt(span.start), alias, span.start);
    }
    fn moduleExpression(self: *const Compiler, expression: *ast.Expr) ?u32 {
        const inner = ungroup(expression);
        return switch (inner.value) {
            .name => |name| self.imported(name, inner.span),
            .member => |member| if (self.moduleExpression(member.object)) |owner|
                self.build.graph.exportedNamespace(owner, member.name)
            else
                null,
            else => null,
        };
    }
    fn moduleInitializer(self: *const Compiler, expression: *ast.Expr) ?u32 {
        const inner = ungroup(expression);
        return switch (inner.value) {
            .name => |name| self.environment.unit.resolverAt(inner.span.start).namespaceInitializer(self.environment.unit.scopeAt(inner.span.start), name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len]),
            .member => |member| self.moduleInitializer(member.object),
            else => null,
        };
    }
    fn defaultNamespace(self: *const Compiler, context: *Context, name: []const u8, span: Span) ?builtin.Namespace {
        const native = builtin.Namespace.parse(name) orelse return null;
        return if (self.environment.unit.resolverAt(span.start).readable(self.environment.unit.scopeAt(span.start), name) == null and context.resolve(name, span) == null) native else null;
    }
    fn prelude(self: *const Compiler, name: []const u8) ?builtin.Signature {
        if (self.environment.unit.native_namespace) |native| return builtin.namespaceLookup(native, name);
        return builtin.implicit(name);
    }
    fn callTarget(self: *const Compiler, name: []const u8, member_: ?*const ModuleGraph.lexical.Member) ?CallTarget {
        if (member_) |member| {
            if (member.module != self.environment.module_index) return self.memberExport(member.*).target;
            return if (self.environment.records.get(member.name)) |index| .{ .record = index } else null;
        }
        if (self.environment.functions.get(name)) |index| return .{ .function = index };
        return if (self.prelude(name)) |signature| .{ .builtin = signature.id } else null;
    }
    fn namespaceCallTarget(self: *const Compiler, owner: u32, name: []const u8) ?CallTarget {
        const native = self.build.graph.units.items[owner].native_namespace orelse return null;
        const signature = builtin.namespaceConstructor(native, name) orelse return null;
        return .{ .builtin = signature.id };
    }
    fn memberExport(self: *const Compiler, member: ModuleGraph.lexical.Member) bc.Export {
        for (self.build.modules[member.module].exports) |exposed| if (std.mem.eql(u8, member.name, exposed.name)) return exposed;
        unreachable;
    }
    fn importInitializer(self: *const Compiler, span: Span) ?u32 {
        const unit = self.environment.unit;
        for (unit.imports.items, 0..) |item, i| {
            if (item.span.start != span.start) continue;
            // Leading top-level imports have run before any subsequent block or function can execute.
            const leading = @min(i, unit.script.statements.len);
            for (unit.imports.items[0..leading], unit.script.statements[0..leading]) |prior, statement| {
                if (statement.value != .imported or statement.span.start != prior.span.start) break;
                if (prior.initializer == item.initializer) return null;
            }
            return item.initializer;
        }
        unreachable;
    }
    fn collectImportedSymbols(self: *Compiler) !void {
        for (self.environment.unit.imports.items) |item| switch (item.form) {
            .namespace => |name| {
                if (namedConstant(name) != null)
                    return self.fail(item.span, "import namespace '{s}' conflicts with a builtin", .{name});
            },
            .all => for (self.build.modules[item.target].exports) |exposed| {
                try self.checkImportedFunction(item.scope, exposed.name, exposed, item.span);
            },
            .selected => |selected| for (selected) |binding| {
                const exposed = try self.importedExport(item.target, binding.name, binding.span);
                try self.checkImportedFunction(item.scope, binding.alias, exposed, binding.span);
            },
        };
    }
    fn checkImportedFunction(self: *Compiler, id: Parser.ScopeId, name: []const u8, exposed: bc.Export, span: Span) !void {
        const callable = exposed.target == .function or exposed.target == .builtin or exposed.target == .record;
        if (callable and namedConstant(name) != null)
            return self.fail(span, "imported function '{s}' conflicts with a builtin", .{name});
        if (callable) {
            const first = self.memberExport(self.environment.unit.scopes[id].get(name).?.callable.?);
            if (!sameMixfix(first.mixfix, exposed.mixfix))
                return self.fail(span, "conflicting imported operator roles for '{s}'", .{name});
        }
    }
    fn importedExport(self: *Compiler, module_index: u32, name: []const u8, span: Span) !bc.Export {
        for (self.build.modules[module_index].exports) |item| if (std.mem.eql(u8, item.name, name)) return item;
        return self.fail(span, "module '{s}' does not export '{s}'", .{ self.build.modules[module_index].name, name });
    }
    fn groupNamed(self: *Compiler, name: ast.OperatorName) !u32 {
        const previous = self.environment;
        if (name.module) |module| self.environment = self.build.environments[module];
        defer self.environment = previous;
        if (name.namespace) |alias| {
            const owner = self.imported(alias, name.span) orelse return self.fail(name.span, "unknown module namespace '{s}'", .{alias});
            const exposed = try self.importedExport(owner, name.name, name.span);
            if (exposed.target != .precedence) return self.fail(name.span, "export '{s}' is not a precedence group", .{name.name});
            return exposed.target.precedence;
        }
        if (self.environment.unit.resolverAt(name.span.start).precedence(self.environment.unit.scopeAt(name.span.start), name.name)) |member| return self.memberExport(member).target.precedence;
        if (self.environment.group_names.get(name.name)) |id| return id;
        return precedence.builtinNamed(name.name) orelse self.fail(name.span, "unknown precedence group '{s}'", .{name.name});
    }
    pub fn operatorGroup(self: *Compiler, mixed: @FieldType(@FieldType(ast.Expr, "value"), "mixfix_call")) anyerror!u32 {
        if (mixed.qualified) |binding| return self.groupNamed(binding.form.group);
        const name = mixed.operator;
        const leading = mixed.leading;
        if (name.namespace) |alias| {
            const owner = self.imported(alias, name.span) orelse return self.fail(name.span, "unknown module namespace '{s}'", .{alias});
            const exposed = try self.importedExport(owner, name.name, name.span);
            if (exposed.target != .function and exposed.target != .builtin and exposed.target != .record) return self.fail(name.span, "export '{s}' is not a mixfix function", .{name.name});
            if (exportedGroup(exposed, leading)) |group| return group;

            return self.fail(name.span, "function '{s}' has no matching mixfix declaration", .{name.name});
        }
        const resolver_ = self.environment.unit.resolverAt(name.span.start);
        const id = self.environment.unit.scopeAt(name.span.start);
        const call = resolver_.callable(id, name.name);
        if (call.mixfix[@intFromBool(leading)]) |form| return self.groupNamed(form.group);
        if (call.member) |member| if (member.module != self.environment.module_index) {
            const exposed = self.memberExport(member.*);
            if (exportedGroup(exposed, leading)) |group| return group;

            return self.fail(name.span, "function '{s}' has no matching mixfix declaration", .{name.name});
        };
        return self.fail(name.span, "function '{s}' has no matching mixfix declaration", .{name.name});
    }
    fn collectPrecedence(self: *Compiler) !void {
        const table = &self.build.precedence;
        const scratch = self.build.syntax_allocator;
        for (self.environment.unit.script.statements) |statement| {
            if (statement.value != .precedence_group) continue;
            const group = statement.value.precedence_group;
            if (self.environment.group_names.contains(group.name)) return self.fail(statement.span, "duplicate precedence group '{s}'", .{group.name});
            if (self.environment.unit.resolverAt(statement.span.start).precedence(0, group.name) != null or self.imported(group.name, statement.span) != null)
                return self.fail(statement.span, "precedence group '{s}' conflicts with an imported name", .{group.name});
            if (precedence.builtinNamed(group.name) != null) return self.fail(statement.span, "cannot redefine builtin precedence group '{s}'", .{group.name});
            const id = table.add(group.name, self.environment.module_index, group.associativity, statement.span) catch |err| {
                if (err == error.OutOfMemory) return err;
                return self.fail(statement.span, "cannot declare precedence group '{s}': {s}", .{ group.name, @errorName(err) });
            };
            try self.environment.group_names.put(scratch, group.name, id);
        }
        if (self.environment.group_names.count() != 0) try self.linkPrecedenceRelations();
        for (self.environment.unit.headers.operators) |header| {
            const statement = header.statement;
            const binding = statement.value.mixfix_binding;
            const name = binding.target.name;
            const group = binding.form.group;
            const call = self.environment.unit.resolverAt(statement.span.start).callable(header.scope, name);
            var enclosing: ?Parser.ScopeId = header.scope;
            var expansion = false;
            while (enclosing) |id| : (enclosing = self.environment.unit.headers.scopes[id].parent) if (self.environment.unit.headers.scopes[id].kind == .expansion) {
                expansion = true;
                break;
            };
            if (binding.target.namespace == null and expansion) continue;
            if (binding.target.namespace == null and call.shadowed) {
                _ = try self.groupNamed(group);
                continue;
            }
            const target = if (binding.target.namespace != null) (try self.qualifiedTarget(binding.target)).target else self.callTarget(name, call.member);
            const arity = binding.form.arity();
            switch (target orelse return self.fail(statement.span, "mixfix binding requires a callable function '{s}'", .{name})) {
                inline .function, .builtin => |index, kind| {
                    const callee = if (kind == .function) self.callFunction(index) else builtin.signature(index);
                    if (!callee.acceptsCount(arity)) return self.fail(statement.span, "mixfix function '{s}' does not accept {d} arguments", .{ name, arity });
                },
                .record => |index| {
                    const declared = self.build.records.items[index];
                    if (arity > declared.fields.len) return self.fail(statement.span, "struct '{s}' does not accept {d} arguments", .{ name, arity });
                    for (declared.fields[arity..]) |field| if (field.default_function == null) return self.fail(statement.span, "struct '{s}' requires field '{s}'", .{ name, field.name });
                },
                else => return self.fail(statement.span, "mixfix binding requires a callable function '{s}'", .{name}),
            }
            _ = try self.groupNamed(group);
        }
    }
    fn linkPrecedenceRelations(self: *Compiler) !void {
        const table = &self.build.precedence;
        const scratch = self.build.syntax_allocator;
        // A module can insert its groups into an established order, but must
        // not change the meaning of two groups owned by another module.
        const count = table.groups.items.len;
        var before = try std.bit_set.DynamicBitSetUnmanaged.initEmpty(scratch, count * count);
        defer before.deinit(scratch);
        for (table.groups.items, 0..) |left, i| {
            if (left.module == self.environment.module_index) continue;
            for (table.groups.items[0..i], 0..) |right, j| {
                if (right.module == self.environment.module_index) continue;
                if ((try table.compare(@intCast(i), @intCast(j))) == .unrelated) before.set(i * count + j);
            }
        }
        var last_span: Span = .{ .start = 0, .end = 0 };
        for (self.environment.unit.script.statements) |statement| {
            if (statement.value != .precedence_group) continue;
            last_span = statement.span;
            const group = statement.value.precedence_group;
            const id = self.environment.group_names.get(group.name).?;
            for (group.relations) |relation| {
                const other = try self.groupNamed(relation.target);
                const higher = if (relation.direction == .above) id else other;
                const lower = if (relation.direction == .above) other else id;
                table.above(higher, lower) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    return self.fail(relation.span, "invalid precedence relation: {s}", .{@errorName(err)});
                };
            }
        }
        table.validate() catch |err| {
            if (err == error.OutOfMemory) return err;
            return self.fail(last_span, "invalid precedence graph: {s}", .{@errorName(err)});
        };
        for (table.groups.items, 0..) |left, i| {
            if (left.module == self.environment.module_index) continue;
            for (table.groups.items[0..i], 0..) |right, j| {
                if (right.module == self.environment.module_index or !before.isSet(i * count + j)) continue;
                if ((try table.compare(@intCast(i), @intCast(j))) != .unrelated)
                    return self.fail(last_span, "cannot change the precedence relationship between existing groups '{s}' and '{s}'", .{ left.name, right.name });
            }
        }
    }
    fn compileStatements(self: *Compiler, context: *Context, statements_: []const *ast.Stmt) anyerror!void {
        context.block_depth += 1;
        defer context.block_depth -= 1;
        for (statements_) |statement| try self.compileStatement(context, statement);
    }
    fn compileAssignment(self: *Compiler, context: *Context, name: []const u8, value: *ast.Expr, span: Span) !void {
        const binding = context.resolve(name, span) orelse return self.fail(span, "name '{s}' is not an assignable value", .{name});
        if (binding.local and span.start < binding.declaration)
            return self.fail(span, "local variable assigned before its declaration", .{});
        if (binding.symbol.readonly) return self.fail(span, "cannot assign readonly parameter '{s}'", .{name});
        // A module assigned to a name is named after it, like a file.
        const actual = if (value.value == .typst_module) try self.compileTypstModule(context, value.value.typst_module, value.span, name) else try self.compileExpression(context, value);
        if (binding.symbol.inferable) {
            if (binding.local) {
                context.locals.getPtr(binding.declaration).?.kind = actual;
                context.locals.getPtr(binding.declaration).?.inferable = false;
                context.local_types.items[binding.symbol.index] = actual;
            } else {
                self.environment.globals.getPtr(name).?.kind = actual;
                self.environment.globals.getPtr(name).?.inferable = false;
                self.global_types.items[binding.symbol.index - self.global_base] = actual;
            }
        } else try self.require(binding.symbol.kind, actual, value.span);
        try context.store(binding, span);
    }
    fn exportName(self: *Compiler, name: []const u8, span: Span, name_span: Span, explicit_kind: ?ModuleGraph.lexical.Kind) !void {
        if (self.export_names.contains(name)) return self.fail(name_span, "duplicate export '{s}'", .{name});
        const resolver_ = self.environment.unit.resolverAt(name_span.start);
        const call = resolver_.callable(0, name);
        const imported_value: ?bc.Export = if (resolver_.readable(0, name)) |readable| (if (readable == .imported and readable.imported == .member) self.memberExport(readable.imported.member) else null) else null;
        const imported_function: ?bc.Export = if (call.member) |member| (if (member.module != self.environment.module_index) self.memberExport(member.*) else null) else null;
        const target: @FieldType(bc.Export, "target") = if (explicit_kind == .block or (call.member != null and call.member.?.identity.kind == .block))
            .{ .block = if (call.member) |member| member.identity.module else self.environment.module_index }
        else if (explicit_kind == .function)
            .{ .function = self.environment.functions.get(name).? }
        else if (explicit_kind == .record)
            .{ .record = self.environment.records.get(name).? }
        else if (self.environment.globals.get(name)) |binding|
            .{ .global = binding.index }
        else if (imported_value) |exposed|
            exposed.target
        else if (self.imported(name, name_span)) |module_index|
            .{ .namespace = module_index }
        else if (self.environment.functions.get(name)) |function|
            .{ .function = function }
        else if (self.environment.records.get(name)) |record|
            .{ .record = record }
        else if (imported_function) |exposed|
            exposed.target
        else if (self.environment.group_names.get(name)) |group|
            .{ .precedence = group }
        else if (resolver_.precedence(0, name)) |member|
            self.memberExport(member).target
        else if (self.prelude(name)) |signature|
            .{ .builtin = signature.id }
        else
            return self.fail(name_span, "unknown exported variable or function '{s}'", .{name});
        const callable = target == .function or target == .builtin or target == .record;
        var forms: [2]?bc.MixfixForm = .{ null, null };
        if (callable) for (0..2) |index| {
            forms[index] = if (call.mixfix[index]) |form| try self.copyMixfix(form.*) else if (imported_function) |item| item.mixfix[index] else null;
        };
        try self.export_names.put(self.allocator, name, {});
        try self.exports.append(.{ .name = name, .target = target, .span = span, .mixfix = forms });
    }
    fn copyMixfix(self: *Compiler, form: ast.MixfixForm) !bc.MixfixForm {
        const group = try self.groupNamed(form.group);
        const parts = try self.allocator.dupe(?[]const u8, form.parts);
        return .{ .head = form.head, .parts = parts, .group = group };
    }
    fn qualifiedTarget(self: *Compiler, name: ast.OperatorName) !CallableTarget {
        const previous = self.environment;
        self.environment = self.build.environments[name.module.?];
        defer self.environment = previous;
        const namespace = name.namespace.?;
        const unit = self.environment.unit;
        const resolver = unit.resolverAt(name.span.start);
        const scope = unit.scopeAt(name.span.start);
        if (self.imported(namespace, name.span)) |module| {
            const exposed = try self.importedExport(module, name.name, name.span);
            const root = namespace[0 .. std.mem.indexOfScalar(u8, namespace, '.') orelse namespace.len];
            return .{ .target = exposed.target, .module = module, .initializer = resolver.namespaceInitializer(scope, root) };
        }
        if (resolver.readable(scope, namespace) == null) if (builtin.Namespace.parse(namespace)) |native| {
            const signature = builtin.namespaceLookup(native, name.name) orelse return self.fail(name.span, "{s} has no function '{s}'", .{ namespace, name.name });
            return .{ .target = .{ .builtin = signature.id } };
        };
        return self.fail(name.span, "unknown module namespace '{s}'", .{namespace});
    }
    fn compileResolvedCall(self: *Compiler, context: *Context, imported_symbol: CallableTarget, call: @FieldType(@FieldType(ast.Expr, "value"), "call"), skip: usize, span: Span) anyerror!Type {
        const target = imported_symbol.target;
        if (target == .global) {
            const kind = self.build.types.items[target.global];
            if (kind != .function and kind != .any) return self.fail(span, "export '{s}' is not callable", .{call.name});
            if (imported_symbol.module) |module| try context.checkImport(module, imported_symbol.initializer, span);
            _ = try context.emit(.load_global, target.global, 0, span);
            return self.dynamicCall(context, call, skip, span);
        }
        if (target != .function and target != .builtin and target != .record) return self.fail(span, "export '{s}' is not a function or struct", .{call.name});
        if (imported_symbol.module) |module| try context.checkImport(module, imported_symbol.initializer, span);
        return self.compileCall(context, target, call, skip, span);
    }
    fn callFunction(self: *const Compiler, index: u32) bc.Function {
        return if (index < self.function_base) self.build.functions.items[index] else self.output.items[index - self.function_base];
    }
    fn functionValue(self: *Compiler, context: *Context, target: CallTarget, span: Span) !Type {
        const value: @import("types.zig").Function = switch (target) {
            .function => |index| .{ .bytecode = index },
            .builtin => |id| .{ .native = @backingInt(id) },
            else => return self.fail(span, "only functions can be used as callable values", .{}),
        };
        try context.constant(.{ .function = value }, span);
        return .function;
    }
    fn dynamicCall(self: *Compiler, context: *Context, call: @FieldType(@FieldType(ast.Expr, "value"), "call"), skip: usize, span: Span) !Type {
        for (call.args[skip..]) |arg| _ = try self.compileExpression(context, arg);
        _ = try context.emit(.call_value, try self.callNames(call.argument_names, skip, span), try self.narrow(call.args.len - skip, span), span);
        return .any;
    }
    fn callNames(self: *Compiler, names: []const ?[]const u8, skip: usize, span: Span) !u32 {
        if (names.len == 0) return 0;
        try self.build.argument_names.append(self.allocator, try self.allocator.dupe(?[]const u8, names[skip..]));
        return self.narrow(self.build.argument_names.items.len, span);
    }
    fn compileCall(self: *Compiler, context: *Context, target: CallTarget, call: @FieldType(@FieldType(ast.Expr, "value"), "call"), skip: usize, span: Span) anyerror!Type {
        switch (target) {
            inline .function, .builtin => |index, kind| {
                const callee = if (kind == .function) self.callFunction(index) else builtin.signature(index);
                const fixed = if (kind == .function) callee.parameters[0..callee.fixedCount()] else callee.args;
                const minimum = if (kind == .function) callee.requiredCount() else callee.minimum;
                const names = if (kind == .function) callee.parameter_names[0..callee.fixedCount()] else callee.parameter_names;
                const args = call.args[skip..];
                const offset: usize = 0;
                const count = if (call.argument_names.len != 0)
                    try self.compileBoundArguments(context, call, skip, offset, .{ .names = names, .kinds = fixed, .defaults = if (kind == .function) callee.defaults else &.{}, .default_functions = if (kind == .function) callee.default_functions else &.{}, .minimum = minimum, .variadic = callee.variadic, .native_defaults = kind == .builtin }, span)
                else count: {
                    try self.compileArguments(context, call.name, args, offset, fixed, minimum, callee.variadic, span);
                    break :count args.len + offset;
                };
                _ = try context.emit(if (kind == .function) .call else .call_builtin, if (kind == .function) index else @backingInt(index), try self.narrow(count, span), span);
                return if (kind == .builtin) self.builtinResult(context, callee, args) else callee.result;
            },
            .record => |index| return self.compileRecordCall(context, index, call, skip, span),
            else => unreachable,
        }
    }

    fn builtinResult(self: *Compiler, context: *Context, signature: builtin.Signature, args: []const *ast.Expr) Type {
        if (signature.id == .unit or signature.id == .lerp or signature.id == .apply) {
            // Both vector parameters of lerp must have the same dimension.
            // Named calls can supply them in either order.
            for (args) |arg| if (self.expressionType(context, arg)) |kind| {
                if (kind.isVector()) return kind;
            };
        }
        switch (signature.id) {
            .rectangle, .circle, .ellipse, .arc, .bezier, .path => for (args) |arg| {
                if (self.expressionType(context, arg)) |kind| {
                    if (kind == .vec2) return .path;
                    if (kind == .vec3) return .shape;
                }
            },
            .reverse, .closed => if (args.len == 1) return self.expressionType(context, args[0]) orelse signature.result,
            .joined, .region_union, .region_intersection, .region_difference => if (args.len >= 2) {
                const left = self.expressionType(context, args[0]);
                const right = self.expressionType(context, args[1]);
                if (left == .shape or right == .shape) return .shape;
                if (left == .path and right == .path) return .path;
            },
            else => {},
        }
        return if (signature.id == .copy and args.len == 1) self.expressionType(context, args[0]) orelse signature.result else signature.result;
    }

    fn expressionType(self: *Compiler, context: *Context, expression: *ast.Expr) ?Type {
        const inner = ungroup(expression);
        if (inner.value == .name) if (context.resolve(inner.value.name, inner.span)) |binding| return binding.symbol.kind;
        if (inner.value == .dict) return .dict;
        if (inner.value == .list) return .list;
        if (inner.value == .vector) return if (inner.value.vector.z == null) .vec2 else .vec3;
        if (inner.value == .member) {
            const member = inner.value.member;
            if (ungroup(member.object).value == .name) {
                const name = ungroup(member.object).value.name;
                if (self.defaultNamespace(context, name, inner.span)) |native| if (builtin.namespaceConstant(native, member.name)) |value| return value.valueType();
            }
            if (self.moduleExpression(member.object)) |module_index| for (self.build.modules[module_index].exports) |exposed| {
                if (std.mem.eql(u8, exposed.name, member.name) and exposed.target == .global) return self.build.types.items[exposed.target.global];
            };
            const object = self.expressionType(context, member.object) orelse return null;
            if (object.recordIndex()) |index| if (index < self.build.records.items.len) {
                for (self.build.records.items[index].fields) |field| if (std.mem.eql(u8, field.name, member.name)) return field.kind;
            };
        }
        if (inner.value == .call) {
            const call = inner.value.call;
            var target: ?CallTarget = null;
            var skip: usize = 0;
            if (call.qualified) |name| {
                target = (self.qualifiedTarget(name.*) catch return null).target;
            } else if (call.dot and call.args.len != 0) {
                if (ungroup(call.args[0]).value == .name) if (self.defaultNamespace(context, ungroup(call.args[0]).value.name, inner.span)) |native| {
                    const signature = builtin.namespaceLookup(native, call.name) orelse return null;
                    return self.builtinResult(context, signature, call.args[1..]);
                };
                if (self.moduleExpression(call.args[0])) |module_index| {
                    skip = 1;
                    for (self.build.modules[module_index].exports) |exposed| {
                        if (std.mem.eql(u8, exposed.name, call.name)) target = exposed.target;
                    }
                }
            }
            if (target == null) {
                const resolved = self.environment.unit.resolverAt(inner.span.start).callable(self.environment.unit.scopeAt(inner.span.start), call.name);
                if (resolved.shadowed) return null;
                target = if (resolved.namespace) |owner| self.namespaceCallTarget(owner, call.name) else self.callTarget(call.name, resolved.member);
            }
            return switch (target orelse return null) {
                .record => |index| Type.record(index),
                .function => |index| self.callFunction(index).result,
                .builtin => |id| self.builtinResult(context, builtin.signature(id), call.args[skip..]),
                else => null,
            };
        }
        return null;
    }

    fn compileRecordCall(self: *Compiler, context: *Context, index: u32, call: @FieldType(@FieldType(ast.Expr, "value"), "call"), skip: usize, span: Span) anyerror!Type {
        const record = self.build.records.items[index];
        const names = try self.allocator.alloc([]const u8, record.fields.len);
        const kinds = try self.allocator.alloc(Type, record.fields.len);
        const defaults = try self.allocator.alloc(?u32, record.fields.len);
        for (record.fields, names, kinds, defaults) |field, *name, *kind, *default| {
            name.* = field.name;
            kind.* = field.kind;
            default.* = field.default_function;
        }
        const count = try self.compileBoundArguments(context, call, skip, 0, .{ .names = names, .kinds = kinds, .default_functions = defaults, .minimum = 0 }, span);
        _ = try context.emit(.make_record, index, try self.narrow(count, span), span);
        return Type.record(index);
    }

    /// Evaluate explicit arguments once, in source order, then materialize only
    /// the missing defaults and permute the resulting values into parameter slots.
    fn compileBoundArguments(self: *Compiler, context: *Context, call: @FieldType(@FieldType(ast.Expr, "value"), "call"), skip: usize, offset: usize, parameters: CallParameters, span: Span) anyerror!usize {
        const args = call.args[skip..];
        const labels = if (call.argument_names.len == 0) &.{} else call.argument_names[skip..];
        const used = try self.allocator.alloc(bool, parameters.kinds.len);
        @memset(used, false);
        var slots: std.ArrayList(u32) = .empty;
        for (0..offset) |index| {
            if (index >= used.len) return self.fail(span, "too many implicit arguments", .{});
            used[index] = true;
            try slots.append(self.allocator, @intCast(index));
        }
        var positional = offset;
        var highest = offset;
        for (args, 0..) |argument, source_index| {
            const label = if (labels.len == 0) null else labels[source_index];
            const destination = if (label) |wanted| named: {
                for (parameters.names, 0..) |name, index| if (std.mem.eql(u8, name, wanted)) break :named index;
                return self.fail(argument.span, "unknown argument '{s}' for '{s}'", .{ wanted, call.name });
            } else positional;
            if (label == null) positional += 1;
            if (destination < used.len) {
                if (used[destination]) return self.fail(argument.span, "argument '{s}' supplied more than once", .{parameters.names[destination]});
                used[destination] = true;
            } else if (parameters.variadic == null) return self.fail(argument.span, "too many arguments for '{s}'", .{call.name});
            const kind = if (destination < parameters.kinds.len) parameters.kinds[destination] else parameters.variadic.?;
            try self.require(kind, try self.compileExpression(context, argument), argument.span);
            try slots.append(self.allocator, try self.narrow(destination, argument.span));
            highest = @max(highest, destination + 1);
        }
        const fixed_count = if (parameters.native_defaults) @max(highest, parameters.minimum) else parameters.kinds.len;
        for (0..@min(fixed_count, used.len)) |index| {
            if (used[index]) continue;
            if (index < parameters.default_functions.len and parameters.default_functions[index] != null) {
                _ = try context.emit(.call, parameters.default_functions[index].?, 0, span);
            } else if (index < parameters.defaults.len and parameters.defaults[index] != null) {
                try context.constant(parameters.defaults[index].?, span);
            } else if (parameters.native_defaults and index >= parameters.minimum) {
                try context.constant(.omitted, span);
            } else return self.fail(span, "missing argument '{s}' for '{s}'", .{ parameters.names[index], call.name });
            try slots.append(self.allocator, @intCast(index));
        }
        var ordered = true;
        for (slots.items, 0..) |slot, index| if (slot != index) {
            ordered = false;
            break;
        };
        if (!ordered) {
            const index = try self.narrow(self.build.argument_bindings.items.len, span);
            const count = try self.narrow(slots.items.len, span);
            try self.build.argument_bindings.append(.{ .slots = try slots.toOwnedSlice(self.allocator), .parameter_count = count });
            const binding = &self.build.argument_bindings.items[index];
            _ = try context.emit(.bind_arguments, index, binding.parameter_count, span);
            return binding.parameter_count;
        }
        return slots.items.len;
    }
    fn compileArguments(self: *Compiler, context: *Context, name: []const u8, args: []const *ast.Expr, offset: usize, fixed: []const Type, minimum: usize, variadic: ?Type, span: Span) anyerror!void {
        const count = args.len + offset;
        if (count < minimum or (variadic == null and count > fixed.len)) {
            if (variadic != null) return self.fail(span, "function '{s}' expects at least {d} arguments, found {d}", .{ name, minimum, count });
            if (minimum == fixed.len) return self.fail(span, "function '{s}' expects {d} arguments, found {d}", .{ name, minimum, count });
            return self.fail(span, "function '{s}' expects {d}..{d} arguments, found {d}", .{ name, minimum, fixed.len, count });
        }
        for (args, 0..) |argument, i| {
            const kind = if (i + offset < fixed.len) fixed[i + offset] else variadic.?;
            try self.require(kind, try self.compileExpression(context, argument), argument.span);
        }
    }
    fn compileStatement(self: *Compiler, context: *Context, statement_: *ast.Stmt) anyerror!void {
        const span = statement_.span;
        switch (statement_.value) {
            .expression => |expression| {
                _ = try self.compileExpression(context, expression);
                _ = try context.emit(.pop, 0, 0, span);
            },
            .expand_block => |definition| {
                if (!context.entry or context.block_depth != 1) return self.fail(span, "expand_block declarations must be at script top level", .{});
                if (definition.exported) try self.exportName(definition.name, span, span, .block);
            },
            .insertion => try self.compileInsertion(context, span),
            .assignment => |assignment| try self.compileAssignment(context, assignment.name, assignment.value, span),
            .set => |assignment| {
                const target = ungroup(assignment.target);
                switch (target.value) {
                    .member => |member| {
                        const object = try self.compileExpression(context, member.object);
                        const field_index = try self.recordField(object, member.name, target.span);
                        if (field_index == null and object != .any) return self.fail(target.span, "type {s} has no writable field '{s}'", .{ self.typeName(object), member.name });
                        const actual = try self.compileExpression(context, assignment.value);
                        if (field_index) |index| try self.require(self.build.records.items[object.recordIndex().?].fields[index].kind, actual, assignment.value.span);
                        _ = try context.emit(.set_field, try self.addConstant(.{ .string = member.name }, target.span), if (field_index) |index| try self.narrow(index + 1, target.span) else 0, span);
                    },
                    .index => |index| {
                        const object = try self.compileExpression(context, index.object);
                        if (object != .list and object != .dict and object != .any) return self.fail(target.span, "indexed assignment requires a list or dictionary", .{});
                        const key = try self.compileExpression(context, index.index);
                        if (object == .list) try self.require(.int, key, index.index.span);
                        if (object == .dict) try self.require(.string, key, index.index.span);
                        _ = try self.compileExpression(context, assignment.value);
                        _ = try context.emit(.set_index, 0, 0, span);
                    },
                    else => return self.fail(target.span, "invalid assignment target", .{}),
                }
            },
            .list_append => |append| {
                const binding = context.resolve(append.name, span) orelse return self.fail(span, "unknown list variable '{s}'", .{append.name});
                if (binding.symbol.readonly and binding.module == null) return self.fail(span, "cannot modify readonly parameter '{s}'", .{append.name});
                try self.require(.list, binding.symbol.kind, span);
                try context.load(binding, span);
                _ = try self.compileExpression(context, append.value);
                _ = try context.emit(.list_append, 0, 0, span);
            },
            .append_to => |append| {
                try self.require(.list, try self.compileExpression(context, append.target), append.target.span);
                _ = try self.compileExpression(context, append.value);
                _ = try context.emit(.list_append, 0, 0, span);
            },
            .default_output => |value| {
                if (!context.entry or context.block_depth != 1) return self.fail(span, "default output must be at script top level", .{});
                if (self.default_output != null) return self.fail(span, "duplicate default output", .{});
                try self.require(.picture, try self.compileExpression(context, value), value.span);
                try self.declareGlobal("<default>", .picture, false, false, span);
                const slot = self.environment.globals.get("<default>").?.index;
                self.default_output = .{ .name = "default", .global = slot, .span = span };
                _ = try context.emit(.store_global, slot, 0, span);
            },
            .exported => |exported| {
                if (!context.entry or context.block_depth != 1) return self.fail(span, "export declarations must be at script top level", .{});
                if (exported.value) |value| try self.compileAssignment(context, exported.names[0].name, value, span);
                for (exported.names) |name| try self.exportName(name.name, span, name.span, null);
            },
            .parameter => |parameter| {
                if (!context.entry or context.block_depth != 1) return self.fail(span, "param declarations must be at script top level", .{});
                const binding = self.environment.globals.get(parameter.name).?;
                switch (binding.kind) {
                    .int, .number, .boolean, .string, .length, .angle => {},
                    else => return self.fail(if (parameter.annotation) |annotation| annotation.span else span, "command-line parameters support int, float, bool, string, length, and angle", .{}),
                }
                const default = if (parameter.default) |expression| try self.constantValue(expression, null) else null;
                if (default) |value| try self.require(binding.kind, value.valueType(), parameter.default.?.span);
                if (self.environment.module_index != 0 and default == null) return self.fail(span, "imported module parameter '{s}' requires a default", .{parameter.name});
                try self.parameters.append(.{ .name = parameter.name, .kind = binding.kind, .default = default, .global = binding.index, .span = span, .module = self.environment.module_index });
            },
            .imported => {
                if (self.importInitializer(span)) |module| _ = try context.emit(.import_module, module, 0, span);
            },
            .function => |function| {
                if (!context.entry or context.block_depth != 1) return self.fail(span, "functions must be declared at script top level", .{});
                if (function.exported) try self.exportName(function.name, span, span, .function);
            },
            .structure => |structure| {
                if (!context.entry or context.block_depth != 1) return self.fail(span, "struct declarations must be at script top level", .{});
                if (structure.exported) try self.exportName(structure.name, span, span, .record);
            },
            .precedence_group => {
                if (!context.entry or context.block_depth != 1) return self.fail(span, "precedence declarations must be at script top level", .{});
            },
            .mixfix_binding => |binding| {
                if (binding.target.namespace == null) if (context.resolve(binding.target.name, span)) |value| {
                    try self.require(.function, value.symbol.kind, span);
                    if (value.local and span.start < value.symbol.available_after)
                        return self.fail(span, "mixfix function used before its declaration is complete", .{});
                };
            },
            // A show path is lexical metadata, not an evaluated statement. It
            // is checked here, where template bodies still see the expansion's
            // locals, and loaded again by each typ block in its scope.
            .typst_show => |path| _ = try self.typstShowBase(context, path, span),
            .return_value => |value| {
                if (context.entry and context.return_block == null) return self.fail(span, "return is only valid inside a function or block", .{});
                const actual = if (value) |expression| try self.compileExpression(context, expression) else blk: {
                    try context.constant(.unit, span);
                    break :blk Type.unit;
                };
                if (context.return_block) |block| {
                    block.kind = if (block.kind) |previous| if (previous == actual) actual else .any else actual;
                    _ = try context.emit(.store_local, block.slot, 0, span);

                    const depth = context.stack_depth;
                    defer context.stack_depth = depth;
                    while (context.stack_depth > block.stack_depth) _ = try context.emit(.pop, 0, 0, span);
                    try block.exits.append(self.build.syntax_allocator, try context.emit(.jump, 0, 0, span));
                } else {
                    try self.require(context.result, actual, span);

                    _ = try context.emit(.return_value, 0, 0, span);
                }
            },
            .break_loop, .continue_loop => {
                if (context.loops.items.len == 0) return self.fail(span, "{s} is only valid inside a loop", .{if (statement_.value == .break_loop) "break" else "continue"});
                const loop = context.loops.items[context.loops.items.len - 1];

                // Expressions may contain blocks. Discard their unfinished
                // operands before transferring control out of the expression.
                const depth = context.stack_depth;
                defer context.stack_depth = depth;
                while (context.stack_depth > loop.stack_depth) _ = try context.emit(.pop, 0, 0, span);
                const instruction = try context.emit(.jump, 0, 0, span);
                if (statement_.value == .break_loop) try loop.breaks.append(instruction) else try loop.continues.append(instruction);
            },
            .conditional => |conditional| {
                var exits: std.array_list.Managed(u32) = .init(self.allocator);
                for (conditional.branches) |branch| {
                    try self.require(.boolean, try self.compileExpression(context, branch.condition), branch.condition.span);
                    const skip = try context.emit(.jump_if_false, 0, 0, branch.condition.span);
                    try self.compileStatements(context, branch.body);
                    try exits.append(try context.emit(.jump, 0, 0, span));
                    try context.patch(skip, context.code.items.len);
                }
                try self.compileStatements(context, conditional.otherwise);
                for (exits.items) |exit| try context.patch(exit, context.code.items.len);
            },
            .while_loop => |while_loop| {
                const loop = try self.newLoop(context);
                const head = context.code.items.len;
                try self.require(.boolean, try self.compileExpression(context, while_loop.condition), while_loop.condition.span);
                const exit = try context.emit(.jump_if_false, 0, 0, span);
                try self.compileStatements(context, while_loop.body);
                _ = try context.emit(.jump, try self.narrow(head, span), 0, span);
                try context.patch(exit, context.code.items.len);
                try self.finishLoop(context, loop, head);
            },
            .for_loop => |for_loop| try self.forLoop(context, for_loop, span),
        }
    }

    fn newLoop(self: *Compiler, context: *Context) !*Loop {
        const loop = try self.allocator.create(Loop);
        loop.* = .{ .breaks = .init(self.allocator), .continues = .init(self.allocator), .stack_depth = context.stack_depth };
        try context.loops.append(loop);
        return loop;
    }
    fn finishLoop(_: *Compiler, context: *Context, loop: *Loop, continue_target: usize) !void {
        for (loop.breaks.items) |instruction| try context.patch(instruction, context.code.items.len);
        for (loop.continues.items) |instruction| try context.patch(instruction, continue_target);
        _ = context.loops.pop();
    }

    fn forLoop(self: *Compiler, context: *Context, loop_: @FieldType(@FieldType(ast.Stmt, "value"), "for_loop"), span: Span) anyerror!void {
        const binding: Binding = .{ .symbol = context.locals.get(loop_.name_span.start).?, .local = true, .declaration = loop_.name_span.start };
        const kind: Type = switch (loop_.iterable) {
            .range => |range| range_type: {
                const first = try self.compileExpression(context, range.start);
                try self.require(.scalar, first, range.start.span);
                const stop = try self.compileExpression(context, range.stop.?);
                try self.require(.scalar, stop, range.stop.?.span);
                const step = if (range.step) |expression| try self.compileExpression(context, expression) else step_type: {
                    try context.constant(.{ .int = 1 }, span);
                    break :step_type Type.int;
                };
                try self.require(.scalar, step, span);
                _ = try self.binaryType(.less_equal, first, stop, span);
                _ = try self.binaryType(.add, first, step, span);
                break :range_type if (first == .any or stop == .any or step == .any) .any else if (first == .int and stop == .int and step == .int) .int else if (first == stop and first == step) first else if (first == .int or first == .number) .number else .scalar;
            },
            .collection => |expression| collection_type: {
                const collection = try self.compileExpression(context, expression);
                if (collection != .list and collection != .any)
                    return self.fail(expression.span, "for requires a list or numeric range, found {s}", .{self.typeName(collection)});
                break :collection_type .any;
            },
        };
        // Iteration state belongs to this activation's locals, not the user
        // variable. Rebinding that variable never changes the next element.
        const state_kind: Type = if (loop_.iterable == .range) kind else .any;
        const current_slot = try context.temporary(state_kind, span);
        const stop_slot = try context.temporary(state_kind, span);
        const step_slot = try context.temporary(state_kind, span);
        _ = try context.emit(.iterate_init, @intFromBool(loop_.iterable == .collection), 0, span);
        _ = try context.emit(.store_local, step_slot, 0, span);
        _ = try context.emit(.store_local, stop_slot, 0, span);
        _ = try context.emit(.store_local, current_slot, 0, span);
        context.locals.getPtr(binding.declaration).?.kind = kind;
        context.locals.getPtr(binding.declaration).?.inferable = false;
        context.local_types.items[binding.symbol.index] = kind;
        const loop = try self.newLoop(context);
        const head = context.code.items.len;
        _ = try context.emit(.load_local, current_slot, 0, span);
        _ = try context.emit(.load_local, stop_slot, 0, span);
        _ = try context.emit(.load_local, step_slot, 0, span);
        _ = try context.emit(.iterate_test, 0, 0, span);
        const exit = try context.emit(.jump_if_false, 0, 0, span);
        try context.store(binding, span);
        try self.compileStatements(context, loop_.body);
        const advance = context.code.items.len;
        _ = try context.emit(.load_local, current_slot, 0, span);
        _ = try context.emit(.load_local, stop_slot, 0, span);
        _ = try context.emit(.load_local, step_slot, 0, span);
        _ = try context.emit(.iterate_advance, 0, 0, span);
        const at_end = try context.emit(.jump_if_false, 0, 0, span);
        _ = try context.emit(.store_local, current_slot, 0, span);
        _ = try context.emit(.jump, try self.narrow(head, span), 0, span);
        // Both iterator exits leave a value that must be discarded.
        try context.patch(at_end, context.code.items.len);
        try context.patch(exit, context.code.items.len);
        context.stack_depth = loop.stack_depth + 1;
        _ = try context.emit(.pop, 0, 0, span);
        try self.finishLoop(context, loop, advance);
    }

    fn compileExpression(self: *Compiler, context: *Context, expression_: *ast.Expr) anyerror!Type {
        self.expression_depth += 1;
        defer self.expression_depth -= 1;
        if (self.expression_depth > 256) return self.fail(expression_.span, "expression tree exceeds compilation depth 256", .{});
        if (precedence.hasCustom(expression_)) {
            const resolved = precedence.resolve(self.build.syntax_allocator, &self.build.precedence, expression_, self, self.diagnostic) catch |err| {
                if (self.diagnostic.*) |*detail| if (detail.fileName() == null) detail.setSource(self.environment.unit.name, self.environment.unit.source_text);
                return err;
            };
            return self.compileExpression(context, resolved);
        }
        const span = expression_.span;
        switch (expression_.value) {
            .grouped => |inner| return self.compileExpression(context, inner),
            .mixfix_call, .path_join => unreachable,
            .path_literal => return self.compilePathLiteral(context, expression_),
            .cycle => return self.fail(span, "cycle is only valid at the end of a path literal", .{}),
            .integer => |value| {
                if (value > std.math.maxInt(i64)) return self.fail(span, "integer literal is outside int range", .{});
                try context.constant(.{ .int = @intCast(value) }, span);
                return .int;
            },
            .float => |value| {
                try context.constant(.{ .number = value }, span);
                return .number;
            },
            .quantity => |quantity| {
                const operand = try self.compileExpression(context, quantity.operand);
                try self.require(.scalar, operand, quantity.operand.span);
                const unit = Value{ .quantity = try units.applyUnit(1, quantity.unit) };
                try context.constant(unit, span);
                const result = try self.binaryType(.multiply, operand, unit.valueType(), span);
                _ = try context.emit(.multiply, 0, 0, span);
                return result;
            },
            .boolean => |value| {
                try context.constant(.{ .boolean = value }, span);
                return .boolean;
            },
            .string => |value| {
                try context.constant(.{ .string = try self.allocator.dupe(u8, value) }, span);
                return .string;
            },
            .name => |name| {
                if (context.resolve(name, span)) |binding| {
                    try context.load(binding, span);
                    return binding.symbol.kind;
                }
                if (self.imported(name, span) != null) return self.fail(span, "module namespace '{s}' is not a readable value", .{name});
                if (namedConstant(name)) |value| {
                    try context.constant(value, span);
                    return value.valueType();
                }
                const resolved = self.environment.unit.resolverAt(span.start).callable(self.environment.unit.scopeAt(span.start), name);
                if (!resolved.shadowed) if (self.callTarget(name, resolved.member)) |target| {
                    if (resolved.member) |member| if (member.module != self.environment.module_index) try context.checkImport(member.module, member.initializer, span);
                    return self.functionValue(context, target, span);
                };
                return self.fail(span, "unknown name '{s}'", .{name});
            },
            .list => |values| {
                for (values) |value| _ = try self.compileExpression(context, value);
                _ = try context.emit(.make_list, try self.narrow(values.len, span), 0, span);
                return .list;
            },
            .dict => |entries| {
                for (entries) |entry| {
                    try context.constant(.{ .string = try self.allocator.dupe(u8, entry.key) }, entry.span);
                    _ = try self.compileExpression(context, entry.value);
                }
                _ = try context.emit(.make_dict, try self.narrow(entries.len, span), 0, span);
                return .dict;
            },
            .vector => |v| {
                var dimension: ?units.Dimension = null;
                for ([_]?*ast.Expr{ v.x, v.y, v.z }) |coordinate| if (coordinate) |expr| {
                    const kind = try self.compileExpression(context, expr);
                    try self.require(.scalar, kind, expr.span);
                    if (scalarDimension(kind)) |d| {
                        if (d.eql(.scalar) and zeroLiteral(expr)) continue;
                        if (dimension) |prior| if (!prior.eql(d))
                            return self.fail(span, "vector coordinates have incompatible dimensions", .{});
                        dimension = d;
                    }
                };
                _ = try context.emit(if (v.z == null) .make_vec2 else .make_vec3, 0, 0, span);
                return if (v.z == null) .vec2 else .vec3;
            },
            .unary => |unary| {
                const literal = ungroup(unary.operand);
                if (unary.op == .negate and literal.value == .integer and literal.value.integer == @as(u64, 1) << 63) {
                    try context.constant(.{ .int = std.math.minInt(i64) }, span);
                    return .int;
                }
                const kind = try self.compileExpression(context, unary.operand);
                switch (unary.op) {
                    .logical_not => {
                        try self.require(.boolean, kind, span);
                        _ = try context.emit(.logical_not, 0, 0, span);
                        return .boolean;
                    },
                    .positive, .negate => {
                        if (!kind.isVector() and kind != .variable and kind != .linear) try self.require(.scalar, kind, span);
                        _ = try context.emit(if (unary.op == .negate) .negate else .positive, 0, 0, span);
                        return if (unary.op == .negate and kind == .variable) .linear else kind;
                    },
                }
            },
            .binary => |binary_| {
                const left = try self.compileExpression(context, binary_.left);
                if (binary_.op == .logical_and or binary_.op == .logical_or) {
                    try self.require(.boolean, left, binary_.left.span);
                    _ = try context.emit(.duplicate, 0, 0, span);
                    if (binary_.op == .logical_or) _ = try context.emit(.logical_not, 0, 0, span);
                    const skip = try context.emit(.jump_if_false, 0, 0, span);
                    _ = try context.emit(.pop, 0, 0, span);
                    try self.require(.boolean, try self.compileExpression(context, binary_.right), binary_.right.span);
                    try context.patch(skip, context.code.items.len);
                    return .boolean;
                }
                const right = try self.compileExpression(context, binary_.right);
                const result = try self.binaryType(binary_.op, left, right, span);
                _ = try context.emit(switch (binary_.op) {
                    .add => .add,
                    .subtract => .subtract,
                    .multiply => .multiply,
                    .divide => .divide,
                    .remainder => .remainder,
                    .power => .power,
                    .equal => .equal,
                    .not_equal => .not_equal,
                    .less => .less,
                    .less_equal => .less_equal,
                    .greater => .greater,
                    .greater_equal => .greater_equal,
                    .logical_and, .logical_or => unreachable,
                }, 0, 0, span);
                return result;
            },
            .call => |call| {
                if (call.qualified) |name| return self.compileResolvedCall(context, try self.qualifiedTarget(name.*), call, 0, span);
                if (call.dot and std.mem.eql(u8, call.name, "with")) {
                    try self.require(.function, try self.compileExpression(context, call.args[0]), call.args[0].span);
                    for (call.args[1..]) |arg| _ = try self.compileExpression(context, arg);
                    _ = try context.emit(.bind_function, try self.callNames(call.argument_names, 1, span), try self.narrow(call.args.len - 1, span), span);
                    return .function;
                }
                if (call.dot and call.args.len != 0 and ungroup(call.args[0]).value == .name) {
                    if (self.defaultNamespace(context, ungroup(call.args[0]).value.name, span)) |native| {
                        const signature = builtin.namespaceLookup(native, call.name) orelse return self.fail(span, "{s} has no function '{s}'", .{ native.name(), call.name });
                        return self.compileCall(context, .{ .builtin = signature.id }, call, 1, span);
                    }
                }
                if (call.dot and call.args.len != 0) if (self.moduleExpression(call.args[0])) |module_index| {
                    const exposed = try self.importedExport(module_index, call.name, span);
                    return self.compileResolvedCall(context, .{ .module = module_index, .initializer = self.moduleInitializer(call.args[0]), .target = exposed.target }, call, 1, span);
                };
                const scoped_call = self.environment.unit.resolverAt(span.start).callable(self.environment.unit.scopeAt(span.start), call.name);
                if (context.resolve(call.name, span)) |binding| {
                    if (binding.symbol.kind != .function and binding.symbol.kind != .any) return self.fail(span, "binding '{s}' is not callable", .{call.name});
                    try context.load(binding, span);
                    return self.dynamicCall(context, call, 0, span);
                }
                if (scoped_call.shadowed) return self.fail(span, "binding '{s}' is not callable", .{call.name});
                const target = (if (scoped_call.namespace) |owner| self.namespaceCallTarget(owner, call.name) else self.callTarget(call.name, scoped_call.member)) orelse {
                    if (scoped_call.namespace != null) return self.fail(span, "module namespace '{s}' is not callable", .{call.name});
                    if (scoped_call.member != null) return self.fail(span, "struct declarations must be at script top level", .{});
                    return self.fail(span, "unknown function '{s}'; import its module before calling it", .{call.name});
                };
                if (scoped_call.namespace) |module_index| {
                    try context.checkImport(module_index, scoped_call.namespace_initializer, span);
                } else if (scoped_call.member) |member| if (member.module != self.environment.module_index) {
                    return self.compileResolvedCall(context, .{ .module = member.module, .initializer = member.initializer, .target = target }, call, 0, span);
                };
                return self.compileCall(context, target, call, 0, span);
            },
            .index => |index| {
                const object = try self.compileExpression(context, index.object);
                if (object != .list and object != .dict and object != .any) return self.fail(index.object.span, "indexing requires a list or dictionary", .{});
                const key = try self.compileExpression(context, index.index);
                if (object == .dict) try self.require(.string, key, index.index.span) else if (object == .list) try self.require(.int, key, index.index.span);
                _ = try context.emit(.index, 0, 0, span);
                return .any;
            },
            .slice => |slice| {
                const object = try self.compileExpression(context, slice.object);
                if (object != .list and object != .any) return self.fail(slice.object.span, "slicing requires a list", .{});
                try self.require(.int, try self.compileExpression(context, slice.range.start), slice.range.start.span);
                // Keep the established for-range operand order.
                if (slice.range.stop) |stop| {
                    try self.require(.int, try self.compileExpression(context, stop), stop.span);
                } else try context.constant(.unit, span);
                if (slice.range.step) |step| {
                    try self.require(.int, try self.compileExpression(context, step), step.span);
                } else try context.constant(.{ .int = 1 }, span);
                _ = try context.emit(.slice, @intFromBool(slice.range.stop == null), 0, span);
                return .list;
            },
            .member => |member| {
                if (ungroup(member.object).value == .name) {
                    if (self.defaultNamespace(context, ungroup(member.object).value.name, span)) |native| {
                        if (builtin.namespaceConstant(native, member.name)) |value| {
                            try context.constant(value, span);
                            return value.valueType();
                        }
                        if (builtin.namespaceLookup(native, member.name)) |signature| return self.functionValue(context, .{ .builtin = signature.id }, span);
                        return self.fail(span, "{s} has no readable member '{s}'", .{ native.name(), member.name });
                    }
                }
                if (self.moduleExpression(member.object)) |module_index| {
                    const exposed = try self.importedExport(module_index, member.name, span);
                    try context.checkImport(module_index, self.moduleInitializer(member.object), span);
                    if (exposed.target != .global) return self.functionValue(context, exposed.target, span);
                    _ = try context.emit(.load_global, exposed.target.global, 0, span);
                    return self.build.types.items[exposed.target.global];
                }
                const object = try self.compileExpression(context, member.object);
                if (try self.recordField(object, member.name, span)) |index| {
                    _ = try context.emit(.field, try self.addConstant(.{ .string = member.name }, span), try self.narrow(index + 1, span), span);
                    return self.build.records.items[object.recordIndex().?].fields[index].kind;
                }
                const result: Type = if (object == .any) .any else object.fieldType(member.name) orelse
                    return self.fail(span, "{s} has no member '{s}'", .{ self.typeName(object), member.name });
                _ = try context.emit(.field, try self.addConstant(.{ .string = member.name }, span), 0, span);
                return result;
            },
            .expansion => |invocation| return self.compileExpansion(context, invocation, span),
            .block => |body| {
                var block: ReturnBlock = .{
                    .slot = try context.temporary(.any, span),
                    .stack_depth = context.stack_depth,
                };
                const previous = context.return_block;
                context.return_block = &block;
                defer context.return_block = previous;
                try self.compileStatements(context, body);
                return self.finishBlock(context, &block, !definitelyReturns(body), span);
            },
            .typst => |block| {
                var count: u32 = 0;
                try self.compileTypstReads(context, block, &count);
                try self.compileTypstShows(context, span, &count);
                const captures: bc.TypstCaptures = .{ .pairs = @intCast(count), .whole = block.whole };
                _ = try context.emit(.typst, try self.addConstant(.{ .string = block.code }, span), @bitCast(captures), span);
                return .text;
            },
            .typst_module => |block| return self.compileTypstModule(context, block, span, null),
        }
    }

    /// The typ.module's Typst name is the name it is assigned to, as a file's
    /// stem names the module it holds, or "module".
    fn compileTypstModule(self: *Compiler, context: *Context, block: ast.Typst, span: Span, name: ?[]const u8) !Type {
        try context.constant(.{ .string = try self.allocator.dupe(u8, name orelse "module") }, span);
        var count: u32 = 0;
        try self.compileTypstReads(context, block, &count);
        // The instruction spans exactly the code, which locates
        // native diagnostics within this module's source.
        const code: Span = .{ .start = span.end - block.code.len, .end = span.end };
        const captures: bc.TypstCaptures = .{ .pairs = @intCast(count), .whole = block.whole };
        _ = try context.emit(.typst_module, try self.addConstant(.{ .string = block.code }, code), @bitCast(captures), code);
        return .typst_module;
    }

    fn finishBlock(self: *Compiler, context: *Context, block: *ReturnBlock, fallthrough: bool, span: Span) !Type {
        _ = self;
        if (fallthrough) {
            block.kind = if (block.kind == null or block.kind == .unit) .unit else .any;
            try context.constant(.unit, span);
            _ = try context.emit(.store_local, block.slot, 0, span);
        }
        for (block.exits.items) |exit| try context.patch(exit, context.code.items.len);
        _ = try context.emit(.load_local, block.slot, 0, span);
        return block.kind orelse .unit;
    }

    fn compileInsertion(self: *Compiler, context: *Context, span: Span) !void {
        const insertion = context.insertion orelse return self.fail(span, "'...' requires an expand_block definition", .{});
        const owner = self.environment;
        const locals = context.locals;
        const pending = context.insertion;
        defer {
            self.environment = owner;
            context.locals = locals;
            context.insertion = pending;
        }
        self.environment = insertion.environment;
        context.locals = insertion.locals;
        context.insertion = insertion.insertion_parent;
        try self.compileStatements(context, insertion.body);
        insertion.inserted = true;
    }

    fn compileExpansion(self: *Compiler, context: *Context, invocation: @FieldType(@FieldType(ast.Expr, "value"), "expansion"), span: Span) anyerror!Type {
        const definition = invocation.definition.value.expand_block;
        const caller = self.environment;
        const caller_locals = context.locals;
        const parent_expansion = context.expansion;
        const parent_insertion = context.insertion;
        const parent_return = context.return_block;
        defer {
            self.environment = caller;
            context.locals = caller_locals;
            context.expansion = parent_expansion;
            context.insertion = parent_insertion;
            context.return_block = parent_return;
        }
        const owner = self.build.environments[invocation.module];
        if (owner != caller) {
            const resolver = caller.unit.resolverAt(span.start);
            const scope = caller.unit.scopeAt(span.start);
            const initializer = if (invocation.name.namespace) |namespace|
                resolver.namespaceInitializer(scope, namespace[0 .. std.mem.indexOfScalar(u8, namespace, '.') orelse namespace.len])
            else if (resolver.callable(scope, invocation.name.name).member) |member|
                (if (member.initializer == std.math.maxInt(u32)) null else member.initializer)
            else
                null;
            try context.checkImport(invocation.module, initializer, span);
        }
        self.environment = owner;
        const params = definition.params;
        const variadic = params.len != 0 and params[params.len - 1].variadic;
        const fixed = params.len - @intFromBool(variadic);
        const kinds = try self.build.syntax_allocator.alloc(Type, params.len);
        const names = try self.build.syntax_allocator.alloc([]const u8, fixed);
        const defaults = try self.build.syntax_allocator.alloc(?Value, fixed);
        @memset(defaults, null);
        var minimum = fixed;
        for (params, 0..) |param, i| {
            kinds[i] = try self.typeOf(param.annotation);
            if (i < fixed) {
                names[i] = param.name;
                if (param.default) |expression| {
                    defaults[i] = try self.constantValue(expression, params);
                    try self.require(kinds[i], defaults[i].?.valueType(), expression.span);
                    minimum = @min(minimum, i);
                }
            }
        }
        self.environment = caller;
        const count = try self.compileBoundArguments(context, .{ .name = definition.name, .args = invocation.args, .argument_names = invocation.argument_names }, 0, 0, .{ .names = names, .kinds = kinds[0..fixed], .defaults = defaults, .minimum = minimum, .variadic = if (variadic) kinds[fixed] else null }, span);
        if (variadic) _ = try context.emit(.make_list, @intCast(count - fixed), 0, span);
        // Validate/store parameters in declaration order, as ordinary calls do.
        if (params.len > 1) {
            const slots = try self.allocator.alloc(u32, params.len);
            for (slots, 0..) |*slot, i| slot.* = @intCast(params.len - 1 - i);
            const index: u32 = @intCast(self.build.argument_bindings.items.len);
            try self.build.argument_bindings.append(.{ .slots = slots, .parameter_count = @intCast(params.len) });
            _ = try context.emit(.bind_arguments, index, @intCast(params.len), span);
        }
        self.environment = owner;
        context.locals = .{};
        for (params, 0..) |param, i| {
            try self.declareLocal(context, param.name, if (param.variadic) .list else kinds[i], false, param.span);
            const store = try context.emit(.store_local, context.locals.get(param.span.start).?.index, 0, span);
            context.code.items[store].module = caller.module_index;
        }
        try self.collectLocals(context, definition.body);
        var scope_id: Parser.ScopeId = 0;
        for (owner.unit.headers.expansions) |header| if (header.statement == invocation.definition) {
            scope_id = header.scope;
            break;
        };
        var expansion: Expansion = .{ .parent = parent_expansion, .definition = owner.unit, .definition_body = owner.unit.headers.scopes[scope_id].body, .definition_locals = context.locals, .insertion_position = owner.unit.headers.scopes[scope_id].insertion.?, .environment = caller, .scope = invocation.scope, .locals = caller_locals, .body = invocation.body, .insertion_parent = parent_insertion };
        context.expansion = &expansion;
        var block: ReturnBlock = .{ .slot = try context.temporary(.any, span), .stack_depth = context.stack_depth };
        context.return_block = &block;
        context.insertion = &expansion;
        try self.compileStatements(context, definition.body);
        const kind = try self.finishBlock(context, &block, !definitelyReturns(definition.body), invocation.definition.span);
        if (definition.result) |annotation| try self.require(try self.typeOf(annotation), kind, annotation.span);
        return kind;
    }

    /// Whether Typst can receive a value of this type: as data, or as the
    /// typ.module a show path starts with. Any/scalar bindings receive the
    /// same check on their actual value when captured. Forward declarations
    /// need not be initialized yet.
    fn passable(read: TypstRead, kind: Type) bool {
        return switch (kind) {
            .any, .typst_module => true,
            .scalar, .quantity, .int, .number, .boolean, .string, .length, .color => !read.show,
            else => false,
        };
    }

    fn failTypstRead(self: *Compiler, read: TypstRead, kind: Type) error{LanguageError} {
        return if (read.show)
            self.fail(read.span, unsupported_show, .{ read.name, self.typeName(kind) })
        else
            self.fail(read.span, unsupported_typst_value, .{ read.name, self.typeName(kind) });
    }

    /// Rejects a type already known to be unsupported. A binding whose type
    /// is still to be inferred is kept for the check after this body is
    /// compiled.
    fn recordTypstRead(self: *Compiler, context: *Context, read: TypstRead) !void {
        if (!passable(read, read.binding.symbol.kind)) return self.failTypstRead(read, read.binding.symbol.kind);
        if (read.binding.symbol.inferable) try context.typst_reads.append(self.build.syntax_allocator, read);
    }

    /// Checks each read against the type its binding has once this body is
    /// compiled, since a forward declaration may be inferred after the read.
    /// Diagnostics name the reading module.
    fn checkTypstReads(self: *Compiler, context: *Context) !void {
        const current = self.environment;
        defer self.environment = current;
        for (context.typst_reads.items) |read| {
            const binding = read.binding;
            const kind = if (binding.local)
                context.local_types.items[binding.symbol.index]
            else if (binding.module != null)
                binding.symbol.kind
            else
                read.environment.globals.get(read.name).?.kind;
            if (passable(read, kind)) continue;
            self.environment = read.environment;
            return self.failTypstRead(read, kind);
        }
    }

    fn countCapture(self: *Compiler, count: *u32, span: Span) !void {
        if (count.* == std.math.maxInt(u32) / 2) return self.fail(span, "Typst code reads more Huak values than the bytecode stack holds", .{});
        count.* += 1;
    }

    /// Pushes a (name, value) pair for each Huak name the Typst code reads,
    /// in order of first use. When the code binds `huak` itself, a use may
    /// name that binding, so only names that are readable here and passable
    /// to Typst are captured.
    fn compileTypstReads(self: *Compiler, context: *Context, block: ast.Typst, count: *u32) !void {
        for (block.uses, 0..) |use, index| {
            // A block reads few names; an earlier use of this one captured it.
            const repeated = for (block.uses[0..index]) |earlier| {
                if (std.mem.eql(u8, earlier.name, use.name)) break true;
            } else false;
            if (repeated) continue;
            const read: TypstRead = .{
                .binding = context.resolve(use.name, use.span) orelse {
                    if (block.rebound) continue;
                    return self.fail(use.span, unreadable_typst_value, .{use.name});
                },
                .environment = self.environment,
                .name = use.name,
                .span = use.span,
                .show = false,
            };
            if (block.rebound) {
                const binding = read.binding;
                if (!passable(read, binding.symbol.kind) or (binding.local and use.span.start < binding.symbol.available_after)) continue;
            }
            try self.recordTypstRead(context, read);
            try self.countCapture(count, use.span);
            // The name is a slice of the module source, which the program keeps.
            try context.constant(.{ .string = use.name }, use.span);
            try context.load(read.binding, use.span);
        }
    }

    const ShowBase = struct { binding: Binding, taken: usize };

    /// Resolves at `site` the Huak value a `typ.show` path starts with: a
    /// readable binding, or an export reached through import namespaces.
    /// The remaining segments name members of that typ.module.
    fn typstShowBase(self: *Compiler, context: *Context, path: []const ast.ExportName, site: Span) !ShowBase {
        const first = path[0];
        const base: ShowBase = if (context.resolve(first.name, site)) |binding| .{ .binding = binding, .taken = 1 } else found: {
            var module = self.imported(first.name, site) orelse return self.fail(first.span, unreadable_show, .{first.name});
            const unit = self.environment.unit;
            const initializer = unit.resolverAt(site.start).namespaceInitializer(unit.scopeAt(site.start), first.name);
            for (path[1..], 2..) |segment, taken| {
                if (self.build.graph.exportedNamespace(module, segment.name)) |inner| {
                    module = inner;
                    continue;
                }
                const exposed = try self.importedExport(module, segment.name, segment.span);
                if (exposed.target != .global) return self.fail(segment.span, unreadable_show, .{segment.name});
                const global = exposed.target.global;
                break :found .{ .binding = .{ .symbol = .{ .index = global, .kind = self.build.types.items[global], .readonly = true }, .local = false, .module = module, .initializer = initializer }, .taken = taken };
            }
            return self.fail(first.span, unreadable_show, .{first.name});
        };
        const value = path[base.taken - 1];
        if (base.taken == path.len) return self.fail(value.span, "typ.show needs a member of the typ.module value, such as {s}.style", .{value.name});
        try self.recordTypstRead(context, .{ .binding = base.binding, .environment = self.environment, .name = value.name, .span = value.span, .show = true });
        return base;
    }

    fn samePath(a: []const ast.ExportName, b: []const ast.ExportName) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (!std.mem.eql(u8, x.name, y.name)) return false;
        return true;
    }

    /// Pushes a (".member.path", value) pair for each `typ.show` in scope at
    /// span: outer scopes first, each in source order, so the outermost
    /// applies outermost. Paths resolve at the typ block; a repeated path
    /// applies once, where it first appears.
    fn compileTypstShows(self: *Compiler, context: *Context, span: Span, count: *u32) !void {
        const unit = self.environment.unit;
        if (unit.headers.typst_declarations.len == 0) return;
        try self.compileScopeShows(context, unit.scopeAt(span.start), span, count);
    }

    fn compileScopeShows(self: *Compiler, context: *Context, scope: Parser.ScopeId, span: Span, count: *u32) !void {
        const headers = self.environment.unit.headers;
        if (headers.scopes[scope].parent) |parent| try self.compileScopeShows(context, parent, span, count);
        for (headers.typst_declarations, 0..) |header, index| {
            if (header.scope != scope or self.shownBefore(scope, index)) continue;
            const path = header.statement.value.typst_show;
            const base = try self.typstShowBase(context, path, span);
            try self.countCapture(count, span);
            try context.constant(.{ .string = try self.showMembers(path, base.taken) }, header.statement.span);
            try context.load(base.binding, span);
        }
    }

    /// Whether an enclosing scope, or this scope earlier, declares the same path.
    fn shownBefore(self: *const Compiler, scope: Parser.ScopeId, index: usize) bool {
        const headers = self.environment.unit.headers;
        const path = headers.typst_declarations[index].statement.value.typst_show;
        for (headers.typst_declarations, 0..) |other, other_index| {
            if (other_index == index or !samePath(other.statement.value.typst_show, path)) continue;
            if (other.scope == scope) {
                if (other_index < index) return true;
                continue;
            }
            var enclosing = headers.scopes[scope].parent;
            while (enclosing) |id| : (enclosing = headers.scopes[id].parent) if (id == other.scope) return true;
        }
        return false;
    }

    /// The members after the path's Huak names, as ".a.b". The leading '.'
    /// marks a show pair; Huak names never start with one. A path written
    /// without spaces is borrowed from the module source.
    fn showMembers(self: *Compiler, path: []const ast.ExportName, taken: usize) ![]const u8 {
        var length: usize = 0;
        for (path[taken..]) |segment| length += 1 + segment.name.len;
        const written = self.environment.unit.source_text[path[taken - 1].span.end..path[path.len - 1].span.end];
        if (written.len == length) return written;
        const text = try self.allocator.alloc(u8, length);
        var at: usize = 0;
        for (path[taken..]) |segment| {
            text[at] = '.';
            @memcpy(text[at + 1 ..][0..segment.name.len], segment.name);
            at += 1 + segment.name.len;
        }
        return text;
    }

    fn compilePathLiteral(self: *Compiler, context: *Context, expression_: *ast.Expr) anyerror!Type {
        var points: std.array_list.Managed(*ast.Expr) = .init(self.build.syntax_allocator);
        defer points.deinit();
        var joins: std.array_list.Managed(ast.PathJoin) = .init(self.build.syntax_allocator);
        defer joins.deinit();
        var closed = false;
        try self.collectPathLiteral(expression_, &points, &joins, &closed, 0);
        if (points.items.len < 2) return self.fail(expression_.span, "a path literal needs at least two points", .{});
        var dimension: Type = .any;
        for (points.items) |point_| {
            const actual = try self.compileExpression(context, point_);
            try self.require(if (dimension == .any) .vector else dimension, actual, point_.span);
            if (actual.isVector()) dimension = actual;
        }
        _ = try context.emit(.make_list, try self.narrow(points.items.len, expression_.span), 0, expression_.span);
        try context.constant(.{ .boolean = closed }, expression_.span);
        const values = try self.allocator.alloc(Value, joins.items.len);
        for (values, joins.items) |*value, join| value.* = .{ .string = @tagName(join) };
        try context.constant(bc.types.listView(values), expression_.span);
        _ = try context.emit(.call_builtin, @backingInt(builtin.Id.path), 3, expression_.span);
        return switch (dimension) {
            .vec2 => .path,
            .vec3 => .shape,
            else => .any,
        };
    }

    fn collectPathLiteral(self: *Compiler, expression_: *ast.Expr, points: *std.array_list.Managed(*ast.Expr), joins: *std.array_list.Managed(ast.PathJoin), closed: *bool, depth: usize) anyerror!void {
        if (depth > 256) return self.fail(expression_.span, "path literal exceeds compilation depth 256", .{});
        switch (expression_.value) {
            .path_literal => |join| {
                try self.collectPathLiteral(join.left, points, joins, closed, depth + 1);
                if (closed.*) return self.fail(join.left.span, "cycle must be the final endpoint of a path literal", .{});
                try joins.append(join.kind);
                try self.collectPathLiteral(join.right, points, joins, closed, depth + 1);
            },
            .cycle => {
                if (closed.* or points.items.len == 0 or joins.items.len != points.items.len)
                    return self.fail(expression_.span, "cycle is only valid as the closing endpoint of a path literal", .{});
                closed.* = true;
            },
            else => try points.append(expression_),
        }
    }

    fn binaryType(self: *Compiler, operation: ast.Binary, left: Type, right: Type, span: Span) !Type {
        const comparison = switch (operation) {
            .equal, .not_equal, .less, .less_equal, .greater, .greater_equal => true,
            else => false,
        };
        if (left.isScalar() and right.isScalar()) {
            const left_dimension = scalarDimension(left);
            const right_dimension = scalarDimension(right);
            if (left_dimension != null and right_dimension != null) {
                const a = left_dimension.?;
                const b = right_dimension.?;
                if (comparison or operation == .add or operation == .subtract or operation == .remainder) {
                    if (!a.eql(b)) return self.fail(span, "incompatible dimensions: {s} and {s}", .{ self.typeName(left), self.typeName(right) });
                }
                if (comparison) return .boolean;
                if (!a.eql(.scalar) or !b.eql(.scalar)) {
                    return switch (operation) {
                        .add, .subtract, .remainder => dimensionType(a),
                        .multiply, .divide => dimensionType(try a.combine(b, operation == .divide)),
                        .power => if (b.eql(.scalar)) .scalar else self.fail(span, "an exponent must be dimensionless", .{}),
                        else => unreachable,
                    };
                }
            } else return if (comparison) .boolean else .scalar;
        }
        if (operation == .equal or operation == .not_equal) return .boolean;
        if (operation == .less or operation == .less_equal or operation == .greater or operation == .greater_equal) {
            if ((left == .string or left == .any) and (right == .string or right == .any)) return .boolean;
            if ((left == .any and right.isScalar()) or (right == .any and left.isScalar())) return .boolean;
            try self.require(.number, left, span);
            try self.require(.number, right, span);
            return .boolean;
        }
        if (left == .any or right == .any) return .any;
        const left_number = left == .int or left == .number;
        const right_number = right == .int or right == .number;
        if (left_number and right_number) return if (operation == .divide or operation == .power or left == .number or right == .number) .number else .int;
        if (operation == .add and left == .string and right == .string) return .string;
        if ((operation == .add or operation == .subtract) and left.isVector() and left == right) return left;
        if ((operation == .multiply or operation == .divide) and left.isVector() and right.isScalar()) return left;
        if (operation == .multiply and left.isScalar() and right.isVector()) return right;
        const left_linear = left == .variable or left == .linear;
        const right_linear = right == .variable or right == .linear;
        if ((operation == .add or operation == .subtract) and (left_linear or left_number) and (right_linear or right_number)) return .linear;
        if ((operation == .multiply and ((left_linear and right_number) or (left_number and right_linear))) or (operation == .divide and left_linear and right_number)) return .linear;
        return self.fail(span, "operator {s} does not accept {s} and {s}", .{ @tagName(operation), self.typeName(left), self.typeName(right) });
    }

    fn constantValue(self: *Compiler, expression_: *ast.Expr, function_parameters: ?[]const ast.Parameter) anyerror!Value {
        return switch (expression_.value) {
            .grouped => |inner| self.constantValue(inner, function_parameters),
            .integer => |value| if (value <= std.math.maxInt(i64)) .{ .int = @intCast(value) } else self.fail(expression_.span, "integer literal is outside int range", .{}),
            .float => |value| .{ .number = value },
            .quantity => |quantity| numeric.valueArithmetic(.multiply, try self.constantValue(quantity.operand, function_parameters), .{ .quantity = try units.applyUnit(1, quantity.unit) }) catch |err| self.fail(expression_.span, "invalid constant quantity: {s}", .{@errorName(err)}),
            .binary => |binary| blk: {
                const op: bc.Op = switch (binary.op) {
                    .add => .add,
                    .subtract => .subtract,
                    .multiply => .multiply,
                    .divide => .divide,
                    .remainder => .remainder,
                    .power => .power,
                    else => return self.fail(expression_.span, "parameter default must be a constant literal", .{}),
                };
                break :blk numeric.valueArithmetic(op, try self.constantValue(binary.left, function_parameters), try self.constantValue(binary.right, function_parameters)) catch |err| return self.fail(expression_.span, "invalid constant parameter default: {s}", .{@errorName(err)});
            },
            .boolean => |value| .{ .boolean = value },
            .list => |items| blk: {
                const values = try self.allocator.alloc(Value, items.len);
                for (items, values) |item, *value| value.* = try self.constantValue(item, function_parameters);
                break :blk @import("types.zig").listView(values);
            },
            .dict => |entries| blk: {
                const dictionary = try self.allocator.create(bc.types.Dict);
                dictionary.* = .{};
                for (entries) |entry| {
                    const key = try self.allocator.dupe(u8, entry.key);
                    const value = try self.constantValue(entry.value, function_parameters);
                    const stored = try dictionary.entries.getOrPut(self.allocator, key);
                    if (stored.found_existing) return self.fail(entry.span, "duplicate dictionary key '{s}'", .{key});
                    stored.value_ptr.* = value;
                }
                break :blk .{ .dict = dictionary };
            },
            .vector => |v| blk: {
                const x = try self.constantValue(v.x, function_parameters);
                const y = try self.constantValue(v.y, function_parameters);
                break :blk (if (v.z) |z| numeric.makeVector(3, .{ x, y, try self.constantValue(z, function_parameters) }) else numeric.makeVec2(x, y)) catch |err| self.fail(expression_.span, "invalid constant vector: {s}", .{@errorName(err)});
            },
            .string => |value| .{ .string = try self.allocator.dupe(u8, value) },
            .name => |name| blk: {
                if (function_parameters) |parameters| {
                    for (parameters) |parameter| if (std.mem.eql(u8, parameter.name, name))
                        return self.fail(expression_.span, "function default cannot reference parameter '{s}'", .{name});
                }
                if (self.environment.unit.resolverAt(expression_.span.start).readable(0, name)) |readable| {
                    if (readable == .imported and readable.imported == .member) {
                        const member = readable.imported.member;
                        if (self.build.graph.units.items[member.module].native_namespace) |native| if (builtin.namespaceConstant(native, member.name)) |value| break :blk value;
                    }
                    if (function_parameters != null) return self.fail(expression_.span, "function default cannot reference nonconstant binding '{s}'", .{name});
                }
                break :blk namedConstant(name) orelse return self.fail(expression_.span, "parameter default must be a constant literal", .{});
            },
            .member => |member| blk: {
                const object = ungroup(member.object);
                var root = object;
                while (root.value == .member) root = ungroup(root.value.member.object);
                if (root.value == .name) if (function_parameters) |parameters| for (parameters) |parameter| if (std.mem.eql(u8, parameter.name, root.value.name))
                    return self.fail(expression_.span, "function default cannot reference parameter '{s}'", .{root.value.name});
                if (self.moduleExpression(object)) |index| if (self.build.graph.units.items[index].native_namespace) |native| {
                    if (builtin.namespaceConstant(native, member.name)) |value| break :blk value;
                };
                if (object.value == .name) {
                    const name = object.value.name;
                    const native = if (self.imported(name, expression_.span)) |index|
                        self.build.graph.units.items[index].native_namespace
                    else if (self.environment.unit.resolverAt(expression_.span.start).readable(0, name) == null) builtin.Namespace.parse(name) else null;
                    if (native) |domain| if (builtin.namespaceConstant(domain, member.name)) |value| break :blk value;
                }
                return self.fail(expression_.span, "parameter default must be a constant literal", .{});
            },
            .unary => |unary| blk: {
                const literal = ungroup(unary.operand);
                if (unary.op == .negate and literal.value == .integer and literal.value.integer == @as(u64, 1) << 63) break :blk .{ .int = std.math.minInt(i64) };
                const operand = try self.constantValue(unary.operand, function_parameters);
                switch (unary.op) {
                    .positive => if (operand.valueType().isScalar()) break :blk operand,
                    .negate => switch (operand) {
                        .int => |value| {
                            const result = @subWithOverflow(@as(i64, 0), value);
                            if (result[1] == 0) break :blk .{ .int = result[0] };
                        },
                        .number => |value| break :blk .{ .number = -value },
                        .quantity => |value| break :blk .{ .quantity = value.negate() },
                        else => {},
                    },
                    .logical_not => if (operand == .boolean) break :blk .{ .boolean = !operand.boolean },
                }
                return self.fail(expression_.span, "invalid constant parameter default", .{});
            },
            else => return self.fail(expression_.span, "parameter default must be a constant literal", .{}),
        };
    }
};

fn ungroup(expression: *ast.Expr) *ast.Expr {
    var result = expression;
    while (result.value == .grouped) result = result.value.grouped;
    return result;
}

fn scalarDimension(kind: Type) ?units.Dimension {
    return switch (kind) {
        .int, .number => .scalar,
        .length => .distance,
        .angle => .rotation,
        else => null,
    };
}
fn dimensionType(dimension: units.Dimension) Type {
    if (dimension.eql(.scalar)) return .number;
    if (dimension.eql(.distance)) return .length;
    if (dimension.eql(.rotation)) return .angle;
    return .quantity;
}

fn namedConstant(name: []const u8) ?Value {
    if (units.unitNamed(name)) |unit| return .{ .quantity = units.applyUnit(1, unit) catch unreachable };
    return null;
}

fn testGlobalType(program: *const bc.Program, name: []const u8) Type {
    for (program.global_names, program.global_types) |binding, kind| if (std.mem.eql(u8, binding, name)) return kind;
    unreachable;
}

fn zeroLiteral(expression: *ast.Expr) bool {
    return switch (expression.value) {
        .grouped => |inner| zeroLiteral(inner),
        .integer => |value| value == 0,
        .float => |value| value == 0,
        .unary => |unary| unary.op != .logical_not and zeroLiteral(unary.operand),
        else => false,
    };
}

test "list literals share assignments and explicit copies remain isolated across executions" {
    const Machine = @import("Machine.zig");
    const input =
        \\fn collected() -> list
        \\    values:=[1,2]
        \\    for i in 3:40 do
        \\        values+=i
        \\    end
        \\    return values
        \\end
        \\seed:=[7]
        \\builder:=[];builder+=seed
        \\alias:=builder
        \\before:=[];before+=builder
        \\alias+=8
        \\after:=[];after+=builder
        \\count:=len(alias)
        \\result:=collected()
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "list-builder.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        for (0..2) |_| {
            var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
            defer machine.deinit();
            _ = try machine.execute(&.{});
            const seed = @import("types.zig").sequence(machine.getGlobal("seed").?).?;
            const before = @import("types.zig").sequence(machine.getGlobal("before").?).?;
            const after = @import("types.zig").sequence(machine.getGlobal("after").?).?;
            const result = @import("types.zig").sequence(machine.getGlobal("result").?).?;
            try std.testing.expectEqual(@as(usize, 1), seed.len);
            try std.testing.expectEqual(@as(usize, 1), before.len);
            try std.testing.expectEqual(@as(usize, 2), after.len);
            try std.testing.expectEqual(@as(i64, 8), after[1].int);
            try std.testing.expectEqual(@as(i64, 2), machine.getGlobal("count").?.int);
            try std.testing.expectEqual(@as(usize, 40), result.len);
            try std.testing.expectEqual(@as(i64, 40), result[39].int);
        }
    }
    for ([_][]const u8{ "push([1],2)", "array([1])", "list(1)", "fn obsolete(value:array) end" }) |invalid| {
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, invalid, "invalid-list.huak", .{}, &diagnostic));
    }
}

test "list append assignment checks the target without declaring or rebinding it" {
    const invalid = [_]struct { input: []const u8, message: []const u8 }{
        .{ .input = "missing+=1", .message = "unknown list variable" },
        .{ .input = "items:=1;items+=2", .message = "expected list" },
        .{ .input = "items:=\"a\";items+=\"b\"", .message = "expected list" },
        .{ .input = "param items=1;items+=2", .message = "readonly parameter" },
        .{ .input = "items:=[];value:=items+1", .message = "operator add" },
    };
    for ([_]bool{ false, true }) |optimize| {
        for (invalid) |case| {
            var diagnostic: ?Diagnostic = null;
            try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, case.input, "invalid-list-append.huak", .{ .optimize = optimize }, &diagnostic));
            try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), case.message) != null);
        }
    }
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator,
        \\items:=[]
        \\items+=[1,2]
        \\fn extend(values:list, value:any)
        \\    values+=value
        \\    items+=value
        \\end
    , "list-append-bindings.huak", .{ .optimize = false }, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(@as(usize, 1), program.global_names.len);
    const function = program.functions[1];
    try std.testing.expectEqual(@as(usize, 2), function.local_types.len);
    try std.testing.expectEqual(bc.Op.load_local, function.code[0].op);
    try std.testing.expectEqual(bc.Op.load_local, function.code[1].op);
    try std.testing.expectEqual(bc.Op.list_append, function.code[2].op);
    try std.testing.expectEqual(bc.Op.load_global, function.code[3].op);
    try std.testing.expectEqual(bc.Op.load_local, function.code[4].op);
    try std.testing.expectEqual(bc.Op.list_append, function.code[5].op);
    for (function.code) |instruction| try std.testing.expect(instruction.op != .store_local and instruction.op != .store_global);
}

fn listAllocationExercise(allocator: std.mem.Allocator, program: *const bc.Program) !void {
    const Machine = @import("Machine.zig");
    var machine = try Machine.init(allocator, program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
}

test "VM list builders release constructor growth and snapshot allocation failures" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator,
        \\values:=[1,2]
        \\for i in 3:24 do; values+=i; end
        \\snapshot:=[];snapshot+=values
        \\values+=25
        \\count:=len(values)
    , "list-allocations.huak", .{}, &diagnostic);
    defer program.deinit();
    try listAllocationExercise(std.testing.allocator, &program);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), listAllocationExercise, .{&program});
}

fn definitelyReturns(statements: []const *ast.Stmt) bool {
    for (statements) |statement| switch (statement.value) {
        .return_value => return true,
        .conditional => |conditional| {
            if (conditional.otherwise.len == 0 or !definitelyReturns(conditional.otherwise)) continue;
            var all = true;
            for (conditional.branches) |branch| if (!definitelyReturns(branch.body)) {
                all = false;
                break;
            };
            if (all) return true;
        },
        else => {},
    };
    return false;
}

test "block values keep lexical bindings and return to the nearest block" {
    const input =
        \\a := 2
        \\value := block
        \\    a := 1
        \\    b := block; return 2; end
        \\    return a + b
        \\end
        \\fn compute() -> int
        \\    x := 10 + block
        \\        for i in 1:4 do
        \\            if i == 2 then; return i; end
        \\        end
        \\        return 0
        \\    end
        \\    return x + 1
        \\end
        \\result := compute()
        \\sum := 0
        \\for i in 1:4 do
        \\    x := block
        \\        if i == 2 then; continue; end
        \\        if i == 4 then; break; end
        \\        return i
        \\    end
        \\    sum = sum + x
        \\end
        \\empty := block; x := 1; end
        \\shadow := block
        \\    a := block; return a+1; end
        \\    return a
        \\end
        \\fn combine(a:int, b:int) -> int; return a+b; end
        \\mixfix(combine) combine _ with _ in unary
        \\continued := block
        \\    a := combine 10
        \\        with a
        \\    return a
        \\end
        \\for i in 1:2 do
        \\    a := a+1
        \\    sum = sum+a
        \\end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "block-values.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        inline for (.{ "a", "value", "result", "sum", "shadow", "continued" }, .{ 2, 3, 13, 10, 3, 12 }) |name, expected|
            try std.testing.expectEqual(@as(i64, expected), machine.getGlobal(name).?.int);
        try std.testing.expectEqual(Value.unit, machine.getGlobal("empty").?);
        try std.testing.expect(machine.getGlobal("b") == null);
    }
}

test "explicit partial application retains values and ordinary mixfix calls" {
    const input =
        \\fn add(a:int, b:int, c:int=4) -> int; return a+b+c; end
        \\fn bind(a:int) -> function; return add.with(a: a); end
        \\f := bind(2)
        \\first := f(b:3)
        \\g := add.with(1).with(c:8)
        \\second := g(2)
        \\third := g(b:2,c:10)
        \\fourth := block
        \\    add := add.with(1,c:3)
        \\    mixfix(add) add _ in unary
        \\    return add 2
        \\end
        \\size := len.with("abc")
        \\fifth := size()
        \\fn collect(a:int, rest:int...) -> list; return rest; end
        \\tail := collect.with(1,2)
        \\values := tail(3,4)
        \\events := []
        \\fn mark(value:int) -> int; events+=value; return value; end
        \\fn deferred(a:int, b:int=block
        \\    local:=mark(8)
        \\    return local+1
        \\end) -> int; return a+b; end
        \\ready := deferred.with(a:mark(1))
        \\before := len(events)
        \\sixth := ready()
        \\seventh := ready(b:mark(2))
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = compile(std.testing.allocator, input, "partial-values.huak", .{ .optimize = optimize }, &diagnostic) catch |err| {
            if (diagnostic) |detail| std.debug.print("{s}\n", .{detail.text()});
            return err;
        };
        defer program.deinit();
        var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = machine.execute(&.{}) catch |err| {
            if (machine.failure) |failure| std.debug.print("{s}\n", .{failure.diagnostic.text()});
            return err;
        };
        inline for (.{ "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "before" }, .{ 9, 11, 13, 6, 3, 10, 3, 1 }) |name, expected|
            try std.testing.expectEqual(@as(i64, expected), machine.getGlobal(name).?.int);
        const events = machine.getGlobal("events").?.list.items();
        try std.testing.expectEqual(@as(usize, 3), events.len);
        for (events, [_]i64{ 1, 8, 2 }) |event, expected| try std.testing.expectEqual(expected, event.int);
        for (machine.getGlobal("values").?.list.items(), 2..) |value, expected|
            try std.testing.expectEqual(@as(i64, @intCast(expected)), value.int);
    }
}

test "expanded blocks bind arguments once and expose local commands without captures" {
    const input =
        \\fn put(target:dict, value:int)
        \\    target["sum"] = target["sum"] + value
        \\end
        \\fn next(target:dict) -> dict
        \\    target["calls"] = target["calls"] + 1
        \\    return target
        \\end
        \\expand_block accumulate(target:dict)
        \\    place := put.with(target: target)
        \\    mixfix(place) place _ in unary
        \\    ...
        \\    target["finished"] = target["finished"] + 1
        \\    return target["sum"]
        \\end
        \\state := {"sum":0,"calls":0,"finished":0}
        \\first := accumulate next(state) do
        \\    place 3
        \\    place(4)
        \\end
        \\second := accumulate(state) do
        \\    place 2
        \\    return 99
        \\end
        \\third := accumulate state do; end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = compile(std.testing.allocator, input, "expanded.huak", .{ .optimize = optimize }, &diagnostic) catch |err| {
            if (diagnostic) |detail| std.debug.print("{s} at {d}\n", .{ detail.text(), detail.span.start });
            return err;
        };
        defer program.deinit();
        var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = machine.execute(&.{}) catch |err| {
            if (machine.failure) |failure| std.debug.print("{s}\n", .{failure.diagnostic.text()});
            return err;
        };
        inline for (.{ "first", "second", "third" }, .{ 7, 99, 9 }) |name, expected|
            try std.testing.expectEqual(@as(i64, expected), machine.getGlobal(name).?.int);
        const state = machine.getGlobal("state").?.dict;
        try std.testing.expectEqual(@as(i64, 1), state.entries.get("calls").?.int);
        try std.testing.expectEqual(@as(i64, 2), state.entries.get("finished").?.int);
    }
    for ([_][]const u8{
        "expand_block invalid(); end",
        "expand_block invalid(); ...; ...; end",
        "expand_block invalid(); ...; block ... end; end",
        "expand_block scope(); import math.abs; ...; end; scope do abs:=1 end",
    }) |invalid| {
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, invalid, "invalid-block.huak", .{}, &diagnostic));
    }
}

fn exportedGroup(exposed: bc.Export, leading: bool) ?u32 {
    return if (exposed.mixfix[@intFromBool(leading)]) |form| form.group else null;
}

fn sameMixfix(left: [2]?bc.MixfixForm, right: [2]?bc.MixfixForm) bool {
    for (left, right) |one, two| {
        if (one == null or two == null) {
            if (one != null or two != null) return false;
            continue;
        }
        if (one.?.group != two.?.group or one.?.parts.len != two.?.parts.len) return false;
        if (!std.mem.eql(u8, one.?.head, two.?.head)) return false;
        for (one.?.parts, two.?.parts) |a, b| {
            if (a == null or b == null) {
                if (a != null or b != null) return false;
            } else if (!std.mem.eql(u8, a.?, b.?)) return false;
        }
    }
    return true;
}

test "dynamic drawing picture targets retain typed runtime validation" {
    var diagnostic: ?Diagnostic = null;
    var valid = try compile(std.testing.allocator, "expand_block drawing(target:picture); ...; return target; end\npictures:=[picture(640, 480)]\ndrawing pictures[0] do end", "dynamic-picture.huak", .{}, &diagnostic);
    defer valid.deinit();
    try std.testing.expectEqual(Type.picture, valid.functions[valid.entry].local_types[0]);
    var invalid = try compile(std.testing.allocator, "expand_block drawing(target:picture); ...; return target; end\ndrawing [3][0] do end", "invalid-dynamic-picture.huak", .{}, &diagnostic);
    defer invalid.deinit();
    var machine = try @import("Machine.zig").init(std.testing.allocator, &invalid, .{}, .{});
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    try std.testing.expectEqualStrings("expected picture, received int", machine.failure.?.text());
}

test "reexported native templates retain their own group in nested blocks" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !ResolvedSource {
            return .{ .name = "brush.huak", .source =
            \\import object.draw as paint
            \\precedence stroke_scope above addition;end
            \\mixfix(paint) paint _ in stroke_scope
            \\export paint
            };
        }
    };
    var context: u8 = 0;
    for ([_][]const u8{ "paint", "brush.paint" }) |head| {
        for ([_]bool{ false, true }) |grouped| {
            const input = try std.fmt.allocPrint(
                std.testing.allocator,
                "import \"brush\".paint;import \"brush\" as brush\nimport geometry.joined as join\nmixfix(join) _ join _ in addition\np:=path((0,0),(1,1));q:=path((1,1),(2,2))\nblock\n{s} {s}\nend",
                .{ head, if (grouped) "(p join q)" else "p join q" },
            );
            defer std.testing.allocator.free(input);
            var diagnostic: ?Diagnostic = null;
            const options: CompileOptions = .{ .import_resolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } } };
            if (grouped) {
                var program = try compile(std.testing.allocator, input, "native-group.huak", options, &diagnostic);
                defer program.deinit();
            } else {
                try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "native-group.huak", options, &diagnostic));
                try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "path") != null);
            }
        }
    }
}

test "ordinary and dot record calls retain their signatures" {
    const input =
        \\struct Empty;end
        \\struct Broken;end
        \\fn ordinary(value:Broken)->int return 4 end
        \\fn plain(value:Empty)->int return 3 end
        \\mixfix(ordinary) ordinary _ in unary
        \\mixfix(plain) plain _ in unary
        \\mixed:=ordinary Broken()
        \\mixed_plain:=plain Empty()
        \\first:=ordinary(Broken())
        \\second:=Broken().ordinary()
        \\third:=plain(Empty())
        \\fourth:=Empty().plain()
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "ordinary-record-hooks.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        for ([_][]const u8{ "first", "second", "mixed" }) |name| try std.testing.expectEqual(@as(i64, 4), machine.getGlobal(name).?.int);
        for ([_][]const u8{ "third", "fourth", "mixed_plain" }) |name| try std.testing.expectEqual(@as(i64, 3), machine.getGlobal(name).?.int);
    }
}

fn compileUnit(build: *Build, unit: *ModuleGraph.Unit, module_index: u32, diagnostic: *?Diagnostic) !void {
    const memory = build.allocator;
    var compiler = try Compiler.init(memory, diagnostic, unit, module_index, build);
    try compiler.declarations.append(null);
    try compiler.declareRecords();
    try compiler.collectImportedSymbols();
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
                    const value = try compiler.constantValue(expression, function.params);
                    try compiler.require(declared, value.valueType(), expression.span);
                    defaults[parameter_index] = value;
                }
            }
        }
        try compiler.output.append(.{ .name = function.name, .code = &.{}, .parameters = parameters, .parameter_names = parameter_names, .defaults = defaults, .variadic = variadic, .result = if (function.result) |annotation| try compiler.typeOf(annotation) else .unit, .local_types = &.{}, .span = statement.span, .module = module_index });
    }
    try compiler.declareExpressionDefaults();
    try compiler.collectPrecedence();
    try compiler.collectGlobals(unit.script.statements);
    var entry = Context.init(&compiler, true, .unit);
    if (unit.data) |data| {
        const span: Span = .{ .start = 0, .end = unit.source_text.len };
        const name = ModuleGraph.Unit.data_export;
        try compiler.declareGlobal(name, data.valueType(), false, false, span);
        try entry.constant(data, span);
        _ = try entry.emit(.store_global, compiler.environment.globals.get(name).?.index, 0, span);
        try compiler.exportName(name, span, span, .value);
    }
    try compiler.collectLocals(&entry, unit.script.statements);
    try compiler.compileStatements(&entry, unit.script.statements);
    try compiler.checkTypstReads(&entry);
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
            try compiler.declareLocal(&context, parameter.name, kind, false, parameter.span);
        }
        try compiler.collectLocals(&context, function.body);
        try compiler.compileStatements(&context, function.body);
        try compiler.checkTypstReads(&context);
        if (result != .unit and !definitelyReturns(function.body)) return compiler.fail(statement.span, "function '{s}' may finish without returning {s}", .{ function.name, compiler.typeName(result) });
        try context.constant(.unit, statement.span);
        _ = try context.emit(.return_value, 0, 0, statement.span);
        compiler.output.items[index].code = try context.code.toOwnedSlice();
        compiler.output.items[index].local_types = try context.local_types.toOwnedSlice();
    }
    for (compiler.expression_defaults.items) |default| {
        var context = Context.init(&compiler, false, default.kind);
        var declarations: Compiler.Declarations = .{ .compiler = &compiler, .context = &context };
        try ast.walk(&declarations, .{ .expression = default.expression });
        const actual = try compiler.compileExpression(&context, default.expression);
        try compiler.require(default.kind, actual, default.expression.span);
        try compiler.checkTypstReads(&context);
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
            const exposed = compiler.memberExport(value.member);
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

const DefaultReferences = struct {
    compiler: *Compiler,
    parameters: []const ast.Parameter,
    dynamic: bool = false,
    pub fn enter(self: *DefaultReferences, node: ast.Node) !bool {
        if (node != .expression) return true;
        const expression = node.expression;
        switch (expression.value) {
            .name => |name| {
                for (self.parameters) |param| if (std.mem.eql(u8, param.name, name))
                    return self.compiler.fail(expression.span, "function default cannot reference parameter '{s}'", .{name});
                if (namedConstant(name) == null or self.compiler.environment.unit.resolverAt(expression.span.start).readable(0, name) != null) self.dynamic = true;
            },
            .call, .mixfix_call, .block, .expansion, .typst, .index, .slice => self.dynamic = true,
            else => {},
        }
        return true;
    }
};

/// Module source survives in storage. The AST belongs to syntax. Providers
/// are only borrowed while resolving the root and its imports.
pub fn parseModules(storage: std.mem.Allocator, syntax: std.mem.Allocator, input: []const u8, name: []const u8, options: CompileOptions, diagnostic: *?Diagnostic) !ModuleGraph {
    diagnostic.* = null;
    var graph = ModuleGraph.init(storage, syntax, .{ .source_parser = options.source_parser }, options.import_resolver, diagnostic);
    try graph.root(name, input);
    graph.options = .{};
    graph.resolver = null;
    return graph;
}

/// Run the same parsing, linking and semantic checks without producing an
/// executable Program, optimizing bytecode or scheduling picture tasks.
pub fn check(allocator: std.mem.Allocator, input: []const u8, name: []const u8, options: CompileOptions, diagnostic: *?Diagnostic) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const graph = try parseModules(arena.allocator(), arena.allocator(), input, name, options, diagnostic);
    try checkGraph(allocator, &graph);
}

/// Check a graph already parsed by an editor tool. The check owns its
/// temporary lowering state; the caller keeps the graph and its source ranges.
pub fn checkGraph(allocator: std.mem.Allocator, graph: *const ModuleGraph) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = try lowerGraph(graph, arena.allocator(), arena.allocator());
}

fn lowerGraph(graph: *const ModuleGraph, memory: std.mem.Allocator, syntax: std.mem.Allocator) !Build {
    const count = graph.units.items.len;
    var build: Build = .{ .allocator = memory, .syntax_allocator = syntax, .graph = graph, .functions = .init(memory), .constants = .init(memory), .records = .init(memory), .argument_bindings = .init(memory), .parameters = .init(memory), .names = .init(memory), .types = .init(memory), .readonly = .init(memory), .modules = try memory.alloc(bc.Module, count), .environments = try syntax.alloc(*Environment, count), .precedence = try precedence.Table.init(syntax) };
    for (graph.order.items) |index| try compileUnit(&build, graph.units.items[index], index, graph.diagnostic);
    return build;
}

pub fn compile(allocator: std.mem.Allocator, input: []const u8, name: []const u8, options: CompileOptions, diagnostic: *?Diagnostic) !bc.Program {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const memory = arena.allocator();
    var syntax_arena: std.heap.ArenaAllocator = .init(allocator);
    defer syntax_arena.deinit();
    const graph = try parseModules(memory, syntax_arena.allocator(), input, name, options, diagnostic);
    var build = try lowerGraph(&graph, memory, syntax_arena.allocator());
    if (options.optimize) {
        {
            var pool_index = optimizer.PoolIndex.init(allocator);
            defer pool_index.deinit();
            for (build.functions.items) |*function| function.code = try optimizer.optimize(memory, function.code, &build.constants, .{
                .global_types = build.types.items,
                .local_types = function.local_types,
                .argument_bindings = build.argument_bindings.items,
                .scratch_allocator = allocator,
                .pool_index = &pool_index,
            });
        }
        try optimizer.compactConstants(memory, build.functions.items, &build.constants);
    }
    // Finish every arena allocation before copying its owner into Program.
    // A later allocation can grow the arena and make an earlier owner copy
    // omit the newly allocated block during deinit.
    const functions = try build.functions.toOwnedSlice();
    const constants = try build.constants.toOwnedSlice();
    const parameters = try build.parameters.toOwnedSlice();
    const records = try build.records.toOwnedSlice();
    const argument_bindings = try build.argument_bindings.toOwnedSlice();
    const groups = try memory.dupe(bc.PrecedenceGroup, build.precedence.groups.items);
    const global_names = try build.names.toOwnedSlice();
    const global_types = try build.types.toOwnedSlice();
    const readonly = try build.readonly.toOwnedSlice();
    var program: bc.Program = .{ .arena = undefined, .source_text = build.modules[0].source_text, .name = build.modules[0].name, .functions = functions, .constants = constants, .records = records, .argument_bindings = argument_bindings, .parameters = parameters, .exports = build.modules[0].exports, .outputs = build.outputs, .modules = build.modules, .groups = groups, .global_names = global_names, .global_types = global_types, .readonly_globals = readonly, .entry = build.modules[0].entry };
    program.argument_names = try build.argument_names.toOwnedSlice(memory);
    // Planning works in the caller's allocator and releases its state here;
    // only the regions join Program memory.
    program.task_regions = try task_plan.build(memory, allocator, &program);
    // The regions are allocated in memory; copy the arena owner only afterwards.
    program.arena = arena;
    return program;
}

test "check preserves semantic and imported diagnostics without producing a Program" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (std.mem.eql(u8, path, "middle.huak")) return .{ .name = "middle.huak", .source = "import \"broken.huak\" as broken\nexport value:=broken.value" };
            if (std.mem.eql(u8, path, "broken.huak")) return .{ .name = "broken.huak", .source = "export value:=not_declared" };
            return error.FileNotFound;
        }
    };
    var marker: u8 = 0;
    const cases = [_][]const u8{
        "value:=not_declared",
        "value:int:=\"wrong\"",
        "fn bad()->int return true end",
        "export missing",
        "fn broken(",
        "import \"middle.huak\" as middle",
        "typ.show missing.style\nvalue:=typ[]",
        "value:=typ[invalid fixture]",
    };
    for (cases) |input| for ([_]bool{ false, true }) |optimize| {
        var expected: ?Diagnostic = null;
        var actual: ?Diagnostic = null;
        const options: CompileOptions = .{ .optimize = optimize, .source_parser = .{ .ptr = &marker, .vtable = &.{ .block = emptyTypstFixture } }, .import_resolver = .{ .ptr = &marker, .vtable = &.{ .resolve = Resolver.resolve } } };
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "check-root.huak", options, &expected));
        try std.testing.expectError(error.LanguageError, check(std.testing.allocator, input, "check-root.huak", options, &actual));
        try std.testing.expectEqualStrings(expected.?.text(), actual.?.text());
        try std.testing.expectEqualStrings(expected.?.fileName().?, actual.?.fileName().?);
        try std.testing.expectEqualDeep(expected.?.span, actual.?.span);
        try std.testing.expectEqualDeep(expected.?.position(""), actual.?.position(""));
    };
    var diagnostic: ?Diagnostic = null;
    try check(std.testing.allocator, "value:=typ[]\npanic(\"checking must not execute\")", "native-block-check.huak", .{ .source_parser = .{ .ptr = &marker, .vtable = &.{ .block = emptyTypstFixture } } }, &diagnostic);
    try std.testing.expect(diagnostic == null);
}

fn checkAllocationExercise(allocator: std.mem.Allocator) !void {
    var marker: u8 = 0;
    var diagnostic: ?Diagnostic = null;
    try check(allocator,
        \\import "left.huak" as left
        \\import "right.huak" as right
        \\struct Entry value:int=3 end
        \\items:=[]
        \\for i in 0:3 do items+=[Entry(value:i)] end
        \\export result:=left.get()+right.get()
    , "check-allocation.huak", .{ .import_resolver = .{ .ptr = &marker, .vtable = &.{ .resolve = ModuleTestSources.resolve } } }, &diagnostic);
    try std.testing.expect(diagnostic == null);
}

test "check releases both semantic arenas on success and every allocation failure" {
    try checkAllocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), checkAllocationExercise, .{});
}

fn aggregateGlobal(program: *const bc.Program, machine: *const @import("Machine.zig"), name: []const u8) Value {
    for (program.global_names, machine.globals) |found, value| if (std.mem.eql(u8, found, name)) return value;
    unreachable;
}

test "aggregate compiler preserves nominal fields aliases and fresh defaults" {
    const input =
        \\struct Box
        \\ value:int=7
        \\ items:list=[]
        \\ options:dict={}
        \\end
        \\a:=Box(value:3)
        \\alias:=a
        \\alias.value=4
        \\a.items += 9
        \\a.options["key"]=12
        \\b:=Box()
        \\original:=a.value
        \\fresh:=len(b.items)+len(b.options)
        \\cloned:=copy(a)
        \\cloned.value=8
        \\independent:=a.value
        \\cloned.items[0]=10
        \\shared:=a.items[0]
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "aggregate.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(i64, 4), aggregateGlobal(&program, &machine, "original").int);
        try std.testing.expectEqual(@as(i64, 0), aggregateGlobal(&program, &machine, "fresh").int);
        try std.testing.expectEqual(@as(i64, 4), aggregateGlobal(&program, &machine, "independent").int);
        try std.testing.expectEqual(@as(i64, 10), aggregateGlobal(&program, &machine, "shared").int);
    }
}

test "aggregate compiler evaluates named arguments once in source order before defaults" {
    const input =
        \\events:=[0]
        \\fn event(value:int)->int
        \\ events[0]=events[0]*10+value
        \\ return value
        \\end
        \\struct Example
        \\ a:int
        \\ b:int
        \\ c:int=event(3)
        \\end
        \\fn combine(x:int=10,y:int=20,z:int=30)->int
        \\ return 100*x+10*y+z
        \\end
        \\object:=Example(b:event(1),a:event(2))
        \\result:=combine(y:event(4),x:event(5))
        \\trace:=events[0]
        \\fields:=object.a*100+object.b*10+object.c
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "aggregate-order.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(i64, 12345), aggregateGlobal(&program, &machine, "trace").int);
        try std.testing.expectEqual(@as(i64, 570), aggregateGlobal(&program, &machine, "result").int);
        try std.testing.expectEqual(@as(i64, 213), aggregateGlobal(&program, &machine, "fields").int);
    }
}

fn pathLiteralAllocationExercise(allocator: std.mem.Allocator) !void {
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(allocator,
            \\fn outline(a:vec2,b:vec2,c:vec2) -> path
            \\    return a~~b--c~~cycle
            \\end
            \\shape:=outline((0mm,0mm),(10mm,15mm),(20mm,0mm))
        , "path-allocation.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
    }
}

test "path literal lowering releases temporary and persistent data on every allocation failure" {
    try pathLiteralAllocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), pathLiteralAllocationExercise, .{});
}

test "infix and ordinary calls produce the same checked and optimized instructions" {
    const declarations =
        \\precedence combine_group
        \\ above addition
        \\ associativity left
        \\end
        \\mixfix(combine) _ combine _ in combine_group
        \\fn combine(a:int,b:int)->int;return a*10+b;end
        \\
    ;
    const left = try std.fmt.allocPrint(std.testing.allocator, "{s}answer:=1 combine 2 combine 3\n", .{declarations});
    defer std.testing.allocator.free(left);
    const right = try std.fmt.allocPrint(std.testing.allocator, "{s}answer:=combine(combine(1,2),3)\n", .{declarations});
    defer std.testing.allocator.free(right);
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var infix = try compile(std.testing.allocator, left, "infix.huak", .{ .optimize = optimize }, &diagnostic);
        defer infix.deinit();
        var ordinary = try compile(std.testing.allocator, right, "ordinary.huak", .{ .optimize = optimize }, &diagnostic);
        defer ordinary.deinit();
        try std.testing.expectEqual(ordinary.constants.len, infix.constants.len);
        for (ordinary.constants, infix.constants) |expected, actual| try std.testing.expectEqualDeep(expected, actual);
        try std.testing.expectEqual(ordinary.functions.len, infix.functions.len);
        for (ordinary.functions, infix.functions) |expected, actual| {
            try std.testing.expectEqual(expected.code.len, actual.code.len);
            for (expected.code, actual.code) |a, b| {
                try std.testing.expectEqual(a.op, b.op);
                try std.testing.expectEqual(a.a, b.a);
                try std.testing.expectEqual(a.b, b.b);
            }
        }
    }
}

test "precedence metadata survives caller source release and grouped signed minimums" {
    const allocator = std.testing.allocator;
    const original = try allocator.dupe(u8,
        \\precedence stable_group
        \\ below addition
        \\ above path
        \\end
        \\export stable_group
        \\param n=-(9223372036854775808)
        \\answer:=-(9223372036854775808)
    );
    var diagnostic: ?Diagnostic = null;
    var program = compile(allocator, original, "owned-precedence.huak", .{}, &diagnostic) catch |err| {
        allocator.free(original);
        return err;
    };
    allocator.free(original);
    defer program.deinit();
    const group = program.groups[program.exports[0].target.precedence];
    try std.testing.expectEqualStrings("stable_group", group.name);
    try std.testing.expectEqual(ast.Associativity.none, group.associativity);
    var machine = try @import("Machine.zig").init(allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(std.math.minInt(i64), machine.getGlobal("answer").?.int);
    try std.testing.expectEqual(std.math.minInt(i64), machine.getGlobal("n").?.int);
}

test "imported global exports retain value syntax over a same-named private prefix" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !ResolvedSource {
            return .{ .name = "dependency.huak", .source =
            \\fn same(x:int)->int;return x;end
            \\mixfix(same) same _ in unary
            \\same:=0; if true then;same=3;end
            \\export same
            };
        }
    };
    var context: u8 = 0;
    const resolver: ImportResolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } };
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, "import \"dependency\" as values\nanswer:=values.same+1", "root.huak", .{ .optimize = optimize, .import_resolver = resolver }, &diagnostic);
        defer program.deinit();
        var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(i64, 4), machine.getGlobal("answer").?.int);
    }
    var diagnostic: ?Diagnostic = null;
    try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, "import \"dependency\" as values\nanswer:=values.same(1)", "private-call.huak", .{ .import_resolver = resolver }, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "not callable") != null);
}

fn prefixDrawingAllocationExercise(allocator: std.mem.Allocator) !void {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(allocator,
        \\expand_block drawing(target:picture)
        \\    ...
        \\    return target
        \\end
        \\import object.{fill, draw}; import geometry.reverse
        \\mixfix(draw) draw _ in logical_or
        \\export paint
        \\mixfix(paint) paint _ in logical_or
        \\fn paint(p:path)->object;return fill(p);end
        \\mixfix(reverse) reverse _ in unary
        \\export pic:=picture(640, 480)
        \\curve:=path((0,0),(10,10))
        \\drawing pic do
        \\ draw reverse curve
        \\ drawing pic do;paint curve;end
        \\end
    , "allocation-prefix.huak", .{}, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(precedence.builtinId(.logical_or), program.exports[0].mixfix[0].?.group);
    try std.testing.expectEqual(@as(usize, 4), program.functions[program.entry].local_types.len);
}

test "prefix declarations and drawing targets release every failed compilation allocation" {
    try prefixDrawingAllocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), prefixDrawingAllocationExercise, .{});
}

fn infixAllocationExercise(allocator: std.mem.Allocator) !void {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(allocator,
        \\precedence transform
        \\ below addition
        \\ above path
        \\ associativity left
        \\end
        \\mixfix(combine) _ combine _ in transform
        \\export transform
        \\export combine
        \\fn combine(a:int,b:int)->int;return a*10+b;end
        \\result:=1 combine 2+1 combine 4
    , "allocation-infix.huak", .{}, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(@as(usize, 2), program.exports.len);
    var machine = try @import("Machine.zig").init(allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 134), machine.getGlobal("result").?.int);
}

test "infix compilation metadata and execution release every failed allocation" {
    try infixAllocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), infixAllocationExercise, .{});
}

test "exports retain named global visibility without adding execution instructions" {
    var diagnostic: ?Diagnostic = null;
    var exported = try compile(std.testing.allocator,
        \\export later
        \\export title:="first"
        \\later:=3
        \\title="last"
        \\hidden:=7
    , "exports.huak", .{}, &diagnostic);
    defer exported.deinit();
    var ordinary = try compile(std.testing.allocator,
        \\title:="first"
        \\later:=3
        \\title="last"
        \\hidden:=7
    , "ordinary.huak", .{}, &diagnostic);
    defer ordinary.deinit();
    try std.testing.expectEqual(@as(usize, 2), exported.exports.len);
    try std.testing.expectEqualStrings("later", exported.exports[0].name);
    try std.testing.expectEqualStrings("title", exported.exports[1].name);
    for (exported.exports) |item| {
        try std.testing.expectEqualStrings(item.name, exported.global_names[item.target.global]);
        try std.testing.expect(std.mem.startsWith(u8, exported.source_text[item.span.start..item.span.end], "export "));
    }
    try std.testing.expectEqualSlices(Type, ordinary.global_types, exported.global_types);
    try std.testing.expectEqual(ordinary.constants.len, exported.constants.len);
    for (ordinary.constants, exported.constants) |expected, actual| try std.testing.expectEqualDeep(expected, actual);
    const ordinary_code = ordinary.functions[0].code;
    const exported_code = exported.functions[0].code;
    try std.testing.expectEqual(ordinary_code.len, exported_code.len);
    for (ordinary_code, exported_code) |expected, actual| {
        try std.testing.expectEqual(expected.op, actual.op);
        try std.testing.expectEqual(expected.a, actual.a);
        try std.testing.expectEqual(expected.b, actual.b);
    }
}

test "exports reject duplicate unknown and non-top-level declarations" {
    const cases = [_]struct { code: []const u8, message: []const u8 }{
        .{ .code = "export missing", .message = "unknown exported variable" },
        .{ .code = "export f\nfn other();end", .message = "unknown exported variable" },
        .{ .code = "export x:=1;export x", .message = "duplicate export" },
        .{ .code = "default picture();default picture()", .message = "duplicate default output" },
        .{ .code = "if true then;export x:=1;end", .message = "script top level" },
        .{ .code = "while false do;export x:=1;end", .message = "script top level" },
        .{ .code = "for i in 1:2 do;export x:=i;end", .message = "script top level" },
        .{ .code = "fn f();export x:=1;end", .message = "script top level" },
        .{ .code = "fn f();default 1;end", .message = "script top level" },
        .{ .code = "export fn f();end;export f", .message = "duplicate export" },
        .{ .code = "x:=1;export x,x", .message = "duplicate export" },
        .{ .code = "x:=1;export x,missing", .message = "unknown exported variable" },
        .{ .code = "if true then;export fn f();end;end", .message = "script top level" },
        .{ .code = "fn f();export fn nested();end;end", .message = "script top level" },
        .{ .code = "export plate:=1;export plate;default plate", .message = "duplicate export" },
        .{ .code = "if true then;export plate:=1;default plate;end", .message = "script top level" },
    };
    for (cases) |case| {
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, case.code, "invalid-export.huak", .{}, &diagnostic));
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), case.message) != null);
    }
}

test "default output is picture-only and independent from module exports" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator, "private:=picture(); default private", "output.huak", .{}, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(@as(usize, 0), program.exports.len);
    try std.testing.expectEqual(@as(usize, 2), program.outputs.len);
    try std.testing.expectEqualStrings("private", program.outputs[0].name);
    try std.testing.expectEqualStrings("default", program.outputs[1].name);
    try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, "default 1", "invalid.huak", .{}, &diagnostic));
}

test "function export modifiers and mixed export lists reuse ordinary compilation" {
    const modified =
        \\precedence stage below addition; above path; associativity left end
        \\mixfix(double) double _ in unary
        \\mixfix(combined) _ combined _ in stage
        \\export fn double(x:int)->int return x*2 end
        \\fn combined(a:int,b:int)->int return a*10+b end
        \\value:=double(3)
        \\export value,combined,stage
    ;
    const ordinary =
        \\precedence stage below addition; above path; associativity left end
        \\mixfix(double) double _ in unary
        \\mixfix(combined) _ combined _ in stage
        \\fn double(x:int)->int return x*2 end
        \\fn combined(a:int,b:int)->int return a*10+b end
        \\value:=double(3)
        \\export double
        \\export value
        \\export combined
        \\export stage
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var direct = try compile(std.testing.allocator, modified, "modified.huak", .{ .optimize = optimize }, &diagnostic);
        defer direct.deinit();
        var separate = try compile(std.testing.allocator, ordinary, "ordinary.huak", .{ .optimize = optimize }, &diagnostic);
        defer separate.deinit();
        try std.testing.expectEqual(@as(usize, 4), direct.exports.len);
        try std.testing.expectEqual(direct.exports[0].mixfix[0].?.group, separate.exports[0].mixfix[0].?.group);
        try std.testing.expectEqual(direct.exports[2].mixfix[1].?.group, separate.exports[2].mixfix[1].?.group);
        for (direct.exports, separate.exports) |actual, expected| {
            try std.testing.expectEqualStrings(expected.name, actual.name);
            try std.testing.expectEqualDeep(expected.target, actual.target);
        }
        for (direct.functions, separate.functions) |actual, expected| {
            try std.testing.expectEqual(expected.code.len, actual.code.len);
            for (actual.code, expected.code) |a, b| {
                try std.testing.expectEqual(b.op, a.op);
                try std.testing.expectEqual(b.a, a.a);
                try std.testing.expectEqual(b.b, a.b);
            }
        }
    }
}

test "selected data imports shadow calls while explicit function aliases remain available" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !ResolvedSource {
            return .{ .name = "data.huak", .source = "export sin:=7" };
        }
    };
    var context: u8 = 0;
    var diagnostic: ?Diagnostic = null;
    const resolver: ImportResolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } };
    var program = try compile(std.testing.allocator, "import math.sin as sine; import \"data.huak\".sin; value:=sin; angle:=sine(0)", "root.huak", .{ .import_resolver = resolver }, &diagnostic);
    defer program.deinit();
    var builtin_calls: usize = 0;
    for (program.functions[program.entry].code) |instruction| if (instruction.op == .call_builtin) {
        try std.testing.expectEqual(@backingInt(builtin.lookup("sin").?.id), instruction.a);
        builtin_calls += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), builtin_calls);
    try std.testing.expectEqual(Type.int, testGlobalType(&program, "value"));
    try std.testing.expectEqual(Type.number, testGlobalType(&program, "angle"));
    try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, "import math.sin; import \"data.huak\".sin; value:=sin(0)", "shadowed.huak", .{ .import_resolver = resolver }, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "not callable") != null);
}

test "variadic functions own their argument list and retain shallow element references" {
    const input =
        \\shared:=[1]
        \\empty:=gather()
        \\mixed:=gather(shared,2)
        \\shared+=8
        \\coerced:=numbers(1,2.5)
        \\prefixed:=3.with_tail(4,5)
        \\fn gather(values...)->list
        \\    values+=9
        \\    return values
        \\end
        \\fn numbers(values:float...)->list return values end
        \\fn with_tail(head:int,tail:int...)->list return [head,tail] end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "variadic.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        const gather = program.functions[1];
        try std.testing.expectEqual(Type.any, gather.variadic.?);
        try std.testing.expectEqual(@as(usize, 0), gather.fixedCount());
        try std.testing.expectEqual(Type.list, gather.parameters[0]);
        var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        const sequence = @import("types.zig").sequence;
        try std.testing.expectEqual(@as(usize, 1), sequence(machine.getGlobal("empty").?).?.len);
        const mixed = sequence(machine.getGlobal("mixed").?).?;
        try std.testing.expectEqual(@as(usize, 3), mixed.len);
        try std.testing.expectEqual(@as(usize, 2), sequence(mixed[0]).?.len);
        try std.testing.expectEqual(@as(usize, 2), sequence(machine.getGlobal("shared").?).?.len);
        const coerced = sequence(machine.getGlobal("coerced").?).?;
        try std.testing.expectEqual(@as(f64, 1), coerced[0].number);
        try std.testing.expectEqual(@as(f64, 2.5), coerced[1].number);
        const prefixed = sequence(machine.getGlobal("prefixed").?).?;
        try std.testing.expectEqual(@as(i64, 3), prefixed[0].int);
        const tail = sequence(prefixed[1]).?;
        try std.testing.expectEqual(@as(i64, 4), tail[0].int);
        try std.testing.expectEqual(@as(i64, 5), tail[1].int);
    }
}

test "variadic aliases preserve ordinary dot prefix and infix call roles" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !ResolvedSource {
            return .{ .name = "library.huak", .source =
            \\export fn count(values:int...)->int return len(values) end
            \\mixfix(count) count _ in unary
            \\export fn plus(head:int,tail:int...)->int return head+tail[0] end
            \\mixfix(plus) _ plus _ in addition
            };
        }
    };
    var context: u8 = 0;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator,
            \\import "library.huak".{count as size,plus as combine}
            \\a:=size(1,2,3)
            \\b:=count 9
            \\c:=4.combine(6,7)
            \\d:=4 plus 6
        , "root.huak", .{ .optimize = optimize, .import_resolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } } }, &diagnostic);
        defer program.deinit();
        var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(i64, 3), machine.getGlobal("a").?.int);
        try std.testing.expectEqual(@as(i64, 1), machine.getGlobal("b").?.int);
        try std.testing.expectEqual(@as(i64, 10), machine.getGlobal("c").?.int);
        try std.testing.expectEqual(@as(i64, 10), machine.getGlobal("d").?.int);
    }
}

test "variadic calls check fixed prefixes and declared element types" {
    const invalid = [_][]const u8{
        "fn f(head:int,tail:vec2...);end;f()",
        "fn f(head:int,tail:vec2...);end;f(1,2)",
        "fn f(values:missing...);end",
        "fn f(a:int,b:int,c:int,rest...);end;mixfix(f) _ f _ in addition",
        "fn f(a:int,b:int,c:int,rest...);end;mixfix(f) f _ in unary",
    };
    for (invalid) |input| {
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "invalid-variadic.huak", .{}, &diagnostic));
        try std.testing.expect(diagnostic != null);
    }
}

test "reexported operator groups must agree when the same function is imported twice" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (std.mem.eql(u8, path, "base")) return .{ .name = "base.huak", .source = "export fn f(a:int,b:int)->int return a+b end;mixfix(f) _ f _ in addition" };
            return .{ .name = "bridge.huak", .source = "import \"base\".f;mixfix(f) _ f _ in multiplication;export f" };
        }
    };
    var context: u8 = 0;
    for ([_][]const u8{ "import \"base\".f;import \"bridge\".f", "import \"bridge\".f;import \"base\".f" }) |input| {
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "root.huak", .{ .import_resolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } } }, &diagnostic));
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "conflicting imported operator roles") != null);
    }
}

test "parameter defaults infer supported types without changing explicit annotations" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator,
        \\param path="."
        \\param count=-3
        \\param size=2.5
        \\param enabled=not false
        \\param angle=3.141592653589793
        \\param wide:float=1
        \\param required:int
        \\export count
    , "inferred-param.huak", .{}, &diagnostic);
    defer program.deinit();
    const expected = [_]Type{ .string, .int, .number, .boolean, .number, .number, .int };
    try std.testing.expectEqual(expected.len, program.parameters.len);
    for (expected, program.parameters) |kind, parameter| {
        try std.testing.expectEqual(kind, parameter.kind);
        try std.testing.expect(program.readonly_globals[parameter.global]);
    }
    try std.testing.expect(program.parameters[6].default == null);
    const invalid = [_][]const u8{ "param x=1/0", "param x=sin(1)", "param x=[1]", "param x=(1,2)", "param x=missing", "param x:any=1", "param x=\"str\";x=\"other\"" };
    for (invalid) |input| {
        diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "bad-param.huak", .{}, &diagnostic));
        try std.testing.expect(diagnostic != null);
    }
}

test "compiler resolves recursive and forward functions to linear code" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator, "param n:int=6\nanswer:=fact(n)\nfn fact(x:int)->int\nif x<=1 then; return 1; end\nreturn x*fact(x-1)\nend\n", "test.huak", .{}, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(@as(usize, 2), program.functions.len);
    try std.testing.expectEqual(@as(usize, 1), program.parameters.len);
    try std.testing.expect(program.readonly_globals[program.parameters[0].global]);
    var calls: usize = 0;
    for (program.functions) |function| for (function.code) |instruction| if (instruction.op == .call) {
        calls += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), calls);
}

test "compile errors identify invalid symbols types and control flow" {
    const cases = [_][]const u8{ "x:=missing\n", "x:wrong:=1\n", "break\n", "return 1\n", "param n:int=2\nn=3\n", "fn f(x:int)->int;return true;end\n", "x:=sin(1,2)\n", "fn f()->int;x:=2;end\n" };
    for (cases) |input| {
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "invalid.huak", .{}, &diagnostic));
        try std.testing.expect(diagnostic != null);
        try std.testing.expect(diagnostic.?.text().len != 0);
    }
}

test "lowered loops and short circuit contain bounded explicit jumps" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator,
        \\n:=0
        \\for i in 1:2:7 do
        \\  if i==3 then; continue; end
        \\  n=n+i
        \\  if n>8 then; break; end
        \\end
        \\while n<20 do
        \\  n=n+1
        \\end
        \\a := false and (1/0 > 0)
        \\b := true or (1/0 > 0)
    , "loops.huak", .{}, &diagnostic);
    defer program.deinit();
    var range_tests: usize = 0;
    var range_advances: usize = 0;
    for (program.functions[0].code) |instruction| switch (instruction.op) {
        .jump, .jump_if_false => try std.testing.expect(instruction.a < program.functions[0].code.len),
        .iterate_test => range_tests += 1,
        .iterate_advance => range_advances += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), range_tests);
    try std.testing.expectEqual(@as(usize, 1), range_advances);
}

test "signed minimum literal defaults and owned source survive caller storage" {
    var input = "param n:int=-9223372036854775808\nx:=n\n".*;
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator, &input, "owned.huak", .{}, &diagnostic);
    defer program.deinit();
    @memset(&input, 'x');
    try std.testing.expectEqual(std.math.minInt(i64), program.parameters[0].default.?.int);
    try std.testing.expectEqualStrings("n", program.parameters[0].name);
    try std.testing.expect(std.mem.startsWith(u8, program.source_text, "param n:"));
    try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, "x:=9223372036854775808\n", "overflow.huak", .{}, &diagnostic));
}

test "decoded strings outlive the temporary syntax arena" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator, "param title:string=\"中文\\n\"\nx:=\"\\u03bb\"\n", "strings.huak", .{}, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqualStrings("中文\n", program.parameters[0].default.?.string);
    try std.testing.expectEqualStrings("λ", program.constants[0].string);
}

test "declarations cannot hide in conditional scopes and annotations remain stable" {
    const cases = [_][]const u8{
        "if true then; param n:int=1; end\n",
        "if true then; fn f(); end; end\n",
        "x:int:=1\nx=1.5\n",
        "for i in 1:0.5:2 do; end\ni=true\n",
        "fn f(x:int)->int;return x;end\ny:=f(false)\n",
        "p:=(1,2)\nx:=p.width\n",
    };
    for (cases) |input| {
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "types.huak", .{}, &diagnostic));
        try std.testing.expect(diagnostic != null);
    }
}

test "qualified native calls preserve data names and native member result types" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator,
        \\param scale:float=1.5
        \\matrix:=transform.scale(scale)
        \\s:=solver(); result:=solver.solve(s)
        \\status:string:=result.status
        \\rank:int:=result.rank
    , "names.huak", .{}, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(Type.number, testGlobalType(&program, "scale"));
    try std.testing.expectEqual(Type.transform, testGlobalType(&program, "matrix"));
    try std.testing.expectEqual(Type.string, testGlobalType(&program, "status"));
    try std.testing.expectEqual(Type.int, testGlobalType(&program, "rank"));
}

test "explicit and dynamic any values do not acquire a later incidental type" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator,
        \\a:any:=1
        \\a="later"
        \\b:=[1][0]
        \\b="later"
        \\result:=echo(1)
        \\fn echo(x:any)->any
        \\  x="changed"
        \\  return x
        \\end
    , "dynamic.huak", .{}, &diagnostic);
    defer program.deinit();
    for (program.global_types) |kind| try std.testing.expectEqual(Type.any, kind);
    try std.testing.expectEqual(Type.any, program.functions[1].local_types[0]);
}

test "range inference preserves dynamic bounds and known integer or floating types" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator,
        \\values:=[1,2,1]
        \\for a in values[0]:2 do; end
        \\for b in 1:values[1] do; end
        \\for c in 1:values[2]:2 do; end
        \\for d in 1.0:values[1] do; end
        \\for e in 1:2 do; end
        \\for f in 1:0.5:2 do; end
    , "range-types.huak", .{}, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqualSlices(Type, &.{.list}, program.global_types);
    try std.testing.expectEqualSlices(Type, &.{ .any, .any, .any, .any, .int, .number }, program.functions[program.entry].local_types[0..6]);
}

test "unary positive preserves variable handles while negation produces linear expressions" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator, "import solver.{solver, unknown}\ns:=solver(); x:=unknown(s); positive:=+x; negative:=-x", "sign.huak", .{}, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(Type.variable, testGlobalType(&program, "positive"));
    try std.testing.expectEqual(Type.linear, testGlobalType(&program, "negative"));
}

test "string ordering agrees with the VM typed comparison surface" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator, "ordered:=\"a\"<\"b\"\n", "strings.huak", .{}, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(Type.boolean, program.global_types[0]);
    try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, "ordered:=\"a\"<1\n", "strings.huak", .{}, &diagnostic));
}

test "long left associative trees report a compilation limit instead of exhausting the stack" {
    var input: std.array_list.Managed(u8) = .init(std.testing.allocator);
    defer input.deinit();
    try input.appendSlice("value:=1");
    for (0..2000) |_| try input.appendSlice("+1");
    try input.append('\n');
    var diagnostic: ?Diagnostic = null;
    try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input.items, "long.huak", .{}, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "compilation depth") != null);
}

test "dot calls compile exactly like free builtin forward and recursive calls" {
    var diagnostic: ?Diagnostic = null;
    var dotted = try compile(std.testing.allocator,
        \\import math.{pow, sqrt}
        \\values:=[2,3]
        \\a:=(1+2).pow(3).sqrt()
        \\b:=values[0].combine(4)
        \\c:=4.factorial()
        \\fn combine(x:int,y:int)->int; return x*10+y; end
        \\fn factorial(x:int)->int
        \\  if x<=1 then; return 1; end
        \\  return x*(x-1).factorial()
        \\end
    , "dot.huak", .{}, &diagnostic);
    defer dotted.deinit();
    var free = try compile(std.testing.allocator,
        \\import math.{pow, sqrt}
        \\values:=[2,3]
        \\a:=sqrt(pow(1+2,3))
        \\b:=combine(values[0],4)
        \\c:=factorial(4)
        \\fn combine(x:int,y:int)->int; return x*10+y; end
        \\fn factorial(x:int)->int
        \\  if x<=1 then; return 1; end
        \\  return x*factorial(x-1)
        \\end
    , "free.huak", .{}, &diagnostic);
    defer free.deinit();
    try std.testing.expectEqualSlices(Type, free.global_types, dotted.global_types);
    try std.testing.expectEqual(free.constants.len, dotted.constants.len);
    for (free.constants, dotted.constants) |expected, actual| try std.testing.expectEqualDeep(expected, actual);
    try std.testing.expectEqual(free.functions.len, dotted.functions.len);
    for (free.functions, dotted.functions) |expected, actual| {
        try std.testing.expectEqual(expected.code.len, actual.code.len);
        for (expected.code, actual.code) |free_instruction, dot_instruction| {
            try std.testing.expectEqual(free_instruction.op, dot_instruction.op);
            try std.testing.expectEqual(free_instruction.a, dot_instruction.a);
            try std.testing.expectEqual(free_instruction.b, dot_instruction.b);
        }
    }
}

test "dot calls share unknown function arity and type diagnostics with free calls" {
    const cases = [_]struct { dotted: []const u8, free: []const u8 }{
        .{ .dotted = "p:=(1,2); p.missing()", .free = "p:=(1,2); missing(p)" },
        .{ .dotted = "p:=(1,2); p.x()", .free = "p:=(1,2); x(p)" },
        .{ .dotted = "import math.sin; 2.sin(3)", .free = "import math.sin; sin(2,3)" },
        .{ .dotted = "import math.min; 2.min()", .free = "import math.min; min(2)" },
        .{ .dotted = "import math.sin; \"bad\".sin()", .free = "import math.sin; sin(\"bad\")" },
        .{ .dotted = "import text.width; 1.width()", .free = "import text.width; width(1)" },
        .{ .dotted = "1.f()\nfn f(x:int,y:int);end", .free = "f(1)\nfn f(x:int,y:int);end" },
        .{ .dotted = "false.f()\nfn f(x:int);end", .free = "f(false)\nfn f(x:int);end" },
    };
    for (cases) |case| {
        var dotted: ?Diagnostic = null;
        var free: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, case.dotted, "dot.huak", .{}, &dotted));
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, case.free, "free.huak", .{}, &free));
        try std.testing.expectEqualStrings(free.?.text(), dotted.?.text());
    }
}

test "properties stay distinct from dot calls with explicitly aliased functions" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator,
        \\import text.{width, height, baseline}; import math.sin as sine; import solver.{solver, solve}
        \\sin:=99
        \\a:=1.sine()
        \\fn metrics(t:text)->length
        \\  return t.width+t.width()+t.height+t.height()+t.baseline+t.baseline()
        \\end
        \\fn status(s:solution)->string; return s.status; end
        \\s:=solver().solve()
        \\tag:=s.status()
        \\point:=(2,3)
        \\coordinate:=point.x
        \\custom:=point.x()
        \\fn x(p:vec2)->float; return p.y; end
    , "members.huak", .{}, &diagnostic);
    defer program.deinit();
    const expected = [_]Type{ .int, .number, .solution, .string, .vec2, .scalar, .number };
    for (expected, [_][]const u8{ "sin", "a", "s", "tag", "point", "coordinate", "custom" }) |kind, name| try std.testing.expectEqual(kind, testGlobalType(&program, name));
}

const ModuleTestSources = struct {
    fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
        const files = [_]ResolvedSource{
            .{ .name = "left.huak", .source = "import \"shared.huak\" as shared\nexport get\nfn get()->int;return shared.get();end" },
            .{ .name = "right.huak", .source = "import \"shared.huak\" as shared\nexport get\nfn get()->int;return shared.get();end" },
            .{ .name = "shared.huak", .source = "param count=3\nprint(\"initialized\")\nexport get\nfn get()->int;return count;end" },
        };
        for (files) |file| if (std.mem.eql(u8, file.name, path)) return file;
        return error.FileNotFound;
    }
    fn count(ctx: ?*anyopaque, _: std.mem.Allocator, id: builtin.Id, args: []const Value, _: ?*@import("Machine.zig")) !Value {
        if (id != .print or args.len != 1) return error.UnexpectedBuiltin;
        const calls: *usize = @ptrCast(@alignCast(ctx.?));
        calls.* += 1;
        return .unit;
    }
};

fn moduleAllocationExercise(allocator: std.mem.Allocator) !void {
    var marker: u8 = 0;
    var diagnostic: ?Diagnostic = null;
    var program = try compile(allocator,
        \\import "left.huak" as left
        \\import "right.huak" as right
        \\export result:=left.get()+right.get()
    , "root.huak", .{ .import_resolver = .{ .ptr = &marker, .vtable = &.{ .resolve = ModuleTestSources.resolve } } }, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(@as(usize, 4), program.modules.len);
    var calls: usize = 0;
    for (0..2) |_| {
        var machine = try @import("Machine.zig").init(allocator, &program, .{ .ptr = &calls, .vtable = &.{ .call_builtin = ModuleTestSources.count } }, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(i64, 6), machine.getGlobal("result").?.int);
        try std.testing.expect(machine.getGlobal("count") == null);
    }
    try std.testing.expectEqual(@as(usize, 2), calls);
}

test "diamond imports initialize once per execution and release every allocation failure" {
    try moduleAllocationExercise(std.testing.allocator);
    // Arena growth can resize in place depending on the backing heap layout.
    // Disable backing resizes so every allocation-failure run has the same work.
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), moduleAllocationExercise, .{});
}

test "task planning proves loop builders and transitive captures with and without optimization" {
    const input =
        \\import object.draw
        \\param offset:int=4
        \\a:=figure(1)
        \\b:=figure(2)
        \\fn coordinate(n:int)->int
        \\  return n+offset
        \\end
        \\fn figure(index:int)->picture
        \\  p:=picture(640, 480)
        \\  alias:=p
        \\  for i in 0:2 do
        \\    object.append(alias, draw(path((i,0),(coordinate(index),10))))
        \\  end
        \\  return p
        \\end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "task-loops.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, 1), program.task_regions.len);
        const region = program.task_regions[0];
        try std.testing.expectEqual(@as(usize, 2), region.tasks.len);
        try std.testing.expectEqual(region.tasks[0].start, region.start);
        try std.testing.expectEqual(region.tasks[1].end + 1, region.end);
        for (region.tasks) |task| {
            try std.testing.expectEqualSlices(u32, &.{0}, task.reads);
            try std.testing.expectEqual(bc.Op.store_global, program.functions[task.function].code[task.end].op);
            try std.testing.expectEqual(task.global, program.functions[task.function].code[task.end].a);
        }
    }
}

test "list append is a task boundary without consuming following picture calls" {
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator,
            \\values:=[]
            \\values+=1
            \\first:=figure()
            \\second:=figure()
            \\fn figure()->picture
            \\    return picture(640, 480)
            \\end
            \\
        , "list-task-boundary.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, 1), program.task_regions.len);
        try std.testing.expectEqual(@as(usize, 2), program.task_regions[0].tasks.len);
    }
}

test "task planning records earlier picture producers and reads through helper captures" {
    const input =
        \\import object.{draw, append}
        \\base:=figure(0)
        \\a:=duplicate(base)
        \\b:=captured()
        \\fn figure(index:int)->picture
        \\  p:=picture(640, 480)
        \\  object.append(p, draw(path((index,0),(10,10))))
        \\  return p
        \\end
        \\fn duplicate(source:picture)->picture
        \\  p:=picture(640, 480)
        \\  append(p, copy(source))
        \\  return p
        \\end
        \\fn captured()->picture
        \\  return duplicate(a)
        \\end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "task-dag.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, 1), program.task_regions.len);
        const tasks = program.task_regions[0].tasks;
        try std.testing.expectEqual(@as(usize, 3), tasks.len);
        try std.testing.expectEqual(@as(usize, 0), tasks[0].reads.len);
        try std.testing.expectEqualSlices(u32, &.{tasks[0].global}, tasks[1].reads);
        try std.testing.expectEqualSlices(u32, &.{tasks[1].global}, tasks[2].reads);
    }
}

test "picture metadata and compound subpaths remain read-only worker inputs" {
    const input =
        \\import geometry.{compound, subpaths, rectangle}; import object.{region}; import object.fill
        \\source:=picture(80mm,40mm)
        \\first:=copy(source)
        \\second:=copy(source)
        \\fn copy(source:picture)->picture
        \\    result:=picture(source.width,source.height)
        \\    animated:bool:=source.animated
        \\    if not animated then
        \\        shape:=compound(subpaths(region(compound([rectangle((0mm,0mm),2mm,3mm),rectangle((4mm,0mm),2mm,3mm)]))))
        \\        object.append(result, fill(shape))
        \\    end
        \\    return result
        \\end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "picture-metadata.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, 1), program.task_regions.len);
        try std.testing.expectEqual(@as(usize, 2), program.task_regions[0].tasks.len);
        for (program.task_regions[0].tasks) |task| {
            try std.testing.expect(!task.uses_typst);
            try std.testing.expectEqualSlices(u32, &.{0}, task.reads);
        }
        var invalid: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, "p:=picture(640, 480); x:=p.baseline; ", "picture-metadata-invalid.huak", .{ .optimize = optimize }, &invalid));
        try std.testing.expect(std.mem.indexOf(u8, invalid.?.text(), "picture has no member 'baseline'") != null);
    }
}

test "outline effects distinguish geometry from possibly typeset pictures and dynamic inputs" {
    for ([_]struct { kind: []const u8, value: []const u8, safe: bool, uses_typst: bool }{
        .{ .kind = "path", .value = "rectangle((0,0),10,10)", .safe = true, .uses_typst = false },
        .{ .kind = "object", .value = "picture()", .safe = true, .uses_typst = true },
        .{ .kind = "any", .value = "picture()", .safe = false, .uses_typst = false },
    }) |fixture| for ([_]bool{ false, true }) |optimize| {
        const input = try std.fmt.allocPrint(std.testing.allocator,
            \\import geometry.{{rectangle}}; import object.{{outlines}}; import object.append
            \\source:={s}
            \\first:=copy(source)
            \\second:=copy(source)
            \\fn copy(source:{s})->picture
            \\    result:=picture(640, 480)
            \\    shapes:object:=outlines(source)
            \\    append(result, shapes)
            \\    return result
            \\end
        , .{ fixture.value, fixture.kind });
        defer std.testing.allocator.free(input);
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "outline-effects.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, if (fixture.safe) 1 else 0), program.task_regions.len);
        if (fixture.safe) for (program.task_regions[0].tasks) |task| {
            try std.testing.expectEqual(fixture.uses_typst, task.uses_typst);
        };
    };
}

test "task planning rejects alias returns external mutations and observable effects" {
    const bodies = [_][]const u8{
        "return source",
        "object.append(source, draw(path((0,0),(1,1))));return picture(640, 480)",
        "object.append(captured, draw(path((0,0),(1,1))));return picture(640, 480)",
        "p:=picture(640, 480);if flag then;p=source;end;object.append(p, draw(path((0,0),(1,1))));return p",
        "p:=picture(640, 480);while flag do;p=source;flag:=false;end;object.append(p, draw(path((0,0),(1,1))));return p",
        "print(1);return picture(640, 480)",
        "s:=solver();return picture(640, 480)",
        "xs:=[];xs+=1;return picture(640, 480)",
        "aliases:=[source];object.append(aliases[0], draw(path((0,0),(1,1))));return picture(640, 480)",
        "aliases:=[source];return aliases[0]",
    };
    for (bodies) |body| for ([_]bool{ false, true }) |optimize| {
        const input = try std.fmt.allocPrint(std.testing.allocator, "import object.draw; import solver.solver\ncaptured:=picture(640, 480)\na:=build(captured,true)\nb:=build(captured,false)\nfn build(source:picture,flag:bool)->picture\n{s}\nend", .{body});
        defer std.testing.allocator.free(input);
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "task-effects.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, 0), program.task_regions.len);
    };
}

test "task planning preserves barriers duplicate writes and basic block boundaries" {
    const input =
        \\param flag:bool=true
        \\d:=picture(); e:=picture(); a:=figure()
        \\b:=figure()
        \\print(0)
        \\a=figure()
        \\c:=figure()
        \\if flag then
        \\  d=figure()
        \\  e=figure()
        \\end
        \\f:=figure()
        \\g:=figure()
        \\fn figure()->picture;return picture(640, 480);end
        \\
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "task-boundaries.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, 4), program.task_regions.len);
        for (program.task_regions) |region| {
            try std.testing.expectEqual(@as(usize, 2), region.tasks.len);
            for (program.functions[region.function].code) |instruction| {
                if (instruction.op == .jump or instruction.op == .jump_if_false)
                    try std.testing.expect(instruction.a <= region.start or instruction.a >= region.end);
            }
        }
        var repeated = try compile(std.testing.allocator, "a:=figure()\nb:=figure()\na=figure()\nc:=figure()\nfn figure()->picture;return picture(640, 480);end;", "task-repeated-writer.huak", .{ .optimize = optimize }, &diagnostic);
        defer repeated.deinit();
        try std.testing.expectEqual(@as(usize, 2), repeated.task_regions.len);
        for (repeated.task_regions) |region| {
            try std.testing.expectEqual(@as(usize, 2), region.tasks.len);
            try std.testing.expect(region.tasks[0].global != region.tasks[1].global);
        }
    }
}

test "drawing instances have a dedicated type and no last-object query" {
    const invalid = [_][]const u8{
        "picture.object_id(picture(640, 480))",
        "import picture.object_id",
        "animation.animate(picture(640, 480),1,\"opacity\",[[0,0],[1,1]])",
        "animation.motion(picture(640, 480),1,path((0,0),(10,0)),[[0,0],[1,1]])",
        "p:=picture(640, 480); n:int:=object.append(p, object.draw(path((0,0),(10,0))))",
        "p:=picture(640, 480); o:=object.append(p, object.draw(path((0,0),(10,0)))); n:=o+1",
    };
    for ([_]bool{ false, true }) |optimize| for (invalid) |input| {
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "object-type.huak", .{ .optimize = optimize }, &diagnostic));
        try std.testing.expect(diagnostic != null);
    };
}

test "task planning distinguishes stable object display from allocation identity" {
    const suffixes = [_][]const u8{
        "s:=str(a)",
        "s:=str([a])",
        "print(a)",
        "print([a])",
        "fn unused(p:picture)->string;return str(p);end",
        "s:=str(path((0,0),(1,1)))",
    };
    for (suffixes) |suffix| for ([_]bool{ false, true }) |optimize| {
        const input = try std.fmt.allocPrint(std.testing.allocator, "a:=figure()\nb:=figure()\nfn figure()->picture\ntemporary:=picture(640, 480)\nreturn picture(640, 480)\nend\n{s}", .{suffix});
        defer std.testing.allocator.free(input);
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "task-identity.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        const observes_allocation = std.mem.indexOf(u8, suffix, "[a]") != null or std.mem.indexOf(u8, suffix, "path(") != null;
        try std.testing.expectEqual(@as(usize, if (observes_allocation) 0 else 1), program.task_regions.len);
    };
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator, "n:=str(12)\ns:=str(\"ok\")\na:=figure()\nb:=figure()\nfn figure()->picture;return picture(640, 480);end;", "task-simple-str.huak", .{}, &diagnostic);
    defer program.deinit();
    try std.testing.expectEqual(@as(usize, 1), program.task_regions.len);
}

test "task planning skips ordinary scripts without allocating and bounds helper graph work" {
    var diagnostic: ?Diagnostic = null;
    var ordinary = try compile(std.testing.allocator, "n:=1\nfn unused()->picture;return picture(640, 480);end;", "task-no-candidates.huak", .{}, &diagnostic);
    defer ordinary.deinit();
    var no_allocations = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const regions = try task_plan.build(no_allocations.allocator(), no_allocations.allocator(), &ordinary);
    try std.testing.expectEqual(@as(usize, 0), regions.len);
    var single = try compile(std.testing.allocator, "a:=figure()\nfn figure()->picture;return picture(640, 480);end;", "task-one-candidate.huak", .{}, &diagnostic);
    defer single.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try task_plan.build(no_allocations.allocator(), no_allocations.allocator(), &single)).len);

    // A reverse dependency chain needs one summary round per helper. Exceeding
    // the proof budget must preserve valid source as ordinary serial bytecode.
    const count = @import("tasks/effects.zig").limits.rounds + 2;
    var source_text: std.ArrayList(u8) = .empty;
    defer source_text.deinit(std.testing.allocator);
    try source_text.appendSlice(std.testing.allocator, "a:=f0()\nb:=f0()\n");
    for (0..count) |index| {
        const declaration = if (index + 1 == count)
            try std.fmt.allocPrint(std.testing.allocator, "fn f{d}()->picture;return picture(640, 480);end\n", .{index})
        else
            try std.fmt.allocPrint(std.testing.allocator, "fn f{d}()->picture;return f{d}();end\n", .{ index, index + 1 });
        defer std.testing.allocator.free(declaration);
        try source_text.appendSlice(std.testing.allocator, declaration);
    }
    try source_text.appendSlice(std.testing.allocator, "");
    var bounded = try compile(std.testing.allocator, source_text.items, "task-bounded-analysis.huak", .{}, &diagnostic);
    defer bounded.deinit();
    try std.testing.expectEqual(@as(usize, 0), bounded.task_regions.len);
}

test "mixfix uses ordinary bytecode and evaluates argument slots once in order" {
    const declarations =
        \\mixfix(combine) combine from _ with _ in unary
        \\export fn combine(a:int,b:int)->int return a*100+b*10 end
        \\calls:=[]
        \\fn record(value:int)->int calls+=value; return value end
        \\
    ;
    const mixed_source = try std.fmt.allocPrint(std.testing.allocator, "{s}answer:=combine from record(1) with record(2)+3", .{declarations});
    defer std.testing.allocator.free(mixed_source);
    const ordinary_source = try std.fmt.allocPrint(std.testing.allocator, "{s}answer:=combine(record(1),record(2))+3", .{declarations});
    defer std.testing.allocator.free(ordinary_source);
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var mixed = try compile(std.testing.allocator, mixed_source, "mixed.huak", .{ .optimize = optimize }, &diagnostic);
        defer mixed.deinit();
        var ordinary = try compile(std.testing.allocator, ordinary_source, "ordinary.huak", .{ .optimize = optimize }, &diagnostic);
        defer ordinary.deinit();
        for (ordinary.functions, mixed.functions) |expected, actual| {
            try std.testing.expectEqual(expected.code.len, actual.code.len);
            for (expected.code, actual.code) |a, b| {
                try std.testing.expectEqual(a.op, b.op);
                try std.testing.expectEqual(a.a, b.a);
                try std.testing.expectEqual(a.b, b.b);
            }
        }
        const form = mixed.exports[0].mixfix[0].?;
        try std.testing.expectEqual(precedence.builtinId(.unary), form.group);
        try std.testing.expectEqualStrings("from", form.parts[0].?);
        try std.testing.expect(form.parts[1] == null);
        try std.testing.expectEqualStrings("with", form.parts[2].?);
        var machine = try @import("Machine.zig").init(std.testing.allocator, &mixed, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(i64, 123), machine.getGlobal("answer").?.int);
        const calls = @import("types.zig").sequence(machine.getGlobal("calls").?).?;
        try std.testing.expectEqual(@as(usize, 2), calls.len);
        try std.testing.expectEqual(@as(i64, 1), calls[0].int);
        try std.testing.expectEqual(@as(i64, 2), calls[1].int);
    }
}

const MixfixModules = struct {
    fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
        if (std.mem.eql(u8, path, "forms")) return .{ .name = "forms.huak", .source =
        \\precedence phrase above logical_or; below addition end
        \\mixfix(combine) combine from _ with _ in phrase
        \\export fn combine(a:int,b:int)->int return a*100+b*10 end
        \\mixfix(len) len of _ in unary
        \\export len
        };
        if (std.mem.eql(u8, path, "bridge")) return .{ .name = "bridge.huak", .source =
        \\import "forms".{combine as build,len as count}
        \\export build,count
        };
        return error.UnknownModule;
    }
};

test "mixfix imports preserve alias scope native identity and private precedence origin" {
    var context: u8 = 0;
    const input =
        \\precedence phrase above multiplication end
        \\import "bridge" as library
        \\import "forms".combine as make
        \\a:=library.combine from 1 with 2+3
        \\b:=combine from 1 with 2+3
        \\n:=library.len of [7,8,9]
        \\inner:=0
        \\if true then
        \\    mixfix(make) make first _ second _ in unary
        \\    inner=make first 1 second 2+3
        \\end
        \\outer:=combine from 1 with 2+3
        \\ordinary:=library.count([1,2])
        \\export make
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "root.huak", .{ .import_resolver = .{ .ptr = &context, .vtable = &.{ .resolve = MixfixModules.resolve } }, .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, 3), program.modules.len);
        try std.testing.expect(program.exports[0].mixfix[0].?.group != precedence.builtinId(.unary));
        var native_calls: usize = 0;
        for (program.functions[program.entry].code) |instruction| if (instruction.op == .call_builtin) {
            try std.testing.expectEqual(@backingInt(builtin.Id.len), instruction.a);
            native_calls += 1;
        };
        try std.testing.expectEqual(@as(usize, 2), native_calls);
        var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        for ([_][]const u8{ "a", "b", "outer" }) |name| try std.testing.expectEqual(@as(i64, 150), machine.getGlobal(name).?.int);
        try std.testing.expectEqual(@as(i64, 123), machine.getGlobal("inner").?.int);
        try std.testing.expectEqual(@as(i64, 3), machine.getGlobal("n").?.int);
        try std.testing.expectEqual(@as(i64, 2), machine.getGlobal("ordinary").?.int);
    }
}

test "mixfix imported native calls check module initialization before argument effects" {
    var context: u8 = 0;
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator,
        \\calls:=[]
        \\fn source()->list calls+=1; return [7] end
        \\answer:=early()
        \\import "bridge".count
        \\fn early()->int; return len of source(); end
    , "early.huak", .{ .import_resolver = .{ .ptr = &context, .vtable = &.{ .resolve = MixfixModules.resolve } } }, &diagnostic);
    defer program.deinit();
    var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
    try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "not initialized") != null);
    try std.testing.expectEqual(@as(usize, 0), @import("types.zig").sequence(machine.getGlobal("calls").?).?.len);
}

test "mixfix declarations validate callable arity groups and unused branches" {
    const cases = [_][]const u8{
        "mixfix(missing) missing from _ with _ in unary",
        "mixfix(len) len from _ with _ in unary",
        "fn f(a:int,b:int)->int return a+b end; mixfix(f) f from _ in unary",
        "fn f(a:int,b:int)->int return a+b end; mixfix(f) f from _ with _ in missing",
        "if false then mixfix(missing) missing from _ with _ in unary end",
        "fn f(a:int,b:int)->int return a+b end; mixfix(f) f from _ with _ in unary; value:=f from 1 with true",
    };
    for (cases) |input| {
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "invalid-mixfix.huak", .{}, &diagnostic));
        try std.testing.expect(diagnostic != null);
    }
}

fn mixfixAllocationExercise(allocator: std.mem.Allocator) !void {
    var context: u8 = 0;
    var diagnostic: ?Diagnostic = null;
    var program = try compile(allocator, "import \"bridge\".{build,count}; result:=combine from 1 with (len of [1,2])", "root.huak", .{ .import_resolver = .{ .ptr = &context, .vtable = &.{ .resolve = MixfixModules.resolve } } }, &diagnostic);
    defer program.deinit();
}

test "mixfix template imports and persistent metadata release every allocation failure" {
    try mixfixAllocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), mixfixAllocationExercise, .{});
}

test "slice operands retain for range order and distinguish omitted endpoints" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator,
        \\calls:=[]
        \\fn record(value:int)->int calls+=value; return value end
        \\values:=[0,1,2,3]
        \\selected:=values[record(0):record(2):record(3)]
        \\tail:=selected[1:]
    , "slice-order.huak", .{}, &diagnostic);
    defer program.deinit();
    var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    const sequence = @import("types.zig").sequence;
    const calls = sequence(machine.getGlobal("calls").?).?;
    try std.testing.expectEqual(@as(usize, 3), calls.len);
    for (calls, [_]i64{ 0, 3, 2 }) |item, expected| try std.testing.expectEqual(expected, item.int);
    const tail = sequence(machine.getGlobal("tail").?).?;
    try std.testing.expectEqual(@as(usize, 1), tail.len);
    try std.testing.expectEqual(@as(i64, 2), tail[0].int);
    var count: usize = 0;
    for (program.functions[program.entry].code) |instruction| if (instruction.op == .slice) {
        try std.testing.expectEqual(@as(u32, @intFromBool(count == 1)), instruction.a);
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "an explicit dynamic void slice stop never becomes an open endpoint" {
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator,
            \\fn missing()->any return end
            \\values:=[1,2,3]
            \\selected:=values[1:missing()]
        , "slice-void.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "int") != null);
        try std.testing.expect(machine.getGlobal("selected") == null);
    }
}

test "function defaults retain ordinary dot and both mixfix call forms" {
    const input =
        \\fn combine(a:int,b:int=2)->int return a*10+b end
        \\mixfix(combine) combine _ with _ in unary
        \\mixfix(combine) _ combine _ in addition
        \\plain:=combine(3)
        \\value:=3
        \\dot:=value.combine()
        \\prefixed:=combine 3
        \\word:=value combine 4
        \\mixed:=combine 3 with 2
        \\events:=[]
        \\fn record(x:int)->int events+=x;return x end
        \\explicit:=combine(record(1),record(2))
        \\fn settings(value:float=1,position:vec2=(0mm,1mm),label:string="默认")->list
        \\    return [value,position,label]
        \\end
        \\configured:=settings()
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "function-defaults.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, 1), program.functions[1].requiredCount());
        try std.testing.expectEqual(@as(usize, 2), program.functions[1].fixedCount());
        try std.testing.expect(program.functions[1].acceptsCount(1));
        try std.testing.expect(!program.functions[1].acceptsCount(0));
        for (0..2) |_| {
            var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
            defer machine.deinit();
            _ = try machine.execute(&.{});
            for ([_][]const u8{ "plain", "dot", "prefixed", "mixed" }) |name|
                try std.testing.expectEqual(@as(i64, 32), machine.getGlobal(name).?.int);
            try std.testing.expectEqual(@as(i64, 34), machine.getGlobal("word").?.int);
            try std.testing.expectEqual(@as(i64, 12), machine.getGlobal("explicit").?.int);
            const events = @import("types.zig").sequence(machine.getGlobal("events").?).?;
            try std.testing.expectEqual(@as(usize, 2), events.len);
            try std.testing.expectEqual(@as(i64, 1), events[0].int);
            try std.testing.expectEqual(@as(i64, 2), events[1].int);
            const configured = @import("types.zig").sequence(machine.getGlobal("configured").?).?;
            try std.testing.expectEqual(@as(f64, 1), configured[0].number);
            try std.testing.expectEqualStrings("默认", configured[2].string);
        }
    }
}

test "function default list templates are fresh while explicit lists remain shared" {
    const input =
        \\fn fresh(values:list=[[1]])->list
        \\    child:=values[0];child+=2;values+=3
        \\    return values
        \\end
        \\first:=fresh()
        \\second:=fresh()
        \\child:=first[0];child+=4
        \\seed:=[[7]]
        \\explicit:=fresh(seed)
        \\fn gather(head:int=7,rest:int...)->list return [head,rest] end
        \\empty:=gather()
        \\fixed:=gather(8)
        \\full:=gather(8,9,10)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "function-default-lists.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        for (0..2) |_| {
            var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
            defer machine.deinit();
            _ = try machine.execute(&.{});
            const sequence = @import("types.zig").sequence;
            const first = sequence(machine.getGlobal("first").?).?;
            const second = sequence(machine.getGlobal("second").?).?;
            try std.testing.expectEqual(@as(usize, 3), sequence(first[0]).?.len);
            try std.testing.expectEqual(@as(usize, 2), sequence(second[0]).?.len);
            const seed = sequence(machine.getGlobal("seed").?).?;
            try std.testing.expectEqual(@as(usize, 2), seed.len);
            try std.testing.expectEqual(@as(i64, 2), sequence(seed[0]).?[1].int);
            const empty = sequence(machine.getGlobal("empty").?).?;
            try std.testing.expectEqual(@as(i64, 7), empty[0].int);
            try std.testing.expectEqual(@as(usize, 0), sequence(empty[1]).?.len);
            const full = sequence(machine.getGlobal("full").?).?;
            try std.testing.expectEqual(@as(i64, 8), full[0].int);
            try std.testing.expectEqual(@as(usize, 2), sequence(full[1]).?.len);
            const template = sequence(program.functions[1].defaults[0].?).?;
            try std.testing.expectEqual(@as(usize, 1), template.len);
            try std.testing.expectEqual(@as(usize, 1), sequence(template[0]).?.len);
        }
    }
}

test "function defaults stay attached to aliases namespaces and reexports" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (std.mem.eql(u8, path, "library")) return .{ .name = "library.huak", .source =
            \\export fn add(a:int,b:int=4)->int return a+b end
            \\mixfix(add) add to _ in unary
            };
            return .{ .name = "bridge.huak", .source = "import \"library\".add as sum;export sum" };
        }
    };
    var context: u8 = 0;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator,
            \\import "bridge" as tools
            \\import "library".add as total
            \\a:=tools.sum(3)
            \\b:=tools.add to 4
            \\c:=total(5)
            \\export total
        , "default-aliases.huak", .{ .optimize = optimize, .import_resolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } } }, &diagnostic);
        defer program.deinit();
        const target = program.exports[0].target.function;
        try std.testing.expectEqual(@as(i64, 4), program.functions[target].defaults[1].?.int);
        var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(i64, 7), machine.getGlobal("a").?.int);
        try std.testing.expectEqual(@as(i64, 8), machine.getGlobal("b").?.int);
        try std.testing.expectEqual(@as(i64, 9), machine.getGlobal("c").?.int);
    }
}

test "function defaults validate unused declarations and retain strict arity and types" {
    const invalid = [_][]const u8{
        "fn f(a:int=1,b:int) end",
        "fn f(a:int=1,rest:int...=2) end",
        "fn f(a=1) end",
        "fn f(a:int=\"bad\") end",
        "fn f(a:int=1/0) end",
        "fn f(a:int=9223372036854775807+1) end",
        "fn f(a:int,b:int=1) end; f()",
        "fn f(a:int,b:int=1) end; f(1,2,3)",
        "fn f(a:int,b:int=1) end; f(1,\"bad\")",
        "fn f(a:list=[missing]) end",
    };
    for ([_]bool{ false, true }) |optimize| for (invalid) |input| {
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "invalid-function-default.huak", .{ .optimize = optimize }, &diagnostic));
        try std.testing.expect(diagnostic != null);
    };
}

test "function defaults cannot implicitly capture parameters" {
    const cases = [_][]const u8{
        "fn f(pi:float,x:float=pi) end",
        "fn f(x:float=pi,pi:float=1) end",
        "fn f(pi:float=pi) end",
        "fn f(cm:float,x:length=cm) end",
    };
    for ([_]bool{ false, true }) |optimize| for (cases) |input| {
        var diagnostic: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "shadowed-function-default.huak", .{ .optimize = optimize }, &diagnostic));
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "function default cannot reference") != null);
    };
}

test "function defaults resolve ordinary imported bindings" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8) !ResolvedSource {
            return .{ .name = "values.huak", .source = "export pi:=1; export tau:=2; export e:=3; export cm:=4" };
        }
    };
    const cases = [_][]const u8{
        "import \"values\".pi; fn f(x:float=pi) end",
        "import \"values\".{tau,e}; fn f(x:vec2=(tau,e)) end",
        "import \"values\".pi as cm; fn f(x:list=[[cm]]) end",
        "import \"values\".*; fn f(x:angle=pi rad) end",
    };
    var context: u8 = 0;
    for ([_]bool{ false, true }) |optimize| for (cases) |input| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "imported-function-default.huak", .{ .optimize = optimize, .import_resolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } } }, &diagnostic);
        defer program.deinit();
        var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        for (program.functions, 0..) |function, index| if (std.mem.eql(u8, function.name, "f")) {
            _ = try machine.invokeFunction(.{ .function = .{ .bytecode = @intCast(index) } }, &.{});
        };
    };
}

test "function defaults keep literal constants and explicit units without changing CLI defaults" {
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator,
            \\fn constants(angle:angle=(2*3.141592653589793) rad,point:vec2=(6.283185307179586,2.718281828459045),items:list=[[mm]])->list
            \\    return [angle,point,items]
            \\end
            \\result:=constants()
            \\cm:=7
            \\fn explicit(cm:float=2,distance:length=1cm)->length return distance end
            \\distance:=explicit()
        , "literal-function-default.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        const result = @import("types.zig").sequence(machine.getGlobal("result").?).?;
        try std.testing.expectEqual(@as(f64, 2 * std.math.pi), result[0].quantity.value);
        try std.testing.expectEqual(@as(f64, 2 * std.math.pi), result[1].vec2.x);
        try std.testing.expectEqual(@as(f64, std.math.e), result[1].vec2.y);
        try std.testing.expectEqual(@as(f64, 10), machine.getGlobal("distance").?.quantity.value);

        var cli = try compile(std.testing.allocator, "pi:=1; param angle:float=3.141592653589793", "unchanged-cli-default.huak", .{ .optimize = optimize }, &diagnostic);
        defer cli.deinit();
        try std.testing.expectEqual(@as(f64, std.math.pi), cli.parameters[0].default.?.number);
    }
}

fn functionDefaultAllocationExercise(allocator: std.mem.Allocator) !void {
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(allocator,
            \\export fn f(items:list=[[1,2]],label:string="retained Ω",count:int=2*3)->list
            \\    return [items,label,count]
            \\end
            \\value:=f()
        , "default-allocation.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, 0), program.functions[1].requiredCount());
    }
}

test "function default metadata releases all partial allocations" {
    try functionDefaultAllocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), functionDefaultAllocationExercise, .{});
}

test "standard assertions execute without a host and retain optional failure messages" {
    const cases = [_]struct { arguments: []const u8, message: ?[]const u8 }{
        .{ .arguments = "true", .message = null },
        .{ .arguments = "true,\"unused Ω\"", .message = null },
        .{ .arguments = "false", .message = "assertion failed" },
        .{ .arguments = "false,\"验证失败 Ω\"", .message = "验证失败 Ω" },
    };
    for ([_]bool{ false, true }) |optimize| for (cases) |case| {
        const input = try std.fmt.allocPrint(
            std.testing.allocator,
            "import \"std/assertions.huak\".assert\nexport assert\nassert({s})\ncompleted:=1\n",
            .{case.arguments},
        );
        defer std.testing.allocator.free(input);
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "pure-assertions.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        try std.testing.expectEqual(@as(usize, 2), program.modules.len);
        try std.testing.expectEqualStrings("std/assertions.huak", program.modules[1].name);
        try std.testing.expect(program.exports[0].target == .function);
        var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        if (case.message) |message| {
            try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
            try std.testing.expectEqualStrings(message, machine.failure.?.native_message);
            try std.testing.expectEqualStrings("assert", machine.failure.?.trace[0].function);
            try std.testing.expect(machine.getGlobal("completed") == null);
        } else {
            _ = try machine.execute(&.{});
            try std.testing.expectEqual(@as(i64, 1), machine.getGlobal("completed").?.int);
        }
    };
}

test "constant propagation combines folding branch pruning and persistent globals" {
    const input =
        \\BASE:=2*3
        \\COUNT:=BASE+4
        \\result:=0
        \\if COUNT>8 then
        \\    result=COUNT*2
        \\else
        \\    dead:=9223372036854775807+1
        \\    panic("unreachable")
        \\    result=0
        \\end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "constant-flow.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(i64, 6), machine.getGlobal("BASE").?.int);
        try std.testing.expectEqual(@as(i64, 10), machine.getGlobal("COUNT").?.int);
        try std.testing.expectEqual(@as(i64, 20), machine.getGlobal("result").?.int);
        try std.testing.expect(machine.getGlobal("dead") == null);
        if (optimize) for (program.functions[program.entry].code) |instruction| switch (instruction.op) {
            .load_global, .add, .multiply, .greater, .jump_if_false, .call_builtin => return error.UnexpectedUnfoldedInstruction,
            else => {},
        };
    }
}

test "constant propagation joins only identical values and never assumes parameter defaults" {
    const input =
        \\param choose:bool=true
        \\same_value:=0
        \\dynamic:=0
        \\signed:=0.0
        \\if choose then same_value=12 else same_value=12 end
        \\same:=same_value+1
        \\if choose then dynamic=2; signed=-0.0 else dynamic=3; signed=0.0 end
        \\different:=dynamic+1
        \\copied:=signed
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "constant-joins.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        for ([_]bool{ false, true }) |choose| {
            var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
            defer machine.deinit();
            _ = try machine.execute(&.{.{ .name = "choose", .value = if (choose) "true" else "false" }});
            try std.testing.expectEqual(@as(i64, 13), machine.getGlobal("same").?.int);
            try std.testing.expectEqual(@as(i64, if (choose) 3 else 4), machine.getGlobal("different").?.int);
            try std.testing.expectEqual(@as(u64, if (choose) 0x8000000000000000 else 0), @as(u64, @bitCast(machine.getGlobal("copied").?.number)));
        }
        if (optimize) for (program.functions[program.entry].code, 0..) |instruction, index| {
            if (instruction.op != .store_global or !std.mem.eql(u8, program.global_names[instruction.a], "same")) continue;
            const preceding = program.functions[program.entry].code[index - 1];
            try std.testing.expectEqual(bc.Op.constant, preceding.op);
            try std.testing.expectEqual(@as(i64, 13), program.constants[preceding.a].int);
        };
    }
}

test "constant propagation retains loop updates and folds immutable loop inputs" {
    const input =
        \\param count:int=4
        \\FACTOR:=2*3
        \\total:=0
        \\for i in 1:count do total=total+FACTOR end
        \\result:=total
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "constant-loop.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        for ([_]struct { argument: []const u8, result: i64 }{ .{ .argument = "0", .result = 0 }, .{ .argument = "4", .result = 24 }, .{ .argument = "7", .result = 42 } }) |case| {
            var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
            defer machine.deinit();
            _ = try machine.execute(&.{.{ .name = "count", .value = case.argument }});
            try std.testing.expectEqual(case.result, machine.getGlobal("result").?.int);
        }
        if (optimize) for (program.functions[program.entry].code) |instruction| {
            if (instruction.op == .load_global and std.mem.eql(u8, program.global_names[instruction.a], "FACTOR")) return error.UnpropagatedLoopInvariant;
        };
    }
}

test "constant propagation respects typed stores and failed initialization" {
    const Machine = @import("Machine.zig");
    const input =
        \\param choose:bool=false
        \\rounded:float:=9007199254740993
        \\result:=rounded+1
        \\distance:length:=1
        \\ratio:=distance/1pt
        \\fn local_rounding()->float
        \\    value:float:=9007199254740993
        \\    return value+1
        \\end
        \\local_result:=local_rounding()
        \\if not choose then after=late end
        \\late:=7
        \\after:=late
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "constant-store-coercion.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        for ([_]bool{ false, true }) |choose| {
            var machine = try Machine.init(std.testing.allocator, &program, .{}, .{});
            defer machine.deinit();
            if (choose) {
                _ = try machine.execute(&.{.{ .name = "choose", .value = "true" }});
                try std.testing.expectEqual(@as(i64, 7), machine.getGlobal("after").?.int);
            } else {
                try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
                try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "before initialization") != null);
                try std.testing.expect(machine.getGlobal("after") == null);
            }
            try std.testing.expectEqual(@as(f64, 9007199254740992), machine.getGlobal("result").?.number);
            try std.testing.expectEqual(@as(f64, 9007199254740992), machine.getGlobal("local_result").?.number);
            try std.testing.expectEqual(@as(f64, 1), machine.getGlobal("ratio").?.number);
        }
    }
}

test "constant propagation clears bindings at observable host calls" {
    const Machine = @import("Machine.zig");
    const Observer = struct {
        machine: ?*Machine = null,
        calls: usize = 0,
        fn call(context: ?*anyopaque, _: std.mem.Allocator, id: builtin.Id, _: []const Value, _: ?*@import("Machine.zig")) !Value {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (id != .print) return error.UnexpectedBuiltin;
            self.calls += 1;
            for (self.machine.?.program.global_names, 0..) |name, index| if (std.mem.eql(u8, name, "value")) {
                self.machine.?.globals[index] = .{ .int = 9 };
            };
            return .unit;
        }
    };
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, "value:=2; print(\"change\"); result:=value+1", "constant-host-barrier.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var observer: Observer = .{};
        var machine = try Machine.init(std.testing.allocator, &program, .{ .ptr = &observer, .vtable = &.{ .call_builtin = Observer.call } }, .{});
        defer machine.deinit();
        observer.machine = &machine;
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(usize, 1), observer.calls);
        try std.testing.expectEqual(@as(i64, 10), machine.getGlobal("result").?.int);
    }
}

fn propagationAllocationExercise(allocator: std.mem.Allocator) !void {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(allocator,
        \\FIRST:=2*3
        \\SECOND:=FIRST+4
        \\result:=0
        \\if SECOND>8 then result=SECOND*2 else panic("dead") end
    , "constant-flow-allocations.huak", .{}, &diagnostic);
    defer program.deinit();
    var machine = try @import("Machine.zig").init(allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(@as(i64, 20), machine.getGlobal("result").?.int);
}

test "constant propagation pipeline releases every temporary round on allocation failure" {
    try propagationAllocationExercise(std.testing.allocator);
    var backing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(backing.allocator(), propagationAllocationExercise, .{});
}

test "constant propagation treats dynamic handle arithmetic as an implicit host barrier" {
    const Machine = @import("Machine.zig");
    const Observer = struct {
        machine: ?*Machine = null,
        calls: usize = 0,
        fn path(_: ?*anyopaque, _: std.mem.Allocator, id: builtin.Id, _: []const Value, _: ?*@import("Machine.zig")) !Value {
            if (id != .path) return error.UnexpectedBuiltin;
            return .{ .handle = .{ .kind = .path, .index = 0 } };
        }
        fn binary(context: ?*anyopaque, _: std.mem.Allocator, op: bc.Op, left: Value, right: Value) !Value {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (op != .add and op != .subtract) return error.UnexpectedOperator;
            if (op == .subtract) try std.testing.expect(left == .int and left.int == 0);
            try std.testing.expect(right.valueType() == .path);
            self.calls += 1;
            for (self.machine.?.program.global_names, 0..) |name, index| if (std.mem.eql(u8, name, "value")) {
                self.machine.?.globals[index] = .{ .int = 9 };
            };
            return .{ .int = 0 };
        }
    };
    for ([_]bool{ false, true }) |optimize| for ([_][]const u8{ "object+object", "-object" }) |operation| {
        const input = try std.fmt.allocPrint(std.testing.allocator, "; object:any:=path((0,0),(1,1)); value:=2; ignored:={s}; result:=value+1", .{operation});
        defer std.testing.allocator.free(input);
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "constant-binary-barrier.huak", .{ .optimize = optimize }, &diagnostic);
        defer program.deinit();
        var observer: Observer = .{};
        var machine = try Machine.init(std.testing.allocator, &program, .{ .ptr = &observer, .vtable = &.{ .call_builtin = Observer.path, .binary = Observer.binary } }, .{});
        defer machine.deinit();
        observer.machine = &machine;
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(usize, 1), observer.calls);
        try std.testing.expectEqual(@as(i64, 10), machine.getGlobal("result").?.int);
    };
}

// A fixed empty-block fixture exercises compiler lowering only. Real native
// parsing, evaluation and rendering are covered by the integration suites.
fn emptyTypstFixture(_: *anyopaque, input: []const u8) !usize {
    if (!std.mem.startsWith(u8, input, "[]")) return error.UnexpectedTestBlock;
    return 2;
}

fn typstOptions(optimize: bool) CompileOptions {
    return .{ .optimize = optimize, .source_parser = Parser.TestSourceParser.parser };
}

fn typstCompile(allocator: std.mem.Allocator, input: []const u8, optimize: bool) !bc.Program {
    var diagnostic: ?Diagnostic = null;
    return compile(allocator, input, "typst-reads.huak", typstOptions(optimize), &diagnostic) catch |err| {
        if (diagnostic) |detail| std.debug.print("typst reads compiler: {s}\n", .{detail.text()});
        return err;
    };
}

const ExpectedRequest = struct {
    op: bc.Op = .typst,
    /// Huak names, or ".member" for a show value.
    names: []const []const u8,
    loads: ?[]const bc.Op = null,
    /// Globals loaded for the captures.
    globals: ?[]const []const u8 = null,
    /// The code uses `huak` as a whole value.
    whole: bool = false,
    /// The name a typ.module is made with.
    module: ?[]const u8 = null,
};

/// Checks the Typst requests of `function` in code order.
fn expectTypstRequests(program: *const bc.Program, function: bc.Function, expected: []const ExpectedRequest) !void {
    var index: usize = 0;
    for (function.code, 0..) |instruction, position| if (instruction.op == .typst or instruction.op == .typst_module) {
        try std.testing.expect(index < expected.len);
        const want = expected[index];
        try std.testing.expectEqual(want.op, instruction.op);
        const pairs: usize = instruction.typstCaptures().pairs;
        try std.testing.expectEqual(want.names.len, pairs);
        try std.testing.expectEqual(want.whole, instruction.typstCaptures().whole);
        // A module's name precedes its captured pairs.
        const named = instruction.op == .typst_module;
        try std.testing.expectEqual(pairs * 2 + @intFromBool(named), instruction.stackEffect().consumed);
        if (want.module) |name| {
            const constant = function.code[position - pairs * 2 - 1];
            try std.testing.expectEqual(bc.Op.constant, constant.op);
            try std.testing.expectEqualStrings(name, program.constants[constant.a].string);
        }
        try std.testing.expectEqual(@as(usize, 1), instruction.stackEffect().produced);
        const inputs = function.code[position - pairs * 2 .. position];
        for (want.names, 0..) |name, capture| {
            try std.testing.expectEqual(bc.Op.constant, inputs[capture * 2].op);
            try std.testing.expectEqualStrings(name, program.constants[inputs[capture * 2].a].string);
            const load = inputs[capture * 2 + 1];
            if (want.loads) |loads| try std.testing.expectEqual(loads[capture], load.op);
            if (want.globals) |globals| {
                try std.testing.expectEqual(bc.Op.load_global, load.op);
                try std.testing.expectEqualStrings(globals[capture], program.global_names[load.a]);
            }
        }
        index += 1;
    };
    try std.testing.expectEqual(expected.len, index);
}

fn expectTypstFailure(input: []const u8, message: []const u8) !void {
    var diagnostic: ?Diagnostic = null;
    try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "typst-errors.huak", typstOptions(false), &diagnostic));
    std.testing.expectEqualStrings(message, diagnostic.?.text()) catch |err| {
        std.debug.print("input: {s}\n", .{input});
        return err;
    };
}

test "Typst reads capture the names the code uses once each from their scopes" {
    const input =
        \\outer:=1
        \\first:=typ[#huak.outer #huak.outer]
        \\if true then
        \\    inside:="inside"
        \\    middle:=typ[#huak.outer #huak.inside]
        \\else
        \\    other:=2
        \\    alternate:=typ[#huak.other]
        \\end
        \\none:=typ[#other.outer]
        \\fn make_caption(outer:int)->text
        \\    local_value:="local"
        \\    return typ[#huak.local_value $huak.outer$]
        \\end
    ;
    var program = try typstCompile(std.testing.allocator, input, false);
    defer program.deinit();
    try expectTypstRequests(&program, program.functions[0], &.{
        .{ .names = &.{"outer"}, .loads = &.{.load_global} },
        .{ .names = &.{ "outer", "inside" }, .loads = &.{ .load_global, .load_local } },
        .{ .names = &.{"other"}, .loads = &.{.load_local} },
        .{ .names = &.{} },
    });
    try expectTypstRequests(&program, program.functions[1], &.{.{ .names = &.{ "local_value", "outer" }, .loads = &.{ .load_local, .load_local } }});
}

test "typ.show declarations add no runtime work without a typ block" {
    var original = try typstCompile(std.testing.allocator, "theme:=typ.module[]", false);
    defer original.deinit();
    var declared = try typstCompile(std.testing.allocator, "theme:=typ.module[]\ntyp.show theme.style", false);
    defer declared.deinit();
    try std.testing.expectEqual(original.constants.len, declared.constants.len);
    try std.testing.expectEqual(original.functions[0].code.len, declared.functions[0].code.len);
    for (original.functions[0].code, declared.functions[0].code) |left, right| {
        try std.testing.expectEqual(left.op, right.op);
        try std.testing.expectEqual(left.a, right.a);
        try std.testing.expectEqual(left.b, right.b);
    }
    var future = try typstCompile(std.testing.allocator, "if false then typ.show future.style; future:=typ.module[] end", true);
    defer future.deinit();
    for (future.functions[0].code) |instruction| try std.testing.expect(instruction.op != .load_global and instruction.op != .load_local);
}

test "Typst reads reject unknown names functions and values Typst cannot receive" {
    try expectTypstFailure("value:=typ[#huak.missing]", "Typst code reads huak.missing, which names no readable Huak value here");
    try expectTypstFailure("fn function()->int return 1 end\nvalue:=typ[#huak.function]", "Typst code reads huak.function, which names no readable Huak value here");
    try expectTypstFailure("value:=typ[#huak.pi]", "Typst code reads huak.pi, which names no readable Huak value here");
    try expectTypstFailure("items:=[1]\nvalue:=typ[#huak.items]", "Typst code can read numeric, bool, string, length, color, and typ.module values from huak; huak.items has type list");
    // A forward declaration is checked with its inferred type.
    try expectTypstFailure("if false then value:=typ[#huak.later] end\nlater:=[1]", "Typst code can read numeric, bool, string, length, color, and typ.module values from huak; huak.later has type list");
    try expectTypstFailure("value:=picture(640, 480)\ncaption:=typ[#huak.value]", "Typst code can read numeric, bool, string, length, color, and typ.module values from huak; huak.value has type picture");
    try expectTypstFailure("value:=1deg\ncaption:=typ[#huak.value]", "Typst code can read numeric, bool, string, length, color, and typ.module values from huak; huak.value has type angle");
    // Code that binds `huak` itself may read its own members, so only
    // readable values Typst can receive are captured.
    var rebound = try typstCompile(std.testing.allocator, "items:=[1]\ncount:=2\nvalue:=typ[#let huak = (items: 1); #huak.items #huak.unknown #huak.count]", false);
    defer rebound.deinit();
    try expectTypstRequests(&rebound, rebound.functions[0], &.{.{ .names = &.{"count"} }});
}

test "Typst instructions record whether the code uses huak as a whole value" {
    const input =
        \\count:=2
        \\bare:=typ[#repr(huak)]
        \\both:=typ[#repr(huak) #huak.count]
        \\member:=typ[#huak.count]
        \\plain:=typ[text]
        \\lib:=typ.module[#let all = huak]
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try typstCompile(std.testing.allocator, input, optimize);
        defer program.deinit();
        try expectTypstRequests(&program, program.functions[0], &.{
            .{ .names = &.{}, .whole = true },
            .{ .names = &.{"count"}, .whole = true },
            .{ .names = &.{"count"} },
            .{ .names = &.{} },
            .{ .op = .typst_module, .names = &.{}, .whole = true, .module = "lib" },
        });
    }
}

test "typ.show paths apply outermost first while typ.module captures reads only" {
    const input =
        \\size:=2pt
        \\outer:=typ.module[#let style(b) = b]
        \\inner:=typ.module[#let style(b) = text(huak.size, b)]
        \\typ.show outer.style
        \\fn caption()->text
        \\    typ.show inner.style
        \\    typ.show outer.style
        \\    return typ[#huak.size]
        \\end
        \\plain:=typ[]
    ;
    var program = try typstCompile(std.testing.allocator, input, false);
    defer program.deinit();
    try expectTypstRequests(&program, program.functions[0], &.{
        .{ .op = .typst_module, .names = &.{}, .module = "outer" },
        .{ .op = .typst_module, .names = &.{"size"}, .globals = &.{"size"}, .module = "inner" },
        .{ .names = &.{".style"}, .globals = &.{"outer"} },
    });
    try expectTypstRequests(&program, program.functions[1], &.{.{ .names = &.{ "size", ".style", ".style" }, .globals = &.{ "size", "outer", "inner" } }});
    // A module's instruction spans exactly its code.
    for (program.functions[0].code) |instruction| if (instruction.op == .typst_module) {
        try std.testing.expect(std.mem.startsWith(u8, program.source_text[instruction.span.start..instruction.span.end], "[#let style(b) = "));
        try std.testing.expect(program.source_text[instruction.span.end - 1] == ']');
    };
}

test "typ.module reads only the names its code uses and never itself" {
    const input =
        \\size:=2pt
        \\mark:=typ.module[#let mark(body) = text(huak.size, body)]
        \\shout:=typ.module[#let shout(body) = huak.mark.mark(upper(body))]
        \\fn make()->typ.module return typ.module[] end
    ;
    var program = try typstCompile(std.testing.allocator, input, false);
    defer program.deinit();
    // A module is named after the name it is assigned to.
    try expectTypstRequests(&program, program.functions[0], &.{
        .{ .op = .typst_module, .names = &.{"size"}, .module = "mark" },
        .{ .op = .typst_module, .names = &.{"mark"}, .module = "shout" },
    });
    try expectTypstRequests(&program, program.functions[1], &.{.{ .op = .typst_module, .names = &.{}, .module = "module" }});
    try expectTypstFailure("theme:=typ.module[#huak.theme]", "Typst code reads huak.theme, which names no readable Huak value here");
    try expectTypstFailure("fn make()->typ.module\n    theme:=typ.module[#huak.theme]\n    return theme\nend", "Typst code reads huak.theme, which names no readable Huak value here");
}

test "typ.show and typ.module reject values Typst cannot receive" {
    try expectTypstFailure("count:=1\ntyp.show count.style\nvalue:=typ[]", "typ.show needs a typ.module value; 'count' has type int");
    try expectTypstFailure("count:=1\nblock\n    typ.show count.style\nend", "typ.show needs a typ.module value; 'count' has type int");
    try expectTypstFailure("typ.show missing.style", "typ.show needs a readable typ.module value, found 'missing'");
    try expectTypstFailure("theme:=typ.module[]\ntyp.show theme", "typ.show needs a member of a typ.module value, such as theme.style");
    try expectTypstFailure("items:=[1]\nrule:=typ.module[#huak.items]", "Typst code can read numeric, bool, string, length, color, and typ.module values from huak; huak.items has type list");
    try expectTypstFailure("fn make()->text return typ.module[] end", "expected text, found typ.module");
}

test "typ.show paths reach typ.module exports through import namespaces" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (std.mem.eql(u8, path, "themes")) return .{ .name = "themes.huak", .source = "export theme:=typ.module[#let style(b) = b]\nexport count:=1\nexport fn helper()->int return 1 end\n" };
            return .{ .name = "outer.huak", .source = "import \"themes\" as themes\nexport themes\n" };
        }
    };
    var marker: u8 = 0;
    var options = typstOptions(false);
    options.import_resolver = .{ .ptr = &marker, .vtable = &.{ .resolve = Resolver.resolve } };
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator, "import \"themes\" as themes\nimport \"outer\" as outer\ntyp.show themes.theme.style\ntyp.show outer.themes.theme.page.style\na:=typ[]", "show-root.huak", options, &diagnostic);
    defer program.deinit();
    const root = program.functions[program.entry];
    var found = false;
    for (root.code, 0..) |instruction, position| if (instruction.op == .typst) {
        found = true;
        try std.testing.expectEqual(@as(u32, 2), instruction.b);
        // Each show value is checked for its initialized module, then loaded.
        try std.testing.expectEqual(bc.Op.load_global, root.code[position - 1].op);
        try std.testing.expectEqualStrings("themes.huak::theme", program.global_names[root.code[position - 1].a]);
        var members: [2][]const u8 = undefined;
        var count: usize = 0;
        for (root.code[0..position]) |earlier| if (earlier.op == .constant and program.constants[earlier.a] == .string and program.constants[earlier.a].string.len > 0 and program.constants[earlier.a].string[0] == '.') {
            members[count] = program.constants[earlier.a].string;
            count += 1;
        };
        try std.testing.expectEqual(@as(usize, 2), count);
        try std.testing.expectEqualStrings(".style", members[0]);
        try std.testing.expectEqualStrings(".page.style", members[1]);
    };
    try std.testing.expect(found);
    const failures = [_]struct { input: []const u8, message: []const u8 }{
        .{ .input = "import \"themes\" as themes\ntyp.show themes.style", .message = "module 'themes.huak' does not export 'style'" },
        .{ .input = "import \"themes\" as themes\ntyp.show themes.theme", .message = "typ.show needs a member of the typ.module value, such as theme.style" },
        .{ .input = "import \"themes\" as themes\ntyp.show themes.count.style", .message = "typ.show needs a typ.module value; 'count' has type int" },
        .{ .input = "import \"themes\" as themes\ntyp.show themes.helper.style", .message = "typ.show needs a readable typ.module value, found 'helper'" },
    };
    for (failures) |failure| {
        var detail: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, failure.input, "show-root.huak", options, &detail));
        try std.testing.expectEqualStrings(failure.message, detail.?.text());
    }
}

test "Typst reads in template call bodies resolve like ordinary reads" {
    // The body sees template parameters and locals, including the parameter
    // that shadows a caller global and names forwarded by a nested insertion.
    const forwarded =
        \\expand_block foo(width:length = 2pt)
        \\    a := 1
        \\    ...
        \\end
        \\expand_block bar(gap:length = 1pt)
        \\    c := 3
        \\    foo do
        \\        e := 5
        \\        ...
        \\    end
        \\end
        \\gap := 9pt
        \\bar do
        \\    caption := typ[#huak.gap #huak.c #huak.width #huak.a #huak.e]
        \\end
    ;
    var program = try typstCompile(std.testing.allocator, forwarded, false);
    defer program.deinit();
    const locals: []const bc.Op = &.{ .load_local, .load_local, .load_local, .load_local, .load_local };
    try expectTypstRequests(&program, program.functions[0], &.{.{ .names = &.{ "gap", "c", "width", "a", "e" }, .loads = locals }});
    var optimized = try typstCompile(std.testing.allocator, forwarded, true);
    optimized.deinit();
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (!std.mem.eql(u8, path, "frames")) return error.UnknownModule;
            return .{ .name = "frames.huak", .source = "export expand_block frame(gap:length = 1pt)\n    inner := 3\n    ...\nend\nexport expand_block broken()\n    value := typ[#huak.missing]\n    ...\nend\n" };
        }
    };
    var marker: u8 = 0;
    var options = typstOptions(false);
    options.import_resolver = .{ .ptr = &marker, .vtable = &.{ .resolve = Resolver.resolve } };
    var diagnostic: ?Diagnostic = null;
    var imported = try compile(std.testing.allocator, "import \"frames\".frame\ngap := 9pt\nfn caption()->text\n    result := typ[]\n    frame do\n        result = typ[#huak.gap #huak.inner]\n    end\n    return result\nend", "frames-root.huak", options, &diagnostic);
    defer imported.deinit();
    var function: ?bc.Function = null;
    for (imported.functions) |candidate| if (std.mem.eql(u8, candidate.name, "caption")) {
        function = candidate;
    };
    try expectTypstRequests(&imported, function.?, &.{ .{ .names = &.{} }, .{ .names = &.{ "gap", "inner" }, .loads = &.{ .load_local, .load_local } } });

    const Failure = struct { input: []const u8, message: []const u8, file: []const u8 = "typst-template.huak", line: usize, column: usize };
    const failures = [_]Failure{
        // An invoked template checks the reads in its own body, and an
        // imported template reports them in its defining module.
        .{ .input = "expand_block frame()\n    value := typ[#huak.missing]\n    ...\nend\nframe do\nend", .message = "Typst code reads huak.missing, which names no readable Huak value here", .line = 2, .column = 24 },
        .{ .input = "import \"frames\".broken\nbroken do\nend", .message = "Typst code reads huak.missing, which names no readable Huak value here", .file = "frames.huak", .line = 6, .column = 24 },
        .{ .input = "expand_block frame()\n    items := [1]\n    ...\nend\nframe do\n    caption := typ[#huak.items]\nend", .message = "Typst code can read numeric, bool, string, length, color, and typ.module values from huak; huak.items has type list", .line = 6, .column = 26 },
        .{ .input = "expand_block frame()\n    ...\nend\nframe do\n    if false then caption := typ[#huak.later] end\n    later := [1]\nend", .message = "local variable used before its declaration is complete", .line = 5, .column = 40 },
        .{ .input = "expand_block frame()\n    ...\nend\nframe do\n    caption := typ[#huak.missing]\nend", .message = "Typst code reads huak.missing, which names no readable Huak value here", .line = 5, .column = 26 },
    };
    for (failures) |failure| {
        var detail: ?Diagnostic = null;
        try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, failure.input, "typst-template.huak", options, &detail));
        try std.testing.expectEqualStrings(failure.message, detail.?.text());
        try std.testing.expectEqualStrings(failure.file, detail.?.fileName().?);
        const position = detail.?.position("");
        try std.testing.expectEqual(failure.line, position.line);
        try std.testing.expectEqual(failure.column, position.column);
    }
}

test "Typst reads preserve imported aliases initialization checks and module isolation" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (!std.mem.eql(u8, path, "library")) return error.UnknownModule;
            return .{ .name = "library.huak", .source = "export title:=\"title\"\nlabel:=typ[#huak.title]\n" };
        }
    };
    var marker: u8 = 0;
    var options = typstOptions(false);
    options.import_resolver = .{ .ptr = &marker, .vtable = &.{ .resolve = Resolver.resolve } };
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator, "import \"library\".title as caption\na:=typ[#huak.caption]", "typst-root.huak", options, &diagnostic);
    defer program.deinit();
    const root = program.functions[program.entry];
    var root_found = false;
    for (root.code, 0..) |instruction, position| if (instruction.op == .typst) {
        root_found = true;
        try std.testing.expectEqual(@as(u32, 1), instruction.b);
        try std.testing.expectEqual(bc.Op.check_module, root.code[position - 2].op);
        try std.testing.expectEqualStrings("caption", program.constants[root.code[position - 3].a].string);
    };
    try std.testing.expect(root_found);
    var bare = try compile(std.testing.allocator, "import \"library\" as library\na:=typ[]", "unread-root.huak", options, &diagnostic);
    defer bare.deinit();
    var seen: [2]bool = @splat(false);
    for (bare.functions) |function| for (function.code) |instruction| if (instruction.op == .typst) {
        try std.testing.expectEqual(@as(u32, if (function.module == 0) 0 else 1), instruction.b);
        seen[function.module] = true;
    };
    try std.testing.expect(seen[0] and seen[1]);
}

fn typstReadAllocationExercise(allocator: std.mem.Allocator) !void {
    for ([_]bool{ false, true }) |optimize| {
        var program = try typstCompile(allocator, "count:=1\nfn make_caption(count:int)->text\ntyp.show style.style\nreturn typ[#huak.count]\nend\nstyle:=typ.module[#huak.count]\nfirst:=typ[#huak.count]\nif true then local:=2;second:=typ[#huak.local #huak.count] end", optimize);
        defer program.deinit();
    }
}

test "Typst read lowering releases every failed allocation" {
    try typstReadAllocationExercise(std.testing.allocator);
    var stable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(stable.allocator(), typstReadAllocationExercise, .{});
}

test "Typst reads include native lengths colors and runtime checked quantities" {
    var program = try typstCompile(std.testing.allocator, "import color.rgb\ndistance:=2cm\nink:=rgb(0.1,0.2,0.3)\nflexible:quantity:=3mm\ncaption:=typ[#huak.distance #huak.ink #huak.flexible]", false);
    defer program.deinit();
    try expectTypstRequests(&program, program.functions[program.entry], &.{.{ .names = &.{ "distance", "ink", "flexible" } }});
}

test "struct export modifiers retain nominal constructors beside value bindings through aliases" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (std.mem.eql(u8, path, "library")) return .{ .name = "library.huak", .source = "S:=42\nexport struct S\n value:int=5\nend\nexport number:=S" };
            return .{ .name = "bridge.huak", .source = "import \"library\".S as Renamed\nexport Renamed" };
        }
    };
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var context: u8 = 0;
        var program = try compile(std.testing.allocator,
            \\import "library" as types
            \\import "library".S as Alias
            \\import "bridge".Renamed as Reexport
            \\local:Alias:=Alias()
            \\qualified:types.S:=types.S(value:9)
            \\again:Reexport:=Reexport()
            \\copied_qualified:=copy(types.S(value:11))
            \\copied_alias:=copy(Alias(value:12))
            \\first:=local.value; second:=qualified.value; third:=again.value
            \\copied_first:=copied_qualified.value; copied_second:=copied_alias.value
            \\number:=types.number
            \\export Alias, Reexport
        , "constructor-export.huak", .{ .optimize = optimize, .import_resolver = .{ .ptr = &context, .vtable = &.{ .resolve = Resolver.resolve } } }, &diagnostic);
        defer program.deinit();
        try std.testing.expect(program.exports[0].target == .record);
        try std.testing.expectEqualDeep(program.exports[0].target, program.exports[1].target);
        try std.testing.expectEqual(testGlobalType(&program, "local"), testGlobalType(&program, "qualified"));
        try std.testing.expectEqual(testGlobalType(&program, "local"), testGlobalType(&program, "again"));
        try std.testing.expectEqual(testGlobalType(&program, "local"), testGlobalType(&program, "copied_qualified"));
        try std.testing.expectEqual(testGlobalType(&program, "local"), testGlobalType(&program, "copied_alias"));
        var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(i64, 5), machine.getGlobal("first").?.int);
        try std.testing.expectEqual(@as(i64, 9), machine.getGlobal("second").?.int);
        try std.testing.expectEqual(@as(i64, 5), machine.getGlobal("third").?.int);
        try std.testing.expectEqual(@as(i64, 42), machine.getGlobal("number").?.int);
        try std.testing.expectEqual(@as(i64, 11), machine.getGlobal("copied_first").?.int);
        try std.testing.expectEqual(@as(i64, 12), machine.getGlobal("copied_second").?.int);
        var bare = try compile(std.testing.allocator, "struct S value:int end\nS:=42\nexport S", "value-export.huak", .{ .optimize = optimize }, &diagnostic);
        defer bare.deinit();
        try std.testing.expect(bare.exports[0].target == .global);
    }
}

test "forward constructor references to nested structs fail before reading module exports" {
    for ([_]bool{ false, true }) |optimize| {
        for ([_][]const u8{
            "fn f()->any\n return Local()\n struct Local\n value:int\n end\nend",
            "if true then\n result:=Local()\n struct Local\n value:int\n end\nend",
        }) |input| {
            var diagnostic: ?Diagnostic = null;
            try std.testing.expectError(error.LanguageError, compile(std.testing.allocator, input, "nested-struct.huak", .{ .optimize = optimize }, &diagnostic));
            try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "top level") != null);
        }
    }
}

test "nested namespace imports preserve parent initialization and nominal type identity" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (std.mem.eql(u8, path, "facade")) return .{ .name = "facade.huak", .source =
            \\import "tools" as tools
            \\tools.values[0] = tools.values[0] + 1
            \\export tools
            };
            if (std.mem.eql(u8, path, "tools")) return .{ .name = "tools.huak", .source =
            \\export values := [0]
            \\export struct Item
            \\    value:int = 7
            \\end
            };
            return error.MissingModule;
        }
    };
    for ([_]bool{ false, true }) |optimize| {
        var opaque_context: u8 = 0;
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator,
            \\import "facade".tools.values
            \\import "facade" as library
            \\import "tools".Item as LocalItem
            \\fn read(item:library.tools.Item) -> int
            \\    return item.value
            \\end
            \\count := values[0]
            \\item := library.tools.Item()
            \\other:LocalItem := item
            \\result := read(other)
            \\export library
        , "namespaces.huak", .{ .optimize = optimize, .import_resolver = .{ .ptr = &opaque_context, .vtable = &.{ .resolve = Resolver.resolve } } }, &diagnostic);
        defer program.deinit();
        try std.testing.expect(program.exports[0].target == .namespace);
        var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        try std.testing.expectEqual(@as(i64, 1), machine.getGlobal("count").?.int);
        try std.testing.expectEqual(@as(i64, 7), machine.getGlobal("result").?.int);
    }
}

test "nested native constants work in defaults without bypassing parameter shadowing" {
    var diagnostic: ?Diagnostic = null;
    var program = try compile(std.testing.allocator,
        \\import std
        \\fn pi(value:float = std.math.PI) -> float
        \\    return value
        \\end
        \\result := pi()
    , "nested-default.huak", .{}, &diagnostic);
    defer program.deinit();
    var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try std.testing.expectEqual(std.math.pi, machine.getGlobal("result").?.number);
    try std.testing.expectError(error.LanguageError, compile(std.testing.allocator,
        \\import std
        \\fn bad(std:int, value:float = std.math.PI) -> float
        \\    return value
        \\end
    , "shadowed-namespace-default.huak", .{}, &diagnostic));
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "cannot reference parameter 'std'") != null);
}

test "nested namespace access checks the facade before argument effects even when the leaf is ready" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, _: std.mem.Allocator, _: []const u8, path: []const u8) !ResolvedSource {
            if (std.mem.eql(u8, path, "tools")) return .{ .name = "tools.huak", .source =
            \\export values := [0]
            \\export fn f(value:int) -> int
            \\    return value
            \\end
            };
            if (std.mem.eql(u8, path, "facade")) return .{ .name = "facade.huak", .source =
            \\import "tools" as tools
            \\tools.values[0] = 1
            \\export tools
            };
            return error.MissingModule;
        }
    };
    for ([_]struct { imported: []const u8, expression: []const u8 }{
        .{ .imported = "import \"facade\" as library", .expression = "library.tools.f(effect())" },
        .{ .imported = "import \"facade\".tools.f", .expression = "f(effect())" },
        .{ .imported = "import \"facade\".tools.values", .expression = "values[0]" },
        .{ .imported = "import \"facade\".tools as library", .expression = "library.f(effect())" },
        .{ .imported = "import \"facade\" as library", .expression = "library.tools.values[0]" },
    }) |fixture| for ([_]bool{ false, true }) |optimize| {
        const input = try std.fmt.allocPrint(std.testing.allocator,
            \\import "tools" as direct
            \\events := direct.values
            \\early()
            \\{s}
            \\fn early() -> int
            \\    return {s}
            \\end
            \\fn effect() -> int
            \\    direct.values[0] = 99
            \\    return 9
            \\end
        , .{ fixture.imported, fixture.expression });
        defer std.testing.allocator.free(input);
        var marker: u8 = 0;
        var diagnostic: ?Diagnostic = null;
        var program = try compile(std.testing.allocator, input, "facade-order.huak", .{ .optimize = optimize, .import_resolver = .{ .ptr = &marker, .vtable = &.{ .resolve = Resolver.resolve } } }, &diagnostic);
        defer program.deinit();
        var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        try std.testing.expectError(error.RuntimeFailed, machine.execute(&.{}));
        try std.testing.expect(std.mem.indexOf(u8, machine.failure.?.text(), "not initialized") != null);
        try std.testing.expectEqual(@as(i64, 0), machine.getGlobal("events").?.list.items()[0].int);
    };
}

test "symbolic mixfix is lexical and nested expansion forwards its insertion" {
    const input =
        \\fn twice(x:int)->int return x*2 end
        \\fn difference(a:int,b:int)->int return a-b end
        \\a := block
        \\    mixfix(twice) + _ in unary
        \\    return +3 + 4
        \\end
        \\b := block
        \\    mixfix(difference) _ + _ in addition
        \\    return 20 + 2*3
        \\end
        \\c := +3 + 4
        \\events := []
        \\expand_block foo(target:list)
        \\    target += 1
        \\    ...
        \\    target += 5
        \\end
        \\expand_block bar(target:list)
        \\    target += 0
        \\    foo target do
        \\        local := 3
        \\        target += 2
        \\        ...
        \\        target += 4
        \\    end
        \\    target += 6
        \\end
        \\bar events do events += local end
        \\expand_block nested(target:list)
        \\    if true then
        \\        local := 7
        \\        ...
        \\    end
        \\end
        \\nested events do events += local end
    ;
    for ([_]bool{ false, true }) |optimize| {
        var diagnostic: ?Diagnostic = null;
        var program = compile(std.testing.allocator, input, "symbol-nested.huak", .{ .optimize = optimize }, &diagnostic) catch |err| {
            if (diagnostic) |detail| std.debug.print("{s}\n", .{detail.text()});
            return err;
        };
        defer program.deinit();
        var machine = try @import("Machine.zig").init(std.testing.allocator, &program, .{}, .{});
        defer machine.deinit();
        _ = try machine.execute(&.{});
        inline for (.{ "a", "b", "c" }, .{ 10, 14, 7 }) |name, expected|
            try std.testing.expectEqual(@as(i64, expected), machine.getGlobal(name).?.int);
        const events = machine.getGlobal("events").?.list.items();
        try std.testing.expectEqual(@as(usize, 8), events.len);
        for (events, 0..) |value, index| try std.testing.expectEqual(@as(i64, @intCast(index)), value.int);
    }
}
