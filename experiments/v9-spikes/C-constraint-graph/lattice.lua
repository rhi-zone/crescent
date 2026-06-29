-- A join-semilattice of finite string sets (powerset, ordered by subset).
-- BOTH domains in this spike happen to use this same lattice: the type domain
-- uses it as a set of atoms {int,str,...} (union = union type); the liveness
-- domain uses it as a set of live variable names. That coincidence is itself a
-- finding (see FINDINGS.md) -- the engine never assumes it.

local Set = {}

function Set.bottom() return {} end

function Set.join(a, b)
  local out = {}
  for k in pairs(a) do out[k] = true end
  for k in pairs(b) do out[k] = true end
  return out
end

function Set.eq(a, b)
  for k in pairs(a) do if not b[k] then return false end end
  for k in pairs(b) do if not a[k] then return false end end
  return true
end

function Set.minus(a, kill)
  local out = {}
  for k in pairs(a) do if not kill[k] then out[k] = true end end
  return out
end

function Set.of(...)
  local out = {}
  for _, k in ipairs({ ... }) do out[k] = true end
  return out
end

function Set.tostring(s, sep)
  local keys = {}
  for k in pairs(s) do keys[#keys + 1] = k end
  table.sort(keys)
  if #keys == 0 then return "(empty)" end
  return table.concat(keys, sep or " | ")
end

return Set
