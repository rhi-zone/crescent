if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local FF = require("lib.feature_flags")

T.describe("feature_flags", function()

  -- ─── define + enabled (defaults) ────────────────────────────────────────

  T.it("define: default false", function()
    local flags = FF.new()
    flags:define("new_ui", { default = false, description = "Enable new UI" })
    T.eq(flags:enabled("new_ui"), false)
  end)

  T.it("define: default true", function()
    local flags = FF.new()
    flags:define("dark_mode", { default = true })
    T.eq(flags:enabled("dark_mode"), true)
  end)

  T.it("define: default defaults to false when omitted", function()
    local flags = FF.new()
    flags:define("implicit_flag", {})
    T.eq(flags:enabled("implicit_flag"), false)
  end)

  -- ─── enable / disable / set ──────────────────────────────────────────────

  T.it("enable: sets flag to true", function()
    local flags = FF.new()
    flags:define("f", { default = false })
    flags:enable("f")
    T.eq(flags:enabled("f"), true)
  end)

  T.it("disable: sets flag to false", function()
    local flags = FF.new()
    flags:define("f", { default = true })
    flags:disable("f")
    T.eq(flags:enabled("f"), false)
  end)

  T.it("set: boolean true", function()
    local flags = FF.new()
    flags:define("f", { default = false })
    flags:set("f", true)
    T.eq(flags:enabled("f"), true)
  end)

  T.it("set: boolean false", function()
    local flags = FF.new()
    flags:define("f", { default = true })
    flags:set("f", false)
    T.eq(flags:enabled("f"), false)
  end)

  -- ─── load ────────────────────────────────────────────────────────────────

  T.it("load: bulk config sets values", function()
    local flags = FF.new()
    flags:define("a", { default = false })
    flags:define("b", { default = false })
    flags:define("c", { default = true })
    flags:load({ a = true, c = false })
    T.eq(flags:enabled("a"), true)
    T.eq(flags:enabled("b"), false)
    T.eq(flags:enabled("c"), false)
  end)

  T.it("load: string variant override", function()
    local flags = FF.new()
    flags:define("btn", {
      variants = {
        { name = "blue",  weight = 50 },
        { name = "green", weight = 50 },
      },
      default_variant = "blue",
    })
    flags:load({ btn = "green" })
    local v = flags:variant("btn", { user_id = "anyone" })
    T.eq(v, "green")
  end)

  -- ─── enabled_for: rollout ────────────────────────────────────────────────

  T.it("enabled_for rollout: same user always same result", function()
    local flags = FF.new()
    flags:define("beta", { default = false, rollout = 0.5 })
    local ctx = { user_id = "alice" }
    local r1 = flags:enabled_for("beta", ctx)
    local r2 = flags:enabled_for("beta", ctx)
    T.eq(r1, r2)
  end)

  T.it("enabled_for rollout: different users may differ", function()
    local flags = FF.new()
    flags:define("beta", { default = false, rollout = 0.5 })
    -- With 0.5 rollout and enough users we expect both true and false.
    local true_count = 0
    local false_count = 0
    for i = 1, 100 do
      local v = flags:enabled_for("beta", { user_id = "user" .. i })
      if v then true_count = true_count + 1 else false_count = false_count + 1 end
    end
    T.ok(true_count > 0,  "expected some true")
    T.ok(false_count > 0, "expected some false")
  end)

  T.it("enabled_for rollout: ~correct percentage over many users", function()
    local flags = FF.new()
    flags:define("beta", { default = false, rollout = 0.1 })
    local enabled = 0
    for i = 1, 1000 do
      if flags:enabled_for("beta", { user_id = "u" .. i }) then
        enabled = enabled + 1
      end
    end
    -- Expect roughly 10% ± 5%.
    T.ok(enabled >= 50,  "rollout too low: " .. enabled)
    T.ok(enabled <= 150, "rollout too high: " .. enabled)
  end)

  T.it("enabled_for rollout: 0% always false", function()
    local flags = FF.new()
    flags:define("off", { default = false, rollout = 0.0 })
    for i = 1, 20 do
      T.eq(flags:enabled_for("off", { user_id = "u" .. i }), false)
    end
  end)

  T.it("enabled_for rollout: 100% always true", function()
    local flags = FF.new()
    flags:define("on", { default = false, rollout = 1.0 })
    for i = 1, 20 do
      T.eq(flags:enabled_for("on", { user_id = "u" .. i }), true)
    end
  end)

  -- ─── rules ───────────────────────────────────────────────────────────────

  T.it("rules: first matching rule wins", function()
    local flags = FF.new()
    flags:define("premium", {
      default = false,
      rules = {
        { condition = function(ctx) return ctx.plan == "enterprise" end, value = true },
        { condition = function(ctx) return ctx.beta_user == true end,    value = true },
      },
    })
    T.eq(flags:enabled_for("premium", { plan = "enterprise" }), true)
    T.eq(flags:enabled_for("premium", { beta_user = true }),    true)
    T.eq(flags:enabled_for("premium", { plan = "free" }),       false)
  end)

  T.it("rules: no match → default", function()
    local flags = FF.new()
    flags:define("f", {
      default = false,
      rules = {
        { condition = function(ctx) return ctx.x == 1 end, value = true },
      },
    })
    T.eq(flags:enabled_for("f", { x = 2 }), false)
  end)

  T.it("rules: rule returning false overrides default true", function()
    local flags = FF.new()
    flags:define("f", {
      default = true,
      rules = {
        { condition = function(ctx) return ctx.blocked == true end, value = false },
      },
    })
    T.eq(flags:enabled_for("f", { blocked = true }), false)
    T.eq(flags:enabled_for("f", { blocked = false }), true)
  end)

  -- ─── variant ─────────────────────────────────────────────────────────────

  T.it("variant: consistent for same user", function()
    local flags = FF.new()
    flags:define("btn", {
      variants = {
        { name = "blue",  weight = 50 },
        { name = "green", weight = 30 },
        { name = "red",   weight = 20 },
      },
      default_variant = "blue",
    })
    local ctx = { user_id = "bob" }
    local v1 = flags:variant("btn", ctx)
    local v2 = flags:variant("btn", ctx)
    T.eq(v1, v2)
  end)

  T.it("variant: returns one of the defined variant names", function()
    local flags = FF.new()
    flags:define("btn", {
      variants = {
        { name = "blue",  weight = 50 },
        { name = "green", weight = 30 },
        { name = "red",   weight = 20 },
      },
      default_variant = "blue",
    })
    local valid = { blue = true, green = true, red = true }
    for i = 1, 30 do
      local v = flags:variant("btn", { user_id = "u" .. i })
      T.ok(valid[v], "unexpected variant: " .. tostring(v))
    end
  end)

  T.it("variant: weighted distribution roughly correct", function()
    local flags = FF.new()
    flags:define("btn", {
      variants = {
        { name = "blue",  weight = 50 },
        { name = "green", weight = 30 },
        { name = "red",   weight = 20 },
      },
      default_variant = "blue",
    })
    local counts = { blue = 0, green = 0, red = 0 }
    for i = 1, 1000 do
      local v = flags:variant("btn", { user_id = "user" .. i })
      counts[v] = counts[v] + 1
    end
    -- blue ~50%, green ~30%, red ~20%, allow ±10 pp.
    T.ok(counts.blue  >= 400 and counts.blue  <= 600, "blue count: "  .. counts.blue)
    T.ok(counts.green >= 200 and counts.green <= 400, "green count: " .. counts.green)
    T.ok(counts.red   >= 100 and counts.red   <= 300, "red count: "   .. counts.red)
  end)

  T.it("variant: no variants flag returns nil+err", function()
    local flags = FF.new()
    flags:define("f", { default = false })
    local v, err = flags:variant("f", {})
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  -- ─── override ────────────────────────────────────────────────────────────

  T.it("override: takes precedence over default", function()
    local flags = FF.new()
    flags:define("f", { default = false })
    flags:override("f", true)
    T.eq(flags:enabled("f"), true)
  end)

  T.it("override: takes precedence over rules", function()
    local flags = FF.new()
    flags:define("f", {
      default = false,
      rules = {
        { condition = function(ctx) return ctx.admin == true end, value = true },
      },
    })
    flags:override("f", false)
    T.eq(flags:enabled_for("f", { admin = true }), false)
  end)

  T.it("override: takes precedence over rollout", function()
    local flags = FF.new()
    flags:define("f", { default = false, rollout = 1.0 })
    flags:override("f", false)
    T.eq(flags:enabled_for("f", { user_id = "anyone" }), false)
  end)

  -- ─── clear_override ──────────────────────────────────────────────────────

  T.it("clear_override: reverts to rules", function()
    local flags = FF.new()
    flags:define("f", {
      default = false,
      rules = {
        { condition = function(ctx) return ctx.admin == true end, value = true },
      },
    })
    flags:override("f", false)
    T.eq(flags:enabled_for("f", { admin = true }), false)
    flags:clear_override("f")
    T.eq(flags:enabled_for("f", { admin = true }), true)
  end)

  T.it("clear_override: reverts to default when no rules", function()
    local flags = FF.new()
    flags:define("f", { default = true })
    flags:override("f", false)
    T.eq(flags:enabled("f"), false)
    flags:clear_override("f")
    T.eq(flags:enabled("f"), true)
  end)

  -- ─── snapshot / from_snapshot ────────────────────────────────────────────

  T.it("snapshot/from_snapshot: round-trip boolean flags", function()
    local flags = FF.new()
    flags:define("a", { default = false, description = "flag a" })
    flags:define("b", { default = true })
    flags:set("a", true)
    flags:override("b", false)

    local snap  = flags:snapshot()
    local flags2 = FF.from_snapshot(snap)

    T.eq(flags2:enabled("a"), true)
    T.eq(flags2:enabled("b"), false)  -- override restored
  end)

  T.it("snapshot/from_snapshot: preserves description and rollout", function()
    local flags = FF.new()
    flags:define("beta", { default = false, description = "beta", rollout = 0.25 })

    local snap   = flags:snapshot()
    local flags2 = FF.from_snapshot(snap)

    local info = flags2:all()
    T.eq(info.beta.description, "beta")
    T.eq(info.beta.rollout,     0.25)
  end)

  T.it("snapshot/from_snapshot: preserves variants", function()
    local flags = FF.new()
    flags:define("btn", {
      variants = {
        { name = "blue",  weight = 50 },
        { name = "green", weight = 50 },
      },
      default_variant = "blue",
    })
    flags:load({ btn = "green" })

    local snap   = flags:snapshot()
    local flags2 = FF.from_snapshot(snap)

    T.eq(flags2:variant("btn", {}), "green")
  end)

  -- ─── all() / enabled_flags() ─────────────────────────────────────────────

  T.it("all: returns map of all flags", function()
    local flags = FF.new()
    flags:define("a", { default = false })
    flags:define("b", { default = true })
    local info = flags:all()
    T.ok(info.a ~= nil)
    T.ok(info.b ~= nil)
    T.eq(info.a.default, false)
    T.eq(info.b.default, true)
  end)

  T.it("enabled_flags: returns only true flags (sorted)", function()
    local flags = FF.new()
    flags:define("alpha",   { default = false })
    flags:define("beta",    { default = true })
    flags:define("gamma",   { default = false })
    flags:enable("alpha")
    local ef = flags:enabled_flags()
    T.eq(#ef, 2)
    T.eq(ef[1], "alpha")
    T.eq(ef[2], "beta")
  end)

  T.it("enabled_flags: empty when all false", function()
    local flags = FF.new()
    flags:define("a", { default = false })
    flags:define("b", { default = false })
    T.eq(#flags:enabled_flags(), 0)
  end)

  -- ─── on("change") ────────────────────────────────────────────────────────

  T.it("on change: fires on enable", function()
    local flags = FF.new()
    flags:define("f", { default = false })
    local fired = false
    local got_name, got_old, got_new
    flags:on("change", function(name, old_val, new_val)
      fired     = true
      got_name  = name
      got_old   = old_val
      got_new   = new_val
    end)
    flags:enable("f")
    T.ok(fired)
    T.eq(got_name, "f")
    T.eq(got_old,  nil)
    T.eq(got_new,  true)
  end)

  T.it("on change: fires on disable", function()
    local flags = FF.new()
    flags:define("f", { default = true })
    flags:set("f", true)  -- set value so old is true
    local events = {}
    flags:on("change", function(name, old_val, new_val)
      events[#events + 1] = { name, old_val, new_val }
    end)
    flags:disable("f")
    T.eq(#events, 1)
    T.eq(events[1][3], false)
  end)

  T.it("on change: fires on load", function()
    local flags = FF.new()
    flags:define("a", { default = false })
    local count = 0
    flags:on("change", function() count = count + 1 end)
    flags:load({ a = true })
    T.eq(count, 1)
  end)

  T.it("on change: fires on override", function()
    local flags = FF.new()
    flags:define("f", { default = false })
    local fired = false
    flags:on("change", function() fired = true end)
    flags:override("f", true)
    T.ok(fired)
  end)

  T.it("on change: does not fire when value unchanged", function()
    local flags = FF.new()
    flags:define("f", { default = false })
    flags:set("f", true)
    local count = 0
    flags:on("change", function() count = count + 1 end)
    flags:set("f", true)  -- same value
    T.eq(count, 0)
  end)

  -- ─── missing flag errors ──────────────────────────────────────────────────

  T.it("enabled: missing flag returns nil+err", function()
    local flags = FF.new()
    local v, err = flags:enabled("nonexistent")
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("enabled_for: missing flag returns nil+err", function()
    local flags = FF.new()
    local v, err = flags:enabled_for("nonexistent", { user_id = "x" })
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("variant: missing flag returns nil+err", function()
    local flags = FF.new()
    local v, err = flags:variant("nonexistent", {})
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("enable: missing flag returns nil+err", function()
    local flags = FF.new()
    local v, err = flags:enable("nonexistent")
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

  T.it("override: missing flag returns nil+err", function()
    local flags = FF.new()
    local v, err = flags:override("nonexistent", true)
    T.eq(v, nil)
    T.ok(err ~= nil)
  end)

end)
