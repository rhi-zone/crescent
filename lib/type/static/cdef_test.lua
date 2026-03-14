-- lib/type/static/cdef_test.lua
-- Tests for cdef.lua: C declaration → TypeSlot conversion.

local assert    = require("lib.test.assert")
local defs      = require("lib.type.static.defs")
local intern    = require("lib.type.static.intern")
local types_mod = require("lib.type.static.types")
local env_mod   = require("lib.type.static.env")
local cdef_mod  = require("lib.type.static.cdef")

---------------------------------------------------------------------------
-- Minimal ctx factory
-- Creates a types_mod ctx + scope, then runs cdef.init so T_FFI_C is ready.
---------------------------------------------------------------------------

local function new_ctx()
    local pool = intern.new()
    local ctx  = types_mod.new_ctx(pool)
    ctx.scope  = env_mod.new(0)
    cdef_mod.init(ctx)
    return ctx
end

---------------------------------------------------------------------------
-- Helper: look up a field by name in ctx.T_FFI_C.
-- Returns the field's type_id or nil.
---------------------------------------------------------------------------

local function ffi_c_field(ctx, name)
    local name_id = intern.intern(ctx.pool, name)
    local fe = types_mod.table_field(ctx, ctx.T_FFI_C, name_id)
    return fe and types_mod.find(ctx, fe.type_id) or nil
end

---------------------------------------------------------------------------
-- Tests
---------------------------------------------------------------------------

assert.describe("cdef: init", function()
    assert.it("allocates ctx.T_FFI_C as an open table", function()
        local ctx = new_ctx()
        assert.ok(ctx.T_FFI_C, "T_FFI_C should be set")
        local t = ctx.types:get(ctx.T_FFI_C)
        assert.eq(t.tag, defs.TAG_TABLE)
        -- Open table: row_var_id >= 0
        assert.ok(t.data[4] >= 0, "T_FFI_C should be an open table (row_var_id >= 0)")
    end)

    assert.it("allocates ctx.cdef_typedefs as an empty table", function()
        local ctx = new_ctx()
        assert.ok(ctx.cdef_typedefs, "cdef_typedefs should be set")
        assert.eq(type(ctx.cdef_typedefs), "table")
    end)

    assert.it("registers ffi_C type alias in scope", function()
        local ctx = new_ctx()
        local ffi_C_id = intern.intern(ctx.pool, "ffi_C")
        local alias = env_mod.lookup_type(ctx.scope, ffi_C_id)
        assert.ok(alias, "ffi_C alias should be in scope")
        assert.eq(alias.body, ctx.T_FFI_C)
    end)
end)

assert.describe("cdef: void foo(void)", function()
    assert.it("registers foo as a function type in T_FFI_C", function()
        local ctx = new_ctx()
        cdef_mod.process(ctx, "void foo(void);")
        local foo_tid = ffi_c_field(ctx, "foo")
        assert.ok(foo_tid, "foo should be in ffi.C")
        local t = ctx.types:get(foo_tid)
        assert.eq(t.tag, defs.TAG_FUNCTION)
    end)

    assert.it("foo has no parameters and no return value", function()
        local ctx = new_ctx()
        cdef_mod.process(ctx, "void foo(void);")
        local foo_tid = ffi_c_field(ctx, "foo")
        local t = ctx.types:get(foo_tid)
        -- params_len == 0
        assert.eq(t.data[1], 0)
        -- returns_len == 0 (void)
        assert.eq(t.data[3], 0)
    end)
end)

assert.describe("cdef: int add(int a, int b)", function()
    assert.it("registers add as a function type in T_FFI_C", function()
        local ctx = new_ctx()
        cdef_mod.process(ctx, "int add(int a, int b);")
        local add_tid = ffi_c_field(ctx, "add")
        assert.ok(add_tid, "add should be in ffi.C")
        local t = ctx.types:get(add_tid)
        assert.eq(t.tag, defs.TAG_FUNCTION)
    end)

    assert.it("add takes 2 integer params", function()
        local ctx = new_ctx()
        cdef_mod.process(ctx, "int add(int a, int b);")
        local add_tid = ffi_c_field(ctx, "add")
        local t = ctx.types:get(add_tid)
        assert.eq(t.data[1], 2)
        -- Each param should be T_INTEGER
        local p0 = types_mod.find(ctx, ctx.lists:get(t.data[0]))
        local p1 = types_mod.find(ctx, ctx.lists:get(t.data[0] + 1))
        assert.eq(p0, ctx.T_INTEGER)
        assert.eq(p1, ctx.T_INTEGER)
    end)

    assert.it("add returns integer", function()
        local ctx = new_ctx()
        cdef_mod.process(ctx, "int add(int a, int b);")
        local add_tid = ffi_c_field(ctx, "add")
        local t = ctx.types:get(add_tid)
        assert.eq(t.data[3], 1)
        local ret = types_mod.find(ctx, ctx.lists:get(t.data[2]))
        assert.eq(ret, ctx.T_INTEGER)
    end)
end)

assert.describe("cdef: typedef struct Point", function()
    assert.it("registers Point as a type alias in scope", function()
        local ctx = new_ctx()
        cdef_mod.process(ctx, "typedef struct { int x; int y; } Point;")
        local point_id = intern.intern(ctx.pool, "Point")
        local alias = env_mod.lookup_type(ctx.scope, point_id)
        assert.ok(alias, "Point alias should be in scope")
    end)

    assert.it("Point is a table type with x and y fields", function()
        local ctx = new_ctx()
        cdef_mod.process(ctx, "typedef struct { int x; int y; } Point;")
        local point_id = intern.intern(ctx.pool, "Point")
        local alias = env_mod.lookup_type(ctx.scope, point_id)
        local resolved = types_mod.find(ctx, alias.body)
        local t = ctx.types:get(resolved)
        assert.eq(t.tag, defs.TAG_TABLE)
        -- Verify x field
        local x_id = intern.intern(ctx.pool, "x")
        local fe_x = types_mod.table_field(ctx, resolved, x_id)
        assert.ok(fe_x, "Point should have x field")
        assert.eq(types_mod.find(ctx, fe_x.type_id), ctx.T_INTEGER)
        -- Verify y field
        local y_id = intern.intern(ctx.pool, "y")
        local fe_y = types_mod.table_field(ctx, resolved, y_id)
        assert.ok(fe_y, "Point should have y field")
        assert.eq(types_mod.find(ctx, fe_y.type_id), ctx.T_INTEGER)
    end)

    assert.it("Point is stored in cdef_typedefs", function()
        local ctx = new_ctx()
        cdef_mod.process(ctx, "typedef struct { int x; int y; } Point;")
        local point_id = intern.intern(ctx.pool, "Point")
        assert.ok(ctx.cdef_typedefs[point_id], "Point should be in cdef_typedefs")
    end)
end)

assert.describe("cdef: char *strdup(const char *s)", function()
    assert.it("registers strdup returning string (char* → string)", function()
        local ctx = new_ctx()
        cdef_mod.process(ctx, "char *strdup(const char *s);")
        local strdup_tid = ffi_c_field(ctx, "strdup")
        assert.ok(strdup_tid, "strdup should be in ffi.C")
        local t = ctx.types:get(strdup_tid)
        assert.eq(t.tag, defs.TAG_FUNCTION)
        -- Return type should be T_STRING (char* → string)
        assert.eq(t.data[3], 1)
        local ret = types_mod.find(ctx, ctx.lists:get(t.data[2]))
        assert.eq(ret, ctx.T_STRING)
    end)
end)

assert.describe("cdef: T_FFI_C field access", function()
    assert.it("T_FFI_C accumulates fields across process calls", function()
        local ctx = new_ctx()
        cdef_mod.process(ctx, "void foo(void);")
        cdef_mod.process(ctx, "int bar(void);")
        local foo_tid = ffi_c_field(ctx, "foo")
        local bar_tid = ffi_c_field(ctx, "bar")
        assert.ok(foo_tid, "foo should be in ffi.C after two process calls")
        assert.ok(bar_tid, "bar should be in ffi.C after two process calls")
    end)

    assert.it("two process calls share the same T_FFI_C table", function()
        local ctx = new_ctx()
        local t_before = ctx.T_FFI_C
        cdef_mod.process(ctx, "void foo(void);")
        -- T_FFI_C is mutated in-place by table_add_field; the ID is stable
        assert.eq(ctx.T_FFI_C, t_before)
    end)
end)

assert.describe("cdef: enum values", function()
    assert.it("enum constants are integer fields in T_FFI_C", function()
        local ctx = new_ctx()
        cdef_mod.process(ctx, "enum Color { RED = 0, GREEN = 1, BLUE = 2 };")
        local red_tid   = ffi_c_field(ctx, "RED")
        local green_tid = ffi_c_field(ctx, "GREEN")
        assert.ok(red_tid,   "RED should be in ffi.C")
        assert.ok(green_tid, "GREEN should be in ffi.C")
        assert.eq(red_tid,   ctx.T_INTEGER)
        assert.eq(green_tid, ctx.T_INTEGER)
    end)
end)
