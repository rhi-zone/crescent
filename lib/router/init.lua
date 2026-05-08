if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Node types
local NODE_STATIC = 1
local NODE_PARAM = 2
local NODE_WILDCARD = 3

--:: Node = { segment: string, kind: number, children: { [number]: Node }, handlers: { [string]: unknown }, param_name: string | nil, prefix: string | nil }

--: (segment: string | nil, kind: number | nil, param_name: string | nil) -> Node
local function new_node(segment, kind, param_name)
	return {
		segment = segment or "",
		kind = kind or NODE_STATIC,
		children = {},
		handlers = {},
		param_name = param_name,
		prefix = nil,
	}
end

--- Parse a path into segments. Each segment is {text, kind, param_name?, prefix?}.
--- "/users/:id/posts/*rest" -> {{"users",STATIC}, {"id",PARAM,"id"}, {"posts",STATIC}, {"rest",WILDCARD,"rest"}}
--:: Segment = { text: string, kind: number, param_name: string | nil, prefix: string | nil }
--: (path: string) -> ({ [number]: Segment }, number)
local function parse_segments(path)
	local segs = {} --[[: { [number]: Segment }]]
	local n = 0
	for part in path:gmatch("[^/]+") do
		if part:sub(1, 1) == "*" then
			n = n + 1
			segs[n] = { text = part:sub(2), kind = NODE_WILDCARD, param_name = part:sub(2), prefix = nil }
		elseif part:sub(1, 1) == ":" then
			n = n + 1
			segs[n] = { text = part:sub(2), kind = NODE_PARAM, param_name = part:sub(2), prefix = nil }
		else
			-- Check for inline params: "v:version" -> split into static prefix + param
			local seg_prefix, pname = part:match("^(.-):(.*)")
			if seg_prefix and #seg_prefix > 0 then
				n = n + 1
				segs[n] = { text = part, kind = NODE_PARAM, param_name = pname, prefix = seg_prefix }
			else
				n = n + 1
				segs[n] = { text = part, kind = NODE_STATIC, param_name = nil, prefix = nil }
			end
		end
	end
	return segs, n
end

--- Find or create a child node matching the given segment.
--: (node: Node, seg_text: string, kind: number, param_name: string | nil, prefix: string | nil) -> Node
local function find_or_create_child(node, seg_text, kind, param_name, prefix)
	local children = node.children
	for i = 1, #children do
		local c = children[i]
		if c.kind == kind and c.segment == seg_text then
			return c
		end
	end
	local child = new_node(seg_text, kind, param_name)
	if prefix then child.prefix = prefix end
	children[#children + 1] = child
	return child
end

--:: MethodFn = (self: RouterInstance, path: string, handler: unknown) -> (boolean | nil, string | nil)
--:: RouterInstance = { root: Node, add: (self: RouterInstance, method: string, path: string, handler: unknown) -> (boolean | nil, string | nil), find: (self: RouterInstance, method: string, path: string) -> { handler: unknown, params: { [string]: string } } | nil, get: MethodFn, post: MethodFn, put: MethodFn, delete: MethodFn, patch: MethodFn, head: MethodFn, options: MethodFn, group: (self: RouterInstance, prefix: string, fn: (g: Group) -> nil) -> nil, ... }
--:: Group = { add: (self: Group, method: string, path: string, handler: unknown) -> (boolean | nil, string | nil), get: MethodFn, post: MethodFn, put: MethodFn, delete: MethodFn, patch: MethodFn, head: MethodFn, options: MethodFn, group: (self: Group, prefix: string, fn: (g: Group) -> nil) -> nil }
--:: Router = RouterInstance

local Router = {}
Router.__index = Router

--: (self: RouterInstance, method: string, path: string, handler: unknown) -> (boolean | nil, string | nil)
function Router:add(method, path, handler)
	if type(method) ~= "string" or #method == 0 then
		return nil, "method must be a non-empty string"
	end
	if type(path) ~= "string" or #path == 0 then
		return nil, "path must be a non-empty string"
	end
	if handler == nil then
		return nil, "handler must not be nil"
	end
	method = method:upper()

	-- Root path special case
	if path == "/" then
		if self.root.handlers[method] then
			return nil, "route already exists: " .. method .. " /"
		end
		self.root.handlers[method] = handler
		return true
	end

	local segs, n = parse_segments(path)
	local node = self.root
	for i = 1, n do
		local seg = segs[i]
		node = find_or_create_child(node, seg.text, seg.kind, seg.param_name, seg.prefix)
	end

	if node.handlers[method] then
		return nil, "route already exists: " .. method .. " " .. path
	end
	node.handlers[method] = handler
	return true
end

--- Match path segments against the radix tree.
--: (self: RouterInstance, method: string, path: string) -> { handler: unknown, params: { [string]: string } } | nil
function Router:find(method, path)
	method = method:upper()

	-- Root path special case
	if path == "/" or path == "" then
		local h = self.root.handlers[method]
		if h then return { handler = h, params = {} } end
		-- Check if any handler exists for other methods
		if next(self.root.handlers) then return nil end
		return nil
	end

	-- Split path into parts
	local parts = {}
	local np = 0
	for part in path:gmatch("[^/]+") do
		np = np + 1
		parts[np] = part
	end

	local params = {}
	local node = self.root

	for i = 1, np do
		local part = parts[i] --[[:! string]]
		local matched = false

		-- Try static children first (highest priority)
		local children = node.children
		for j = 1, #children do
			local c = children[j]
			if c.kind == NODE_STATIC and c.segment == part then
				node = c
				matched = true
				break
			end
		end

		-- Try param children
		if not matched then
			for j = 1, #children do
				local c = children[j]
				if c.kind == NODE_PARAM then
					if c.prefix then
						-- Inline param: "v:version" matches "v1" -> version="1"
						local prefix = (c.prefix --[[:! string]])
						if part:sub(1, #prefix) == prefix then
							params[c.param_name or ""] = part:sub(#prefix + 1)
							node = c
							matched = true
							break
						end
					else
						params[c.param_name or ""] = part
						node = c
						matched = true
						break
					end
				end
			end
		end

		-- Try wildcard children (consumes rest of path)
		if not matched then
			for j = 1, #children do
				local c = children[j]
				if c.kind == NODE_WILDCARD then
					-- Collect remaining path segments
					local rest = {}
					for k = i, np do
						rest[#rest + 1] = parts[k]
					end
					params[c.param_name or ""] = table.concat(rest, "/")
					local h = c.handlers[method]
					if h then
						return { handler = h, params = params }
					end
					return nil
				end
			end
		end

		if not matched then return nil end
	end

	local h = node.handlers[method]
	if h then return { handler = h, params = params } end
	return nil
end

--- Collect all registered routes.
--: (self: RouterInstance) -> { { method: string, path: string, handler: unknown } }
function Router:routes()
	local result = {}
	--: (node: Node, prefix: string) -> nil
	local function walk(node, prefix)
		local path
		if node == self.root then
			path = ""
		elseif node.kind == NODE_PARAM then
			local pname = node.param_name or ""
			if node.prefix then
				path = prefix .. "/" .. node.prefix .. ":" .. pname
			else
				path = prefix .. "/:" .. pname
			end
		elseif node.kind == NODE_WILDCARD then
			path = prefix .. "/*" .. (node.param_name or "")
		else
			path = prefix .. "/" .. node.segment
		end

		for method, handler in pairs(node.handlers) do
			result[#result + 1] = {
				method = method,
				path = path == "" and "/" or path,
				handler = handler,
			}
		end

		for i = 1, #node.children do
			walk(node.children[i], path)
		end
	end
	walk(self.root, "")
	return result
end

--- Group routes under a common prefix.
--: (self: RouterInstance, prefix: string, fn: (g: Group) -> nil) -> nil
function Router:group(prefix, fn)
	local router_self = self
	local g = {} --[[:! Group]]
	g.add = function(_, method, gpath, handler)
		return router_self:add(method, prefix .. gpath, handler)
	end
	g.get = function(_, gpath, handler)
		return router_self:add("GET", prefix .. gpath, handler)
	end
	g.post = function(_, gpath, handler)
		return router_self:add("POST", prefix .. gpath, handler)
	end
	g.put = function(_, gpath, handler)
		return router_self:add("PUT", prefix .. gpath, handler)
	end
	g.delete = function(_, gpath, handler)
		return router_self:add("DELETE", prefix .. gpath, handler)
	end
	g.patch = function(_, gpath, handler)
		return router_self:add("PATCH", prefix .. gpath, handler)
	end
	g.head = function(_, gpath, handler)
		return router_self:add("HEAD", prefix .. gpath, handler)
	end
	g.options = function(_, gpath, handler)
		return router_self:add("OPTIONS", prefix .. gpath, handler)
	end
	g.group = function(_, sub_prefix, sub_fn)
		return router_self:group(prefix .. sub_prefix, sub_fn)
	end
	fn(g)
end

-- Method shortcuts
for _, method in ipairs({ "get", "post", "put", "delete", "patch", "head", "options" }) do
	Router[method] = function(self, path, handler)
		return self:add(method:upper(), path, handler)
	end
end

--- Create a new router instance.
--: () -> Router
function M.new()
	local r = setmetatable({
		root = new_node("", NODE_STATIC),
	}, Router) --[[: Router]]
	return r
end

return M
