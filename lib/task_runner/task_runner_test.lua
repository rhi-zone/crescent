-- lib/task_runner/task_runner_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local TR = require("lib.task_runner")

-- ── Single task execution ──────────────────────────────────────────────────────

T.describe("single task", function()
  T.it("runs a task with no deps", function()
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:task("hello", {
      run = function(ctx)
        return "world"
      end,
    })
    local results, err = runner:run("hello")
    T.ok(not err, "no error")
    T.ok(results["hello"], "result exists")
    T.ok(results["hello"].ok, "task ok")
    T.eq(results["hello"].value, "world")
  end)

  T.it("empty deps list: task runs fine", function()
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:task("noop", { deps = {}, run = function() return 42 end })
    local results, err = runner:run("noop")
    T.ok(not err)
    T.eq(results["noop"].value, 42)
  end)

  T.it("task with no run fn returns vacuous success", function()
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:task("meta", { desc = "no run" })
    local results, err = runner:run("meta")
    T.ok(not err)
    T.ok(results["meta"].ok)
  end)

  T.it("result includes duration_ms", function()
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:task("t", { run = function() return 1 end })
    local results = runner:run("t")
    T.ok(type(results["t"].duration_ms) == "number")
  end)
end)

-- ── Task with deps ─────────────────────────────────────────────────────────────

T.describe("deps", function()
  T.it("deps run before the dependent task", function()
    local order = {}
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:task("a", { run = function() order[#order+1] = "a" end })
    runner:task("b", { deps = {"a"}, run = function() order[#order+1] = "b" end })
    runner:run("b")
    T.eq(order[1], "a")
    T.eq(order[2], "b")
  end)

  T.it("shared dep runs only once", function()
    local count = 0
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:task("shared", { run = function() count = count + 1 end })
    runner:task("x", { deps = {"shared"}, run = function() end })
    runner:task("y", { deps = {"shared"}, run = function() end })
    runner:run({"x", "y"})
    T.eq(count, 1, "shared ran exactly once")
  end)

  T.it("ctx:result() accesses upstream return value", function()
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:task("build", {
      run = function() return { output = "dist/app.js" } end,
    })
    runner:task("test", {
      deps = {"build"},
      run = function(ctx)
        local br = ctx:result("build")
        return br.output
      end,
    })
    local results = runner:run("test")
    T.eq(results["test"].value, "dist/app.js")
  end)

  T.it("multi-level deps execute in correct order", function()
    local order = {}
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:task("clean",  { run = function() order[#order+1] = "clean" end })
    runner:task("build",  { deps = {"clean"}, run = function() order[#order+1] = "build" end })
    runner:task("test",   { deps = {"build"}, run = function() order[#order+1] = "test" end })
    runner:task("deploy", { deps = {"test","build"}, run = function() order[#order+1] = "deploy" end })
    runner:run("deploy")
    -- clean before build, build before test/deploy, test before deploy
    local pos = {}
    for i, v in ipairs(order) do pos[v] = i end
    T.ok(pos["clean"]  < pos["build"],  "clean before build")
    T.ok(pos["build"]  < pos["test"],   "build before test")
    T.ok(pos["test"]   < pos["deploy"], "test before deploy")
  end)
end)

-- ── plan() ────────────────────────────────────────────────────────────────────

T.describe("plan", function()
  T.it("returns topological order without running", function()
    local ran = {}
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:task("a", { run = function() ran[#ran+1] = "a" end })
    runner:task("b", { deps = {"a"}, run = function() ran[#ran+1] = "b" end })
    local plan = runner:plan("b")
    T.eq(#ran, 0, "nothing ran")
    T.eq(plan[1], "a")
    T.eq(plan[2], "b")
  end)

  T.it("plan for multiple targets includes all transitive deps", function()
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:task("base", {})
    runner:task("x", { deps = {"base"} })
    runner:task("y", { deps = {"base"} })
    local plan = runner:plan({"x", "y"})
    local found = {}
    for _, n in ipairs(plan) do found[n] = true end
    T.ok(found["base"])
    T.ok(found["x"])
    T.ok(found["y"])
  end)

  T.it("plan returns nil + err for unknown task", function()
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    local plan, err = runner:plan("nonexistent")
    T.ok(plan == nil)
    T.ok(err ~= nil)
  end)
end)

-- ── validate() ───────────────────────────────────────────────────────────────

T.describe("validate", function()
  T.it("returns true for acyclic graph", function()
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:task("a", {})
    runner:task("b", { deps = {"a"} })
    local ok, err = runner:validate()
    T.ok(ok)
    T.ok(not err)
  end)

  T.it("detects a direct cycle", function()
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:task("a", { deps = {"b"} })
    runner:task("b", { deps = {"a"} })
    local ok, err = runner:validate()
    T.ok(not ok)
    T.ok(err ~= nil, "error message present")
  end)

  T.it("detects a longer cycle", function()
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:task("a", { deps = {"c"} })
    runner:task("b", { deps = {"a"} })
    runner:task("c", { deps = {"b"} })
    local ok, err = runner:validate()
    T.ok(not ok)
    T.ok(type(err) == "string")
  end)
end)

-- ── Task failure ──────────────────────────────────────────────────────────────

T.describe("task failure", function()
  T.it("failed task produces ok=false result with err", function()
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:task("bad", {
      run = function() error("boom") end,
    })
    local results, err = runner:run("bad")
    T.ok(results["bad"] ~= nil)
    T.ok(not results["bad"].ok)
    T.ok(results["bad"].err ~= nil)
    T.ok(err ~= nil, "run returns error")
  end)

  T.it("dependent task does not run when dep fails", function()
    local ran = {}
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:task("fail_task", { run = function() error("fail") end })
    runner:task("after",     { deps = {"fail_task"}, run = function() ran[#ran+1] = "after" end })
    runner:run("after")
    T.eq(#ran, 0, "after did not run")
  end)
end)

-- ── run_all() ────────────────────────────────────────────────────────────────

T.describe("run_all", function()
  T.it("runs every defined task", function()
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:task("p", {})
    runner:task("q", { deps = {"p"} })
    runner:task("r", {})
    local results = runner:run_all()
    T.ok(results["p"] ~= nil)
    T.ok(results["q"] ~= nil)
    T.ok(results["r"] ~= nil)
  end)
end)

-- ── Tags: run_tagged ──────────────────────────────────────────────────────────

T.describe("tags", function()
  T.it("run_tagged runs only tasks with the given tag", function()
    local ran = {}
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:task("lint",  { tags = {"ci"}, run = function() ran[#ran+1] = "lint" end })
    runner:task("test",  { tags = {"ci"}, run = function() ran[#ran+1] = "test" end })
    runner:task("build", { tags = {"release"}, run = function() ran[#ran+1] = "build" end })
    runner:run_tagged("ci")
    local found = {}
    for _, v in ipairs(ran) do found[v] = true end
    T.ok(found["lint"])
    T.ok(found["test"])
    T.ok(not found["build"], "build not tagged ci")
  end)

  T.it("run_tagged returns empty results for unknown tag", function()
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:task("a", {})
    local results, err = runner:run_tagged("nonexistent")
    T.ok(not err)
    T.ok(next(results) == nil, "no results")
  end)
end)

-- ── Event hooks ───────────────────────────────────────────────────────────────

T.describe("event hooks", function()
  T.it("task:start fires before run", function()
    local started = {}
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:on("task:start", function(name) started[#started+1] = name end)
    runner:task("x", { run = function() end })
    runner:run("x")
    T.eq(#started, 1)
    T.eq(started[1], "x")
  end)

  T.it("task:done fires after successful run with result", function()
    local done_names = {}
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:on("task:done", function(name, result)
      done_names[#done_names+1] = {name = name, ok = result.ok}
    end)
    runner:task("y", { run = function() return 99 end })
    runner:run("y")
    T.eq(#done_names, 1)
    T.eq(done_names[1].name, "y")
    T.ok(done_names[1].ok)
  end)

  T.it("task:error fires on failure", function()
    local errors = {}
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:on("task:error", function(name, err) errors[#errors+1] = {name=name, err=err} end)
    runner:task("bad", { run = function() error("kaboom") end })
    runner:run("bad")
    T.eq(#errors, 1)
    T.eq(errors[1].name, "bad")
    T.ok(errors[1].err ~= nil)
  end)

  T.it("task:start and task:done both fire, in order", function()
    local events = {}
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:on("task:start", function(name) events[#events+1] = "start:" .. name end)
    runner:on("task:done",  function(name) events[#events+1] = "done:" .. name end)
    runner:task("a", {})
    runner:task("b", { deps = {"a"} })
    runner:run("b")
    T.eq(events[1], "start:a")
    T.eq(events[2], "done:a")
    T.eq(events[3], "start:b")
    T.eq(events[4], "done:b")
  end)
end)

-- ── once flag ─────────────────────────────────────────────────────────────────

T.describe("once flag", function()
  T.it("once task not re-executed when dep of multiple tasks in same run", function()
    -- The shared-dep test above already covers the natural dedup behavior.
    -- 'once' is an explicit declaration of that intent; the runner honors it
    -- through the done_set mechanism.
    local count = 0
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:task("shared", { once = true, run = function() count = count + 1 end })
    runner:task("p", { deps = {"shared"} })
    runner:task("q", { deps = {"shared"} })
    runner:run({"p", "q"})
    T.eq(count, 1)
  end)
end)

-- ── ctx:log ───────────────────────────────────────────────────────────────────

T.describe("ctx:log", function()
  T.it("log messages are forwarded to log_fn", function()
    local logs = {}
    local runner = TR.new({
      log_fn = function(name, msg) logs[#logs+1] = {name=name, msg=msg} end,
      clock_fn = os.clock,
    })
    runner:task("logged", {
      run = function(ctx) ctx:log("hello from logged") end,
    })
    runner:run("logged")
    T.eq(#logs, 1)
    T.eq(logs[1].name, "logged")
    T.eq(logs[1].msg, "hello from logged")
  end)
end)

-- ── run(list) ─────────────────────────────────────────────────────────────────

T.describe("run with list", function()
  T.it("runs multiple named targets", function()
    local runner = TR.new({ log_fn = function() end, clock_fn = os.clock })
    runner:task("a", { run = function() return 1 end })
    runner:task("b", { run = function() return 2 end })
    local results, err = runner:run({"a", "b"})
    T.ok(not err)
    T.eq(results["a"].value, 1)
    T.eq(results["b"].value, 2)
  end)
end)
