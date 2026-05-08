-- lib/type/static/arena.lua
-- Arena allocators for flat FFI arrays with bump allocation and reset.
-- Also includes the list pool for variable-length int32 sequences.

local ffi = require("ffi")

local M = {}

--:: ArenaBase = { cap: integer, len: integer, items: unknown, grow: (ArenaBase) -> (), ... }
--:: PoolBase = { cap: integer, len: integer, items: Ptr<integer>, grow: (PoolBase) -> (), ... }

-- Generic arena factory for a given FFI ctype.
-- Returns an arena with alloc/reset/grow/get and raw .items access.
local function new_arena(ct, initial_cap)
    initial_cap = initial_cap or 1024
    local ct_ptr = ffi.typeof("$*", ct)
    local ct_arr = ffi.typeof("$[?]" --[[: any]], ct) --[[:! Ctype<unknown>]]
    local elem_size = ffi.sizeof(ct)
    local arena = {
        items = ct_arr(initial_cap),
        cap = initial_cap,
        len = 0,
    }

    --: (ArenaBase) -> integer
    function arena:alloc()
        local i = self.len
        local cap = self.cap
        if i >= cap then self:grow() end
        self.len = i + 1
        return i
    end

    function arena:get(i)
        return self.items + i
    end

    function arena:reset()
        self.len = 0
    end

    --: (ArenaBase) -> ()
    function arena:grow()
        local old_cap = self.cap
        local new_cap = old_cap * 2
        local new_items = ct_arr(new_cap)
        local old_len = self.len
        ffi.copy(new_items --[[:! cdata]], self.items --[[:! cdata]], old_len * elem_size)
        self.items = new_items
        self.cap = new_cap
    end

    return arena
end

--: (integer | nil) -> ASTNodeArena
function M.new_node_arena(initial_cap)
    return new_arena(ffi.typeof("ASTNode" --[[: any]]) --[[: any]], initial_cap) --[[: ASTNodeArena]]
end

--: (integer | nil) -> TypeSlotArena
function M.new_type_arena(initial_cap)
    return new_arena(ffi.typeof("TypeSlot" --[[: any]]) --[[: any]], initial_cap) --[[: TypeSlotArena]]
end

--: (integer | nil) -> FieldEntryArena
function M.new_field_arena(initial_cap)
    return new_arena(ffi.typeof("FieldEntry" --[[: any]]) --[[: any]], initial_cap) --[[: FieldEntryArena]]
end

-- List pool: flat int32_t array for variable-length sequences.
-- Used for storing lists of child node IDs, parameter IDs, etc.
--: (integer | nil) -> ListPool
function M.new_list_pool(initial_cap)
    initial_cap = initial_cap or 4096
    local int32_arr = ffi.typeof("int32_t[?]" --[[: any]])
    local pool = {
        items = int32_arr(initial_cap),
        cap = initial_cap,
        len = 0,
    }

    --: (ListPool) -> integer
    function pool:mark()
        return self.len
    end

    --: (ListPool, integer) -> ()
    function pool:push(value)
        local i = self.len
        local cap = self.cap
        if i >= cap then self:grow() end
        self.items[i] = value
        self.len = i + 1
    end

    --: (ListPool, integer) -> (integer, integer)
    function pool:since(start)
        return start, self.len - start
    end

    --: (ListPool, integer) -> integer
    function pool:get(i)
        return self.items[i]
    end

    function pool:reset()
        self.len = 0
    end

    --: (ListPool) -> ()
    function pool:grow()
        local old_cap = self.cap
        local new_cap = old_cap * 2
        local new_items = int32_arr(new_cap)
        local old_len = self.len
        ffi.copy(new_items, self.items, old_len * 4)
        self.items = new_items
        self.cap = new_cap
    end

    return pool
end

return M
