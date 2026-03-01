-- Calling a method on an uninitialized (nil) variable.
local x
local result = x:match("pattern")
