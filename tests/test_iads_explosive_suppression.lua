local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("core.Constants")
require("core.IadsNetwork")
require("services.stores.UnitGeoGrid")

TestIadsExplosiveSuppression = {}

local function impact(id, observedAt)
	return {
		TerminalEventId = id,
		Kind = Medusa.Constants.CrewSuppressionTerminalKind.EXPLOSIVE,
		Position = { x = 0, y = 0, z = 0 },
		EffectiveExplosiveMassKg = 1,
		ObservedAt = observedAt,
		Source = Medusa.Constants.CrewSuppressionTerminalSource.HIT,
	}
end

local function cannonEvent(id, observedAt)
	return {
		TerminalEventId = id,
		Kind = Medusa.Constants.CrewSuppressionTerminalKind.CANNON,
		Position = { x = 0, y = 0, z = 0 },
		ObservedAt = observedAt,
		Source = Medusa.Constants.CrewSuppressionTerminalSource.FORWARD_VECTOR,
	}
end

function TestIadsExplosiveSuppression:setUp()
	self.originalGetTime = GetTime
	self.now = 100
	GetTime = function()
		return self.now
	end
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
	self.network = Medusa.Core.IadsNetwork:new({ id = "test", coalitionId = coalition.side.RED, prefix = "test" })
	self.network._running = true
	self.network._doctrine = {
		CrewSuppression = {
			Enabled = true,
			DurationMinSec = 30,
			DurationMaxSec = 120,
			MaxGroupDiameterM = 609.6,
			ExplosiveRadiusScaleM = 10,
			ExplosiveRadiusMaxM = 500,
			ExplosiveEffectiveness = 1,
			DefaultCrewSkill = Medusa.Constants.CrewSuppression.DEFAULT_CREW_SKILL,
			SkillResistancePerLevel = 0.1,
			CannonRadiusM = 50,
			CannonEffectiveness = 0.5,
		},
	}
	self.repository = {
		getByUnitId = function()
			return nil
		end,
	}
	self.grid = Medusa.Services.UnitGeoGrid:new(500)
	for i = 1, 70 do
		self.grid:add(i, { x = i, y = 0, z = 0 })
	end
	self.network._assetIndex = {
		batteryRepository = function()
			return self.repository
		end,
		suppressibleUnitGeoGrid = function()
			return self.grid
		end,
	}
	self.network._trackManager = {
		getStore = function()
			return {}
		end,
	}
end

function TestIadsExplosiveSuppression:tearDown()
	GetTime = self.originalGetTime
end

function TestIadsExplosiveSuppression:test_impact_queue_rejects_newest_at_capacity()
	for i = 1, Medusa.Constants.CrewSuppression.IMPACT_QUEUE_CAPACITY do
		lu.assertTrue(self.network:enqueueTerminalEvent(impact(i, self.now)))
	end

	lu.assertFalse(self.network:enqueueTerminalEvent(impact(999, self.now)))
	lu.assertEquals(self.network._terminalEventQueue:size(), Medusa.Constants.CrewSuppression.IMPACT_QUEUE_CAPACITY)
	lu.assertEquals(self.network._terminalEventQueue:peek().TerminalEventId, 1)
end

function TestIadsExplosiveSuppression:test_query_visits_never_exceed_budget_and_resumes_next_tick()
	self.network:enqueueTerminalEvent(impact(1, self.now))

	local steps1, visits1 = self.network:_processTerminalEvents(5, 32)
	local steps2, visits2 = self.network:_processTerminalEvents(5, 32)
	local steps3, visits3 = self.network:_processTerminalEvents(5, 32)

	lu.assertEquals(steps1, 1)
	lu.assertEquals(visits1, 32)
	lu.assertEquals(steps2, 1)
	lu.assertEquals(visits2, 32)
	lu.assertEquals(steps3, 1)
	lu.assertEquals(visits3, 6)
	lu.assertNil(self.network._activeTerminalEvent)
end

function TestIadsExplosiveSuppression:test_expired_impact_is_removed_without_spatial_query()
	local queryCount = 0
	local originalBegin = self.grid.beginQuery
	self.grid.beginQuery = function(grid, ...)
		queryCount = queryCount + 1
		return originalBegin(grid, ...)
	end
	self.network:enqueueTerminalEvent(impact(1, self.now - 31))

	local steps, visits = self.network:_processTerminalEvents(5, 32)

	lu.assertEquals(steps, 1)
	lu.assertEquals(visits, 0)
	lu.assertEquals(queryCount, 0)
	lu.assertEquals(self.network._terminalEventQueue:size(), 0)
end

function TestIadsExplosiveSuppression:test_active_impact_expires_before_another_query_continuation()
	local continueCount = 0
	local originalContinue = self.grid.continueQuery
	self.grid.continueQuery = function(grid, cursor, visitBudget, output)
		continueCount = continueCount + 1
		return originalContinue(grid, cursor, visitBudget, output)
	end
	self.network:enqueueTerminalEvent(impact(1, self.now))
	self.network:_processTerminalEvents(5, 32)
	lu.assertNotNil(self.network._activeTerminalEvent)
	self.now = self.now + 31

	local steps, visits = self.network:_processTerminalEvents(5, 32)

	lu.assertEquals(steps, 1)
	lu.assertEquals(visits, 0)
	lu.assertEquals(continueCount, 1)
	lu.assertNil(self.network._activeTerminalEvent)
end

function TestIadsExplosiveSuppression:test_processing_advances_no_more_than_the_task_budget()
	self.grid = Medusa.Services.UnitGeoGrid:new(500)
	for i = 1, 10 do
		self.network:enqueueTerminalEvent(impact(i, self.now))
	end

	local steps, visits = self.network:_processTerminalEvents(5, 32)

	lu.assertEquals(steps, 5)
	lu.assertEquals(visits, 0)
	lu.assertEquals(self.network._terminalEventQueue:size(), 5)
end

function TestIadsExplosiveSuppression:test_suppression_cleanup_discards_queued_and_active_impacts()
	self.network:enqueueTerminalEvent(impact(1, self.now))
	self.network:_processTerminalEvents(1, 1)
	lu.assertNotNil(self.network._activeTerminalEvent)
	self.network:enqueueTerminalEvent(impact(2, self.now))

	self.network:_unsubscribeSuppressionEvents()

	lu.assertNil(self.network._activeTerminalEvent)
	lu.assertEquals(self.network._terminalEventQueue:size(), 0)
end

function TestIadsExplosiveSuppression:test_disabled_doctrine_rejects_impact_before_queueing()
	self.network._doctrine.CrewSuppression.Enabled = false

	lu.assertFalse(self.network:enqueueTerminalEvent(impact(1, self.now)))
	lu.assertEquals(self.network._terminalEventQueue:size(), 0)
end

function TestIadsExplosiveSuppression:test_terminal_queue_is_fifo_across_explosive_and_cannon_kinds()
	self.grid = Medusa.Services.UnitGeoGrid:new(500)
	lu.assertTrue(self.network:enqueueTerminalEvent(cannonEvent(1, self.now)))
	lu.assertTrue(self.network:enqueueTerminalEvent(impact(2, self.now)))

	local steps = self.network:_processTerminalEvents(1, 32)

	lu.assertEquals(steps, 1)
	lu.assertEquals(self.network._terminalEventQueue:size(), 1)
	lu.assertEquals(self.network._terminalEventQueue:peek().TerminalEventId, 2)
end

function TestIadsExplosiveSuppression:test_terminal_boundary_rejects_kind_source_mismatch()
	local invalid = cannonEvent(1, self.now)
	invalid.Source = Medusa.Constants.CrewSuppressionTerminalSource.HIT

	lu.assertFalse(self.network:enqueueTerminalEvent(invalid))
	lu.assertEquals(self.network._terminalEventQueue:size(), 0)
end
