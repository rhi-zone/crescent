local script_dir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.+/)")
package.path = script_dir .. "../?.lua;" .. script_dir .. "../?/init.lua;" .. package.path
require("lib.cr").main(arg, script_dir)
