-- tooling/grammar_gen/derivations.lua
--
-- Each entry is a derivation: the decision-set for one real init.lua file,
-- expressed as an ordered list of segments. A "raw" segment is a terminal —
-- free-form content specific to this instance (the doc header, a one-off
-- explanatory comment) that isn't claimed to be a reusable production.
-- A "rule" segment is a reference to a production — one of the local
-- functions defined below, in the "productions" section — called with the
-- slot choices + minted parameters for this instance, with its expansion
-- captured immediately.
--
-- This is the "authoring as derivation" half of the mechanism: producing a
-- module's source is choosing, for each rule segment, which production
-- applies and what parameters it takes — not writing the boilerplate by
-- hand each time.
--
-- The productions and the derivations that use them live in this one file
-- rather than two (productions.lua + derivations.lua) because crescent's
-- typechecker gives require() an unknown-typed result for local (non-stdlib)
-- modules unless a top-level --:: declare exists for that require path.
-- Narrowing that unknown back down for a whole module surface — as opposed
-- to one value crossing a pcall boundary — hit a real substrate gap, and the
-- checker now rejects the force-cast the corpus's own tiered dispatchers use
-- at exactly this kind of boundary (see docs/design/decision-tape.md's
-- "what's proven vs aspirational" section and TODO.md for the reproduction).
-- One file sidesteps the gap entirely rather than hacking around it.
--
-- ═══════════════════════════ productions ═══════════════════════════

-- ── path_bootstrap ───────────────────────────────────────────────────────
-- Ensures package.path includes "./?/init.lua" so `require("lib.x.y")`
-- resolves lib/x/y/init.lua. Two independent slots were found here:
--   indent: how the body line is indented ("  " | "\t" | "    ")
--   find_string: the substring passed to package.path:find
--     - "./?/init.lua" (compress, crypto, regex, json — 4 reuses)
--     - "?/init.lua"   (base64 only — 1 occurrence)
-- The base64 find_string is very likely a copy-paste slip (it still works,
-- since :find without magic-char anchoring matches a substring — "?/init.lua"
-- is found inside "./?/init.lua" too — but it's not the same production as
-- the other four). We preserve it as observed rather than "fixing" it: the
-- grammar records what the corpus actually contains, not what it should
-- contain.
--: (indent: string, find_string: string) -> string
local function path_bootstrap(indent, find_string)
  return 'if not package.path:find("' .. find_string .. '", 1, true) then\n'
    .. indent .. 'package.path = "./?/init.lua;" .. package.path\n'
    .. 'end\n'
end

-- ── tier_select: "cast_narrow" pattern ───────────────────────────────────
-- Used by compress, crypto, regex. A single optional tier is tried; on
-- failure (or absence), fall through to the pure tier. The combined result
-- is narrowed with one big force-cast (`impl_t`) because the optional tier's
-- static type was lost crossing the `pcall(require, ...)` boundary.
--
-- Two established variants of the ok-check exist ("branch selection", not
-- minting, since both already occur in the corpus):
--   "plain"               (compress, crypto): if ok then .. else require(pure) end
--   "ternary_cache_clear" (regex): a ternary combined with clearing
--     package.loaded on failure, so a later retry (e.g. after installing the
--     optional dependency) doesn't see a stale failed cache entry.
--
-- opts:
--   indent           file-level indent string
--   var_ok           local var name for the pcall's ok flag ("ok")
--   var_raw          local var name for the pcall's raw result
--   system_path      require path for the optional tier
--   pure_path        require path for the baseline tier
--   variant          "plain" | "ternary_cache_clear"
--   probe_fields     ordered list of field names for the impl_t cast type,
--                    e.g. {"deflate","inflate",...,"_tier"}
--: (opts: { indent: string, var_ok: string, var_raw: string, system_path: string, pure_path: string, variant: string, system_label?: string, probe_fields: { [integer]: string } }) -> string
local function tier_select_cast_narrow(opts)
  local indent = opts.indent
  local parts = {} --: { [integer]: string }
  local probe_type = "{ "
  for _, f in ipairs(opts.probe_fields) do
    probe_type = probe_type .. f .. ": unknown, "
  end
  probe_type = probe_type .. "... }"

  if opts.variant == "plain" then
    parts[#parts + 1] = "local " .. opts.var_ok .. ", " .. opts.var_raw
      .. " = pcall(require, \"" .. opts.system_path .. "\")\n"
    parts[#parts + 1] = "local impl --: unknown\n"
    parts[#parts + 1] = "if " .. opts.var_ok .. " then\n"
    parts[#parts + 1] = indent .. "impl = " .. opts.var_raw .. "\n"
    parts[#parts + 1] = "else\n"
    parts[#parts + 1] = indent .. "impl = require(\"" .. opts.pure_path .. "\")\n"
    parts[#parts + 1] = "end\n"
  elseif opts.variant == "ternary_cache_clear" then
    local system_label = opts.system_label or "system"
    parts[#parts + 1] = "-- Try system tier first (" .. system_label .. "), fall back to pure Lua.\n"
    parts[#parts + 1] = "local " .. opts.var_ok .. ", " .. opts.var_raw
      .. " = pcall(require, \"" .. opts.system_path .. "\")\n"
    parts[#parts + 1] = "if not " .. opts.var_ok .. " then\n"
    parts[#parts + 1] = indent .. "-- Clear partial require cache entry so future attempts can retry.\n"
    parts[#parts + 1] = indent .. "package.loaded[\"" .. opts.system_path .. "\"] = nil\n"
    parts[#parts + 1] = "end\n"
    parts[#parts + 1] = "local impl_raw = (" .. opts.var_ok .. " and type(" .. opts.var_raw .. ") == \"table\") and "
      .. opts.var_raw .. " or require(\"" .. opts.pure_path .. "\")\n"
    parts[#parts + 1] = "local impl_u = impl_raw --[[: unknown]]\n"
  else
    error("tier_select_cast_narrow: unknown variant " .. tostring(opts.variant))
  end

  if opts.variant == "plain" then
    parts[#parts + 1] = "local impl_t = impl --[[:! " .. probe_type .. "]]\n"
  else
    parts[#parts + 1] = "local impl_t = impl_u --[[:! " .. probe_type .. "]]\n"
  end

  return table.concat(parts)
end

-- ── tier_select: "incremental_override" pattern ──────────────────────────
-- Used by base64, json. The pure tier is required directly (so it keeps its
-- static type — no cast needed) and used as the initial baseline. Each
-- optional tier is then tried in turn; on success the baseline is
-- overridden. This is the OTHER established alternative at the same
-- "how does a module select and narrow across tiers" slot as
-- tier_select_cast_narrow above — not a different mechanism, a different
-- production filling the same slot.
--
-- The per-tier "try this tier" block is itself a repeated sub-production:
-- it occurs twice in base64 (ffi, simd) and twice in json (ffi, simd) — 4
-- occurrences of one production, discovered structurally, not asserted.
--
-- opts:
--   indent        file-level indent string
--   pure_path     require path for the baseline (pure) tier
--   impl_type     name of the already-declared Impl type (e.g. "Base64Impl")
--   probe_field   field probed on each optional tier's result table
--   tiers         ordered list of { name, require_path, label_comment }
--: (opts: { indent: string, pure_path: string, impl_type: string, probe_field: string, tiers: { [integer]: { name: string, require_path: string, label_comment?: string, val_suffix?: string } } }) -> string
local function tier_select_incremental(opts)
  local indent = opts.indent
  local parts = {} --: { [integer]: string }
  parts[#parts + 1] = "local impl = require(\"" .. opts.pure_path .. "\") --: " .. opts.impl_type .. "\n"
  parts[#parts + 1] = "local tier = \"pure\" --: string\n"

  for i, t in ipairs(opts.tiers) do
    parts[#parts + 1] = "\n"
    local label_comment = t.label_comment
    if label_comment then
      parts[#parts + 1] = "-- " .. label_comment .. "\n"
    end
    local n = tostring(i + 1) -- tier numbering starts at 2 (pure is tier 1)
    local ok_var = "ok" .. n
    local val_suffix = t.val_suffix or "_impl"
    local raw_var = t.name .. val_suffix .. "_raw"
    local val_var = t.name .. val_suffix
    parts[#parts + 1] = "local " .. ok_var .. ", " .. raw_var
      .. " = pcall(require, \"" .. t.require_path .. "\")\n"
    parts[#parts + 1] = "local " .. val_var .. " = " .. raw_var .. " --[[: unknown]]\n"
    parts[#parts + 1] = "if " .. ok_var .. " and type(" .. val_var .. ") == \"table\" and ("
      .. val_var .. " --[[: { " .. opts.probe_field .. ": unknown, ... }]])." .. opts.probe_field .. " then\n"
    parts[#parts + 1] = indent .. "impl = " .. val_var .. " --[[:! " .. opts.impl_type .. "]]\n"
    parts[#parts + 1] = indent .. "tier = \"" .. t.name .. "\"\n"
    parts[#parts + 1] = "end\n"
  end

  return table.concat(parts)
end

-- ── type_alias_block ──────────────────────────────────────────────────────
-- Every file in the family declares one `--::` alias per exported function
-- shape, then composes them into a `<Name>Module` struct type, then narrows
-- the constructed table with `--: <Name>Module`. This production has one
-- alternative across all five files (100% reuse) — the closest thing in
-- this corpus to a pure "convention" as opposed to a "decision": nobody
-- picked among options here, everybody used the only production that
-- exists at this slot.
--
-- aliases: ordered list of { name, sig } for `--:: name = sig`
-- module_name: e.g. "CompressModule"
-- fields: ordered list of { name, type } for the struct body
--: (aliases: { [integer]: { name: string, sig: string } }, module_name: string, fields: { [integer]: { name: string, type: string, no_comma?: boolean } }) -> string
local function type_alias_block(aliases, module_name, fields)
  local parts = {} --: { [integer]: string }
  for _, a in ipairs(aliases) do
    parts[#parts + 1] = "--:: " .. a.name .. " = " .. a.sig .. "\n"
  end
  parts[#parts + 1] = "--:: " .. module_name .. " = {\n"
  -- align the ':' the way the real files do: pad names to the longest.
  local maxlen = 0
  for _, f in ipairs(fields) do
    if #f.name > maxlen then maxlen = #f.name end
  end
  for _, f in ipairs(fields) do
    local pad = string.rep(" ", maxlen - #f.name)
    -- json's real file omits the trailing comma on its last struct field
    -- (`schema`) — a copy-paste artifact, not a rule. `no_comma` reproduces
    -- it rather than "fixing" the corpus.
    local comma = f.no_comma and "" or ","
    parts[#parts + 1] = "--::     " .. f.name .. ":" .. pad .. " " .. f.type .. comma .. "\n"
  end
  parts[#parts + 1] = "--:: }\n"
  return table.concat(parts)
end

-- ── narrow_comment ────────────────────────────────────────────────────────
-- The `--: TypeName` line that narrows the table literal immediately below
-- it. Factored out from type_alias_block because its *position* relative to
-- the struct declaration is itself part of what differs between the two
-- tier-select patterns: in cast_narrow files (compress, crypto, regex) it
-- sits directly under the struct; in incremental_override files (base64,
-- json) the struct is declared early (before tier selection) but the narrow
-- line is deferred until immediately before `local M = {`, i.e. the two
-- occurrences of "the type block" and "the narrow line" are adjacent in one
-- family and split apart by the entire tier-selection block in the other.
--: (type_name: string) -> string
local function narrow_comment(type_name)
  return "--: " .. type_name .. "\n"
end

-- ── m_table_cast_narrow ───────────────────────────────────────────────────
-- Builds the final `local M = { ... }` table for the cast_narrow pattern:
-- every field is copied off `impl_t` with an individual force-cast, because
-- `impl_t` itself was already a force-cast to an all-`unknown` probe shape.
--
-- fields: ordered list of:
--   { name: string, type?: string, source?: string, comment?: string }
-- `type == nil` means "no cast" — this is the escape hatch (crypto's
-- random_bytes): two tiers have incompatible call signatures, so no
-- alternative production fits and none is minted. `comment`, if present, is
-- emitted on the line(s) above the field.
-- `source` overrides the right-hand side default of `impl_t.<name>`.
--: (indent: string, fields: { [integer]: { name: string, type?: string, source?: string, comment?: string } }) -> string
local function m_table_cast_narrow(indent, fields)
  local maxlen = 0
  for _, f in ipairs(fields) do
    if #f.name > maxlen then maxlen = #f.name end
  end
  local parts = { "local M = {\n" } --: { [integer]: string }
  for _, f in ipairs(fields) do
    local comment = f.comment
    if comment then
      for line in comment:gmatch("[^\n]+") do
        parts[#parts + 1] = indent .. "-- " .. line .. "\n"
      end
    end
    local pad = string.rep(" ", maxlen - #f.name)
    local rhs = f.source or ("impl_t." .. f.name)
    local ftype = f.type
    if ftype then
      parts[#parts + 1] = indent .. f.name .. pad .. " = " .. rhs .. pad .. " --[[:! " .. ftype .. "]],\n"
    else
      parts[#parts + 1] = indent .. f.name .. pad .. " = " .. rhs .. ",\n"
    end
  end
  parts[#parts + 1] = "}\n"
  return table.concat(parts)
end

-- ── m_table_incremental ───────────────────────────────────────────────────
-- Builds the final `local M = { ... }` table for the incremental_override
-- pattern: fields are read straight off `impl` (already typed, no cast
-- needed) plus the file-local `tier` variable and, in this family, always
-- `_impl = impl` so callers can reach the raw selected implementation.
--
-- fields: ordered list of { name: string, source: string }
--: (indent: string, fields: { [integer]: { name: string, source: string } }) -> string
local function m_table_incremental(indent, fields)
  local maxlen = 0
  for _, f in ipairs(fields) do
    if #f.name > maxlen then maxlen = #f.name end
  end
  local parts = { "local M = {\n" } --: { [integer]: string }
  for _, f in ipairs(fields) do
    local pad = string.rep(" ", maxlen - #f.name)
    parts[#parts + 1] = indent .. f.name .. pad .. " = " .. f.source .. ",\n"
  end
  parts[#parts + 1] = "}\n"
  return table.concat(parts)
end

-- ═══════════════════════════ derivations ═══════════════════════════

--:: Segment = { kind: string, text: string }

-- A terminal: free-form content specific to this file instance.
--: (text: string) -> Segment
local function raw(text)
  return { kind = "raw", text = text }
end

-- A reference to a production, already expanded. Kept as a distinct
-- constructor (rather than splicing the string in directly) so a reader of
-- a derivation can see, at a glance, which segments are terminals and which
-- are productions being invoked — the same distinction the mechanism draws
-- between terminal and rule-reference.
--: (text: string) -> Segment
local function rule(text)
  return { kind = "rule", text = text }
end

local D = {}

-- ── lib/compress/init.lua ────────────────────────────────────────────────
-- tier_select pattern: cast_narrow, variant "plain". indent: 2 spaces.
D.compress = {
  real_path = "lib/compress/init.lua",
  segments = {
    raw([[-- lib/compress/init.lua
-- Tiered zlib/gzip compression: system zlib FFI > pure Lua inflate.
-- Tier selected at load time via pcall; best available wins.
--
-- Public API:
--   M.deflate(input, opts)   -> compressed, err
--   M.inflate(input, opts)   -> decompressed, err
--   M.encode = M.deflate     (codec alias)
--   M.decode = M.inflate     (codec alias)
--   M.deflater(opts)         -> {push, finish}
--   M.inflater(opts)         -> {push, finish}
--   M._tier                  -> "system-zlib" | "pure-lua"

]]),
    rule(path_bootstrap("  ", "./?/init.lua")),
    raw("\n"),
    rule(tier_select_cast_narrow({
      indent = "  ",
      var_ok = "ok",
      var_raw = "impl_raw",
      system_path = "lib.compress.system",
      pure_path = "lib.compress.pure",
      variant = "plain",
      probe_fields = { "encode", "decode", "deflate", "inflate", "deflater", "inflater", "_tier" },
    })),
    raw("\n"),
    rule(type_alias_block(
      {
        { name = "Deflate",  sig = "(input: string, opts: { level: number | nil, format: string | nil } | nil) -> (string | nil, string | nil)" },
        { name = "Inflate",  sig = "(input: string, opts: { format: string | nil } | nil) -> (string | nil, string | nil)" },
        { name = "Deflater", sig = "(opts: { level: number | nil, format: string | nil } | nil) -> unknown" },
        { name = "Inflater", sig = "(opts: { format: string | nil } | nil) -> unknown" },
      },
      "CompressModule",
      {
        { name = "deflate",  type = "Deflate" },
        { name = "inflate",  type = "Inflate" },
        { name = "encode",   type = "Deflate" },
        { name = "decode",   type = "Inflate" },
        { name = "deflater", type = "Deflater" },
        { name = "inflater", type = "Inflater" },
        { name = "_tier",    type = "string" },
      })),
    rule(narrow_comment("CompressModule")),
    rule(m_table_cast_narrow("  ", {
      { name = "deflate",  type = "Deflate" },
      { name = "inflate",  type = "Inflate" },
      { name = "encode",   type = "Deflate" },
      { name = "decode",   type = "Inflate" },
      { name = "deflater", type = "Deflater" },
      { name = "inflater", type = "Inflater" },
      { name = "_tier",    type = "string" },
    })),
    raw("\n"),
    raw("return M\n"),
  },
}

-- ── lib/crypto/init.lua ──────────────────────────────────────────────────
-- tier_select pattern: cast_narrow, variant "plain". indent: tab.
-- Contains the one genuine escape hatch in the corpus: random_bytes has
-- incompatible call signatures across tiers, so it is left untyped with an
-- explanatory comment rather than forcing a cast or minting a union type
-- that would lie about the shape.
D.crypto = {
  real_path = "lib/crypto/init.lua",
  segments = {
    raw([[-- lib/crypto/init.lua
-- Cryptographic primitives: AES-256-GCM, ChaCha20-Poly1305, HKDF, random bytes.
-- Tier selection: system-libcrypto (FFI) > pure-lua. Best available wins.
--
-- Public API:
--   M.aes_gcm_encrypt(key, nonce, plaintext, aad)      -> string | (nil, errmsg)
--   M.aes_gcm_decrypt(key, nonce, ct_with_tag, aad)    -> string | (nil, errmsg)
--   M.chacha20_encrypt(key, nonce, plaintext, aad)      -> string | (nil, errmsg)
--   M.chacha20_decrypt(key, nonce, ct_with_tag, aad)    -> string | (nil, errmsg)
--   M.hkdf(ikm, salt, info, length)                     -> string | (nil, errmsg)
--   M.random_bytes(n)                                    -> string | (nil, errmsg)
--   M._tier -> "system-libcrypto" | "pure-lua"

]]),
    rule(path_bootstrap("\t", "./?/init.lua")),
    raw("\n"),
    rule(tier_select_cast_narrow({
      indent = "\t",
      var_ok = "ok",
      var_raw = "sys",
      system_path = "lib.crypto.system",
      pure_path = "lib.crypto.pure",
      variant = "plain",
      probe_fields = { "aes_gcm_encrypt", "aes_gcm_decrypt", "chacha20_encrypt", "chacha20_decrypt", "hkdf", "random_bytes", "_tier" },
    })),
    raw("\n"),
    rule(type_alias_block(
      {
        { name = "AeadEncrypt", sig = "(key: string, nonce: string, plaintext: string, aad: string | nil) -> (string | nil, string | nil)" },
        { name = "AeadDecrypt", sig = "(key: string, nonce: string, ct_with_tag: string, aad: string | nil) -> (string | nil, string | nil)" },
        { name = "Hkdf",        sig = "(ikm: string, salt: string | nil, info: string | nil, length: integer | nil) -> (string | nil, string | nil)" },
      },
      "CryptoModule",
      {
        { name = "aes_gcm_encrypt",  type = "AeadEncrypt" },
        { name = "aes_gcm_decrypt",  type = "AeadDecrypt" },
        { name = "chacha20_encrypt", type = "AeadEncrypt" },
        { name = "chacha20_decrypt", type = "AeadDecrypt" },
        { name = "hkdf",             type = "Hkdf" },
        { name = "random_bytes",     type = "unknown" },
        { name = "_tier",            type = "string" },
      })),
    rule(narrow_comment("CryptoModule")),
    rule(m_table_cast_narrow("\t", {
      { name = "aes_gcm_encrypt",  type = "AeadEncrypt" },
      { name = "aes_gcm_decrypt",  type = "AeadDecrypt" },
      { name = "chacha20_encrypt", type = "AeadEncrypt" },
      { name = "chacha20_decrypt", type = "AeadDecrypt" },
      { name = "hkdf",             type = "Hkdf" },
      -- The escape hatch: no `type`, so m_table_cast_narrow emits no cast —
      -- system tier takes (n), pure tier takes (random_bytes_fn, n). No
      -- alternative at the "field cast" slot fits both, and none is minted.
      { name = "random_bytes", comment = "random_bytes intentionally untyped: system tier takes (n), pure tier\ntakes (random_bytes_fn, n). Callers should branch on _tier or use the\nimplementation directly." },
      { name = "_tier", type = "string" },
    })),
    raw("\n"),
    raw("return M\n"),
  },
}

-- ── lib/regex/init.lua ───────────────────────────────────────────────────
-- tier_select pattern: cast_narrow, variant "ternary_cache_clear" — the
-- OTHER established sub-variant of the ok-check, reusing the same slot
-- compress/crypto fill with "plain". indent: tab (same as crypto).
D.regex = {
  real_path = "lib/regex/init.lua",
  segments = {
    raw([[-- lib/regex/init.lua
-- Regex library with tier selection: PCRE2 FFI (system) > pure Lua.
--
-- Public API:
--   M.compile(pattern, flags?) -> regex, err
--   M.match(pattern, subject, init?) -> captures | nil
--   M.find(pattern, subject, init?) -> start, end_ | nil
--   M.gmatch(pattern, subject) -> iterator
--   M.gsub(pattern, subject, replacement, n?) -> result, count
--   M.split(pattern, subject) -> array
--   M._tier -> "system-pcre2" | "pure-lua"

]]),
    rule(path_bootstrap("\t", "./?/init.lua")),
    raw("\n"),
    rule(tier_select_cast_narrow({
      indent = "\t",
      var_ok = "ok",
      var_raw = "mod",
      system_path = "lib.regex.system",
      pure_path = "lib.regex.pure",
      variant = "ternary_cache_clear",
      system_label = "PCRE2 FFI",
      probe_fields = { "compile", "match", "find", "gmatch", "gsub", "split", "_tier" },
    })),
    raw("\n"),
    rule(type_alias_block(
      {
        { name = "RegexCompile", sig = "(pattern: string, flags: string | nil) -> (unknown, string | nil)" },
        { name = "RegexMatch",   sig = "(pattern: string, subject: string, init: integer | nil) -> unknown" },
        { name = "RegexFind",    sig = "(pattern: string, subject: string, init: integer | nil) -> unknown" },
        { name = "RegexGmatch",  sig = "(pattern: string, subject: string) -> unknown" },
        { name = "RegexGsub",    sig = "(pattern: string, subject: string, replacement: unknown, n: integer | nil) -> unknown" },
        { name = "RegexSplit",   sig = "(pattern: string, subject: string) -> unknown" },
      },
      "RegexModule",
      {
        { name = "compile", type = "RegexCompile" },
        { name = "match",   type = "RegexMatch" },
        { name = "find",    type = "RegexFind" },
        { name = "gmatch",  type = "RegexGmatch" },
        { name = "gsub",    type = "RegexGsub" },
        { name = "split",   type = "RegexSplit" },
        { name = "_tier",   type = "string" },
      })),
    rule(narrow_comment("RegexModule")),
    rule(m_table_cast_narrow("\t", {
      { name = "compile", type = "RegexCompile" },
      { name = "match",   type = "RegexMatch" },
      { name = "find",    type = "RegexFind" },
      { name = "gmatch",  type = "RegexGmatch" },
      { name = "gsub",    type = "RegexGsub" },
      { name = "split",   type = "RegexSplit" },
      { name = "_tier",   type = "string" },
    })),
    raw("\n"),
    raw("return M\n"),
  },
}

-- ── lib/encode/base64/init.lua ───────────────────────────────────────────
-- tier_select pattern: incremental_override. indent: 4 spaces.
-- find_string anomaly: "?/init.lua" instead of "./?/init.lua" (see
-- productions.lua path_bootstrap comment) — preserved, not "fixed".
D.base64 = {
  real_path = "lib/encode/base64/init.lua",
  segments = {
    raw([[-- lib/encode/base64/init.lua
-- Base64 encoding and decoding (RFC 4648 §4 standard, §5 URL-safe).
-- Three-tier implementation; best available selected at load time.
--
-- Tier selection:
--   simd  — SIMD via pre-built shared library (stub; always falls through)
--   ffi   — LuaJIT FFI scalar (zero-copy byte access via uint8_t*)
--   pure  — pure Lua (works on PUC-Rio Lua 5.2+ and LuaJIT)
--
-- Public API:
--   M.encode(str, opts)   → string
--   M.decode(b64, opts)   → string | (nil, errmsg)
--   M._tier               → "ffi" | "pure"
--   M._impl               → the selected implementation table

]]),
    rule(path_bootstrap("    ", "?/init.lua")),
    raw("\n-- ── Public module ──────────────────────────────────────────────────────────────\n\n"),
    rule(type_alias_block(
      {
        { name = "Base64Encode", sig = "(str: string, opts: { url: boolean | nil, pad: boolean | nil } | nil) -> string" },
        { name = "Base64Decode", sig = "(b64: string, opts: { url: boolean | nil } | nil) -> (string | nil, string | nil)" },
      },
      "Base64Impl",
      {
        { name = "encode", type = "Base64Encode" },
        { name = "decode", type = "Base64Decode" },
      })),
    rule(type_alias_block({}, "Base64Module", {
      { name = "encode", type = "Base64Encode" },
      { name = "decode", type = "Base64Decode" },
      { name = "_tier",  type = "string" },
      { name = "_impl",  type = "Base64Impl" },
    })),
    raw("\n" .. [[
-- ── Tier selection ─────────────────────────────────────────────────────────────
-- Pure-Lua tier is the baseline (always available, statically typed). Optional
-- tiers (ffi/simd) come back through `pcall(require, ...)` which loses the
-- module's static type; we runtime-narrow and cast at the pcall boundary.

]]),
    rule(tier_select_incremental({
      indent = "    ",
      pure_path = "lib.encode.base64.pure",
      impl_type = "Base64Impl",
      probe_field = "encode",
      tiers = {
        { name = "ffi",  require_path = "lib.encode.base64.ffi",  label_comment = "Try Tier 2: FFI scalar." },
        { name = "simd", require_path = "lib.encode.base64.simd", label_comment = "Try Tier 3: SIMD (stub — always returns false).", val_suffix = "_result" },
      },
    })),
    raw("\n"),
    rule(narrow_comment("Base64Module")),
    rule(m_table_incremental("    ", {
      { name = "encode", source = "impl.encode" },
      { name = "decode", source = "impl.decode" },
      { name = "_tier",  source = "tier" },
      { name = "_impl",  source = "impl" },
    })),
    raw("\n"),
    raw("return M\n"),
  },
}

-- ── lib/format/json/init.lua ─────────────────────────────────────────────
-- tier_select pattern: incremental_override, same shape as base64 (2
-- optional tiers, same val_suffix convention: "ffi" tier binds "_impl",
-- "simd" tier binds "_result"). indent: 4 spaces, standard find_string.
-- Preserves a real anomaly: the "── Public module ──" comment is
-- duplicated verbatim in the source (a likely copy-paste artifact) and the
-- final `schema` field in the JsonModule type has no trailing comma. Both
-- are reproduced as observed, not corrected.
D.json = {
  real_path = "lib/format/json/init.lua",
  segments = {
    raw([[-- lib/format/json/init.lua
-- Crescent JSON library — three-tier implementation.
--
-- Tier selection (best available at load time):
--   simd  — libcrescentjson (simdjson C shim); requires pre-built .so/.dylib
--   ffi   — LuaJIT FFI scalar; requires LuaJIT
--   pure  — pure Lua; works on PUC-Rio Lua 5.2+ and LuaJIT
--
-- Public API:
--   json.encode(value)       → string | (nil, errmsg)
--   json.decode(str)         → value  | (nil, errmsg)
--   json.null                — sentinel for JSON null
--   json.value_to_json       — alias for the raw encoder (throws on error)
--   json.json_to_value       — alias for the raw decoder (throws on error)
--   json._encode_raw         — alias for the raw encoder (throws on error)
--   json._decode_raw         — alias for the raw decoder (throws on error)
--   json._tier               — "simd" | "ffi" | "pure"
--   json._impl               — the selected implementation table

]]),
    rule(path_bootstrap("    ", "./?/init.lua")),
    raw("\n-- ── Public module ─────────────────────────────────────────────────────────────\n\n-- ── Public module ─────────────────────────────────────────────────────────────\n\n"),
    rule(type_alias_block(
      {
        { name = "JsonEncode",    sig = "(val: unknown, null_sentinel: unknown) -> (string | nil, string | nil)" },
        { name = "JsonDecode",    sig = "(s: string, null_sentinel: unknown) -> (unknown, string | nil)" },
        { name = "JsonEncodeRaw", sig = "(val: unknown, null_sentinel: unknown) -> string" },
        { name = "JsonDecodeRaw", sig = "(s: string, null_sentinel: unknown) -> unknown" },
      },
      "JsonImpl",
      {
        { name = "null",          type = "{}" },
        { name = "encode",        type = "JsonEncode" },
        { name = "decode",        type = "JsonDecode" },
        { name = "_encode_raw",   type = "JsonEncodeRaw" },
        { name = "_decode_raw",   type = "JsonDecodeRaw" },
        { name = "value_to_json", type = "JsonEncodeRaw" },
        { name = "json_to_value", type = "JsonDecodeRaw" },
      })),
    rule(type_alias_block({}, "JsonModule", {
      { name = "null",          type = "{}" },
      { name = "encode",        type = "JsonEncode" },
      { name = "decode",        type = "JsonDecode" },
      { name = "_encode_raw",   type = "JsonEncodeRaw" },
      { name = "_decode_raw",   type = "JsonDecodeRaw" },
      { name = "value_to_json", type = "JsonEncodeRaw" },
      { name = "json_to_value", type = "JsonDecodeRaw" },
      { name = "_tier",         type = "string" },
      { name = "_impl",         type = "JsonImpl" },
      { name = "schema",        type = "unknown", no_comma = true },
    })),
    raw("\n" .. [[
-- ── Tier selection ────────────────────────────────────────────────────────────
-- The pure-Lua tier is the baseline (always available, statically typed and
-- imported directly). Optional tiers (simd/ffi) come back through
-- `pcall(require, ...)`, which loses the module's static type; we narrow at
-- runtime and treat the result as a JsonImpl. The pcall boundary is the one
-- legitimate cast site — every consumer downstream sees the typed JsonImpl.

]]),
    rule(tier_select_incremental({
      indent = "    ",
      pure_path = "lib.format.json.pure",
      impl_type = "JsonImpl",
      probe_field = "encode",
      tiers = {
        { name = "ffi",  require_path = "lib.format.json.ffi",  label_comment = "Try Tier 2: FFI scalar." },
        { name = "simd", require_path = "lib.format.json.simd", label_comment = "Try Tier 3: simdjson via C shim.", val_suffix = "_result" },
      },
    })),
    raw("\n"),
    rule(narrow_comment("JsonModule")),
    rule(m_table_incremental("    ", {
      { name = "null",          source = "impl.null" },
      { name = "encode",        source = "impl.encode" },
      { name = "decode",        source = "impl.decode" },
      { name = "_encode_raw",   source = "impl._encode_raw" },
      { name = "_decode_raw",   source = "impl._decode_raw" },
      { name = "value_to_json", source = "impl._encode_raw" },
      { name = "json_to_value", source = "impl._decode_raw" },
      { name = "_tier",         source = "tier" },
      { name = "_impl",         source = "impl" },
      { name = "schema",        source = 'require("lib.format.json.schema")' },
    })),
    raw("\n"),
    raw("return M\n"),
  },
}

return D
