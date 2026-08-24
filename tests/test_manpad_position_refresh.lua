local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("services.Services")
require("entities.Battery")
require("services.BatteryActivationService")
require("services.ManpadService")
require("observability.MetricsService")
local ManpadTest = require("manpad_test_support")

-- ============================================================
-- Test coverage: ManpadService.refreshOnePosition
--
-- Contract:
--   refreshOnePosition(ctx) where ctx = { manpadStore, geoGrid, now, posRefreshBatteryId }
--   Advances the caller-owned round-robin cursor over store contents.
--   Refreshes at most one battery per call when all conditions hold.
--   No return value.
-- ============================================================

local _refreshCtx
local function cursor()
	return _refreshCtx.posRefreshBatteryId
end

local function refresh(store, grid, now)
	_refreshCtx.manpadStore = store
	_refreshCtx.geoGrid = grid
	_refreshCtx.now = now
	Medusa.Services.ManpadService.refreshOnePosition(_refreshCtx)
end

-- ============================================================
-- Module-level saved originals (restored in tearDown)
-- ============================================================

local _origGetUnitPosition
local _origMetricsInc

-- ============================================================
-- Builder helpers
-- ============================================================

local _seq = 0
local function nextId()
	_seq = _seq + 1
	return string.format("manpad-bat-%d", _seq)
end

--- makeManpad builds a minimal MANPAD Battery DTO.
--- Accepts an overrides table; Manpad sub-keys are merged into the default Manpad table.
local function makeManpad(overrides)
	local bat = {
		BatteryId = nextId(),
		Role = Medusa.Constants.BatteryRole.MANPAD,
		Position = nil,
		Units = {
			{ UnitName = "unit-alpha", Roles = { Medusa.Constants.BatteryUnitRole.MANPAD } },
		},
		Manpad = {
			LastPositionRefreshTime = nil,
			UnitHeadings = {},
			UnitHeadingCount = 0,
		},
	}
	return ManpadTest.applyManpadOverrides(bat, overrides)
end

--- makeStore returns a minimal manpadStore exposing :getAll(buf).
--- batteries is a Lua array; :getAll clears buf (if provided) and refills it.
local function makeStore(batteries)
	batteries = batteries or {}
	return {
		getAll = function(self, outputTable)
			local t = outputTable or {}
			-- clear
			for i = #t, 1, -1 do
				t[i] = nil
			end
			for i, v in ipairs(batteries) do
				t[i] = v
			end
			return t
		end,
	}
end

--- makeGeoGrid returns a geoGrid stub that records :updatePosition calls.
local function makeGeoGrid()
	local grid = {
		calls = {},
	}
	grid.updatePosition = function(self, entityId, pos, defaultType)
		table.insert(self.calls, { entityId = entityId, pos = pos, defaultType = defaultType })
	end
	return grid
end

-- ============================================================
-- TestManpadPositionRefresh
-- ============================================================

TestManpadPositionRefresh = {}

function TestManpadPositionRefresh:setUp()
	_seq = 0

	-- Save originals
	_origGetUnitPosition = GetUnitPosition
	_origMetricsInc = Medusa.Observability.MetricsService.inc

	-- Default stubs (individual tests may override)
	GetUnitPosition = function(unitName)
		return { x = 10, y = 20, z = 30 }
	end

	self._metricCounts = {}
	local counts = self._metricCounts
	-- The contract specifies a dot-call: MetricsService.inc("metric_name")
	-- so the first positional argument is the metric name string.
	Medusa.Observability.MetricsService.inc = function(metricName, delta)
		counts[metricName] = (counts[metricName] or 0) + 1
	end

	_refreshCtx = {}

	-- Logger must be initialised for the module under test
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
end

function TestManpadPositionRefresh:tearDown()
	GetUnitPosition = _origGetUnitPosition
	Medusa.Observability.MetricsService.inc = _origMetricsInc
end

-- ---------------------------------------------------------------
-- 1. Empty store: cursor stays nil, no side effects
-- ---------------------------------------------------------------
function TestManpadPositionRefresh:test_empty_store_noop()
	local store = makeStore({})
	local grid = makeGeoGrid()

	refresh(store, grid, 1000)

	lu.assertIsNil(cursor(), "cursor must stay nil when store is empty")
	lu.assertEquals(#grid.calls, 0, "updatePosition must not be called on empty store")
	lu.assertNil(
		self._metricCounts["medusa_manpad_position_refreshes_total"],
		"metric must not be incremented on empty store"
	)
end

-- ---------------------------------------------------------------
-- 2. First refresh: single battery, never refreshed, valid position
-- ---------------------------------------------------------------
function TestManpadPositionRefresh:test_first_refresh_succeeds_and_advances_cursor()
	local bat = makeManpad()
	local store = makeStore({ bat })
	local grid = makeGeoGrid()
	local now = 500

	GetUnitPosition = function(unitName)
		return { x = 1, y = 2, z = 3 }
	end

	refresh(store, grid, now)

	lu.assertEquals(cursor(), bat.BatteryId, "cursor must advance to the refreshed battery")
	lu.assertNotNil(bat.Position, "Position must be set after successful refresh")
	lu.assertEquals(bat.Position.x, 1, "Position.x must match returned position")
	lu.assertEquals(bat.Position.y, 2, "Position.y must match returned position")
	lu.assertEquals(bat.Position.z, 3, "Position.z must match returned position")
	lu.assertEquals(bat.Manpad.LastPositionRefreshTime, now, "LastPositionRefreshTime must be set to now")
	lu.assertEquals(#grid.calls, 1, "updatePosition must be called exactly once")
	lu.assertEquals(grid.calls[1].entityId, bat.BatteryId, "updatePosition called with correct BatteryId")
	lu.assertEquals(grid.calls[1].defaultType, "Manpad", "updatePosition called with defaultType 'Manpad'")
	lu.assertEquals(
		self._metricCounts["medusa_manpad_position_refreshes_total"],
		1,
		"metric must be incremented once on success"
	)
end

-- ---------------------------------------------------------------
-- 3. Refresh skipped when within minimum interval (30s gap, need 60)
-- ---------------------------------------------------------------
function TestManpadPositionRefresh:test_refresh_skipped_when_within_min_interval()
	local bat = makeManpad({ Manpad = { LastPositionRefreshTime = 5 } })
	local store = makeStore({ bat })
	local grid = makeGeoGrid()
	local now = 30 -- 30 - 5 = 25 < 60

	refresh(store, grid, now)

	lu.assertEquals(cursor(), bat.BatteryId, "cursor must advance even when refresh is skipped")
	lu.assertNil(bat.Position, "Position must not be set when interval not met")
	lu.assertEquals(bat.Manpad.LastPositionRefreshTime, 5, "LastPositionRefreshTime must not change on skip")
	lu.assertEquals(#grid.calls, 0, "updatePosition must not be called on skip")
	lu.assertNil(self._metricCounts["medusa_manpad_position_refreshes_total"], "metric must not be incremented on skip")
end

-- ---------------------------------------------------------------
-- 4. Refresh succeeds when past minimum interval (65s gap >= 60)
-- ---------------------------------------------------------------
function TestManpadPositionRefresh:test_refresh_succeeds_when_past_min_interval()
	local bat = makeManpad({ Manpad = { LastPositionRefreshTime = 5 } })
	local store = makeStore({ bat })
	local grid = makeGeoGrid()
	local now = 70 -- 70 - 5 = 65 >= 60

	GetUnitPosition = function(unitName)
		return { x = 7, y = 8, z = 9 }
	end

	refresh(store, grid, now)

	lu.assertEquals(cursor(), bat.BatteryId, "cursor must advance after refresh past min interval")
	lu.assertNotNil(bat.Position, "Position must be updated when interval is met")
	lu.assertEquals(bat.Manpad.LastPositionRefreshTime, 70, "LastPositionRefreshTime must be updated to now=70")
	lu.assertEquals(#grid.calls, 1, "updatePosition must be called once")
	lu.assertEquals(
		self._metricCounts["medusa_manpad_position_refreshes_total"],
		1,
		"metric must be incremented on successful refresh"
	)
end

-- ---------------------------------------------------------------
-- 5. Cursor wraps past the greatest BatteryId
-- ---------------------------------------------------------------
function TestManpadPositionRefresh:test_cursor_wraps_past_end()
	local bat1 = makeManpad()
	local bat2 = makeManpad()
	local store = makeStore({ bat1, bat2 })
	local grid = makeGeoGrid()
	local now = 1000

	_refreshCtx.posRefreshBatteryId = bat2.BatteryId

	GetUnitPosition = function(unitName)
		return { x = 5, y = 5, z = 5 }
	end

	refresh(store, grid, now)

	lu.assertEquals(cursor(), bat1.BatteryId, "cursor must wrap to the first BatteryId")
	-- bat1 (index 1) should be refreshed
	lu.assertNotNil(bat1.Position, "bat1 Position must be updated after wrap to index 1")
	lu.assertEquals(bat1.Manpad.LastPositionRefreshTime, now, "bat1 LastPositionRefreshTime must be set")
	-- bat2 must be untouched
	lu.assertNil(bat2.Position, "bat2 Position must not be updated when cursor wrapped to 1")
	lu.assertNil(bat2.Manpad.LastPositionRefreshTime, "bat2 LastPositionRefreshTime must remain nil")
end

-- ---------------------------------------------------------------
-- 6. GetUnitPosition returns nil: no stamp, no position, no grid call, no counter
-- ---------------------------------------------------------------
function TestManpadPositionRefresh:test_nil_unit_position_does_not_stamp()
	local bat = makeManpad()
	local store = makeStore({ bat })
	local grid = makeGeoGrid()
	local now = 1000

	GetUnitPosition = function(unitName)
		return nil
	end

	refresh(store, grid, now)

	lu.assertEquals(cursor(), bat.BatteryId, "cursor must advance even when GetUnitPosition returns nil")
	lu.assertNil(bat.Position, "Position must remain nil when unit position is nil")
	lu.assertNil(bat.Manpad.LastPositionRefreshTime, "LastPositionRefreshTime must stay nil when position lookup fails")
	lu.assertEquals(#grid.calls, 0, "updatePosition must not be called when unit position is nil")
	lu.assertNil(
		self._metricCounts["medusa_manpad_position_refreshes_total"],
		"metric must not be incremented when position lookup fails"
	)
end

-- ---------------------------------------------------------------
-- 7. Units[1] has no UnitName field: cursor advances, no side effects
-- ---------------------------------------------------------------
function TestManpadPositionRefresh:test_unit_missing_unitname_advances_cursor_but_skips()
	local bat = makeManpad({ Units = { {} } }) -- Units[1] = {} (no UnitName key)
	local store = makeStore({ bat })
	local grid = makeGeoGrid()
	local now = 1000

	refresh(store, grid, now)

	lu.assertEquals(cursor(), bat.BatteryId, "cursor must advance when Units[1].UnitName is absent")
	lu.assertNil(bat.Position, "Position must remain nil when UnitName is absent")
	lu.assertNil(bat.Manpad.LastPositionRefreshTime, "LastPositionRefreshTime must remain nil when UnitName is absent")
	lu.assertEquals(#grid.calls, 0, "updatePosition must not be called when UnitName is absent")
	lu.assertNil(
		self._metricCounts["medusa_manpad_position_refreshes_total"],
		"metric must not be incremented when UnitName is absent"
	)
end

function TestManpadPositionRefresh:test_storeOrderChanges_doNotRepeatBattery()
	local bat1 = makeManpad()
	local bat2 = makeManpad()
	local getAllCount = 0
	local store = {
		getAll = function(self, outputTable)
			for i = #outputTable, 1, -1 do
				outputTable[i] = nil
			end
			getAllCount = getAllCount + 1
			if getAllCount == 1 then
				outputTable[1], outputTable[2] = bat1, bat2
			else
				outputTable[1], outputTable[2] = bat2, bat1
			end
			return outputTable
		end,
	}
	local grid = makeGeoGrid()

	refresh(store, grid, 1000)
	refresh(store, grid, 1001)

	lu.assertEquals(bat1.Manpad.LastPositionRefreshTime, 1000)
	lu.assertEquals(bat2.Manpad.LastPositionRefreshTime, 1001)
	lu.assertEquals(cursor(), bat2.BatteryId)
end
