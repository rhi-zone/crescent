if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

--:: Vec = { data: unknown, n: integer }

local M = {}

local has_ffi, ffi = pcall(require, "ffi")

if has_ffi then
  -- FFI tier: double[?] storage, 0-indexed C arrays
  M._tier = "ffi"

  local double_arr = ffi.typeof("double[?]")
  local vec_mt = {}
  vec_mt.__index = vec_mt

  --: (t: {[number]: number}) -> Vec
  local function vec_from_table(t)
    local n = #t
    local data = double_arr(n)
    for i = 1, n do
      data[i - 1] = t[i]
    end
    return setmetatable({ data = data, n = n }, vec_mt)
  end

  --: (v: Vec) -> string
  function vec_mt:__tostring()
    return M.to_string(self)
  end

  --: (t: {[number]: number}) -> Vec
  function M.new(t)
    return vec_from_table(t)
  end

  --: (n: number) -> Vec
  function M.zeros(n)
    local data = double_arr(n)
    for i = 0, n - 1 do
      data[i] = 0.0
    end
    return setmetatable({ data = data, n = n }, vec_mt)
  end

  --: (n: number) -> Vec
  function M.ones(n)
    local data = double_arr(n)
    for i = 0, n - 1 do
      data[i] = 1.0
    end
    return setmetatable({ data = data, n = n }, vec_mt)
  end

  --: (n: number) -> Vec
  function M.random(n)
    local data = double_arr(n)
    for i = 0, n - 1 do
      data[i] = math.random()
    end
    return setmetatable({ data = data, n = n }, vec_mt)
  end

  --: (start: number, stop: number, n: number) -> Vec
  function M.linspace(start, stop, n)
    local data = double_arr(n)
    if n <= 1 then
      if n == 1 then data[0] = start end
      return setmetatable({ data = data, n = n }, vec_mt)
    end
    local step = (stop - start) / (n - 1)
    for i = 0, n - 1 do
      data[i] = start + i * step
    end
    return setmetatable({ data = data, n = n }, vec_mt)
  end

  --: (v: Vec) -> number
  function M.len(v)
    return v.n
  end

  --: (a: Vec, b: Vec) -> Vec
  function M.add(a, b)
    local n = a.n
    local data = double_arr(n)
    local ad, bd = a.data, b.data
    for i = 0, n - 1 do
      data[i] = ad[i] + bd[i]
    end
    return setmetatable({ data = data, n = n }, vec_mt)
  end

  --: (a: Vec, b: Vec) -> Vec
  function M.sub(a, b)
    local n = a.n
    local data = double_arr(n)
    local ad, bd = a.data, b.data
    for i = 0, n - 1 do
      data[i] = ad[i] - bd[i]
    end
    return setmetatable({ data = data, n = n }, vec_mt)
  end

  --: (a: Vec, b: Vec) -> Vec
  function M.mul(a, b)
    local n = a.n
    local data = double_arr(n)
    local ad, bd = a.data, b.data
    for i = 0, n - 1 do
      data[i] = ad[i] * bd[i]
    end
    return setmetatable({ data = data, n = n }, vec_mt)
  end

  --: (a: Vec, b: Vec) -> Vec
  function M.div(a, b)
    local n = a.n
    local data = double_arr(n)
    local ad, bd = a.data, b.data
    for i = 0, n - 1 do
      data[i] = ad[i] / bd[i]
    end
    return setmetatable({ data = data, n = n }, vec_mt)
  end

  --: (a: Vec, s: number) -> Vec
  function M.scale(a, s)
    local n = a.n
    local data = double_arr(n)
    local ad = a.data
    for i = 0, n - 1 do
      data[i] = ad[i] * s
    end
    return setmetatable({ data = data, n = n }, vec_mt)
  end

  --: (a: Vec) -> Vec
  function M.neg(a)
    local n = a.n
    local data = double_arr(n)
    local ad = a.data
    for i = 0, n - 1 do
      data[i] = -ad[i]
    end
    return setmetatable({ data = data, n = n }, vec_mt)
  end

  --: (a: Vec, b: Vec) -> number
  function M.dot(a, b)
    local n = a.n
    local ad, bd = a.data, b.data
    local s = 0.0
    for i = 0, n - 1 do
      s = s + ad[i] * bd[i]
    end
    return s
  end

  --: (a: Vec) -> number
  function M.norm(a)
    local n = a.n
    local ad = a.data
    local s = 0.0
    for i = 0, n - 1 do
      local v = ad[i]
      s = s + v * v
    end
    return math.sqrt(s)
  end

  --: (a: Vec) -> number
  function M.norm1(a)
    local n = a.n
    local ad = a.data
    local s = 0.0
    for i = 0, n - 1 do
      local v = ad[i]
      if v < 0 then v = -v end
      s = s + v
    end
    return s
  end

  --: (a: Vec) -> number
  function M.sum(a)
    local n = a.n
    local ad = a.data
    local s = 0.0
    for i = 0, n - 1 do
      s = s + ad[i]
    end
    return s
  end

  --: (a: Vec) -> number
  function M.mean(a)
    return M.sum(a) / a.n
  end

  --: (a: Vec) -> number
  function M.min(a)
    local n = a.n
    if n == 0 then return math.huge end
    local ad = a.data
    local m = ad[0]
    for i = 1, n - 1 do
      if ad[i] < m then m = ad[i] end
    end
    return m
  end

  --: (a: Vec) -> number
  function M.max(a)
    local n = a.n
    if n == 0 then return -math.huge end
    local ad = a.data
    local m = ad[0]
    for i = 1, n - 1 do
      if ad[i] > m then m = ad[i] end
    end
    return m
  end

  --: (a: Vec) -> number
  function M.argmin(a)
    local n = a.n
    if n == 0 then return 0 end
    local ad = a.data
    local m, mi = ad[0], 1
    for i = 1, n - 1 do
      if ad[i] < m then m = ad[i]; mi = i + 1 end
    end
    return mi
  end

  --: (a: Vec) -> number
  function M.argmax(a)
    local n = a.n
    if n == 0 then return 0 end
    local ad = a.data
    local m, mi = ad[0], 1
    for i = 1, n - 1 do
      if ad[i] > m then m = ad[i]; mi = i + 1 end
    end
    return mi
  end

  --: (a: Vec, b: Vec) -> number
  function M.cosine(a, b)
    local n = a.n
    local ad, bd = a.data, b.data
    local d, na, nb = 0.0, 0.0, 0.0
    for i = 0, n - 1 do
      local ai, bi = ad[i], bd[i]
      d = d + ai * bi
      na = na + ai * ai
      nb = nb + bi * bi
    end
    local denom = math.sqrt(na) * math.sqrt(nb)
    if denom == 0 then return 0.0 end
    return d / denom
  end

  --: (a: Vec, b: Vec) -> number
  function M.distance(a, b)
    local n = a.n
    local ad, bd = a.data, b.data
    local s = 0.0
    for i = 0, n - 1 do
      local d = ad[i] - bd[i]
      s = s + d * d
    end
    return math.sqrt(s)
  end

  --: (a: Vec) -> Vec
  function M.normalize(a)
    local n = a.n
    local ad = a.data
    local s = 0.0
    for i = 0, n - 1 do
      local v = ad[i]
      s = s + v * v
    end
    local inv = 1.0 / math.sqrt(s)
    local data = double_arr(n)
    for i = 0, n - 1 do
      data[i] = ad[i] * inv
    end
    return setmetatable({ data = data, n = n }, vec_mt)
  end

  --: (v: Vec, i: number) -> number
  function M.get(v, i)
    return v.data[i - 1]
  end

  --: (v: Vec, i: number, x: number) -> ()
  function M.set(v, i, x)
    v.data[i - 1] = x
  end

  --: (v: Vec) -> {[number]: number}
  function M.to_table(v)
    local n = v.n
    local t = {}
    local vd = v.data
    for i = 0, n - 1 do
      t[i + 1] = vd[i]
    end
    return t
  end

  --: (v: Vec) -> string
  function M.to_string(v)
    local n = v.n
    if n == 0 then return "[]" end
    local parts = {}
    local vd = v.data
    for i = 0, n - 1 do
      parts[i + 1] = tostring(vd[i])
    end
    return "[" .. table.concat(parts, ", ") .. "]"
  end

else
  -- Pure Lua tier: 1-indexed tables with n field
  M._tier = "pure"

  --: (t: {[number]: number}) -> Vec
  function M.new(t)
    local n = #t
    local v = { n = n }
    for i = 1, n do
      v[i] = t[i] + 0.0
    end
    return v
  end

  --: (n: number) -> Vec
  function M.zeros(n)
    local v = { n = n }
    for i = 1, n do
      v[i] = 0.0
    end
    return v
  end

  --: (n: number) -> Vec
  function M.ones(n)
    local v = { n = n }
    for i = 1, n do
      v[i] = 1.0
    end
    return v
  end

  --: (n: number) -> Vec
  function M.random(n)
    local v = { n = n }
    for i = 1, n do
      v[i] = math.random()
    end
    return v
  end

  --: (start: number, stop: number, n: number) -> Vec
  function M.linspace(start, stop, n)
    local v = { n = n }
    if n <= 1 then
      if n == 1 then v[1] = start end
      return v
    end
    local step = (stop - start) / (n - 1)
    for i = 1, n do
      v[i] = start + (i - 1) * step
    end
    return v
  end

  --: (v: Vec) -> number
  function M.len(v)
    return v.n
  end

  --: (a: Vec, b: Vec) -> Vec
  function M.add(a, b)
    local n = a.n
    local c = { n = n }
    for i = 1, n do
      c[i] = a[i] + b[i]
    end
    return c
  end

  --: (a: Vec, b: Vec) -> Vec
  function M.sub(a, b)
    local n = a.n
    local c = { n = n }
    for i = 1, n do
      c[i] = a[i] - b[i]
    end
    return c
  end

  --: (a: Vec, b: Vec) -> Vec
  function M.mul(a, b)
    local n = a.n
    local c = { n = n }
    for i = 1, n do
      c[i] = a[i] * b[i]
    end
    return c
  end

  --: (a: Vec, b: Vec) -> Vec
  function M.div(a, b)
    local n = a.n
    local c = { n = n }
    for i = 1, n do
      c[i] = a[i] / b[i]
    end
    return c
  end

  --: (a: Vec, s: number) -> Vec
  function M.scale(a, s)
    local n = a.n
    local c = { n = n }
    for i = 1, n do
      c[i] = a[i] * s
    end
    return c
  end

  --: (a: Vec) -> Vec
  function M.neg(a)
    local n = a.n
    local c = { n = n }
    for i = 1, n do
      c[i] = -a[i]
    end
    return c
  end

  --: (a: Vec, b: Vec) -> number
  function M.dot(a, b)
    local n = a.n
    local s = 0.0
    for i = 1, n do
      s = s + a[i] * b[i]
    end
    return s
  end

  --: (a: Vec) -> number
  function M.norm(a)
    local n = a.n
    local s = 0.0
    for i = 1, n do
      local v = a[i]
      s = s + v * v
    end
    return math.sqrt(s)
  end

  --: (a: Vec) -> number
  function M.norm1(a)
    local n = a.n
    local s = 0.0
    for i = 1, n do
      local v = a[i]
      if v < 0 then v = -v end
      s = s + v
    end
    return s
  end

  --: (a: Vec) -> number
  function M.sum(a)
    local n = a.n
    local s = 0.0
    for i = 1, n do
      s = s + a[i]
    end
    return s
  end

  --: (a: Vec) -> number
  function M.mean(a)
    return M.sum(a) / a.n
  end

  --: (a: Vec) -> number
  function M.min(a)
    local n = a.n
    if n == 0 then return math.huge end
    local m = a[1]
    for i = 2, n do
      if a[i] < m then m = a[i] end
    end
    return m
  end

  --: (a: Vec) -> number
  function M.max(a)
    local n = a.n
    if n == 0 then return -math.huge end
    local m = a[1]
    for i = 2, n do
      if a[i] > m then m = a[i] end
    end
    return m
  end

  --: (a: Vec) -> number
  function M.argmin(a)
    local n = a.n
    if n == 0 then return 0 end
    local m, mi = a[1], 1
    for i = 2, n do
      if a[i] < m then m = a[i]; mi = i end
    end
    return mi
  end

  --: (a: Vec) -> number
  function M.argmax(a)
    local n = a.n
    if n == 0 then return 0 end
    local m, mi = a[1], 1
    for i = 2, n do
      if a[i] > m then m = a[i]; mi = i end
    end
    return mi
  end

  --: (a: Vec, b: Vec) -> number
  function M.cosine(a, b)
    local n = a.n
    local d, na, nb = 0.0, 0.0, 0.0
    for i = 1, n do
      local ai, bi = a[i], b[i]
      d = d + ai * bi
      na = na + ai * ai
      nb = nb + bi * bi
    end
    local denom = math.sqrt(na) * math.sqrt(nb)
    if denom == 0 then return 0.0 end
    return d / denom
  end

  --: (a: Vec, b: Vec) -> number
  function M.distance(a, b)
    local n = a.n
    local s = 0.0
    for i = 1, n do
      local d = a[i] - b[i]
      s = s + d * d
    end
    return math.sqrt(s)
  end

  --: (a: Vec) -> Vec
  function M.normalize(a)
    local n = a.n
    local s = 0.0
    for i = 1, n do
      local v = a[i]
      s = s + v * v
    end
    local inv = 1.0 / math.sqrt(s)
    local c = { n = n }
    for i = 1, n do
      c[i] = a[i] * inv
    end
    return c
  end

  --: (v: Vec, i: number) -> number
  function M.get(v, i)
    return v[i]
  end

  --: (v: Vec, i: number, x: number) -> ()
  function M.set(v, i, x)
    v[i] = x
  end

  --: (v: Vec) -> {[number]: number}
  function M.to_table(v)
    local n = v.n
    local t = {}
    for i = 1, n do
      t[i] = v[i]
    end
    return t
  end

  --: (v: Vec) -> string
  function M.to_string(v)
    local n = v.n
    if n == 0 then return "[]" end
    local parts = {}
    for i = 1, n do
      parts[i] = tostring(v[i])
    end
    return "[" .. table.concat(parts, ", ") .. "]"
  end
end

return M
