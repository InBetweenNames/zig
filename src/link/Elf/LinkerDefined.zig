index: File.Index,

symtab: std.ArrayListUnmanaged(elf.Elf64_Sym) = .{},
strtab: std.ArrayListUnmanaged(u8) = .{},

symbols: std.ArrayListUnmanaged(Symbol) = .{},
symbols_extra: std.ArrayListUnmanaged(u32) = .{},
symbols_resolver: std.ArrayListUnmanaged(Elf.SymbolResolver.Index) = .{},

entry_index: ?Symbol.Index = null,
dynamic_index: ?Symbol.Index = null,
ehdr_start_index: ?Symbol.Index = null,
init_array_start_index: ?Symbol.Index = null,
init_array_end_index: ?Symbol.Index = null,
fini_array_start_index: ?Symbol.Index = null,
fini_array_end_index: ?Symbol.Index = null,
preinit_array_start_index: ?Symbol.Index = null,
preinit_array_end_index: ?Symbol.Index = null,
got_index: ?Symbol.Index = null,
plt_index: ?Symbol.Index = null,
end_index: ?Symbol.Index = null,
gnu_eh_frame_hdr_index: ?Symbol.Index = null,
dso_handle_index: ?Symbol.Index = null,
rela_iplt_start_index: ?Symbol.Index = null,
rela_iplt_end_index: ?Symbol.Index = null,
global_pointer_index: ?Symbol.Index = null,
start_stop_indexes: std.ArrayListUnmanaged(u32) = .{},

output_symtab_ctx: Elf.SymtabCtx = .{},

pub fn deinit(self: *LinkerDefined, allocator: Allocator) void {
    self.symtab.deinit(allocator);
    self.strtab.deinit(allocator);
    self.symbols.deinit(allocator);
    self.symbols_extra.deinit(allocator);
    self.symbols_resolver.deinit(allocator);
    self.start_stop_indexes.deinit(allocator);
}

pub fn init(self: *LinkerDefined, allocator: Allocator) !void {
    // Null byte in strtab
    try self.strtab.append(allocator, 0);
}

pub fn initSymbols(self: *LinkerDefined, elf_file: *Elf) !void {
    const newSymbolAssumeCapacity = struct {
        fn newSymbolAssumeCapacity(ld: *LinkerDefined, name_off: u32) Symbol.Index {
            const esym_index: u32 = @intCast(ld.symtab.items.len);
            const esym = ld.symtab.addOneAssumeCapacity();
            esym.* = .{
                .st_name = name_off,
                .st_info = elf.STB_GLOBAL << 4,
                .st_other = @intFromEnum(elf.STV.HIDDEN),
                .st_shndx = elf.SHN_ABS,
                .st_value = 0,
                .st_size = 0,
            };
            const index = ld.addSymbolAssumeCapacity();
            const symbol = &ld.symbols.items[index];
            symbol.name_offset = name_off;
            symbol.extra_index = ld.addSymbolExtraAssumeCapacity(.{});
            symbol.ref = .{ .index = 0, .file = 0 };
            symbol.esym_index = esym_index;
            symbol.version_index = elf_file.default_sym_version;
        }
    }.newSymbolAssumeCapacity;

    const gpa = elf_file.base.comp.gpa;

    var nsyms: usize = 0;
    if (elf_file.entry_name) |_| {
        nsyms += 1; // entry
    }
    nsyms += 1; // _DYNAMIC
    nsyms += 1; // __ehdr_start
    nsyms += 1; // __init_array_start
    nsyms += 1; // __init_array_end
    nsyms += 1; // __fini_array_start
    nsyms += 1; // __fini_array_end
    nsyms += 1; // __preinit_array_start
    nsyms += 1; // __preinit_array_end
    nsyms += 1; // _GLOBAL_OFFSET_TABLE_
    nsyms += 1; // _PROCEDURE_LINKAGE_TABLE_
    nsyms += 1; // _end
    if (elf_file.base.comp.link_eh_frame_hdr) {
        nsyms += 1; // __GNU_EH_FRAME_HDR
    }
    nsyms += 1; // __dso_handle
    nsyms += 1; // __rela_iplt_start
    nsyms += 1; // __rela_iplt_end
    if (elf_file.getTarget().cpu.arch.isRISCV() and elf_file.isEffectivelyDynLib()) {
        nsyms += 1; // __global_pointer$
    }

    var start_stop_count: usize = 0;
    for (elf_file.objects.items) |index| {
        for (elf_file.file(index).?.object.shdrs.items) |shdr| {
            if (elf_file.getStartStopBasename(shdr)) |_| {
                start_stop_count += 2; // __start_, __stop_
            }
        }
    }
    nsyms += start_stop_count;

    try self.start_stop_indexes.ensureTotalCapacityPrecise(gpa, start_stop_count);
    try self.symtab.ensureTotalCapacityPrecise(gpa, nsyms);
    try self.symbols.ensureTotalCapacityPrecise(gpa, nsyms);
    try self.symbols_extra.ensureTotalCapacityPrecise(gpa, nsyms * @sizeOf(Symbol.Extra));
    try self.symbols_resolver.ensureTotalCapacityPrecise(gpa, nsyms);
    self.symbols_resolver.resize(gpa, nsyms) catch unreachable;
    @memset(self.symbols_resolver.items, 0);

    if (elf_file.entry_name) |name| {
        self.entry_index = newSymbolAssumeCapacity(self, try self.addString(gpa, name));
    }

    self.dynamic_index = newSymbolAssumeCapacity(self, try self.addString(gpa, "_DYNAMIC"));
    self.ehdr_start_index = newSymbolAssumeCapacity(self, try self.addString(gpa, "__ehdr_start"));
    self.init_array_start_index = newSymbolAssumeCapacity(self, try self.addString(gpa, "__init_array_start"));
    self.init_array_end_index = newSymbolAssumeCapacity(self, try self.addString(gpa, "__init_array_end"));
    self.fini_array_start_index = newSymbolAssumeCapacity(self, try self.addString(gpa, "__fini_array_start"));
    self.fini_array_end_index = newSymbolAssumeCapacity(self, try self.addString(gpa, "__fini_array_end"));
    self.preinit_array_start_index = newSymbolAssumeCapacity(self, try self.addString(gpa, "__preinit_array_start"));
    self.preinit_array_end_index = newSymbolAssumeCapacity(self, try self.addString(gpa, "__preinit_array_end"));
    self.got_index = newSymbolAssumeCapacity(self, try self.addString(gpa, "_GLOBAL_OFFSET_TABLE_"));
    self.plt_index = newSymbolAssumeCapacity(self, try self.addString(gpa, "_PROCEDURE_LINKAGE_TABLE_"));
    self.end_index = newSymbolAssumeCapacity(self, try self.addString(gpa, "_end"));

    if (elf_file.base.comp.link_eh_frame_hdr) {
        self.gnu_eh_frame_hdr_index = newSymbolAssumeCapacity(self, try self.addString(gpa, "__GNU_EH_FRAME_HDR"));
    }

    self.dso_handle_index = newSymbolAssumeCapacity(self, try self.addString(gpa, "__dso_handle"));
    self.rela_iplt_start_index = newSymbolAssumeCapacity(self, try self.addString(gpa, "__rela_iplt_start"));
    self.rela_iplt_end_index = newSymbolAssumeCapacity(self, try self.addString(gpa, "__rela_iplt_end"));

    if (elf_file.getTarget().cpu.arch.isRISCV() and elf_file.isEffectivelyDynLib()) {
        self.global_pointer_index = newSymbolAssumeCapacity(self, try self.addString(gpa, "__global_pointer$"));
    }

    for (elf_file.objects.items) |index| {
        for (elf_file.file(index).?.object.shdrs.items) |shdr| {
            if (elf_file.getStartStopBasename(shdr)) |name| {
                const start_name = try std.fmt.allocPrintZ(gpa, "__start_{s}", .{name});
                defer gpa.free(start_name);
                const stop_name = try std.fmt.allocPrintZ(gpa, "__stop_{s}", .{name});
                defer gpa.free(stop_name);
                const start = newSymbolAssumeCapacity(self, try self.addString(gpa, start_name));
                const stop = newSymbolAssumeCapacity(self, try self.addString(gpa, stop_name));
                self.start_stop_indexes.appendSliceAssumeCapacity(&.{ start, stop });
            }
        }
    }
}

pub fn resolveSymbols(self: *LinkerDefined, elf_file: *Elf) !void {
    const gpa = elf_file.base.comp.gpa;

    for (self.symtab.items, self.symbols_resolver.items, 0..) |esym, *resolv, i| {
        const gop = try elf_file.resolver.getOrPut(gpa, .{
            .index = @intCast(i),
            .file = self.index,
        }, elf_file);
        if (!gop.found_existing) {
            gop.ref.* = .{ .index = 0, .file = 0 };
        }
        resolv.* = gop.index;

        if (esym.st_shndx == elf.SHN_UNDEF) continue;
        if (elf_file.symbol(gop.ref.*) == null) {
            gop.ref.* = .{ .index = @intCast(i), .file = self.index };
            continue;
        }

        if (self.asFile().symbolRank(esym, false) < elf_file.symbol(gop.ref.*).?.symbolRank(elf_file)) {
            gop.ref.* = .{ .index = @intCast(i), .file = self.index };
        }
    }
}

pub fn allocateSymbols(self: *LinkerDefined, elf_file: *Elf) void {
    const comp = elf_file.base.comp;
    const link_mode = comp.config.link_mode;

    const allocSymbol = struct {
        fn allocSymbol(ld: *LinkerDefined, index: Symbol.Index, value: u64, osec: u32, ef: *Elf) void {
            const sym = ef.symbol(ld.resolveSymbol(index, ef)).?;
            sym.value = @intCast(value);
            sym.output_section_index = osec;
        }
    }.allocSymbol;

    // _DYNAMIC
    if (elf_file.dynamic_section_index) |shndx| {
        const shdr = &elf_file.shdrs.items[shndx];
        allocSymbol(self, self.dynamic_index.?, shdr.sh_addr, shndx, elf_file);
    }

    // __ehdr_start
    allocSymbol(self, self.ehdr_start_index.?, elf_file.image_base, 1, elf_file);

    // __init_array_start, __init_array_end
    if (elf_file.sectionByName(".init_array")) |shndx| {
        const shdr = &elf_file.shdrs.items[shndx];
        allocSymbol(self, self.init_array_start_index.?, shdr.sh_addr, shndx, elf_file);
        allocSymbol(self, self.init_array_end_index.?, shdr.sh_addr + shdr.sh_size, shndx, elf_file);
    }

    // __fini_array_start, __fini_array_end
    if (elf_file.sectionByName(".fini_array")) |shndx| {
        const shdr = &elf_file.shdrs.items[shndx];
        allocSymbol(self, self.fini_array_start_index.?, shdr.sh_addr, shndx, elf_file);
        allocSymbol(self, self.fini_array_end_index.?, shdr.sh_addr + shdr.sh_size, shndx, elf_file);
    }

    // __preinit_array_start, __preinit_array_end
    if (elf_file.sectionByName(".preinit_array")) |shndx| {
        const shdr = &elf_file.shdrs.items[shndx];
        allocSymbol(self, self.preinit_array_start_index.?, shdr.sh_addr, shndx, elf_file);
        allocSymbol(self, self.preinit_array_end_index.?, shdr.sh_addr + shdr.sh_size, shndx, elf_file);
    }

    // _GLOBAL_OFFSET_TABLE_
    if (elf_file.getTarget().cpu.arch == .x86_64) {
        if (elf_file.got_plt_section_index) |shndx| {
            const shdr = elf_file.shdrs.items[shndx];
            allocSymbol(self, self.got_index.?, shdr.sh_addr, shndx, elf_file);
        }
    } else {
        if (elf_file.got_section_index) |shndx| {
            const shdr = elf_file.shdrs.items[shndx];
            allocSymbol(self, self.got_index.?, shdr.sh_addr, shndx, elf_file);
        }
    }

    // _PROCEDURE_LINKAGE_TABLE_
    if (elf_file.plt_section_index) |shndx| {
        const shdr = &elf_file.shdrs.items[shndx];
        allocSymbol(self, self.plt_index.?, shdr.sh_addr, shndx, elf_file);
    }

    // __dso_handle
    if (self.dso_handle_index) |index| {
        const shdr = &elf_file.shdrs.items[1];
        allocSymbol(self, index, shdr.sh_addr, 0, elf_file);
    }

    // __GNU_EH_FRAME_HDR
    if (elf_file.eh_frame_hdr_section_index) |shndx| {
        const shdr = &elf_file.shdrs.items[shndx];
        allocSymbol(self, self.gnu_eh_frame_hdr_index.?, shdr.sh_addr, shndx, elf_file);
    }

    // __rela_iplt_start, __rela_iplt_end
    if (elf_file.rela_dyn_section_index) |shndx| blk: {
        if (link_mode != .static or comp.config.pie) break :blk;
        const shdr = &elf_file.shdrs.items[shndx];
        const end_addr = shdr.sh_addr + shdr.sh_size;
        const start_addr = end_addr - elf_file.calcNumIRelativeRelocs() * @sizeOf(elf.Elf64_Rela);
        allocSymbol(self, self.rela_iplt_start_index.?, start_addr, shndx, elf_file);
        allocSymbol(self, self.rela_iplt_end_index.?, end_addr, shndx, elf_file);
    }

    // _end
    {
        var value: u64 = 0;
        var osec: u32 = 0;
        for (elf_file.shdrs.items, 0..) |shdr, shndx| {
            if (shdr.sh_flags & elf.SHF_ALLOC != 0) {
                value = shdr.sh_addr + shdr.sh_size;
                osec = shndx;
            }
        }
        allocSymbol(self, self.end_index.?, value, osec, elf_file);
    }

    // __global_pointer$
    if (self.global_pointer_index) |index| {
        const value, const osec = if (elf_file.sectionByName(".sdata")) |shndx| .{
            elf_file.shdrs.items[shndx].sh_addr + 0x800,
            shndx,
        } else .{ 0, 0 };
        allocSymbol(self, index, value, osec, elf_file);
    }

    // __start_*, __stop_*
    {
        var index: usize = 0;
        while (index < self.start_stop_indexes.items.len) : (index += 2) {
            const start_ref = self.resolveSymbol(self.start_stop_indexes.items[index]);
            const start = elf_file.symbol(start_ref).?;
            const name = start.name(elf_file);
            const stop_ref = self.resolveSymbol(self.start_stop_indexes.items[index + 1]);
            const stop = elf_file.symbol(stop_ref).?;
            const shndx = elf_file.sectionByName(name["__start_".len..]).?;
            const shdr = &elf_file.shdrs.items[shndx];
            start.value = @intCast(shdr.sh_addr);
            start.output_section_index = shndx;
            stop.value = @intCast(shdr.sh_addr + shdr.sh_size);
            stop.output_section_index = shndx;
        }
    }
}

pub fn globals(self: *LinkerDefined) []Symbol {
    return self.symbols.items;
}

pub fn updateSymtabSize(self: *LinkerDefined, elf_file: *Elf) void {
    for (self.globals(), self.symbols_resolver.items) |*global, resolv| {
        const ref = elf_file.resolver.get(resolv).?;
        const ref_sym = elf_file.symbol(ref) orelse continue;
        if (ref_sym.file(elf_file).?.index() != self.index) continue;
        global.flags.output_symtab = true;
        if (global.isLocal(elf_file)) {
            global.addExtra(.{ .symtab = self.output_symtab_ctx.nlocals }, elf_file);
            self.output_symtab_ctx.nlocals += 1;
        } else {
            global.addExtra(.{ .symtab = self.output_symtab_ctx.nglobals }, elf_file);
            self.output_symtab_ctx.nglobals += 1;
        }
        self.output_symtab_ctx.strsize += @as(u32, @intCast(global.name(elf_file).len)) + 1;
    }
}

pub fn writeSymtab(self: *LinkerDefined, elf_file: *Elf) void {
    for (self.globals(), self.symbols_resolver.items) |global, resolv| {
        const ref = elf_file.resolver.get(resolv).?;
        const ref_sym = elf_file.symbol(ref) orelse continue;
        if (ref_sym.file(elf_file).?.index() != self.index) continue;
        const idx = global.outputSymtabIndex(elf_file) orelse continue;
        const st_name = @as(u32, @intCast(elf_file.strtab.items.len));
        elf_file.strtab.appendSliceAssumeCapacity(global.name(elf_file));
        elf_file.strtab.appendAssumeCapacity(0);
        const out_sym = &elf_file.symtab.items[idx];
        out_sym.st_name = st_name;
        global.setOutputSym(elf_file, out_sym);
    }
}

pub fn asFile(self: *LinkerDefined) File {
    return .{ .linker_defined = self };
}

fn addString(self: *LinkerDefined, allocator: Allocator, str: []const u8) !u32 {
    const off: u32 = @intCast(self.strtab.items.len);
    try self.strtab.ensureUnusedCapacity(allocator, str.len + 1);
    self.strtab.appendSliceAssumeCapacity(str);
    self.strtab.appendAssumeCapacity(0);
    return off;
}

pub fn getString(self: LinkerDefined, off: u32) [:0]const u8 {
    assert(off < self.strtab.items.len);
    return mem.sliceTo(@as([*:0]const u8, @ptrCast(self.strtab.items.ptr + off)), 0);
}

pub fn resolveSymbol(self: LinkerDefined, index: Symbol.Index, elf_file: *Elf) Elf.Ref {
    const resolv = self.symbols_resolver.items[index];
    return elf_file.resolver.get(resolv).?;
}

pub fn addSymbol(self: *LinkerDefined, allocator: Allocator) !Symbol.Index {
    try self.symbols.ensureUnusedCapacity(allocator, 1);
    const index: Symbol.Index = @intCast(self.symbols.items.len);
    self.symbols.appendAssumeCapacity(.{ .file_index = self.index });
    return index;
}

pub fn addSymbolExtra(self: *LinkerDefined, allocator: Allocator, extra: Symbol.Extra) !u32 {
    const fields = @typeInfo(Symbol.Extra).Struct.fields;
    try self.symbols_extra.ensureUnusedCapacity(allocator, fields.len);
    return self.addSymbolExtraAssumeCapacity(extra);
}

pub fn addSymbolExtraAssumeCapacity(self: *LinkerDefined, extra: Symbol.Extra) u32 {
    const index = @as(u32, @intCast(self.symbols_extra.items.len));
    const fields = @typeInfo(Symbol.Extra).Struct.fields;
    inline for (fields) |field| {
        self.symbols_extra.appendAssumeCapacity(switch (field.type) {
            u32 => @field(extra, field.name),
            else => @compileError("bad field type"),
        });
    }
    return index;
}

pub fn symbolExtra(self: *LinkerDefined, index: u32) Symbol.Extra {
    const fields = @typeInfo(Symbol.Extra).Struct.fields;
    var i: usize = index;
    var result: Symbol.Extra = undefined;
    inline for (fields) |field| {
        @field(result, field.name) = switch (field.type) {
            u32 => self.symbols_extra.items[i],
            else => @compileError("bad field type"),
        };
        i += 1;
    }
    return result;
}

pub fn setSymbolExtra(self: *LinkerDefined, index: u32, extra: Symbol.Extra) void {
    const fields = @typeInfo(Symbol.Extra).Struct.fields;
    inline for (fields, 0..) |field, i| {
        self.symbols_extra.items[index + i] = switch (field.type) {
            u32 => @field(extra, field.name),
            else => @compileError("bad field type"),
        };
    }
}

pub fn fmtSymtab(self: *LinkerDefined, elf_file: *Elf) std.fmt.Formatter(formatSymtab) {
    return .{ .data = .{
        .self = self,
        .elf_file = elf_file,
    } };
}

const FormatContext = struct {
    self: *LinkerDefined,
    elf_file: *Elf,
};

fn formatSymtab(
    ctx: FormatContext,
    comptime unused_fmt_string: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = unused_fmt_string;
    _ = options;
    try writer.writeAll("  globals\n");
    for (ctx.self.globals()) |index| {
        const global = ctx.elf_file.symbol(index);
        try writer.print("    {}\n", .{global.fmt(ctx.elf_file)});
    }
}

const assert = std.debug.assert;
const elf = std.elf;
const mem = std.mem;
const std = @import("std");

const Allocator = mem.Allocator;
const Atom = @import("Atom.zig");
const Elf = @import("../Elf.zig");
const File = @import("file.zig").File;
const LinkerDefined = @This();
const Symbol = @import("Symbol.zig");
