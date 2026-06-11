-- Fixture: coinductive / recursive type cycles (fp/maybe, fp/either, hamt pattern)
--
-- Source fire: docs/agnostic-static-analysis-design.md "First Validation
--   Ladder" §5 names "stack-overflow triggers (`lib/hamt`, `lib/fp/maybe`,
--   `lib/fp/either`)" as part of the acceptance corpus. Both fp/maybe and
--   fp/either use self-referential or deeply-recursive Lua patterns that
--   stress termination in type-equality and subtyping checks.
--
-- What a CORRECT checker must conclude:
--   Accepts a self-referential type alias (TreeNode whose children are
--   TreeNode | nil) and a discriminated Maybe-like union without crashing or
--   diverging. Recursion on a value of the recursive type must typecheck: the
--   base case (nil child / nothing) terminates structural descent and the
--   recursive case preserves the declared type. No stack overflow.
--
-- Feature families:
--   - Self-referential / coinductive recursive type aliases
--   - Union types with recursive members (`TreeNode | nil`)
--   - Termination: type-equality and subtyping under recursive types
--   - Discriminated narrowing on recursive unions (`is_just` boolean flag)
--   - Recursive function calls on recursively-typed values
--
-- Legacy verdict (CURRENT checker): 0 errors. The stack-overflow triggers
--   in fp/maybe and fp/either (referenced in the design doc) are FIXED in
--   the current checker via the cycle guard added in commit 56810b60 and
--   related fixes. This fixture records the minimum structural shape that
--   must continue to be accepted; regression protection.

--:: MaybeInt = { is_just: boolean, value: integer | nil }
--:: TreeNode = { value: integer, left: TreeNode | nil, right: TreeNode | nil }

--: (MaybeInt, MaybeInt) -> MaybeInt
local function maybe_or(a, b)
  if a.is_just then return a end
  return b
end

--: (integer | nil) -> MaybeInt
local function maybe_of(v)
  if v == nil then
    return { is_just = false, value = nil }
  end
  return { is_just = true, value = v }
end

--: (TreeNode) -> integer
local function tree_sum(node)
  local s = node.value
  if node.left then
    s = s + tree_sum(node.left)
  end
  if node.right then
    s = s + tree_sum(node.right)
  end
  return s
end

return { maybe_or = maybe_or, maybe_of = maybe_of, tree_sum = tree_sum }
