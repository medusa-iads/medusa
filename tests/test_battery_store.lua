local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("services.Services")
require("services.stores.BatteryStore")

-- == Helpers ==

local function makeBattery(batteryId, groupId)
	return {
		BatteryId = batteryId,
		GroupId = groupId,
		Role = Medusa.Constants.BatteryRole.SR_SAM,
		Units = {},
	}
end

local function makeManpad(batteryId, groupId, unitId)
	return {
		BatteryId = batteryId,
		GroupId = groupId,
		Role = Medusa.Constants.BatteryRole.MANPAD,
		Manpad = {
			SleepWakeState = Medusa.Constants.Manpad.SleepWakeState.ASLEEP,
			WakeReason = Medusa.Constants.Manpad.WakeReason.NONE,
			AlertCycleCount = 0,
			LastAlertedTime = nil,
			AudioCueRangeM = 3000,
			UnitHeadings = {},
			UnitHeadingCount = 0,
		},
		Units = {
			{
				UnitId = unitId,
			},
		},
	}
end

-- == Tests ==

TestBatteryStore = {}

function TestBatteryStore:setUp()
	self.store = Medusa.Services.BatteryStore:new()
end

function TestBatteryStore:test_add_and_get()
	local battery = makeBattery("bat-1", 100)
	self.store:add(battery)

	lu.assertEquals(self.store:count(), 1)
	lu.assertIs(self.store:get("bat-1"), battery)
end

function TestBatteryStore:test_capacity_rejects_additional_battery_without_growth()
	for i = 1, Medusa.Constants.C2.MAX_BATTERIES do
		self.store:add(makeBattery("bat-" .. i, i))
	end

	lu.assertError(function()
		self.store:add(makeBattery("overflow", 1000))
	end)
	lu.assertEquals(self.store:count(), Medusa.Constants.C2.MAX_BATTERIES)
	lu.assertNil(self.store:get("overflow"))
end

function TestBatteryStore:test_add_duplicate_errors()
	self.store:add(makeBattery("bat-1", 100))

	lu.assertErrorMsgContains("duplicate BatteryId: bat-1", function()
		self.store:add(makeBattery("bat-1", 200))
	end)
end

function TestBatteryStore:test_get_returns_nil_for_unknown()
	lu.assertIsNil(self.store:get("no-such-id"))
end

function TestBatteryStore:test_getByGroupId()
	local battery = makeBattery("bat-1", 100)
	self.store:add(battery)

	lu.assertIs(self.store:getByGroupId(100), battery)
end

function TestBatteryStore:test_getByGroupId_returns_nil_for_unknown()
	lu.assertIsNil(self.store:getByGroupId(999))
end

function TestBatteryStore:test_remove_returns_battery()
	local battery = makeBattery("bat-1", 100)
	self.store:add(battery)

	local removed = self.store:remove("bat-1")
	lu.assertIs(removed, battery)
	lu.assertEquals(self.store:count(), 0)
end

function TestBatteryStore:test_remove_clears_both_indexes()
	local battery = makeBattery("bat-1", 100)
	self.store:add(battery)
	self.store:remove("bat-1")

	lu.assertIsNil(self.store:get("bat-1"))
	lu.assertIsNil(self.store:getByGroupId(100))
end

function TestBatteryStore:test_remove_unknown_returns_nil()
	lu.assertIsNil(self.store:remove("no-such-id"))
end

function TestBatteryStore:test_getAll_returns_all_batteries()
	self.store:add(makeBattery("bat-1", 100))
	self.store:add(makeBattery("bat-2", 200))
	self.store:add(makeBattery("bat-3", 300))

	local all = self.store:getAll()
	lu.assertEquals(#all, 3)
end

function TestBatteryStore:test_getAll_reuses_output_table()
	self.store:add(makeBattery("bat-1", 100))
	self.store:add(makeBattery("bat-2", 200))

	local buffer = { "stale-entry-1", "stale-entry-2", "stale-entry-3" }
	local result = self.store:getAll(buffer)

	lu.assertIs(result, buffer)
	lu.assertEquals(#result, 2)
end

function TestBatteryStore:test_getAll_empty_store()
	local all = self.store:getAll()
	lu.assertEquals(#all, 0)
end

function TestBatteryStore:test_count_tracks_add_and_remove()
	self.store:add(makeBattery("bat-1", 100))
	self.store:add(makeBattery("bat-2", 200))
	lu.assertEquals(self.store:count(), 2)

	self.store:remove("bat-1")
	lu.assertEquals(self.store:count(), 1)

	self.store:remove("bat-2")
	lu.assertEquals(self.store:count(), 0)
end

function TestBatteryStore:test_partition_views_are_structurally_isolated()
	local battery = makeBattery("bat-1", 100)
	local manpad = makeManpad("manpad-1", 200, 300)
	self.store:add(battery)
	self.store:add(manpad)

	local batteries = self.store:batteries()
	local manpads = self.store:manpads()

	lu.assertEquals(self.store:count(), 2)
	lu.assertEquals(batteries:count(), 1)
	lu.assertEquals(manpads:count(), 1)
	lu.assertIs(batteries:get("bat-1"), battery)
	lu.assertIsNil(batteries:get("manpad-1"))
	lu.assertIs(manpads:get("manpad-1"), manpad)
	lu.assertIsNil(manpads:get("bat-1"))
end

function TestBatteryStore:test_battery_entity_owns_manpad_wake_reason_default()
	local manpadState = makeManpad("manpad-default", 210, 310).Manpad
	manpadState.WakeReason = nil
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "test-network",
		GroupId = 210,
		GroupName = "manpad-default",
		Role = Medusa.Constants.BatteryRole.MANPAD,
		Manpad = manpadState,
	})

	lu.assertEquals(battery.Manpad.WakeReason, Medusa.Constants.Manpad.WakeReason.NONE)
end

function TestBatteryStore:test_unit_index_tracks_add_unit_removal_and_battery_removal()
	local manpad = makeManpad("manpad-1", 200, 300)
	manpad.Units[1].UnitName = "manpad-1-1"
	manpad.Units[2] = { UnitId = 301, UnitName = "manpad-1-2" }
	self.store:add(manpad)

	local indexedBattery, indexedUnit = self.store:getByUnitId(301)
	lu.assertIs(indexedBattery, manpad)
	lu.assertIs(indexedUnit, manpad.Units[2])

	local removedBattery, removedUnit = self.store:removeUnit(300)
	lu.assertIs(removedBattery, manpad)
	lu.assertEquals(removedUnit.UnitId, 300)
	lu.assertIsNil(self.store:getByUnitId(300))
	lu.assertIsNil(self.store:resolveUnit(nil, "manpad-1-1"))
	lu.assertEquals(#manpad.Units, 1)

	self.store:remove("manpad-1")
	lu.assertIsNil(self.store:getByUnitId(301))
	lu.assertIsNil(self.store:resolveUnit(nil, "manpad-1-2"))
end

function TestBatteryStore:test_resolveUnit_uses_exact_name_when_event_id_is_not_indexed()
	local battery = makeManpad("scenario-one-sa10", 11, 100072)
	battery.Units[1].UnitName = "pvo.4d.606zrp.1bn-10"
	self.store:add(battery)

	local resolvedBattery, resolvedUnit, source = self.store:resolveUnit(72, "pvo.4d.606zrp.1bn-10")

	lu.assertIs(resolvedBattery, battery)
	lu.assertIs(resolvedUnit, battery.Units[1])
	lu.assertEquals(source, "unit-name")
	lu.assertIs(self.store:getByUnitId(72), battery)
end

function TestBatteryStore:test_resolveUnit_replaces_the_bounded_event_id_alias()
	local battery = makeManpad("scenario-one-sa10", 11, 100072)
	battery.Units[1].UnitName = "pvo.4d.606zrp.1bn-10"
	self.store:add(battery)

	self.store:resolveUnit(72, "pvo.4d.606zrp.1bn-10")
	self.store:resolveUnit(73, "pvo.4d.606zrp.1bn-10")

	lu.assertNil(self.store:getByUnitId(72))
	lu.assertIs(self.store:getByUnitId(73), battery)
	lu.assertIs(self.store:getByUnitId(100072), battery)
end

function TestBatteryStore:test_resolveUnit_rejects_conflicting_id_and_name_owners()
	local byId = makeManpad("by-id", 201, 72)
	byId.Units[1].UnitName = "other-launcher"
	local byName = makeManpad("by-name", 202, 100072)
	byName.Units[1].UnitName = "pvo.4d.606zrp.1bn-10"
	self.store:add(byId)
	self.store:add(byName)

	local battery, unit, source = self.store:resolveUnit(72, "pvo.4d.606zrp.1bn-10")

	lu.assertNil(battery)
	lu.assertNil(unit)
	lu.assertEquals(source, "identity-conflict")
end

function TestBatteryStore:test_position_refresh_cursor_rotates_live_units()
	local manpad = makeManpad("manpad-1", 200, 300)
	manpad.Units[2] = { UnitId = 301 }
	self.store:add(manpad)

	local _, first = self.store:nextUnitForPositionRefresh()
	local _, second = self.store:nextUnitForPositionRefresh()
	local _, wrapped = self.store:nextUnitForPositionRefresh()
	lu.assertEquals(first.UnitId, 300)
	lu.assertEquals(second.UnitId, 301)
	lu.assertEquals(wrapped.UnitId, 300)

	self.store:removeUnit(300)
	local _, remaining = self.store:nextUnitForPositionRefresh()
	lu.assertEquals(remaining.UnitId, 301)
end

function TestBatteryStore:test_rejects_duplicate_group_and_unit_identifiers_without_partial_add()
	local existing = makeManpad("manpad-1", 200, 300)
	existing.Units[1].UnitName = "managed-unit"
	self.store:add(existing)

	lu.assertErrorMsgContains("duplicate GroupId: 200", function()
		self.store:add(makeManpad("manpad-2", 200, 301))
	end)
	lu.assertErrorMsgContains("duplicate UnitId: 300", function()
		self.store:add(makeManpad("manpad-3", 201, 300))
	end)
	local duplicateName = makeManpad("manpad-4", 203, 303)
	duplicateName.Units[1].UnitName = "managed-unit"
	lu.assertErrorMsgContains("duplicate UnitName: managed-unit", function()
		self.store:add(duplicateName)
	end)

	lu.assertEquals(self.store:count(), 1)
	lu.assertIsNil(self.store:get("manpad-2"))
	lu.assertIsNil(self.store:get("manpad-3"))
	lu.assertIsNil(self.store:get("manpad-4"))
end

function TestBatteryStore:test_manpad_role_and_state_must_match()
	local invalidManpad = makeBattery("manpad-1", 200)
	invalidManpad.Role = Medusa.Constants.BatteryRole.MANPAD
	lu.assertErrorMsgContains("MANPAD battery requires Manpad state", function()
		self.store:add(invalidManpad)
	end)

	local invalidBattery = makeBattery("bat-1", 100)
	invalidBattery.Manpad = {}
	lu.assertErrorMsgContains("non-MANPAD battery cannot have Manpad state", function()
		self.store:add(invalidBattery)
	end)

	local invalidState = makeManpad("manpad-2", 201, 301)
	invalidState.Manpad.SleepWakeState = "INVALID"
	lu.assertErrorMsgContains("invalid MANPAD SleepWakeState", function()
		self.store:add(invalidState)
	end)

	local invalidWakeReason = makeManpad("manpad-3", 202, 302)
	invalidWakeReason.Manpad.WakeReason = "INVALID"
	lu.assertErrorMsgContains("invalid MANPAD WakeReason", function()
		self.store:add(invalidWakeReason)
	end)

	local missingWakeReason = makeManpad("manpad-missing-reason", 212, 312)
	missingWakeReason.Manpad.WakeReason = nil
	lu.assertErrorMsgContains("invalid MANPAD WakeReason", function()
		self.store:add(missingWakeReason)
	end)

	local invalidCycleCount = makeManpad("manpad-4", 203, 303)
	invalidCycleCount.Manpad.AlertCycleCount = -1
	lu.assertErrorMsgContains("MANPAD AlertCycleCount must be a non-negative integer", function()
		self.store:add(invalidCycleCount)
	end)

	local invalidAlertedTime = makeManpad("manpad-5", 204, 304)
	invalidAlertedTime.Manpad.LastAlertedTime = "yesterday"
	lu.assertErrorMsgContains("MANPAD LastAlertedTime must be a number", function()
		self.store:add(invalidAlertedTime)
	end)

	local invalidAudioRange = makeManpad("manpad-6", 205, 305)
	invalidAudioRange.Manpad.AudioCueRangeM = Medusa.Constants.Manpad.AUDIO_RANGE_MAX_M + 1
	lu.assertErrorMsgContains("MANPAD AudioCueRangeM must be within the supported range", function()
		self.store:add(invalidAudioRange)
	end)

	local invalidHeadingCount = makeManpad("manpad-7", 206, 306)
	invalidHeadingCount.Manpad.UnitHeadingCount = 0.5
	lu.assertErrorMsgContains("MANPAD UnitHeadingCount must be a non-negative integer", function()
		self.store:add(invalidHeadingCount)
	end)
end

function TestBatteryStore:test_manpad_audio_range_accepts_zero()
	local manpad = makeManpad("manpad-zero-audio", 207, 307)
	manpad.Manpad.AudioCueRangeM = 0
	self.store:add(manpad)
	lu.assertEquals(self.store:get("manpad-zero-audio").Manpad.AudioCueRangeM, 0)
end
