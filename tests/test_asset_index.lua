local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("services.Services")
require("services.AssetIndex")

-- == Tests ==

TestAssetIndex = {}

function TestAssetIndex:test_accessors_return_stores()
	local mockStores = {
		sensors = { name = "sensors" },
		batteries = { name = "batteries" },
		c2Nodes = { name = "c2Nodes" },
		zones = { name = "zones" },
		airbases = { name = "airbases" },
		interceptors = { name = "interceptors" },
		tracks = { name = "tracks" },
		geoGrid = { name = "geoGrid" },
	}

	local index = Medusa.Services.AssetIndex.new(mockStores)

	lu.assertIs(index:sensors(), mockStores.sensors)
	lu.assertIs(index:batteries(), mockStores.batteries)
	lu.assertIs(index:c2Nodes(), mockStores.c2Nodes)
	lu.assertIs(index:zones(), mockStores.zones)
	lu.assertIs(index:airbases(), mockStores.airbases)
	lu.assertIs(index:interceptors(), mockStores.interceptors)
	lu.assertIs(index:tracks(), mockStores.tracks)
	lu.assertIs(index:geoGrid(), mockStores.geoGrid)
end

function TestAssetIndex:test_nil_store_returns_nil()
	local index = Medusa.Services.AssetIndex.new({})

	lu.assertIsNil(index:sensors())
	lu.assertIsNil(index:tracks())
end

function TestAssetIndex:test_multiple_instances_are_independent()
	local stores1 = { sensors = { id = 1 } }
	local stores2 = { sensors = { id = 2 } }

	local index1 = Medusa.Services.AssetIndex.new(stores1)
	local index2 = Medusa.Services.AssetIndex.new(stores2)

	lu.assertEquals(index1:sensors().id, 1)
	lu.assertEquals(index2:sensors().id, 2)
end
