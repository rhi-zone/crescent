if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

local M = {}
M._tier = "pure"

local sqrt = math.sqrt
local sin  = math.sin
local cos  = math.cos
local abs  = math.abs
local floor = math.floor
local ceil  = math.ceil
local pi    = math.pi
local atan2 = math.atan2
local max   = math.max
local min   = math.min

-- ─── vec2 ────────────────────────────────────────────────────────────────────

local vec2_mt = {}
vec2_mt.__index = vec2_mt

function M.vec2(x, y)
  return setmetatable({ x = x or 0, y = y or 0 }, vec2_mt)
end

function vec2_mt:add(o)   return M.vec2(self.x + o.x, self.y + o.y) end
function vec2_mt:sub(o)   return M.vec2(self.x - o.x, self.y - o.y) end
function vec2_mt:mul(s)   return M.vec2(self.x * s,   self.y * s)   end
function vec2_mt:div(s)   return M.vec2(self.x / s,   self.y / s)   end
function vec2_mt:dot(o)   return self.x * o.x + self.y * o.y        end
function vec2_mt:cross(o) return self.x * o.y - self.y * o.x        end  -- scalar
function vec2_mt:len_sq() return self.x * self.x + self.y * self.y  end
function vec2_mt:len()    return sqrt(self:len_sq())                 end

function vec2_mt:normalize()
  local l = self:len()
  if l == 0 then return M.vec2(0, 0) end
  return M.vec2(self.x / l, self.y / l)
end

function vec2_mt:distance(o)
  local dx, dy = self.x - o.x, self.y - o.y
  return sqrt(dx*dx + dy*dy)
end

function vec2_mt:distance_sq(o)
  local dx, dy = self.x - o.x, self.y - o.y
  return dx*dx + dy*dy
end

function vec2_mt:lerp(o, t)
  return M.vec2(self.x + (o.x - self.x) * t, self.y + (o.y - self.y) * t)
end

function vec2_mt:angle()
  return atan2(self.y, self.x)
end

function vec2_mt:rotate(a)
  local c, s = cos(a), sin(a)
  return M.vec2(self.x * c - self.y * s, self.x * s + self.y * c)
end

function vec2_mt:reflect(n)
  local d = 2 * self:dot(n)
  return M.vec2(self.x - d * n.x, self.y - d * n.y)
end

function vec2_mt:project(o)
  local d = o:dot(o)
  if d == 0 then return M.vec2(0, 0) end
  local s = self:dot(o) / d
  return M.vec2(o.x * s, o.y * s)
end

function vec2_mt:perp()
  return M.vec2(-self.y, self.x)
end

function vec2_mt:floor()
  return M.vec2(floor(self.x), floor(self.y))
end

function vec2_mt:ceil()
  return M.vec2(ceil(self.x), ceil(self.y))
end

function vec2_mt:round()
  return M.vec2(floor(self.x + 0.5), floor(self.y + 0.5))
end

function vec2_mt:eq(o)
  return self.x == o.x and self.y == o.y
end

function vec2_mt:__add(o)      return self:add(o)           end
function vec2_mt:__sub(o)      return self:sub(o)           end
function vec2_mt:__unm()       return M.vec2(-self.x, -self.y) end
function vec2_mt:__eq(o)       return self:eq(o)            end
function vec2_mt:__tostring()
  return "vec2(" .. self.x .. ", " .. self.y .. ")"
end
function vec2_mt.__mul(a, b)
  if type(a) == "number" then return b:mul(a) end
  if type(b) == "number" then return a:mul(b) end
  error("vec2 * vec2 is ambiguous: use :dot() or :cross() explicitly", 2)
end
function vec2_mt.__div(a, b)
  if type(b) == "number" then return a:div(b) end
  error("vec2 / vec2 is not defined", 2)
end

-- ─── vec3 ────────────────────────────────────────────────────────────────────

local vec3_mt = {}
vec3_mt.__index = vec3_mt

function M.vec3(x, y, z)
  return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, vec3_mt)
end

function vec3_mt:add(o)   return M.vec3(self.x+o.x, self.y+o.y, self.z+o.z)   end
function vec3_mt:sub(o)   return M.vec3(self.x-o.x, self.y-o.y, self.z-o.z)   end
function vec3_mt:mul(s)   return M.vec3(self.x*s,   self.y*s,   self.z*s)      end
function vec3_mt:div(s)   return M.vec3(self.x/s,   self.y/s,   self.z/s)      end
function vec3_mt:dot(o)   return self.x*o.x + self.y*o.y + self.z*o.z          end
function vec3_mt:len_sq() return self.x*self.x + self.y*self.y + self.z*self.z end
function vec3_mt:len()    return sqrt(self:len_sq())                            end

function vec3_mt:cross(o)
  return M.vec3(
    self.y * o.z - self.z * o.y,
    self.z * o.x - self.x * o.z,
    self.x * o.y - self.y * o.x
  )
end

function vec3_mt:normalize()
  local l = self:len()
  if l == 0 then return M.vec3(0, 0, 0) end
  return M.vec3(self.x/l, self.y/l, self.z/l)
end

function vec3_mt:lerp(o, t)
  return M.vec3(
    self.x + (o.x - self.x) * t,
    self.y + (o.y - self.y) * t,
    self.z + (o.z - self.z) * t
  )
end

function vec3_mt:distance(o)
  local dx, dy, dz = self.x-o.x, self.y-o.y, self.z-o.z
  return sqrt(dx*dx + dy*dy + dz*dz)
end

function vec3_mt:distance_sq(o)
  local dx, dy, dz = self.x-o.x, self.y-o.y, self.z-o.z
  return dx*dx + dy*dy + dz*dz
end

function vec3_mt:reflect(n)
  local d = 2 * self:dot(n)
  return M.vec3(self.x - d*n.x, self.y - d*n.y, self.z - d*n.z)
end

function vec3_mt:project(o)
  local d = o:dot(o)
  if d == 0 then return M.vec3(0, 0, 0) end
  local s = self:dot(o) / d
  return M.vec3(o.x*s, o.y*s, o.z*s)
end

function vec3_mt:eq(o)
  return self.x == o.x and self.y == o.y and self.z == o.z
end

function vec3_mt:__add(o)  return self:add(o)                    end
function vec3_mt:__sub(o)  return self:sub(o)                    end
function vec3_mt:__unm()   return M.vec3(-self.x, -self.y, -self.z) end
function vec3_mt:__eq(o)   return self:eq(o)                     end
function vec3_mt:__tostring()
  return "vec3(" .. self.x .. ", " .. self.y .. ", " .. self.z .. ")"
end
function vec3_mt.__mul(a, b)
  if type(a) == "number" then return b:mul(a) end
  if type(b) == "number" then return a:mul(b) end
  error("vec3 * vec3 is ambiguous: use :dot() or :cross() explicitly", 2)
end
function vec3_mt.__div(a, b)
  if type(b) == "number" then return a:div(b) end
  error("vec3 / vec3 is not defined", 2)
end

-- ─── mat4 ────────────────────────────────────────────────────────────────────
-- Column-major: index = col*4 + row + 1 (1-indexed Lua arrays)
-- m[1..4] = col 0, m[5..8] = col 1, m[9..12] = col 2, m[13..16] = col 3

local mat4_mt = {}
mat4_mt.__index = mat4_mt

-- identity
function M.mat4()
  return setmetatable({
    1,0,0,0,
    0,1,0,0,
    0,0,1,0,
    0,0,0,1,
  }, mat4_mt)
end

function M.mat4_from(arr)
  local m = {}
  for i = 1, 16 do m[i] = arr[i] or 0 end
  return setmetatable(m, mat4_mt)
end

-- m[col*4 + row + 1], col=0..3, row=0..3
local function mat4_get(m, col, row) return m[col*4 + row + 1] end
local function mat4_set(m, col, row, v) m[col*4 + row + 1] = v end

function mat4_mt:mul(o)
  local r = {}
  for col = 0, 3 do
    for row = 0, 3 do
      local s = 0
      for k = 0, 3 do
        s = s + mat4_get(self, k, row) * mat4_get(o, col, k)
      end
      r[col*4 + row + 1] = s
    end
  end
  return setmetatable(r, mat4_mt)
end

function mat4_mt:mul_vec4(x, y, z, w)
  -- accepts (x,y,z,w) or a table {x,y,z,w}
  local vx, vy, vz, vw
  if type(x) == "table" then
    vx, vy, vz, vw = x[1], x[2], x[3], x[4]
  else
    vx, vy, vz, vw = x, y, z, w
  end
  local m = self
  return
    m[1]*vx + m[5]*vy + m[9]*vz  + m[13]*vw,
    m[2]*vx + m[6]*vy + m[10]*vz + m[14]*vw,
    m[3]*vx + m[7]*vy + m[11]*vz + m[15]*vw,
    m[4]*vx + m[8]*vy + m[12]*vz + m[16]*vw
end

function mat4_mt:transpose()
  local m = self
  return setmetatable({
    m[1],  m[5],  m[9],  m[13],
    m[2],  m[6],  m[10], m[14],
    m[3],  m[7],  m[11], m[15],
    m[4],  m[8],  m[12], m[16],
  }, mat4_mt)
end

function mat4_mt:determinant()
  local m = self
  local a00,a01,a02,a03 = m[1],m[2],m[3],m[4]
  local a10,a11,a12,a13 = m[5],m[6],m[7],m[8]
  local a20,a21,a22,a23 = m[9],m[10],m[11],m[12]
  local a30,a31,a32,a33 = m[13],m[14],m[15],m[16]
  -- cofactor expansion
  local b00 = a00*a11 - a01*a10
  local b01 = a00*a12 - a02*a10
  local b02 = a00*a13 - a03*a10
  local b03 = a01*a12 - a02*a11
  local b04 = a01*a13 - a03*a11
  local b05 = a02*a13 - a03*a12
  local b06 = a20*a31 - a21*a30
  local b07 = a20*a32 - a22*a30
  local b08 = a20*a33 - a23*a30
  local b09 = a21*a32 - a22*a31
  local b10 = a21*a33 - a23*a31
  local b11 = a22*a33 - a23*a32
  return b00*b11 - b01*b10 + b02*b09 + b03*b08 - b04*b07 + b05*b06
end

function mat4_mt:inverse()
  local m = self
  local a00,a01,a02,a03 = m[1],m[2],m[3],m[4]
  local a10,a11,a12,a13 = m[5],m[6],m[7],m[8]
  local a20,a21,a22,a23 = m[9],m[10],m[11],m[12]
  local a30,a31,a32,a33 = m[13],m[14],m[15],m[16]
  local b00 = a00*a11 - a01*a10
  local b01 = a00*a12 - a02*a10
  local b02 = a00*a13 - a03*a10
  local b03 = a01*a12 - a02*a11
  local b04 = a01*a13 - a03*a11
  local b05 = a02*a13 - a03*a12
  local b06 = a20*a31 - a21*a30
  local b07 = a20*a32 - a22*a30
  local b08 = a20*a33 - a23*a30
  local b09 = a21*a32 - a22*a31
  local b10 = a21*a33 - a23*a31
  local b11 = a22*a33 - a23*a32
  local det = b00*b11 - b01*b10 + b02*b09 + b03*b08 - b04*b07 + b05*b06
  if det == 0 then return nil, "matrix is singular" end
  local inv = 1 / det
  return setmetatable({
    (a11*b11 - a12*b10 + a13*b09)*inv,
    (a02*b10 - a01*b11 - a03*b09)*inv,
    (a31*b05 - a32*b04 + a33*b03)*inv,
    (a22*b04 - a21*b05 - a23*b03)*inv,
    (a12*b08 - a10*b11 - a13*b07)*inv,
    (a00*b11 - a02*b08 + a03*b07)*inv,
    (a32*b02 - a30*b05 - a33*b01)*inv,
    (a20*b05 - a22*b02 + a23*b01)*inv,
    (a10*b10 - a11*b08 + a13*b06)*inv,
    (a01*b08 - a00*b10 - a03*b06)*inv,
    (a30*b04 - a31*b02 + a33*b00)*inv,
    (a21*b02 - a20*b04 - a23*b00)*inv,
    (a11*b07 - a10*b09 - a12*b06)*inv,
    (a00*b09 - a01*b07 + a02*b06)*inv,
    (a31*b01 - a30*b03 - a32*b00)*inv,
    (a20*b03 - a21*b01 + a22*b00)*inv,
  }, mat4_mt)
end

function mat4_mt:__mul(o) return self:mul(o) end

function mat4_mt:__tostring()
  local m = self
  return string.format(
    "mat4[%.4f %.4f %.4f %.4f | %.4f %.4f %.4f %.4f | %.4f %.4f %.4f %.4f | %.4f %.4f %.4f %.4f]",
    m[1],m[5],m[9],m[13], m[2],m[6],m[10],m[14],
    m[3],m[7],m[11],m[15], m[4],m[8],m[12],m[16]
  )
end

-- ─── transforms ──────────────────────────────────────────────────────────────

function M.translate(x, y, z)
  return setmetatable({
    1,0,0,0,
    0,1,0,0,
    0,0,1,0,
    x,y,z,1,
  }, mat4_mt)
end

function M.scale(x, y, z)
  return setmetatable({
    x,0,0,0,
    0,y,0,0,
    0,0,z,0,
    0,0,0,1,
  }, mat4_mt)
end

function M.rotate_x(a)
  local c, s = cos(a), sin(a)
  return setmetatable({
    1, 0, 0, 0,
    0, c, s, 0,
    0,-s, c, 0,
    0, 0, 0, 1,
  }, mat4_mt)
end

function M.rotate_y(a)
  local c, s = cos(a), sin(a)
  return setmetatable({
    c, 0,-s, 0,
    0, 1, 0, 0,
    s, 0, c, 0,
    0, 0, 0, 1,
  }, mat4_mt)
end

function M.rotate_z(a)
  local c, s = cos(a), sin(a)
  return setmetatable({
    c, s, 0, 0,
   -s, c, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
  }, mat4_mt)
end

function M.perspective(fov, aspect, near, far)
  local f = 1 / math.tan(fov * 0.5)
  local nf = 1 / (near - far)
  return setmetatable({
    f/aspect, 0, 0,                    0,
    0,        f, 0,                    0,
    0,        0, (far+near)*nf,       -1,
    0,        0, 2*far*near*nf,        0,
  }, mat4_mt)
end

function M.ortho(left, right, bottom, top, near, far)
  local lr = 1 / (left - right)
  local bt = 1 / (bottom - top)
  local nf = 1 / (near - far)
  return setmetatable({
    -2*lr,        0,          0,     0,
     0,          -2*bt,       0,     0,
     0,           0,          2*nf,  0,
    (left+right)*lr, (top+bottom)*bt, (far+near)*nf, 1,
  }, mat4_mt)
end

function M.look_at(eye, center, up)
  local fx = center.x - eye.x
  local fy = center.y - eye.y
  local fz = center.z - eye.z
  local fl = sqrt(fx*fx + fy*fy + fz*fz)
  if fl == 0 then return M.mat4() end
  fx, fy, fz = fx/fl, fy/fl, fz/fl

  local sx = fy * up.z - fz * up.y
  local sy = fz * up.x - fx * up.z
  local sz = fx * up.y - fy * up.x
  local sl = sqrt(sx*sx + sy*sy + sz*sz)
  if sl == 0 then return M.mat4() end
  sx, sy, sz = sx/sl, sy/sl, sz/sl

  local ux = sy * fz - sz * fy
  local uy = sz * fx - sx * fz
  local uz = sx * fy - sy * fx

  return setmetatable({
    sx,  ux, -fx, 0,
    sy,  uy, -fy, 0,
    sz,  uz, -fz, 0,
    -(sx*eye.x + sy*eye.y + sz*eye.z),
    -(ux*eye.x + uy*eye.y + uz*eye.z),
    -(-fx*eye.x + -fy*eye.y + -fz*eye.z),
    1,
  }, mat4_mt)
end

-- ─── quaternion ──────────────────────────────────────────────────────────────

local quat_mt = {}
quat_mt.__index = quat_mt

function M.quat(w, x, y, z)
  return setmetatable({ w = w or 1, x = x or 0, y = y or 0, z = z or 0 }, quat_mt)
end

function M.quat_identity()
  return M.quat(1, 0, 0, 0)
end

function quat_mt:len_sq()
  return self.w*self.w + self.x*self.x + self.y*self.y + self.z*self.z
end

function quat_mt:len()
  return sqrt(self:len_sq())
end

function quat_mt:normalize()
  local l = self:len()
  if l == 0 then return M.quat(1, 0, 0, 0) end
  return M.quat(self.w/l, self.x/l, self.y/l, self.z/l)
end

function quat_mt:conjugate()
  return M.quat(self.w, -self.x, -self.y, -self.z)
end

function quat_mt:inverse()
  local lsq = self:len_sq()
  if lsq == 0 then return nil, "zero quaternion has no inverse" end
  return M.quat(self.w/lsq, -self.x/lsq, -self.y/lsq, -self.z/lsq)
end

function quat_mt:dot(o)
  return self.w*o.w + self.x*o.x + self.y*o.y + self.z*o.z
end

function quat_mt:mul(o)
  local aw, ax, ay, az = self.w, self.x, self.y, self.z
  local bw, bx, by, bz = o.w,   o.x,   o.y,   o.z
  return M.quat(
    aw*bw - ax*bx - ay*by - az*bz,
    aw*bx + ax*bw + ay*bz - az*by,
    aw*by - ax*bz + ay*bw + az*bx,
    aw*bz + ax*by - ay*bx + az*bw
  )
end

function quat_mt:slerp(o, t)
  local dot = self:dot(o)
  -- clamp dot to [-1,1]
  if dot < -1 then dot = -1 elseif dot > 1 then dot = 1 end
  -- if quats are in opposite hemispheres, negate one
  local bw, bx, by, bz = o.w, o.x, o.y, o.z
  if dot < 0 then
    dot = -dot
    bw, bx, by, bz = -bw, -bx, -by, -bz
  end
  -- if nearly identical, lerp
  if dot > 0.9995 then
    local q = M.quat(
      self.w + (bw - self.w) * t,
      self.x + (bx - self.x) * t,
      self.y + (by - self.y) * t,
      self.z + (bz - self.z) * t
    )
    return q:normalize()
  end
  local theta0 = math.acos(dot)
  local theta  = theta0 * t
  local sin0   = sin(theta0)
  local sa = sin(theta0 - theta) / sin0
  local sb = sin(theta)          / sin0
  return M.quat(
    sa*self.w + sb*bw,
    sa*self.x + sb*bx,
    sa*self.y + sb*by,
    sa*self.z + sb*bz
  )
end

function quat_mt:to_mat4()
  local w, x, y, z = self.w, self.x, self.y, self.z
  local x2, y2, z2 = x+x, y+y, z+z
  local xx, yy, zz = x*x2, y*y2, z*z2
  local xy, xz, yz = x*y2, x*z2, y*z2
  local wx, wy, wz = w*x2, w*y2, w*z2
  return setmetatable({
    1-(yy+zz), xy+wz,     xz-wy,     0,
    xy-wz,     1-(xx+zz), yz+wx,     0,
    xz+wy,     yz-wx,     1-(xx+yy), 0,
    0,         0,         0,         1,
  }, mat4_mt)
end

function quat_mt:to_axis_angle()
  local q = self:normalize()
  local w = q.w
  if w > 1 then w = 1 elseif w < -1 then w = -1 end
  local angle = 2 * math.acos(w)
  local s = sqrt(1 - w*w)
  if s < 1e-8 then
    return M.vec3(1, 0, 0), angle
  end
  return M.vec3(q.x/s, q.y/s, q.z/s), angle
end

function M.quat_from_axis_angle(axis, angle)
  local a = axis:normalize()
  local s = sin(angle * 0.5)
  return M.quat(cos(angle * 0.5), a.x*s, a.y*s, a.z*s)
end

function M.quat_from_euler(pitch, yaw, roll)
  local cp, sp = cos(pitch*0.5), sin(pitch*0.5)
  local cy, sy = cos(yaw*0.5),   sin(yaw*0.5)
  local cr, sr = cos(roll*0.5),  sin(roll*0.5)
  return M.quat(
    cr*cp*cy + sr*sp*sy,
    sr*cp*cy - cr*sp*sy,
    cr*sp*cy + sr*cp*sy,
    cr*cp*sy - sr*sp*cy
  )
end

function quat_mt:__mul(o) return self:mul(o) end
function quat_mt:__tostring()
  return "quat(" .. self.w .. ", " .. self.x .. ", " .. self.y .. ", " .. self.z .. ")"
end

-- ─── interpolation ───────────────────────────────────────────────────────────

function M.lerp(a, b, t)
  return a + (b - a) * t
end

function M.clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

function M.smoothstep(edge0, edge1, t)
  local x = M.clamp((t - edge0) / (edge1 - edge0), 0, 1)
  return x * x * (3 - 2 * x)
end

function M.smootherstep(edge0, edge1, t)
  local x = M.clamp((t - edge0) / (edge1 - edge0), 0, 1)
  return x * x * x * (x * (x * 6 - 15) + 10)
end

function M.sign(x)
  if x > 0 then return 1 elseif x < 0 then return -1 else return 0 end
end

-- ─── AABB ────────────────────────────────────────────────────────────────────

local aabb_mt = {}
aabb_mt.__index = aabb_mt

function M.aabb(min_v, max_v)
  return setmetatable({ min = min_v, max = max_v }, aabb_mt)
end

function aabb_mt:contains(p)
  return p.x >= self.min.x and p.x <= self.max.x
     and p.y >= self.min.y and p.y <= self.max.y
     and p.z >= self.min.z and p.z <= self.max.z
end

function aabb_mt:intersects(o)
  return self.min.x <= o.max.x and self.max.x >= o.min.x
     and self.min.y <= o.max.y and self.max.y >= o.min.y
     and self.min.z <= o.max.z and self.max.z >= o.min.z
end

function aabb_mt:union(o)
  return M.aabb(
    M.vec3(min(self.min.x, o.min.x), min(self.min.y, o.min.y), min(self.min.z, o.min.z)),
    M.vec3(max(self.max.x, o.max.x), max(self.max.y, o.max.y), max(self.max.z, o.max.z))
  )
end

function aabb_mt:center()
  return M.vec3(
    (self.min.x + self.max.x) * 0.5,
    (self.min.y + self.max.y) * 0.5,
    (self.min.z + self.max.z) * 0.5
  )
end

function aabb_mt:size()
  return M.vec3(
    self.max.x - self.min.x,
    self.max.y - self.min.y,
    self.max.z - self.min.z
  )
end

return M
