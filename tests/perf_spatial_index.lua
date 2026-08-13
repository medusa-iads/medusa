local paths = {
	"./tests/?.lua",
	"./tests/mocks/?.lua",
	"./dependencies/?.lua",
	"./src/?.lua",
}
package.path = table.concat(paths, ";") .. ";" .. package.path

require("mocks.mock_dcs")
require("_header")
require("harness")
require("core.Constants")
require("entities.Battery")
require("services.Services")
require("services.AssetSpatialIndexService")

local BR = Medusa.Constants.BatteryRole
local AM = Medusa.Constants.Aaa.Mode
local NETWORKED_BATTERY_COUNT = 24
local LOCAL_AAA_COUNT = 66
local MANPAD_COUNT = 80
local QUERY_COUNT = 2000
local QUERY_RADIUS_M = 260000

local function position(index)
	return {
		x = (index % 12) * 5000,
		y = 0,
		z = math.floor(index / 12) * 5000,
	}
end

local function battery(id, role, index)
	local value = {
		BatteryId = id,
		Role = role,
		Position = position(index),
		Units = {},
	}
	if role == BR.AAA then
		value.Aaa = { Mode = AM.INDEPENDENT }
	end
	return value
end

local unified = GeoGrid(10000, { "Battery", "Track", "Manpad" })
local split = Medusa.Services.AssetSpatialIndexService:new(10000)

for i = 1, NETWORKED_BATTERY_COUNT do
	local value = battery("networked-" .. i, BR.MR_SAM, i)
	unified:add("Battery", value.BatteryId, value.Position)
	split:syncBattery(value)
end

for i = 1, LOCAL_AAA_COUNT do
	local value = battery("aaa-" .. i, BR.AAA, NETWORKED_BATTERY_COUNT + i)
	unified:add("Battery", value.BatteryId, value.Position)
	split:syncBattery(value)
end

for i = 1, MANPAD_COUNT do
	local value = battery("manpad-" .. i, BR.MANPAD, NETWORKED_BATTERY_COUNT + LOCAL_AAA_COUNT + i)
	unified:add("Manpad", value.BatteryId, value.Position)
	split:syncBattery(value)
end

local function measure(grid)
	local started = os.clock()
	local candidates = 0
	for _ = 1, QUERY_COUNT do
		local result = grid:queryRadius({ x = 0, y = 0, z = 0 }, QUERY_RADIUS_M, { "Battery" })
		for _ in pairs(result.BatteryIds) do
			candidates = candidates + 1
		end
	end
	return candidates, os.clock() - started
end

local unifiedCandidates, unifiedSeconds = measure(unified)
local networkedCandidates, networkedSeconds = measure(split:networkedGeoGrid())
local expectedUnified = QUERY_COUNT * (NETWORKED_BATTERY_COUNT + LOCAL_AAA_COUNT)
local expectedNetworked = QUERY_COUNT * NETWORKED_BATTERY_COUNT
assert(unifiedCandidates == expectedUnified)
assert(networkedCandidates == expectedNetworked)

io.write(
	string.format(
		"queries=%d unified_candidates=%d networked_candidates=%d reduction=%.1f%% unified_seconds=%.4f networked_seconds=%.4f\n",
		QUERY_COUNT,
		unifiedCandidates,
		networkedCandidates,
		(1 - networkedCandidates / unifiedCandidates) * 100,
		unifiedSeconds,
		networkedSeconds
	)
)
