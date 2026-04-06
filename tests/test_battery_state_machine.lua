local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("entities.Entities")
require("entities.Battery")

local Battery = Medusa.Entities.Battery
local AS = Medusa.Constants.ActivationState
local BOS = Medusa.Constants.BatteryOperationalStatus
local BUR = Medusa.Constants.BatteryUnitRole

-- == Helpers ==

local function makeMinimalBattery(overrides)
	local data = {
		NetworkId = "net-1",
		GroupId = 100,
		GroupName = "sa6-1",
	}
	if overrides then
		for k, v in pairs(overrides) do
			data[k] = v
		end
	end
	return Battery.new(data)
end

local function makeUnit(roles)
	return Battery.newUnit({
		UnitId = math.random(1, 99999),
		Roles = roles,
		AmmoCount = 4,
	})
end

-- == TestCanTransition ==

TestCanTransition = {}

function TestCanTransition:test_allowsFirstTransition()
	local b = makeMinimalBattery()
	lu.assertTrue(Battery.canTransition(b, AS.STATE_HOT, 100))
end

function TestCanTransition:test_blocksSameState()
	local b = makeMinimalBattery()
	b.ActivationState = AS.STATE_HOT
	lu.assertFalse(Battery.canTransition(b, AS.STATE_HOT, 100))
end

function TestCanTransition:test_blocksWithinHoldDown()
	local b = makeMinimalBattery()
	b.ActivationState = AS.STATE_COLD
	b.LastStateChangeTime = 95
	b.StateChangeHoldDownSec = 10
	lu.assertFalse(Battery.canTransition(b, AS.STATE_HOT, 100))
end

function TestCanTransition:test_allowsAfterHoldDown()
	local b = makeMinimalBattery()
	b.ActivationState = AS.STATE_COLD
	b.LastStateChangeTime = 85
	b.StateChangeHoldDownSec = 10
	lu.assertTrue(Battery.canTransition(b, AS.STATE_HOT, 100))
end

function TestCanTransition:test_allowsWithoutHoldDown()
	local b = makeMinimalBattery()
	b.ActivationState = AS.STATE_COLD
	b.LastStateChangeTime = 99
	b.StateChangeHoldDownSec = nil
	lu.assertTrue(Battery.canTransition(b, AS.STATE_HOT, 100))
end

-- == TestTransitionTo ==

TestTransitionTo = {}

function TestTransitionTo:test_setsStateAndTime()
	local b = makeMinimalBattery()
	Battery.transitionTo(b, AS.STATE_HOT, 42)
	lu.assertEquals(b.ActivationState, AS.STATE_HOT)
	lu.assertEquals(b.LastStateChangeTime, 42)
end

function TestTransitionTo:test_returnsTrue()
	local b = makeMinimalBattery()
	lu.assertTrue(Battery.transitionTo(b, AS.STATE_COLD, 10))
end

-- == TestRecomputeOperationalStatus ==

TestRecomputeOperationalStatus = {}

function TestRecomputeOperationalStatus:test_destroyedWhenNoUnits()
	local b = makeMinimalBattery()
	b.Units = {}
	lu.assertEquals(Battery.recomputeOperationalStatus(b), BOS.DESTROYED)
end

function TestRecomputeOperationalStatus:test_destroyedWhenUnitsNil()
	local b = makeMinimalBattery()
	b.Units = nil
	lu.assertEquals(Battery.recomputeOperationalStatus(b), BOS.DESTROYED)
end

function TestRecomputeOperationalStatus:test_activeWhenFullyOperational()
	local b = makeMinimalBattery()
	b.Units = {
		makeUnit({ BUR.SEARCH_RADAR }),
		makeUnit({ BUR.TRACK_RADAR }),
		makeUnit({ BUR.LAUNCHER }),
	}
	b.TotalAmmoStatus = 4
	lu.assertEquals(Battery.recomputeOperationalStatus(b), BOS.ACTIVE)
end

function TestRecomputeOperationalStatus:test_inoperativeWhenNoTrackerNoLauncher()
	local b = makeMinimalBattery()
	b.Units = {
		makeUnit({ BUR.SEARCH_RADAR }),
		makeUnit({ BUR.COMMAND_POST }),
	}
	b.TotalAmmoStatus = 4
	lu.assertEquals(Battery.recomputeOperationalStatus(b), BOS.INOPERATIVE)
end

function TestRecomputeOperationalStatus:test_searchOnlyWhenNoTracker()
	local b = makeMinimalBattery()
	b.Units = {
		makeUnit({ BUR.SEARCH_RADAR }),
		makeUnit({ BUR.LAUNCHER }),
	}
	b.TotalAmmoStatus = 4
	lu.assertEquals(Battery.recomputeOperationalStatus(b), BOS.SEARCH_ONLY)
end

function TestRecomputeOperationalStatus:test_searchOnlyWhenNoLauncher()
	local b = makeMinimalBattery()
	b.Units = {
		makeUnit({ BUR.SEARCH_RADAR }),
		makeUnit({ BUR.TRACK_RADAR }),
	}
	b.TotalAmmoStatus = 4
	lu.assertEquals(Battery.recomputeOperationalStatus(b), BOS.SEARCH_ONLY)
end

function TestRecomputeOperationalStatus:test_ammoDepletedUsesAmmoDepletedBehavior()
	local b = makeMinimalBattery()
	b.Units = {
		makeUnit({ BUR.SEARCH_RADAR }),
		makeUnit({ BUR.TRACK_RADAR }),
		makeUnit({ BUR.LAUNCHER }),
	}
	b.TotalAmmoStatus = 0
	b.AmmoDepletedBehavior = "SEARCH_ONLY"
	lu.assertEquals(Battery.recomputeOperationalStatus(b), "SEARCH_ONLY")
end

function TestRecomputeOperationalStatus:test_ammoDepletedDefaultsToRearming()
	local b = makeMinimalBattery()
	b.Units = {
		makeUnit({ BUR.SEARCH_RADAR }),
		makeUnit({ BUR.TRACK_RADAR }),
		makeUnit({ BUR.LAUNCHER }),
	}
	b.TotalAmmoStatus = 0
	b.AmmoDepletedBehavior = nil
	lu.assertEquals(Battery.recomputeOperationalStatus(b), BOS.REARMING)
end

function TestRecomputeOperationalStatus:test_engagementImpairedWhenNoSearchRadar()
	local b = makeMinimalBattery()
	b.Units = {
		makeUnit({ BUR.TRACK_RADAR }),
		makeUnit({ BUR.LAUNCHER }),
	}
	b.TotalAmmoStatus = 4
	lu.assertEquals(Battery.recomputeOperationalStatus(b), BOS.ENGAGEMENT_IMPAIRED)
end

function TestRecomputeOperationalStatus:test_telarCountsAsTrackerAndLauncher()
	local b = makeMinimalBattery()
	b.Units = {
		makeUnit({ BUR.SEARCH_RADAR }),
		makeUnit({ BUR.TELAR }),
	}
	b.TotalAmmoStatus = 4
	lu.assertEquals(Battery.recomputeOperationalStatus(b), BOS.ACTIVE)
end

function TestRecomputeOperationalStatus:test_tlarCountsForAllRoles()
	local b = makeMinimalBattery()
	b.Units = {
		makeUnit({ BUR.TLAR }),
	}
	b.TotalAmmoStatus = 4
	lu.assertEquals(Battery.recomputeOperationalStatus(b), BOS.ACTIVE)
end

-- == TestComputeEffectiveRanges ==

TestComputeEffectiveRanges = {}

function TestComputeEffectiveRanges:test_normalRangesWhenSearchUp()
	local b = makeMinimalBattery()
	b.Units = { makeUnit({ BUR.SEARCH_RADAR }), makeUnit({ BUR.LAUNCHER }) }
	b.DetectionRangeMax = 100000
	b.WeaponRangeMax = 80000
	b.ReactionDelaySec = 5
	Battery.computeEffectiveRanges(b)
	lu.assertEquals(b.EffectiveDetectionRangeMax, 100000)
	lu.assertEquals(b.EffectiveReactionDelaySec, 5)
	lu.assertEquals(b.EngagementRangeMax, 80000)
end

function TestComputeEffectiveRanges:test_degradedWhenOptionalAndSearchDown()
	local b = makeMinimalBattery({ RadarDependencyPolicy = "OPTIONAL_DEGRADED" })
	b.Units = { makeUnit({ BUR.TRACK_RADAR }), makeUnit({ BUR.LAUNCHER }) }
	b.DetectionRangeMax = 100000
	b.WeaponRangeMax = 80000
	b.ReactionDelaySec = 5
	Battery.computeEffectiveRanges(b)
	-- 100000 * 60 / 100 = 60000
	lu.assertEquals(b.EffectiveDetectionRangeMax, 60000)
	-- ceil(5 * 1.5) = 8
	lu.assertEquals(b.EffectiveReactionDelaySec, 8)
	-- min(60000, 80000) = 60000
	lu.assertEquals(b.EngagementRangeMax, 60000)
end

function TestComputeEffectiveRanges:test_zeroRangeWhenRequiredAndSearchDown()
	local b = makeMinimalBattery()
	b.Units = { makeUnit({ BUR.TRACK_RADAR }), makeUnit({ BUR.LAUNCHER }) }
	b.DetectionRangeMax = 100000
	b.WeaponRangeMax = 80000
	b.ReactionDelaySec = 5
	Battery.computeEffectiveRanges(b)
	lu.assertEquals(b.EffectiveDetectionRangeMax, 0)
	lu.assertEquals(b.EffectiveReactionDelaySec, 5)
end

function TestComputeEffectiveRanges:test_tlarCountsAsSearchRadar()
	local b = makeMinimalBattery()
	b.Units = { makeUnit({ BUR.TLAR }) }
	b.DetectionRangeMax = 50000
	b.WeaponRangeMax = 40000
	b.ReactionDelaySec = 3
	Battery.computeEffectiveRanges(b)
	lu.assertEquals(b.EffectiveDetectionRangeMax, 50000)
	lu.assertEquals(b.EffectiveReactionDelaySec, 3)
end
