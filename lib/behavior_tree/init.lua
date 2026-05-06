if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- Status constants
local RUNNING  = "running"
local SUCCESS  = "success"
local FAILURE  = "failure"

-- ---------------------------------------------------------------------------
-- Internal tick dispatch
-- ---------------------------------------------------------------------------

local tick_node  -- forward declaration

-- Fisher-Yates shuffle (in-place on a copy)
--: (children: { [integer]: BTNode }) -> { [integer]: BTNode }
local function shuffled(children)
  local t = {} --: { [integer]: BTNode }
  for i = 1, #children do t[i] = children[i] end
  for i = #t, 2, -1 do
    local j = math.random(i)
    t[i], t[j] = t[j], t[i]
  end
  return t
end

--: (node: BTNode) -> nil
local function reset_node(node)
  -- Reset per-node state
  for k in pairs(node.state) do node.state[k] = nil end
  -- Recurse into children
  if node.children then
    local ch = node.children --[[:! { [integer]: BTNode }]]
    for i = 1, #ch do reset_node(ch[i]) end
  end
  if node.child then reset_node(node.child --[[:! BTNode]]) end
end

-- Sequence: run children left-to-right; fail on first failure; succeed when all succeed.
-- Stateful: remembers which child was "running".
--: (BTNode, unknown) -> string
local function tick_sequence(node, bb)
  local children = node.children --[[:! { [integer]: BTNode }]]
  local start = node.state.child_idx or 1
  for i = start, #children do
    local status = tick_node(children[i], bb)
    if status == FAILURE then
      node.state.child_idx = 1
      return FAILURE
    elseif status == RUNNING then
      node.state.child_idx = i
      return RUNNING
    end
    -- SUCCESS: advance
  end
  node.state.child_idx = 1
  return SUCCESS
end

-- Selector: run children left-to-right; succeed on first success; fail when all fail.
--: (BTNode, unknown) -> string
local function tick_selector(node, bb)
  local children = node.children --[[:! { [integer]: BTNode }]]
  local start = node.state.child_idx or 1
  for i = start, #children do
    local status = tick_node(children[i], bb)
    if status == SUCCESS then
      node.state.child_idx = 1
      return SUCCESS
    elseif status == RUNNING then
      node.state.child_idx = i
      return RUNNING
    end
    -- FAILURE: try next
  end
  node.state.child_idx = 1
  return FAILURE
end

-- Parallel: tick ALL children every tick.
-- success_threshold: "all" | "any" | number
--: (BTNode, unknown) -> string
local function tick_parallel(node, bb)
  local threshold = node.threshold  -- stored on node, not state
  local children = node.children --[[:! { [integer]: BTNode }]]
  local n = #children
  local successes = 0
  local failures  = 0
  for i = 1, n do
    local status = tick_node(children[i], bb)
    if status == SUCCESS then successes = successes + 1
    elseif status == FAILURE then failures = failures + 1
    end
  end
  local needed = 0
  if threshold == "all" then needed = n
  elseif threshold == "any" then needed = 1
  else needed = threshold --[[:! integer]]
  end
  local needed_ = needed
  if successes >= needed_ then return SUCCESS end
  if failures > (n - needed_) then return FAILURE end
  return RUNNING
end

-- RandomSequence / RandomSelector: shuffle children once per "fresh start"
--: (BTNode, unknown) -> string
local function tick_random_sequence(node, bb)
  if not node.state.shuffled then
    node.state.shuffled = shuffled(node.children --[[:! { [integer]: BTNode }]])
    node.state.child_idx = 1
  end
  local children = node.state.shuffled --[[:! { [integer]: BTNode }]]
  local start = node.state.child_idx or 1
  for i = start, #children do
    local status = tick_node(children[i], bb)
    if status == FAILURE then
      node.state.shuffled   = nil
      node.state.child_idx  = 1
      return FAILURE
    elseif status == RUNNING then
      node.state.child_idx = i
      return RUNNING
    end
  end
  node.state.shuffled  = nil
  node.state.child_idx = 1
  return SUCCESS
end

--: (BTNode, unknown) -> string
local function tick_random_selector(node, bb)
  if not node.state.shuffled then
    node.state.shuffled  = shuffled(node.children --[[:! { [integer]: BTNode }]])
    node.state.child_idx = 1
  end
  local children = node.state.shuffled --[[:! { [integer]: BTNode }]]
  local start = node.state.child_idx or 1
  for i = start, #children do
    local status = tick_node(children[i], bb)
    if status == SUCCESS then
      node.state.shuffled  = nil
      node.state.child_idx = 1
      return SUCCESS
    elseif status == RUNNING then
      node.state.child_idx = i
      return RUNNING
    end
  end
  node.state.shuffled  = nil
  node.state.child_idx = 1
  return FAILURE
end

-- Decorator tickers

local function tick_inverter(node, bb)
  local status = tick_node(node.child, bb)
  if status == SUCCESS then return FAILURE
  elseif status == FAILURE then return SUCCESS
  else return RUNNING
  end
end

local function tick_succeeder(node, bb)
  tick_node(node.child, bb)
  return SUCCESS
end

local function tick_failer(node, bb)
  tick_node(node.child, bb)
  return FAILURE
end

--: (BTNode, unknown) -> string | nil
local function tick_repeater(node, bb)
  local n = node.state.n --[[:! integer | nil]]
  if n == nil then
    n = node.total  -- initialise from config on node
  end
  local ni = n --[[:! integer]]
  while true do
    local status = tick_node(node.child --[[:! BTNode]], bb)
    if status == RUNNING then
      node.state.n = ni
      return RUNNING
    end
    -- child finished (success or failure)
    reset_node(node.child --[[:! BTNode]])
    if ni == -1 then
      -- infinite: just keep going (return running so the tree keeps ticking)
      node.state.n = ni
      return RUNNING
    end
    ni = ni - 1
    node.state.n = ni
    if ni <= 0 then
      node.state.n = nil  -- will re-read node.total on next fresh start
      return SUCCESS
    end
  end
end

--: (BTNode, unknown) -> string | nil
local function tick_repeat_until_fail(node, bb)
  while true do
    local status = tick_node(node.child --[[:! BTNode]], bb)
    if status == RUNNING then return RUNNING end
    if status == FAILURE then return SUCCESS end
    -- SUCCESS: repeat
    reset_node(node.child --[[:! BTNode]])
  end
end

--: (BTNode, unknown) -> string | nil
local function tick_retry(node, bb)
  -- retry child up to n times on failure
  local remaining = node.state.remaining --[[:! integer | nil]]
  if remaining == nil then remaining = node.total end
  local rem = remaining --[[:! integer]]
  while true do
    local status = tick_node(node.child --[[:! BTNode]], bb)
    if status == SUCCESS then
      node.state.remaining = nil  -- will re-read node.total on next fresh start
      return SUCCESS
    elseif status == RUNNING then
      node.state.remaining = rem
      return RUNNING
    end
    -- FAILURE
    rem = rem - 1
    node.state.remaining = rem
    if rem <= 0 then
      node.state.remaining = nil  -- will re-read node.total on next fresh start
      return FAILURE
    end
    reset_node(node.child --[[:! BTNode]])
  end
end

--: (BTNode, unknown) -> string | nil
local function tick_cooldown(node, bb)
  local cooldown_until = node.state.cooldown_until or 0
  local tick_count     = node.state.tick_count or 0
  tick_count = tick_count + 1
  node.state.tick_count = tick_count
  if tick_count <= cooldown_until then
    return FAILURE  -- still in cooldown — block execution
  end
  local status = tick_node(node.child --[[:! BTNode]], bb)
  if status == SUCCESS then
    node.state.cooldown_until = tick_count + (node.ticks --[[:! integer]])
  end
  return status
end

-- Leaf tickers

local function tick_action(node, bb)
  return node.fn(bb, node.state)
end

local function tick_condition(node, bb)
  if node.fn(bb) then return SUCCESS else return FAILURE end
end

local function tick_wait(node, bb)
  local elapsed = node.state.elapsed or 0
  elapsed = elapsed + 1
  node.state.elapsed = elapsed
  if elapsed >= node.ticks then  -- config on node, not state
    node.state.elapsed = 0
    return SUCCESS
  end
  return RUNNING
end

local function tick_subtree(node, bb)
  return node.subtree:tick(bb)
end

-- Dispatch table
local TICKERS = {
  sequence         = tick_sequence,
  selector         = tick_selector,
  parallel         = tick_parallel,
  random_sequence  = tick_random_sequence,
  random_selector  = tick_random_selector,
  inverter         = tick_inverter,
  succeeder        = tick_succeeder,
  failer           = tick_failer,
  repeater         = tick_repeater,
  repeat_until_fail = tick_repeat_until_fail,
  retry            = tick_retry,
  cooldown         = tick_cooldown,
  action           = tick_action,
  condition        = tick_condition,
  wait             = tick_wait,
  subtree          = tick_subtree,
}

tick_node = function(node, bb)
  local node_ = node --[[:! BTNode]]
  local ticker = TICKERS[node_.type]
  if not ticker then
    return nil, "unknown node type: " .. tostring(node_.type)
  end
  local status = (ticker --[[:! (BTNode, unknown) -> string]])(node_, bb)
  node_.last_status = status
  return status
end


-- ---------------------------------------------------------------------------
-- Debug / pretty-print
-- ---------------------------------------------------------------------------

--: (BTNode, integer | nil) -> string
local function debug_node(node, indent)
  indent = indent or 0
  local pad = string.rep("  ", indent)
  local parts = { pad .. node.type }
  if node.last_status then
    parts[#parts + 1] = " [" .. node.last_status .. "]"
  end
  local line = table.concat(parts)
  local lines = { line }
  if node.child then
    lines[#lines + 1] = debug_node(node.child --[[:! BTNode]], indent + 1)
  end
  if node.children then
    local ch = node.children --[[:! { [integer]: BTNode }]]
    for i = 1, #ch do
      lines[#lines + 1] = debug_node(ch[i], indent + 1)
    end
  end
  return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Node constructors
-- ---------------------------------------------------------------------------

--:: BTNode = { type: string, state: { [string]: unknown }, last_status: string | nil, children: { [integer]: BTNode } | nil, child: BTNode | nil, fn: unknown, threshold: unknown, total: integer | nil, ticks: integer | nil, subtree: unknown, ... }

--: (t: { type: string, ... }) -> BTNode
local function make_node(t)
  local n = t --[[:! BTNode]]
  n.state = {}
  n.last_status = nil
  return n
end

function M.sequence(children)
  return make_node({ type = "sequence", children = children })
end

function M.selector(children)
  return make_node({ type = "selector", children = children })
end

function M.parallel(children, success_threshold)
  local node = make_node({ type = "parallel", children = children })
  node.threshold = success_threshold or "all"
  return node
end

function M.random_sequence(children)
  return make_node({ type = "random_sequence", children = children })
end

function M.random_selector(children)
  return make_node({ type = "random_selector", children = children })
end

function M.inverter(child)
  return make_node({ type = "inverter", child = child })
end

function M.succeeder(child)
  return make_node({ type = "succeeder", child = child })
end

function M.failer(child)
  return make_node({ type = "failer", child = child })
end

function M.repeater(child, n)
  local node = make_node({ type = "repeater", child = child })
  node.total = n  -- immutable config
  return node
end

function M.repeat_until_fail(child)
  return make_node({ type = "repeat_until_fail", child = child })
end

function M.retry(child, n)
  local node = make_node({ type = "retry", child = child })
  node.total = n  -- immutable config
  return node
end

function M.cooldown(child, ticks)
  local node = make_node({ type = "cooldown", child = child })
  node.ticks = ticks  -- immutable config
  return node
end

function M.action(fn)
  return make_node({ type = "action", fn = fn })
end

function M.condition(fn)
  return make_node({ type = "condition", fn = fn })
end

function M.wait(ticks)
  local node = make_node({ type = "wait" })
  node.ticks = ticks  -- immutable config
  return node
end

function M.subtree(tree)
  return make_node({ type = "subtree", subtree = tree })
end

-- ---------------------------------------------------------------------------
-- Tree object
-- ---------------------------------------------------------------------------

local Tree = {}
Tree.__index = Tree

function Tree:tick(blackboard)
  local status = tick_node(self._root, blackboard or {})
  self._status = status
  return status
end

function Tree:reset()
  reset_node(self._root)
  self._status = nil
end

function Tree:status()
  return self._status
end

function Tree:debug()
  return debug_node(self._root, 0)
end

function M.new(root)
  return setmetatable({ _root = root, _status = nil }, Tree)
end

return M
