if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

local T  = require("lib.test.assert")
local GM = require("lib.game_math")

local function near(a, b) return math.abs(a - b) < 1e-6 end
local function nearf(a, b, eps) return math.abs(a - b) < (eps or 1e-6) end

-- ─── vec2 ────────────────────────────────────────────────────────────────────

T.describe("vec2", function()
  T.it("constructs with x/y fields", function()
    local v = GM.vec2(3, 4)
    T.eq(v.x, 3)
    T.eq(v.y, 4)
  end)

  T.it("defaults to zero", function()
    local v = GM.vec2()
    T.eq(v.x, 0)
    T.eq(v.y, 0)
  end)

  T.it("add", function()
    local v = GM.vec2(1, 2):add(GM.vec2(3, 4))
    T.ok(v:eq(GM.vec2(4, 6)))
  end)

  T.it("sub", function()
    local v = GM.vec2(5, 3):sub(GM.vec2(2, 1))
    T.ok(v:eq(GM.vec2(3, 2)))
  end)

  T.it("mul scalar", function()
    local v = GM.vec2(2, 3):mul(4)
    T.ok(v:eq(GM.vec2(8, 12)))
  end)

  T.it("div scalar", function()
    local v = GM.vec2(8, 4):div(2)
    T.ok(v:eq(GM.vec2(4, 2)))
  end)

  T.it("dot", function()
    T.eq(GM.vec2(1, 2):dot(GM.vec2(3, 4)), 11)
  end)

  T.it("cross (scalar)", function()
    -- (1,0) x (0,1) = 1
    T.eq(GM.vec2(1, 0):cross(GM.vec2(0, 1)), 1)
    -- (0,1) x (1,0) = -1
    T.eq(GM.vec2(0, 1):cross(GM.vec2(1, 0)), -1)
  end)

  T.it("len and len_sq", function()
    local v = GM.vec2(3, 4)
    T.ok(near(v:len(), 5))
    T.eq(v:len_sq(), 25)
  end)

  T.it("normalize", function()
    local v = GM.vec2(3, 4):normalize()
    T.ok(near(v:len(), 1))
    T.ok(near(v.x, 0.6))
    T.ok(near(v.y, 0.8))
  end)

  T.it("normalize zero returns zero", function()
    local v = GM.vec2(0, 0):normalize()
    T.eq(v.x, 0)
    T.eq(v.y, 0)
  end)

  T.it("lerp at t=0 is self", function()
    local a = GM.vec2(1, 2)
    local b = GM.vec2(3, 4)
    T.ok(a:lerp(b, 0):eq(a))
  end)

  T.it("lerp at t=1 is other", function()
    local a = GM.vec2(1, 2)
    local b = GM.vec2(3, 4)
    T.ok(a:lerp(b, 1):eq(b))
  end)

  T.it("lerp midpoint", function()
    local v = GM.vec2(0, 0):lerp(GM.vec2(2, 4), 0.5)
    T.ok(near(v.x, 1))
    T.ok(near(v.y, 2))
  end)

  T.it("distance", function()
    T.ok(near(GM.vec2(0,0):distance(GM.vec2(3,4)), 5))
  end)

  T.it("distance_sq", function()
    T.ok(near(GM.vec2(0,0):distance_sq(GM.vec2(3,4)), 25))
  end)

  T.it("angle of (1,0) is 0", function()
    T.ok(near(GM.vec2(1, 0):angle(), 0))
  end)

  T.it("angle of (0,1) is pi/2", function()
    T.ok(near(GM.vec2(0, 1):angle(), math.pi / 2))
  end)

  T.it("rotate 90 degrees", function()
    local v = GM.vec2(1, 0):rotate(math.pi / 2)
    T.ok(near(v.x, 0))
    T.ok(near(v.y, 1))
  end)

  T.it("rotate 180 degrees", function()
    local v = GM.vec2(1, 0):rotate(math.pi)
    T.ok(near(v.x, -1))
    T.ok(near(v.y, 0))
  end)

  T.it("reflect off y-axis normal", function()
    -- incoming (1,0) reflected off normal (-1,0) → (-1,0)? No: reflect(n): v - 2*dot(v,n)*n
    -- v=(1,1), n=(0,1): v - 2*(1)*(0,1) = (1,-1)
    local v = GM.vec2(1, 1):reflect(GM.vec2(0, 1))
    T.ok(near(v.x, 1))
    T.ok(near(v.y, -1))
  end)

  T.it("perp is perpendicular", function()
    local v = GM.vec2(3, 4)
    local p = v:perp()
    T.ok(near(v:dot(p), 0))
  end)

  T.it("project onto axis", function()
    local v = GM.vec2(3, 4)
    local axis = GM.vec2(1, 0)
    local proj = v:project(axis)
    T.ok(near(proj.x, 3))
    T.ok(near(proj.y, 0))
  end)

  T.it("floor/ceil/round", function()
    local v = GM.vec2(1.3, 2.7)
    T.ok(v:floor():eq(GM.vec2(1, 2)))
    T.ok(v:ceil():eq(GM.vec2(2, 3)))
    T.ok(v:round():eq(GM.vec2(1, 3)))
  end)

  T.it("metamethod + and -", function()
    local a = GM.vec2(1, 2)
    local b = GM.vec2(3, 4)
    T.ok((a + b):eq(GM.vec2(4, 6)))
    T.ok((b - a):eq(GM.vec2(2, 2)))
  end)

  T.it("metamethod unary -", function()
    T.ok((-GM.vec2(1, -2)):eq(GM.vec2(-1, 2)))
  end)

  T.it("metamethod * scalar", function()
    T.ok((GM.vec2(2, 3) * 3):eq(GM.vec2(6, 9)))
    T.ok((3 * GM.vec2(2, 3)):eq(GM.vec2(6, 9)))
  end)

  T.it("metamethod / scalar", function()
    T.ok((GM.vec2(6, 4) / 2):eq(GM.vec2(3, 2)))
  end)

  T.it("metamethod ==", function()
    T.ok(GM.vec2(1, 2) == GM.vec2(1, 2))
    T.ok(not (GM.vec2(1, 2) == GM.vec2(1, 3)))
  end)

  T.it("tostring", function()
    T.eq(tostring(GM.vec2(1, 2)), "vec2(1, 2)")
  end)

  T.it("* vec2 raises error", function()
    local ok, err = pcall(function()
      local _ = GM.vec2(1,0) * GM.vec2(0,1)
    end)
    T.ok(not ok)
    T.ok(err:find("ambiguous") ~= nil)
  end)
end)

-- ─── vec3 ────────────────────────────────────────────────────────────────────

T.describe("vec3", function()
  T.it("constructs with x/y/z", function()
    local v = GM.vec3(1, 2, 3)
    T.eq(v.x, 1); T.eq(v.y, 2); T.eq(v.z, 3)
  end)

  T.it("add", function()
    local v = GM.vec3(1,2,3):add(GM.vec3(4,5,6))
    T.ok(v:eq(GM.vec3(5,7,9)))
  end)

  T.it("sub", function()
    local v = GM.vec3(5,7,9):sub(GM.vec3(1,2,3))
    T.ok(v:eq(GM.vec3(4,5,6)))
  end)

  T.it("mul scalar", function()
    T.ok(GM.vec3(1,2,3):mul(2):eq(GM.vec3(2,4,6)))
  end)

  T.it("div scalar", function()
    T.ok(GM.vec3(2,4,6):div(2):eq(GM.vec3(1,2,3)))
  end)

  T.it("dot", function()
    T.eq(GM.vec3(1,2,3):dot(GM.vec3(4,5,6)), 32)
  end)

  T.it("cross produces orthogonal vector", function()
    local a = GM.vec3(1, 0, 0)
    local b = GM.vec3(0, 1, 0)
    local c = a:cross(b)
    -- should be (0,0,1)
    T.ok(near(c.x, 0))
    T.ok(near(c.y, 0))
    T.ok(near(c.z, 1))
    -- orthogonal to both inputs
    T.ok(near(c:dot(a), 0))
    T.ok(near(c:dot(b), 0))
  end)

  T.it("cross anti-commutative", function()
    local a = GM.vec3(1, 2, 3)
    local b = GM.vec3(4, 5, 6)
    local ab = a:cross(b)
    local ba = b:cross(a)
    T.ok(near(ab.x, -ba.x))
    T.ok(near(ab.y, -ba.y))
    T.ok(near(ab.z, -ba.z))
  end)

  T.it("len", function()
    T.ok(near(GM.vec3(1,2,2):len(), 3))
  end)

  T.it("normalize", function()
    local v = GM.vec3(1, 2, 2):normalize()
    T.ok(near(v:len(), 1))
  end)

  T.it("lerp", function()
    local v = GM.vec3(0,0,0):lerp(GM.vec3(2,4,6), 0.5)
    T.ok(near(v.x, 1)); T.ok(near(v.y, 2)); T.ok(near(v.z, 3))
  end)

  T.it("distance", function()
    T.ok(near(GM.vec3(0,0,0):distance(GM.vec3(1,2,2)), 3))
  end)

  T.it("reflect", function()
    local v = GM.vec3(1, -1, 0):reflect(GM.vec3(0, 1, 0))
    T.ok(near(v.x, 1))
    T.ok(near(v.y, 1))
    T.ok(near(v.z, 0))
  end)

  T.it("project", function()
    local v = GM.vec3(3, 4, 0):project(GM.vec3(1, 0, 0))
    T.ok(near(v.x, 3)); T.ok(near(v.y, 0)); T.ok(near(v.z, 0))
  end)

  T.it("metamethods + - unm == tostring", function()
    local a = GM.vec3(1,2,3)
    local b = GM.vec3(4,5,6)
    T.ok((a + b):eq(GM.vec3(5,7,9)))
    T.ok((b - a):eq(GM.vec3(3,3,3)))
    T.ok((-a):eq(GM.vec3(-1,-2,-3)))
    T.ok(a == GM.vec3(1,2,3))
    T.eq(tostring(GM.vec3(1,2,3)), "vec3(1, 2, 3)")
  end)

  T.it("metamethod * scalar", function()
    T.ok((GM.vec3(1,2,3) * 2):eq(GM.vec3(2,4,6)))
    T.ok((2 * GM.vec3(1,2,3)):eq(GM.vec3(2,4,6)))
  end)
end)

-- ─── mat4 ────────────────────────────────────────────────────────────────────

T.describe("mat4", function()
  T.it("identity * identity = identity", function()
    local id = GM.mat4()
    local r = id:mul(id)
    for i = 1, 16 do T.eq(r[i], id[i]) end
  end)

  T.it("translate(1,2,3) * origin gives (1,2,3,1)", function()
    local t = GM.translate(1, 2, 3)
    local x, y, z, w = t:mul_vec4(0, 0, 0, 1)
    T.ok(near(x, 1)); T.ok(near(y, 2)); T.ok(near(z, 3)); T.ok(near(w, 1))
  end)

  T.it("scale(2,3,4) * (1,1,1,1) = (2,3,4,1)", function()
    local s = GM.scale(2, 3, 4)
    local x, y, z, w = s:mul_vec4(1, 1, 1, 1)
    T.ok(near(x, 2)); T.ok(near(y, 3)); T.ok(near(z, 4)); T.ok(near(w, 1))
  end)

  T.it("rotate_z(90) rotates (1,0,0) to (0,1,0)", function()
    local r = GM.rotate_z(math.pi / 2)
    local x, y, z, w = r:mul_vec4(1, 0, 0, 1)
    T.ok(near(x, 0)); T.ok(near(y, 1)); T.ok(near(z, 0))
  end)

  T.it("rotate_x(90) rotates (0,1,0) to (0,0,1)", function()
    local r = GM.rotate_x(math.pi / 2)
    local x, y, z, w = r:mul_vec4(0, 1, 0, 1)
    T.ok(near(x, 0)); T.ok(near(y, 0)); T.ok(near(z, 1))
  end)

  T.it("rotate_y(90) rotates (0,0,1) to (1,0,0)", function()
    local r = GM.rotate_y(math.pi / 2)
    local x, y, z, _ = r:mul_vec4(0, 0, 1, 1)
    T.ok(near(x, 1)); T.ok(near(y, 0)); T.ok(near(z, 0))
  end)

  T.it("transpose of identity is identity", function()
    local id = GM.mat4()
    local t  = id:transpose()
    for i = 1, 16 do T.eq(t[i], id[i]) end
  end)

  T.it("determinant of identity is 1", function()
    T.ok(near(GM.mat4():determinant(), 1))
  end)

  T.it("inverse of identity is identity", function()
    local inv = GM.mat4():inverse()
    local id  = GM.mat4()
    for i = 1, 16 do T.ok(near(inv[i], id[i])) end
  end)

  T.it("M * M^-1 = identity", function()
    local m = GM.translate(1, 2, 3)
    local inv = m:inverse()
    local r = m:mul(inv)
    local id = GM.mat4()
    for i = 1, 16 do T.ok(nearf(r[i], id[i], 1e-10)) end
  end)

  T.it("perspective produces non-trivial matrix", function()
    local p = GM.perspective(math.pi / 4, 16/9, 0.1, 100)
    -- [1][1] != 1 (it's the focal length divided by aspect)
    T.ok(p[1] ~= 1)
    -- w-divide slot (col 2, row 3) = index 12 in column-major layout
    T.ok(near(p[12], -1))
  end)

  T.it("ortho projection", function()
    local o = GM.ortho(-1, 1, -1, 1, -1, 1)
    -- scale x: 2/(right-left) = 2/2 = 1; col-major: [1]
    T.ok(near(o[1], 1))
  end)

  T.it("mul_vec4 with table input", function()
    local t = GM.translate(5, 6, 7)
    local x, y, z, w = t:mul_vec4({0, 0, 0, 1})
    T.ok(near(x, 5)); T.ok(near(y, 6)); T.ok(near(z, 7))
  end)

  T.it("metamethod * chains transforms", function()
    local t  = GM.translate(1, 0, 0)
    local t2 = GM.translate(2, 0, 0)
    local r  = t * t2
    local x, y, z, w = r:mul_vec4(0, 0, 0, 1)
    T.ok(near(x, 3))
  end)
end)

-- ─── quaternion ──────────────────────────────────────────────────────────────

T.describe("quat", function()
  T.it("identity has w=1", function()
    local q = GM.quat_identity()
    T.eq(q.w, 1); T.eq(q.x, 0); T.eq(q.y, 0); T.eq(q.z, 0)
  end)

  T.it("len of unit quat is 1", function()
    T.ok(near(GM.quat_identity():len(), 1))
  end)

  T.it("normalize already-unit quat", function()
    local q = GM.quat_identity():normalize()
    T.ok(near(q:len(), 1))
  end)

  T.it("conjugate negates xyz", function()
    local q = GM.quat(1, 2, 3, 4):normalize()
    local c = q:conjugate()
    T.ok(near(c.w, q.w))
    T.ok(near(c.x, -q.x))
    T.ok(near(c.y, -q.y))
    T.ok(near(c.z, -q.z))
  end)

  T.it("q * q^-1 = identity", function()
    local q = GM.quat_from_axis_angle(GM.vec3(0,1,0), math.pi/3)
    local inv = q:inverse()
    local r = q * inv
    T.ok(near(r.w, 1)); T.ok(near(r.x, 0)); T.ok(near(r.y, 0)); T.ok(near(r.z, 0))
  end)

  T.it("dot of quat with itself = 1 for unit quat", function()
    local q = GM.quat_identity()
    T.ok(near(q:dot(q), 1))
  end)

  T.it("from_axis_angle 90deg around Y rotates X to -Z", function()
    local q = GM.quat_from_axis_angle(GM.vec3(0, 1, 0), math.pi / 2)
    local m = q:to_mat4()
    local x, y, z, _ = m:mul_vec4(1, 0, 0, 1)
    T.ok(near(x, 0)); T.ok(near(y, 0)); T.ok(near(z, -1))
  end)

  T.it("to_axis_angle round-trips", function()
    local axis_in = GM.vec3(0, 1, 0)
    local angle_in = math.pi / 4
    local q = GM.quat_from_axis_angle(axis_in, angle_in)
    local axis_out, angle_out = q:to_axis_angle()
    T.ok(near(angle_out, angle_in))
    T.ok(near(axis_out.x, axis_in.x))
    T.ok(near(axis_out.y, axis_in.y))
    T.ok(near(axis_out.z, axis_in.z))
  end)

  T.it("identity to_mat4 is identity matrix", function()
    local m  = GM.quat_identity():to_mat4()
    local id = GM.mat4()
    for i = 1, 16 do T.ok(near(m[i], id[i])) end
  end)

  T.it("slerp at t=0 returns self", function()
    local q1 = GM.quat_identity()
    local q2 = GM.quat_from_axis_angle(GM.vec3(0,1,0), math.pi)
    local r  = q1:slerp(q2, 0)
    T.ok(near(r.w, q1.w)); T.ok(near(r.x, q1.x))
    T.ok(near(r.y, q1.y)); T.ok(near(r.z, q1.z))
  end)

  T.it("slerp at t=1 returns other", function()
    local q1 = GM.quat_identity()
    local q2 = GM.quat_from_axis_angle(GM.vec3(0,1,0), math.pi / 2)
    local r  = q1:slerp(q2, 1)
    T.ok(near(r.w, q2.w)); T.ok(near(r.x, q2.x))
    T.ok(near(r.y, q2.y)); T.ok(near(r.z, q2.z))
  end)

  T.it("slerp midpoint is unit quat", function()
    local q1 = GM.quat_identity()
    local q2 = GM.quat_from_axis_angle(GM.vec3(0,1,0), math.pi / 2)
    local r  = q1:slerp(q2, 0.5)
    T.ok(nearf(r:len(), 1, 1e-5))
  end)

  T.it("quat_from_euler identity (0,0,0) ~ identity", function()
    local q = GM.quat_from_euler(0, 0, 0)
    T.ok(near(q.w, 1)); T.ok(near(q.x, 0)); T.ok(near(q.y, 0)); T.ok(near(q.z, 0))
  end)

  T.it("mul identity * q = q", function()
    local id = GM.quat_identity()
    local q  = GM.quat_from_axis_angle(GM.vec3(1,0,0), math.pi/4)
    local r  = id * q
    T.ok(near(r.w, q.w)); T.ok(near(r.x, q.x))
    T.ok(near(r.y, q.y)); T.ok(near(r.z, q.z))
  end)
end)

-- ─── interpolation ───────────────────────────────────────────────────────────

T.describe("interpolation", function()
  T.it("lerp scalars", function()
    T.ok(near(GM.lerp(0, 10, 0.3), 3))
    T.ok(near(GM.lerp(0, 10, 0),   0))
    T.ok(near(GM.lerp(0, 10, 1),   10))
  end)

  T.it("clamp", function()
    T.eq(GM.clamp(5, 0, 10),  5)
    T.eq(GM.clamp(-1, 0, 10), 0)
    T.eq(GM.clamp(15, 0, 10), 10)
  end)

  T.it("smoothstep at edges is 0/1", function()
    T.ok(near(GM.smoothstep(0, 1, 0), 0))
    T.ok(near(GM.smoothstep(0, 1, 1), 1))
  end)

  T.it("smoothstep at midpoint is 0.5", function()
    T.ok(near(GM.smoothstep(0, 1, 0.5), 0.5))
  end)

  T.it("smoothstep is monotone: 0.25 < 0.5 < 0.75", function()
    local a = GM.smoothstep(0, 1, 0.25)
    local b = GM.smoothstep(0, 1, 0.5)
    local c = GM.smoothstep(0, 1, 0.75)
    T.ok(a < b and b < c)
  end)

  T.it("smootherstep at edges is 0/1", function()
    T.ok(near(GM.smootherstep(0, 1, 0), 0))
    T.ok(near(GM.smootherstep(0, 1, 1), 1))
  end)

  T.it("smootherstep at midpoint is 0.5", function()
    T.ok(near(GM.smootherstep(0, 1, 0.5), 0.5))
  end)

  T.it("sign", function()
    T.eq(GM.sign(5),  1)
    T.eq(GM.sign(-3), -1)
    T.eq(GM.sign(0),  0)
  end)
end)

-- ─── AABB ────────────────────────────────────────────────────────────────────

T.describe("aabb", function()
  T.it("contains point inside", function()
    local box = GM.aabb(GM.vec3(0,0,0), GM.vec3(2,2,2))
    T.ok(box:contains(GM.vec3(1,1,1)))
  end)

  T.it("contains point on boundary", function()
    local box = GM.aabb(GM.vec3(0,0,0), GM.vec3(2,2,2))
    T.ok(box:contains(GM.vec3(0,0,0)))
    T.ok(box:contains(GM.vec3(2,2,2)))
  end)

  T.it("does not contain point outside", function()
    local box = GM.aabb(GM.vec3(0,0,0), GM.vec3(2,2,2))
    T.ok(not box:contains(GM.vec3(3,1,1)))
    T.ok(not box:contains(GM.vec3(-1,1,1)))
  end)

  T.it("intersects overlapping boxes", function()
    local a = GM.aabb(GM.vec3(0,0,0), GM.vec3(2,2,2))
    local b = GM.aabb(GM.vec3(1,1,1), GM.vec3(3,3,3))
    T.ok(a:intersects(b))
    T.ok(b:intersects(a))
  end)

  T.it("does not intersect disjoint boxes", function()
    local a = GM.aabb(GM.vec3(0,0,0), GM.vec3(1,1,1))
    local b = GM.aabb(GM.vec3(2,2,2), GM.vec3(3,3,3))
    T.ok(not a:intersects(b))
  end)

  T.it("union spans both boxes", function()
    local a = GM.aabb(GM.vec3(0,0,0), GM.vec3(1,1,1))
    local b = GM.aabb(GM.vec3(2,2,2), GM.vec3(3,3,3))
    local u = a:union(b)
    T.ok(u:contains(GM.vec3(0,0,0)))
    T.ok(u:contains(GM.vec3(3,3,3)))
    T.ok(u:contains(GM.vec3(1.5,1.5,1.5)))
  end)

  T.it("center", function()
    local box = GM.aabb(GM.vec3(0,0,0), GM.vec3(4,6,8))
    local c = box:center()
    T.ok(near(c.x, 2)); T.ok(near(c.y, 3)); T.ok(near(c.z, 4))
  end)

  T.it("size", function()
    local box = GM.aabb(GM.vec3(1,2,3), GM.vec3(4,6,9))
    local s = box:size()
    T.ok(near(s.x, 3)); T.ok(near(s.y, 4)); T.ok(near(s.z, 6))
  end)
end)

-- ─── tier ────────────────────────────────────────────────────────────────────

T.describe("module", function()
  T.it("_tier is pure", function()
    T.eq(GM._tier, "pure")
  end)
end)
