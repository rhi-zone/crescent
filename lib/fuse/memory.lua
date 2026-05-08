local ffi = require("ffi")
local fuse = require("lib.fuse")
local time = require("lib.time")

--[[TODO: go/rust compiler without extra fs artifacts]]
--[[TODO: npm script runner wrapper without physical node_modules]]
ffi.cdef [[
	void *memcpy(void *dest, const void *src, size_t n);
]]

--: (string | Ctype<unknown>) -> integer
local sizeof = ffi.sizeof
local mk_buf = ffi.typeof("char [?]") --[[:! Ctype<unknown>]]

--:: fuse_memory_entry = { data: Ctype<unknown> | nil, created: number, modified: number, children: { [string]: fuse_memory_entry } | nil }

local mod = {}

--: (fuse_memory_entry | nil) -> unknown
mod.memory_fs = function (root)
	if not root then
		local now = time.time()
		root = { created = now, modified = now, children = {} } --[[:! fuse_memory_entry]]
	end
	local root_ = root --[[:! fuse_memory_entry]]
	--: (unknown) -> (fuse_memory_entry | nil, fuse_memory_entry | nil, string | nil)
	local find = function (path_c)
		local path = ffi.string(path_c --[[:! Ptr<integer>]])
		local parent = nil --: fuse_memory_entry | nil
		local child = root_ --: fuse_memory_entry | nil
		local name = nil --: string | nil
		local iter = path:gmatch("[^/]+")
		if iter() ~= "" then return nil, nil, nil end
		for segment in iter do
			if not child then return nil, nil, nil end
			name = segment
			parent = child
			local children = child.children
			child = children and children[segment] or nil
		end
		return child, parent, name
	end
	return {
		--[[FIXME: use info]]
		read = function (path_c, buf, size, offset, info)
			local size_ = size --[[:! integer]]
			local offset_ = offset --[[:! integer]]
			local child = find(path_c)
			if not child then return fuse.error.no_entry end
			local data = child.data
			if not data then return fuse.error.no_entry end
			local actual_size = math.min(size_, sizeof(data) - offset_)
			ffi.C.memcpy(buf, data, actual_size)
			return actual_size - offset_
		end,
		--[[FIXME: use info]]
		write = function (path_c, buf, size, offset, info)
			local size_ = size --[[:! integer]]
			local offset_ = offset --[[:! integer]]
			local child, parent, name = find(path_c)
			if not parent then return fuse.error.no_entry end
			local actual_size = size_ + offset_
			if not child then
				local now = time.time()
				child = { created = now, modified = now, data = mk_buf(actual_size) } --[[:! fuse_memory_entry]]
				parent.children = parent.children or {}
				local children = parent.children --[[:! { [string]: fuse_memory_entry }]]
				children[name --[[:! string]]] = child
			elseif sizeof(child.data --[[:! Ctype<unknown>]]) < actual_size then
				local data = mk_buf(actual_size) --[[:! Ctype<unknown>]]
				local old_data = child.data --[[:! Ctype<unknown>]]
				if offset_ > 0 then ffi.C.memcpy(data, old_data, math.min(sizeof(old_data), offset_)) end
				if offset_ + size_ < sizeof(old_data) then
					ffi.C.memcpy(data, old_data, offset_ + size_, sizeof(old_data) - offset_ - size_)
				end
				child.data = data
				if parent.children then
					parent.children[name --[[:! string]]] = child
				end
			end
			ffi.C.memcpy((child --[[:! fuse_memory_entry]]).data, buf, actual_size)
			return size_
		end,
		unlink = function (path_c)
			local child, parent, name = find(path_c)
			if not child then return fuse.error.no_entry end
			if parent and parent.children then
				parent.children[name --[[:! string]]] = nil
			end
			return fuse.error.success
		end,
	}
end

return mod
