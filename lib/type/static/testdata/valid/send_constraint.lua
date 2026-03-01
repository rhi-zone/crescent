-- x:method(arg) on an unbound var: typechecker infers x has the method, no error
local function call_upper(x)
  return x:upper()
end
