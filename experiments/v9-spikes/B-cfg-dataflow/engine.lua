-- v9 spike B: domain-agnostic monotone-dataflow worklist engine.
--
-- This file knows NOTHING about types or liveness. It is parameterized
-- entirely by a `domain`:
--
--   domain.direction : "forward" | "backward"
--   domain.init      : boundary value (entry value for forward, exit for backward)
--   domain.bottom    : start value for every block before the fixpoint
--   domain.join(a,b) : lattice join (least upper bound)
--   domain.transfer(block, input) -> output
--   domain.equal(a,b): lattice equality (for the fixpoint test)
--
-- The CFG it consumes is { blocks=[block], byid={id->block}, entry=id, exit=id }
-- where each block has integer `id`, `.succs` and `.preds` (lists of ids).
--
-- It returns { flow_in = {id->val}, flow_out = {id->val} } where the names are
-- relative to the ANALYSIS direction:
--   forward : flow_in  = value BEFORE the block, flow_out = value AFTER it.
--   backward: flow_in  = value entering along the analysis (= program-AFTER the
--             block, i.e. live-out), flow_out = the other end (live-in).
--
-- Direction is handled by ONE swap: which adjacency list feeds a block, and
-- which adjacency list it notifies on change. Nothing else in the loop branches
-- on direction.

local function solve(cfg, domain)
  local fwd = domain.direction == "forward"
  local function sources(b) return fwd and b.preds or b.succs end   -- who feeds b
  local function sinks(b)   return fwd and b.succs or b.preds end   -- who b notifies
  local boundary = fwd and cfg.entry or cfg.exit

  local flow_in, flow_out = {}, {}
  for _, b in ipairs(cfg.blocks) do
    flow_in[b.id]  = domain.bottom
    flow_out[b.id] = domain.bottom
  end

  -- worklist of block ids; seed with all blocks.
  local work, queued = {}, {}
  for _, b in ipairs(cfg.blocks) do work[#work + 1] = b.id; queued[b.id] = true end
  local head, steps = 1, 0

  while head <= #work do
    local id = work[head]; head = head + 1; queued[id] = nil
    steps = steps + 1
    local b = cfg.byid[id]

    -- input = join of all source outputs (plus boundary seed if this is the edge block)
    local inp = (id == boundary) and domain.init or domain.bottom
    for _, sid in ipairs(sources(b)) do
      inp = domain.join(inp, flow_out[sid])
    end
    flow_in[id] = inp

    local out = domain.transfer(b, inp)
    if not domain.equal(out, flow_out[id]) then
      flow_out[id] = out
      for _, sid in ipairs(sinks(b)) do
        if not queued[sid] then work[#work + 1] = sid; queued[sid] = true end
      end
    end
  end

  return { flow_in = flow_in, flow_out = flow_out, steps = steps }
end

return { solve = solve }
