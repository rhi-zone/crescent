if not package.path:find("./?/init.lua", 1, true) then package.path = "./?/init.lua;" .. package.path end

local T = require("lib.test.assert")
local notify = require("lib.notify")

T.describe("callback channel", function()
  T.it("sends message to function", function()
    local received
    local ch = notify.callback(function(msg) received = msg end, { time_fn = os.time })
    local ok = ch:send({ text = "hello" })
    T.ok(ok)
    T.eq(received.text, "hello")
  end)
end)

T.describe("console channel", function()
  T.it("sends to stderr without error", function()
    local ch = notify.console({ format = "text", time_fn = os.time })
    local ok = ch:send({ level = "info", text = "test" })
    T.ok(ok)
  end)

  T.it("json format sends without error", function()
    local ch = notify.console({ format = "json", time_fn = os.time })
    local ok = ch:send({ level = "error", topic = "deploy", text = "fail" })
    T.ok(ok)
  end)
end)

T.describe("log_channel", function()
  T.it("calls logger with level and formatted text", function()
    local logged_level, logged_text
    local ch = notify.log_channel({
      logger = function(level, text) logged_level = level; logged_text = text end,
      time_fn = os.time,
    })
    ch:send({ level = "error", topic = "deploy", text = "failed", meta = { service = "api" } })
    T.eq(logged_level, "error")
    T.ok(logged_text:find("%[deploy%]"), "should contain topic")
    T.ok(logged_text:find("failed"), "should contain text")
    T.ok(logged_text:find("service=api"), "should contain meta")
  end)
end)

T.describe("webhook", function()
  T.it("builds correct request body", function()
    local posted_url, posted_body, posted_headers
    local transport = {
      post = function(url, body, headers)
        posted_url = url
        posted_body = body
        posted_headers = headers
        return true
      end,
    }
    local ch = notify.webhook({
      url = "https://hooks.example.com/test",
      headers = { ["Authorization"] = "Bearer tok" },
      transport = transport,
      time_fn = os.time,
    })
    local ok = ch:send({ text = "deploy ok" })
    T.ok(ok)
    T.eq(posted_url, "https://hooks.example.com/test")
    T.eq(posted_body.text, "deploy ok")
    T.eq(posted_headers["Authorization"], "Bearer tok")
  end)

  T.it("applies transform to body", function()
    local posted_body
    local transport = {
      post = function(_, body) posted_body = body; return true end,
    }
    local ch = notify.webhook({
      url = "https://hooks.example.com/test",
      transport = transport,
      transform = function(msg) return { slack_text = msg.text } end,
      time_fn = os.time,
    })
    ch:send({ text = "hello" })
    T.eq(posted_body.slack_text, "hello")
    T.eq(posted_body.text, nil, "original fields should not leak through transform")
  end)

  T.it("returns error when no transport", function()
    local ch = notify.webhook({ url = "https://example.com", time_fn = os.time })
    local ok, err = ch:send({ text = "test" })
    T.fail(ok)
    T.ok(err:find("no transport"), "should report missing transport")
  end)
end)

T.describe("router", function()
  local function make_recorder(name)
    local msgs = {}
    return {
      send = function(self, msg) msgs[#msgs + 1] = msg; return true end,
      msgs = msgs,
      name = name,
    }
  end

  T.it("routes to matching channels", function()
    local r = notify.router({ time_fn = os.time })
    local a = make_recorder("a")
    local b = make_recorder("b")
    r:add("a", a)
    r:add("b", b)
    r:send({ text = "hi" })
    T.eq(#a.msgs, 1)
    T.eq(#b.msgs, 1)
  end)

  T.it("level filter works", function()
    local r = notify.router({ time_fn = os.time })
    local err_only = make_recorder("err")
    local all = make_recorder("all")
    r:add("err", err_only, { levels = { "error", "critical" } })
    r:add("all", all)
    r:send({ level = "info", text = "info msg" })
    r:send({ level = "error", text = "error msg" })
    T.eq(#err_only.msgs, 1, "err channel should only get error")
    T.eq(err_only.msgs[1].text, "error msg")
    T.eq(#all.msgs, 2, "all channel gets everything")
  end)

  T.it("topic filter works", function()
    local r = notify.router({ time_fn = os.time })
    local deploy = make_recorder("deploy")
    r:add("deploy", deploy, { topics = { "deploy" } })
    r:send({ topic = "deploy", text = "deployed" })
    r:send({ topic = "billing", text = "invoice" })
    T.eq(#deploy.msgs, 1)
    T.eq(deploy.msgs[1].text, "deployed")
  end)

  T.it("custom filter function", function()
    local r = notify.router({ time_fn = os.time })
    local ch = make_recorder("custom")
    r:add("custom", ch, {
      filter = function(msg) return msg.meta and msg.meta.urgent end,
    })
    r:send({ text = "normal" })
    r:send({ text = "urgent", meta = { urgent = true } })
    T.eq(#ch.msgs, 1)
    T.eq(ch.msgs[1].text, "urgent")
  end)

  T.it("unmatched message goes to unfiltered channels only", function()
    local r = notify.router({ time_fn = os.time })
    local filtered = make_recorder("filtered")
    local unfiltered = make_recorder("unfiltered")
    r:add("filtered", filtered, { levels = { "critical" } })
    r:add("unfiltered", unfiltered)
    r:send({ level = "debug", text = "low priority" })
    T.eq(#filtered.msgs, 0)
    T.eq(#unfiltered.msgs, 1)
  end)

  T.it("send returns per-channel results", function()
    local r = notify.router({ time_fn = os.time })
    local good = { send = function() return true end }
    local bad = { send = function() return nil, "down" end }
    r:add("good", good)
    r:add("bad", bad)
    local results = r:send({ text = "test" })
    T.eq(#results, 2)
    T.eq(results[1].name, "good")
    T.ok(results[1].ok)
    T.eq(results[2].name, "bad")
    T.fail(results[2].ok)
    T.eq(results[2].err, "down")
  end)
end)

T.describe("message", function()
  T.it("sets defaults", function()
    local msg = notify.message({ text = "hi", time_fn = os.time })
    T.eq(msg.level, "info")
    T.ok(msg.timestamp, "timestamp should be set")
    T.eq(msg.text, "hi")
  end)

  T.it("preserves all fields", function()
    local msg = notify.message({
      level = "critical",
      topic = "alerts",
      text = "disk full",
      meta = { host = "srv1" },
      timestamp = 1000,
      time_fn = os.time,
    })
    T.eq(msg.level, "critical")
    T.eq(msg.topic, "alerts")
    T.eq(msg.text, "disk full")
    T.eq(msg.meta.host, "srv1")
    T.eq(msg.timestamp, 1000)
  end)
end)

T.describe("batch", function()
  T.it("buffers messages until max_size", function()
    local sent = {}
    local ch = { send = function(_, msg) sent[#sent + 1] = msg; return true end }
    local b = notify.batch(ch, { max_size = 3, time_fn = os.time })
    b:send({ text = "1" })
    b:send({ text = "2" })
    T.eq(#sent, 0, "should not flush before max_size")
    T.eq(b:pending(), 2)
    b:send({ text = "3" })
    T.eq(#sent, 1, "should flush at max_size")
    T.eq(b:pending(), 0)
  end)

  T.it("flush sends all buffered", function()
    local sent = {}
    local ch = { send = function(_, msg) sent[#sent + 1] = msg; return true end }
    local b = notify.batch(ch, { max_size = 100, time_fn = os.time })
    b:send({ text = "a" })
    b:send({ text = "b" })
    T.eq(#sent, 0)
    b:flush()
    T.eq(#sent, 1)
    T.ok(sent[1].items, "default transform should produce items")
    T.eq(#sent[1].items, 2)
  end)

  T.it("transform combines messages", function()
    local sent = {}
    local ch = { send = function(_, msg) sent[#sent + 1] = msg; return true end }
    local b = notify.batch(ch, {
      max_size = 100,
      time_fn = os.time,
      transform = function(msgs)
        local texts = {}
        for _, m in ipairs(msgs) do texts[#texts + 1] = m.text end
        return { combined = table.concat(texts, ", ") }
      end,
    })
    b:send({ text = "x" })
    b:send({ text = "y" })
    b:flush()
    T.eq(sent[1].combined, "x, y")
  end)

  T.it("tick with expired max_wait triggers flush", function()
    local sent = {}
    local ch = { send = function(_, msg) sent[#sent + 1] = msg; return true end }
    -- Use max_wait = 0 so it always triggers
    local b = notify.batch(ch, { max_size = 100, max_wait = 0, time_fn = os.time })
    b:send({ text = "tick test" })
    -- os.time() granularity is 1s; max_wait=0 means any elapsed time triggers
    -- Since last_flush is set to os.time() at creation, and tick checks >=, 0 diff >= 0 is true
    b:tick()
    T.eq(#sent, 1)
  end)

  T.it("tick before max_wait does not flush", function()
    local sent = {}
    local ch = { send = function(_, msg) sent[#sent + 1] = msg; return true end }
    local b = notify.batch(ch, { max_size = 100, max_wait = 9999, time_fn = os.time })
    b:send({ text = "no flush" })
    b:tick()
    T.eq(#sent, 0, "should not flush before max_wait")
  end)
end)

T.describe("rate_limit", function()
  local function make_clock(start)
    local t = start or 1000
    return function() return t end, function(v) t = v end
  end

  T.it("allows messages under limit", function()
    local sent = {}
    local ch = { send = function(_, msg) sent[#sent + 1] = msg; return true end }
    local now, _ = make_clock()
    local rl = notify.rate_limit(ch, { max_per_minute = 5, time_fn = now })
    for i = 1, 5 do
      local ok = rl:send({ text = tostring(i) })
      T.ok(ok, "message " .. i .. " should be allowed")
    end
    T.eq(#sent, 5)
  end)

  T.it("drops messages over limit", function()
    local sent = {}
    local ch = { send = function(_, msg) sent[#sent + 1] = msg; return true end }
    local now, _ = make_clock()
    local rl = notify.rate_limit(ch, { max_per_minute = 2, time_fn = now })
    rl:send({ text = "1" })
    rl:send({ text = "2" })
    local ok, err = rl:send({ text = "3" })
    T.fail(ok)
    T.eq(err, "rate limited")
    T.eq(#sent, 2)
  end)

  T.it("on_drop callback called", function()
    local dropped = {}
    local ch = { send = function() return true end }
    local now, _ = make_clock()
    local rl = notify.rate_limit(ch, {
      max_per_minute = 1,
      time_fn = now,
      on_drop = function(msg) dropped[#dropped + 1] = msg end,
    })
    rl:send({ text = "ok" })
    rl:send({ text = "dropped" })
    T.eq(#dropped, 1)
    T.eq(dropped[1].text, "dropped")
  end)

  T.it("allows messages after window expires", function()
    local sent = {}
    local ch = { send = function(_, msg) sent[#sent + 1] = msg; return true end }
    local now, set_time = make_clock(1000)
    local rl = notify.rate_limit(ch, { max_per_minute = 1, time_fn = now })
    rl:send({ text = "first" })
    local ok = rl:send({ text = "blocked" })
    T.fail(ok)
    -- Advance time past the 60-second window
    set_time(1061)
    ok = rl:send({ text = "allowed again" })
    T.ok(ok)
    T.eq(#sent, 2)
  end)
end)

T.describe("retry", function()
  T.it("succeeds on first try", function()
    local calls = 0
    local ch = { send = function() calls = calls + 1; return true end }
    local rt = notify.retry(ch, { max_attempts = 3 })
    local ok = rt:send({ text = "ok" })
    T.ok(ok)
    T.eq(calls, 1)
  end)

  T.it("succeeds on second try", function()
    local calls = 0
    local ch = {
      send = function()
        calls = calls + 1
        if calls < 2 then return nil, "temporary" end
        return true
      end,
    }
    local rt = notify.retry(ch, { max_attempts = 3 })
    local ok = rt:send({ text = "retry" })
    T.ok(ok)
    T.eq(calls, 2)
  end)

  T.it("all attempts fail returns error", function()
    local calls = 0
    local ch = { send = function() calls = calls + 1; return nil, "down" end }
    local rt = notify.retry(ch, { max_attempts = 3 })
    local ok, err = rt:send({ text = "fail" })
    T.fail(ok)
    T.eq(err, "down")
    T.eq(calls, 3)
  end)
end)

T.describe("integration: multiple channels via router", function()
  T.it("routes to all matching channels", function()
    local r = notify.router({ time_fn = os.time })
    local webhook_sent = {}
    local log_sent = {}
    local cb_received = {}

    local transport = {
      post = function(_, body) webhook_sent[#webhook_sent + 1] = body; return true end,
    }
    r:add("webhook", notify.webhook({
      url = "https://hooks.example.com",
      transport = transport,
      transform = function(msg) return { text = msg.text } end,
      time_fn = os.time,
    }), { levels = { "error", "critical" } })

    r:add("log", notify.log_channel({
      logger = function(level, text) log_sent[#log_sent + 1] = { level = level, text = text } end,
      time_fn = os.time,
    }))

    r:add("cb", notify.callback(function(msg)
      cb_received[#cb_received + 1] = msg
    end, { time_fn = os.time }), { topics = { "deploy" } })

    r:send({ level = "error", topic = "deploy", text = "Deploy failed" })
    r:send({ level = "info", topic = "billing", text = "Invoice sent" })

    -- webhook: only error/critical -> 1 message
    T.eq(#webhook_sent, 1)
    T.eq(webhook_sent[1].text, "Deploy failed")

    -- log: no filter -> 2 messages
    T.eq(#log_sent, 2)

    -- cb: only deploy topic -> 1 message
    T.eq(#cb_received, 1)
    T.eq(cb_received[1].text, "Deploy failed")
  end)
end)
