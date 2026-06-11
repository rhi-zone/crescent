-- Fixture: equirecursive union — legacy checker stack-overflow trigger
--
-- Source fire: lib/hamt/init.lua; commit 56810b60 ("fix(type/static):
--   meta_op_ret_impl cycle guard for self-referential unions"). The commit
--   message confirms: "single-file `bin/cr check lib/hamt/init.lua`
--   reproduces deterministically" (stack overflow, no diagnostics emitted).
--
-- What a CORRECT checker must conclude:
--   Accepts the module without crashing or producing a stack overflow.
--   Inside the `if ntype == NODE_LEAF then` branch, `node.key` is accessible
--   (narrowed from HamtNode to Leaf, because only Leaf has `key`). The
--   recursive HamtNode definition (Interior.children contains HamtNode) must
--   not cause the checker to recurse infinitely when resolving field access or
--   operator dispatch.
--
-- Feature families (per docs/typechecker-reference.md):
--   - Union types (| operator)
--   - Type aliases (--:: decl) — recursive / equirecursive
--   - Integer-tag discriminated narrowing on union members
--   - Termination: checker must not diverge on self-referential union arms
--
-- Legacy verdict: the legacy checker (pre-56810b60) produced a C stack
--   overflow and emitted no diagnostics. The fix in 56810b60 added a `seen`
--   set to meta_op_ret_impl. The CURRENT checker accepts this file with
--   lint-level force-cast warnings (CLAUDE.md lint rule discourages
--   --[[:! T]] when upstream annotation could be added); the type narrowing
--   via integer tag is NOT supported without an explicit cast — a correct
--   future checker should narrow without a cast.

--:: Leaf      = { kind: integer, key: unknown }
--:: Interior  = { kind: integer, children: { [integer]: HamtNode } }
--:: HamtNode  = Leaf | Interior

local NODE_LEAF     = 1
local NODE_INTERIOR = 2

--: (node: HamtNode, key: unknown) -> unknown
local function lookup(node, key)
  local ntype = node.kind
  if ntype == NODE_LEAF then
    -- A correct checker narrows `node` to `Leaf` here (integer-tag discrimination).
    -- The current checker requires a force cast to access `node.key`.
    local leaf = node --[[:! Leaf]]
    if leaf.key == key then return true end
    return nil
  elseif ntype == NODE_INTERIOR then
    local inode = node --[[:! Interior]]
    for _, child in pairs(inode.children) do
      local r = lookup(child, key)
      if r ~= nil then return r end
    end
    return nil
  end
  return nil
end

return { lookup = lookup }
