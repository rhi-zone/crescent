if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: HookList = { [integer]: (...unknown) -> nil }
--:: WfHooks = { step_start: HookList, step_done: HookList, step_failed: HookList, complete: HookList }
--:: StepDef = { run: (...unknown) -> unknown, on_success: string | nil, on_failure: string | nil, retry: integer | nil, timeout: number | nil }
--:: WfDef = { _steps: { [string]: StepDef }, _start: string | nil, _time_fn: () -> number, _hooks: WfHooks, ... }
--:: HistEntry = { step: string, result: unknown, error: string | nil, retries: integer, timestamp: number }
--:: WfInst = { _wf: WfDef, status: string, current: string | nil, context: { [string]: unknown }, history: { [integer]: HistEntry }, error: string | nil, ... }

-- ---------------------------------------------------------------------------
-- Deep copy utility (for context snapshots and restore)
-- ---------------------------------------------------------------------------

local function deep_copy(val, seen)
  if type(val) ~= "table" then return val end
  seen = seen or {}
  if seen[val] then return seen[val] end
  local copy = {}
  seen[val] = copy
  for k, v in pairs(val) do
    copy[deep_copy(k, seen)] = deep_copy(v, seen)
  end
  return copy
end

-- ---------------------------------------------------------------------------
-- Workflow definition
-- ---------------------------------------------------------------------------

-- Returns a new workflow definition object.
-- opts = { steps = { [name] = { run, on_success, on_failure, retry, timeout } }, start = name }
function M.define(opts)
  assert(opts and opts.time_fn, "define requires opts.time_fn")
  local wf = {}
  wf._steps = opts.steps or {}
  wf._start = opts.start
  wf._time_fn = opts.time_fn
  wf._hooks = {
    step_start  = {},
    step_done   = {},
    step_failed = {},
    complete    = {},
  }

  -- Hook registration
  function wf:on_step_start(fn)  self._hooks.step_start[#self._hooks.step_start+1] = fn  end
  function wf:on_step_done(fn)   self._hooks.step_done[#self._hooks.step_done+1] = fn    end
  function wf:on_step_failed(fn) self._hooks.step_failed[#self._hooks.step_failed+1] = fn end
  function wf:on_complete(fn)    self._hooks.complete[#self._hooks.complete+1] = fn       end

  local function fire(hooks, ...)
    for i = 1, #hooks do hooks[i](...) end
  end

  -- Validate definition: check for missing step references, detect unreachable steps.
  -- Returns true, nil on success; false, {errmsg,...} on failure.
  function wf:validate()
    local self_ = self --[[:! WfDef]]
    local errs = {} --: { [integer]: string }
    local reachable = {} --: { [string]: boolean }
    local queue = {} --: { [integer]: string }

    if not self_._start then
      errs[#errs+1] = "no start step defined"
    elseif not self_._steps[self_._start] then
      local start_ = self_._start --[[:! string]]
      errs[#errs+1] = "start step '" .. start_ .. "' not found"
    else
      queue[#queue+1] = self_._start
    end

    -- BFS over steps reachable from start
    local visited = {} --: { [string]: boolean }
    local qi = 1
    while qi <= #queue do
      local name = queue[qi]; qi = qi + 1
      if not visited[name] then
        visited[name] = true
        reachable[name] = true
        local step = self_._steps[name]
        if not step then
          errs[#errs+1] = "step '" .. name .. "' referenced but not defined"
        else
          if step.on_success and not visited[step.on_success] then
            queue[#queue+1] = step.on_success
          end
          if step.on_failure and not visited[step.on_failure] then
            queue[#queue+1] = step.on_failure
          end
        end
      end
    end

    -- Check for steps defined but not reachable
    for name in pairs(self_._steps) do
      if not reachable[name] then
        errs[#errs+1] = "step '" .. name .. "' is unreachable from start"
      end
    end

    if #errs == 0 then
      return true, nil
    end
    return false, errs
  end

  -- Create a new workflow instance with optional initial context.
  function wf:start(ctx)
    local self_ = self --[[:! WfDef]]
    local inst = {
      _wf      = self_,
      status   = "pending",
      current  = self_._start,
      context  = ctx and deep_copy(ctx) or {},
      history  = {},
      error    = nil,
    }

    -- Run a single named step (internal helper).
    -- Returns "done", "advance", next_step, or "failed", errmsg.
    local function run_step(name)
      local step = self_._steps[name]
      if not step then
        return "failed", "step '" .. name .. "' not found"
      end

      fire(self_._hooks.step_start, inst, name)

      local max_tries = 1 + (step.retry or 0)
      local last_err
      local result
      local run_ok = false

      for attempt = 1, max_tries do
        local pok, pval = pcall(step.run, inst.context)
        if pok then
          run_ok = true
          result = pval
          last_err = nil
          break
        else
          last_err = tostring(pval)
        end
      end

      if not run_ok then
        -- All attempts failed
        inst.history[#inst.history+1] = {
          step      = name,
          result    = nil,
          error     = last_err,
          retries   = step.retry or 0,
          timestamp = self_._time_fn(),
        }
        fire(self_._hooks.step_failed, inst, name, last_err)
        if step.on_failure then
          return "advance", step.on_failure
        end
        return "failed", last_err
      end

      -- Success
      inst.history[#inst.history+1] = {
        step      = name,
        result    = result,
        error     = nil,
        retries   = 0,
        timestamp = self_._time_fn(),
      }
      fire(self_._hooks.step_done, inst, name, result)

      -- Determine next step
      if type(result) == "string" then
        -- Explicit branch: run() returned a step name
        local result_ = result --[[:! string]]
        return "advance", result_
      elseif type(result) == "table" then
        local result_ = result --[[:! { [integer]: string }]]
        -- Parallel: run() returned an array of step names
        for i = 1, #result_ do
          local pname = result_[i]
          local pstatus, pval = run_step(pname)
          if pstatus == "failed" then
            return "failed", pval
          end
          -- pstatus == "advance" or "done" — just continue
        end
        -- After all parallel steps, go to on_success
        if step.on_success then
          return "advance", step.on_success
        end
        return "done", nil
      else
        -- Normal: use on_success
        if step.on_success then
          return "advance", step.on_success
        end
        return "done", nil
      end
    end

    -- Advance one step.
    -- Returns true, nil on success (step completed, workflow still running or done).
    -- Returns nil, errmsg if the workflow fails.
    function inst:step()
      local self_ = self --[[:! WfInst]]
      if self_.status == "done" or self_.status == "failed" then
        return nil, "workflow already " .. self_.status
      end
      self_.status = "running"

      local action, val = run_step(self_.current --[[:! string]])

      if action == "done" then
        self_.current = nil
        self_.status = "done"
        fire(self_._wf._hooks.complete, self_)
        return true, nil
      elseif action == "advance" then
        self_.current = val
        return true, nil
      else
        -- "failed"
        self_.status = "failed"
        self_.error  = val
        self_.current = nil
        return nil, val
      end
    end

    -- Run all steps until done or failed.
    function inst:run()
      local self_ = self --[[:! WfInst]]
      while self_.status ~= "done" and self_.status ~= "failed" do
        local ok, err = inst.step(self_)
        if not ok then return nil, err end
      end
      if self_.status == "failed" then
        return nil, self_.error
      else
        return true, nil
      end
    end

    -- Serialize the instance to a plain table (no functions).
    function inst:serialize()
      return {
        current  = self.current,
        status   = self.status,
        context  = deep_copy(self.context),
        history  = deep_copy(self.history),
        error    = self.error,
      }
    end

    inst.status = "pending"
    return inst
  end

  -- Restore an instance from a snapshot, re-attaching the workflow definition.
  function wf:restore(snapshot)
    local inst = self:start(snapshot.context)
    inst.current = snapshot.current
    inst.status  = snapshot.status
    inst.history = deep_copy(snapshot.history)
    inst.error   = snapshot.error
    return inst
  end

  return wf
end

return M
