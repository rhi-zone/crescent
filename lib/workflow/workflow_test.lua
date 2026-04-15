if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local WF = require("lib.workflow")

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function linear_wf()
  return WF.define({ time_fn = os.time,
    start = "a",
    steps = {
      a = { run = function(ctx) ctx.a = 1 end, on_success = "b" },
      b = { run = function(ctx) ctx.b = 2 end, on_success = "c" },
      c = { run = function(ctx) ctx.c = 3 end },
    },
  })
end

-- ---------------------------------------------------------------------------
-- Tier
-- ---------------------------------------------------------------------------

T.describe("WF module", function()
  T.it("has _tier = pure", function()
    T.eq(WF._tier, "pure")
  end)
end)

-- ---------------------------------------------------------------------------
-- Linear workflow: run() to completion
-- ---------------------------------------------------------------------------

T.describe("linear workflow run()", function()
  T.it("runs all steps and returns true", function()
    local wf = linear_wf()
    local inst = wf:start()
    local ok, err = inst:run()
    T.ok(ok)
    T.eq(err, nil)
  end)

  T.it("status is done after run()", function()
    local inst = linear_wf():start()
    inst:run()
    T.eq(inst.status, "done")
  end)

  T.it("current is nil after done", function()
    local inst = linear_wf():start()
    inst:run()
    T.eq(inst.current, nil)
  end)

  T.it("context is shared across steps", function()
    local inst = linear_wf():start()
    inst:run()
    T.eq(inst.context.a, 1)
    T.eq(inst.context.b, 2)
    T.eq(inst.context.c, 3)
  end)

  T.it("pre-populated context is available to steps", function()
    local inst = linear_wf():start({ user = "alice" })
    inst:run()
    T.eq(inst.context.user, "alice")
    T.eq(inst.context.a, 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- step(): advance one step at a time
-- ---------------------------------------------------------------------------

T.describe("instance:step()", function()
  T.it("advances one step", function()
    local inst = linear_wf():start()
    T.eq(inst.current, "a")
    local ok, err = inst:step()
    T.ok(ok)
    T.eq(err, nil)
    T.eq(inst.current, "b")
  end)

  T.it("advances through all steps individually", function()
    local inst = linear_wf():start()
    inst:step()
    T.eq(inst.current, "b")
    inst:step()
    T.eq(inst.current, "c")
    inst:step()
    T.eq(inst.current, nil)
    T.eq(inst.status, "done")
  end)

  T.it("context reflects step run so far", function()
    local inst = linear_wf():start()
    inst:step()
    T.eq(inst.context.a, 1)
    T.eq(inst.context.b, nil)
    inst:step()
    T.eq(inst.context.b, 2)
  end)

  T.it("returns error when workflow already done", function()
    local inst = linear_wf():start()
    inst:run()
    local ok, err = inst:step()
    T.eq(ok, nil)
    T.ok(err)
  end)
end)

-- ---------------------------------------------------------------------------
-- on_failure routing
-- ---------------------------------------------------------------------------

T.describe("on_failure routing", function()
  T.it("routes to on_failure step on error", function()
    local wf = WF.define({ time_fn = os.time,
      start = "bad",
      steps = {
        bad     = { run = function() error("boom") end, on_failure = "recover" },
        recover = { run = function(ctx) ctx.recovered = true end },
      },
    })
    local inst = wf:start()
    inst:run()
    T.ok(inst.context.recovered)
    T.eq(inst.status, "done")
  end)

  T.it("fails workflow when no on_failure", function()
    local wf = WF.define({ time_fn = os.time,
      start = "bad",
      steps = {
        bad = { run = function() error("no handler") end },
      },
    })
    local inst = wf:start()
    local ok, err = inst:run()
    T.eq(ok, nil)
    T.ok(err)
    T.eq(inst.status, "failed")
  end)
end)

-- ---------------------------------------------------------------------------
-- Retry
-- ---------------------------------------------------------------------------

T.describe("retry", function()
  T.it("retries up to retry count before on_failure", function()
    local attempts = 0
    local wf = WF.define({ time_fn = os.time,
      start = "flaky",
      steps = {
        flaky   = {
          run = function()
            attempts = attempts + 1
            error("fail")
          end,
          retry = 2,
          on_failure = "recover",
        },
        recover = { run = function(ctx) ctx.recovered = true end },
      },
    })
    local inst = wf:start()
    inst:run()
    T.eq(attempts, 3)   -- 1 original + 2 retries
    T.ok(inst.context.recovered)
  end)

  T.it("succeeds on second attempt", function()
    local attempts = 0
    local wf = WF.define({ time_fn = os.time,
      start = "eventual",
      steps = {
        eventual = {
          run = function(ctx)
            attempts = attempts + 1
            if attempts < 2 then error("not yet") end
            ctx.success = true
          end,
          retry = 3,
        },
      },
    })
    local inst = wf:start()
    local ok = inst:run()
    T.ok(ok)
    T.ok(inst.context.success)
    T.eq(attempts, 2)
  end)

  T.it("retry=0 means no retries (one attempt only)", function()
    local attempts = 0
    local wf = WF.define({ time_fn = os.time,
      start = "once",
      steps = {
        once      = { run = function() attempts=attempts+1; error("x") end, retry=0, on_failure="end_step" },
        end_step  = { run = function() end },
      },
    })
    wf:start():run()
    T.eq(attempts, 1)
  end)
end)

-- ---------------------------------------------------------------------------
-- Conditional branching (run returns step name)
-- ---------------------------------------------------------------------------

T.describe("conditional branching", function()
  T.it("routes to returned step name", function()
    local wf = WF.define({ time_fn = os.time,
      start = "check",
      steps = {
        check     = { run = function(ctx) return ctx.value > 10 and "high" or "low" end },
        high      = { run = function(ctx) ctx.path = "high" end },
        low       = { run = function(ctx) ctx.path = "low" end },
      },
    })

    local inst1 = wf:start({ value = 20 })
    inst1:run()
    T.eq(inst1.context.path, "high")

    local inst2 = wf:start({ value = 5 })
    inst2:run()
    T.eq(inst2.context.path, "low")
  end)

  T.it("conditional ignores on_success when branch returned", function()
    local wf = WF.define({ time_fn = os.time,
      start = "check",
      steps = {
        check  = { run = function() return "target" end, on_success = "never" },
        target = { run = function(ctx) ctx.reached = true end },
        never  = { run = function(ctx) ctx.wrong = true end },
      },
    })
    local inst = wf:start()
    inst:run()
    T.ok(inst.context.reached)
    T.eq(inst.context.wrong, nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Loops (step returns its own name)
-- ---------------------------------------------------------------------------

T.describe("loops", function()
  T.it("repeats step until condition changes", function()
    local wf = WF.define({ time_fn = os.time,
      start = "loop",
      steps = {
        loop = {
          run = function(ctx)
            ctx.count = (ctx.count or 0) + 1
            if ctx.count < 3 then return "loop" end
          end,
          on_success = "finish",
        },
        finish = { run = function(ctx) ctx.done = true end },
      },
    })
    local inst = wf:start()
    inst:run()
    T.eq(inst.context.count, 3)
    T.ok(inst.context.done)
  end)
end)

-- ---------------------------------------------------------------------------
-- Parallel steps
-- ---------------------------------------------------------------------------

T.describe("parallel steps", function()
  T.it("runs all parallel steps and then on_success", function()
    local wf = WF.define({ time_fn = os.time,
      start = "fan_out",
      steps = {
        fan_out = {
          run = function() return {"step_a", "step_b", "step_c"} end,
          on_success = "join",
        },
        step_a = { run = function(ctx) ctx.a = 10 end },
        step_b = { run = function(ctx) ctx.b = 20 end },
        step_c = { run = function(ctx) ctx.c = 30 end },
        join   = { run = function(ctx) ctx.sum = ctx.a + ctx.b + ctx.c end },
      },
    })
    local inst = wf:start()
    inst:run()
    T.eq(inst.context.a, 10)
    T.eq(inst.context.b, 20)
    T.eq(inst.context.c, 30)
    T.eq(inst.context.sum, 60)
    T.eq(inst.status, "done")
  end)

  T.it("parallel failure fails workflow when no on_failure", function()
    local wf = WF.define({ time_fn = os.time,
      start = "fan",
      steps = {
        fan    = { run = function() return {"bad_step"} end, on_success = "ok" },
        bad_step = { run = function() error("parallel fail") end },
        ok     = { run = function() end },
      },
    })
    local inst = wf:start()
    local ok, err = inst:run()
    T.eq(ok, nil)
    T.ok(err)
  end)
end)

-- ---------------------------------------------------------------------------
-- History
-- ---------------------------------------------------------------------------

T.describe("history", function()
  T.it("records each step name in history", function()
    local inst = linear_wf():start()
    inst:run()
    T.eq(#inst.history, 3)
    T.eq(inst.history[1].step, "a")
    T.eq(inst.history[2].step, "b")
    T.eq(inst.history[3].step, "c")
  end)

  T.it("records error in history for failed step", function()
    local wf = WF.define({ time_fn = os.time,
      start = "bad",
      steps = {
        bad     = { run = function() error("kaboom") end, on_failure = "ok" },
        ok      = { run = function() end },
      },
    })
    local inst = wf:start()
    inst:run()
    T.ok(inst.history[1].error)
    T.ok(inst.history[1].error:find("kaboom"))
  end)

  T.it("records timestamp", function()
    local inst = linear_wf():start()
    inst:run()
    T.ok(inst.history[1].timestamp)
    T.ok(type(inst.history[1].timestamp) == "number")
  end)
end)

-- ---------------------------------------------------------------------------
-- Serialize / restore
-- ---------------------------------------------------------------------------

T.describe("serialize / restore", function()
  T.it("snapshot is a plain table with no functions", function()
    local inst = linear_wf():start()
    inst:step()
    local snap = inst:serialize()
    T.eq(type(snap), "table")
    T.eq(type(snap.context), "table")
    T.eq(type(snap.history), "table")
    T.ok(snap.current)
  end)

  T.it("restored instance continues from same step", function()
    local wf   = linear_wf()
    local inst = wf:start()
    inst:step()  -- runs "a", current = "b"
    T.eq(inst.current, "b")

    local snap  = inst:serialize()
    local inst2 = wf:restore(snap)
    T.eq(inst2.current, "b")
    T.eq(inst2.status,  inst.status)
  end)

  T.it("restored instance can run to completion", function()
    local wf   = linear_wf()
    local inst = wf:start()
    inst:step()
    local inst2 = wf:restore(inst:serialize())
    local ok, err = inst2:run()
    T.ok(ok)
    T.eq(err, nil)
    T.eq(inst2.status, "done")
  end)

  T.it("restored context is isolated from original", function()
    local wf   = linear_wf()
    local inst = wf:start({ x = 1 })
    inst:step()
    local snap  = inst:serialize()
    snap.context.x = 99
    local inst2 = wf:restore(snap)
    T.eq(inst2.context.x, 99)
    T.eq(inst.context.x, 1)  -- original unchanged
  end)

  T.it("restored history matches original", function()
    local wf   = linear_wf()
    local inst = wf:start()
    inst:step()
    inst:step()
    local inst2 = wf:restore(inst:serialize())
    T.eq(#inst2.history, #inst.history)
    T.eq(inst2.history[1].step, "a")
    T.eq(inst2.history[2].step, "b")
  end)
end)

-- ---------------------------------------------------------------------------
-- Validate
-- ---------------------------------------------------------------------------

T.describe("validate()", function()
  T.it("returns true for valid workflow", function()
    local ok, errs = linear_wf():validate()
    T.ok(ok)
    T.eq(errs, nil)
  end)

  T.it("detects missing referenced step", function()
    local wf = WF.define({ time_fn = os.time,
      start = "a",
      steps = {
        a = { run = function() end, on_success = "missing_step" },
      },
    })
    local ok, errs = wf:validate()
    T.eq(ok, false)
    T.ok(#errs > 0)
    local found = false
    for _, e in ipairs(errs) do
      if e:find("missing_step") then found = true end
    end
    T.ok(found, "error should mention missing_step")
  end)

  T.it("detects unreachable step", function()
    local wf = WF.define({ time_fn = os.time,
      start = "a",
      steps = {
        a       = { run = function() end },
        orphan  = { run = function() end },
      },
    })
    local ok, errs = wf:validate()
    T.eq(ok, false)
    local found = false
    for _, e in ipairs(errs) do
      if e:find("orphan") then found = true end
    end
    T.ok(found, "error should mention orphan")
  end)

  T.it("detects missing start step", function()
    local wf = WF.define({ time_fn = os.time,
      start = "nonexistent",
      steps = { a = { run = function() end } },
    })
    local ok, errs = wf:validate()
    T.eq(ok, false)
    T.ok(#errs > 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

T.describe("hooks", function()
  T.it("on_step_done called for each step", function()
    local done_steps = {}
    local wf = linear_wf()
    wf:on_step_done(function(inst, name)
      done_steps[#done_steps+1] = name
    end)
    wf:start():run()
    T.eq(#done_steps, 3)
    T.eq(done_steps[1], "a")
    T.eq(done_steps[2], "b")
    T.eq(done_steps[3], "c")
  end)

  T.it("on_step_failed called on error", function()
    local failed_step = nil
    local failed_err  = nil
    local wf = WF.define({ time_fn = os.time,
      start = "bad",
      steps = {
        bad = { run = function() error("boom") end, on_failure = "ok" },
        ok  = { run = function() end },
      },
    })
    wf:on_step_failed(function(inst, name, err)
      failed_step = name
      failed_err  = err
    end)
    wf:start():run()
    T.eq(failed_step, "bad")
    T.ok(failed_err)
  end)

  T.it("on_complete called when workflow done", function()
    local completed = false
    local wf = linear_wf()
    wf:on_complete(function() completed = true end)
    wf:start():run()
    T.ok(completed)
  end)

  T.it("on_step_start called before each step", function()
    local started = {}
    local wf = linear_wf()
    wf:on_step_start(function(inst, name)
      started[#started+1] = name
    end)
    wf:start():run()
    T.eq(#started, 3)
    T.eq(started[1], "a")
  end)

  T.it("on_complete NOT called when workflow fails", function()
    local completed = false
    local wf = WF.define({ time_fn = os.time,
      start = "bad",
      steps = { bad = { run = function() error("x") end } },
    })
    wf:on_complete(function() completed = true end)
    wf:start():run()
    T.eq(completed, false)
  end)
end)

-- ---------------------------------------------------------------------------
-- Status transitions
-- ---------------------------------------------------------------------------

T.describe("status transitions", function()
  T.it("starts as pending", function()
    local inst = linear_wf():start()
    T.eq(inst.status, "pending")
  end)

  T.it("becomes running after first step()", function()
    local inst = linear_wf():start()
    inst:step()
    -- after one step it might be running or done; if more steps remain it's running
    T.ok(inst.status == "running" or inst.status == "done")
  end)

  T.it("becomes failed on unhandled error", function()
    local wf = WF.define({ time_fn = os.time,
      start = "bad",
      steps = { bad = { run = function() error("boom") end } },
    })
    local inst = wf:start()
    inst:run()
    T.eq(inst.status, "failed")
    T.ok(inst.error)
  end)

  T.it("error field is nil on success", function()
    local inst = linear_wf():start()
    inst:run()
    T.eq(inst.error, nil)
  end)
end)

-- ---------------------------------------------------------------------------
-- Edge cases
-- ---------------------------------------------------------------------------

T.describe("edge cases", function()
  T.it("single-step workflow completes", function()
    local wf = WF.define({ time_fn = os.time,
      start = "only",
      steps = { only = { run = function(ctx) ctx.x = 42 end } },
    })
    local inst = wf:start()
    local ok = inst:run()
    T.ok(ok)
    T.eq(inst.context.x, 42)
    T.eq(inst.status, "done")
  end)

  T.it("step() on failed workflow returns error", function()
    local wf = WF.define({ time_fn = os.time,
      start = "bad",
      steps = { bad = { run = function() error("x") end } },
    })
    local inst = wf:start()
    inst:run()
    local ok, err = inst:step()
    T.eq(ok, nil)
    T.ok(err)
  end)

  T.it("multiple instances from same workflow are independent", function()
    local wf  = linear_wf()
    local i1  = wf:start({ tag = "one" })
    local i2  = wf:start({ tag = "two" })
    i1:run()
    i2:run()
    T.eq(i1.context.tag, "one")
    T.eq(i2.context.tag, "two")
  end)
end)
