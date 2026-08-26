local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.C2Node")

-- == C2Node Entity Tests ==

TestC2Node = {}

function TestC2Node:test_missing_data_errors()
	lu.assertErrorMsgContains("data table is required", function()
		Medusa.Entities.C2Node.new(nil)
	end)
end

function TestC2Node:test_missing_node_name_errors()
	lu.assertErrorMsgContains("missing required field: NodeName", function()
		Medusa.Entities.C2Node.new({})
	end)
end
