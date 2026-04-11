if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local GL = require("lib.graph_layout")

local math_sqrt = math.sqrt
local math_abs  = math.abs
local math_pi   = math.pi

local function dist2d(a, b)
  local dx = a.x - b.x
  local dy = a.y - b.y
  return math_sqrt(dx * dx + dy * dy)
end

local function approx(a, b, tol)
  return math_abs(a - b) <= (tol or 1e-9)
end

-- ---------------------------------------------------------------------------
-- bbox
-- ---------------------------------------------------------------------------

T.describe("bbox", function()
  T.it("basic rectangle", function()
    local pos = {
      a = {x=1, y=2},
      b = {x=5, y=3},
      c = {x=2, y=7},
    }
    local bb = GL.bbox(pos)
    T.eq(bb[1], 1)   -- x_min
    T.eq(bb[2], 2)   -- y_min
    T.eq(bb[3], 5)   -- x_max
    T.eq(bb[4], 7)   -- y_max
  end)

  T.it("single point", function()
    local pos = {a = {x=3, y=4}}
    local bb = GL.bbox(pos)
    T.eq(bb[1], 3)
    T.eq(bb[2], 4)
    T.eq(bb[3], 3)
    T.eq(bb[4], 4)
  end)

  T.it("empty positions returns zeros", function()
    local bb = GL.bbox({})
    T.eq(bb[1], 0)
    T.eq(bb[2], 0)
    T.eq(bb[3], 0)
    T.eq(bb[4], 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- centroid
-- ---------------------------------------------------------------------------

T.describe("centroid", function()
  T.it("three points", function()
    local pos = {
      a = {x=0, y=0},
      b = {x=6, y=0},
      c = {x=3, y=6},
    }
    local cx, cy = GL.centroid(pos)
    T.ok(approx(cx, 3), "cx should be 3, got "..cx)
    T.ok(approx(cy, 2), "cy should be 2, got "..cy)
  end)

  T.it("single point returns that point", function()
    local cx, cy = GL.centroid({a = {x=7, y=11}})
    T.eq(cx, 7)
    T.eq(cy, 11)
  end)

  T.it("empty returns 0,0", function()
    local cx, cy = GL.centroid({})
    T.eq(cx, 0)
    T.eq(cy, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- normalize
-- ---------------------------------------------------------------------------

T.describe("normalize", function()
  T.it("positions fit in bounding box", function()
    local pos = {
      a = {x=-50, y=-50},
      b = {x=50,  y=-50},
      c = {x=50,  y=50},
      d = {x=-50, y=50},
    }
    local norm = GL.normalize(pos, {width=100, height=100, margin=0})
    for _, p in pairs(norm) do
      T.ok(p.x >= 0 and p.x <= 100, "x in [0,100]")
      T.ok(p.y >= 0 and p.y <= 100, "y in [0,100]")
    end
  end)

  T.it("respects margin", function()
    local pos = {
      a = {x=0, y=0},
      b = {x=1, y=1},
    }
    local norm = GL.normalize(pos, {width=100, height=100, margin=10})
    local bb = GL.bbox(norm)
    T.ok(bb[1] >= 10 - 1e-9, "x_min >= margin")
    T.ok(bb[2] >= 10 - 1e-9, "y_min >= margin")
    T.ok(bb[3] <= 90 + 1e-9, "x_max <= width-margin")
    T.ok(bb[4] <= 90 + 1e-9, "y_max <= height-margin")
  end)

  T.it("single node goes to center", function()
    local norm = GL.normalize({a = {x=5, y=5}}, {width=100, height=100, margin=0})
    T.ok(approx(norm.a.x, 50), "single node x at center")
    T.ok(approx(norm.a.y, 50), "single node y at center")
  end)
end)

-- ---------------------------------------------------------------------------
-- random_layout
-- ---------------------------------------------------------------------------

T.describe("random_layout", function()
  local graph = {
    nodes = {1, 2, 3, 4, 5},
    edges = {},
  }

  T.it("all nodes receive positions", function()
    local pos = GL.random_layout(graph, {width=100, height=100, seed=1})
    for _, id in ipairs(graph.nodes) do
      T.ok(pos[id] ~= nil, "node "..id.." has position")
      T.ok(type(pos[id].x) == "number", "x is number")
      T.ok(type(pos[id].y) == "number", "y is number")
    end
  end)

  T.it("positions in bounds", function()
    local pos = GL.random_layout(graph, {width=80, height=60, seed=7})
    for _, id in ipairs(graph.nodes) do
      T.ok(pos[id].x >= 0 and pos[id].x <= 80, "x in [0,80]")
      T.ok(pos[id].y >= 0 and pos[id].y <= 60, "y in [0,60]")
    end
  end)

  T.it("same seed produces same layout", function()
    local p1 = GL.random_layout(graph, {seed=99})
    local p2 = GL.random_layout(graph, {seed=99})
    for _, id in ipairs(graph.nodes) do
      T.ok(approx(p1[id].x, p2[id].x), "x reproducible")
      T.ok(approx(p1[id].y, p2[id].y), "y reproducible")
    end
  end)

  T.it("empty graph returns empty positions", function()
    local pos = GL.random_layout({nodes={}, edges={}})
    local count = 0
    for _ in pairs(pos) do count = count + 1 end
    T.eq(count, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- circular
-- ---------------------------------------------------------------------------

T.describe("circular", function()
  T.it("all nodes at correct radius", function()
    local graph = {nodes = {1,2,3,4,5,6}, edges = {}}
    local r   = 40
    local pos = GL.circular(graph, {radius=r, cx=0, cy=0})
    for _, id in ipairs(graph.nodes) do
      local d = math_sqrt(pos[id].x^2 + pos[id].y^2)
      T.ok(approx(d, r, 1e-9), "node "..id.." at radius "..r..", got "..d)
    end
  end)

  T.it("angles evenly spaced", function()
    local graph = {nodes = {1,2,3,4}, edges = {}}
    local pos   = GL.circular(graph, {radius=50, cx=0, cy=0})
    -- Four nodes: expected angles 0, pi/2, pi, 3pi/2
    local expected_step = 2 * math_pi / 4
    local angles = {}
    for _, id in ipairs(graph.nodes) do
      angles[#angles+1] = math.atan2(pos[id].y, pos[id].x)
    end
    -- Differences between consecutive angles should be equal (mod 2pi)
    local d1 = (angles[2] - angles[1]) % (2*math_pi)
    local d2 = (angles[3] - angles[2]) % (2*math_pi)
    local d3 = (angles[4] - angles[3]) % (2*math_pi)
    T.ok(approx(d1, expected_step, 1e-9), "step 1 = pi/2")
    T.ok(approx(d2, expected_step, 1e-9), "step 2 = pi/2")
    T.ok(approx(d3, expected_step, 1e-9), "step 3 = pi/2")
  end)

  T.it("center offset applied", function()
    local graph = {nodes = {1}, edges = {}}
    local pos   = GL.circular(graph, {radius=30, cx=10, cy=20})
    T.ok(approx(pos[1].x, 10), "single node cx")
    T.ok(approx(pos[1].y, 20), "single node cy")
  end)

  T.it("single node at center", function()
    local pos = GL.circular({nodes={"a"}, edges={}})
    T.ok(approx(pos["a"].x, 0), "x=0")
    T.ok(approx(pos["a"].y, 0), "y=0")
  end)

  T.it("empty graph", function()
    local pos = GL.circular({nodes={}, edges={}})
    local count = 0
    for _ in pairs(pos) do count = count + 1 end
    T.eq(count, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- grid
-- ---------------------------------------------------------------------------

T.describe("grid", function()
  T.it("all nodes present", function()
    local graph = {nodes={1,2,3,4,5,6,7,8,9}, edges={}}
    local pos   = GL.grid(graph)
    for _, id in ipairs(graph.nodes) do
      T.ok(pos[id] ~= nil, "node "..id.." has position")
    end
  end)

  T.it("positions are on grid spacing", function()
    local graph = {nodes={1,2,3,4}, edges={}}
    local sp    = 10
    local pos   = GL.grid(graph, {cols=2, spacing=sp})
    -- x and y should be multiples of spacing
    for _, id in ipairs(graph.nodes) do
      local p = pos[id]
      T.ok(p.x % sp == 0, "x multiple of spacing")
      T.ok(p.y % sp == 0, "y multiple of spacing")
    end
  end)

  T.it("no two nodes at same position", function()
    local graph = {nodes={1,2,3,4,5,6}, edges={}}
    local pos   = GL.grid(graph, {cols=3, spacing=10})
    for i, id1 in ipairs(graph.nodes) do
      for j, id2 in ipairs(graph.nodes) do
        if i ~= j then
          local d = dist2d(pos[id1], pos[id2])
          T.ok(d > 0, "nodes "..id1.." and "..id2.." at different positions")
        end
      end
    end
  end)

  T.it("single node", function()
    local pos = GL.grid({nodes={"x"}, edges={}})
    T.ok(pos["x"] ~= nil)
  end)

  T.it("empty graph", function()
    local pos = GL.grid({nodes={}, edges={}})
    local count = 0
    for _ in pairs(pos) do count = count + 1 end
    T.eq(count, 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- force_directed
-- ---------------------------------------------------------------------------

T.describe("force_directed", function()
  T.it("all nodes receive positions", function()
    local graph = {
      nodes = {1,2,3,4},
      edges = {{1,2},{2,3},{3,4},{4,1}},
    }
    local pos = GL.force_directed(graph, {seed=42, iterations=50})
    for _, id in ipairs(graph.nodes) do
      T.ok(pos[id] ~= nil, "node "..id.." has position")
      T.ok(type(pos[id].x) == "number")
      T.ok(type(pos[id].y) == "number")
    end
  end)

  T.it("no two adjacent nodes at same position (4-cycle)", function()
    local graph = {
      nodes = {1,2,3,4},
      edges = {{1,2},{2,3},{3,4},{4,1},{1,3}},
    }
    local pos = GL.force_directed(graph, {seed=42, iterations=100, width=100, height=100})
    -- Check all pairs are distinct
    for i, id1 in ipairs(graph.nodes) do
      for j, id2 in ipairs(graph.nodes) do
        if i < j then
          local d = dist2d(pos[id1], pos[id2])
          T.ok(d > 0.01, "nodes "..id1.." and "..id2.." are separated (d="..d..")")
        end
      end
    end
  end)

  T.it("positions clamped to canvas", function()
    local graph = {
      nodes = {1,2,3},
      edges = {{1,2},{2,3}},
    }
    local W, H = 80, 60
    local pos = GL.force_directed(graph, {width=W, height=H, seed=1, iterations=30})
    for _, id in ipairs(graph.nodes) do
      T.ok(pos[id].x >= -W/2 - 1e-9 and pos[id].x <= W/2 + 1e-9, "x clamped")
      T.ok(pos[id].y >= -H/2 - 1e-9 and pos[id].y <= H/2 + 1e-9, "y clamped")
    end
  end)

  T.it("empty graph", function()
    local pos = GL.force_directed({nodes={}, edges={}})
    local count = 0
    for _ in pairs(pos) do count = count + 1 end
    T.eq(count, 0)
  end)

  T.it("single node stays near center", function()
    local pos = GL.force_directed({nodes={"a"}, edges={}}, {seed=1, iterations=50})
    T.ok(pos["a"] ~= nil)
  end)

  T.it("named nodes work", function()
    local graph = {
      nodes = {"a","b","c"},
      edges = {{"a","b"},{"b","c"}},
    }
    local pos = GL.force_directed(graph, {seed=7, iterations=30})
    T.ok(pos["a"] ~= nil)
    T.ok(pos["b"] ~= nil)
    T.ok(pos["c"] ~= nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- hierarchical
-- ---------------------------------------------------------------------------

T.describe("hierarchical", function()
  T.it("simple chain: parents above children (direction=down)", function()
    -- 1 -> 2 -> 3 -> 4
    local graph = {
      nodes = {1,2,3,4},
      edges = {{1,2},{2,3},{3,4}},
    }
    local pos = GL.hierarchical(graph, {direction="down", layer_sep=20, node_sep=15})
    -- Layer 0: node 1 (y=0), layer 1: node 2 (y=20), etc.
    T.ok(pos[1].y < pos[2].y, "1 above 2")
    T.ok(pos[2].y < pos[3].y, "2 above 3")
    T.ok(pos[3].y < pos[4].y, "3 above 4")
  end)

  T.it("simple chain: parents left of children (direction=right)", function()
    local graph = {
      nodes = {1,2,3},
      edges = {{1,2},{2,3}},
    }
    local pos = GL.hierarchical(graph, {direction="right", layer_sep=20, node_sep=15})
    T.ok(pos[1].x < pos[2].x, "1 left of 2")
    T.ok(pos[2].x < pos[3].x, "2 left of 3")
  end)

  T.it("all nodes receive positions", function()
    local graph = {
      nodes = {1,2,3,4,5},
      edges = {{1,2},{1,3},{2,4},{3,5}},
    }
    local pos = GL.hierarchical(graph)
    for _, id in ipairs(graph.nodes) do
      T.ok(pos[id] ~= nil, "node "..id.." has position")
    end
  end)

  T.it("DAG with multiple roots", function()
    -- Two roots: 1 and 2, both point to 3
    local graph = {
      nodes = {1,2,3},
      edges = {{1,3},{2,3}},
    }
    local pos = GL.hierarchical(graph, {direction="down"})
    -- node 3 must be below both 1 and 2
    T.ok(pos[3].y > pos[1].y, "node 3 below root 1")
    T.ok(pos[3].y > pos[2].y, "node 3 below root 2")
  end)

  T.it("empty graph", function()
    local pos = GL.hierarchical({nodes={}, edges={}})
    local count = 0
    for _ in pairs(pos) do count = count + 1 end
    T.eq(count, 0)
  end)

  T.it("single node", function()
    local pos = GL.hierarchical({nodes={"x"}, edges={}})
    T.ok(pos["x"] ~= nil)
  end)

  T.it("wider DAG: grandchildren below children", function()
    --   1
    --  / \
    -- 2   3
    --  \ /
    --   4
    local graph = {
      nodes = {1,2,3,4},
      edges = {{1,2},{1,3},{2,4},{3,4}},
    }
    local pos = GL.hierarchical(graph, {direction="down"})
    T.ok(pos[1].y < pos[2].y, "1 above 2")
    T.ok(pos[1].y < pos[3].y, "1 above 3")
    T.ok(pos[2].y < pos[4].y, "2 above 4")
    T.ok(pos[3].y < pos[4].y, "3 above 4")
  end)
end)

-- ---------------------------------------------------------------------------
-- Integration: normalize + force_directed
-- ---------------------------------------------------------------------------

T.describe("integration", function()
  T.it("force_directed then normalize fits output in canvas", function()
    local graph = {
      nodes = {1,2,3,4,5,6},
      edges = {{1,2},{2,3},{3,4},{4,5},{5,6},{6,1},{1,4}},
    }
    local pos  = GL.force_directed(graph, {seed=10, iterations=60})
    local norm = GL.normalize(pos, {width=200, height=150, margin=10})
    for _, id in ipairs(graph.nodes) do
      T.ok(norm[id].x >= 10 - 1e-9, "x >= margin")
      T.ok(norm[id].x <= 190 + 1e-9, "x <= width-margin")
      T.ok(norm[id].y >= 10 - 1e-9, "y >= margin")
      T.ok(norm[id].y <= 140 + 1e-9, "y <= height-margin")
    end
  end)

  T.it("circular then bbox radius check", function()
    local graph = {nodes={1,2,3,4,5,6,7,8}, edges={}}
    local r   = 30
    local pos = GL.circular(graph, {radius=r, cx=50, cy=50})
    local bb  = GL.bbox(pos)
    -- x range should be roughly [50-r, 50+r]
    T.ok(bb[1] >= 50 - r - 1e-9, "x_min ok")
    T.ok(bb[3] <= 50 + r + 1e-9, "x_max ok")
    T.ok(bb[2] >= 50 - r - 1e-9, "y_min ok")
    T.ok(bb[4] <= 50 + r + 1e-9, "y_max ok")
  end)
end)
