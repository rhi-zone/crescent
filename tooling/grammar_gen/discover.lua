-- tooling/grammar_gen/discover.lua
--
-- Grammar induction over a corpus: given already-read source files (caller
-- supplies content — this module does no I/O of its own, per crescent's
-- caps-first convention for library-shaped code), find repeated statement
-- shapes (candidate productions), cluster them into slots (a shape with
-- more than one distinct set of hole-values across its instances) vs.
-- plain rules (a shape with exactly one hole-value set — "convention,
-- zero variance"), and flag shapes occurring exactly once as residue.
--
-- Two span granularities are extracted, both needed to reproduce the hand-
-- induced grammar in docs/design/codebase-as-grammar.md:
--   - single statements (after canon.canonicalize_block's ternary/if-else
--     rewrite), at every nesting level in every file — this is what
--     catches the tier_select ok-check as one slot with if_else/ternary
--     alternatives.
--   - contiguous windows of 2..MAX_WINDOW statements within the same
--     block — this is what catches multi-statement idioms like the whole
--     pcall-tier-select-then-narrow sequence, which no single statement's
--     fingerprint captures on its own.
--
-- A corpus entry that fails to parse is recorded separately (not silently
-- dropped) — see M.induce's `unparsed` return.

local luaparse = require("tooling.grammar_gen.luaparse")
local canon = require("tooling.grammar_gen.canon")

local M = {}

local MAX_WINDOW = 5

--:: Occurrence = { fp: string, path: string, line: number, holes: { [integer]: string }, summary: string }
--:: Rule = { fp: string, count: number, occurrences: { [integer]: Occurrence } }
--:: Alternative = { occurrences: { [integer]: Occurrence } }
--:: Slot = { fp: string, count: number, alternatives: { [integer]: Alternative } }
--:: Residue = { fp: string, occurrence: Occurrence }
--:: ClusterResult = { rules: { [integer]: Rule }, slots: { [integer]: Slot }, residue: { [integer]: Residue } }

-- Collect every statement list (a block's `.stats` array) reachable in the
-- file, tagged with its file/path context, after canonicalization has
-- already rewritten cond_assign patterns in place.
--: (block: unknown, path: string, out: { [integer]: { path: string, stats: { [integer]: unknown } } }) -> nil
local function collect_blocks(block, path, out)
  local stats = canon.gl(block, "stats") --: { [integer]: unknown }
  out[#out + 1] = { path = path, stats = stats }
  for _, s in ipairs(stats) do
    local tag = canon.gs(s, "tag")
    if tag == "if" then
      for _, c in ipairs(canon.gl(s, "clauses")) do collect_blocks(canon.get(c, "body"), path, out) end
      local orelse = canon.get(s, "orelse")
      if orelse then collect_blocks(orelse, path, out) end
    elseif tag == "while" or tag == "do" or tag == "repeat" or tag == "fornum" or tag == "forin" then
      collect_blocks(canon.get(s, "body"), path, out)
    elseif tag == "localfunction" then
      collect_blocks(canon.get(canon.get(s, "fn"), "body"), path, out)
    elseif tag == "assign" or tag == "local" then
      for _, v in ipairs(canon.gl(s, "values")) do
        if canon.gs(v, "tag") == "function" then collect_blocks(canon.get(v, "body"), path, out) end
      end
    end
  end
end

-- Group a flat list of occurrence records into clusters, then classify
-- each cluster.
--: (occurrences: { [integer]: Occurrence }) -> ClusterResult
local function cluster(occurrences)
  local by_fp = {} --: { [string]: { [integer]: Occurrence } }
  local order = {} --: { [integer]: string }
  for _, occ in ipairs(occurrences) do
    if not by_fp[occ.fp] then
      by_fp[occ.fp] = {}
      order[#order + 1] = occ.fp
    end
    local list = by_fp[occ.fp]
    list[#list + 1] = occ
  end

  local rules = {} --: { [integer]: Rule }
  local slots = {} --: { [integer]: Slot }
  local residue = {} --: { [integer]: Residue }
  for _, fp in ipairs(order) do
    local occs = by_fp[fp]
    if #occs == 1 then
      residue[#residue + 1] = { fp = fp, occurrence = occs[1] }
    else
      -- Sub-group by exact hole-tuple to find distinct alternatives.
      local by_holes = {} --: { [string]: { [integer]: Occurrence } }
      local holes_order = {} --: { [integer]: string }
      for _, occ in ipairs(occs) do
        local key = table.concat(occ.holes, "\1")
        if not by_holes[key] then
          by_holes[key] = {}
          holes_order[#holes_order + 1] = key
        end
        table.insert(by_holes[key], occ)
      end
      if #holes_order == 1 then
        rules[#rules + 1] = { fp = fp, count = #occs, occurrences = occs }
      else
        local alternatives = {} --: { [integer]: Alternative }
        for _, key in ipairs(holes_order) do
          alternatives[#alternatives + 1] = { occurrences = by_holes[key] }
        end
        slots[#slots + 1] = { fp = fp, count = #occs, alternatives = alternatives }
      end
    end
  end
  return { rules = rules, slots = slots, residue = residue }
end
M.cluster = cluster

-- corpus: { [integer]: { path: string, source: string } }
-- Returns: (result, unparsed) where result = { single = <cluster output>,
-- windows = { [window_size] = <cluster output> } }, unparsed = list of
-- { path, err }.
--: (corpus: { [integer]: { path: string, source: string } }) -> ({ single: ClusterResult, windows: { [integer]: ClusterResult } }, { [integer]: { path: string, err: string } })
function M.induce(corpus)
  local unparsed = {} --: { [integer]: { path: string, err: string } }
  local all_blocks = {} --: { [integer]: { path: string, stats: { [integer]: unknown } } }

  for _, entry in ipairs(corpus) do
    local ast, err = luaparse.parse(entry.source, entry.path)
    if not ast then
      unparsed[#unparsed + 1] = { path = entry.path, err = err or "?" }
    else
      canon.canonicalize_block(ast)
      collect_blocks(ast, entry.path, all_blocks)
    end
  end

  -- Single-statement occurrences.
  local single_occ = {} --: { [integer]: Occurrence }
  for _, blk in ipairs(all_blocks) do
    for _, s in ipairs(blk.stats) do
      local fp = canon.fp_stat(s)
      if fp then
        single_occ[#single_occ + 1] = {
          fp = fp, path = blk.path, line = canon.gi(s, "line"),
          holes = canon.holes(s), summary = fp,
        }
      end
    end
  end

  -- Sliding-window occurrences of contiguous statements (sizes 2..MAX_WINDOW).
  local window_occ = {} --: { [integer]: { [integer]: Occurrence } }
  for w = 2, MAX_WINDOW do window_occ[w] = {} end
  for _, blk in ipairs(all_blocks) do
    local stats = blk.stats
    for w = 2, MAX_WINDOW do
      for i = 1, #stats - w + 1 do
        local fps, allok = {}, true
        for j = i, i + w - 1 do
          local fp = canon.fp_stat(stats[j])
          if not fp then allok = false; break end
          fps[#fps + 1] = fp
        end
        if allok then
          local h = {} --: { [integer]: string }
          for j = i, i + w - 1 do
            for _, hv in ipairs(canon.holes(stats[j])) do h[#h + 1] = hv end
          end
          window_occ[w][#window_occ[w] + 1] = {
            fp = table.concat(fps, "||"), path = blk.path, line = canon.gi(stats[i], "line"),
            holes = h, summary = table.concat(fps, " ; "),
          }
        end
      end
    end
  end

  local windows = {} --: { [integer]: ClusterResult }
  for w = 2, MAX_WINDOW do windows[w] = cluster(window_occ[w]) end

  return { single = cluster(single_occ), windows = windows }, unparsed
end

return M
