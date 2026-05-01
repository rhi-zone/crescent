-- lib/regexp/init.lua
-- Thompson NFA-based regular expression engine with capture groups.
-- _tier = "pure"
--
-- Supported syntax:
--   .            any character (except \n)
--   *  +  ?      greedy quantifiers
--   {n} {n,} {n,m}  counted quantifiers
--   [abc] [^abc] [a-z]  character classes
--   (...)        capture group
--   (?:...)      non-capturing group
--   ^  $         anchors
--   |            alternation
--   \d \w \s     digit / word / space
--   \D \W \S     negated shorthands
--   \n \t \r     escape sequences
--
-- Backreferences are not supported (NFA cannot do them efficiently).
--
-- Public API:
--   M.compile(pattern) -> re, err
--   M.test(pattern_or_re, str) -> bool
--   M.find(pattern_or_re, str, init) -> start, stop, captures...
--   M.match(pattern_or_re, str) -> stop, captures...
--   M.find_all(pattern_or_re, str) -> {{start,stop,...},...}
--   M.sub(pattern_or_re, str, repl, n) -> result, count
--   M.gsub(pattern_or_re, str, repl) -> result, count
--   M.split(pattern_or_re, str, max_splits) -> {parts,...}
--
-- Compiled object methods mirror the module-level API.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ── Character predicates ──────────────────────────────────────────────────────

local function is_digit(b) return b >= 48 and b <= 57 end
local function is_word(b)
  return (b >= 48 and b <= 57) or (b >= 65 and b <= 90)
      or (b >= 97 and b <= 122) or b == 95
end
local function is_space(b)
  return b == 32 or b == 9 or b == 10 or b == 13 or b == 12 or b == 11
end

-- ── NFA instruction set ───────────────────────────────────────────────────────
--
-- Instructions are tables stored in a flat array (prog).
-- Opcodes:
--   CHAR  c           match single byte c
--   CLASS ranges neg  match character class
--   ANY               match any byte (not \n)
--   SPLIT x y         fork: add both x and y to next states
--   JUMP  x           unconditional goto x
--   SAVE  n           save current position into captures slot n
--   MATCH             accepting state
--   ANCHOR_START      zero-width assert pos==1
--   ANCHOR_END        zero-width assert pos==end+1

--:: Instr = { op: integer, ... }
--:: Insns = { [integer]: Instr }
--:: Outs = { [integer]: { [integer]: unknown } }
--:: Frag = { start: integer, outs: Outs }

local OP_CHAR         = 1
local OP_CLASS        = 2
local OP_ANY          = 3
local OP_SPLIT        = 4
local OP_JUMP         = 5
local OP_SAVE         = 6
local OP_MATCH        = 7
local OP_ANCHOR_START = 8
local OP_ANCHOR_END   = 9

-- ── Parser ────────────────────────────────────────────────────────────────────
--
-- Returns a list of NFA instructions plus ngroups count.

local function parse_error(msg) return nil, "regexp: " .. msg end

-- Returns a "class predicate" table: {ranges={{lo,hi},...}, shortcuts={fn,neg,...}, neg=bool}
--: (string, integer) -> (Cls | nil, integer | string | nil)
local function parse_class(pat, pos)
  local neg = false
  if pos <= #pat and pat:byte(pos) == 94 then -- ^
    neg = true; pos = pos + 1
  end
  local ranges = {}
  local shortcuts = {}
  local first = true
  while pos <= #pat do
    local b = pat:byte(pos)
    if b == 93 and not first then -- ]
      return { ranges = ranges, shortcuts = shortcuts, neg = neg }, pos + 1
    end
    first = false
    if b == 92 then -- backslash
      pos = pos + 1
      if pos > #pat then return parse_error("unexpected end in character class") end
      local esc = pat:byte(pos)
      local fn, fneg
      if     esc == 100 then fn = is_digit; fneg = false  -- \d
      elseif esc == 68  then fn = is_digit; fneg = true   -- \D
      elseif esc == 119 then fn = is_word;  fneg = false  -- \w
      elseif esc == 87  then fn = is_word;  fneg = true   -- \W
      elseif esc == 115 then fn = is_space; fneg = false  -- \s
      elseif esc == 83  then fn = is_space; fneg = true   -- \S
      else
        -- literal: check for range a-z
        local lo = esc
        pos = pos + 1
        if pos + 1 <= #pat and pat:byte(pos) == 45 then -- -
          local hi_b = pat:byte(pos + 1)
          if hi_b ~= 93 then  -- not end of class
            ranges[#ranges + 1] = { lo, hi_b }
            pos = pos + 2
          else
            ranges[#ranges + 1] = { lo, lo }
          end
        else
          ranges[#ranges + 1] = { lo, lo }
        end
      end
      if fn then
        shortcuts[#shortcuts + 1] = { fn = fn, neg = fneg }
        pos = pos + 1
      end
    else
      -- normal char: check for range
      local lo = b
      pos = pos + 1
      if pos + 1 <= #pat and pat:byte(pos) == 45 and pat:byte(pos + 1) ~= 93 then
        local hi_b = pat:byte(pos + 1)
        ranges[#ranges + 1] = { lo, hi_b }
        pos = pos + 2
      else
        ranges[#ranges + 1] = { lo, lo }
      end
    end
  end
  return parse_error("unterminated character class")
end

--:: ClsRange = { integer, integer }
--:: ClsShortcut = { fn: (integer) -> boolean, neg: boolean }
--:: Cls = { ranges: { [integer]: ClsRange }, shortcuts: { [integer]: ClsShortcut }, neg: boolean }
--: (Cls, integer) -> boolean
local function class_matches(cls, b)
  local hit = false
  for i = 1, #cls.ranges do
    local r = cls.ranges[i]
    if b >= r[1] and b <= r[2] then hit = true; break end
  end
  if not hit then
    for i = 1, #cls.shortcuts do
      local sc = cls.shortcuts[i]
      local res = sc.fn(b)
      if sc.neg then res = not res end
      if res then hit = true; break end
    end
  end
  if cls.neg then return not hit end
  return hit
end

-- Returns (prog, err) where prog has fields:
--   prog.insns  = flat array of instruction tables
--   prog.ngroups = number of capture groups
-- Instruction table fields: op, c, cls, x, y, n

local parse_alt  -- forward declaration

-- emit helpers: append instruction and return its index
--: (Insns, Instr) -> integer
local function emit(insns, instr)
  insns[#insns + 1] = instr
  return #insns
end

-- "patch" a jump/split target that was left as 0
--: (Insns, integer, string, integer) -> nil
local function patch(insns, idx, field, target)
  insns[idx][field] = target
end

-- compile alternation alternative into insns, returns (first_pc, last_pc_plus1)
-- We build the NFA fragment-style: each fragment = (start_pc, out_list)
-- out_list = array of {idx, field} that need to be patched to the next fragment

-- Fragment approach (textbook Thompson):
--   fragment = { start, outs } where outs = list of {pc, field} needing patch

--: (integer, Outs) -> Frag
local function frag(start, outs) return { start = start, outs = outs } end

--: (Insns, Outs, integer) -> nil
local function patch_outs(insns, outs, target)
  for i = 1, #outs do
    insns[outs[i][1]][outs[i][2]] = target
  end
end

--: (Outs, Outs) -> Outs
local function concat_outs(a, b)
  local r = {}
  for i = 1, #a do r[#r + 1] = a[i] end
  for i = 1, #b do r[#r + 1] = b[i] end
  return r
end

-- Returns frag or (nil, errmsg)
local parse_concat -- forward declaration

parse_alt = function(insns, pat, pos, gc)
  local f, err = parse_concat(insns, pat, pos, gc)
  if not f then return nil, err end
  -- Check for |
  if pos[1] <= #pat and pat:byte(pos[1]) == 124 then
    local alts = { f }
    while pos[1] <= #pat and pat:byte(pos[1]) == 124 do
      pos[1] = pos[1] + 1
      local alt, e = parse_concat(insns, pat, pos, gc)
      if not alt then return nil, e end
      alts[#alts + 1] = alt
    end
    -- Build a chain of SPLIT instructions
    -- split -> alts[1].start, next_split
    -- split -> alts[2].start, next_split
    -- ...
    -- last alt has no split
    local all_outs = {}
    -- We need to wire alts together with SPLITs
    -- Walk backwards: last alt is already a frag, chain splits before it
    local combined = alts[#alts]
    for i = #alts - 1, 1, -1 do
      local split_pc = emit(insns, { op = OP_SPLIT, x = alts[i].start, y = combined.start })
      combined = frag(split_pc, concat_outs(alts[i].outs, combined.outs))
    end
    return combined
  end
  return f
end

-- Parse a single "atom" (no quantifier). Returns frag or (nil, errmsg) or nil for end of input.
local function parse_atom(insns, pat, pos, gc)
  if pos[1] > #pat then return nil end
  local b = pat:byte(pos[1])
  -- ) terminates group, | terminates alternative — caller handles
  if b == 41 or b == 124 then return nil end

  if b == 40 then -- (
    pos[1] = pos[1] + 1
    local capture = true
    local group_idx = 0
    if pos[1] + 1 <= #pat and pat:byte(pos[1]) == 63 and pat:byte(pos[1] + 1) == 58 then
      -- (?:...) non-capturing
      capture = false
      pos[1] = pos[1] + 2
    end
    if capture then
      gc[1] = gc[1] + 1
      group_idx = gc[1]
    end
    local open_pc
    if capture then
      open_pc = emit(insns, { op = OP_SAVE, n = (group_idx - 1) * 2 })
    end
    local inner, e = parse_alt(insns, pat, pos, gc)
    if not inner then return nil, e end
    if pos[1] > #pat or pat:byte(pos[1]) ~= 41 then
      return parse_error("unterminated group")
    end
    pos[1] = pos[1] + 1  -- consume )
    if capture then
      local close_pc = emit(insns, { op = OP_SAVE, n = (group_idx - 1) * 2 + 1 })
      -- open_save.x = inner.start (so simulation follows x, not pc+1)
      insns[open_pc].x = inner.start
      -- patch inner's outs to close_save (so alternatives converge at close_save)
      patch_outs(insns, inner.outs, close_pc)
      -- close_save.x is the out of the group frag (patched by caller to next instruction)
      return frag(open_pc, { { close_pc, "x" } })
    else
      return inner
    end
  elseif b == 94 then -- ^
    pos[1] = pos[1] + 1
    local pc = emit(insns, { op = OP_ANCHOR_START })
    return frag(pc, { { pc, "x" } })
  elseif b == 36 then -- $
    pos[1] = pos[1] + 1
    local pc = emit(insns, { op = OP_ANCHOR_END })
    return frag(pc, { { pc, "x" } })
  elseif b == 46 then -- .
    pos[1] = pos[1] + 1
    local pc = emit(insns, { op = OP_ANY })
    return frag(pc, { { pc, "x" } })
  elseif b == 91 then -- [
    pos[1] = pos[1] + 1
    local cls, e = parse_class(pat, pos[1])
    if not cls then return nil, e end
    -- parse_class returns (cls, new_pos) on success, (nil, err) on failure
    -- But we hijacked the return: parse_class returns cls table + new pos, OR nil+errmsg
    -- Wait — parse_class returns (table, pos) or (nil, errmsg). Let me re-check.
    -- parse_class(pat, pos) returns {ranges,...}, new_pos   OR  nil, errmsg
    -- Here e is actually new_pos when cls is non-nil. Let me fix:
    pos[1] = e  -- e = new_pos returned from parse_class
    local pc = emit(insns, { op = OP_CLASS, cls = cls })
    return frag(pc, { { pc, "x" } })
  elseif b == 92 then -- backslash
    pos[1] = pos[1] + 1
    if pos[1] > #pat then return parse_error("unexpected end of pattern") end
    local esc = pat:byte(pos[1])
    pos[1] = pos[1] + 1
    local instr
    if esc == 100 then -- \d
      instr = { op = OP_CLASS, cls = { ranges = {}, shortcuts = {{ fn=is_digit, neg=false }}, neg = false } }
    elseif esc == 68 then -- \D
      instr = { op = OP_CLASS, cls = { ranges = {}, shortcuts = {{ fn=is_digit, neg=true }}, neg = false } }
    elseif esc == 119 then -- \w
      instr = { op = OP_CLASS, cls = { ranges = {}, shortcuts = {{ fn=is_word, neg=false }}, neg = false } }
    elseif esc == 87 then -- \W
      instr = { op = OP_CLASS, cls = { ranges = {}, shortcuts = {{ fn=is_word, neg=true }}, neg = false } }
    elseif esc == 115 then -- \s
      instr = { op = OP_CLASS, cls = { ranges = {}, shortcuts = {{ fn=is_space, neg=false }}, neg = false } }
    elseif esc == 83 then -- \S
      instr = { op = OP_CLASS, cls = { ranges = {}, shortcuts = {{ fn=is_space, neg=true }}, neg = false } }
    elseif esc == 110 then instr = { op = OP_CHAR, c = 10 }  -- \n
    elseif esc == 116 then instr = { op = OP_CHAR, c = 9 }   -- \t
    elseif esc == 114 then instr = { op = OP_CHAR, c = 13 }  -- \r
    else instr = { op = OP_CHAR, c = esc }
    end
    local pc = emit(insns, instr)
    return frag(pc, { { pc, "x" } })
  else
    pos[1] = pos[1] + 1
    local pc = emit(insns, { op = OP_CHAR, c = b })
    return frag(pc, { { pc, "x" } })
  end
end

-- Parse a quantifier {n}, {n,}, {n,m} at pos, returns (min, max, new_pos) or nil
local function parse_brace_quant(pat, pos)
  -- pos points to '{'
  if pos > #pat then return nil end
  local i = pos + 1
  -- parse n
  local n_start = i
  while i <= #pat and pat:byte(i) >= 48 and pat:byte(i) <= 57 do i = i + 1 end
  if i == n_start then return nil end  -- no digits
  local n = tonumber(pat:sub(n_start, i - 1))
  if i > #pat then return nil end
  local b = pat:byte(i)
  if b == 125 then -- {n}
    return n, n, i + 1
  elseif b == 44 then -- ,
    i = i + 1
    if i <= #pat and pat:byte(i) == 125 then -- {n,}
      return n, math.huge, i + 1
    end
    local m_start = i
    while i <= #pat and pat:byte(i) >= 48 and pat:byte(i) <= 57 do i = i + 1 end
    if i == m_start then return nil end
    local m = tonumber(pat:sub(m_start, i - 1))
    if i > #pat or pat:byte(i) ~= 125 then return nil end
    if m < n then return nil end
    return n, m, i + 1
  end
  return nil
end

-- Build NFA fragment for "f repeated min..max times"
-- Uses existing insns array, returns new frag
local function build_repeat(insns, atom_frag, min, max, orig_pat, gc)
  -- We can't re-parse; we need to clone the atom instructions.
  -- Store atom insns as a sub-array and emit clones.
  -- Actually, we need the atom frag's instruction range.
  -- atom_frag.start .. #insns (after atom was emitted, before this call)
  -- But parse_atom leaves insns appended. We'll need to clone those instructions.
  -- This is complex. Instead, use a different strategy:
  -- We build repetition by emitting the fragment multiple times via cloning.
  return atom_frag, nil  -- placeholder, see build_quant
end

-- Clone instructions from insns[from..to] into insns, adjusting internal jumps
-- by offset = #insns_new - from + 1.  Returns new frag start.
--: (Insns, integer, integer) -> integer
local function clone_frag(insns, from, to)
  local offset = #insns - from + 1
  local new_start = #insns + 1
  for i = from, to do
    local src = insns[i]
    local dst = { op = src.op }
    if src.op == OP_CHAR then dst.c = src.c
    elseif src.op == OP_CLASS then dst.cls = src.cls
    elseif src.op == OP_SPLIT then
      dst.x = src.x and src.x + offset
      dst.y = src.y and src.y + offset
    elseif src.op == OP_JUMP then
      dst.x = src.x and src.x + offset
    elseif src.op == OP_SAVE then dst.n = src.n
    end
    insns[#insns + 1] = dst
  end
  return new_start
end

-- Apply quantifier to an existing atom fragment.
-- atom_from, atom_to = instruction range of the atom in insns (1-indexed, inclusive)
-- atom_outs = the out-list of the atom fragment (to be patched)
-- min, max = repetition range
-- Returns new frag
--: (Insns, integer, integer, Outs, number, number) -> Frag
local function apply_quant(insns, atom_from, atom_to, atom_outs, min, max)
  if min == 0 and max == 1 then
    -- Optional: split(atom.start, out) ; atom ; out
    local split_pc = #insns + 1
    -- Insert split before atom by... we can't insert. We've already emitted atom.
    -- So we need a different layout: emit split, patch atom's outs to after split.
    -- Actually atom was already emitted at atom_from..atom_to.
    -- We'll build: SPLIT -> atom_from | out_placeholder, atom finishes -> out
    -- But split must come BEFORE atom in the fragment's start.
    -- We need to reorder. Since we can't insert, we use jumps:
    -- Layout: JUMP to atom_from ; ... (atom already at atom_from..atom_to) ...
    -- Instead let's build freshly:
    -- split_pc -> atom_from, after_atom
    -- atom (already emitted at atom_from..atom_to) -> after_atom via patching outs
    -- after_atom = split_pc + 1 (we place split AFTER atom and jump)
    -- This won't work linearly. Let's use a different trick:
    -- Emit a SPLIT at a new location, pointing to atom_from and to a placeholder.
    -- Then atom_outs need to point past the split (or to a common exit).
    -- Easiest: since we control the frag abstraction, we just build:
    --   frag.start = split_pc
    --   split.x = atom_from
    --   split.y = OPEN (patched later)
    --   atom_outs already point somewhere — we wire them to after (patch later too)
    local split_pc2 = emit(insns, { op = OP_SPLIT, x = atom_from, y = 0 })
    -- Now: jump from split to atom_from (x), and split.y is an out.
    -- atom_outs are also outs.
    -- But atom_from is NOT right after split_pc2; the atom is at atom_from which was emitted earlier.
    -- The fragment start needs to be split_pc2. But the simulation starts at split_pc2, then goes to
    -- atom_from (via x) or falls through (via y).
    -- This creates a non-linear layout which the Thompson simulator handles fine via explicit threads.
    local new_outs = concat_outs(atom_outs, { { split_pc2, "y" } })
    return frag(split_pc2, new_outs)

  elseif min == 0 and max == math.huge then
    -- Kleene star: split(atom_from, out) at the top; atom loops back to split
    -- Layout: SPLIT(split_pc) -> atom_from | out
    --         atom (atom_from..atom_to) outs -> split_pc (loop)
    local split_pc = emit(insns, { op = OP_SPLIT, x = atom_from, y = 0 })
    -- patch atom outs to loop back to split_pc
    patch_outs(insns, atom_outs, split_pc)
    -- frag.start = split_pc, out = split.y
    return frag(split_pc, { { split_pc, "y" } })

  elseif min == 1 and max == math.huge then
    -- One or more: atom then SPLIT(back, out)
    -- atom already emitted. Patch atom_outs to a new SPLIT.
    local split_pc = emit(insns, { op = OP_SPLIT, x = atom_from, y = 0 })
    patch_outs(insns, atom_outs, split_pc)
    return frag(atom_from, { { split_pc, "y" } })

  elseif min == max then
    -- Exactly n: clone atom n-1 more times, chain them.
    if min == 0 then
      -- Match empty string — emit nothing meaningful; use a zero-width frag
      -- Represent as an unconditional out with no real instruction
      -- We'll emit a SAVE -1 as a no-op placeholder... actually just return a frag
      -- with no real instruction. We'll use a JUMP to the next pc.
      local jpc = emit(insns, { op = OP_JUMP, x = 0 })
      return frag(jpc, { { jpc, "x" } })
    end
    -- Already have 1 copy (atom_from..atom_to). Clone n-1 more.
    local prev_outs = atom_outs
    local prev_from = atom_from
    local prev_to = atom_to
    for _ = 2, min do
      local clone_start = clone_frag(insns, prev_from, prev_to)
      local clone_to = #insns
      -- patch prev_outs to clone_start
      patch_outs(insns, prev_outs, clone_start)
      -- new prev_outs: the cloned atom's outs
      -- The cloned atom's outs were patched to clone_start initially (from x/y=0+offset).
      -- Actually clone_frag preserves the src's x/y values (adjusted). The src's outs
      -- were unpatched (pointed to 0 before adjustment = offset). We need the outs of the clone.
      -- The outs of the original atom were atom_outs. The clones have outs at the same relative
      -- positions, shifted by offset. Rebuild:
      local clone_offset = clone_start - prev_from
      local new_outs = {}
      for i = 1, #prev_outs do
        new_outs[i] = { prev_outs[i][1] + clone_offset, prev_outs[i][2] }
      end
      -- But wait: prev_outs for the first copy are atom_outs which have already been patched
      -- to 0 (they haven't been patched yet to clone_start above). clone_frag copies x=0
      -- and adjusts by offset, so x = 0 + offset = clone_offset. That's wrong.
      -- Let me re-examine clone_frag: for OP_SPLIT it does dst.x = src.x + offset.
      -- If src.x == 0 (unpatched out), dst.x = offset which is clone_start - prev_from.
      -- That happens to equal the relative offset, which is not a valid pc either.
      -- The outs tracking system only works if we track them explicitly.
      -- Let me use a different approach: track outs by (pc, field) pairs and update them
      -- after cloning.
      prev_outs = new_outs
      prev_from = clone_start
      prev_to = clone_to
    end
    return frag(atom_from, prev_outs)

  else
    -- {n,m}: n required, then m-n optional (or unbounded if max=inf)
    -- First: required copies (n total, first already emitted)
    local prev_outs = atom_outs
    local prev_from = atom_from
    local prev_to = atom_to
    for _ = 2, min do
      local clone_start = clone_frag(insns, prev_from, prev_to)
      local clone_to = #insns
      patch_outs(insns, prev_outs, clone_start)
      local clone_offset = clone_start - prev_from
      local new_outs = {}
      for i = 1, #prev_outs do
        new_outs[i] = { prev_outs[i][1] + clone_offset, prev_outs[i][2] }
      end
      prev_outs = new_outs
      prev_from = clone_start
      prev_to = clone_to
    end

    if max == math.huge then
      -- {n,}: after n required copies, add a Kleene+ tail (one more copy looped)
      local tail_start = clone_frag(insns, atom_from, atom_to)
      local tail_to = #insns
      -- split: try tail | exit
      local split_pc = emit(insns, { op = OP_SPLIT, x = tail_start, y = 0 })
      patch_outs(insns, prev_outs, split_pc)
      -- tail loops back to split
      local tail_offset = tail_start - atom_from
      local tail_outs = {}
      for i = 1, #atom_outs do
        tail_outs[i] = { atom_outs[i][1] + tail_offset, atom_outs[i][2] }
      end
      patch_outs(insns, tail_outs, split_pc)
      return frag(atom_from, { { split_pc, "y" } })
    end

    -- Finite {n,m}: add m-n optional copies
    local all_outs = prev_outs
    for _ = min + 1, max do
      local clone_start = clone_frag(insns, atom_from, atom_to)
      local clone_to = #insns
      -- chain to SPLIT: try clone | skip
      local split_pc = emit(insns, { op = OP_SPLIT, x = clone_start, y = 0 })
      patch_outs(insns, all_outs, split_pc)
      local clone_offset = clone_start - atom_from
      local clone_outs = {}
      for i = 1, #atom_outs do
        clone_outs[i] = { atom_outs[i][1] + clone_offset, atom_outs[i][2] }
      end
      all_outs = concat_outs(clone_outs, { { split_pc, "y" } })
      prev_from = clone_start
      prev_to = clone_to
    end
    return frag(atom_from, all_outs)
  end
end

parse_concat = function(insns, pat, pos, gc)
  local frags = {}
  while pos[1] <= #pat do
    local b = pat:byte(pos[1])
    if b == 41 or b == 124 then break end  -- ) or |

    local atom_from = #insns + 1
    local af, e = parse_atom(insns, pat, pos, gc)
    if not af then
      if e then return nil, e end
      break
    end
    local atom_to = #insns

    -- Check for quantifier
    local min, max
    if pos[1] <= #pat then
      local q = pat:byte(pos[1])
      if q == 42 then     -- *
        min, max = 0, math.huge; pos[1] = pos[1] + 1
      elseif q == 43 then -- +
        min, max = 1, math.huge; pos[1] = pos[1] + 1
      elseif q == 63 then -- ?
        min, max = 0, 1; pos[1] = pos[1] + 1
      elseif q == 123 then -- {
        local qmin, qmax, qend = parse_brace_quant(pat, pos[1])
        if qmin then
          min, max = qmin, qmax; pos[1] = qend
        end
      end
      -- Consume optional lazy marker (not implemented, treated as greedy)
      if min and pos[1] <= #pat and pat:byte(pos[1]) == 63 then
        pos[1] = pos[1] + 1
      end
    end

    if min then
      -- For zero-width assertions (anchors, saves with no consumed input), quantifiers don't apply.
      local op = insns[atom_from].op
      if op == OP_ANCHOR_START or op == OP_ANCHOR_END then
        -- Ignore quantifier on anchors
        frags[#frags + 1] = af
      else
        af = apply_quant(insns, atom_from, atom_to, af.outs, min, max)
      end
    end

    frags[#frags + 1] = af
  end

  if #frags == 0 then
    -- empty concat — emit a JUMP placeholder
    local jpc = emit(insns, { op = OP_JUMP, x = 0 })
    return frag(jpc, { { jpc, "x" } })
  end

  -- Chain frags together: each frag's outs patch to next frag's start
  for i = 1, #frags - 1 do
    patch_outs(insns, frags[i].outs, frags[i + 1].start)
  end
  return frag(frags[1].start, frags[#frags].outs)
end

local function compile_pattern(pat)
  local insns = {}
  local gc = { 0 }  -- group counter
  local pos = { 1 }

  local f, e = parse_alt(insns, pat, pos, gc)
  if not f then return nil, e end
  if pos[1] <= #pat then
    return parse_error("unexpected character '" .. pat:sub(pos[1], pos[1]) .. "' at position " .. pos[1])
  end

  -- Patch final outs to MATCH
  local match_pc = emit(insns, { op = OP_MATCH })
  patch_outs(insns, f.outs, match_pc)

  -- Fix SAVE outs: SAVE instruction's "x" is not an out in the traditional sense;
  -- it flows to pc+1. But we put SAVEs in outs list. The issue:
  -- When we do frag(open_pc, {{close_pc, "x"}}), close_save.x is the out.
  -- After patching close_save.x = match_pc, when simulation hits close_save,
  -- it saves then goes to close_save.x = match_pc. That's correct.
  -- For the start: open_save.x is not in outs; simulation goes to open_save+1 = inner.start.
  -- That is correct IF inner.start == open_pc + 1, which requires parse_alt to emit inner
  -- starting at open_pc+1. That IS the case because we emit open_save then call parse_alt.

  return { insns = insns, ngroups = gc[1], pattern = pat }
end

-- ── Thompson NFA simulation ───────────────────────────────────────────────────
--
-- A thread is: { pc, caps }
-- caps is an array of 2*ngroups integers: caps[2i-1]=start, caps[2i]=end for group i.
-- Unset = 0.

-- Add state (pc, caps) to list, following epsilon transitions.
-- visited prevents visiting the same pc twice in one step.
--: (Insns, { [integer]: { pc: integer, caps: { [integer]: integer } } }, integer, { [integer]: integer }, integer, integer, { [integer]: unknown }) -> nil
local function add_thread(insns, list, pc, caps, pos, slen, visited)
  if visited[pc] then return end
  visited[pc] = true
  local instr = insns[pc]
  local op = instr.op
  if op == OP_JUMP then
    add_thread(insns, list, instr.x, caps, pos, slen, visited)
  elseif op == OP_SPLIT then
    -- Clone caps for second branch
    local caps2 = {}
    for i = 1, #caps do caps2[i] = caps[i] end
    add_thread(insns, list, instr.x, caps, pos, slen, visited)
    add_thread(insns, list, instr.y, caps2, pos, slen, visited)
  elseif op == OP_SAVE then
    -- Clone caps and record position
    local caps2 = {}
    for i = 1, #caps do caps2[i] = caps[i] end
    caps2[instr.n + 1] = pos  -- 1-indexed storage; slot n stored at index n+1
    -- Use instr.x if set (group open_save patched to inner.start),
    -- fall back to pc+1 for close_save (its x is patched by caller to next instr)
    add_thread(insns, list, instr.x or (pc + 1), caps2, pos, slen, visited)
  elseif op == OP_ANCHOR_START then
    if pos == 1 then
      add_thread(insns, list, instr.x, caps, pos, slen, visited)
    end
    -- else: thread dies
  elseif op == OP_ANCHOR_END then
    if pos == slen + 1 then
      add_thread(insns, list, instr.x, caps, pos, slen, visited)
    end
  else
    list[#list + 1] = { pc = pc, caps = caps }
  end
end

-- Run the NFA on subject[init..] (1-indexed).
-- Returns (match_start, match_end_plus1, caps) or nil.
-- If anchored=true, only tries starting at init.
--: ({ insns: Insns, ngroups: integer, pattern: string }, string, integer, boolean) -> (integer | nil, integer | nil, { [integer]: integer } | nil)
local function nfa_run(prog, subject, init, anchored)
  local insns = prog.insns
  local ngroups = prog.ngroups
  local slen = #subject
  local ncaps = ngroups * 2

  local function new_caps()
    local c = {}
    for i = 1, ncaps do c[i] = 0 end
    return c
  end

  local best_start, best_end, best_caps = nil, nil, nil

  for start = init, anchored and init or slen + 1 do
    local clist = {}
    local visited = {}
    add_thread(insns, clist, 1, new_caps(), start, slen, visited)

    -- Check if initial state is already MATCH (empty pattern)
    for i = 1, #clist do
      if insns[clist[i].pc].op == OP_MATCH then
        best_start = start
        best_end = start
        best_caps = clist[i].caps
        break
      end
    end

    local pos = start
    while #clist > 0 and pos <= slen do
      local b = subject:byte(pos)
      local nlist = {}
      local nvisited = {}

      for i = 1, #clist do
        local t = clist[i]
        local instr = insns[t.pc]
        local op = instr.op
        local matched = false
        if op == OP_CHAR then
          matched = (b == instr.c)
        elseif op == OP_CLASS then
          matched = class_matches(instr.cls, b)
        elseif op == OP_ANY then
          matched = (b ~= 10)  -- not newline
        end
        if matched then
          add_thread(insns, nlist, instr.x, t.caps, pos + 1, slen, nvisited)
        end
      end

      pos = pos + 1
      clist = nlist

      -- Check for MATCH in new list (following epsilons already done in add_thread)
      for i = 1, #clist do
        if insns[clist[i].pc].op == OP_MATCH then
          -- Leftmost longest: prefer earlier start; for same start, prefer longer
          if not best_start or start < best_start
              or (start == best_start and pos > best_end) then
            best_start = start
            best_end = pos
            best_caps = clist[i].caps
          end
        end
      end
    end

    if best_start == start then
      -- Found a match starting here — for leftmost, this is the best we can do
      break
    end
  end

  if best_start then
    return best_start, best_end, best_caps
  end
  return nil
end

-- Extract capture strings from caps array
local function extract_caps(subject, caps, ngroups)
  local result = {}
  for i = 1, ngroups do
    local s = caps[i * 2 - 1]
    local e = caps[i * 2]
    if s and s > 0 and e and e > 0 then
      result[i] = subject:sub(s, e - 1)
    else
      result[i] = false
    end
  end
  return result
end

-- ── Compiled regex object ─────────────────────────────────────────────────────

local Re = {}
Re.__index = Re

function Re:test(str)
  local s = nfa_run(self._prog, str, 1, false)
  return s ~= nil
end

function Re:find(str, init)
  local s, e, caps = nfa_run(self._prog, str, init or 1, false)
  if not s then return nil end
  if self._prog.ngroups > 0 then
    local cs = extract_caps(str, caps, self._prog.ngroups)
    return s, e - 1, unpack(cs)
  end
  return s, e - 1
end

function Re:match(str)
  local s, e, caps = nfa_run(self._prog, str, 1, false)
  if not s then return nil end
  if self._prog.ngroups > 0 then
    local cs = extract_caps(str, caps, self._prog.ngroups)
    return e - 1, unpack(cs)
  end
  return e - 1
end

function Re:find_all(str)
  local results = {}
  local pos = 1
  local slen = #str
  while pos <= slen + 1 do
    local s, e, caps = nfa_run(self._prog, str, pos, false)
    if not s then break end
    local entry = { s, e - 1 }
    if self._prog.ngroups > 0 then
      local cs = extract_caps(str, caps, self._prog.ngroups)
      for i = 1, #cs do entry[#entry + 1] = cs[i] end
    end
    results[#results + 1] = entry
    if e == s then
      pos = s + 1  -- avoid infinite loop on empty match
    else
      pos = e
    end
  end
  return results
end

local function apply_repl(repl, full_match, caps_arr, ngroups)
  if type(repl) == "function" then
    if ngroups > 0 then
      return repl(unpack(caps_arr)) or full_match
    else
      return repl(full_match) or full_match
    end
  else
    -- String replacement: %0 = whole match, %1..%9 = captures
    return (repl:gsub("%%(%d)", function(d)
      local idx = tonumber(d)
      if idx == 0 then return full_match end
      return (caps_arr[idx] or "")
    end))
  end
end

function Re:sub(str, repl, n)
  local parts = {}
  local count = 0
  local pos = 1
  local slen = #str
  local limit = n or 1
  while pos <= slen + 1 do
    if count >= limit then break end
    local s, e, caps = nfa_run(self._prog, str, pos, false)
    if not s then break end
    if s > pos then parts[#parts + 1] = str:sub(pos, s - 1) end
    local full = str:sub(s, e - 1)
    local caps_arr = self._prog.ngroups > 0 and extract_caps(str, caps, self._prog.ngroups) or {}
    parts[#parts + 1] = apply_repl(repl, full, caps_arr, self._prog.ngroups)
    count = count + 1
    if e == s then
      if s <= slen then parts[#parts + 1] = str:sub(s, s) end
      pos = s + 1
    else
      pos = e
    end
  end
  if pos <= slen then parts[#parts + 1] = str:sub(pos) end
  return table.concat(parts), count
end

function Re:gsub(str, repl)
  local parts = {}
  local count = 0
  local pos = 1
  local slen = #str
  while pos <= slen + 1 do
    local s, e, caps = nfa_run(self._prog, str, pos, false)
    if not s then break end
    if s > pos then parts[#parts + 1] = str:sub(pos, s - 1) end
    local full = str:sub(s, e - 1)
    local caps_arr = self._prog.ngroups > 0 and extract_caps(str, caps, self._prog.ngroups) or {}
    parts[#parts + 1] = apply_repl(repl, full, caps_arr, self._prog.ngroups)
    count = count + 1
    if e == s then
      if s <= slen then parts[#parts + 1] = str:sub(s, s) end
      pos = s + 1
    else
      pos = e
    end
  end
  if pos <= slen then parts[#parts + 1] = str:sub(pos) end
  return table.concat(parts), count
end

function Re:split(str, max_splits)
  local result = {}
  local pos = 1
  local slen = #str
  local count = 0
  while pos <= slen do
    if max_splits and count >= max_splits then break end
    local s, e, _ = nfa_run(self._prog, str, pos, false)
    if not s then break end
    result[#result + 1] = str:sub(pos, s - 1)
    count = count + 1
    if e == s then
      pos = s + 1
    else
      pos = e
    end
  end
  result[#result + 1] = str:sub(pos)
  return result
end

-- ── Module-level functions ────────────────────────────────────────────────────

function M.compile(pattern)
  if type(pattern) == "table" and pattern._prog then return pattern end
  local prog, err = compile_pattern(pattern)
  if not prog then return nil, err end
  return setmetatable({ _prog = prog }, Re)
end

local function ensure_re(pat_or_re)
  if type(pat_or_re) == "table" and pat_or_re._prog then
    return pat_or_re, nil
  end
  return M.compile(pat_or_re)
end

function M.test(pat, str)
  local re, err = ensure_re(pat)
  if not re then return false, err end
  return re:test(str)
end

function M.find(pat, str, init)
  local re, err = ensure_re(pat)
  if not re then return nil, err end
  return re:find(str, init)
end

function M.match(pat, str)
  local re, err = ensure_re(pat)
  if not re then return nil, err end
  return re:match(str)
end

function M.find_all(pat, str)
  local re, err = ensure_re(pat)
  if not re then return nil, err end
  return re:find_all(str)
end

function M.sub(pat, str, repl, n)
  local re, err = ensure_re(pat)
  if not re then return nil, err end
  return re:sub(str, repl, n)
end

function M.gsub(pat, str, repl)
  local re, err = ensure_re(pat)
  if not re then return nil, err end
  return re:gsub(str, repl)
end

function M.split(pat, str, max_splits)
  local re, err = ensure_re(pat)
  if not re then return nil, err end
  return re:split(str, max_splits)
end

return M
