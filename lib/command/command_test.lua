if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local cmd = require("lib.command")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local set_value = cmd.command({
  name = "set_value",
  execute = function(ctx, state, args)
    local old = state.value
    state.value = args.value
    return { old_value = old }
  end,
  undo = function(ctx, state, args, undo_data)
    state.value = undo_data.old_value
  end,
})

local add_item = cmd.command({
  name = "add_item",
  execute = function(ctx, state, args)
    state.list[#state.list + 1] = args.item
    return { index = #state.list }
  end,
  undo = function(ctx, state, args, undo_data)
    table.remove(state.list, undo_data.index)
  end,
})

local no_undo_cmd = cmd.command({
  name = "no_undo",
  execute = function(ctx, state, args)
    state.value = args.value
    return {}
  end,
  -- no undo function
})

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

T.describe("command", function()

  T.it("execute mutates state", function()
    local h     = cmd.history()
    local state = { value = 0 }
    h:execute(set_value, nil, state, { value = 10 })
    T.eq(state.value, 10)
  end)

  T.it("undo reverts state", function()
    local h     = cmd.history()
    local state = { value = 0 }
    h:execute(set_value, nil, state, { value = 10 })
    T.eq(state.value, 10)
    h:undo()
    T.eq(state.value, 0)
  end)

  T.it("redo re-applies command", function()
    local h     = cmd.history()
    local state = { value = 0 }
    h:execute(set_value, nil, state, { value = 10 })
    h:undo()
    T.eq(state.value, 0)
    h:redo()
    T.eq(state.value, 10)
  end)

  T.it("can_undo and can_redo are correct", function()
    local h     = cmd.history()
    local state = { value = 0 }
    T.fail(h:can_undo())
    T.fail(h:can_redo())
    h:execute(set_value, nil, state, { value = 5 })
    T.ok(h:can_undo())
    T.fail(h:can_redo())
    h:undo()
    T.fail(h:can_undo())
    T.ok(h:can_redo())
  end)

  T.it("multiple undo/redo", function()
    local h     = cmd.history()
    local state = { value = 0 }
    h:execute(set_value, nil, state, { value = 10 })
    h:execute(set_value, nil, state, { value = 20 })
    h:execute(set_value, nil, state, { value = 30 })
    T.eq(state.value, 30)
    h:undo()
    T.eq(state.value, 20)
    h:undo()
    T.eq(state.value, 10)
    h:undo()
    T.eq(state.value, 0)
    h:redo()
    T.eq(state.value, 10)
    h:redo()
    T.eq(state.value, 20)
  end)

  T.it("new execute after undo clears redo stack", function()
    local h     = cmd.history()
    local state = { value = 0 }
    h:execute(set_value, nil, state, { value = 10 })
    h:execute(set_value, nil, state, { value = 20 })
    h:undo()
    T.ok(h:can_redo())
    h:execute(set_value, nil, state, { value = 99 })
    T.fail(h:can_redo())
    T.eq(state.value, 99)
  end)

  T.it("undo_depth and redo_depth", function()
    local h     = cmd.history()
    local state = { value = 0 }
    T.eq(h:undo_depth(), 0)
    T.eq(h:redo_depth(), 0)
    h:execute(set_value, nil, state, { value = 1 })
    h:execute(set_value, nil, state, { value = 2 })
    T.eq(h:undo_depth(), 2)
    T.eq(h:redo_depth(), 0)
    h:undo()
    T.eq(h:undo_depth(), 1)
    T.eq(h:redo_depth(), 1)
  end)

  T.it("max_size drops oldest entries", function()
    local h     = cmd.history({ max_size = 2 })
    local state = { value = 0 }
    h:execute(set_value, nil, state, { value = 1 })
    h:execute(set_value, nil, state, { value = 2 })
    h:execute(set_value, nil, state, { value = 3 })
    T.eq(h:undo_depth(), 2)
    -- undo twice; should reach value=1, not 0
    h:undo()
    T.eq(state.value, 2)
    h:undo()
    T.eq(state.value, 1)
    T.fail(h:can_undo())
  end)

  T.it("entries returns correct count and names", function()
    local h     = cmd.history()
    local state = { value = 0, list = {} }
    h:execute(set_value, nil, state, { value = 5 })
    h:execute(add_item,  nil, state, { item = "a" })
    local entries = h:entries()
    T.eq(#entries, 2)
    T.eq(entries[1].name, "set_value")
    T.eq(entries[2].name, "add_item")
  end)

  T.it("callbacks fire on execute/undo/redo", function()
    local exec_count, undo_count, redo_count = 0, 0, 0
    local h = cmd.history({
      on_execute = function() exec_count = exec_count + 1 end,
      on_undo    = function() undo_count = undo_count + 1 end,
      on_redo    = function() redo_count = redo_count + 1 end,
    })
    local state = { value = 0 }
    h:execute(set_value, nil, state, { value = 7 })
    T.eq(exec_count, 1)
    h:undo()
    T.eq(undo_count, 1)
    h:redo()
    T.eq(redo_count, 1)
  end)

  T.it("clear empties history", function()
    local h     = cmd.history()
    local state = { value = 0 }
    h:execute(set_value, nil, state, { value = 1 })
    h:execute(set_value, nil, state, { value = 2 })
    h:undo()
    T.ok(h:can_undo())
    T.ok(h:can_redo())
    h:clear()
    T.fail(h:can_undo())
    T.fail(h:can_redo())
  end)

  T.it("clear_redo clears only the redo stack", function()
    local h     = cmd.history()
    local state = { value = 0 }
    h:execute(set_value, nil, state, { value = 1 })
    h:undo()
    T.ok(h:can_redo())
    h:clear_redo()
    T.fail(h:can_redo())
    -- undo stack untouched? well it's empty after undo; make sure undo gone too
    T.fail(h:can_undo())
  end)

  T.it("batch: single undo reverts all steps", function()
    local h     = cmd.history()
    local state = { value = 0 }
    h:begin_batch()
      h:execute(set_value, nil, state, { value = 5 })
      h:execute(set_value, nil, state, { value = 7 })
    h:commit_batch("my_batch")
    T.eq(state.value, 7)
    T.eq(h:undo_depth(), 1)
    h:undo()
    T.eq(state.value, 0)
    T.fail(h:can_undo())
  end)

  T.it("batch: redo re-applies all steps", function()
    local h     = cmd.history()
    local state = { value = 0 }
    h:begin_batch()
      h:execute(set_value, nil, state, { value = 5 })
      h:execute(set_value, nil, state, { value = 7 })
    h:commit_batch("my_batch")
    h:undo()
    T.eq(state.value, 0)
    h:redo()
    T.eq(state.value, 7)
  end)

  T.it("rollback_batch: state unchanged on error path", function()
    local h     = cmd.history()
    local state = { value = 0 }
    h:begin_batch()
      h:execute(set_value, nil, state, { value = 5 })
      -- Simulate partial work then rollback
    h:rollback_batch()
    T.eq(state.value, 0)
    T.fail(h:can_undo())
  end)

  T.it("transaction: commits on success", function()
    local h     = cmd.history()
    local state = { value = 0 }
    local ok = h:transaction("tx", function()
      h:execute(set_value, nil, state, { value = 42 })
    end)
    T.ok(ok)
    T.eq(state.value, 42)
    T.eq(h:undo_depth(), 1)
  end)

  T.it("transaction: rollback on error", function()
    local h     = cmd.history()
    local state = { value = 0 }
    local ok, err = h:transaction("tx_fail", function()
      h:execute(set_value, nil, state, { value = 99 })
      error("oops")
    end)
    T.fail(ok)
    T.ok(err ~= nil)
    T.eq(state.value, 0)
    T.fail(h:can_undo())
  end)

  T.it("command without undo: undo returns false", function()
    local h     = cmd.history()
    local state = { value = 0 }
    h:execute(no_undo_cmd, nil, state, { value = 55 })
    local result, err = h:undo()
    T.fail(result)
    T.ok(err ~= nil)
  end)

  T.it("macro: play replays sequence", function()
    local h      = cmd.history()
    local state1 = { value = 0 }
    local state2 = { value = 0 }

    h:record()
      h:execute(set_value, nil, state1, { value = 10 })
      h:execute(set_value, nil, state1, { value = 20 })
    local macro = h:stop_record()

    T.eq(#macro, 2)
    T.eq(state1.value, 20)

    -- Play into state2 by overriding leading args
    local prev_depth = h:undo_depth()
    h:play(macro, nil, state2)
    T.eq(state2.value, 20)
    T.eq(h:undo_depth(), prev_depth + 2)
  end)

  T.it("undo returns false when stack empty", function()
    local h = cmd.history()
    local result = h:undo()
    T.fail(result)
  end)

  T.it("redo returns false when stack empty", function()
    local h = cmd.history()
    local result = h:redo()
    T.fail(result)
  end)

end)
