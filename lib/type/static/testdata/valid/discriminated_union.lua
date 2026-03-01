-- Discriminated union narrowing via tag field.
--:: NumNode = { tag: "number", value: number }
--:: StrNode = { tag: "string", value: string }
--:: Node = NumNode | StrNode

local function process(node) --: (Node) -> number
  if node.tag == "number" then
    return node.value + 1
  end
  return 0
end
