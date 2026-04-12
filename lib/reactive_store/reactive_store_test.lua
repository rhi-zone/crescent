if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local RS = require("lib.reactive_store")

-- ── update helpers ─────────────────────────────────────────────────────────

T.describe("update", function()
  T.it("shallow merge returns new table", function()
    local s = { a = 1, b = 2 }
    local s2 = RS.update(s, { b = 99, c = 3 })
    T.eq(s2.a, 1)
    T.eq(s2.b, 99)
    T.eq(s2.c, 3)
    T.eq(s.b, 2)  -- original unchanged
    T.neq(s, s2)
  end)

  T.it("update with empty patch returns copy with same values", function()
    local s = { x = 42 }
    local s2 = RS.update(s, {})
    T.eq(s2.x, 42)
    T.neq(s, s2)
  end)
end)

T.describe("get_in", function()
  T.it("retrieves nested value", function()
    local s = { users = { { name = "alice" } } }
    T.eq(RS.get_in(s, { "users", 1, "name" }), "alice")
  end)

  T.it("returns nil for missing path", function()
    local s = { a = 1 }
    T.eq(RS.get_in(s, { "a", "b" }), nil)
  end)

  T.it("returns root for empty path", function()
    local s = { x = 1 }
    T.eq(RS.get_in(s, {}), s)
  end)
end)

T.describe("update_in", function()
  T.it("updates a single key", function()
    local s = { count = 0 }
    local s2 = RS.update_in(s, { "count" }, function(v) return v + 1 end)
    T.eq(s2.count, 1)
    T.eq(s.count, 0)
  end)

  T.it("updates nested key", function()
    local s = { user = { score = 10 } }
    local s2 = RS.update_in(s, { "user", "score" }, function(v) return v * 2 end)
    T.eq(s2.user.score, 20)
    T.eq(s.user.score, 10)     -- original unchanged
    T.neq(s2.user, s.user)     -- intermediate copy
  end)
end)

-- ── action creators ────────────────────────────────────────────────────────

T.describe("action", function()
  T.it("creator returns correct type", function()
    local inc = RS.action("counter/INCREMENT")
    local a = inc()
    T.eq(a.type, "counter/INCREMENT")
  end)

  T.it("creator merges payload fields", function()
    local add = RS.action("todos/ADD", function(text)
      return { text = text }
    end)
    local a = add("buy milk")
    T.eq(a.type, "todos/ADD")
    T.eq(a.text, "buy milk")
  end)

  T.it("returns error on non-string type", function()
    local creator, err = RS.action(42)
    T.eq(creator, nil)
    T.ok(err)
  end)
end)

T.describe("action_type", function()
  T.it("generates namespaced type strings", function()
    local AT = RS.action_type("todos")
    T.eq(AT.ADD, "todos/ADD")
    T.eq(AT.REMOVE, "todos/REMOVE")
  end)
end)

-- ── store ──────────────────────────────────────────────────────────────────

T.describe("store", function()
  local function counter_reducer(state, action)
    state = state or 0
    if action.type == "INC" then return state + (action.by or 1) end
    if action.type == "DEC" then return state - 1 end
    return state
  end

  T.it("initial state is accessible", function()
    local s = RS.store(counter_reducer, 0)
    T.eq(s:get_state(), 0)
  end)

  T.it("dispatch updates state", function()
    local s = RS.store(counter_reducer, 0)
    s:dispatch({ type = "INC" })
    T.eq(s:get_state(), 1)
    s:dispatch({ type = "INC", by = 4 })
    T.eq(s:get_state(), 5)
  end)

  T.it("subscribe called after dispatch", function()
    local s = RS.store(counter_reducer, 0)
    local calls = {}
    s:subscribe(function(state, action)
      calls[#calls + 1] = { state = state, action = action }
    end)
    s:dispatch({ type = "INC" })
    T.eq(#calls, 1)
    T.eq(calls[1].state, 1)
    T.eq(calls[1].action.type, "INC")
  end)

  T.it("unsubscribe stops notifications", function()
    local s = RS.store(counter_reducer, 0)
    local count = 0
    local unsub = s:subscribe(function() count = count + 1 end)
    s:dispatch({ type = "INC" })
    T.eq(count, 1)
    unsub()
    s:dispatch({ type = "INC" })
    T.eq(count, 1)  -- not incremented after unsub
  end)

  T.it("multiple subscribers each receive notification", function()
    local s = RS.store(counter_reducer, 0)
    local a, b = 0, 0
    s:subscribe(function() a = a + 1 end)
    s:subscribe(function() b = b + 1 end)
    s:dispatch({ type = "INC" })
    T.eq(a, 1)
    T.eq(b, 1)
  end)

  T.it("get_state_at retrieves historical state", function()
    local s = RS.store(counter_reducer, 0)
    s:dispatch({ type = "INC" })         -- state = 1, index 1
    s:dispatch({ type = "INC", by = 9 }) -- state = 10, index 2
    s:dispatch({ type = "DEC" })         -- state = 9, index 3
    T.eq(s:get_state_at(1), 1)
    T.eq(s:get_state_at(2), 10)
    T.eq(s:get_state_at(3), 9)
  end)

  T.it("history array is populated", function()
    local s = RS.store(counter_reducer, 0)
    s:dispatch({ type = "INC" })
    s:dispatch({ type = "DEC" })
    T.eq(#s.history, 2)
    T.eq(s.history[1].action.type, "INC")
    T.eq(s.history[2].state, 0)
  end)

  T.it("dispatch returns error for non-table action", function()
    local s = RS.store(counter_reducer, 0)
    local result, err = s:dispatch("not an action")
    T.eq(result, nil)
    T.ok(err)
  end)
end)

-- ── combine ────────────────────────────────────────────────────────────────

T.describe("combine", function()
  local function count_reducer(state, action)
    state = state or 0
    if action.type == "INC" then return state + 1 end
    return state
  end

  local function name_reducer(state, action)
    state = state or "anon"
    if action.type == "SET_NAME" then return action.name end
    return state
  end

  T.it("routes actions to correct sub-reducer", function()
    local root = RS.combine({ count = count_reducer, name = name_reducer })
    local s = RS.store(root, nil)
    s:dispatch({ type = "INC" })
    T.eq(s:get_state().count, 1)
    T.eq(s:get_state().name, "anon")
    s:dispatch({ type = "SET_NAME", name = "alice" })
    T.eq(s:get_state().name, "alice")
    T.eq(s:get_state().count, 1)
  end)

  T.it("returns same state reference when nothing changes", function()
    local root = RS.combine({ count = count_reducer })
    local s = RS.store(root, nil)
    s:dispatch({ type = "INC" })
    local before = s:get_state()
    s:dispatch({ type = "NOOP" })
    local after = s:get_state()
    T.eq(before, after)  -- same reference
  end)
end)

-- ── slice ──────────────────────────────────────────────────────────────────

T.describe("slice", function()
  local todo_slice = RS.slice({
    name = "todos",
    initial_state = { items = {}, next_id = 1 },
    reducers = {
      add = function(state, action)
        local items = {}
        for i = 1, #state.items do items[i] = state.items[i] end
        items[#items + 1] = { id = state.next_id, text = action.text }
        return { items = items, next_id = state.next_id + 1 }
      end,
      clear = function(_state, _action)
        return { items = {}, next_id = 1 }
      end,
    },
  })

  T.it("generates upper-case action creators", function()
    T.ok(todo_slice.actions.ADD)
    T.ok(todo_slice.actions.CLEAR)
    local a = todo_slice.actions.ADD({ text = "buy milk" })
    T.eq(a.type, "todos/add")
    T.eq(a.text, "buy milk")
  end)

  T.it("reducer handles generated actions", function()
    local s = RS.store(todo_slice.reducer)
    s:dispatch(todo_slice.actions.ADD({ text = "first" }))
    T.eq(#s:get_state().items, 1)
    T.eq(s:get_state().items[1].text, "first")
    T.eq(s:get_state().next_id, 2)
  end)

  T.it("clear action resets state", function()
    local s = RS.store(todo_slice.reducer)
    s:dispatch(todo_slice.actions.ADD({ text = "first" }))
    s:dispatch(todo_slice.actions.CLEAR({}))
    T.eq(#s:get_state().items, 0)
    T.eq(s:get_state().next_id, 1)
  end)

  T.it("unknown actions return unchanged state", function()
    local s = RS.store(todo_slice.reducer)
    local before = s:get_state()
    s:dispatch({ type = "other/THING" })
    T.eq(s:get_state(), before)
  end)
end)

-- ── selector ───────────────────────────────────────────────────────────────

T.describe("selector", function()
  T.it("returns computed value", function()
    local sel = RS.selector(function(state) return state.count * 2 end)
    T.eq(sel({ count = 5 }), 10)
  end)

  T.it("caches result when state reference is the same", function()
    local calls = 0
    local sel = RS.selector(function(state)
      calls = calls + 1
      return state.count * 2
    end)
    local s = { count = 3 }
    sel(s)
    sel(s)
    T.eq(calls, 1)
  end)

  T.it("recomputes when state reference changes", function()
    local calls = 0
    local sel = RS.selector(function(state)
      calls = calls + 1
      return state.count
    end)
    local s1 = { count = 1 }
    local s2 = { count = 2 }
    T.eq(sel(s1), 1)
    T.eq(sel(s2), 2)
    T.eq(calls, 2)
  end)

  T.it("caches with extra args", function()
    local calls = 0
    local sel = RS.selector(function(state, key)
      calls = calls + 1
      return state[key]
    end)
    local s = { a = 1, b = 2 }
    sel(s, "a")
    sel(s, "a")
    T.eq(calls, 1)
    sel(s, "b")  -- different arg -> recompute
    T.eq(calls, 2)
  end)
end)

-- ── derived ────────────────────────────────────────────────────────────────

T.describe("derived", function()
  local function reducer(state, action)
    state = state or { count = 0 }
    if action.type == "INC" then
      return { count = state.count + 1 }
    end
    return state
  end

  T.it("get() returns current derived value", function()
    local s = RS.store(reducer)
    local d = RS.derived(s, function(state) return state.count * 10 end)
    T.eq(d.get(), 0)
    s:dispatch({ type = "INC" })
    T.eq(d.get(), 10)
  end)

  T.it("subscribe notified on value change", function()
    local s = RS.store(reducer)
    local d = RS.derived(s, function(state) return state.count end)
    local vals = {}
    d.subscribe(function(v) vals[#vals + 1] = v end)
    s:dispatch({ type = "INC" })
    s:dispatch({ type = "INC" })
    T.eq(#vals, 2)
    T.eq(vals[1], 1)
    T.eq(vals[2], 2)
  end)

  T.it("derived unsubscribe stops notifications", function()
    local s = RS.store(reducer)
    local d = RS.derived(s, function(state) return state.count end)
    local count = 0
    local unsub = d.subscribe(function() count = count + 1 end)
    s:dispatch({ type = "INC" })
    T.eq(count, 1)
    unsub()
    s:dispatch({ type = "INC" })
    T.eq(count, 1)
  end)
end)

-- ── logger middleware ──────────────────────────────────────────────────────

T.describe("logger middleware", function()
  T.it("calls output for each dispatch", function()
    local messages = {}
    local function out(msg) messages[#messages + 1] = msg end

    local function reducer(state, action)
      state = state or 0
      if action.type == "INC" then return state + 1 end
      return state
    end

    local s = RS.store(reducer, 0, {
      middleware = { RS.logger({ output = out }) },
    })
    s:dispatch({ type = "INC" })
    T.ok(#messages >= 2)  -- at least "dispatching: INC" and "next state: ..."
    local found_dispatch = false
    for _, m in ipairs(messages) do
      if m:find("INC") then found_dispatch = true end
    end
    T.ok(found_dispatch)
  end)
end)

-- ── thunk middleware ───────────────────────────────────────────────────────

T.describe("thunk middleware", function()
  T.it("function actions receive dispatch and get_state", function()
    local function reducer(state, action)
      state = state or 0
      if action.type == "INC" then return state + 1 end
      return state
    end

    local s = RS.store(reducer, 0, {
      middleware = { RS.thunk() },
    })

    local captured_state
    s:dispatch(function(dispatch, get_state)
      dispatch({ type = "INC" })
      dispatch({ type = "INC" })
      captured_state = get_state()
    end)

    T.eq(s:get_state(), 2)
    T.eq(captured_state, 2)
  end)

  T.it("non-function actions pass through", function()
    local function reducer(state, action)
      state = state or 0
      if action.type == "SET" then return action.val end
      return state
    end
    local s = RS.store(reducer, 0, { middleware = { RS.thunk() } })
    s:dispatch({ type = "SET", val = 42 })
    T.eq(s:get_state(), 42)
  end)
end)

-- ── batch middleware ───────────────────────────────────────────────────────

T.describe("batch middleware", function()
  T.it("subscribers called once for multiple dispatches", function()
    local function reducer(state, action)
      state = state or 0
      if action.type == "INC" then return state + 1 end
      return state
    end

    local s = RS.store(reducer, 0)
    local call_count = 0
    s:subscribe(function() call_count = call_count + 1 end)

    RS.batch.actions(s, function()
      s:dispatch({ type = "INC" })
      s:dispatch({ type = "INC" })
      s:dispatch({ type = "INC" })
    end)

    T.eq(s:get_state(), 3)
    T.eq(call_count, 1)
  end)

  T.it("subscriber receives final state after batch", function()
    local function reducer(state, action)
      state = state or { n = 0 }
      if action.type == "INC" then return { n = state.n + 1 } end
      return state
    end

    local s = RS.store(reducer)
    local last_state
    s:subscribe(function(state) last_state = state end)

    RS.batch.actions(s, function()
      s:dispatch({ type = "INC" })
      s:dispatch({ type = "INC" })
    end)

    T.eq(last_state.n, 2)
  end)
end)
