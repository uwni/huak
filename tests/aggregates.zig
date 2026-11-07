//! Source-level aggregate semantics and their real native drawing integration.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const Value = l.types.Value;
const options = @import("test_options");

const ModuleSource = struct { name: []const u8, source: []const u8 };
const ModuleResolver = struct {
    sources: []const ModuleSource,

    fn resolve(context: *anyopaque, allocator: std.mem.Allocator, importer: []const u8, path: []const u8) !l.compiler.ResolvedSource {
        const self: *@This() = @ptrCast(@alignCast(context));
        const name = try std.fs.path.resolve(allocator, &.{ std.fs.path.dirname(importer).?, path });
        for (self.sources) |source| if (std.mem.eql(u8, source.name, name)) return .{ .name = name, .source = try allocator.dupe(u8, source.source) };
        return error.ModuleNotFound;
    }
};

fn compile(allocator: std.mem.Allocator, library: *typst.Library, text: []const u8, sources: []const ModuleSource, optimize: bool, diagnostic: *?l.compiler.Diagnostic) !l.bytecode.Program {
    var resolver: ModuleResolver = .{ .sources = sources };
    return l.compiler.compile(allocator, text, "/aggregates/main.huak", .{
        .source_parser = .init(library),
        .import_resolver = .{ .ptr = &resolver, .vtable = &.{ .resolve = ModuleResolver.resolve } },
        .optimize = optimize,
    }, diagnostic);
}

fn compileValid(library: *typst.Library, text: []const u8, sources: []const ModuleSource, optimize: bool) !l.bytecode.Program {
    var diagnostic: ?l.compiler.Diagnostic = null;
    return compile(t.allocator, library, text, sources, optimize, &diagnostic) catch |err| {
        if (diagnostic) |detail| std.debug.print("aggregate compiler: {s}: {s}\n", .{ detail.fileName() orelse "/aggregates/main.huak", detail.text() });
        return err;
    };
}

fn execute(machine: *l.Machine) !void {
    _ = machine.execute(&.{}) catch |err| {
        if (machine.failure) |detail| std.debug.print("aggregate VM: {s}: {s}\n", .{ detail.text(), detail.native_message });
        return err;
    };
}

fn expectInts(value: Value, expected: []const i64) !void {
    const items = l.types.sequence(value) orelse return error.ExpectedList;
    try t.expectEqual(expected.len, items.len);
    for (items, expected) |item, integer| try t.expectEqualDeep(Value{ .int = integer }, item);
}

fn expectStrings(value: Value, expected: []const []const u8) !void {
    const items = l.types.sequence(value) orelse return error.ExpectedList;
    try t.expectEqual(expected.len, items.len);
    for (items, expected) |item, text| try t.expectEqualStrings(text, item.string);
}

fn expectKeys(dictionary: *const l.types.Dict, expected: []const []const u8) !void {
    try t.expectEqual(expected.len, dictionary.entries.count());
    for (dictionary.entries.keys(), expected) |actual, wanted| try t.expectEqualStrings(wanted, actual);
}

test "aggregate constructors run native color defaults and sparse builtin defaults through SVG and PDF" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const text =
        \\import color.rgb
        \\import object.{draw, label}
        \\struct Style
        \\    color:color=rgb(0.1,0.2,0.3)
        \\    width:length=0.5mm
        \\end
        \\style:=Style()
        \\another:=Style(width:1mm)
        \\pic:=picture(height:40mm, width:640pt)
        \\object.append(pic, draw(path((2mm,2mm),(30mm,15mm)), pen(style.color,style.width)))
        \\caption:=typ[Aggregates Ω]
        \\object.append(pic, label(caption, (3mm,20mm)))
        \\canvas_width:=pic.width
        \\canvas_height:=pic.height
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileValid(&library, text, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        const style = machine.getGlobal("style").?.record;
        const another = machine.getGlobal("another").?.record;
        try t.expectEqual(l.types.Type.color, style.fields[0].handle.kind);
        try t.expectEqual(l.types.Type.color, another.fields[0].handle.kind);
        try t.expect(style.fields[0].handle.index != another.fields[0].handle.index);
        try t.expectEqual(@as(f64, 0.5), style.fields[1].quantity.value);
        try t.expectEqual(@as(f64, 1), another.fields[1].quantity.value);
        try t.expectEqual(l.types.units.fromPoints(640), machine.getGlobal("canvas_width").?.quantity);
        try t.expectEqual(@as(f64, 40), machine.getGlobal("canvas_height").?.quantity.value);
        var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
        defer svg.deinit();
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<svg") != null);
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
        var pdf = try runtime.render(machine.getGlobal("pic").?, .pdf);
        defer pdf.deinit();
        try t.expect(std.mem.startsWith(u8, pdf.bytes(), "%PDF-"));
        const extracted = try @import("support/pdf.zig").text(pdf.bytes(), .{});
        defer t.allocator.free(extracted);
        try t.expect(std.mem.indexOf(u8, extracted, "Aggregates") != null);
    }
}

test "aggregate programs expose the native math namespace without leaking mathematical globals" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const variants = [_][]const u8{
        "angle:=math.sin(0); root:=math.sqrt(9); circle_constant:=math.PI; param heading:angle=(2*math.PI)rad; fn f(x:float=math.PI)->float return x end; defaulted:=f()",
        "import math as mathematics; angle:=mathematics.sin(0); root:=mathematics.sqrt(9); circle_constant:=mathematics.PI",
        "import math.{sin, sqrt, PI}; angle:=sin(0); root:=sqrt(9); circle_constant:=PI",
    };
    for ([_]bool{ false, true }) |optimize| for (variants, 0..) |text, variant| {
        var program = try compileValid(&library, text, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        try t.expectEqual(@as(f64, 0), machine.getGlobal("angle").?.number);
        try t.expectEqual(@as(f64, 3), machine.getGlobal("root").?.number);
        try t.expectApproxEqAbs(std.math.pi, machine.getGlobal("circle_constant").?.number, 1e-15);
        if (variant == 0) {
            try t.expectEqual(@as(usize, 1), program.modules.len);
            try t.expectApproxEqAbs(std.math.pi, machine.getGlobal("defaulted").?.number, 1e-15);
        }
        if (variant != 2) try t.expect(machine.getGlobal("PI") == null);
        for ([_][]const u8{ "answer:=sin(0)", "answer:=PI", "answer:=rgb(0,0,0)", "import math as mathematics\nanswer:=cos(0)", "answer:=math.rgb(0,0,0)", "math:=(1,2); answer:=math.PI" }) |invalid| {
            var diagnostic: ?l.compiler.Diagnostic = null;
            try t.expectError(error.LanguageError, compile(t.allocator, &library, invalid, &.{}, optimize, &diagnostic));
            try t.expect(diagnostic != null);
        }
    };
}

test "native drawing domains are available independently of source standard modules" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const text =
        \\ink:=color.rgb(0.2,0.4,0.7)
        \\nib:=pen.pensquare(1mm,ink)
        \\curve:=geometry.circle((15mm,15mm),5mm)
        \\matrix:=transform.translate((1mm,0mm))
        \\pic:=picture(40mm,30mm)
        \\object.append(pic, object.draw(curve, nib, matrix))
        \\body:=typ[Domain text]
        \\measured:=text.width(body)
        \\object.append(pic, object.label(body, (2mm,2mm)))
        \\editable:=object.outlines(body)
        \\system:=solver()
        \\x:=solver.unknown(system)
        \\solver.equation(system,x,2)
        \\solution:=solver.solve(system)
        \\answer:=solver.value(solution,x)
        \\animation.timeline(pic,1)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileValid(&library, text, &.{}, optimize);
        defer program.deinit();
        try t.expectEqual(@as(usize, 1), program.modules.len);
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        try t.expectEqual(@as(f64, 2), machine.getGlobal("answer").?.number);
        try t.expect(machine.getGlobal("measured").?.quantity.value > 0);
        var svg = try runtime.render(machine.getGlobal("pic").?, .svg);
        defer svg.deinit();
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<svg") != null);
        try t.expect(std.mem.indexOf(u8, svg.bytes(), "<path") != null);
    }
}

test "aggregate struct imports aliases and reexports retain one nominal identity" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const sources = [_]ModuleSource{
        .{ .name = "/aggregates/models.huak", .source = "export struct Point\n x:int=1\n y:int=2\nend" },
        .{ .name = "/aggregates/bridge.huak", .source = "import \"models.huak\".Point as Renamed\nexport Renamed" },
    };
    const text =
        \\import "models.huak" as models
        \\import "models.huak".Point as Direct
        \\import "bridge.huak".Renamed as Alias
        \\fn total(value:models.Point)->int return value.x+value.y end
        \\first:Alias:=Direct(y:5)
        \\second:models.Point:=Alias(x:7)
        \\answer:=total(first)+total(second)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileValid(&library, text, &sources, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        try t.expectEqual(machine.getGlobal("first").?.record.kind, machine.getGlobal("second").?.record.kind);
        try t.expectEqual(@as(i64, 15), machine.getGlobal("answer").?.int);
        try t.expectEqual(@as(usize, 1), program.records.len);
        var diagnostic: ?l.compiler.Diagnostic = null;
        try t.expectError(error.LanguageError, compile(t.allocator, &library,
            \\struct First value:int end
            \\struct Second value:int end
            \\fn consume(value:First)->int return value.value end
            \\bad:=consume(Second(1))
        , &.{}, optimize, &diagnostic));
        try t.expect(std.mem.indexOf(u8, diagnostic.?.text(), "First") != null);
        try t.expect(std.mem.indexOf(u8, diagnostic.?.text(), "Second") != null);
    }
}

test "aggregate named arguments evaluate explicit values once before fresh field defaults" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const text =
        \\events:=[]
        \\fn mark(log:list,value:int)->int log+=value;return value end
        \\struct Fields
        \\    first:int=mark(events,10)
        \\    second:int=mark(events,20)
        \\    third:int=mark(events,30)
        \\end
        \\chosen:=Fields(third:mark(events,3),first:mark(events,1))
        \\defaulted:=Fields()
        \\fn collect(a:int=10,b:int=20,c:int=30)->list return [a,b,c] end
        \\function_events:=[]
        \\collected:=collect(c:mark(function_events,6),a:mark(function_events,4))
        \\struct Box data:dict={"items":[]} end
        \\one:=Box()
        \\two:=Box()
        \\one.data["items"]+=1
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileValid(&library, text, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        try expectInts(machine.getGlobal("events").?, &.{ 3, 1, 20, 10, 20, 30 });
        try expectInts(machine.getGlobal("function_events").?, &.{ 6, 4 });
        try expectInts(machine.getGlobal("collected").?, &.{ 4, 20, 6 });
        try t.expectEqual(@as(i64, 1), machine.getGlobal("chosen").?.record.fields[0].int);
        try t.expectEqual(@as(i64, 20), machine.getGlobal("chosen").?.record.fields[1].int);
        const first = machine.getGlobal("one").?.record.fields[0].dict;
        const second = machine.getGlobal("two").?.record.fields[0].dict;
        try t.expect(first != second);
        try expectInts(first.entries.get("items").?, &.{1});
        try expectInts(second.entries.get("items").?, &.{});
    }
}

test "aggregate field and index writes evaluate every nested target once before their RHS" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const text =
        \\struct Item values:list=[] end
        \\item:=Item()
        \\rows:=[{"node":item}]
        \\fn target(rows:list,log:list)->list log+=1;return rows end
        \\fn position(log:list)->int log+=2;return 0 end
        \\fn key(log:list)->string log+=3;return "node" end
        \\fn scalar(log:list)->int log+=4;return 7 end
        \\fn sequence(log:list)->list log+=4;return [8] end
        \\fn replacement(log:list)->Item log+=4;return Item() end
        \\fn row_replacement(log:list)->dict log+=4;return {"node":Item()} end
        \\append_order:=[]
        \\target(rows,append_order)[position(append_order)][key(append_order)].values+=scalar(append_order)
        \\appended:=copy(item.values)
        \\field_order:=[]
        \\target(rows,field_order)[position(field_order)][key(field_order)].values=sequence(field_order)
        \\assigned:=copy(item.values)
        \\index_order:=[]
        \\target(rows,index_order)[position(index_order)][key(index_order)]=replacement(index_order)
        \\previous_row:=rows[0]
        \\indexed:=rows[0]["node"]
        \\list_order:=[]
        \\target(rows,list_order)[position(list_order)]=row_replacement(list_order)
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileValid(&library, text, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        for ([_][]const u8{ "append_order", "field_order", "index_order" }) |name| try expectInts(machine.getGlobal(name).?, &.{ 1, 2, 3, 4 });
        try expectInts(machine.getGlobal("list_order").?, &.{ 1, 2, 4 });
        try expectInts(machine.getGlobal("appended").?, &.{7});
        try expectInts(machine.getGlobal("assigned").?, &.{8});
        const row = l.types.sequence(machine.getGlobal("rows").?).?[0].dict;
        try t.expect(row != machine.getGlobal("previous_row").?.dict);
        try t.expect(row.entries.get("node").?.record != machine.getGlobal("indexed").?.record);
        try t.expect(row.entries.get("node").?.record != machine.getGlobal("item").?.record);
        try expectInts(row.entries.get("node").?.record.fields[0], &.{});
    }
}

test "aggregate copies share nested values while their outer containers remain independent" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const text =
        \\struct Box data:dict={"items":[]} end
        \\original:=Box()
        \\record_copy:=copy(original)
        \\record_copy.data["items"]+=1
        \\original_list:=[original]
        \\list_copy:=copy(original_list)
        \\list_copy[0].data["items"]+=2
        \\original_dict:={"node":original}
        \\dict_copy:=copy(original_dict)
        \\dict_copy["node"].data["items"]+=3
        \\dict_copy["extra"]=9
        \\list_copy+=[original]
        \\record_copy.data={"items":[4]}
        \\loop_dict:={}
        \\loop_dict["self"]=loop_dict
        \\loop_copy:=copy(loop_dict)
        \\same:=loop_dict==loop_copy
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileValid(&library, text, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        const original = machine.getGlobal("original").?.record;
        const copied = machine.getGlobal("record_copy").?.record;
        try t.expect(original != copied);
        try t.expect(original.fields[0].dict != copied.fields[0].dict);
        try expectInts(original.fields[0].dict.entries.get("items").?, &.{ 1, 2, 3 });
        try expectInts(copied.fields[0].dict.entries.get("items").?, &.{4});
        const list = l.types.sequence(machine.getGlobal("original_list").?).?;
        const list_copy = l.types.sequence(machine.getGlobal("list_copy").?).?;
        try t.expectEqual(@as(usize, 1), list.len);
        try t.expectEqual(@as(usize, 2), list_copy.len);
        try t.expectEqual(original, list_copy[0].record);
        const dict = machine.getGlobal("original_dict").?.dict;
        const dict_copy = machine.getGlobal("dict_copy").?.dict;
        try t.expect(dict != dict_copy);
        try t.expect(!dict.entries.contains("extra"));
        try t.expectEqual(original, dict_copy.entries.get("node").?.record);
        try t.expect(machine.getGlobal("same").?.boolean);
        try t.expectEqual(machine.getGlobal("loop_dict").?.dict, machine.getGlobal("loop_copy").?.dict.entries.get("self").?.dict);
    }
}

test "aggregate dictionaries preserve key order after replacement removal and reinsertion" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const text =
        \\data:={"first":1,"second":2,"third":3}
        \\data["second"]=8
        \\before:=keys(data)
        \\removed:=dict_remove(data,"second")
        \\missing:=dict_remove(data,"absent")
        \\middle:=keys(data)
        \\data["second"]=9
        \\after:=keys(data)
        \\exists:=dict_contains(data,"second")
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileValid(&library, text, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        try expectStrings(machine.getGlobal("before").?, &.{ "first", "second", "third" });
        try expectStrings(machine.getGlobal("middle").?, &.{ "first", "third" });
        try expectStrings(machine.getGlobal("after").?, &.{ "first", "third", "second" });
        try t.expect(machine.getGlobal("removed").?.boolean);
        try t.expect(!machine.getGlobal("missing").?.boolean);
        try t.expect(machine.getGlobal("exists").?.boolean);
    }
}

test "aggregates collections helpers preserve order shallow references and their inputs" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const text =
        \\import collections as collections
        \\shared:=[1]
        \\input:={"first":shared,"preserved":false,"last":{"mark":2}}
        \\got:=collections.get(input,"first",[99])
        \\fallback:=collections.get(input,"absent",shared)
        \\kept:=collections.get(input,"preserved",true)
        \\initial_values:=collections.values(input)
        \\empty_values:=collections.values({})
        \\changed:=collections.setting(input,"new",shared)
        \\replaced:=collections.setting(input,"preserved",true)
        \\second:={"preserved":true,"added":shared,"last":{"other":3}}
        \\merged:=collections.merged(input,second)
        \\merge_empty:=collections.merged(input,{})
        \\fallbacks:={"preserved":true,"added":shared,"tail":{"end":4}}
        \\filled:=collections.defaults(input,fallbacks)
        \\defaults_empty:=collections.defaults(input,{})
        \\input_keys:=keys(input)
        \\second_keys:=keys(second)
        \\fallback_keys:=keys(fallbacks)
        \\shared+=2
    ;
    for ([_]bool{ false, true }) |optimize| {
        var program = try compileValid(&library, text, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try execute(&machine);
        const input = machine.getGlobal("input").?.dict;
        const second = machine.getGlobal("second").?.dict;
        const fallbacks = machine.getGlobal("fallbacks").?.dict;
        const shared = machine.getGlobal("shared").?;
        try expectInts(shared, &.{ 1, 2 });
        try t.expectEqual(shared.list.owned, machine.getGlobal("got").?.list.owned);
        try t.expectEqual(shared.list.owned, machine.getGlobal("fallback").?.list.owned);
        try t.expect(!machine.getGlobal("kept").?.boolean);
        const initial_values = l.types.sequence(machine.getGlobal("initial_values").?).?;
        try t.expectEqual(@as(usize, 3), initial_values.len);
        try t.expectEqual(shared.list.owned, initial_values[0].list.owned);
        try expectInts(initial_values[0], &.{ 1, 2 });
        try t.expect(!initial_values[1].boolean);
        try t.expectEqual(input.entries.get("last").?.dict, initial_values[2].dict);
        try expectInts(machine.getGlobal("empty_values").?, &.{});
        try expectStrings(machine.getGlobal("input_keys").?, &.{ "first", "preserved", "last" });
        try expectStrings(machine.getGlobal("second_keys").?, &.{ "preserved", "added", "last" });
        try expectStrings(machine.getGlobal("fallback_keys").?, &.{ "preserved", "added", "tail" });
        const changed = machine.getGlobal("changed").?.dict;
        const replaced = machine.getGlobal("replaced").?.dict;
        const merged = machine.getGlobal("merged").?.dict;
        const filled = machine.getGlobal("filled").?.dict;
        try t.expect(input != changed and input != replaced and input != merged and input != filled);
        try t.expect(!input.entries.contains("new") and !input.entries.contains("added"));
        try t.expect(!input.entries.get("preserved").?.boolean);
        try t.expect(second.entries.get("preserved").?.boolean);
        try t.expect(fallbacks.entries.get("preserved").?.boolean);
        try expectKeys(changed, &.{ "first", "preserved", "last", "new" });
        try expectKeys(replaced, &.{ "first", "preserved", "last" });
        try expectKeys(merged, &.{ "first", "preserved", "last", "added" });
        try expectKeys(filled, &.{ "first", "preserved", "last", "added", "tail" });
        try t.expectEqual(shared.list.owned, changed.entries.get("new").?.list.owned);
        try t.expect(replaced.entries.get("preserved").?.boolean);
        try t.expect(merged.entries.get("preserved").?.boolean);
        try t.expectEqual(second.entries.get("last").?.dict, merged.entries.get("last").?.dict);
        try t.expectEqual(shared.list.owned, merged.entries.get("first").?.list.owned);
        try t.expectEqual(shared.list.owned, merged.entries.get("added").?.list.owned);
        try t.expect(!filled.entries.get("preserved").?.boolean);
        try t.expectEqual(input.entries.get("last").?.dict, filled.entries.get("last").?.dict);
        try t.expectEqual(fallbacks.entries.get("tail").?.dict, filled.entries.get("tail").?.dict);
        try t.expectEqual(shared.list.owned, filled.entries.get("added").?.list.owned);
        for ([_][]const u8{ "merge_empty", "defaults_empty" }) |name| {
            const copy = machine.getGlobal(name).?.dict;
            try t.expect(input != copy);
            try expectKeys(copy, input.entries.keys());
            try t.expectEqual(shared.list.owned, copy.entries.get("first").?.list.owned);
        }
    }
}

test "aggregate diagnostics reject bad keys fields named arguments and native attribute writes" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    const invalid = [_]struct { text: []const u8, expected: []const u8 }{
        .{ .text = "data:={\"same\":1,\"\\u0073ame\":2}", .expected = "duplicate dictionary key" },
        .{ .text = "struct Data value:int end\nvalue:=Data(value:\"bad\")", .expected = "int" },
        .{ .text = "struct Data value:int end\nvalue:=Data(missing:1)", .expected = "unknown argument" },
        .{ .text = "value:=picture(640, 480)\nvalue.width=1", .expected = "writable field" },
        .{ .text = "data:={\"value\":1}\nresult:=data.value", .expected = "member" },
    };
    for ([_]bool{ false, true }) |optimize| {
        for (invalid) |case| {
            var diagnostic: ?l.compiler.Diagnostic = null;
            try t.expectError(error.LanguageError, compile(t.allocator, &library, case.text, &.{}, optimize, &diagnostic));
            try t.expect(std.mem.indexOf(u8, diagnostic.?.text(), case.expected) != null);
        }
        const failures = [_]struct { text: []const u8, expected: []const u8 }{
            .{ .text = "data:={}\nvalue:=data[\"absent\"]\nafter:=1", .expected = "has no key 'absent'" },
            .{ .text = "container:={\"value\":picture(640, 480)}\ncontainer[\"value\"].width=1\nafter:=1", .expected = "cannot assign field 'width'" },
            .{ .text = "container:=[(1,2)]\ncontainer[0].x=3\nafter:=1", .expected = "cannot assign field 'x'" },
            .{ .text = "fn read(value:any)->any return value[1] end\ndata:={}\nvalue:=read(data)\nafter:=1", .expected = "dictionary key must be string" },
            .{ .text = "struct Data value:int end\ncontainer:={\"value\":Data(1)}\ncontainer[\"value\"].value=\"bad\"\nafter:=1", .expected = "expected int, received string" },
        };
        for (failures) |case| {
            var program = try compileValid(&library, case.text, &.{}, optimize);
            defer program.deinit();
            var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
            defer runtime.deinit();
            var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
            defer machine.deinit();
            try t.expectError(error.RuntimeFailed, machine.execute(&.{}));
            const failure = machine.failure.?;
            try t.expect(std.mem.indexOf(u8, failure.text(), case.expected) != null);
            try t.expect(machine.getGlobal("after") == null);
            try t.expect(failure.diagnostic.span.end > failure.diagnostic.span.start);
        }
    }
}

fn allocationScenario(allocator: std.mem.Allocator, library: *typst.Library) !void {
    var diagnostic: ?l.compiler.Diagnostic = null;
    var program = try compile(allocator, library,
        \\struct Cell data:dict={"items":[]} end
        \\first:=Cell()
        \\first.data["items"]+=1
        \\second:=copy(first)
        \\second.data["items"]+=2
        \\data:={"first":first,"second":second}
        \\names:=data.keys()
        \\removed:=dict_remove(data,"first")
    , &.{}, true, &diagnostic);
    defer program.deinit();
    var runtime = try l.Runtime.init(allocator, allocator, library, .{});
    defer runtime.deinit();
    var machine = try l.Machine.init(allocator, &program, runtime.host(), .{});
    defer machine.deinit();
    _ = try machine.execute(&.{});
    try t.expect(machine.getGlobal("removed").?.boolean);
}

test "aggregate compilation and execution release every allocation on failure" {
    var library = try typst.Library.open(options.library_path);
    defer library.deinit();
    try allocationScenario(t.allocator, &library);
    // Backing allocator resizes can change the number of later allocations.
    // Force the allocating fallback so each injected failure index is stable.
    var stable = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    try t.checkAllAllocationFailures(stable.allocator(), allocationScenario, .{&library});
}
