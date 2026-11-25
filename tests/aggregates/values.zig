//! Aggregate value semantics: named arguments, nested writes, shallow copies and dictionary order.
const std = @import("std");
const t = std.testing;
const huak = @import("huak");
const typst = @import("libtypst");
const l = huak.language;
const options = @import("test_options");
const harness = @import("harness.zig");

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
        var program = try harness.compileValid(&library, text, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try harness.execute(&machine);
        try harness.expectInts(machine.getGlobal("events").?, &.{ 3, 1, 20, 10, 20, 30 });
        try harness.expectInts(machine.getGlobal("function_events").?, &.{ 6, 4 });
        try harness.expectInts(machine.getGlobal("collected").?, &.{ 4, 20, 6 });
        try t.expectEqual(@as(i64, 1), machine.getGlobal("chosen").?.record.fields[0].int);
        try t.expectEqual(@as(i64, 20), machine.getGlobal("chosen").?.record.fields[1].int);
        const first = machine.getGlobal("one").?.record.fields[0].dict;
        const second = machine.getGlobal("two").?.record.fields[0].dict;
        try t.expect(first != second);
        try harness.expectInts(first.entries.get("items").?, &.{1});
        try harness.expectInts(second.entries.get("items").?, &.{});
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
        var program = try harness.compileValid(&library, text, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try harness.execute(&machine);
        for ([_][]const u8{ "append_order", "field_order", "index_order" }) |name| try harness.expectInts(machine.getGlobal(name).?, &.{ 1, 2, 3, 4 });
        try harness.expectInts(machine.getGlobal("list_order").?, &.{ 1, 2, 4 });
        try harness.expectInts(machine.getGlobal("appended").?, &.{7});
        try harness.expectInts(machine.getGlobal("assigned").?, &.{8});
        const row = l.types.sequence(machine.getGlobal("rows").?).?[0].dict;
        try t.expect(row != machine.getGlobal("previous_row").?.dict);
        try t.expect(row.entries.get("node").?.record != machine.getGlobal("indexed").?.record);
        try t.expect(row.entries.get("node").?.record != machine.getGlobal("item").?.record);
        try harness.expectInts(row.entries.get("node").?.record.fields[0], &.{});
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
        var program = try harness.compileValid(&library, text, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try harness.execute(&machine);
        const original = machine.getGlobal("original").?.record;
        const copied = machine.getGlobal("record_copy").?.record;
        try t.expect(original != copied);
        try t.expect(original.fields[0].dict != copied.fields[0].dict);
        try harness.expectInts(original.fields[0].dict.entries.get("items").?, &.{ 1, 2, 3 });
        try harness.expectInts(copied.fields[0].dict.entries.get("items").?, &.{4});
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
        var program = try harness.compileValid(&library, text, &.{}, optimize);
        defer program.deinit();
        var runtime = try l.Runtime.init(t.allocator, t.allocator, &library, .{});
        defer runtime.deinit();
        var machine = try l.Machine.init(t.allocator, &program, runtime.host(), .{});
        defer machine.deinit();
        try harness.execute(&machine);
        try harness.expectStrings(machine.getGlobal("before").?, &.{ "first", "second", "third" });
        try harness.expectStrings(machine.getGlobal("middle").?, &.{ "first", "third" });
        try harness.expectStrings(machine.getGlobal("after").?, &.{ "first", "third", "second" });
        try t.expect(machine.getGlobal("removed").?.boolean);
        try t.expect(!machine.getGlobal("missing").?.boolean);
        try t.expect(machine.getGlobal("exists").?.boolean);
    }
}
