-- lib/lua2ts/init.lua
-- Lua → TypeScript transpiler.
-- Walks the crescent AST (from lib/type/static/parse) and emits TypeScript.
--
-- Usage:
--   local lua2ts = require("lib.lua2ts")
--   local ts, err = lua2ts.transpile(lua_source, opts)
--   local ts, err = lua2ts.transpile_file(path, opts)
--
-- opts:
--   filename : string           (for error messages, default "?")
--   module   : "esm" | "cjs"   (default "esm")
--   strict   : boolean          (emit // @ts-strict-mode, default false)
--   harden   : boolean          (sandboxed JS output: null-proto records,
--                                bounded methods, JS-hazard ident blocklist)

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local parse_mod  = require("lib.type.static.parse")
local intern_mod = require("lib.type.static.intern")
local defs       = require("lib.type.static.defs")
local i32x2_to_double = defs.i32x2_to_double

local M = {}

-- ---------------------------------------------------------------------------
-- Harden mode: JS-runtime hazards the typechecker can't see.
-- ---------------------------------------------------------------------------

-- Real JS globals that should never be reachable from sandboxed projection
-- code. Lua names like _G/os/io/debug are NOT in this list — they're harmless
-- undefined-identifier ReferenceErrors at runtime.
M.JS_HAZARDS = {
    "globalThis", "window", "document", "self", "Function", "eval",
    "setTimeout", "setInterval", "setImmediate",
    "clearTimeout", "clearInterval", "clearImmediate",
    "requestAnimationFrame", "cancelAnimationFrame",
    "requestIdleCallback", "cancelIdleCallback",
    "fetch", "XMLHttpRequest", "WebSocket", "EventSource",
    "Worker", "SharedWorker", "importScripts", "import",
}

local JS_HAZARDS_SET = {}
for _, n in ipairs(M.JS_HAZARDS) do JS_HAZARDS_SET[n] = true end

-- Method-name → harden-helper rewrite table. Purely syntactic on method name;
-- false positives on user methods are validated/rejected at JS runtime by the
-- helper itself.
local HARDEN_METHOD_REWRITE = {
    ["repeat"]   = "__safe_repeat",
    padStart     = "__safe_pad_start",
    padEnd       = "__safe_pad_end",
    join         = "__safe_join",
}

-- Helpers prepended to harden-mode output. Comma-keyed string per helper so
-- emission can dedupe. The order matches the order in HARDEN_HELPERS_ORDER.
local HARDEN_HELPERS_ORDER = {
    "__rec",
    "__MAX_OUTPUT",
    "__PROTO_KEYS",
    "__safeGet",
    "__safe_repeat",
    "__safe_pad_start",
    "__safe_pad_end",
    "__safe_join",
}

local HARDEN_HELPERS = {
    __rec = "const __rec = (o) => Object.assign(Object.create(null), o);",
    __MAX_OUTPUT = "const __MAX_OUTPUT = 100000;",
    __PROTO_KEYS = [[const __PROTO_KEYS = new Set(["__proto__", "constructor", "prototype", "__defineGetter__", "__defineSetter__", "__lookupGetter__", "__lookupSetter__"]);]],
    __safeGet = [[const __safeGet = (t, k) => {
  if (typeof k === "string" && __PROTO_KEYS.has(k)) throw new Error("__safeGet: forbidden key " + k);
  return t[k];
};]],
    __safe_repeat = [[const __safe_repeat = (s, n) => {
  if (typeof s !== "string" || typeof n !== "number" || n < 0 || !Number.isFinite(n)) throw new TypeError("__safe_repeat: invalid args");
  if (s.length * n > __MAX_OUTPUT) throw new Error("__safe_repeat: output too large");
  return s.repeat(n);
};]],
    __safe_pad_start = [[const __safe_pad_start = (s, n, fill) => {
  if (typeof s !== "string" || typeof n !== "number" || n < 0 || !Number.isFinite(n)) throw new TypeError("__safe_pad_start: invalid args");
  if (n > __MAX_OUTPUT) throw new Error("__safe_pad_start: output too large");
  return s.padStart(n, fill);
};]],
    __safe_pad_end = [[const __safe_pad_end = (s, n, fill) => {
  if (typeof s !== "string" || typeof n !== "number" || n < 0 || !Number.isFinite(n)) throw new TypeError("__safe_pad_end: invalid args");
  if (n > __MAX_OUTPUT) throw new Error("__safe_pad_end: output too large");
  return s.padEnd(n, fill);
};]],
    __safe_join = [[const __safe_join = (arr, sep) => {
  if (!Array.isArray(arr)) throw new TypeError("__safe_join: invalid args");
  const s = (sep === undefined || sep === null) ? "," : String(sep);
  let total = 0;
  for (let i = 0; i < arr.length; i++) {
    const part = arr[i] === undefined || arr[i] === null ? "" : String(arr[i]);
    total += part.length;
    if (i > 0) total += s.length;
    if (total > __MAX_OUTPUT) throw new Error("__safe_join: output too large");
  }
  return arr.join(sep);
};]],
}

-- Throw a transpile-time harden error. Caught by pcall in M.transpile.
local function harden_error(name)
    error("E_HARDEN_BLOCKED_IDENT: identifier '" .. name ..
          "' is on the JS-hazard blocklist and cannot be used in harden mode")
end

-- ---------------------------------------------------------------------------
-- Operator tables
-- ---------------------------------------------------------------------------

local binop_str = {
    [defs.OP_ADD]    = "+",
    [defs.OP_SUB]    = "-",
    [defs.OP_MUL]    = "*",
    [defs.OP_DIV]    = "/",
    [defs.OP_MOD]    = "%",
    [defs.OP_POW]    = "**",
    [defs.OP_CONCAT] = "+",   -- Lua .. → JS/TS string concat with +
    [defs.OP_EQ]     = "===",
    [defs.OP_NE]     = "!==",
    [defs.OP_LT]     = "<",
    [defs.OP_LE]     = "<=",
    [defs.OP_GT]     = ">",
    [defs.OP_GE]     = ">=",
    [defs.OP_AND]    = "&&",
    [defs.OP_OR]     = "||",
}

-- Precedence (lower = looser binding; matches TypeScript)
local binop_prec = {
    [defs.OP_OR]     = 1,
    [defs.OP_AND]    = 2,
    [defs.OP_EQ]     = 3,
    [defs.OP_NE]     = 3,
    [defs.OP_LT]     = 4,
    [defs.OP_LE]     = 4,
    [defs.OP_GT]     = 4,
    [defs.OP_GE]     = 4,
    [defs.OP_CONCAT] = 5,
    [defs.OP_ADD]    = 6,
    [defs.OP_SUB]    = 6,
    [defs.OP_MUL]    = 7,
    [defs.OP_DIV]    = 7,
    [defs.OP_MOD]    = 7,
    [defs.OP_POW]    = 9,  -- right-assoc, emit with parens on left
}

-- ---------------------------------------------------------------------------
-- Annotation comment scanner
-- Extracts --: and --:: comments from source, keyed by line number.
-- Returns { [lineno] = { kind="type"|"decl", content=string } }
-- ---------------------------------------------------------------------------
--:: L2TSAnn = { kind: string, content: string }
local function scan_annotations(source)
  --: { [integer]: L2TSAnn }
  local anns = {}
    local lineno = 1
    local i = 1
    local len = #source
    while i <= len do
        local nl = source:find("\n", i, true)
        local line_end = nl and nl - 1 or len
        local line = source:sub(i, line_end)
        -- look for --:: or --: in the line
        local dcolon = line:match("%-%-::(.*)$")
        if dcolon then
            anns[lineno] = { kind = "decl", content = dcolon:match("^%s*(.-)%s*$") }
        else
            local colon = line:match("%-%-:([^:].*)$")
            if not colon then colon = line:match("%-%-:()") and "" end  -- bare --:
            if colon then
                anns[lineno] = { kind = "type", content = colon:match("^%s*(.-)%s*$") }
            end
        end
        lineno = lineno + 1
        i = (nl and nl + 1) or (len + 1)
    end
    return anns
end

-- ---------------------------------------------------------------------------
-- Type annotation → TypeScript type string
-- Translates the crescent annotation mini-language to TS types.
-- This is a best-effort string transform; does not parse the full type grammar.
-- ---------------------------------------------------------------------------
local function ann_to_ts(content)
    if not content or content == "" then return nil end
    -- nil → null
    content = content:gsub("%bnil", "null")
    -- integer → number
    content = content:gsub("integer", "number")
    -- (A, B) -> C  →  (a: A, b: B) => C
    -- We use a simple pattern for the common single-arrow case.
    -- For now: replace -> with =>
    content = content:gsub("%->" , "=>")
    -- { [string]: V } → Record<string, V>
    content = content:gsub("{%s*%[string%]%s*:%s*(.-)%s*}", function(v)
        return "Record<string, " .. v .. ">"
    end)
    -- T? → T | null
    content = content:gsub("([%w_]+)%?", "%1 | null")
    return content
end

-- ---------------------------------------------------------------------------
-- Emit context
-- Produces indented TS output line by line.
-- ---------------------------------------------------------------------------
local function new_ctx(pool, nodes, lists, source, opts)
    local ctx = {
        pool   = pool,
        nodes  = nodes,
        lists  = lists,
        indent = 0,
        lines  = {},    -- collected output lines
        -- annotation map: lineno → { kind, content }
        anns   = scan_annotations(source),
        opts   = opts or {},
        -- pending ESM imports: { modname → alias }
        imports = {},
        import_order = {},
        -- bundle mode: collect required module names (dot-separated)
        bundle_mode     = (opts or {}).bundle_mode or false,
        bundle_requires = {},   -- ordered list of required module names
        bundle_req_seen = {},   -- set for dedup
        harden          = (opts or {}).harden or false,
        -- Set of helper names that have been triggered by harden emission;
        -- emitted at the top of output (alongside imports) once each.
        harden_used     = {},
    }

    -- Reject use of a JS-hazard identifier in harden mode. Any reference
    -- (binding, parameter, free read, assignment target) errors. See
    -- M.JS_HAZARDS for the list.
    function ctx:check_ident(name)
        if self.harden and JS_HAZARDS_SET[name] then
            harden_error(name)
        end
    end

    -- Mark a harden helper as used so it gets emitted at the top.
    function ctx:use_harden(name)
        self.harden_used[name] = true
        -- __safe_* helpers depend on __MAX_OUTPUT
        if name:sub(1, 7) == "__safe_" then
            self.harden_used.__MAX_OUTPUT = true
        end
        -- __safeGet depends on __PROTO_KEYS
        if name == "__safeGet" then
            self.harden_used.__PROTO_KEYS = true
        end
    end

    function ctx:istr()
        return string.rep("  ", self.indent)
    end

    function ctx:emit(line)
        self.lines[#self.lines + 1] = self:istr() .. line
    end

    function ctx:raw(line)
        self.lines[#self.lines + 1] = line
    end

    -- Intern ID → Lua string
    function ctx:name(id)
        return intern_mod.get(self.pool, id) or ("__id" .. tostring(id))
    end

    -- Retrieve items from the list pool as a Lua array of int32 values.
    function ctx:list(start, len)
        local result = {}
        for i = 0, len - 1 do
            result[i + 1] = tonumber(self.lists:get(start + i))
        end
        return result
    end

    -- Get node data as Lua values (not raw FFI cdata).
    function ctx:node(id)
        local n = self.nodes:get(id)
        return {
            kind  = tonumber(n.kind),
            flags = tonumber(n.flags),
            line  = tonumber(n.line),
            col   = tonumber(n.col),
            d     = {
                tonumber(n.data[0]),
                tonumber(n.data[1]),
                tonumber(n.data[2]),
                tonumber(n.data[3]),
                tonumber(n.data[4]),
                tonumber(n.data[5]),
            },
        }
    end

    -- Annotation for line N (the --: on the line preceding the declaration).
    function ctx:ann_for(lineno)
        -- The annotation is on the line before the declaration.
        return self.anns[lineno - 1]
    end

    -- Register an ESM import.
    function ctx:add_import(alias, modname)
        if not self.imports[modname] then
            self.imports[modname] = alias
            self.import_order[#self.import_order + 1] = modname
        end
    end

    -- Record a bundle-mode require dependency (dot-separated module name).
    function ctx:add_bundle_require(modname)
        if not self.bundle_req_seen[modname] then
            self.bundle_req_seen[modname] = true
            self.bundle_requires[#self.bundle_requires + 1] = modname
        end
    end

    return ctx
end

-- ---------------------------------------------------------------------------
-- Expression emitter — returns a string
-- ---------------------------------------------------------------------------

local emit_expr  -- forward declaration
local emit_stmt  -- forward declaration
local emit_block -- forward declaration

-- Escape a Lua string literal for JS/TS output.
local function escape_str(s)
    return s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
              :gsub('\r', '\\r'):gsub('\t', '\\t')
end

-- Returns true if the expression needs parentheses at the given parent precedence.
local function needs_parens(prec, parent_prec)
    return prec < parent_prec
end

-- Emit a comma-separated list of expressions.
local function emit_expr_list(ctx, starts, lens)
    local items = ctx:list(starts, lens)
    local parts = {}
    for i, nid in ipairs(items) do
        parts[i] = emit_expr(ctx, nid, 0)
    end
    return table.concat(parts, ", ")
end

-- Emit a single parameter name from an intern ID.
local function param_name(ctx, id)
    local s = ctx:name(id)
    if s ~= "..." then ctx:check_ident(s) end
    return s == "..." and "...args" or s
end

emit_expr = function(ctx, nid, parent_prec)
    local n = ctx:node(nid)
    local kind = n.kind
    local d = n.d

    if kind == defs.NODE_LITERAL then
        local lit_kind = d[1]
        if lit_kind == defs.LIT_STRING then
            local s = ctx:name(d[2])
            return '"' .. escape_str(s) .. '"'
        elseif lit_kind == defs.LIT_NUMBER then
            local v = i32x2_to_double(d[2], d[3])
            return tostring(v)
        elseif lit_kind == defs.LIT_INTEGER then
            return tostring(d[2])
        elseif lit_kind == defs.LIT_BOOLEAN then
            return d[2] == 1 and "true" or "false"
        elseif lit_kind == defs.LIT_NIL then
            return "null"
        else
            return "/* unknown literal */"
        end

    elseif kind == defs.NODE_IDENTIFIER then
        local name = ctx:name(d[1])
        ctx:check_ident(name)
        return name

    elseif kind == defs.NODE_VARARG_EXPR then
        return "...args"

    elseif kind == defs.NODE_UNARY_EXPR then
        local op = d[1]
        local operand_id = d[2]
        if op == defs.OP_LEN then
            -- #foo → foo.length
            return emit_expr(ctx, operand_id, 100) .. ".length"
        elseif op == defs.OP_UNM then
            local e = emit_expr(ctx, operand_id, 8)
            return "-" .. e
        elseif op == defs.OP_NOT then
            local e = emit_expr(ctx, operand_id, 8)
            return "!" .. e
        else
            return "/* unary? */" .. emit_expr(ctx, operand_id, 0)
        end

    elseif kind == defs.NODE_BINARY_EXPR then
        local op = d[1]
        local left_id = d[2]
        local right_id = d[3]
        local op_s = binop_str[op] or "/* op? */"
        local prec = binop_prec[op] or 5
        local le = emit_expr(ctx, left_id, prec)
        local re = emit_expr(ctx, right_id, prec + 1)  -- left-assoc by default
        if op == defs.OP_POW then
            re = emit_expr(ctx, right_id, prec)  -- right-assoc: no extra +1
        end
        local result = le .. " " .. op_s .. " " .. re
        if needs_parens(prec, parent_prec) then
            return "(" .. result .. ")"
        end
        return result

    elseif kind == defs.NODE_FIELD_EXPR then
        local obj_id = d[1]
        local field_id = d[2]
        local obj = emit_expr(ctx, obj_id, 100)
        local field = ctx:name(field_id)
        return obj .. "." .. field

    elseif kind == defs.NODE_INDEX_EXPR then
        local obj_id = d[1]
        local idx_id = d[2]
        local obj = emit_expr(ctx, obj_id, 100)
        local idx = emit_expr(ctx, idx_id, 0)
        -- Harden mode: wrap bracket access in __safeGet to block prototype-key
        -- access (e.g. t["__proto__"]). Numeric literal indices skip the wrap
        -- since they can never collide with a string prototype key. Field
        -- access (NODE_FIELD_EXPR) is unaffected — `foo` is a static
        -- identifier, not a runtime value.
        if ctx.harden then
            local idx_n = ctx:node(idx_id)
            local is_num_lit = false
            if idx_n.kind == defs.NODE_LITERAL then
                local lk = idx_n.d[1]
                if lk == defs.LIT_NUMBER or lk == defs.LIT_INTEGER then
                    is_num_lit = true
                end
            elseif idx_n.kind == defs.NODE_UNARY_EXPR and idx_n.d[1] == defs.OP_UNM then
                local inner_n = ctx:node(idx_n.d[2])
                if inner_n.kind == defs.NODE_LITERAL then
                    local lk = inner_n.d[1]
                    if lk == defs.LIT_NUMBER or lk == defs.LIT_INTEGER then
                        is_num_lit = true
                    end
                end
            end
            if not is_num_lit then
                ctx:use_harden("__safeGet")
                return "__safeGet(" .. obj .. ", " .. idx .. ")"
            end
        end
        return obj .. "[" .. idx .. "]"

    elseif kind == defs.NODE_METHOD_CALL then
        -- obj:method(args) → obj.method(args)
        local obj_id = d[1]
        local method_id = d[2]
        local args_start = d[3]
        local args_len = d[4]
        local obj = emit_expr(ctx, obj_id, 100)
        local method = ctx:name(method_id)
        -- Harden mode: rewrite memory-dangerous methods to bounded helpers.
        if ctx.harden and HARDEN_METHOD_REWRITE[method] then
            local helper = HARDEN_METHOD_REWRITE[method]
            ctx:use_harden(helper)
            local args = emit_expr_list(ctx, args_start, args_len)
            local sep = (args == "") and "" or ", "
            return helper .. "(" .. obj .. sep .. args .. ")"
        end
        local args = emit_expr_list(ctx, args_start, args_len)
        return obj .. "." .. method .. "(" .. args .. ")"

    elseif kind == defs.NODE_CALL_EXPR then
        local callee_id = d[1]
        local args_start = d[2]
        local args_len = d[3]
        -- Check for special callees
        local callee_n = ctx:node(callee_id)
        -- error("msg") → throw new Error("msg")
        if callee_n.kind == defs.NODE_IDENTIFIER then
            local callee_name = ctx:name(callee_n.d[1])
            if callee_name == "error" then
                local args = emit_expr_list(ctx, args_start, args_len)
                return "(() => { throw new Error(" .. args .. "); })()"
            elseif callee_name == "ipairs" then
                -- ipairs(t) → t.entries()
                if args_len == 1 then
                    local arg_items = ctx:list(args_start, args_len)
                    local t = emit_expr(ctx, arg_items[1], 100)
                    return t .. ".entries()"
                end
            elseif callee_name == "pairs" then
                -- pairs(t) → Object.entries(t)
                if args_len == 1 then
                    local arg_items = ctx:list(args_start, args_len)
                    local t = emit_expr(ctx, arg_items[1], 100)
                    return "Object.entries(" .. t .. ")"
                end
            elseif callee_name == "require" then
                -- require("lib.foo") → handled at call-site statement level
                -- return as-is for now; import hoisting happens in stmt handler.
                -- In bundle mode, rewrite to __require("lib/foo") and record dep.
                if ctx.bundle_mode and args_len == 1 then
                    local arg_items = ctx:list(args_start, 1)
                    local arg_n = ctx:node(arg_items[1])
                    if arg_n.kind == defs.NODE_LITERAL and arg_n.d[1] == defs.LIT_STRING then
                        local mod_name = ctx:name(arg_n.d[2])
                        ctx:add_bundle_require(mod_name)
                        local mod_id = mod_name:gsub("%.", "/")
                        return '__require("' .. mod_id .. '")'
                    end
                end
                local args = emit_expr_list(ctx, args_start, args_len)
                return "require(" .. args .. ")"
            elseif callee_name == "pcall" then
                -- pcall(f, ...) → try { return [true, f(...)]; } catch(e) { return [false, e.message]; }
                -- Wrap as IIFE
                if args_len >= 1 then
                    local arg_items = ctx:list(args_start, args_len)
                    local fn = emit_expr(ctx, arg_items[1], 100)
                    local rest_parts = {}
                    for i = 2, args_len do
                        rest_parts[#rest_parts + 1] = emit_expr(ctx, arg_items[i], 0)
                    end
                    local rest = table.concat(rest_parts, ", ")
                    return "(() => { try { return [true, " .. fn .. "(" .. rest .. ")]; } catch(__e) { return [false, (__e as Error).message]; } })()"
                end
            end
        end
        -- Check for x.new(...) → new x(...)
        if callee_n.kind == defs.NODE_FIELD_EXPR then
            local field_name = ctx:name(callee_n.d[2])
            if field_name == "new" then
                local obj = emit_expr(ctx, callee_n.d[1], 100)
                local args = emit_expr_list(ctx, args_start, args_len)
                return "new " .. obj .. "(" .. args .. ")"
            end
        end
        local callee = emit_expr(ctx, callee_id, 100)
        local args = emit_expr_list(ctx, args_start, args_len)
        return callee .. "(" .. args .. ")"

    elseif kind == defs.NODE_FUNC_EXPR then
        -- function(params) body end → (params) => { body }
        local ps = d[1]
        local pl = d[2]
        local bs = d[3]
        local bl = d[4]
        local has_vararg = (n.flags % 2) == 1  -- FLAG_VARARG = 1
        local params = ctx:list(ps, pl)
        local param_parts = {}
        for i, pid in ipairs(params) do
            param_parts[i] = param_name(ctx, pid)
        end
        if has_vararg then
            param_parts[#param_parts + 1] = "...args"
        end
        local pstr = table.concat(param_parts, ", ")
        -- Inline the body into an arrow function
        local saved_lines = ctx.lines
        ctx.lines = {}
        ctx.indent = ctx.indent + 1
        emit_block(ctx, bs, bl)
        ctx.indent = ctx.indent - 1
        local body_lines = ctx.lines
        ctx.lines = saved_lines
        local body_str = table.concat(body_lines, "\n")
        return "(" .. pstr .. ") => {\n" .. body_str .. "\n" .. ctx:istr() .. "}"

    elseif kind == defs.NODE_TABLE_EXPR then
        local fs = d[1]
        local fl = d[2]
        if fl == 0 then return "{}" end
        local fields = ctx:list(fs, fl)
        -- Determine if array (all positional) or object (any keyed)
        local is_array = true
        for _, fid in ipairs(fields) do
            local fn = ctx:node(fid)
            if fn.d[1] ~= -1 then  -- -1 = positional
                is_array = false
                break
            end
        end
        local parts = {}
        if is_array then
            for _, fid in ipairs(fields) do
                local fn = ctx:node(fid)
                parts[#parts + 1] = emit_expr(ctx, fn.d[2], 0)
            end
            return "[" .. table.concat(parts, ", ") .. "]"
        else
            for _, fid in ipairs(fields) do
                local fn = ctx:node(fid)
                local key_id = fn.d[1]
                local val_id = fn.d[2]
                if key_id == -1 then
                    -- positional in a mixed table: use numeric key
                    parts[#parts + 1] = emit_expr(ctx, val_id, 0)
                else
                    local key_n = ctx:node(key_id)
                    local val_s = emit_expr(ctx, val_id, 0)
                    if key_n.kind == defs.NODE_LITERAL and key_n.d[1] == defs.LIT_STRING then
                        local key_s = ctx:name(key_n.d[2])
                        -- Use identifier syntax if valid, else quoted
                        if key_s:match("^[%a_][%w_]*$") then
                            parts[#parts + 1] = key_s .. ": " .. val_s
                        else
                            parts[#parts + 1] = '["' .. escape_str(key_s) .. '"]: ' .. val_s
                        end
                    elseif key_n.kind == defs.NODE_LITERAL and key_n.d[1] == defs.LIT_INTEGER then
                        parts[#parts + 1] = "[" .. tostring(key_n.d[2]) .. "]: " .. val_s
                    else
                        local key_s = emit_expr(ctx, key_id, 0)
                        parts[#parts + 1] = "[" .. key_s .. "]: " .. val_s
                    end
                end
            end
            local obj_lit = "{" .. table.concat(parts, ", ") .. "}"
            if ctx.harden then
                ctx:use_harden("__rec")
                return "__rec(" .. obj_lit .. ")"
            end
            return obj_lit
        end

    elseif kind == defs.NODE_CAST_EXPR then
        -- --[[ : T ]] expr — pass through; type information lost at expression level
        return emit_expr(ctx, d[1], parent_prec)

    else
        return "/* TODO: expr kind=" .. tostring(kind) .. " */"
    end
end

-- ---------------------------------------------------------------------------
-- Statement emitter
-- ---------------------------------------------------------------------------

-- Emit param list with optional type annotation.
local function emit_params(ctx, ps, pl, has_vararg, ann_content)
    local params = ctx:list(ps, pl)
    local param_parts = {}
    for i, pid in ipairs(params) do
        param_parts[i] = param_name(ctx, pid)
    end
    if has_vararg then
        param_parts[#param_parts + 1] = "...args"
    end
    -- If annotation exists, attach types (best-effort: split by comma)
    if ann_content then
        local ts_ann = ann_to_ts(ann_content)
        -- Try to extract parameter types from (A, B) -> C form
        local param_types_str = ts_ann and ts_ann:match("^%((.-)%)%s*=>") or nil
        if param_types_str then
            local types_list = {}
            for t in (param_types_str .. ","):gmatch("([^,]+),") do
                types_list[#types_list + 1] = t:match("^%s*(.-)%s*$")
            end
            for i, pname in ipairs(param_parts) do
                if types_list[i] and not pname:match("^%.%.%.") then
                    param_parts[i] = pname .. ": " .. types_list[i]
                end
            end
        end
    end
    return table.concat(param_parts, ", ")
end

-- Emit a return type annotation suffix (": ReturnType" or "").
local function emit_return_type(ann_content)
    if not ann_content then return "" end
    local ts = ann_to_ts(ann_content)
    if not ts then return "" end
    local ret = ts:match("%s*=>%s*(.+)$")
    if ret then return ": " .. ret end
    return ""
end

-- Check if a call expression is `require("mod")` and return the module name.
local function get_require_mod(ctx, nid)
    local n = ctx:node(nid)
    if n.kind ~= defs.NODE_CALL_EXPR then return nil end
    local callee_n = ctx:node(n.d[1])
    if callee_n.kind ~= defs.NODE_IDENTIFIER then return nil end
    local callee_name = ctx:name(callee_n.d[1])
    if callee_name ~= "require" then return nil end
    local args_len = n.d[3]
    if args_len ~= 1 then return nil end
    local arg_items = ctx:list(n.d[2], 1)
    local arg_n = ctx:node(arg_items[1])
    if arg_n.kind ~= defs.NODE_LITERAL or arg_n.d[1] ~= defs.LIT_STRING then return nil end
    return ctx:name(arg_n.d[2])
end

-- Convert a module name like "lib.foo.bar" to an import path like "./lib/foo/bar".
local function mod_to_import_path(modname)
    return "./" .. modname:gsub("%.", "/")
end

-- Derive a variable alias from a module name: "lib.foo.bar" → "bar".
local function mod_to_alias(modname)
    return modname:match("([^%.]+)$") or modname
end

emit_stmt = function(ctx, nid)
    local n = ctx:node(nid)
    local kind = n.kind
    local d = n.d

    if kind == defs.NODE_LOCAL_STMT then
        local ns = d[1]
        local nl = d[2]
        local es = d[3]
        local el = d[4]
        local names = ctx:list(ns, nl)
        -- Build name strings
        local name_parts = {}
        for i, nid2 in ipairs(names) do
            local nm = ctx:name(nid2)
            ctx:check_ident(nm)
            name_parts[i] = nm
        end
        -- Check for annotation on preceding line
        local ann = ctx:ann_for(n.line)
        local ann_content = ann and ann.content or nil

        if el == 0 then
            -- local x [, y] (no initializer) → let x [, y]
            if #name_parts == 1 then
                local ts_type = ann_content and (": " .. (ann_to_ts(ann_content) or "unknown")) or ""
                ctx:emit("let " .. name_parts[1] .. ts_type .. ";")
            else
                ctx:emit("let [" .. table.concat(name_parts, ", ") .. "];")
            end
        elseif el == 1 then
            -- Single initializer
            local exprs = ctx:list(es, el)
            local expr_id = exprs[1]
            -- Special case: require("lib.foo") → import (ESM) or __require (bundle)
            local mod_name = get_require_mod(ctx, expr_id)
            if mod_name then
                if ctx.bundle_mode then
                    -- Bundle mode: emit const x = __require("lib/foo"); and record dep.
                    local alias = name_parts[1]
                    local mod_id = mod_name:gsub("%.", "/")
                    ctx:add_bundle_require(mod_name)
                    local ts_type = ann_content and (": " .. (ann_to_ts(ann_content) or "unknown")) or ""
                    ctx:emit("const " .. alias .. ts_type .. ' = __require("' .. mod_id .. '");')
                    return
                elseif ctx.opts.module ~= "cjs" then
                    local alias = name_parts[1]
                    local path = mod_to_import_path(mod_name)
                    ctx:add_import(alias, path)
                    -- Don't emit a local statement; the import will be hoisted.
                    return
                end
            end
            local val = emit_expr(ctx, expr_id, 0)
            if #name_parts == 1 then
                local ts_type = ann_content and (": " .. (ann_to_ts(ann_content) or "unknown")) or ""
                ctx:emit("const " .. name_parts[1] .. ts_type .. " = " .. val .. ";")
            else
                -- Destructure multiple names from single value (multi-return)
                ctx:emit("const [" .. table.concat(name_parts, ", ") .. "] = " .. val .. ";")
            end
        else
            -- Multiple initializers (uncommon)
            local exprs = ctx:list(es, el)
            local val_parts = {}
            for i, eid in ipairs(exprs) do
                val_parts[i] = emit_expr(ctx, eid, 0)
            end
            if #name_parts == 1 then
                ctx:emit("const " .. name_parts[1] .. " = " .. val_parts[1] .. ";")
            else
                ctx:emit("const [" .. table.concat(name_parts, ", ") .. "] = [" .. table.concat(val_parts, ", ") .. "];")
            end
        end

    elseif kind == defs.NODE_FUNC_DECL then
        -- function name(params) body end  OR  local function name(params) body end
        local name_node_id = d[1]
        local ps = d[2]
        local pl = d[3]
        local bs = d[4]
        local bl = d[5]
        local has_vararg = (n.flags % 2) == 1  -- FLAG_VARARG = 1
        local is_local = (n.flags % 4) >= 2    -- FLAG_LOCAL = 2

        local ann = ctx:ann_for(n.line)
        local ann_content = ann and ann.content or nil

        local name_n = ctx:node(name_node_id)
        local is_method = name_n.kind == defs.NODE_FIELD_EXPR

        local param_str = emit_params(ctx, ps, pl, has_vararg, ann_content)
        local ret_type = emit_return_type(ann_content)

        if is_method then
            -- function Foo.bar(params) ... end → Foo.bar = function(params): RetType { ... }
            local name_s = emit_expr(ctx, name_node_id, 0)
            ctx:emit(name_s .. " = function(" .. param_str .. ")" .. ret_type .. " {")
        else
            local fname = ctx:name(name_n.d[1])
            ctx:check_ident(fname)
            if is_local then
                ctx:emit("function " .. fname .. "(" .. param_str .. ")" .. ret_type .. " {")
            else
                ctx:emit("function " .. fname .. "(" .. param_str .. ")" .. ret_type .. " {")
            end
        end
        ctx.indent = ctx.indent + 1
        emit_block(ctx, bs, bl)
        ctx.indent = ctx.indent - 1
        ctx:emit("}")

    elseif kind == defs.NODE_ASSIGN_STMT then
        local ts = d[1]
        local tl = d[2]
        local es = d[3]
        local el = d[4]
        local targets = ctx:list(ts, tl)
        local exprs = ctx:list(es, el)
        -- Emit each assignment; if counts differ, emit as destructure
        if #targets == 1 then
            local lhs = emit_expr(ctx, targets[1], 0)
            local rhs = emit_expr(ctx, exprs[1], 0)
            ctx:emit(lhs .. " = " .. rhs .. ";")
        else
            local lhs_parts = {}
            for i, tid in ipairs(targets) do
                lhs_parts[i] = emit_expr(ctx, tid, 0)
            end
            local rhs_parts = {}
            for i, eid in ipairs(exprs) do
                rhs_parts[i] = emit_expr(ctx, eid, 0)
            end
            ctx:emit("[" .. table.concat(lhs_parts, ", ") .. "] = [" .. table.concat(rhs_parts, ", ") .. "];")
        end

    elseif kind == defs.NODE_EXPR_STMT then
        local expr_id = d[1]
        local expr_n = ctx:node(expr_id)
        -- error("msg") as a statement
        if expr_n.kind == defs.NODE_CALL_EXPR then
            local callee_n = ctx:node(expr_n.d[1])
            if callee_n.kind == defs.NODE_IDENTIFIER then
                local cname = ctx:name(callee_n.d[1])
                if cname == "error" then
                    local args = emit_expr_list(ctx, expr_n.d[2], expr_n.d[3])
                    ctx:emit("throw new Error(" .. args .. ");")
                    return
                end
            end
        end
        ctx:emit(emit_expr(ctx, expr_id, 0) .. ";")

    elseif kind == defs.NODE_RETURN_STMT then
        local rs = d[1]
        local rl = d[2]
        if rl == 0 then
            ctx:emit("return;")
        elseif rl == 1 then
            local exprs = ctx:list(rs, rl)
            ctx:emit("return " .. emit_expr(ctx, exprs[1], 0) .. ";")
        else
            local exprs = ctx:list(rs, rl)
            local parts = {}
            for i, eid in ipairs(exprs) do
                parts[i] = emit_expr(ctx, eid, 0)
            end
            ctx:emit("return [" .. table.concat(parts, ", ") .. "];")
        end

    elseif kind == defs.NODE_IF_STMT then
        local cs = d[1]
        local cl = d[2]
        local clauses = ctx:list(cs, cl)
        for i, cid in ipairs(clauses) do
            local cn = ctx:node(cid)
            local test_id = cn.d[1]
            local bs = cn.d[2]
            local bl = cn.d[3]
            if test_id == -1 then
                -- else clause
                ctx:emit("} else {")
            elseif i == 1 then
                ctx:emit("if (" .. emit_expr(ctx, test_id, 0) .. ") {")
            else
                ctx:emit("} else if (" .. emit_expr(ctx, test_id, 0) .. ") {")
            end
            ctx.indent = ctx.indent + 1
            emit_block(ctx, bs, bl)
            ctx.indent = ctx.indent - 1
        end
        ctx:emit("}")

    elseif kind == defs.NODE_WHILE_STMT then
        local test_id = d[1]
        local bs = d[2]
        local bl = d[3]
        ctx:emit("while (" .. emit_expr(ctx, test_id, 0) .. ") {")
        ctx.indent = ctx.indent + 1
        emit_block(ctx, bs, bl)
        ctx.indent = ctx.indent - 1
        ctx:emit("}")

    elseif kind == defs.NODE_REPEAT_STMT then
        local test_id = d[1]
        local bs = d[2]
        local bl = d[3]
        ctx:emit("do {")
        ctx.indent = ctx.indent + 1
        emit_block(ctx, bs, bl)
        ctx.indent = ctx.indent - 1
        ctx:emit("} while (!(" .. emit_expr(ctx, test_id, 0) .. "));")

    elseif kind == defs.NODE_DO_STMT then
        local bs = d[1]
        local bl = d[2]
        ctx:emit("{")
        ctx.indent = ctx.indent + 1
        emit_block(ctx, bs, bl)
        ctx.indent = ctx.indent - 1
        ctx:emit("}")

    elseif kind == defs.NODE_FOR_NUM then
        -- for i = init, limit [, step] do ... end
        local var_id = d[1]
        local init_id = d[2]
        local limit_id = d[3]
        local step_id = d[4]  -- -1 if no step
        local bs = d[5]
        local bl = d[6]
        local vname = ctx:name(var_id)
        ctx:check_ident(vname)
        local init_s = emit_expr(ctx, init_id, 0)
        local limit_s = emit_expr(ctx, limit_id, 0)
        -- Adjust init for 0-indexing (subtract 1 from numeric literals)
        local init_n = ctx:node(init_id)
        local adjusted_init
        if init_n.kind == defs.NODE_LITERAL and init_n.d[1] == defs.LIT_INTEGER then
            adjusted_init = tostring(init_n.d[2] - 1)
        elseif init_n.kind == defs.NODE_LITERAL and init_n.d[1] == defs.LIT_NUMBER then
            local v = i32x2_to_double(init_n.d[2], init_n.d[3])
            adjusted_init = tostring(v - 1)
        else
            adjusted_init = "(" .. init_s .. ") - 1"
        end
        local step_s
        if step_id == -1 then
            step_s = "1"
        else
            step_s = emit_expr(ctx, step_id, 0)
        end
        -- Check if limit is a length expression (#foo) to use < instead of <=
        local limit_n = ctx:node(limit_id)
        local cmp
        if limit_n.kind == defs.NODE_UNARY_EXPR and limit_n.d[1] == defs.OP_LEN then
            cmp = "<"
        else
            cmp = "<="
        end
        local header = string.format(
            "for (let %s = %s; %s %s %s; %s += %s) {",
            vname, adjusted_init, vname, cmp, limit_s, vname, step_s
        )
        ctx:emit(header)
        ctx.indent = ctx.indent + 1
        emit_block(ctx, bs, bl)
        ctx.indent = ctx.indent - 1
        ctx:emit("}")

    elseif kind == defs.NODE_FOR_IN then
        -- for k, v in expr do ... end
        local ns = d[1]
        local nl = d[2]
        local es = d[3]
        local el = d[4]
        local bs = d[5]
        local bl = d[6]
        local names = ctx:list(ns, nl)
        local exprs = ctx:list(es, el)
        local name_parts = {}
        for i, nid2 in ipairs(names) do
            local nm = ctx:name(nid2)
            ctx:check_ident(nm)
            name_parts[i] = nm
        end
        local var_str = #name_parts > 1
            and "[" .. table.concat(name_parts, ", ") .. "]"
            or name_parts[1]
        -- Detect ipairs/pairs by inspecting the expression
        -- emit_expr already handles ipairs → .entries() and pairs → Object.entries()
        local iter_s = emit_expr_list(ctx, es, el)
        ctx:emit("for (const " .. var_str .. " of " .. iter_s .. ") {")
        ctx.indent = ctx.indent + 1
        emit_block(ctx, bs, bl)
        ctx.indent = ctx.indent - 1
        ctx:emit("}")

    elseif kind == defs.NODE_BREAK_STMT then
        ctx:emit("break;")

    elseif kind == defs.NODE_GOTO_STMT then
        local label_id = d[1]
        ctx:emit("continue " .. ctx:name(label_id) .. ";")

    elseif kind == defs.NODE_LABEL_STMT then
        local label_id = d[1]
        ctx:emit(ctx:name(label_id) .. ":")

    elseif kind == defs.NODE_CHUNK then
        local bs = d[1]
        local bl = d[2]
        emit_block(ctx, bs, bl)

    else
        ctx:emit("/* TODO: stmt kind=" .. tostring(kind) .. " */")
    end
end

emit_block = function(ctx, bs, bl)
    local stmts = ctx:list(bs, bl)
    for _, sid in ipairs(stmts) do
        -- Skip statements that have been absorbed into class declarations.
        if ctx.skip_stmts and ctx.skip_stmts[sid] then
            -- (absorbed into a class declaration)
        else
            emit_stmt(ctx, sid)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Annotation declaration emitter
-- Emits `--::` type declarations as TypeScript type aliases.
-- ---------------------------------------------------------------------------
local function emit_decl_annotations(ctx)
    local lines = {}
    -- Scan all annotations for ANN_DECL kind
    for _, ann in pairs(ctx.anns) do
        if ann.kind == "decl" then
            -- content like "Foo = { x: integer }"
            local name, body = ann.content:match("^([%a_][%w_]*)%s*=%s*(.+)$")
            if name and body then
                local ts_body = ann_to_ts(body)
                lines[#lines + 1] = "export type " .. name .. " = " .. ts_body .. ";"
            end
        end
    end
    return lines
end

-- ---------------------------------------------------------------------------
-- Class pattern scanner
--
-- Detects the Lua OOP prototype pattern at chunk level and returns a table
-- describing each discovered class prototype so the emitter can emit TS
-- `class` syntax instead of individual statements.
--
-- Detected patterns (all at top-level of the chunk):
--   local M = {}                       → proto declaration
--   M.__index = M                      → marks M as a class prototype
--   function M.new(...) ... end        → constructor
--   function M:method(...)             → instance method (self prepended by parser)
--   function M.method(self, ...)       → instance method (explicit self)
--   function M.static(...)             → static method (no self)
--
-- Returns: { [proto_name] = ClassInfo }
-- ClassInfo = {
--   decl_id       : node id of `local M = {}` (to skip)
--   index_id      : node id of `M.__index = M` (to skip)
--   ctor_id       : node id of `function M.new(...)` (to emit as constructor)
--   methods       : array of { id, name, is_static }
-- }
-- skip_ids: set of all stmt ids that should NOT be emitted by emit_stmt.
-- ---------------------------------------------------------------------------

-- Returns the single string name of an identifier node, or nil.
local function ident_name(ctx, nid)
    local n = ctx:node(nid)
    if n.kind ~= defs.NODE_IDENTIFIER then return nil end
    return ctx:name(n.d[1])
end

-- Returns (obj_name, field_name) if nid is a NODE_FIELD_EXPR whose object is
-- a simple identifier, otherwise nil.
local function field_of_ident(ctx, nid)
    local n = ctx:node(nid)
    if n.kind ~= defs.NODE_FIELD_EXPR then return nil end
    local obj_name = ident_name(ctx, n.d[1])
    if not obj_name then return nil end
    local field_name = ctx:name(n.d[2])
    return obj_name, field_name
end

-- Returns true if nid is a call to setmetatable(_, proto_name) or
-- setmetatable(_, { __index = proto_name }).
local function is_setmetatable_call(ctx, nid, proto_name)
    local n = ctx:node(nid)
    if n.kind ~= defs.NODE_CALL_EXPR then return false end
    local callee_n = ctx:node(n.d[1])
    if callee_n.kind ~= defs.NODE_IDENTIFIER then return false end
    if ctx:name(callee_n.d[1]) ~= "setmetatable" then return false end
    if n.d[3] ~= 2 then return false end  -- must have exactly 2 args
    local args = ctx:list(n.d[2], 2)
    local mt_n = ctx:node(args[2])
    -- setmetatable(t, M)
    if mt_n.kind == defs.NODE_IDENTIFIER then
        return ctx:name(mt_n.d[1]) == proto_name
    end
    -- setmetatable(t, { __index = M })
    if mt_n.kind == defs.NODE_TABLE_EXPR and mt_n.d[2] == 1 then
        local fields = ctx:list(mt_n.d[1], 1)
        local fn = ctx:node(fields[1])
        -- key must be __index
        if fn.d[1] == -1 then return false end  -- positional field
        local key_n = ctx:node(fn.d[1])
        if key_n.kind ~= defs.NODE_LITERAL or key_n.d[1] ~= defs.LIT_STRING then return false end
        if ctx:name(key_n.d[2]) ~= "__index" then return false end
        -- value must be proto_name
        local val_name = ident_name(ctx, fn.d[2])
        return val_name == proto_name
    end
    return false
end

local function scan_classes(ctx, stmt_ids)
    local classes = {}   -- { [proto_name] = ClassInfo }
    local skip    = {}   -- { [stmt_id] = true }

    -- Pass 1: find `local M = {}` and `M.__index = M`.
    for _, sid in ipairs(stmt_ids) do
        local sn = ctx:node(sid)

        -- local M = {}
        if sn.kind == defs.NODE_LOCAL_STMT then
            local names = ctx:list(sn.d[1], sn.d[2])
            if sn.d[2] == 1 and sn.d[4] == 1 then
                local name = ctx:name(names[1])
                local exprs = ctx:list(sn.d[3], 1)
                local val_n = ctx:node(exprs[1])
                if val_n.kind == defs.NODE_TABLE_EXPR and val_n.d[2] == 0 then
                    -- `local M = {}` — candidate prototype declaration
                    if not classes[name] then
                        classes[name] = {
                            decl_id  = sid,
                            index_id = nil,
                            ctor_id  = nil,
                            methods  = {},
                        }
                    end
                end
            end

        -- M.__index = M
        elseif sn.kind == defs.NODE_ASSIGN_STMT then
            if sn.d[2] == 1 and sn.d[4] == 1 then
                local targets = ctx:list(sn.d[1], 1)
                local exprs   = ctx:list(sn.d[3], 1)
                local obj, field = field_of_ident(ctx, targets[1])
                if obj and field == "__index" then
                    local rhs = ident_name(ctx, exprs[1])
                    if rhs == obj and classes[obj] then
                        classes[obj].index_id = sid
                        skip[sid] = true
                    end
                end
            end
        end
    end

    -- Remove candidates that never got M.__index = M (they're not OOP prototypes).
    for name, info in pairs(classes) do
        if not info.index_id then
            classes[name] = nil
        end
    end

    -- Pass 2: find constructor and methods.
    for _, sid in ipairs(stmt_ids) do
        local sn = ctx:node(sid)
        if sn.kind == defs.NODE_FUNC_DECL then
            local name_nid = sn.d[1]
            local obj, field = field_of_ident(ctx, name_nid)
            if obj and classes[obj] then
                local info = classes[obj]
                if field == "new" then
                    info.ctor_id = sid
                    skip[sid] = true
                else
                    -- Determine if instance method: first param is "self"
                    local is_instance = false
                    local ps, pl = sn.d[2], sn.d[3]
                    if pl >= 1 then
                        local params = ctx:list(ps, pl)
                        local first_name = ctx:name(params[1])
                        if first_name == "self" then
                            is_instance = true
                        end
                    end
                    info.methods[#info.methods + 1] = {
                        id        = sid,
                        name      = field,
                        is_static = not is_instance,
                    }
                    skip[sid] = true
                end
            end
        end
    end

    -- Mark decl_id for skipping only for confirmed prototypes.
    for _, info in pairs(classes) do
        skip[info.decl_id] = true
        if info.ctor_id then skip[info.ctor_id] = true end
    end

    -- Pass 3: find M.__index = Other (non-self-referential delegation).
    -- These are __index assignments where the RHS is not M itself (i.e. not
    -- the class pattern already handled above).  Emit as Object.setPrototypeOf.
    -- { [stmt_id] = { lhs = "M", rhs_id = node_id } }
    local delegations = {}
    for _, sid in ipairs(stmt_ids) do
        if not skip[sid] then
            local sn = ctx:node(sid)
            if sn.kind == defs.NODE_ASSIGN_STMT and sn.d[2] == 1 and sn.d[4] == 1 then
                local targets = ctx:list(sn.d[1], 1)
                local exprs   = ctx:list(sn.d[3], 1)
                local obj, field = field_of_ident(ctx, targets[1])
                if obj and field == "__index" then
                    -- Any __index assignment not already skipped (i.e. not M.__index = M)
                    -- is a delegation.
                    delegations[sid] = { lhs = obj, rhs_id = exprs[1] }
                    skip[sid] = true
                end
            end
        end
    end

    return classes, skip, delegations
end

-- Emit a constructor body, transforming it into a TypeScript constructor.
-- Skips: `local self = setmetatable(...)` and `return self` statements.
-- Replaces field assignments `self.x = v` with `this.x = v`.
local function emit_ctor_body(ctx, proto_name, bs, bl)
    local stmts = ctx:list(bs, bl)
    for _, sid in ipairs(stmts) do
        local sn = ctx:node(sid)

        -- Skip: local self = setmetatable({}, M) (or { __index = M })
        if sn.kind == defs.NODE_LOCAL_STMT then
            local names = ctx:list(sn.d[1], sn.d[2])
            if sn.d[2] == 1 and sn.d[4] == 1 then
                if ctx:name(names[1]) == "self" then
                    local exprs = ctx:list(sn.d[3], 1)
                    if is_setmetatable_call(ctx, exprs[1], proto_name) then
                        -- Skip this statement.
                        goto continue
                    end
                end
            end
        end

        -- Skip: return self
        if sn.kind == defs.NODE_RETURN_STMT then
            if sn.d[2] == 1 then
                local exprs = ctx:list(sn.d[1], 1)
                local ret_name = ident_name(ctx, exprs[1])
                if ret_name == "self" then
                    goto continue
                end
            end
        end

        emit_stmt(ctx, sid)
        ::continue::
    end
end

-- Emit a constructor body preamble: `const self = this;` so that field
-- assignments like `self.x = v` in the Lua body work as `this.x`.
-- This is emitted before the body statements (after the setmetatable skip).
local function emit_ctor_body_with_self(ctx, proto_name, bs, bl)
    ctx:emit("const self = this;")
    emit_ctor_body(ctx, proto_name, bs, bl)
end

-- Emit a method body, replacing `self` with `this` in all expressions.
-- We do this by temporarily replacing `self` identifier emissions.
-- Actually: since we just strip `self` from param list and rely on `this`
-- being implicit, we don't need to rewrite the body — `self` references
-- in JS/TS are just `self` (a valid identifier). However, TS classes use
-- `this`, so we emit a `const self = this;` preamble so the body works.
local function emit_method_body(ctx, bs, bl)
    ctx:emit("const self = this;")
    emit_block(ctx, bs, bl)
end

-- Emit a full class declaration for a detected prototype.
local function emit_class(ctx, proto_name, info)
    ctx:emit("class " .. proto_name .. " {")
    ctx.indent = ctx.indent + 1

    -- Constructor
    if info.ctor_id then
        local cn = ctx:node(info.ctor_id)
        local ps, pl = cn.d[2], cn.d[3]
        local bs, bl = cn.d[4], cn.d[5]
        local has_vararg = (cn.flags % 2) == 1
        -- ctor params: strip nothing (new() has no implicit self)
        local params = ctx:list(ps, pl)
        local param_parts = {}
        for i, pid in ipairs(params) do
            param_parts[i] = param_name(ctx, pid)
        end
        if has_vararg then param_parts[#param_parts + 1] = "...args" end
        ctx:emit("constructor(" .. table.concat(param_parts, ", ") .. ") {")
        ctx.indent = ctx.indent + 1
        emit_ctor_body_with_self(ctx, proto_name, bs, bl)
        ctx.indent = ctx.indent - 1
        ctx:emit("}")
    end

    -- Methods
    for _, minfo in ipairs(info.methods) do
        local mn = ctx:node(minfo.id)
        local ps, pl = mn.d[2], mn.d[3]
        local bs, bl = mn.d[4], mn.d[5]
        local has_vararg = (mn.flags % 2) == 1
        local params = ctx:list(ps, pl)
        local param_parts = {}
        local start_idx = 1
        if not minfo.is_static and pl >= 1 then
            -- strip self from param list
            local first = ctx:name(params[1])
            if first == "self" then start_idx = 2 end
        end
        for i = start_idx, pl do
            param_parts[#param_parts + 1] = param_name(ctx, params[i])
        end
        if has_vararg then param_parts[#param_parts + 1] = "...args" end
        local pstr = table.concat(param_parts, ", ")
        local prefix = minfo.is_static and "static " or ""
        ctx:emit(prefix .. minfo.name .. "(" .. pstr .. ") {")
        ctx.indent = ctx.indent + 1
        if not minfo.is_static then
            emit_method_body(ctx, bs, bl)
        else
            emit_block(ctx, bs, bl)
        end
        ctx.indent = ctx.indent - 1
        ctx:emit("}")
    end

    ctx.indent = ctx.indent - 1
    ctx:emit("}")
end

-- Emit the top-level chunk, scanning for class patterns first.
local function emit_chunk_with_classes(ctx, bs, bl)
    local stmt_ids = ctx:list(bs, bl)

    -- Scan for prototype class patterns and delegation assignments.
    local classes, skip, delegations = scan_classes(ctx, stmt_ids)
    ctx.skip_stmts = skip

    -- Emit class declarations in declaration order (preserve source order).
    -- We do this by emitting classes when we hit their decl_id statement.
    -- Mark each class by its decl_id for ordered emission.
    local class_at_decl = {}
    for name, info in pairs(classes) do
        class_at_decl[info.decl_id] = { name = name, info = info }
    end

    for _, sid in ipairs(stmt_ids) do
        if class_at_decl[sid] then
            -- Emit the class declaration in place of the `local M = {}` statement.
            local entry = class_at_decl[sid]
            emit_class(ctx, entry.name, entry.info)
        elseif delegations[sid] then
            -- M.__index = Other → Object.setPrototypeOf(M, Other)
            local d = delegations[sid]
            local rhs_s = emit_expr(ctx, d.rhs_id, 0)
            ctx:emit("Object.setPrototypeOf(" .. d.lhs .. ", " .. rhs_s .. ");")
        elseif not skip[sid] then
            emit_stmt(ctx, sid)
        end
        -- (else: skip — absorbed into class)
    end
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--: (string, ({ filename: string | nil, module: string | nil, strict: boolean | nil, harden: boolean | nil }) | nil) -> (string | nil, string | nil)
function M.transpile(source, opts)
    opts = opts or {}
    local filename = opts.filename or "?"
    local ok, result = pcall(function()
        local parsed = parse_mod.parse(source, filename)
        local ctx = new_ctx(parsed.pool, parsed.nodes, parsed.lists, source, opts)

        -- Walk the root chunk
        local root = ctx:node(parsed.root)
        if root.kind ~= defs.NODE_CHUNK then
            return nil, "expected chunk root"
        end
        emit_chunk_with_classes(ctx, root.d[1], root.d[2])

        -- Collect type declarations from --:: annotations
        local decl_lines = emit_decl_annotations(ctx)

        -- Build output
        local out = {}

        -- Header
        if opts.strict then
            out[#out + 1] = "// @ts-strict-mode"
        end

        -- Harden helpers (emitted exactly once at the top, in fixed order).
        if ctx.harden then
            local emitted_any = false
            for _, hname in ipairs(HARDEN_HELPERS_ORDER) do
                if ctx.harden_used[hname] then
                    out[#out + 1] = HARDEN_HELPERS[hname]
                    emitted_any = true
                end
            end
            if emitted_any then out[#out + 1] = "" end
        end

        -- ESM imports (hoisted)
        if opts.module ~= "cjs" and #ctx.import_order > 0 then
            for _, path in ipairs(ctx.import_order) do
                local alias = ctx.imports[path]
                out[#out + 1] = 'import * as ' .. alias .. ' from "' .. path .. '";'
            end
            out[#out + 1] = ""
        end

        -- Type declarations
        if #decl_lines > 0 then
            for _, dl in ipairs(decl_lines) do
                out[#out + 1] = dl
            end
            out[#out + 1] = ""
        end

        -- Body
        for _, line in ipairs(ctx.lines) do
            out[#out + 1] = line
        end

        return table.concat(out, "\n")
    end)
    if not ok then
        return nil, tostring(result)
    end
    return result
end

--: (string, ({ filename: string | nil, module: string | nil, strict: boolean | nil, harden: boolean | nil }) | nil) -> (string | nil, string | nil)
function M.transpile_file(path, opts)
    local f, err = io.open(path, "r")
    if not f then return nil, "cannot open " .. path .. ": " .. (err or "?") end
    local source = f:read("*a")
    f:close()
    opts = opts or {}
    opts.filename = opts.filename or path
    return M.transpile(source, opts)
end

-- ---------------------------------------------------------------------------
-- Bundle API
-- ---------------------------------------------------------------------------

-- Bundle preamble: module registry + __require helper.
local BUNDLE_PREAMBLE = [[// --- crescent bundle ---
const __modules = {};
const __require = (id) => {
  if (!__modules[id]) throw new Error("module not found: " + id);
  if (!__modules[id].__loaded) {
    __modules[id].__loaded = true;
    __modules[id].exports = {};
    __modules[id].factory(__modules[id].exports, __require);
  }
  return __modules[id].exports;
};]]

-- Transpile a single source in bundle mode and return { body_lines, deps }.
-- body_lines: array of lines (the transpiled body, without preamble/imports).
-- deps: array of dot-separated module names required by this source.
local function transpile_bundle_module(source, opts)
    local bundle_opts = {}
    for k, v in pairs(opts or {}) do bundle_opts[k] = v end
    bundle_opts.bundle_mode = true
    bundle_opts.module = "cjs"   -- suppress ESM import hoisting

    local ok, result = pcall(function()
        local parsed = parse_mod.parse(source, bundle_opts.filename or "?")
        local ctx = new_ctx(parsed.pool, parsed.nodes, parsed.lists, source, bundle_opts)

        local root = ctx:node(parsed.root)
        if root.kind ~= defs.NODE_CHUNK then
            error("expected chunk root")
        end
        emit_chunk_with_classes(ctx, root.d[1], root.d[2])

        return { lines = ctx.lines, deps = ctx.bundle_requires }
    end)
    if not ok then
        return nil, tostring(result)
    end
    return result
end

-- Wrap transpiled body lines as a factory module entry.
-- mod_id: slash-separated module id (e.g. "lib/foo")
-- body_lines: array of indented body lines
local function wrap_module_factory(mod_id, body_lines)
    local parts = {}
    parts[#parts + 1] = '__modules["' .. mod_id .. '"] = { factory: (exports, __require) => {'
    for _, line in ipairs(body_lines) do
        parts[#parts + 1] = "  " .. line
    end
    parts[#parts + 1] = "}};"
    return parts
end

-- Transpile entry_path and all transitive require() deps into a single JS bundle.
--
-- entry_path  : module name for the entry (dot-separated, e.g. "myapp.main"), used as the registry id.
-- entry_src   : Lua source string for the entry module.
-- resolve_fn  : function(mod_name: string) -> string | nil
--               Called with a dot-separated module name. Return the Lua source, or nil to skip
--               (external/platform dep — a __require call will be emitted but the module won't
--               be inlined).
-- opts        : same opts as transpile (filename, strict, etc.), minus module (always bundle).
--
-- Returns bundle_string or (nil, errmsg).
function M.bundle(entry_path, entry_src, resolve_fn, opts)
    opts = opts or {}

    -- Work queue: { mod_name (dot-sep), source }
    -- visited: set of mod_names already processed (cycle guard)
    local visited = {}
    local order   = {}  -- ordered list of { mod_id, lines } for output
    local errors_out = {}

    local function process(mod_name, source)
        if visited[mod_name] then return end
        visited[mod_name] = true

        local mod_id = mod_name:gsub("%.", "/")
        local file_opts = {}
        for k, v in pairs(opts) do file_opts[k] = v end
        file_opts.filename = file_opts.filename or (mod_id .. ".lua")

        local result, err = transpile_bundle_module(source, file_opts)
        if not result then
            errors_out[#errors_out + 1] = "error transpiling " .. mod_name .. ": " .. (err or "?")
            return
        end

        -- Recurse into deps first (depth-first, topological order)
        for _, dep_name in ipairs(result.deps) do
            if not visited[dep_name] then
                local dep_src = resolve_fn(dep_name)
                if dep_src then
                    process(dep_name, dep_src)
                end
                -- If resolve_fn returns nil, the dep is external — skip inlining.
                -- The __require call will still be emitted; at runtime it will
                -- throw "module not found" unless the host provides it.
            end
        end

        order[#order + 1] = { mod_id = mod_id, lines = result.lines }
    end

    process(entry_path, entry_src)

    if #errors_out > 0 then
        return nil, table.concat(errors_out, "\n")
    end

    -- Assemble output
    local out = {}

    if opts.strict then
        out[#out + 1] = "// @ts-strict-mode"
    end
    out[#out + 1] = BUNDLE_PREAMBLE
    out[#out + 1] = ""

    -- Emit each module as a factory (deps before entry due to depth-first order)
    for _, mod in ipairs(order) do
        local factory_lines = wrap_module_factory(mod.mod_id, mod.lines)
        for _, line in ipairs(factory_lines) do
            out[#out + 1] = line
        end
        out[#out + 1] = ""
    end

    -- Run the entry module
    local entry_id = entry_path:gsub("%.", "/")
    out[#out + 1] = "// run entry"
    out[#out + 1] = '__require("' .. entry_id .. '");'

    return table.concat(out, "\n")
end

return M
