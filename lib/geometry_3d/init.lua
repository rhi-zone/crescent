if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

--:: Vec3 = { x: number, y: number, z: number }
--:: Ray3 = { origin: Vec3, dir: Vec3 }
--:: Plane3 = { n: Vec3, d: number }
--:: AABB3 = { min: Vec3, max: Vec3 }
--:: Sphere3 = { c: Vec3, r: number }
--:: Triangle3 = { a: Vec3, b: Vec3, c: Vec3 }
--:: Quat = { w: number, x: number, y: number, z: number }
--:: Mat4 = { [integer]: number }
--:: Face3 = { [integer]: integer }
--:: Mesh3 = { vertices: { [integer]: Vec3 }, faces: { [integer]: Face3 } }

local sqrt = math.sqrt
local abs  = math.abs
local cos  = math.cos
local sin  = math.sin
local pi   = math.pi
local huge = math.huge
local max  = math.max
local min  = math.min

-- ============================================================================
-- VECTOR3 OPERATIONS
-- ============================================================================

--: (number, number, number) -> Vec3
function M.vec3(x, y, z)
  return {x = x, y = y, z = z}
end

--: (Vec3, Vec3) -> Vec3
function M.add3(a, b)
  return {x = a.x + b.x, y = a.y + b.y, z = a.z + b.z}
end

--: (Vec3, Vec3) -> Vec3
function M.sub3(a, b)
  return {x = a.x - b.x, y = a.y - b.y, z = a.z - b.z}
end

--: (Vec3, number) -> Vec3
function M.scale3(v, s)
  return {x = v.x * s, y = v.y * s, z = v.z * s}
end

--: (Vec3, Vec3) -> number
function M.dot3(a, b)
  return a.x * b.x + a.y * b.y + a.z * b.z
end

--: (Vec3, Vec3) -> Vec3
function M.cross3(a, b)
  return {
    x = a.y * b.z - a.z * b.y,
    y = a.z * b.x - a.x * b.z,
    z = a.x * b.y - a.y * b.x,
  }
end

--: (Vec3) -> number
function M.len3(v)
  return sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

--: (Vec3) -> Vec3
function M.norm3(v)
  local l = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
  if l == 0 then return {x = 0, y = 0, z = 0} end
  local inv = 1 / l
  return {x = v.x * inv, y = v.y * inv, z = v.z * inv}
end

--: (Vec3, Vec3, number) -> Vec3
function M.lerp3(a, b, t)
  local s = 1 - t
  return {x = s * a.x + t * b.x, y = s * a.y + t * b.y, z = s * a.z + t * b.z}
end

--: (Vec3) -> Vec3
function M.neg3(v)
  return {x = -v.x, y = -v.y, z = -v.z}
end

-- ============================================================================
-- RAY
-- ============================================================================

-- Ray: {origin={x,y,z}, dir={x,y,z}} (dir should be normalized)
--: (Vec3, Vec3) -> Ray3
function M.ray(origin, direction)
  return {origin = origin, dir = direction}
end

-- Ray-triangle intersection (Möller-Trumbore)
-- Returns: t (distance along ray), u, v (barycentric) or nil
--: (Ray3, Vec3, Vec3, Vec3) -> (number | nil, number | nil, number | nil)
function M.ray_triangle(ray, v0, v1, v2)
  local EPSILON = 1e-8
  local e1 = M.sub3(v1, v0)
  local e2 = M.sub3(v2, v0)
  local h = M.cross3(ray.dir, e2)
  local a = M.dot3(e1, h)
  if abs(a) < EPSILON then return nil end  -- parallel
  local f = 1.0 / a
  local s = M.sub3(ray.origin, v0)
  local u = f * M.dot3(s, h)
  if u < 0 or u > 1 then return nil end
  local q = M.cross3(s, e1)
  local v = f * M.dot3(ray.dir, q)
  if v < 0 or u + v > 1 then return nil end
  local t = f * M.dot3(e2, q)
  if t < EPSILON then return nil end
  return t, u, v
end

-- Ray-sphere intersection
-- Returns: t1, t2 (near and far intersections) or nil
--: (Ray3, Vec3, number) -> (number | nil, number | nil)
function M.ray_sphere(ray, center, radius)
  local oc = M.sub3(ray.origin, center)
  local a = M.dot3(ray.dir, ray.dir)
  local b = 2 * M.dot3(oc, ray.dir)
  local c = M.dot3(oc, oc) - radius * radius
  local disc = b * b - 4 * a * c
  if disc < 0 then return nil end
  local sq = sqrt(disc)
  local inv2a = 1 / (2 * a)
  local t1 = (-b - sq) * inv2a
  local t2 = (-b + sq) * inv2a
  return t1, t2
end

-- Ray-AABB intersection (slab method)
-- aabb: {min={x,y,z}, max={x,y,z}}
-- Returns: t_near, t_far or nil if no intersection
function M.ray_aabb(ray, aabb)
  local t_near = -huge
  local t_far  =  huge

  local axes = {"x", "y", "z"}
  for _, ax in ipairs(axes) do
    local orig = ray.origin[ax]
    local dir  = ray.dir[ax]
    local lo   = aabb.min[ax]
    local hi   = aabb.max[ax]
    if abs(dir) < 1e-10 then
      -- parallel slab: ray must be inside the slab
      if orig < lo or orig > hi then return nil end
    else
      local inv = 1 / dir
      local ta = (lo - orig) * inv
      local tb = (hi - orig) * inv
      if ta > tb then ta, tb = tb, ta end
      if ta > t_near then t_near = ta end
      if tb < t_far  then t_far  = tb end
      if t_near > t_far then return nil end
    end
  end

  if t_far < 0 then return nil end  -- AABB is behind ray origin
  return t_near, t_far
end

-- Ray-plane intersection
-- plane: {normal={x,y,z}, d=number}  (n·x = d)
-- Returns: t or nil if parallel
--: (Ray3, { normal: Vec3, d: number }) -> number | nil
function M.ray_plane(ray, plane)
  local denom = M.dot3(plane.normal, ray.dir)
  if abs(denom) < 1e-10 then return nil end
  local t = (plane.d - M.dot3(plane.normal, ray.origin)) / denom
  return t
end

-- ============================================================================
-- MESH
-- ============================================================================

-- Mesh: {vertices={{x,y,z},...}, faces={{i,j,k},...}} (1-indexed)

-- Compute face normal (not normalized)
function M.face_normal(mesh, face_idx)
  local face = mesh.faces[face_idx]
  local v0 = mesh.vertices[face[1]]
  local v1 = mesh.vertices[face[2]]
  local v2 = mesh.vertices[face[3]]
  return M.cross3(M.sub3(v1, v0), M.sub3(v2, v0))
end

-- Compute vertex normals (average of adjacent face normals)
function M.vertex_normals(mesh)
  local nv = #mesh.vertices
  local normals = {}
  for i = 1, nv do
    normals[i] = {x = 0.0, y = 0.0, z = 0.0} --[[:! Vec3]]
  end
  for _, face in ipairs(mesh.faces) do
    local v0 = mesh.vertices[face[1]]
    local v1 = mesh.vertices[face[2]]
    local v2 = mesh.vertices[face[3]]
    local n = M.cross3(M.sub3(v1, v0), M.sub3(v2, v0))
    for _, vi in ipairs(face) do
      local acc = normals[vi]
      acc.x = acc.x + n.x
      acc.y = acc.y + n.y
      acc.z = acc.z + n.z
    end
  end
  for i = 1, nv do
    normals[i] = M.norm3(normals[i])
  end
  return normals
end

-- Mesh bounding box
function M.mesh_aabb(mesh)
  local mn = {x =  huge, y =  huge, z =  huge}
  local mx = {x = -huge, y = -huge, z = -huge}
  for _, v in ipairs(mesh.vertices) do
    if v.x < mn.x then mn.x = v.x end
    if v.y < mn.y then mn.y = v.y end
    if v.z < mn.z then mn.z = v.z end
    if v.x > mx.x then mx.x = v.x end
    if v.y > mx.y then mx.y = v.y end
    if v.z > mx.z then mx.z = v.z end
  end
  return {min = mn, max = mx}
end

-- Mesh bounding sphere (approximate: center = centroid, radius = max dist)
function M.mesh_bsphere(mesh)
  local nv = #mesh.vertices
  local cx, cy, cz = 0, 0, 0
  for _, v in ipairs(mesh.vertices) do
    cx = cx + v.x
    cy = cy + v.y
    cz = cz + v.z
  end
  local inv = 1 / nv
  local center = {x = cx * inv, y = cy * inv, z = cz * inv}
  local r2 = 0
  for _, v in ipairs(mesh.vertices) do
    local dx = v.x - center.x
    local dy = v.y - center.y
    local dz = v.z - center.z
    local d2 = dx*dx + dy*dy + dz*dz
    if d2 > r2 then r2 = d2 end
  end
  return center, sqrt(r2)
end

-- Surface area of a mesh (sum of triangle areas)
function M.mesh_area(mesh)
  local area = 0.0 --[[: number]]
  for _, face in ipairs(mesh.faces) do
    local v0 = mesh.vertices[face[1]]
    local v1 = mesh.vertices[face[2]]
    local v2 = mesh.vertices[face[3]]
    local cross = M.cross3(M.sub3(v1, v0), M.sub3(v2, v0))
    area = area + M.len3(cross)
  end
  return area * 0.5
end

-- Signed volume of a closed mesh (divergence theorem)
-- Positive for outward normals, negative for inward
function M.mesh_volume(mesh)
  local vol = 0.0 --[[: number]]
  for _, face in ipairs(mesh.faces) do
    local v0 = mesh.vertices[face[1]]
    local v1 = mesh.vertices[face[2]]
    local v2 = mesh.vertices[face[3]]
    vol = vol + M.dot3(v0, M.cross3(v1, v2))
  end
  return vol / 6
end

-- Check if a point is inside a closed mesh (ray casting)
-- Uses a ray direction that avoids axis-aligned edges to reduce double-counting.
--: (Mesh3, Vec3) -> boolean
function M.point_in_mesh(mesh, point)
  -- Irrational-ratio direction avoids hitting shared edges and vertices exactly
  local ray = M.ray(point, M.norm3({x = 1, y = 0.00137, z = 0.00093}))
  local count = 0
  for _, face in ipairs(mesh.faces) do
    local v0 = mesh.vertices[face[1]]
    local v1 = mesh.vertices[face[2]]
    local v2 = mesh.vertices[face[3]]
    local t = M.ray_triangle(ray, v0, v1, v2)
    if t then count = count + 1 end
  end
  return (count % 2) == 1
end

-- ============================================================================
-- TRANSFORMATIONS — 4×4 row-major matrix (flat array of 16 numbers)
-- ============================================================================
-- Index layout (1-based): row r, col c → index (r-1)*4 + c

--: () -> Mat4
function M.mat4_identity()
  return {
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
  }
end

--: (number, number, number) -> Mat4
function M.mat4_translate(tx, ty, tz)
  return {
    1,  0,  0,  tx,
    0,  1,  0,  ty,
    0,  0,  1,  tz,
    0,  0,  0,  1,
  }
end

--: (number, number, number) -> Mat4
function M.mat4_scale(sx, sy, sz)
  return {
    sx, 0,  0,  0,
    0,  sy, 0,  0,
    0,  0,  sz, 0,
    0,  0,  0,  1,
  }
end

--: (number) -> Mat4
function M.mat4_rotate_x(angle)
  local c = cos(angle)
  local s = sin(angle)
  return {
    1,  0,  0,  0,
    0,  c, -s,  0,
    0,  s,  c,  0,
    0,  0,  0,  1,
  }
end

--: (number) -> Mat4
function M.mat4_rotate_y(angle)
  local c = cos(angle)
  local s = sin(angle)
  return {
     c,  0,  s,  0,
     0,  1,  0,  0,
    -s,  0,  c,  0,
     0,  0,  0,  1,
  }
end

--: (number) -> Mat4
function M.mat4_rotate_z(angle)
  local c = cos(angle)
  local s = sin(angle)
  return {
     c, -s,  0,  0,
     s,  c,  0,  0,
     0,  0,  1,  0,
     0,  0,  0,  1,
  }
end

-- Matrix multiply: result = a * b
--: (Mat4, Mat4) -> Mat4
function M.mat4_mul(a, b)
  local r = {}
  for row = 0, 3 do
    for col = 0, 3 do
      local sum = 0.0 --[[: number]]
      for k = 0, 3 do
        sum = sum + a[row*4 + k + 1] * b[k*4 + col + 1]
      end
      r[row*4 + col + 1] = sum
    end
  end
  return r
end

-- Apply affine transform to a point (applies translation)
--: (Mat4, Vec3) -> Vec3
function M.mat4_transform_point(mat, v)
  local x = mat[1]*v.x + mat[2]*v.y + mat[3]*v.z + mat[4]
  local y = mat[5]*v.x + mat[6]*v.y + mat[7]*v.z + mat[8]
  local z = mat[9]*v.x + mat[10]*v.y + mat[11]*v.z + mat[12]
  local w = mat[13]*v.x + mat[14]*v.y + mat[15]*v.z + mat[16]
  if w ~= 1 and w ~= 0 then
    local inv = 1 / w
    return {x = x * inv, y = y * inv, z = z * inv}
  end
  return {x = x, y = y, z = z}
end

-- Apply transform to a direction (no translation)
--: (Mat4, Vec3) -> Vec3
function M.mat4_transform_dir(mat, v)
  return {
    x = mat[1]*v.x + mat[2]*v.y + mat[3]*v.z,
    y = mat[5]*v.x + mat[6]*v.y + mat[7]*v.z,
    z = mat[9]*v.x + mat[10]*v.y + mat[11]*v.z,
  }
end

-- ============================================================================
-- QUATERNION  {w, x, y, z}
-- ============================================================================

--: (number, number, number, number) -> Quat
function M.quat(w, x, y, z)
  return {w = w, x = x, y = y, z = z}
end

--: (Vec3, number) -> Quat
function M.quat_from_axis_angle(axis, angle)
  local half = angle * 0.5
  local s = sin(half)
  local n = M.norm3(axis)
  return {w = cos(half), x = n.x * s, y = n.y * s, z = n.z * s}
end

--: (Quat, Quat) -> Quat
function M.quat_mul(a, b)
  return {
    w = a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z,
    x = a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y,
    y = a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,
    z = a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w,
  }
end

-- Rotate vector v by quaternion q using sandwich product q * v * q^-1
--: (Quat, Vec3) -> Vec3
function M.quat_rotate(q, v)
  -- t = 2 * cross(q.xyz, v)
  local qx, qy, qz = q.x, q.y, q.z
  local vx, vy, vz = v.x, v.y, v.z
  local tx = 2 * (qy * vz - qz * vy)
  local ty = 2 * (qz * vx - qx * vz)
  local tz = 2 * (qx * vy - qy * vx)
  return {
    x = vx + q.w * tx + (qy * tz - qz * ty),
    y = vy + q.w * ty + (qz * tx - qx * tz),
    z = vz + q.w * tz + (qx * ty - qy * tx),
  }
end

--: (Quat) -> Quat
function M.quat_normalize(q)
  local l = sqrt(q.w*q.w + q.x*q.x + q.y*q.y + q.z*q.z)
  if l == 0 then return {w = 1, x = 0, y = 0, z = 0} end
  local inv = 1 / l
  return {w = q.w * inv, x = q.x * inv, y = q.y * inv, z = q.z * inv}
end

--: (Quat) -> Quat
function M.quat_conjugate(q)
  return {w = q.w, x = -q.x, y = -q.y, z = -q.z}
end

--: (Quat, Quat, number) -> Quat
function M.quat_slerp(a, b, t)
  local dot = a.w*b.w + a.x*b.x + a.y*b.y + a.z*b.z
  -- Ensure shortest path
  local bw, bx, by, bz = b.w, b.x, b.y, b.z
  if dot < 0 then
    dot = -dot
    bw, bx, by, bz = -bw, -bx, -by, -bz
  end
  -- Clamp for numerical safety
  if dot > 0.9995 then
    -- Linear interpolation fallback
    local s = 1 - t
    local w = s*a.w + t*bw
    local x = s*a.x + t*bx
    local y = s*a.y + t*by
    local z = s*a.z + t*bz
    local l = sqrt(w*w + x*x + y*y + z*z)
    local inv = 1 / l
    return {w = w*inv, x = x*inv, y = y*inv, z = z*inv}
  end
  local theta0 = math.acos(dot)
  local theta  = theta0 * t
  local sin_theta  = sin(theta)
  local sin_theta0 = sin(theta0)
  local s1 = cos(theta) - dot * sin_theta / sin_theta0
  local s2 = sin_theta / sin_theta0
  return {
    w = s1*a.w + s2*bw,
    x = s1*a.x + s2*bx,
    y = s1*a.y + s2*by,
    z = s1*a.z + s2*bz,
  }
end

-- ============================================================================
-- PRIMITIVES — mesh generators
-- ============================================================================

-- Unit cube mesh (8 vertices, 12 triangles, consistent outward winding)
function M.cube_mesh()
  local verts = {
    {x=-0.5, y=-0.5, z=-0.5}, -- 1
    {x= 0.5, y=-0.5, z=-0.5}, -- 2
    {x= 0.5, y= 0.5, z=-0.5}, -- 3
    {x=-0.5, y= 0.5, z=-0.5}, -- 4
    {x=-0.5, y=-0.5, z= 0.5}, -- 5
    {x= 0.5, y=-0.5, z= 0.5}, -- 6
    {x= 0.5, y= 0.5, z= 0.5}, -- 7
    {x=-0.5, y= 0.5, z= 0.5}, -- 8
  }
  local faces = {
    -- -Z face (back, outward normal -Z)
    {1, 3, 2}, {1, 4, 3},
    -- +Z face (front, outward normal +Z)
    {5, 6, 7}, {5, 7, 8},
    -- -Y face (bottom, outward normal -Y)
    {1, 2, 6}, {1, 6, 5},
    -- +Y face (top, outward normal +Y)
    {4, 7, 3}, {4, 8, 7},
    -- -X face (left, outward normal -X)
    {1, 5, 8}, {1, 8, 4},
    -- +X face (right, outward normal +X)
    {2, 3, 7}, {2, 7, 6},
  }
  return {vertices = verts, faces = faces}
end

-- UV sphere mesh
function M.sphere_mesh(radius, lat_segs, lon_segs)
  local verts = {}
  local faces = {}

  -- Top pole
  verts[1] = {x = 0, y = radius, z = 0}

  -- Rings
  for lat = 1, lat_segs - 1 do
    local theta = pi * lat / lat_segs  -- 0 (top) to pi (bottom)
    local sin_t = sin(theta)
    local cos_t = cos(theta)
    for lon = 0, lon_segs - 1 do
      local phi = 2 * pi * lon / lon_segs
      verts[#verts + 1] = {
        x = radius * sin_t * cos(phi),
        y = radius * cos_t,
        z = radius * sin_t * sin(phi),
      }
    end
  end

  -- Bottom pole
  verts[#verts + 1] = {x = 0, y = -radius, z = 0}

  local top_idx    = 1
  local bot_idx    = #verts
  local ring_start = 2  -- first ring starts at index 2

  -- Top cap triangles
  for lon = 0, lon_segs - 1 do
    local a = ring_start + lon
    local b = ring_start + (lon + 1) % lon_segs
    faces[#faces + 1] = {top_idx, a, b} --[[:! Face3]]
  end

  -- Middle quads (as two triangles each)
  for lat = 0, lat_segs - 3 do
    local row1 = ring_start + lat * lon_segs
    local row2 = row1 + lon_segs
    for lon = 0, lon_segs - 1 do
      local a = row1 + lon
      local b = row1 + (lon + 1) % lon_segs
      local c = row2 + (lon + 1) % lon_segs
      local d = row2 + lon
      faces[#faces + 1] = {a, b, c}
      faces[#faces + 1] = {a, c, d}
    end
  end

  -- Bottom cap triangles
  local last_ring = ring_start + (lat_segs - 2) * lon_segs
  for lon = 0, lon_segs - 1 do
    local a = last_ring + lon
    local b = last_ring + (lon + 1) % lon_segs
    faces[#faces + 1] = {bot_idx, b, a}
  end

  return {vertices = verts, faces = faces}
end

-- Plane mesh (XZ plane, centered at origin)
function M.plane_mesh(width, height, w_segs, h_segs)
  local verts = {}
  local faces = {}

  local half_w = width  * 0.5
  local half_h = height * 0.5

  for row = 0, h_segs do
    local z = -half_h + height * row / h_segs
    for col = 0, w_segs do
      local x = -half_w + width * col / w_segs
      verts[#verts + 1] = {x = x, y = 0, z = z}
    end
  end

  local stride = w_segs + 1
  for row = 0, h_segs - 1 do
    for col = 0, w_segs - 1 do
      local a = row * stride + col + 1
      local b = a + 1
      local c = a + stride
      local d = c + 1
      faces[#faces + 1] = {a, b, d}
      faces[#faces + 1] = {a, d, c}
    end
  end

  return {vertices = verts, faces = faces}
end

return M
