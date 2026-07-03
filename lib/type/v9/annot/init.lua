-- lib/type/v9/annot/init.lua
-- The v9 ANNOTATION SEAM: the `--:` type-grammar STRING -> a small v9-owned
-- tree (At). Deliberately NOT a lift of the legacy ann.lua (entangled with
-- the legacy type algebra); this parser knows only the v9 lattice's
-- vocabulary and names everything else honestly.
--
-- SUPPORTED in v0 (maps losslessly-enough onto the v9 lattice):
--   atoms          nil true false boolean number string table function
--                  (integer -> the number atom; string/number literal types
--                  -> their base atom — stated UP-approximations: sound as
--                  seeds, wider as bounds. true/false are EXACT: the lattice
--                  carries boolean literal atoms; boolean = true | false)
--   unknown, never
--   unions         T | U | nil
--   records        { x: T, y?: U, readonly z: V, ... }   (the `...` open
--                  marker is a no-op: v9 records are always open)
--   index sigs     { [string]: T } / { [number]: T } / both — the
--                  index-bounded record (DISTINCT from the `...` marker);
--                  `T[]` is sugar for { [number]: T }. Key types beyond
--                  string/number are the `index-signature-key` bucket.
--   instantiation  $Elem<N> / $Values<N> / $Keys<N> / $Arg<N> in a declared
--                  fn's RESULT position: computed per call site from
--                  argument N (iteration projections / identity) — what
--                  lets pairs/ipairs declarations carry element types
--                  without generics.
--   functions      (T, U) -> R   (a: T) -> R   () -> (R1, R2)   ...T rest
--                  `x is T` predicates read as boolean results (the
--                  narrowing power is a later increment, stated)
--                  `-> ...(T)` result spread reads as a result-OPEN arrow
--                  `-> (R1, R2, ...)` a trailing `...` in a result tuple
--                  marks the arrow result-OPEN after its fixed positions
--                  (positions beyond read as unknown, not nil)
--   aliases        Name        resolved through the injected `resolve` cap.
--                  RECURSIVE aliases unroll once and CUT to `unknown` at
--                  the knot — the same bounded-depth upper approximation as
--                  lattice.clip (fields above the knot stay precise; the
--                  annotation is fully read, not bucketed)
--
-- EVERYTHING ELSE routes to a NAMED bucket (returned in `buckets`; the
-- caller prefixes `unsupported:annotation-`): generic / intrinsic / typeof /
-- intersection / complement / index-signature-key / meta-slot / tuple /
-- cdata / any / unknown-name / recursive-alias / alias-budget / parse. A
-- bucketed subtree reads as `unknown` (or the `table` atom where table-ness
-- is certain) — honest, dialable, never a silent guess.
--
-- Errors are data at the public seam: `(nil, buckets, errmsg)`.

if not package.path:find("?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: At = { k: string, ... }
--:: Tok = { t: string, v: string }
--:: Resolve = (name: string) -> (string | nil, string | nil)
--:: Ctx = { resolve: Resolve, buckets: { [integer]: string }, seen: { [string]: boolean }, visiting: { [string]: integer }, depth: integer, memo: { [string]: At }, expansions: integer }
--:: P = { toks: { [integer]: Tok }, pos: integer, ctx: Ctx }

-- Alias-expansion budget per parse: a MUTUALLY-recursive alias graph can
-- make path-wise unrolling exponential (each path re-expands every alias it
-- has not seen twice — the js_types DOM graph hangs a naive walk). Two
-- guards: expansions are MEMOIZED per parse (an alias expands once; later
-- references share the immutable subtree — the At becomes a DAG), and a
-- hard budget converts any residual pathology into the honest
-- `alias-budget` bucket instead of a hang.
local MAX_EXPANSIONS = 512

-- Names that are types themselves, mapped to v9 atoms (integer is the
-- number atom in v0 — no int split in the lattice; true/false ARE the
-- lattice's boolean literal atoms, and "boolean" is their union).
local ATOM_NAMES = {
    ["nil"] = "nil", boolean = "boolean", number = "number", integer = "number",
    string = "string", table = "table", ["function"] = "function",
    ["true"] = "true", ["false"] = "false",
} --: { [string]: string }

-- ── tokenizer ───────────────────────────────────────────────────────────────

--: (string) -> ({ [integer]: Tok } | nil, string | nil)
local function tokenize(s)
    local toks = {} --: { [integer]: Tok }
    local i = 1
    local n = #s
    while i <= n do
        local c = s:sub(i, i)
        if c == " " or c == "\t" or c == "\n" or c == "\r" then
            i = i + 1
        elseif c:match("[%a_]") then
            local word = s:match("^[%w_]+", i) or c
            toks[#toks + 1] = { t = "ident", v = word }
            i = i + #word
        elseif c:match("%d") then
            local num = s:match("^%d[%w_.]*", i) or c
            toks[#toks + 1] = { t = "num", v = num }
            i = i + #num
        elseif c == "\"" or c == "'" then
            local j = i + 1
            while j <= n do
                local cj = s:sub(j, j)
                if cj == "\\" then
                    j = j + 2
                elseif cj == c then
                    break
                else
                    j = j + 1
                end
            end
            if j > n then return nil, "unterminated string literal" end
            toks[#toks + 1] = { t = "str", v = s:sub(i + 1, j - 1) }
            i = j + 1
        elseif s:sub(i, i + 2) == "..." then
            toks[#toks + 1] = { t = "...", v = "..." }
            i = i + 3
        elseif s:sub(i, i + 1) == "->" then
            toks[#toks + 1] = { t = "->", v = "->" }
            i = i + 2
        elseif c == "(" or c == ")" or c == "{" or c == "}" or c == "[" or c == "]"
            or c == "<" or c == ">" or c == "," or c == ":" or c == "?" or c == "|"
            or c == "&" or c == "~" or c == "$" or c == "#" or c == "." or c == "-"
            or c == "=" then
            toks[#toks + 1] = { t = c, v = c }
            i = i + 1
        else
            return nil, "unexpected character `" .. c .. "`"
        end
    end
    return toks, nil
end

-- ── parser plumbing ─────────────────────────────────────────────────────────

--: (P) -> Tok | nil
local function peek(p) return p.toks[p.pos] end

--: (P, integer) -> Tok | nil
local function peek_at(p, off) return p.toks[p.pos + off] end

--: (P) -> Tok | nil
local function advance(p)
    local t = p.toks[p.pos]
    p.pos = p.pos + 1
    return t
end

--: (P, string) -> boolean
local function at(p, t)
    local tok = p.toks[p.pos]
    return tok ~= nil and tok.t == t
end

--: (P, string) -> nil
local function expect(p, t)
    if not at(p, t) then
        local tok = p.toks[p.pos]
        error("expected `" .. t .. "`, got " .. (tok ~= nil and "`" .. tok.v .. "`" or "end"), 0)
    end
    p.pos = p.pos + 1
    return nil
end

-- Record a named bucket (dedup) and return the opaque node for it.
--: (P, feature: string, approx: string | nil) -> At
local function bucket(p, feature, approx)
    local ctx = p.ctx
    if not ctx.seen[feature] then
        ctx.seen[feature] = true
        ctx.buckets[#ctx.buckets + 1] = feature
    end
    return { k = "opaque", feature = feature, approx = approx }
end

-- Skip a balanced bracket run starting at the CURRENT opener token.
--: (P) -> nil
local function skip_balanced(p)
    local opener = advance(p)
    if opener == nil then return nil end
    local close = ")" --: string
    if opener.t == "{" then close = "}" end
    if opener.t == "[" then close = "]" end
    if opener.t == "<" then close = ">" end
    local depth = 1
    while depth > 0 do
        local tok = advance(p)
        if tok == nil then error("unbalanced `" .. opener.t .. "`", 0) end
        if tok.t == opener.t then depth = depth + 1 end
        if tok.t == close then depth = depth - 1 end
    end
    return nil
end

local parse_type, parse_term

-- ── records ─────────────────────────────────────────────────────────────────

--:: RecField = { name: string, at: At, optional: boolean, readonly: boolean }

--: (P) -> At
local function parse_record(p)
    expect(p, "{")
    local fields = {} --: { [integer]: RecField }
    local feature = nil --: string | nil
    local istr = nil --: At | nil
    local inum = nil --: At | nil
    while not at(p, "}") do
        if at(p, "...") then
            -- the open marker; v9 records are always open. `...[%K]: %V`
            -- match patterns ride the match bucket.
            advance(p)
            if at(p, "[") then
                feature = "match"
                skip_balanced(p)
                if at(p, ":") then
                    advance(p)
                    parse_type(p)
                end
            end
        elseif at(p, "#") then
            -- meta slot (metamethods): outside the v0 lattice.
            feature = "meta-slot"
            advance(p)
            if at(p, "...") then advance(p) end
            while not at(p, ",") and not at(p, "}") and peek(p) ~= nil do
                if at(p, "{") or at(p, "(") or at(p, "[") or at(p, "<") then
                    skip_balanced(p)
                else
                    advance(p)
                end
            end
        elseif at(p, "[") then
            -- index signature `[string]: T` / `[number]: T` — REAL v0 types
            -- (an index-bounded record; `integer` reads as number). Key
            -- types beyond string/number are the named
            -- `index-signature-key` boundary.
            advance(p)
            local kat = parse_type(p)
            expect(p, "]")
            expect(p, ":")
            local vat = parse_type(p)
            local kname = nil --: string | nil
            if kat.k == "atom" then
                local n = kat.name
                if type(n) == "string" then kname = n end
            end
            if kname == "string" then
                istr = vat
            elseif kname == "number" then
                inum = vat
            else
                feature = "index-signature-key"
            end
        else
            local ro = false
            if at(p, "ident") then
                local tok = peek(p)
                if tok ~= nil and tok.v == "readonly" then
                    local after = peek_at(p, 1)
                    if after ~= nil and (after.t == "ident" or after.t == "str") then
                        ro = true
                        advance(p)
                    end
                end
            end
            local key = advance(p)
            if key == nil or (key.t ~= "ident" and key.t ~= "str") then
                error("expected a field name in record type", 0)
            end
            local opt = false
            if at(p, "?") then
                opt = true
                advance(p)
            end
            expect(p, ":")
            local fat = parse_type(p)
            fields[#fields + 1] = { name = key.v, at = fat, optional = opt, readonly = ro }
        end
        if at(p, ",") then advance(p) elseif not at(p, "}") then break end
    end
    expect(p, "}")
    if feature ~= nil then
        -- table-ness is certain, field precision is not: the whole record
        -- approximates to the `table` atom (stated, dialable).
        return bucket(p, feature, "table")
    end
    return { k = "record", fields = fields, istr = istr, inum = inum }
end

-- ── function types / groups ─────────────────────────────────────────────────

--:: FnParam = { at: At, optional: boolean }

-- After `->`: a single type, a parenthesized result tuple, an `x is T`
-- predicate (reads as boolean — narrowing is a later increment), or a
-- `...(T)` result spread (reads as a result-OPEN arrow).
--: (P) -> ({ [integer]: At }, boolean)
local function parse_results(p)
    if at(p, "...") then
        advance(p)
        if at(p, "(") then skip_balanced(p) else parse_term(p) end
        bucket(p, "return-spread", nil)
        return {}, true
    end
    local tok = peek(p)
    local after = peek_at(p, 1)
    if tok ~= nil and tok.t == "ident" and after ~= nil and after.t == "ident" and after.v == "is" then
        advance(p)
        advance(p)
        parse_type(p)
        return { { k = "atom", name = "boolean" } }, false
    end
    local t = parse_type(p)
    if t.k == "tuple" then
        local parts = t.parts --: { [integer]: At }
        return parts, t.open == true
    end
    return { t }, false
end

-- A parenthesized group: function params (when `->` follows), a plain
-- parenthesized type, or a result tuple (legal only after `->`; the caller
-- buckets it elsewhere).
--: (P) -> At
local function parse_group(p)
    expect(p, "(")
    local params = {} --: { [integer]: FnParam }
    local vararg = false
    local rest = nil --: At | nil
    while not at(p, ")") do
        if at(p, "...") then
            advance(p)
            vararg = true
            if not at(p, ")") and not at(p, ",") then
                rest = parse_type(p)
            end
        else
            local opt = false
            local tok = peek(p)
            local after = peek_at(p, 1)
            if tok ~= nil and tok.t == "ident" and after ~= nil then
                -- `name: T` or `name?: T` — a param label, positional in v0.
                if after.t == ":" then
                    advance(p)
                    advance(p)
                elseif after.t == "?" then
                    local colon = peek_at(p, 2)
                    if colon ~= nil and colon.t == ":" then
                        opt = true
                        advance(p)
                        advance(p)
                        advance(p)
                    end
                end
            end
            local pat = parse_type(p)
            params[#params + 1] = { at = pat, optional = opt }
        end
        if at(p, ",") then advance(p) elseif not at(p, ")") then break end
    end
    expect(p, ")")
    if at(p, "->") then
        advance(p)
        local results, open = parse_results(p)
        return {
            k = "fn", params = params, vararg = vararg, rest = rest,
            results = results, open = open,
        }
    end
    if #params == 1 and not vararg and not params[1].optional then
        return params[1].at
    end
    -- a trailing `...` in a group read as a RESULT tuple marks the arrow
    -- result-open (parse_results consumes `open`; other positions ignore it).
    local parts = {} --: { [integer]: At }
    for i = 1, #params do parts[i] = params[i].at end
    return { k = "tuple", parts = parts, open = vararg }
end

-- ── primaries / terms / unions ──────────────────────────────────────────────

--: (P) -> At
local function parse_prim(p)
    local tok = peek(p)
    if tok == nil then error("type expected, got end of annotation", 0) end
    if tok.t == "(" then
        return parse_group(p)
    elseif tok.t == "{" then
        return parse_record(p)
    elseif tok.t == "~" then
        advance(p)
        parse_term(p)
        return bucket(p, "complement", nil)
    elseif tok.t == "<" then
        -- generic prelude `<T>(...) -> ...`: skip the binder + the body.
        skip_balanced(p)
        parse_type(p)
        return bucket(p, "generic", nil)
    elseif tok.t == "$" then
        advance(p)
        -- the CALL-SITE INSTANTIATION intrinsics `$Elem<N>` / `$Values<N>` /
        -- `$Keys<N>` / `$Arg<N>`: a declared RESULT position computed per
        -- call site from argument N's value (iteration projections /
        -- identity — see lattice.lua's header). Name-agnostic machinery:
        -- the power lives in the declaration, one generic arm in call_core.
        local name = nil --: string | nil
        if at(p, "ident") then
            local tk = peek(p)
            if tk ~= nil then name = tk.v end
            advance(p)
        end
        local proj = nil --: string | nil
        if name == "Elem" then proj = "elem" end
        if name == "Values" then proj = "values" end
        if name == "Keys" then proj = "keys" end
        if name == "Arg" then proj = "arg" end
        -- $Require<N>: the MODULE-SUMMARY instantiation — a declared result
        -- position computed from argument N's LITERAL module name at
        -- lowering (the one inst resolved from syntax, not the solved
        -- value: the lattice up-approximates string literals to the string
        -- atom, so the name exists only at the call site). The house
        -- convention's `typeof require(T) decays to $Require<T>`, carried
        -- into v9 as declaration data — `require` itself is NOT name-keyed
        -- anywhere; the power lives in its stdlib declaration.
        if name == "Require" then proj = "require" end
        if proj ~= nil and at(p, "<") then
            local numtok = peek_at(p, 1)
            local closer = peek_at(p, 2)
            if numtok ~= nil and numtok.t == "num" and closer ~= nil and closer.t == ">" then
                local idx = tonumber(numtok.v)
                if idx ~= nil then
                    advance(p)
                    advance(p)
                    advance(p)
                    return { k = "inst", proj = proj, idx = math.floor(idx) }
                end
            end
        end
        if at(p, "<") then skip_balanced(p) end
        return bucket(p, "intrinsic", nil)
    elseif tok.t == "str" then
        -- literal string type: UP-approximated to the string atom (stated).
        advance(p)
        return { k = "atom", name = "string" }
    elseif tok.t == "num" then
        advance(p)
        return { k = "atom", name = "number" }
    elseif tok.t == "-" then
        advance(p)
        if at(p, "num") then advance(p) end
        return { k = "atom", name = "number" }
    elseif tok.t == "ident" then
        local name = tok.v
        if name == "typeof" then
            advance(p)
            while at(p, "ident") or at(p, ".") do advance(p) end
            return bucket(p, "typeof", nil)
        end
        if name == "unknown" then
            advance(p)
            return { k = "unknown" }
        end
        if name == "never" then
            advance(p)
            return { k = "never" }
        end
        if name == "any" then
            -- `any` does not exist in crescent (conventions); named loudly.
            advance(p)
            return bucket(p, "any", nil)
        end
        if name == "cdata" then
            advance(p)
            return bucket(p, "cdata", nil)
        end
        local atom = ATOM_NAMES[name]
        if atom ~= nil then
            advance(p)
            return { k = "atom", name = atom }
        end
        -- alias / generic application / unknown name.
        advance(p)
        if at(p, "<") then
            skip_balanced(p)
            return bucket(p, "generic", nil)
        end
        local ctx = p.ctx
        local content, feature = ctx.resolve(name)
        if feature ~= nil then
            return bucket(p, feature, nil)
        end
        if content == nil then
            return bucket(p, "unknown-name", nil)
        end
        -- memoized expansion: an alias expands ONCE per parse; later
        -- references share the immutable subtree (the At is a DAG). This is
        -- what keeps mutually-recursive alias graphs linear instead of
        -- exponential-in-paths. (A memo hit computed under a knot cut is a
        -- sound upper approximation for any other position.)
        local hit = ctx.memo[name]
        if hit ~= nil then return hit end
        local count = ctx.visiting[name] or 0
        if count >= 2 then
            -- the knot: a recursive alias unrolls once, then cuts to
            -- unknown (a bounded-depth UPPER approximation, like clip).
            return { k = "unknown" }
        end
        if ctx.depth >= 24 then
            return bucket(p, "recursive-alias", nil)
        end
        ctx.expansions = ctx.expansions + 1
        if ctx.expansions > MAX_EXPANSIONS then
            -- the budget backstop: an honest named boundary, never a hang.
            return bucket(p, "alias-budget", nil)
        end
        local toks, terr = tokenize(content)
        if toks == nil then
            error("alias `" .. name .. "`: " .. (terr or "tokenize error"), 0)
        end
        ctx.visiting[name] = count + 1
        ctx.depth = ctx.depth + 1
        local sub = { toks = toks, pos = 1, ctx = ctx } --: P
        local t = parse_type(sub)
        ctx.depth = ctx.depth - 1
        ctx.visiting[name] = count
        ctx.memo[name] = t
        return t
    end
    error("type expected, got `" .. tok.v .. "`", 0)
end

-- postfix: `T[]` array sugar = `{ [number]: T }` (a real index-bounded
-- record, no bucket).
--: (P) -> At
parse_term = function(p)
    local t = parse_prim(p)
    while at(p, "[") do
        local after = peek_at(p, 1)
        if after ~= nil and after.t == "]" then
            advance(p)
            advance(p)
            local fields = {} --: { [integer]: RecField }
            t = { k = "record", fields = fields, istr = nil, inum = t }
        else
            break
        end
    end
    return t
end

--: (P) -> At
parse_type = function(p)
    local parts = { parse_term(p) } --: { [integer]: At }
    local intersect = false
    while at(p, "|") or at(p, "&") do
        if at(p, "&") then intersect = true end
        advance(p)
        parts[#parts + 1] = parse_term(p)
    end
    if intersect then
        return bucket(p, "intersection", nil)
    end
    local t = parts[1] --: At
    if #parts > 1 then
        t = { k = "union", parts = parts }
    end
    -- bare right-associative arrow sugar: `string -> integer`.
    if at(p, "->") then
        advance(p)
        local results, open = parse_results(p)
        local params = { { at = t, optional = false } } --: { [integer]: FnParam }
        return { k = "fn", params = params, vararg = false, rest = nil, results = results, open = open }
    end
    return t
end

-- ── public seam ─────────────────────────────────────────────────────────────

-- Parse one `--:` annotation string. `resolve(name)` is the alias cap:
-- returns (alias content, nil), (nil, feature) for a name that exists but
-- is outside v0 (a generic alias), or (nil, nil) for an unknown name.
-- Returns (At | nil, buckets, errmsg): buckets are the named-boundary
-- features encountered (dedup, in encounter order); a nil At means the
-- string does not parse as a type at all.
--: (content: string, resolve: Resolve) -> (At | nil, { [integer]: string }, string | nil)
function M.parse(content, resolve)
    local buckets = {} --: { [integer]: string }
    local toks0, terr = tokenize(content)
    local traw = toks0 --: unknown
    --: (x: unknown) -> x is { [integer]: Tok }
    local function is_toks(x) return type(x) == "table" end
    if not is_toks(traw) then return nil, buckets, terr end
    if #traw == 0 then return nil, buckets, "empty annotation" end
    local ctx = { resolve = resolve, buckets = buckets, seen = {}, visiting = {}, depth = 0, memo = {}, expansions = 0 } --: Ctx
    local p = { toks = traw, pos = 1, ctx = ctx } --: P
    local ok, res = pcall(parse_type, p)
    if not ok then return nil, buckets, tostring(res) end
    local t = res --: unknown
    --: (x: unknown) -> x is At
    local function is_at(x) return type(x) == "table" end
    if not is_at(t) then return nil, buckets, "annotation parser returned a non-node" end
    if p.pos <= #p.toks then
        local tok = p.toks[p.pos]
        return nil, buckets, "trailing `" .. tok.v .. "` after type"
    end
    return t, buckets, nil
end

-- Classify one `--::` declaration string. Returns one of:
--   ("alias", name, body)      Name = <type grammar>
--   ("declare", name, body)    declare name = <type grammar> — a GLOBAL
--                              declaration (the house no-ambient-globals
--                              convention); the caller wires it into its
--                              global environment
--   ("require", modname, nil)  `require "a.b.c"` — the TYPE-ONLY import
--                              directive: the caller imports module a.b.c's
--                              exported `--::` alias env (the cross-module
--                              seam); a `require` line without a literal
--                              module string stays the cross-module feature
--                              bucket
--   ("feature", feature, nil)  a named non-v0 form: module / augment /
--                              newtype / template / unseal ->
--                              annotation-<kw>; malformed require -> the
--                              cross-module boundary; generic aliases ->
--                              generic; a malformed `declare` (no `= T`
--                              body) -> annotation-declare
--   ("garbage", errmsg, nil)   does not classify
-- The generic-alias NAME is reported through the second return so callers
-- can map references to the generic bucket.
--: (content: string) -> (string, string, string | nil)
function M.classify_decl(content)
    local dname, dbody = content:match("^%s*declare%s+([%a_][%w_]*)%s*=%s*(.-)%s*$")
    if dname ~= nil and dbody ~= nil and dbody ~= "" then
        return "declare", dname, dbody
    end
    local name, body = content:match("^%s*([%a_][%w_]*)%s*=%s*(.*)$")
    if name ~= nil and body ~= nil then
        return "alias", name, body
    end
    local gname = content:match("^%s*([%a_][%w_]*)%s*<")
    if gname ~= nil then
        return "generic-alias", gname, nil
    end
    local kw = content:match("^%s*(%a+)")
    if kw == "require" then
        local mod = content:match("^%s*require%s*%(?%s*[\"']([^\"']+)[\"']")
        if mod ~= nil then
            return "require", mod, nil
        end
        return "feature", "cross-module", nil
    end
    if kw == "declare" or kw == "module" or kw == "augment" or kw == "newtype"
        or kw == "template" or kw == "unseal" then
        return "feature", "annotation-" .. kw, nil
    end
    return "garbage", "unrecognized `--::` declaration", nil
end

return M
