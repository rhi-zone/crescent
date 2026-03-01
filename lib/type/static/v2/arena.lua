-- lib/type/static/v2/arena.lua
-- Arena allocators for flat FFI arrays with bump allocation and reset.
-- Also includes the list pool for variable-length int32 sequences.

local ffi = require("ffi")

local M = {}

-- Generic arena factory for a given FFI ctype.
-- Returns an arena with alloc/reset/grow/get and raw .items access.
local function new_arena(ct, initial_cap)
    initial_cap = initial_cap or 1024
    local ct_ptr = ffi.typeof("$*", ct)
    local ct_arr = ffi.typeof("$[?]", ct)
    local elem_size = ffi.sizeof(ct)
    local arena = {
        items = ct_arr(initial_cap),
        cap = initial_cap,
        len = 0,
    }

    function arena:alloc()
        local i = self.len
        if i >= self.cap then self:grow() end
        self.len = i + 1
        return i
    end

    function arena:get(i)
        return self.items + i
    end

    function arena:reset()
        self.len = 0
    end

    function arena:grow()
        local new_cap = self.cap * 2
        local new_items = ct_arr(new_cap)
        ffi.copy(new_items, self.items, self.len * elem_size)
        self.items = new_items
        self.cap = new_cap
    end

    return arena
end

function M.new_node_arena(initial_cap)
    return new_arena(ffi.typeof("ASTNode"), initial_cap)
end

function M.new_type_arena(initial_cap)
    return new_arena(ffi.typeof("TypeSlot"), initial_cap)
end

function M.new_field_arena(initial_cap)
    return new_arena(ffi.typeof("FieldEntry"), initial_cap)
end

-- List pool: flat int32_t array for variable-length sequences.
-- Used for storing lists of child node IDs, parameter IDs, etc.
function M.new_list_pool(initial_cap)
    initial_cap = initial_cap or 4096
    local int32_arr = ffi.typeof("int32_t[?]")
    local pool = {
        items = int32_arr(initial_cap),
        cap = initial_cap,
        len = 0,
    }

    function pool:mark()
        return self.len
    end

    function pool:push(value)
        local i = self.len
        if i >= self.cap then self:grow() end
        self.items[i] = value
        self.len = i + 1
    end

    function pool:since(start)
        return start, self.len - start
    end

    function pool:get(i)
        return self.items[i]
    end

    function pool:reset()
        self.len = 0
    end

    function pool:grow()
        local new_cap = self.cap * 2
        local new_items = int32_arr(new_cap)
        ffi.copy(new_items, self.items, self.len * 4)
        self.items = new_items
        self.cap = new_cap
    end

    return pool
end

return M
