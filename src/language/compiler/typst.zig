//! Embedded Typst: typ blocks and their reads, typ.show and typ.module.
const std = @import("std");
const ast = @import("../ast.zig");
const Parser = @import("../Parser.zig");
const source = @import("../source.zig");
const bc = @import("../bytecode.zig");
const Type = bc.Type;
const Span = source.Span;
const modules = @import("modules.zig");
const symbols = @import("symbols.zig");
const Compiler = @import("Compiler.zig");
const Context = @import("Context.zig");
const Binding = symbols.Binding;
const Environment = symbols.Environment;

/// A Huak value read by Typst code or a `typ.show` path, resolved where the
/// read compiles, which may be inside a template expansion. Its environment
/// is the reading module.
pub const TypstRead = struct { binding: Binding, environment: *Environment, name: []const u8, span: Span, show: bool };

const unreadable_typst_value = "Typst code reads huak.{s}, which names no readable Huak value here";

const unsupported_typst_value = "Typst code can read numeric, bool, string, length, color, and typ.module values from huak; huak.{s} has type {s}";

const unreadable_show = "typ.show needs a readable typ.module value, found '{s}'";

const unsupported_show = "typ.show needs a typ.module value; '{s}' has type {s}";

/// A `typ[…]` block: its reads, the shows in scope and the Typst code.
pub fn compileTypstBlock(self: *Compiler, context: *Context, block: ast.Typst, span: Span) anyerror!Type {
    var count: u32 = 0;
    try compileTypstReads(self, context, block, &count);
    try compileTypstShows(self, context, span, &count);
    const captures: bc.TypstCaptures = .{ .pairs = @intCast(count), .whole = block.whole };
    _ = try context.emit(.typst, try self.addConstant(.{ .string = block.code }, span), @bitCast(captures), span);
    return .text;
}

/// The typ.module's Typst name is the name it is assigned to, as a file's
/// stem names the module it holds, or "module".
pub fn compileTypstModule(self: *Compiler, context: *Context, block: ast.Typst, span: Span, name: ?[]const u8) !Type {
    try context.constant(.{ .string = try self.allocator.dupe(u8, name orelse "module") }, span);
    var count: u32 = 0;
    try compileTypstReads(self, context, block, &count);
    // The instruction spans exactly the code, which locates
    // native diagnostics within this module's source.
    const code: Span = .{ .start = span.end - block.code.len, .end = span.end };
    const captures: bc.TypstCaptures = .{ .pairs = @intCast(count), .whole = block.whole };
    _ = try context.emit(.typst_module, try self.addConstant(.{ .string = block.code }, code), @bitCast(captures), code);
    return .typst_module;
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

pub fn failTypstRead(self: *Compiler, read: TypstRead, kind: Type) error{LanguageError} {
    return if (read.show)
        self.fail(read.span, unsupported_show, .{ read.name, self.typeName(kind) })
    else
        self.fail(read.span, unsupported_typst_value, .{ read.name, self.typeName(kind) });
}

/// Rejects a type already known to be unsupported. A binding whose type
/// is still to be inferred is kept for the check after this body is
/// compiled.
pub fn recordTypstRead(self: *Compiler, context: *Context, read: TypstRead) !void {
    if (!passable(read, read.binding.symbol.kind)) return failTypstRead(self, read, read.binding.symbol.kind);
    if (read.binding.symbol.inferable) try context.typst_reads.append(self.build.syntax_allocator, read);
}

/// Checks each read against the type its binding has once this body is
/// compiled, since a forward declaration may be inferred after the read.
/// Diagnostics name the reading module.
pub fn checkTypstReads(self: *Compiler, context: *Context) !void {
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
        return failTypstRead(self, read, kind);
    }
}

pub fn countCapture(self: *Compiler, count: *u32, span: Span) !void {
    if (count.* == std.math.maxInt(u32) / 2) return self.fail(span, "Typst code reads more Huak values than the bytecode stack holds", .{});
    count.* += 1;
}

/// Pushes a (name, value) pair for each Huak name the Typst code reads,
/// in order of first use. When the code binds `huak` itself, a use may
/// name that binding, so only names that are readable here and passable
/// to Typst are captured.
pub fn compileTypstReads(self: *Compiler, context: *Context, block: ast.Typst, count: *u32) !void {
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
        try recordTypstRead(self, context, read);
        try countCapture(self, count, use.span);
        // The name is a slice of the module source, which the program keeps.
        try context.constant(.{ .string = use.name }, use.span);
        try context.load(read.binding, use.span);
    }
}

const ShowBase = struct { binding: Binding, taken: usize };

/// Resolves at `site` the Huak value a `typ.show` path starts with: a
/// readable binding, or an export reached through import namespaces.
/// The remaining segments name members of that typ.module.
pub fn typstShowBase(self: *Compiler, context: *Context, path: []const ast.ExportName, site: Span) !ShowBase {
    const first = path[0];
    const base: ShowBase = if (context.resolve(first.name, site)) |binding| .{ .binding = binding, .taken = 1 } else found: {
        var module = modules.imported(self, first.name, site) orelse return self.fail(first.span, unreadable_show, .{first.name});
        const unit = self.environment.unit;
        const initializer = unit.resolverAt(site.start).namespaceInitializer(unit.scopeAt(site.start), first.name);
        for (path[1..], 2..) |segment, taken| {
            if (self.build.graph.exportedNamespace(module, segment.name)) |inner| {
                module = inner;
                continue;
            }
            const exposed = try modules.importedExport(self, module, segment.name, segment.span);
            if (exposed.target != .global) return self.fail(segment.span, unreadable_show, .{segment.name});
            const global = exposed.target.global;
            break :found .{ .binding = .{ .symbol = .{ .index = global, .kind = self.build.types.items[global], .readonly = true }, .local = false, .module = module, .initializer = initializer }, .taken = taken };
        }
        return self.fail(first.span, unreadable_show, .{first.name});
    };
    const value = path[base.taken - 1];
    if (base.taken == path.len) return self.fail(value.span, "typ.show needs a member of the typ.module value, such as {s}.style", .{value.name});
    try recordTypstRead(self, context, .{ .binding = base.binding, .environment = self.environment, .name = value.name, .span = value.span, .show = true });
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
pub fn compileTypstShows(self: *Compiler, context: *Context, span: Span, count: *u32) !void {
    const unit = self.environment.unit;
    if (unit.headers.typst_declarations.len == 0) return;
    try compileScopeShows(self, context, unit.scopeAt(span.start), span, count);
}

pub fn compileScopeShows(self: *Compiler, context: *Context, scope: Parser.ScopeId, span: Span, count: *u32) !void {
    const headers = self.environment.unit.headers;
    if (headers.scopes[scope].parent) |parent| try compileScopeShows(self, context, parent, span, count);
    for (headers.typst_declarations, 0..) |header, index| {
        if (header.scope != scope or shownBefore(self, scope, index)) continue;
        const path = header.statement.value.typst_show;
        const base = try typstShowBase(self, context, path, span);
        try countCapture(self, count, span);
        try context.constant(.{ .string = try showMembers(self, path, base.taken) }, header.statement.span);
        try context.load(base.binding, span);
    }
}

/// Whether an enclosing scope, or this scope earlier, declares the same path.
pub fn shownBefore(self: *const Compiler, scope: Parser.ScopeId, index: usize) bool {
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
pub fn showMembers(self: *Compiler, path: []const ast.ExportName, taken: usize) ![]const u8 {
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
