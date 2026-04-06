local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.C2Node")

-- == C2Node Entity Tests ==

TestC2Node = {}

local ulidCounter = 0

function TestC2Node:setUp()
	ulidCounter = 0
	NewULID = function()
		ulidCounter = ulidCounter + 1
		return string.format("ULID-%d", ulidCounter)
	end
end

function TestC2Node:test_missing_data_errors()
	lu.assertErrorMsgContains("data table is required", function()
		Medusa.Entities.C2Node.new(nil)
	end)
end

function TestC2Node:test_missing_network_id_errors()
	lu.assertErrorMsgContains("missing required field: NetworkId", function()
		Medusa.Entities.C2Node.new({})
	end)
end

