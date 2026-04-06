local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.Battery")

-- == Helpers ==

local function makeBattery(overrides)
	local b = {
		Units = {},
		DetectionRangeMax = nil,
		WeaponRangeMax = nil,
		EngagementRangeMax = nil,
		EngagementRangeMin = nil,
		EngagementAltitudeMax = nil,
		EngagementAltitudeMin = nil,
		TotalAmmoStatus = 0,
	}
	if overrides then
		for k, v in pairs(overrides) do
			b[k] = v
		end
	end
	return b
end

local function makeUnit(role, ammoCount, ammoTypes)
	return {
		UnitId = 1,
		Roles = { role },
		AmmoCount = ammoCount,
		AmmoTypes = ammoTypes,
		OperationalStatus = "ACTIVE",
		RadarStatus = "NA",
	}
end

-- == Tests ==

TestAmmoExtraction = {}

function TestAmmoExtraction:test_recompute_single_launcher()
	local battery = makeBattery({
		Units = {
			makeUnit("LAUNCHER", 4, {
				{ WeaponTypeName = "5V55", Count = 4, RangeMax = 75000, RangeMin = 5000, AltMax = 25000, AltMin = 25 },
			}),
		},
	})

	Medusa.Entities.Battery.recomputeEnvelope(battery)

	lu.assertEquals(battery.WeaponRangeMax, 75000)
	lu.assertEquals(battery.EngagementRangeMin, 5000)
	lu.assertEquals(battery.TotalAmmoStatus, 4)
end

function TestAmmoExtraction:test_recompute_multiple_launchers()
	local battery = makeBattery({
		Units = {
			makeUnit("LAUNCHER", 4, {
				{ WeaponTypeName = "5V55", Count = 4, RangeMax = 75000, RangeMin = 5000, AltMax = 25000, AltMin = 25 },
			}),
			makeUnit("LAUNCHER", 2, {
				{ WeaponTypeName = "48N6", Count = 2, RangeMax = 150000, RangeMin = 3000, AltMax = 30000, AltMin = 10 },
			}),
		},
	})

	Medusa.Entities.Battery.recomputeEnvelope(battery)

	lu.assertEquals(battery.WeaponRangeMax, 150000)
	lu.assertEquals(battery.EngagementRangeMin, 3000)
	lu.assertEquals(battery.TotalAmmoStatus, 6)
end

function TestAmmoExtraction:test_recompute_ignores_non_launcher()
	local battery = makeBattery({
		Units = {
			makeUnit("OTHER", 4, {
				{ WeaponTypeName = "5V55", Count = 4, RangeMax = 75000, RangeMin = 5000, AltMax = 25000, AltMin = 25 },
			}),
		},
	})

	Medusa.Entities.Battery.recomputeEnvelope(battery)

	lu.assertIsNil(battery.WeaponRangeMax)
	lu.assertEquals(battery.TotalAmmoStatus, 0)
end

function TestAmmoExtraction:test_recompute_ignores_empty_ammo()
	local battery = makeBattery({
		Units = {
			makeUnit("LAUNCHER", 0, {
				{ WeaponTypeName = "5V55", Count = 0, RangeMax = 75000, RangeMin = 5000, AltMax = 25000, AltMin = 25 },
			}),
		},
	})

	Medusa.Entities.Battery.recomputeEnvelope(battery)

	lu.assertIsNil(battery.WeaponRangeMax)
	lu.assertEquals(battery.TotalAmmoStatus, 0)
end

function TestAmmoExtraction:test_recompute_telar_counted()
	local battery = makeBattery({
		Units = {
			makeUnit("TELAR", 6, {
				{ WeaponTypeName = "9M330", Count = 6, RangeMax = 12000, RangeMin = 1500, AltMax = 6000, AltMin = 10 },
			}),
		},
	})

	Medusa.Entities.Battery.recomputeEnvelope(battery)

	lu.assertEquals(battery.WeaponRangeMax, 12000)
	lu.assertEquals(battery.TotalAmmoStatus, 6)
end

function TestAmmoExtraction:test_recompute_tlar_counted()
	local battery = makeBattery({
		Units = {
			makeUnit("TLAR", 8, {
				{ WeaponTypeName = "9M331", Count = 8, RangeMax = 15000, RangeMin = 1000, AltMax = 6000, AltMin = 15 },
			}),
		},
	})

	Medusa.Entities.Battery.recomputeEnvelope(battery)

	lu.assertEquals(battery.WeaponRangeMax, 15000)
	lu.assertEquals(battery.TotalAmmoStatus, 8)
end

function TestAmmoExtraction:test_engagement_range_min_of_detection_and_weapon()
	local battery = makeBattery({ DetectionRangeMax = 200000 })
	battery.Units = {
		makeUnit("LAUNCHER", 4, {
			{ WeaponTypeName = "5V55", Count = 4, RangeMax = 75000, RangeMin = 5000, AltMax = 25000, AltMin = 25 },
		}),
	}

	Medusa.Entities.Battery.recomputeEnvelope(battery)

	lu.assertEquals(battery.EngagementRangeMax, 75000)
end

function TestAmmoExtraction:test_engagement_range_weapon_limited()
	local battery = makeBattery()
	battery.Units = {
		makeUnit("LAUNCHER", 4, {
			{ WeaponTypeName = "5V55", Count = 4, RangeMax = 50000, RangeMin = 5000, AltMax = 25000, AltMin = 25 },
		}),
	}

	Medusa.Entities.Battery.recomputeEnvelope(battery)

	lu.assertEquals(battery.EngagementRangeMax, 50000)
end

function TestAmmoExtraction:test_engagement_range_detection_limited()
	local battery = makeBattery({ DetectionRangeMax = 80000 })

	Medusa.Entities.Battery.recomputeEnvelope(battery)

	lu.assertEquals(battery.EngagementRangeMax, 80000)
end

function TestAmmoExtraction:test_engagement_range_detection_wins()
	local battery = makeBattery({ DetectionRangeMax = 60000 })
	battery.Units = {
		makeUnit("LAUNCHER", 4, {
			{ WeaponTypeName = "48N6", Count = 4, RangeMax = 100000, RangeMin = 3000, AltMax = 30000, AltMin = 10 },
		}),
	}

	Medusa.Entities.Battery.recomputeEnvelope(battery)

	lu.assertEquals(battery.EngagementRangeMax, 60000)
end

function TestAmmoExtraction:test_recompute_altitude_envelope()
	local battery = makeBattery({
		Units = {
			makeUnit("LAUNCHER", 4, {
				{ WeaponTypeName = "5V55", Count = 2, RangeMax = 75000, RangeMin = 5000, AltMax = 25000, AltMin = 25 },
				{ WeaponTypeName = "48N6", Count = 2, RangeMax = 150000, RangeMin = 3000, AltMax = 30000, AltMin = 10 },
			}),
		},
	})

	Medusa.Entities.Battery.recomputeEnvelope(battery)

	lu.assertEquals(battery.EngagementAltitudeMax, 30000)
	lu.assertEquals(battery.EngagementAltitudeMin, 10)
end

-- Integration test: full pipeline from EntityFactory with ammo data

TestAmmoIntegration = {}

local origGetGroupUnits, origGetUnitDesc, origGetUnitID, origGetUnitType, origGetUnitPosition, origGetUnitAmmo

function TestAmmoIntegration:setUp()
	NewULID = function()
		return "TEST-ULID"
	end
	origGetGroupUnits = GetGroupUnits
	origGetUnitDesc = GetUnitDesc
	origGetUnitID = GetUnitID
	origGetUnitType = GetUnitType
	origGetUnitPosition = GetUnitPosition
	origGetUnitAmmo = GetUnitAmmo
end

function TestAmmoIntegration:tearDown()
	GetGroupUnits = origGetGroupUnits
	GetUnitDesc = origGetUnitDesc
	GetUnitID = origGetUnitID
	GetUnitType = origGetUnitType
	GetUnitPosition = origGetUnitPosition
	GetUnitAmmo = origGetUnitAmmo
end

function TestAmmoIntegration:test_ammo_via_entity_factory()
	require("entities.SensorUnit")
	require("entities.C2Node")
	require("services.Services")
	require("services.stores.BatteryStore")
	require("services.stores.SensorUnitStore")
	require("services.stores.C2NodeStore")
	require("services.EntityFactory")

	local mockUnit = {
		getID = function()
			return 1
		end,
		getName = function()
			return "sa10-launcher"
		end,
		getPosition = function()
			return { p = { x = 100, y = 50, z = 200 } }
		end,
	}

	GetGroupUnits = function()
		return { mockUnit }
	end
	GetUnitID = function()
		return 1
	end
	GetUnitType = function()
		return "S-300PS 5P85C ln"
	end
	GetUnitPosition = function()
		return { x = 100, y = 0, z = 200 }
	end
	GetUnitDesc = function()
		return { attributes = { ["SAM LL"] = true, ["LR SAM"] = true } }
	end
	GetUnitAmmo = function()
		return {
			{
				count = 4,
				desc = {
					typeName = "5V55",
					missileCategory = 2,
					rangeMaxAltMax = 75000,
					rangeMin = 5000,
					altMax = 25000,
					altMin = 25,
				},
			},
		}
	end

	local stores = {
		batteries = Medusa.Services.BatteryStore:new(),
		sensors = Medusa.Services.SensorUnitStore:new(),
		c2Nodes = Medusa.Services.C2NodeStore:new(),
	}
	local dto = { groupId = 1, groupName = "test.group", parsed = { roles = {}, echelonPath = {}, isHQ = false } }

	Medusa.Services.EntityFactory.createFromDTO(dto, stores, "net1")

	local battery = stores.batteries:getAll()[1]
	lu.assertNotNil(battery)
	lu.assertEquals(battery.Role, "LR_SAM")
	lu.assertEquals(battery.Units[1].Roles[1], "LAUNCHER")
	lu.assertEquals(battery.Units[1].AmmoCount, 4)
	lu.assertEquals(battery.WeaponRangeMax, 75000)
	lu.assertEquals(battery.EngagementRangeMin, 5000)
	lu.assertEquals(battery.EngagementAltitudeMax, 25000)
	lu.assertEquals(battery.EngagementAltitudeMin, 25)
	lu.assertEquals(battery.TotalAmmoStatus, 4)
	lu.assertEquals(battery.EngagementRangeMax, 75000)
end
