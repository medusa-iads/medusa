local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Constants")
require("entities.Battery")
require("services.Services")
require("services.AssetSpatialIndexService")

local C = Medusa.Constants
local BR = C.BatteryRole
local BUR = C.BatteryUnitRole
local AM = C.Aaa.Mode

local function battery(id, role)
	local value = {
		BatteryId = id,
		Role = role,
		Position = { x = 100, y = 0, z = 100 },
		Units = {},
	}
	if role == BR.AAA then
		value.Aaa = { Mode = AM.INDEPENDENT }
		value.Units[1] = { Roles = { BUR.AAA }, IsAlive = true }
	end
	return value
end

local function contains(grid, typeName, id)
	local result = grid:queryRadius({ x = 100, y = 0, z = 100 }, 1000, { typeName })
	local ids = result[typeName .. "Ids"] or {}
	return ids[id] == true
end

TestAssetSpatialIndexService = {}

function TestAssetSpatialIndexService:setUp()
	self.index = Medusa.Services.AssetSpatialIndexService:new(10000)
end

function TestAssetSpatialIndexService:test_routes_networked_and_local_defenses_to_separate_grids()
	local sam = battery("sam", BR.MR_SAM)
	local manpad = battery("manpad", BR.MANPAD)
	local aaa = battery("aaa", BR.AAA)

	self.index:syncBattery(sam)
	self.index:syncBattery(manpad)
	self.index:syncBattery(aaa)

	lu.assertTrue(contains(self.index:networkedGeoGrid(), "Battery", "sam"))
	lu.assertFalse(contains(self.index:networkedGeoGrid(), "Battery", "aaa"))
	lu.assertTrue(contains(self.index:localGeoGrid(), "Manpad", "manpad"))
	lu.assertTrue(contains(self.index:localGeoGrid(), "Aaa", "aaa"))
end

function TestAssetSpatialIndexService:test_aaa_is_withdrawn_while_capability_and_mode_disagree()
	local aaa = battery("aaa", BR.AAA)
	self.index:syncBattery(aaa)

	aaa.DetectionRangeMax = 20000
	aaa.Units[2] = { Roles = { BUR.SEARCH_RADAR }, IsAlive = true }
	self.index:syncBattery(aaa)

	lu.assertFalse(contains(self.index:networkedGeoGrid(), "Battery", "aaa"))
	lu.assertFalse(contains(self.index:localGeoGrid(), "Aaa", "aaa"))

	aaa.Aaa.Mode = AM.RADAR_DIRECTED
	self.index:syncBattery(aaa)
	lu.assertTrue(contains(self.index:networkedGeoGrid(), "Battery", "aaa"))
	lu.assertFalse(contains(self.index:localGeoGrid(), "Aaa", "aaa"))

	aaa.Units[2] = nil
	self.index:syncBattery(aaa)
	lu.assertFalse(contains(self.index:networkedGeoGrid(), "Battery", "aaa"))
	lu.assertFalse(contains(self.index:localGeoGrid(), "Aaa", "aaa"))

	aaa.Aaa.Mode = AM.INDEPENDENT
	self.index:syncBattery(aaa)
	lu.assertTrue(contains(self.index:localGeoGrid(), "Aaa", "aaa"))
end

function TestAssetSpatialIndexService:test_sync_and_remove_are_idempotent()
	local sam = battery("sam", BR.MR_SAM)

	self.index:syncBattery(sam)
	self.index:syncBattery(sam)
	lu.assertTrue(contains(self.index:networkedGeoGrid(), "Battery", "sam"))

	self.index:removeBattery("sam")
	self.index:removeBattery("sam")
	lu.assertFalse(contains(self.index:networkedGeoGrid(), "Battery", "sam"))
end
