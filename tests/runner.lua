-- Unit test runner for Medusa

-- Ensure local test paths are available for require()
local test_paths = {
	"./tests/?.lua",
	"./tests/mocks/?.lua",
	"./tests/luaunit/?.lua",
	"./dependencies/?.lua",
	"./src/?.lua",
}
package.path = table.concat(test_paths, ";") .. ";" .. package.path

-- Load luaunit
local lu = require("luaunit")
assert(lu, "luaunit should be defined")

-- Load mocks
local mock_dcs = require("mocks.mock_dcs")
assert(mock_dcs, "mock_dcs should be defined")

-- Require header to establish globals (Medusa table, etc.)
require("_header")

-- Load harness into test runtime for std helpers (StartsWith, SplitString, ScheduleOnce, etc.)
require("harness")

-- Discover and load all test_*.lua files and run them with luaunit
local function is_windows()
	return package.config:sub(1, 1) == "\\"
end

local function list_test_files()
	local command = is_windows() and "dir /b tests\\test_*.lua" or "ls -1 tests/test_*.lua 2>/dev/null"
	local handle = io.popen(command)
	if not handle then
		return {}
	end
	local files = {}
	for line in handle:lines() do
		if line and #line > 0 then
			table.insert(files, line)
		end
	end
	handle:close()
	return files
end

for _, filepath in ipairs(list_test_files()) do
	-- Normalize to module name (strip directory and .lua extension)
	local module_name = filepath:gsub("^.+[\\/]", ""):gsub("%.lua$", "")
	require(module_name)
end

os.exit(lu.LuaUnit.run())
