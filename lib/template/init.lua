-- lib/template — lightweight string template engine with Lua expressions
--
-- Compiles templates to functions for fast repeated rendering.
-- Syntax:
--   {{ expr }}       — output expression (HTML-escaped)
--   {{{ expr }}}     — raw output (no escaping)
--   {% code %}       — Lua code block
--   {# comment #}    — comment (stripped)
--   {{ expr | filter }} — piped filters
--
-- Usage:
--   local template = require("lib.template")
--   local tmpl = template.compile("Hello, {{ name }}!")
--   tmpl({name = "World"})  --> "Hello, World!"

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- HTML character escaping -------------------------------------------------

local ESCAPE_MAP = {
	["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;",
	['"'] = "&quot;", ["'"] = "&#039;",
}

--: (s: string) -> string
local function html_escape(s)
	return tostring(s):gsub("[&<>\"']", ESCAPE_MAP)
end
M.escape = html_escape

-- Built-in filters --------------------------------------------------------

--: { [string]: (value: unknown) -> unknown }
local filters = {}

filters.upper = function(s) return tostring(s):upper() end
filters.lower = function(s) return tostring(s):lower() end
filters.trim = function(s) return tostring(s):match("^%s*(.-)%s*$") end
filters.length = function(s)
	if type(s) == "table" then return #s end
	return #tostring(s)
end

--: (default_val: unknown) -> (value: unknown) -> unknown
filters.default = function(default_val)
	return function(v)
		if v == nil then return default_val end
		return v
	end
end

-- Add a custom filter
--: (name: string, fn: (value: unknown) -> unknown) -> nil
function M.add_filter(name, fn)
	filters[name] = fn
end

-- Compiler ----------------------------------------------------------------

-- Parse a filter chain like "upper" or "trim | upper" or "default('N/A')"
-- Returns Lua code string that wraps the expression.
--: (expr: string, escaped: boolean) -> string
local function compile_expr(expr, escaped)
	-- Split on | but not || (logical or)
	local parts = {}
	local current = ""
	local i = 1
	local len = #expr
	while i <= len do
		local c = expr:sub(i, i)
		if c == "|" then
			if expr:sub(i + 1, i + 1) == "|" then
				-- || is logical or, keep it
				current = current .. "||"
				i = i + 2
			else
				parts[#parts + 1] = current
				current = ""
				i = i + 1
			end
		else
			current = current .. c
			i = i + 1
		end
	end
	parts[#parts + 1] = current

	-- First part is the expression, rest are filter names
	local base = parts[1]:match("^%s*(.-)%s*$")
	local code = base

	for fi = 2, #parts do
		local filter_str = parts[fi]:match("^%s*(.-)%s*$")
		-- Check for filter with argument: name(arg)
		local fname, farg = filter_str:match("^(%w+)%((.+)%)$")
		if fname then
			-- Filter with argument — call make_default or similar
			code = "__filters." .. fname .. "(" .. farg .. ")(" .. code .. ")"
		else
			code = "__filters." .. filter_str .. "(" .. code .. ")"
		end
	end

	if escaped then
		return "__esc(" .. code .. ")"
	else
		return "tostring(" .. code .. ")"
	end
end

-- Safe globals available inside templates
local TEMPLATE_GLOBALS = {
	table = table, string = string, math = math, type = type,
	tostring = tostring, tonumber = tonumber, pairs = pairs,
	ipairs = ipairs, next = next, select = select, unpack = unpack,
	pcall = pcall, error = error, assert = assert,
	setfenv = setfenv, setmetatable = setmetatable,
}

-- Compile a template string to a Lua code string
--: (tmpl: string) -> (string, string | nil)
local function compile_to_source(tmpl)
	local out = {}
	out[#out + 1] = "local __esc, __filters = ...\n"
	out[#out + 1] = "local __out = {}\n"

	local pos = 1
	local len = #tmpl

	while pos <= len do
		-- Find next tag opening
		local tag_start = tmpl:find("{", pos, true)
		if not tag_start then
			-- Rest is plain text
			local text = tmpl:sub(pos)
			if #text > 0 then
				out[#out + 1] = "__out[#__out+1]=" .. string.format("%q", text) .. "\n"
			end
			break
		end

		-- Check what follows the {
		local next_char = tmpl:sub(tag_start + 1, tag_start + 1)

		if next_char == "{" then
			-- Could be {{ or {{{
			local third_char = tmpl:sub(tag_start + 2, tag_start + 2)
			if third_char == "{" then
				-- {{{ raw output }}}
				-- Emit text before tag
				if tag_start > pos then
					local text = tmpl:sub(pos, tag_start - 1)
					out[#out + 1] = "__out[#__out+1]=" .. string.format("%q", text) .. "\n"
				end
				local expr_start = tag_start + 3
				local close = tmpl:find("}}}", expr_start, true)
				if not close then
					return nil, "unclosed {{{ at position " .. tag_start
				end
				local expr = tmpl:sub(expr_start, close - 1)
				local code = compile_expr(expr, false)
				out[#out + 1] = "__out[#__out+1]=" .. code .. "\n"
				pos = close + 3
			else
				-- {{ escaped output }}
				-- Emit text before tag
				if tag_start > pos then
					local text = tmpl:sub(pos, tag_start - 1)
					out[#out + 1] = "__out[#__out+1]=" .. string.format("%q", text) .. "\n"
				end
				local expr_start = tag_start + 2
				local close = tmpl:find("}}", expr_start, true)
				if not close then
					return nil, "unclosed {{ at position " .. tag_start
				end
				-- Make sure this isn't actually a }}} close (skip)
				local expr = tmpl:sub(expr_start, close - 1)
				local code = compile_expr(expr, true)
				out[#out + 1] = "__out[#__out+1]=" .. code .. "\n"
				pos = close + 2
			end
		elseif next_char == "%" then
			-- {% code block %}
			if tag_start > pos then
				local text = tmpl:sub(pos, tag_start - 1)
				out[#out + 1] = "__out[#__out+1]=" .. string.format("%q", text) .. "\n"
			end
			local code_start = tag_start + 2
			local close = tmpl:find("%}", code_start, true)
			if not close then
				return nil, "unclosed {% at position " .. tag_start
			end
			local code = tmpl:sub(code_start, close - 1)
			-- Trim leading/trailing whitespace from code
			code = code:match("^%s*(.-)%s*$")
			out[#out + 1] = code .. "\n"
			pos = close + 2
		elseif next_char == "#" then
			-- {# comment #}
			if tag_start > pos then
				local text = tmpl:sub(pos, tag_start - 1)
				out[#out + 1] = "__out[#__out+1]=" .. string.format("%q", text) .. "\n"
			end
			local close = tmpl:find("#}", tag_start + 2, true)
			if not close then
				return nil, "unclosed {# at position " .. tag_start
			end
			pos = close + 2
		else
			-- Lone { — treat as literal text
			if tag_start > pos then
				local text = tmpl:sub(pos, tag_start)
				out[#out + 1] = "__out[#__out+1]=" .. string.format("%q", text) .. "\n"
			else
				out[#out + 1] = "__out[#__out+1]=\"{\"\n"
			end
			pos = tag_start + 1
		end
	end

	out[#out + 1] = "return table.concat(__out)\n"
	return table.concat(out)
end

-- Compile a template string to a render function.
-- Returns (fn, nil) on success or (nil, errmsg) on failure.
--: (tmpl: string) -> ((ctx: { [string]: unknown }) -> string) | nil, string | nil
function M.compile(tmpl)
	local source, err = compile_to_source(tmpl)
	if not source then
		return nil, err
	end

	local fn, load_err = loadstring(source, "template")
	if not fn then
		return nil, "compile error: " .. tostring(load_err)
	end

	return function(ctx)
		-- Build env: user ctx keys shadow template globals for stdlib access.
		-- Uses rawget on ctx so existing metatables don't interfere with globals.
		local env = setmetatable({}, {__index = function(_, k)
			if ctx then
				local v = rawget(ctx, k)
				if v ~= nil then return v end
			end
			return TEMPLATE_GLOBALS[k]
		end})
		setfenv(fn, env)
		return fn(html_escape, filters)
	end
end

-- One-shot render: compile and immediately execute.
-- Returns (result, nil) on success or (nil, errmsg) on failure.
--: (tmpl: string, ctx: { [string]: unknown } | nil) -> string | nil, string | nil
function M.render(tmpl, ctx)
	local fn, err = M.compile(tmpl)
	if not fn then
		return nil, err
	end
	return fn(ctx)
end

-- Expose compile_to_source for debugging/inspection
M._compile_to_source = compile_to_source

return M
