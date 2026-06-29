-- v9 spike C: domain-agnostic constraint engine (MLsub-flavored, worklist to fixpoint)
--
-- The engine knows NOTHING about types or liveness. It knows only:
--   * cells   : named lattice elements (opaque values)
--   * a domain: provides bottom(), join(a,b), eq(a,b) for its cells
--   * constraints: each declares the cells it READS and WRITES, plus an
--                  apply(get) -> { [cell]=value } that proposes new values.
--
-- The engine joins each proposed value into the target cell (monotone) and
-- re-schedules every constraint that READS a cell whose value changed, until
-- nothing changes. This is the only control loop in the whole system.
--
-- Both type inference (union-flow) and liveness (gen/kill dataflow) are
-- expressed as nothing but (cells, domain, constraints) over this one loop.

local Engine = {}
Engine.__index = Engine

local function new(domain)
  return setmetatable({
    domain = domain,            -- { bottom, join, eq }
    cells = {},                 -- cell-id -> lattice value
    constraints = {},           -- list of constraint records
    readers = {},               -- cell-id -> { constraint-index, ... }
  }, Engine)
end

function Engine:cell(id)
  if self.cells[id] == nil then self.cells[id] = self.domain.bottom() end
  return id
end

-- A constraint reads some cells and writes some cells.
function Engine:constrain(reads, writes, apply)
  self.constraints[#self.constraints + 1] = { reads = reads, writes = writes, apply = apply }
  local idx = #self.constraints
  for _, c in ipairs(reads) do
    self:cell(c)
    self.readers[c] = self.readers[c] or {}
    self.readers[c][#self.readers[c] + 1] = idx
  end
  for _, c in ipairs(writes) do self:cell(c) end
end

function Engine:solve()
  local domain = self.domain
  -- worklist of constraint indices; start with all of them
  local queued, work = {}, {}
  for i = 1, #self.constraints do work[i] = i; queued[i] = true end
  local head = 1
  local function get(id) return self.cells[id] end
  local steps = 0
  while head <= #work do
    local idx = work[head]; head = head + 1; queued[idx] = nil
    steps = steps + 1
    local con = self.constraints[idx]
    local proposed = con.apply(get) or {}
    for cellid, val in pairs(proposed) do
      local old = self.cells[cellid]
      local merged = domain.join(old, val)
      if not domain.eq(old, merged) then
        self.cells[cellid] = merged
        for _, r in ipairs(self.readers[cellid] or {}) do
          if not queued[r] then work[#work + 1] = r; queued[r] = true end
        end
      end
    end
  end
  return steps
end

function Engine:value(id) return self.cells[id] end

return { new = new }
