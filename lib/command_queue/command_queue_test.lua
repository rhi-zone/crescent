if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local CQ = require("lib.command_queue")

-- Helper: build a simple set command against a state table
local function make_set(state, key, value)
  local old = state[key]
  return {
    execute  = function() state[key] = value end,
    undo     = function() state[key] = old end,
    describe = function() return "set " .. key .. " = " .. tostring(value) end,
  }
end

-- ---------------------------------------------------------------------------
T.describe("history: basic execute / undo / redo", function()
  T.it("execute runs the command", function()
    local h = CQ.history()
    local state = { x = 0 }
    h:execute(make_set(state, "x", 5))
    T.eq(state.x, 5)
  end)

  T.it("can_undo is true after execute", function()
    local h = CQ.history()
    local state = { x = 0 }
    h:execute(make_set(state, "x", 5))
    T.ok(h:can_undo())
  end)

  T.it("undo reverses the command", function()
    local h = CQ.history()
    local state = { x = 0 }
    h:execute(make_set(state, "x", 5))
    h:undo()
    T.eq(state.x, 0)
  end)

  T.it("can_undo is false after undoing all", function()
    local h = CQ.history()
    local state = { x = 0 }
    h:execute(make_set(state, "x", 5))
    h:undo()
    T.fail(h:can_undo())
  end)

  T.it("redo re-applies undone command", function()
    local h = CQ.history()
    local state = { x = 0 }
    h:execute(make_set(state, "x", 5))
    h:undo()
    T.ok(h:can_redo())
    h:redo()
    T.eq(state.x, 5)
  end)

  T.it("multiple undo/redo cycle", function()
    local h = CQ.history()
    local state = { x = 0 }
    h:execute(make_set(state, "x", 5))
    h:execute(make_set(state, "x", 10))
    T.eq(state.x, 10)
    h:undo()
    T.eq(state.x, 5)
    h:undo()
    T.eq(state.x, 0)
    T.fail(h:can_undo())
    h:redo()
    T.eq(state.x, 5)
    h:redo()
    T.eq(state.x, 10)
    T.fail(h:can_redo())
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("history: undo/redo on empty stack", function()
  T.it("undo returns nil + error when empty", function()
    local h = CQ.history()
    local ok, err = h:undo()
    T.eq(ok, nil)
    T.ok(err)
  end)

  T.it("redo returns nil + error when empty", function()
    local h = CQ.history()
    local ok, err = h:redo()
    T.eq(ok, nil)
    T.ok(err)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("history: redo cleared on new execute", function()
  T.it("new execute clears the redo stack", function()
    local h = CQ.history()
    local state = { x = 0 }
    h:execute(make_set(state, "x", 5))
    h:undo()
    T.ok(h:can_redo())
    h:execute(make_set(state, "x", 99))
    T.fail(h:can_redo())
    T.eq(state.x, 99)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("compound command", function()
  T.it("executes all sub-commands", function()
    local state = { x = 0, y = 0 }
    local c = CQ.compound({
      make_set(state, "x", 1),
      make_set(state, "y", 2),
    }, "set x and y")
    c.execute()
    T.eq(state.x, 1)
    T.eq(state.y, 2)
  end)

  T.it("undoes all sub-commands atomically (reverse order)", function()
    local state = { x = 0, y = 0 }
    local c = CQ.compound({
      make_set(state, "x", 1),
      make_set(state, "y", 2),
    })
    c.execute()
    c.undo()
    T.eq(state.x, 0)
    T.eq(state.y, 0)
  end)

  T.it("describe returns provided description", function()
    local state = {}
    local c = CQ.compound({ make_set(state, "a", 1) }, "my desc")
    T.eq(c.describe(), "my desc")
  end)

  T.it("describe auto-generates from sub-commands", function()
    local state = {}
    local c = CQ.compound({ make_set(state, "a", 1), make_set(state, "b", 2) })
    local d = c.describe()
    T.ok(d:find("set a") and d:find("set b"))
  end)

  T.it("history treats compound as single undo step", function()
    local h = CQ.history()
    local state = { x = 0, y = 0 }
    h:execute(CQ.compound({
      make_set(state, "x", 1),
      make_set(state, "y", 2),
    }))
    T.eq(h:size(), 1)
    h:undo()
    T.eq(state.x, 0)
    T.eq(state.y, 0)
    T.eq(h:size(), 0)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("history:batch", function()
  T.it("all commands inside batch are grouped as one undo step", function()
    local h = CQ.history()
    local state = { x = 0, y = 0 }
    h:batch(function()
      h:execute(make_set(state, "x", 1))
      h:execute(make_set(state, "y", 2))
    end)
    T.eq(state.x, 1)
    T.eq(state.y, 2)
    T.eq(h:size(), 1)
    h:undo()
    T.eq(state.x, 0)
    T.eq(state.y, 0)
    T.eq(h:size(), 0)
  end)

  T.it("empty batch adds nothing to history", function()
    local h = CQ.history()
    h:batch(function() end)
    T.eq(h:size(), 0)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("history:transaction", function()
  T.it("commits on success, state and history updated", function()
    local h = CQ.history()
    local state = { x = 0 }
    local ok = h:transaction(function()
      h:execute(make_set(state, "x", 42))
    end)
    T.ok(ok)
    T.eq(state.x, 42)
    T.eq(h:size(), 1)
  end)

  T.it("rolls back state on error", function()
    local h = CQ.history()
    local state = { x = 0, y = 0 }
    local ok, err = h:transaction(function()
      h:execute(make_set(state, "x", 7))
      h:execute(make_set(state, "y", 8))
      error("oops")
    end)
    T.eq(ok, nil)
    T.ok(err)
    T.eq(state.x, 0)
    T.eq(state.y, 0)
  end)

  T.it("history is unchanged on rollback", function()
    local h = CQ.history()
    local state = { x = 0 }
    h:execute(make_set(state, "x", 1))  -- baseline, size = 1
    h:transaction(function()
      h:execute(make_set(state, "x", 99))
      error("fail")
    end)
    -- state rolled back, history still has only the first command
    T.eq(state.x, 1)
    T.eq(h:size(), 1)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("history: max_size", function()
  T.it("oldest entry dropped when max_size exceeded", function()
    local h = CQ.history({ max_size = 2 })
    local state = { x = 0 }
    h:execute(make_set(state, "x", 1))
    h:execute(make_set(state, "x", 2))
    h:execute(make_set(state, "x", 3))
    T.eq(h:size(), 2)
    -- list should contain the two most recent
    local lst = h:list()
    T.eq(#lst, 2)
    T.eq(lst[1], "set x = 2")
    T.eq(lst[2], "set x = 3")
  end)

  T.it("undo only goes back as far as retained history", function()
    local h = CQ.history({ max_size = 1 })
    local state = { x = 0 }
    h:execute(make_set(state, "x", 1))
    h:execute(make_set(state, "x", 2))
    -- only command for x=2 is retained
    T.eq(h:size(), 1)
    h:undo()
    T.eq(state.x, 1)  -- back to x=1, first command was evicted
    T.eq(h:size(), 0)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("history: list / clear / size / peek", function()
  T.it("list returns descriptions oldest-first", function()
    local h = CQ.history()
    local state = { x = 0 }
    h:execute(make_set(state, "x", 1))
    h:execute(make_set(state, "x", 2))
    local lst = h:list()
    T.eq(#lst, 2)
    T.eq(lst[1], "set x = 1")
    T.eq(lst[2], "set x = 2")
  end)

  T.it("clear empties undo and redo stacks", function()
    local h = CQ.history()
    local state = { x = 0 }
    h:execute(make_set(state, "x", 1))
    h:undo()
    h:clear()
    T.eq(h:size(), 0)
    T.eq(h:redo_size(), 0)
  end)

  T.it("size returns number of undoable commands", function()
    local h = CQ.history()
    local state = { x = 0 }
    T.eq(h:size(), 0)
    h:execute(make_set(state, "x", 1))
    T.eq(h:size(), 1)
    h:execute(make_set(state, "x", 2))
    T.eq(h:size(), 2)
  end)

  T.it("redo_size returns number of redoable commands", function()
    local h = CQ.history()
    local state = { x = 0 }
    h:execute(make_set(state, "x", 1))
    h:execute(make_set(state, "x", 2))
    T.eq(h:redo_size(), 0)
    h:undo()
    T.eq(h:redo_size(), 1)
    h:undo()
    T.eq(h:redo_size(), 2)
  end)

  T.it("peek_undo returns the next command to be undone", function()
    local h = CQ.history()
    local state = { x = 0 }
    h:execute(make_set(state, "x", 1))
    h:execute(make_set(state, "x", 2))
    local cmd = h:peek_undo()
    T.ok(cmd)
    T.eq(cmd.describe(), "set x = 2")
  end)

  T.it("peek_redo returns the next command to be redone", function()
    local h = CQ.history()
    local state = { x = 0 }
    h:execute(make_set(state, "x", 1))
    h:undo()
    local cmd = h:peek_redo()
    T.ok(cmd)
    T.eq(cmd.describe(), "set x = 1")
  end)

  T.it("peek_undo returns nil when stack is empty", function()
    local h = CQ.history()
    T.eq(h:peek_undo(), nil)
  end)

  T.it("peek_redo returns nil when stack is empty", function()
    local h = CQ.history()
    T.eq(h:peek_redo(), nil)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("queue", function()
  T.it("push/run_all executes in order", function()
    local q = CQ.queue()
    local log = {}
    q:push(function() log[#log + 1] = 1 end)
    q:push(function() log[#log + 1] = 2 end)
    q:push(function() log[#log + 1] = 3 end)
    q:run_all()
    T.eq(log[1], 1)
    T.eq(log[2], 2)
    T.eq(log[3], 3)
  end)

  T.it("run_all stops on first error", function()
    local q = CQ.queue()
    local log = {}
    q:push(function() log[#log + 1] = 1 end)
    q:push(function() error("stop") end)
    q:push(function() log[#log + 1] = 3 end)
    local ok, err = q:run_all()
    T.eq(ok, nil)
    T.ok(err)
    T.eq(#log, 1)
  end)

  T.it("run_next executes one item at a time", function()
    local q = CQ.queue()
    local log = {}
    q:push(function() log[#log + 1] = "a" end)
    q:push(function() log[#log + 1] = "b" end)
    q:run_next()
    T.eq(#log, 1)
    T.eq(log[1], "a")
    q:run_next()
    T.eq(#log, 2)
    T.eq(log[2], "b")
  end)

  T.it("run_next returns nil+err on empty queue", function()
    local q = CQ.queue()
    local ok, err = q:run_next()
    T.eq(ok, nil)
    T.ok(err)
  end)

  T.it("size returns pending item count", function()
    local q = CQ.queue()
    T.eq(q:size(), 0)
    q:push(function() end)
    q:push(function() end)
    T.eq(q:size(), 2)
    q:run_next()
    T.eq(q:size(), 1)
  end)

  T.it("clear empties the queue", function()
    local q = CQ.queue()
    q:push(function() end)
    q:clear()
    T.eq(q:size(), 0)
  end)
end)

-- ---------------------------------------------------------------------------
T.describe("priority_queue", function()
  T.it("runs highest priority first", function()
    local pq = CQ.priority_queue()
    local log = {}
    pq:push(function() log[#log + 1] = "low" end,    1)
    pq:push(function() log[#log + 1] = "high" end,   10)
    pq:push(function() log[#log + 1] = "medium" end, 5)
    pq:run_all()
    T.eq(log[1], "high")
    T.eq(log[2], "medium")
    T.eq(log[3], "low")
  end)

  T.it("default priority is 0", function()
    local pq = CQ.priority_queue()
    local log = {}
    pq:push(function() log[#log + 1] = "default" end)
    pq:push(function() log[#log + 1] = "high" end, 5)
    pq:run_all()
    T.eq(log[1], "high")
    T.eq(log[2], "default")
  end)

  T.it("run_next executes highest-priority item", function()
    local pq = CQ.priority_queue()
    local log = {}
    pq:push(function() log[#log + 1] = "a" end, 1)
    pq:push(function() log[#log + 1] = "b" end, 9)
    pq:run_next()
    T.eq(log[1], "b")
    T.eq(pq:size(), 1)
  end)

  T.it("run_next returns nil+err on empty queue", function()
    local pq = CQ.priority_queue()
    local ok, err = pq:run_next()
    T.eq(ok, nil)
    T.ok(err)
  end)

  T.it("clear empties the priority queue", function()
    local pq = CQ.priority_queue()
    pq:push(function() end, 1)
    pq:clear()
    T.eq(pq:size(), 0)
  end)
end)
