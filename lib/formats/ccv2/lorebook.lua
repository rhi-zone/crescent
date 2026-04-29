-- lib/formats/ccv2/lorebook.lua
-- Lorebook parser and trigger engine for SillyTavern / CCv2 character card lorebooks.
-- Pure Lua, no FFI.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local aho_corasick = require("lib.aho_corasick")

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

--: number
M.POS_BEFORE    = 0
--: number
M.POS_AFTER     = 1
--: number
M.POS_AN_TOP    = 2
--: number
M.POS_AN_BOTTOM = 3
--: number
M.POS_AT_DEPTH  = 4
--: number
M.POS_EM_TOP    = 5
--: number
M.POS_EM_BOTTOM = 6

--: number
M.LOGIC_AND_ANY = 0
--: number
M.LOGIC_NOT_ALL = 1
--: number
M.LOGIC_NOT_ANY = 2
--: number
M.LOGIC_AND_ALL = 3

--: number
M.ROLE_SYSTEM    = 0
--: number
M.ROLE_USER      = 1
--: number
M.ROLE_ASSISTANT = 2

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local lower = string.lower
local find = string.find
local sub = string.sub
local sort = table.sort

local ccv2_position_to_st = {
  before_char = 0,
  after_char  = 1,
}

local st_position_to_ccv2 = {
  [0] = "before_char",
  [1] = "after_char",
}

local uid_counter = 0

local function gen_uid()
  uid_counter = uid_counter + 1
  return "lorebook_" .. uid_counter
end

-- ---------------------------------------------------------------------------
-- Entry normalization
-- ---------------------------------------------------------------------------

--: (table) -> table
function M.normalize(entry)
  local e = {}
  e.uid              = entry.uid or gen_uid()
  e.comment          = entry.comment or ""
  e.key              = entry.key or {}
  e.keysecondary     = entry.keysecondary or {}
  e.selectiveLogic   = entry.selectiveLogic or 0
  e.content          = entry.content or ""
  if entry.enabled == nil then e.enabled = true else e.enabled = entry.enabled end
  if entry.constant == nil then e.constant = false else e.constant = entry.constant end
  e.order            = entry.order or 0
  e.position         = entry.position or 0
  e.depth            = entry.depth or 0
  e.role             = entry.role or 0
  if entry.caseSensitive == nil then e.caseSensitive = false else e.caseSensitive = entry.caseSensitive end
  if entry.matchWholeWords == nil then e.matchWholeWords = false else e.matchWholeWords = entry.matchWholeWords end
  e.probability      = entry.probability or 1.0
  if entry.sticky == nil then e.sticky = false else e.sticky = entry.sticky end
  e.cooldown         = entry.cooldown or 0
  e.delay            = entry.delay or 0
  if entry.ignoreBudget == nil then e.ignoreBudget = false else e.ignoreBudget = entry.ignoreBudget end
  if entry.excludeRecursion == nil then e.excludeRecursion = false else e.excludeRecursion = entry.excludeRecursion end
  if entry.preventRecursion == nil then e.preventRecursion = false else e.preventRecursion = entry.preventRecursion end
  e.group            = entry.group or ""
  e.groupWeight      = entry.groupWeight or 1
  e.displayIndex     = entry.displayIndex or 0
  return e
end

-- ---------------------------------------------------------------------------
-- CCv2 <-> ST conversion
-- ---------------------------------------------------------------------------

--: (table) -> table
function M.from_ccv2(book)
  local out = {}
  local entries = book and book.entries or {}
  for i, ce in ipairs(entries) do
    local pos_str = ce.position or "before_char"
    local logic = 0
    if ce.selective then
      logic = 0 -- AND_ANY when selective is true and no further info
    end
    local e = {
      key            = ce.keys or {},
      keysecondary   = ce.secondary_keys or {},
      selectiveLogic = ce.selective and 0 or 0,
      content        = ce.content or "",
      enabled        = ce.enabled == nil and true or ce.enabled,
      constant       = ce.constant == nil and false or ce.constant,
      order          = ce.insertion_order or 0,
      position       = ccv2_position_to_st[pos_str] or 0,
      caseSensitive  = ce.case_sensitive == nil and false or ce.case_sensitive,
      priority       = ce.priority,
    }
    e = M.normalize(e)
    -- Preserve priority from CCv2 if present (not a standard ST field but useful)
    if ce.priority then e.priority = ce.priority end
    out[#out + 1] = e
  end
  return out
end

--: (table) -> table
function M.to_ccv2(entries)
  local book = { entries = {} }
  for _, e in ipairs(entries) do
    local ce = {
      keys            = e.key or {},
      content         = e.content or "",
      enabled         = e.enabled ~= false,
      insertion_order = e.order or 0,
      selective       = e.keysecondary and #e.keysecondary > 0,
      secondary_keys  = e.keysecondary or {},
      constant        = e.constant == true,
      position        = st_position_to_ccv2[e.position] or "before_char",
      case_sensitive  = e.caseSensitive == true,
      priority        = e.order or 0,
    }
    book.entries[#book.entries + 1] = ce
  end
  return book
end

-- ---------------------------------------------------------------------------
-- Trigger scanning internals
-- ---------------------------------------------------------------------------

-- Check if a key string is a regex pattern: /pattern/ or /pattern/i
local function parse_regex_key(key)
  if sub(key, 1, 1) ~= "/" then return nil, nil end
  -- Check for /pattern/i
  if sub(key, -2) == "/i" then
    return sub(key, 2, -3), true
  end
  -- Check for /pattern/
  if sub(key, -1) == "/" and #key > 1 then
    return sub(key, 2, -2), false
  end
  return nil, nil
end

-- Test whether a single key matches the given text.
-- text_lower is the lowercased version of text (precomputed).
-- Returns true if key matches.
local function key_matches(key, text, text_lower, case_sensitive)
  local pattern, ignore_case = parse_regex_key(key)
  if pattern then
    -- Regex key: use string.find
    local search_text = (ignore_case or not case_sensitive) and text_lower or text
    if ignore_case and case_sensitive then
      -- /pattern/i overrides case_sensitive
      search_text = text_lower
      pattern = lower(pattern)
    elseif not case_sensitive then
      pattern = lower(pattern)
    end
    local ok, start = pcall(find, search_text, pattern)
    return ok and start ~= nil
  end
  -- Plain key
  if case_sensitive then
    return find(text, key, 1, true) ~= nil
  else
    return find(text_lower, lower(key), 1, true) ~= nil
  end
end

-- Check secondary keys against selectiveLogic.
-- Returns true if the entry should trigger.
local function check_secondary(entry, text, text_lower)
  local secondary = entry.keysecondary
  if not secondary or #secondary == 0 then
    return true -- no secondary keys: primary match is sufficient
  end

  local logic = entry.selectiveLogic or 0
  local cs = entry.caseSensitive

  if logic == 0 then
    -- AND_ANY: trigger if ANY secondary key matches
    for _, sk in ipairs(secondary) do
      if key_matches(sk, text, text_lower, cs) then return true end
    end
    return false
  elseif logic == 1 then
    -- NOT_ALL: trigger UNLESS ALL secondary keys match
    for _, sk in ipairs(secondary) do
      if not key_matches(sk, text, text_lower, cs) then return true end
    end
    return false
  elseif logic == 2 then
    -- NOT_ANY: trigger UNLESS ANY secondary key matches
    for _, sk in ipairs(secondary) do
      if key_matches(sk, text, text_lower, cs) then return false end
    end
    return true
  elseif logic == 3 then
    -- AND_ALL: trigger only if ALL secondary keys match
    for _, sk in ipairs(secondary) do
      if not key_matches(sk, text, text_lower, cs) then return false end
    end
    return true
  end

  return true
end

-- ---------------------------------------------------------------------------
-- Public scan API
-- ---------------------------------------------------------------------------

--: (table, string, (table | nil)) -> table
function M.scan(entries, text, opts)
  opts = opts or {}
  local rng = opts.rng or math.random
  local text_lower = lower(text)

  -- Phase 1: classify keys into plain vs regex, group by case sensitivity
  -- We build AC automatons per case-sensitivity group for plain keys.
  -- ac_ci: case-insensitive plain keys
  -- ac_cs: case-sensitive plain keys
  -- Each maps pattern -> list of {entry_index, key_index}

  -- entry_index -> true if any primary key matched
  local primary_matched = {}

  -- Regex keys: check individually
  for i, entry in ipairs(entries) do
    if entry.enabled and not entry.constant then
      local cs = entry.caseSensitive
      for _, key in ipairs(entry.key or {}) do
        local pattern = parse_regex_key(key)
        if pattern then
          if key_matches(key, text, text_lower, cs) then
            primary_matched[i] = true
          end
        end
      end
    end
  end

  -- Plain keys: collect and build AC automatons
  -- Group: case-insensitive
  local ci_patterns = {}
  local ci_map = {} -- pattern_string -> list of entry indices
  -- Group: case-sensitive
  local cs_patterns = {}
  local cs_map = {}

  for i, entry in ipairs(entries) do
    if entry.enabled and not entry.constant then
      local cs = entry.caseSensitive
      for _, key in ipairs(entry.key or {}) do
        if not parse_regex_key(key) then
          if cs then
            if not cs_map[key] then
              cs_map[key] = {}
              cs_patterns[#cs_patterns + 1] = key
            end
            local list = cs_map[key]
            list[#list + 1] = i
          else
            local lk = lower(key)
            if not ci_map[lk] then
              ci_map[lk] = {}
              ci_patterns[#ci_patterns + 1] = lk
            end
            local list = ci_map[lk]
            list[#list + 1] = i
          end
        end
      end
    end
  end

  -- Run AC for case-insensitive patterns
  if #ci_patterns > 0 then
    local auto, err = aho_corasick.new(ci_patterns)
    if auto then
      local results = auto:search(text_lower)
      for _, m in ipairs(results) do
        local pat = m[2]
        local indices = ci_map[pat]
        if indices then
          for _, idx in ipairs(indices) do
            primary_matched[idx] = true
          end
        end
      end
    end
  end

  -- Run AC for case-sensitive patterns
  if #cs_patterns > 0 then
    local auto, err = aho_corasick.new(cs_patterns)
    if auto then
      local results = auto:search(text)
      for _, m in ipairs(results) do
        local pat = m[2]
        local indices = cs_map[pat]
        if indices then
          for _, idx in ipairs(indices) do
            primary_matched[idx] = true
          end
        end
      end
    end
  end

  -- Phase 2: check secondary keys and probability
  local triggered = {}
  for i, entry in ipairs(entries) do
    if primary_matched[i] then
      if check_secondary(entry, text, text_lower) then
        -- Probability check
        if (entry.probability or 1.0) >= 1.0 or rng() < entry.probability then
          triggered[#triggered + 1] = i
        end
      end
    end
  end

  -- Sort by order descending
  sort(triggered, function(a, b)
    return (entries[a].order or 0) > (entries[b].order or 0)
  end)

  return triggered
end

--: (table, string, (table | nil)) -> table
function M.get_triggered(entries, text, opts)
  local indices = M.scan(entries, text, opts)
  local out = {}
  for _, i in ipairs(indices) do
    out[#out + 1] = entries[i]
  end
  return out
end

return M
