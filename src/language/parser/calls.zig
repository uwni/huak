//! Calls: ordinary calls with named arguments and dot receivers, qualified call heads, and block expansions.
const std = @import("std");
const Lexer = @import("../Lexer.zig");
const ast = @import("../ast.zig");
const source = @import("../source.zig");
const Parser = @import("../Parser.zig");
const expressions = @import("expressions.zig");
const statements = @import("statements.zig");
const ungroup = ast.ungroup;
const BlockLookup = Parser.BlockLookup;
const MixfixLookup = Parser.MixfixLookup;
const Options = Parser.Options;

pub fn parseCall(self: *Parser, left: *ast.Expr) anyerror!*ast.Expr {
    var args: std.array_list.Managed(*ast.Expr) = .init(self.allocator);
    var argument_names: std.array_list.Managed(?[]const u8) = .init(self.allocator);
    var named = false;
    const callee = ungroup(left);
    const name = switch (callee.value) {
        .name => |name| name,
        .member => |member| call_name: {
            try args.append(member.object);
            break :call_name member.name;
        },
        else => return self.fail(left.span, "only named functions can be called", .{}),
    };
    try self.advance();
    if (self.current.kind != .rparen) while (true) {
        var argument_name: ?[]const u8 = null;
        if (self.current.kind == .identifier) {
            if ((try self.peek()).kind == .colon) {
                const token = self.current;
                argument_name = self.text(token);
                for (argument_names.items) |earlier| if (earlier) |name_| {
                    if (std.mem.eql(u8, name_, argument_name.?)) return self.fail(token.span, "duplicate named argument '{s}'", .{name_});
                };
                if (!named) {
                    for (0..args.items.len) |_| try argument_names.append(null);
                    named = true;
                }
                try self.advance();
                try self.advance();
            }
        }
        if (argument_name == null and named) return self.fail(self.current.span, "positional arguments cannot follow named arguments", .{});
        try args.append(try expressions.expression(self, 0));
        if (named) try argument_names.append(argument_name);
        if (self.current.kind == .ellipsis) return self.fail(self.current.span, "call argument spreading is not supported", .{});
        if (!try self.accept(.comma)) break;
        if (self.current.kind == .rparen) break;
    };
    const finish = try self.expect(.rparen, "expected ')' after arguments");
    return self.createExpr(.join(left.span, finish.span), .{ .call = .{ .name = name, .args = try args.toOwnedSlice(), .argument_names = if (named) try argument_names.toOwnedSlice() else &.{}, .dot = callee.value == .member } });
}

/// Consume a possible callable head using only its lexical cursor. A member such as
/// Module member access belongs to the ordinary postfix parser.
pub fn callHead(allocator: std.mem.Allocator, lexer: *Lexer, current: *Lexer.Token) !?ast.OperatorName {
    const first = current.*;
    var name = first;
    var namespace: ?[]const u8 = null;
    current.* = try lexer.next();
    while (current.kind == .dot) {
        current.* = try lexer.next();
        if (current.kind != .identifier) return null;
        const word = lexer.source[name.span.start..name.span.end];
        namespace = if (namespace) |parent|
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent, word })
        else
            word;
        name = current.*;
        current.* = try lexer.next();
    }
    return .{ .namespace = namespace, .name = lexer.source[name.span.start..name.span.end], .span = .join(first.span, name.span) };
}

pub fn expansion(self: *Parser, name: ast.OperatorName, definition: BlockLookup.Definition) anyerror!*ast.Expr {
    var args: []const *ast.Expr = &.{};
    var names: []const ?[]const u8 = &.{};
    if (self.current.kind == .lparen) {
        const invocation = try parseCall(self, try self.createExpr(name.span, .{ .name = name.name }));
        args = invocation.value.call.args;
        names = invocation.value.call.argument_names;
    } else if (self.current.kind != .kw_do) {
        const values = try self.allocator.alloc(*ast.Expr, 1);
        values[0] = try expressions.expression(self, 0);
        args = values;
    }
    const newline_nesting = self.lexer.newline_nesting;
    self.lexer.newline_nesting = self.lexer.nesting;
    defer self.lexer.newline_nesting = newline_nesting;
    try self.controlDelimiter(.kw_do, "expected 'do' after block arguments");
    const scope = self.headers.?.scopeAt(self.current.span.start);
    if (self.options.blocks) |lookup| try lookup.vtable.enter(lookup.ptr, definition, scope);
    const body_ = try statements.body(self);
    self.lexer.newline_nesting = newline_nesting;
    const finish = try self.expect(.kw_end, "expected 'end' for expanded block");
    return self.createExpr(.join(name.span, finish.span), .{ .expansion = .{ .name = name, .definition = definition.statement, .module = definition.module, .args = args, .argument_names = names, .body = body_, .scope = scope } });
}

test "parenthesized names keep ordinary calls and import literals" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\x:=((foo))(1)
        \\y:=(point.x)()
        \\import ("source.huak") as shapes
    , .{}, &diagnostic);
    const script = try parser.parse();
    try std.testing.expectEqualStrings("foo", script.statements[0].value.assignment.value.value.call.name);
    const member = script.statements[1].value.assignment.value.value.call;
    try std.testing.expect(member.dot);
    try std.testing.expectEqualStrings("x", member.name);
    try std.testing.expectEqualStrings("point", member.args[0].value.name);
    try std.testing.expectEqualStrings("source.huak", script.statements[2].value.imported.path);
}

test "call spread is rejected explicitly rather than treated as a member or path" {
    for ([_][]const u8{ "collect(points...)", "collect(1,points...)", "picture.collect(points...)", "collect(...points)" }) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expect(std.mem.indexOf(u8, diagnostic.?.text(), "spread") != null);
        try std.testing.expectEqualStrings("...", input[diagnostic.?.span.start..diagnostic.?.span.end]);
    }
}

test "dot calls lower arbitrary receivers and chains to named calls" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?source.Diagnostic = null;
    var parser = try Parser.init(arena.allocator(),
        \\value:=(1+2).combine(3,4).finish()
        \\indexed:=items[0].combine(3)
        \\member:=point.x
        \\called:=point.x()
        \\created:=make().finish()
    , .{}, &diagnostic);
    const script = try parser.parse();
    const finish = script.statements[0].value.assignment.value.value.call;
    try std.testing.expectEqualStrings("finish", finish.name);
    try std.testing.expectEqual(@as(usize, 1), finish.args.len);
    const combine = finish.args[0].value.call;
    try std.testing.expectEqualStrings("combine", combine.name);
    try std.testing.expectEqual(@as(usize, 3), combine.args.len);
    try std.testing.expectEqual(ast.Binary.add, combine.args[0].value.grouped.value.binary.op);
    try std.testing.expectEqual(@as(u64, 3), combine.args[1].value.integer);
    try std.testing.expectEqual(@as(u64, 4), combine.args[2].value.integer);
    const indexed = script.statements[1].value.assignment.value.value.call;
    try std.testing.expectEqualStrings("items", indexed.args[0].value.index.object.value.name);
    try std.testing.expectEqual(@as(u64, 0), indexed.args[0].value.index.index.value.integer);
    const member = script.statements[2].value.assignment.value.value.member;
    try std.testing.expectEqualStrings("x", member.name);
    const called = script.statements[3].value.assignment.value.value.call;
    try std.testing.expectEqualStrings("x", called.name);
    try std.testing.expectEqualStrings("point", called.args[0].value.name);
    const created = script.statements[4].value.assignment.value.value.call;
    try std.testing.expectEqualStrings("make", created.args[0].value.call.name);
    try std.testing.expectEqual(@as(usize, 0), created.args[0].value.call.args.len);
}

test "dot calls do not introduce callable values" {
    for ([_][]const u8{ "make()(1)", "[make][0](1)", "(1+2)(3)" }) |input| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var diagnostic: ?source.Diagnostic = null;
        var parser = try Parser.init(arena.allocator(), input, .{}, &diagnostic);
        try std.testing.expectError(error.LanguageError, parser.parse());
        try std.testing.expectEqualStrings("only named functions can be called", diagnostic.?.text());
    }
}

test "call heads probe one mixfix table and preserve ordinary member calls" {
    const Log = struct {
        const Event = struct { mixed: bool, name: []const u8, namespace: ?[]const u8 };
        events: [8]Event = undefined,
        count: usize = 0,
        invalid: bool = false,
        fn record(self: *@This(), mixed: bool, name: ast.OperatorName) void {
            self.events[self.count] = .{ .mixed = mixed, .name = name.name, .namespace = name.namespace };
            self.count += 1;
        }
        fn mixfix(context: *anyopaque, name: ast.OperatorName, leading: bool) ?MixfixLookup.Binding {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.record(leading, name);
            return .{ .form = .{ .head = name.name, .parts = if (self.invalid) &.{} else if (std.mem.eql(u8, name.name, "combine")) &.{ "with", null } else &.{null}, .group = .{ .name = "unary", .span = name.span }, .leading = leading } };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var log: Log = .{};
    const options: Options = .{ .mixfix = .{ .ptr = &log, .vtable = &.{ .lookup = Log.mixfix } } };
    var diagnostic: ?source.Diagnostic = null;
    var frontend = try Parser.init(arena.allocator(),
        \\a:=tools.deep.choose item
        \\b:=tools.deep.combine with 1
        \\c:=tools.deep.field
        \\d:=tools.deep.wrap(1)
        \\e:=tools.deep.wrap (2)
    , options, &diagnostic);
    const script = try frontend.parse();
    // Adjacent f(...) and bare members do not probe call-form metadata.
    try std.testing.expectEqual(@as(usize, 3), log.count);
    for ([_][]const u8{ "choose", "combine", "wrap" }, log.events[0..log.count]) |name, event| {
        try std.testing.expectEqualStrings(name, event.name);
        try std.testing.expect(!event.mixed);
        try std.testing.expectEqualStrings("tools.deep", event.namespace.?);
    }
    try std.testing.expect(script.statements[0].value.assignment.value.value == .mixfix_call);
    try std.testing.expect(script.statements[1].value.assignment.value.value == .mixfix_call);
    try std.testing.expect(script.statements[2].value.assignment.value.value == .member);
    try std.testing.expect(script.statements[3].value.assignment.value.value == .call);
    try std.testing.expect(script.statements[4].value.assignment.value.value == .mixfix_call);
    log.count = 0;
    log.invalid = true;
    var invalid = try Parser.init(arena.allocator(), "value:=tools.deep.broken with 1", options, &diagnostic);
    try std.testing.expectError(error.LanguageError, invalid.parse());
    try std.testing.expectEqual(@as(usize, 1), log.count);
    try std.testing.expect(!log.events[0].mixed);
    try std.testing.expectEqualStrings("invalid mixfix template", diagnostic.?.text());
}
