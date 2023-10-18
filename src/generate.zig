const std = @import("std");

var allocator: std.mem.Allocator = undefined;
const writer = std.io.getStdOut().writer();

const hash = std.hash.Fnv1a_32.hash;

const defines = [_][]const u8{ "IMGUI_VERSION", "IMGUI_VERSION_NUM" };
const namespaces = [_][]const u8{ "ImGui_", "ImGui", "Im" };

var defines_set: std.StringHashMapUnmanaged(void) = .{};
var known_enums: std.StringHashMapUnmanaged(void) = .{};
var type_aliases: std.StringHashMapUnmanaged([]const u8) = .{};
var ignored_functions: std.StringHashMapUnmanaged(void) = .{};

fn write(str: []const u8) void {
    writer.writeAll(str) catch unreachable;
}

fn print(comptime format: []const u8, args: anytype) void {
    std.fmt.format(writer, format, args) catch unreachable;
}

fn trimPrefixOpt(name: []const u8, prefix: []const u8) ?[]const u8 {
    return if (std.mem.startsWith(u8, name, prefix))
        name[prefix.len..]
    else
        null;
}

fn trimPrefix(name: []const u8, prefix: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, name, prefix))
        name[prefix.len..]
    else
        name;
}

fn trimNamespace(name: []const u8) []const u8 {
    for (namespaces) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) {
            return name[prefix.len..];
        }
    }

    return name;
}

fn trimUnderscore(name: []const u8) []const u8 {
    return if (name[name.len - 1] == '_') name[0 .. name.len - 1] else name;
}

fn emitDefine(x: std.json.Value) void {
    const name = x.object.get("name").?.string;
    if (defines_set.contains(name)) {
        const content = x.object.get("content").?.string;
        print("pub const {s} = {s};\n", .{ name, content });
    }
}

fn emitDefines(x: std.json.Value) void {
    for (x.array.items) |item| emitDefine(item);

    write("const IM_DRAWLIST_TEX_LINES_WIDTH_MAX = 63;\n");
    write("const IM_UNICODE_CODEPOINT_MAX = 0xFFFF;\n");
}

fn emitEnumElement(x: std.json.Value, enum_name: []const u8) void {
    const full_name = x.object.get("name").?.string;
    const name = trimPrefix(full_name, enum_name);
    if (x.object.get("value")) |value| {
        print("    {s} = {},\n", .{ name, value.integer });
    } else {
        print("    {s},\n", .{name});
    }
}

fn emitEnumElements(x: std.json.Value, enum_name: []const u8) void {
    for (x.array.items) |item| emitEnumElement(item, enum_name);
}

fn emitEnum(x: std.json.Value) void {
    const full_name = x.object.get("name").?.string;
    const name = trimNamespace(trimUnderscore(full_name));
    print("pub const {s} = enum(c_int) {{\n", .{name});
    emitEnumElements(x.object.get("elements").?, full_name);
    write("};\n");

    known_enums.put(allocator, name, {}) catch unreachable;
}

fn emitEnums(x: std.json.Value) void {
    for (x.array.items) |item| emitEnum(item);
}

fn emitFunctionParameters(x: std.json.Value) void {
    for (x.array.items, 0..) |item, i| {
        if (i > 0) write(", ");
        emitTypeDesc(item);
    }
}

fn emitTypeDesc(x: std.json.Value) void {
    const kind = x.object.get("kind").?.string;
    switch (hash(kind)) {
        hash("Builtin") => {
            const builtin_type = x.object.get("builtin_type").?.string;
            write(switch (hash(builtin_type)) {
                hash("void") => "void",
                hash("char") => "c_char",
                hash("unsigned_char") => "c_char", // ???
                hash("short") => "c_short",
                hash("unsigned_short") => "c_ushort",
                hash("int") => "c_int",
                hash("unsigned_int") => "c_uint",
                hash("long") => "c_long",
                hash("unsigned_long") => "c_ulong",
                hash("long_long") => "c_longlong",
                hash("unsigned_long_long") => "c_ulonglong",
                hash("float") => "f32",
                hash("double") => "f64",
                hash("long_double") => "c_longdouble",
                hash("bool") => "bool",
                else => std.debug.panic("unknown builtin_type {s}", .{builtin_type}),
            });
        },
        hash("User") => {
            const full_name = x.object.get("name").?.string;
            if (type_aliases.get(full_name)) |alias| {
                write(alias);
            } else {
                const name = trimNamespace(full_name);
                write(name);
            }
        },
        hash("Pointer") => {
            write("*");
            emitTypeDesc(x.object.get("inner_type").?);
        },
        hash("Type") => {
            emitTypeDesc(x.object.get("inner_type").?);
        },
        hash("Function") => {
            write("const fn(");
            emitFunctionParameters(x.object.get("parameters").?);
            write(") callconv(.C) ");
            emitTypeDesc(x.object.get("return_type").?);
        },
        hash("Array") => {
            if (x.object.get("bounds")) |bounds| {
                if (trimPrefixOpt(bounds.string, "ImGui")) |name| {
                    if (std.mem.indexOfScalar(u8, name, '_')) |i| {
                        print("[{s}.{s}]", .{ name[0..i], name[i + 1 .. name.len] });
                    } else {
                        print("[{s}]", .{bounds.string});
                    }
                } else {
                    print("[{s}]", .{bounds.string});
                }
            } else {
                write("[*]");
            }
            emitTypeDesc(x.object.get("inner_type").?);
        },
        else => std.debug.panic("unknown type kind {s}", .{kind}),
    }
}

fn emitType(x: std.json.Value) void {
    const description = x.object.get("description").?;
    emitTypeDesc(description);
}

fn emitTypedef(x: std.json.Value) void {
    const full_name = x.object.get("name").?.string;
    const name = trimNamespace(full_name);
    if (!known_enums.contains(name)) {
        print("pub const {s} = ", .{name});
        emitType(x.object.get("type").?);
        write(";\n");
    }
}

fn emitTypedefs(x: std.json.Value) void {
    for (x.array.items) |item| emitTypedef(item);

    write("pub const Wchar = Wchar16;\n"); // IMGUI_USE_WCHAR32
}

fn emitStructField(x: std.json.Value) void {
    const full_name = x.object.get("name").?.string;
    const name = full_name;
    print("    {s}: ", .{name});
    emitType(x.object.get("type").?);
    write(",\n");
}

fn emitStructFields(x: std.json.Value) void {
    for (x.array.items) |item| emitStructField(item);
}

fn emitStruct(x: std.json.Value) void {
    const full_name = x.object.get("name").?.string;
    const name = trimNamespace(full_name);
    print("pub const {s} = extern struct {{\n", .{name});
    emitStructFields(x.object.get("fields").?);
    write("};\n");
}

fn emitStructs(x: std.json.Value) void {
    for (x.array.items) |item| emitStruct(item);
}

fn emitFunctionArgument(x: std.json.Value) void {
    if (x.object.get("is_varargs").?.bool) {
        write("...");
    } else {
        const full_name = x.object.get("name").?.string;
        const name = full_name;
        print("{s}: ", .{name});
        if (x.object.get("type")) |_| {
            emitType(x.object.get("type").?);
        } else {
            std.debug.print("no type {s}\n", .{full_name});
        }
    }
}

fn emitFunctionArguments(x: std.json.Value) void {
    for (x.array.items, 0..) |item, i| {
        if (i > 0) write(", ");
        emitFunctionArgument(item);
    }
}

fn emitExternFunction(x: std.json.Value) void {
    const full_name = x.object.get("name").?.string;
    if (ignored_functions.contains(full_name))
        return;

    print("extern fn {s}(", .{full_name});
    emitFunctionArguments(x.object.get("arguments").?);
    write(") ");
    emitType(x.object.get("return_type").?);
    write(";\n");
}

fn emitPubFunction(x: std.json.Value) void {
    const full_name = x.object.get("name").?.string;
    if (ignored_functions.contains(full_name))
        return;

    const name = trimNamespace(full_name);
    print("pub const {s} = {s};\n", .{ name, full_name });
}

fn emitFunctions(x: std.json.Value) void {
    for (x.array.items) |item| emitExternFunction(item);
    for (x.array.items) |item| emitPubFunction(item);
}

fn emit(x: std.json.Value) void {
    write("const std = @import(\"std\");\n");
    write("const c = @cImport({\n");
    write("    @cInclude(\"stdarg.h\");\n");
    write("});\n");
    emitDefines(x.object.get("defines").?);
    emitEnums(x.object.get("enums").?);
    emitTypedefs(x.object.get("typedefs").?);
    emitStructs(x.object.get("structs").?);
    emitFunctions(x.object.get("functions").?);
    write("test {\n");
    write("    std.testing.refAllDeclsRecursive(@This());\n");
    write("}\n");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    allocator = gpa.allocator();

    for (defines) |define| try defines_set.put(allocator, define, {});
    try type_aliases.put(allocator, "va_list", "c.va_list");
    try type_aliases.put(allocator, "size_t", "usize");
    try ignored_functions.put(allocator, "ImStr_FromCharStr", {}); // IMGUI_HAS_IMSTR
    try ignored_functions.put(allocator, "ImGui_GetKeyIndex", {}); // IMGUI_DISABLE_OBSOLETE_KEYIO
    try known_enums.put(allocator, "Wchar", {}); // IMGUI_USE_WCHAR32

    defer defines_set.deinit(allocator);
    defer known_enums.deinit(allocator);
    defer type_aliases.deinit(allocator);
    defer ignored_functions.deinit(allocator);

    var file = try std.fs.cwd().openFile("cimgui.json", .{});
    defer file.close();

    const file_data = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(file_data);

    var valueTree = try std.json.parseFromSlice(std.json.Value, allocator, file_data, .{});
    defer valueTree.deinit();

    emit(valueTree.value);
}
