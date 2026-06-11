-- Fixture: locals from function-call returns not narrowed without annotation
--
-- Source fire: lib/taskgraph/exec.lua lines 27-30, lib/taskgraph/context.lua
--   lines 54-57. Comment: "Annotate as TaskNode | nil so narrowing works
--   (known typechecker gap: locals from function call returns aren't narrowed
--   without annotation)."
--
-- What a CORRECT checker must conclude:
--   After `local task = get_task(id)` where `get_task` is declared to return
--   `TaskNode | nil`, the checker must infer `task: TaskNode | nil` and must
--   narrow `task` to `TaskNode` inside an `if task then` branch — WITHOUT
--   requiring an explicit `--: TaskNode | nil` annotation on the local
--   declaration. The annotation must be optional, not load-bearing for
--   narrowing. Accessing `task.done` after the nil-guard must succeed.
--
-- Feature families:
--   - Local variable type inference from function call return annotation
--   - Nil-narrowing / truthiness narrowing (`if not task then return end`)
--   - Union types (`T | nil`)
--   - Flow-sensitive narrowing post-guard
--
-- Legacy verdict (CURRENT checker): accepts the unannotated form with 0
--   errors. The gap documented in the source comments is FIXED in the
--   current checker. This fixture records the gap's presence (it was real
--   at the time the workaround was added) and confirms the fix holds.
--   A future checker must also accept this (0 errors).

--:: TaskNode = { id: string, done: boolean }

--: (string) -> (TaskNode | nil)
local function get_task(id)
  if id == "root" then
    return { id = "root", done = false }
  end
  return nil
end

--: (string) -> boolean
local function task_done_with_annotation(id)
  -- Original workaround: explicit annotation made narrowing work.
  local task = get_task(id) --: TaskNode | nil
  if not task then return false end
  return task.done
end

--: (string) -> boolean
local function task_done_without_annotation(id)
  -- Gap: without the annotation, legacy checker did not narrow `task`.
  -- A correct checker must accept this with 0 errors.
  local task = get_task(id)
  if not task then return false end
  return task.done
end

return { task_done_with_annotation = task_done_with_annotation,
         task_done_without_annotation = task_done_without_annotation }
