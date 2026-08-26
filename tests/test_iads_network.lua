local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Config")
require("core.IadsNetwork")
require("entities.SensorUnit")
require("entities.Battery")

local scenario = require("scenario_one_syria")

-- == Helpers ==

local function makeIads()
	return Medusa.Core.IadsNetwork:new({
		id = "T",
		coalitionId = (coalition and coalition.side and coalition.side.RED) or 1,
		prefix = "iads",
	})
end

local function injectProvider(iads, groups)
	iads._discovery._provider = {
		list = function()
			return groups
		end,
	}
end

local COAL_RED = (coalition and coalition.side and coalition.side.RED) or 1
local origGetUnitDesc

-- == Tests ==

TestIadsNetwork = {}

function TestIadsNetwork:setUp()
	origGetUnitDesc = GetUnitDesc
	self.originalWorldEventBus = HarnessWorldEventBus
	HarnessWorldEventBus = CreateHarnessWorldEventBus()
	self.originalControllerSetROE = ControllerSetROE
	self.originalControllerSetAlarmState = ControllerSetAlarmState
	self.originalSetControllerOnOff = SetControllerOnOff
	self.originalGetGroupController = GetGroupController
	self.originalGetGroup = GetGroup
	self.originalGetUnitPosition = GetUnitPosition
	self.originalGetUnitHealth = GetUnitHealth
	self.originalGetControllerDetectedTargets = GetControllerDetectedTargets
	self.originalGetTime = GetTime
	self.originalControllerSetDisperseOnAttack = ControllerSetDisperseOnAttack
	self.originalEnableGroupEmissions = EnableGroupEmissions
	self.originalUnitExists = UnitExists
	self.originalGetUnitID = GetUnitID
	self.originalGetGroupUnits = GetGroupUnits
	self.originalGetUnitAmmo = GetUnitAmmo
	self.originalScheduleOnce = ScheduleOnce
	self.originalCancelSchedule = CancelSchedule
	self.originalPopControllerTask = PopControllerTask
	self.originalMetricsSet = Medusa.Observability.MetricsService.set
	self.originalMetricsInc = Medusa.Observability.MetricsService.inc
	self.originalPartitionBootstrap = Medusa.Services.PartitionService.bootstrap
	self.originalPartitionBegin = Medusa.Services.PartitionService.begin
	self.originalPartitionStep = Medusa.Services.PartitionService.step
	self.originalEnvError = env.error
	self.originalEnvInfo = env.info
	self.originalLogLevel = Medusa.Logger:getLevel()
	GetUnitDesc = function(unit)
		local name = unit and unit.getName and unit:getName() or ""
		if string.find(name, ".gci.", 1, true) or string.find(name, ".ewr.", 1, true) then
			return { attributes = { ["SAM SR"] = true } }
		end
		return { attributes = { ["SAM LL"] = true } }
	end
end

function TestIadsNetwork:tearDown()
	HarnessWorldEventBus:dispose()
	HarnessWorldEventBus = self.originalWorldEventBus
	GetUnitDesc = origGetUnitDesc
	ControllerSetROE = self.originalControllerSetROE
	ControllerSetAlarmState = self.originalControllerSetAlarmState
	SetControllerOnOff = self.originalSetControllerOnOff
	GetGroupController = self.originalGetGroupController
	GetGroup = self.originalGetGroup
	GetUnitPosition = self.originalGetUnitPosition
	GetUnitHealth = self.originalGetUnitHealth
	GetControllerDetectedTargets = self.originalGetControllerDetectedTargets
	GetTime = self.originalGetTime
	ControllerSetDisperseOnAttack = self.originalControllerSetDisperseOnAttack
	EnableGroupEmissions = self.originalEnableGroupEmissions
	UnitExists = self.originalUnitExists
	GetUnitID = self.originalGetUnitID
	GetGroupUnits = self.originalGetGroupUnits
	GetUnitAmmo = self.originalGetUnitAmmo
	ScheduleOnce = self.originalScheduleOnce
	CancelSchedule = self.originalCancelSchedule
	PopControllerTask = self.originalPopControllerTask
	Medusa.Observability.MetricsService.set = self.originalMetricsSet
	Medusa.Observability.MetricsService.inc = self.originalMetricsInc
	Medusa.Services.PartitionService.bootstrap = self.originalPartitionBootstrap
	Medusa.Services.PartitionService.begin = self.originalPartitionBegin
	Medusa.Services.PartitionService.step = self.originalPartitionStep
	env.error = self.originalEnvError
	env.info = self.originalEnvInfo
	Medusa.Logger:setLevel(self.originalLogLevel)
end

function TestIadsNetwork:test_recurring_work_summary_reports_and_resets_thirty_second_totals()
	local messages = {}
	env.info = function(message)
		messages[#messages + 1] = message
	end
	Medusa.Logger:setLevel(Medusa.Constants.LogLevel.DEBUG)
	local iads = makeIads()

	iads:_recordRecurringWork("handoff", 2, 3, 5)
	iads:_recordRecurringWork("handoff", 4, 1, 4)
	iads:_recordRecurringWork("unit_refresh", 4, 0, 0)
	iads:_logRecurringWorkSummary(100)
	iads:_logRecurringWorkSummary(129)
	lu.assertEquals(#messages, 0)

	iads:_logRecurringWorkSummary(130)
	lu.assertEquals(#messages, 1)
	lu.assertStrContains(messages[1], "recurring work (30s)")
	lu.assertNotNil(string.match(messages[1], "handoff%s+6%s+1%s+5"))
	lu.assertNotNil(string.match(messages[1], "unit_refresh%s+4%s+0%s+0"))

	iads:_recordRecurringWork("handoff", 1, 0, 1)
	iads:_logRecurringWorkSummary(160)
	lu.assertEquals(#messages, 2)
	lu.assertNotNil(string.match(messages[2], "handoff%s+1%s+0%s+1"))
end

function TestIadsNetwork:test_unit_refresh_detail_requires_trace_logging()
	local messages = {}
	env.info = function(message)
		messages[#messages + 1] = message
	end
	local iads = makeIads()
	iads:initialize()
	messages = {}

	Medusa.Logger:setLevel(Medusa.Constants.LogLevel.DEBUG)
	lu.assertTrue(iads:_runUnitPositionRefreshPhase())
	lu.assertEquals(#messages, 0)

	Medusa.Logger:setLevel(Medusa.Constants.LogLevel.TRACE)
	lu.assertTrue(iads:_runUnitPositionRefreshPhase())
	lu.assertEquals(#messages, 1)
	lu.assertStrContains(messages[1], "unit position refresh: visited=0 refreshed=0")
end

function TestIadsNetwork:test_unit_lost_event_uses_the_death_pipeline()
	local iads = makeIads()
	iads:initialize()
	lu.assertTrue(iads:_subscribeWorldEvents())
	local provider = { UnitId = 8101, UnitName = "iads.alpha.hq-provider", Available = true }
	iads:getAssetIndex():c2Nodes():add(Medusa.Entities.C2Node.new({
		NodeName = "iads.alpha.hq",
		GroupId = 810,
		Providers = { provider },
	}))
	local initiator = {
		getCoalition = function()
			return COAL_RED
		end,
		getID = function()
			return provider.UnitId
		end,
		getName = function()
			return provider.UnitName
		end,
	}

	HarnessWorldEventBus:publish({ id = world.event.S_EVENT_UNIT_LOST, time = 42, initiator = initiator })

	lu.assertEquals(iads._deathQueue:size(), 0)
	lu.assertEquals(iads._infrastructureDeathQueue:size(), 1)
	lu.assertEquals(iads:_processDeathEvents(1), 1)
	lu.assertFalse(provider.Available)
end

function TestIadsNetwork:test_unmanaged_death_event_is_filtered_before_queue_admission()
	local iads = makeIads()
	iads:initialize()
	lu.assertTrue(iads:_subscribeWorldEvents())
	local initiator = {
		getCoalition = function()
			return COAL_RED
		end,
		getID = function()
			return 8999
		end,
		getName = function()
			return "unmanaged-unit"
		end,
	}

	HarnessWorldEventBus:publish({ id = world.event.S_EVENT_DEAD, initiator = initiator })

	lu.assertEquals(iads._deathQueue:size(), 0)
	lu.assertEquals(iads._infrastructureDeathQueue:size(), 0)
end

function TestIadsNetwork:test_infrastructure_death_uses_reserved_queue_and_processing_priority()
	local iads = makeIads()
	iads:initialize()
	lu.assertTrue(iads:_subscribeWorldEvents())
	local provider = { UnitId = 8201, UnitName = "iads.alpha.hq-provider", Available = true }
	iads:getAssetIndex():c2Nodes():add(Medusa.Entities.C2Node.new({
		NodeName = "iads.alpha.hq",
		GroupId = 820,
		Providers = { provider },
	}))
	for unitId = 1, Medusa.Constants.WorldEventQueue.DEATH_CAPACITY do
		lu.assertTrue(iads._deathQueue:enqueue({ _unitId = unitId }))
	end
	local initiator = {
		getCoalition = function()
			return COAL_RED
		end,
		getID = function()
			return provider.UnitId
		end,
		getName = function()
			return provider.UnitName
		end,
	}

	HarnessWorldEventBus:publish({ id = world.event.S_EVENT_DEAD, initiator = initiator })

	lu.assertEquals(iads._deathQueue:size(), Medusa.Constants.WorldEventQueue.DEATH_CAPACITY)
	lu.assertEquals(iads._infrastructureDeathQueue:size(), 1)
	lu.assertEquals(iads:_processDeathEvents(1), 1)
	lu.assertFalse(provider.Available)
	lu.assertEquals(iads._deathQueue:size(), Medusa.Constants.WorldEventQueue.DEATH_CAPACITY)
end

function TestIadsNetwork:test_provider_health_reconciliation_recovers_a_terminally_dropped_death()
	local iads = makeIads()
	iads:initialize()
	lu.assertTrue(iads:_subscribeWorldEvents())
	local provider = { UnitId = 8301, UnitName = "iads.alpha.hq-provider", Available = true }
	iads:getAssetIndex():c2Nodes():add(Medusa.Entities.C2Node.new({
		NodeName = "iads.alpha.hq",
		GroupId = 830,
		Providers = { provider },
	}))
	for index = 1, Medusa.Constants.WorldEventQueue.INFRASTRUCTURE_DEATH_CAPACITY do
		iads._infrastructureDeathQueue:push({ UnitId = 90000 + index })
	end
	for index = 1, Medusa.Constants.WorldEventQueue.DEATH_OVERFLOW_CAPACITY do
		lu.assertTrue(iads:_queueDeathOverflow(91000 + index))
	end
	local initiator = {
		getCoalition = function()
			return COAL_RED
		end,
		getID = function()
			return provider.UnitId
		end,
		getName = function()
			return provider.UnitName
		end,
	}
	GetUnitHealth = function(unitName)
		if unitName == provider.UnitName then
			return { IsAlive = false }
		end
	end

	HarnessWorldEventBus:publish({ id = world.event.S_EVENT_DEAD, initiator = initiator })
	lu.assertTrue(provider.Available)

	lu.assertEquals(iads:_reconcileCommandProviders(1), 1)
	lu.assertFalse(provider.Available)
	lu.assertIsNil(provider.UnitId)
end

function TestIadsNetwork:test_provider_health_reconciliation_restores_selected_provider_without_rediscovery()
	local iads = makeIads()
	iads:initialize()
	local provider = { UnitId = 8401, UnitName = "iads.alpha.hq-provider", Available = true }
	local store = iads:getAssetIndex():c2Nodes()
	store:add(Medusa.Entities.C2Node.new({
		NodeName = "iads.alpha.hq",
		GroupId = 840,
		Providers = { provider },
	}))
	store:setProviderUnavailable(provider)
	GetUnitHealth = function(unitName)
		if unitName == provider.UnitName then
			return { IsAlive = true }
		end
	end
	GetUnitID = function(unitName)
		if unitName == provider.UnitName then
			return 8402
		end
	end

	lu.assertEquals(iads:_reconcileCommandProviders(1), 1)
	lu.assertTrue(provider.Available)
	lu.assertEquals(provider.UnitId, 8402)
end

function TestIadsNetwork:test_provider_health_requires_two_consecutive_failed_reads()
	local iads = makeIads()
	iads:initialize()
	local provider = { UnitId = 8451, UnitName = "iads.alpha.hq-provider", Available = true }
	iads:getAssetIndex():c2Nodes():add(Medusa.Entities.C2Node.new({
		NodeName = "iads.alpha.hq",
		GroupId = 845,
		Providers = { provider },
	}))
	local observations = { nil, { IsAlive = true }, nil, nil }
	local observationIndex = 0
	GetUnitHealth = function()
		observationIndex = observationIndex + 1
		return observations[observationIndex]
	end
	GetUnitID = function()
		return 8451
	end

	lu.assertEquals(iads:_reconcileCommandProviders(1), 1)
	lu.assertTrue(provider.Available)
	lu.assertEquals(provider.HealthMissCount, 1)
	lu.assertEquals(iads:_reconcileCommandProviders(1), 1)
	lu.assertTrue(provider.Available)
	lu.assertEquals(provider.HealthMissCount, 0)
	lu.assertEquals(iads:_reconcileCommandProviders(1), 1)
	lu.assertTrue(provider.Available)
	lu.assertEquals(provider.HealthMissCount, 1)
	lu.assertEquals(iads:_reconcileCommandProviders(1), 1)
	lu.assertFalse(provider.Available)
	lu.assertNil(provider.UnitId)
end

function TestIadsNetwork:test_unit_lost_with_empty_name_uses_the_captured_unit_id()
	local iads = makeIads()
	iads:initialize()
	lu.assertTrue(iads:_subscribeWorldEvents())
	local provider = { UnitId = 8111, UnitName = "iads.alpha.hq-provider", Available = true }
	iads:getAssetIndex():c2Nodes():add(Medusa.Entities.C2Node.new({
		NodeName = "iads.alpha.hq",
		GroupId = 811,
		Providers = { provider },
	}))
	local sensorStore = iads:getAssetIndex():sensors()
	local sensor = Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 8112,
		UnitName = "iads.alpha.ewr-unit",
		GroupId = 812,
		GroupName = "iads.alpha.ewr",
		SensorType = Medusa.Constants.SensorType.EWR,
	})
	sensorStore:add(sensor)
	local messages = {}
	env.info = function(message)
		messages[#messages + 1] = message
	end
	Medusa.Logger:setLevel(Medusa.Constants.LogLevel.DEBUG)
	local function initiator(unitId, unitName)
		return {
			getCoalition = function()
				return COAL_RED
			end,
			getID = function()
				return unitId
			end,
			getName = function()
				return unitName
			end,
		}
	end

	HarnessWorldEventBus:publish({
		id = world.event.S_EVENT_UNIT_LOST,
		time = 42,
		initiator = initiator(provider.UnitId, ""),
	})
	HarnessWorldEventBus:publish({
		id = world.event.S_EVENT_UNIT_LOST,
		time = 43,
		initiator = initiator(8112, "  "),
	})

	lu.assertEquals(iads._deathQueue:size(), 0)
	lu.assertEquals(iads._infrastructureDeathQueue:size(), 2)
	lu.assertEquals(iads:_processDeathEvents(2), 2)
	lu.assertFalse(provider.Available)
	lu.assertNil(sensorStore:getByUnitId(8112))
	local diagnostics = table.concat(messages, "\n")
	lu.assertStrContains(diagnostics, "death event accepted: unitId=8111 unitName=nil identitySource=unit-id batteryId=nil sensorUnitId=nil providerName=iads.alpha.hq-provider")
	lu.assertStrContains(
		diagnostics,
		string.format("death event accepted: unitId=8112 unitName=nil identitySource=unit-id batteryId=nil sensorUnitId=%s providerName=nil", sensor.SensorUnitId)
	)
end

function TestIadsNetwork:test_unit_lost_resolves_sensor_and_provider_event_ids_through_exact_names()
	local iads = makeIads()
	iads:initialize()
	lu.assertTrue(iads:_subscribeWorldEvents())
	local provider = { UnitId = 100040, UnitName = "pt.east.hq.command-1", Available = true }
	iads:getAssetIndex():c2Nodes():add(Medusa.Entities.C2Node.new({
		NodeName = "pt.east.hq.command",
		GroupId = 121,
		Providers = { provider },
	}))
	local sensorStore = iads:getAssetIndex():sensors()
	local sensor = Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 100039,
		UnitName = "pt.east.ewr.local-1",
		GroupId = 120,
		GroupName = "pt.east.ewr.local",
		SensorType = Medusa.Constants.SensorType.EWR,
	})
	sensorStore:add(sensor)
	local messages = {}
	env.info = function(message)
		messages[#messages + 1] = message
	end
	Medusa.Logger:setLevel(Medusa.Constants.LogLevel.DEBUG)
	local function initiator(unitId, unitName)
		return {
			getCoalition = function()
				return COAL_RED
			end,
			getID = function()
				return unitId
			end,
			getName = function()
				return unitName
			end,
		}
	end

	HarnessWorldEventBus:publish({
		id = world.event.S_EVENT_UNIT_LOST,
		initiator = initiator(40, provider.UnitName),
	})
	HarnessWorldEventBus:publish({
		id = world.event.S_EVENT_UNIT_LOST,
		initiator = initiator(39, sensor.UnitName),
	})

	lu.assertEquals(iads._deathQueue:size(), 0)
	lu.assertEquals(iads._infrastructureDeathQueue:size(), 2)
	lu.assertEquals(iads:_processDeathEvents(2), 2)
	lu.assertFalse(provider.Available)
	lu.assertNil(sensorStore:get(sensor.SensorUnitId))
	local diagnostics = table.concat(messages, "\n")
	lu.assertStrContains(
		diagnostics,
		"death event accepted: unitId=40 unitName=pt.east.hq.command-1 identitySource=unit-name batteryId=nil sensorUnitId=nil providerName=pt.east.hq.command-1"
	)
	lu.assertStrContains(
		diagnostics,
		string.format("death event accepted: unitId=39 unitName=pt.east.ewr.local-1 identitySource=unit-name batteryId=nil sensorUnitId=%s providerName=nil", sensor.SensorUnitId)
	)
end

function TestIadsNetwork:test_bounded_unit_refresh_reconciles_each_confirmed_sa10_search_radar_loss()
	local iads = makeIads()
	iads:initialize()
	local source = scenario.ProtectedSite
	local roles = Medusa.Constants.BatteryUnitRole
	local battery = Medusa.Entities.Battery.new({
		BatteryId = "stress-sa10",
		NetworkId = "T",
		GroupId = source.GroupId,
		GroupName = source.GroupName,
		Role = Medusa.Constants.BatteryRole.LR_SAM,
		Position = source.GroupPosition,
		PositionAnchorUnitId = source.Units[1].UnitId,
		DetectionRangeMax = 120000,
		WeaponRangeMax = 100000,
		EngagementRangeMax = 100000,
		ReactionDelaySec = 5,
		TotalAmmoStatus = 24,
	})
	local fixtureUnits = { source.Units[1], source.Units[2], source.Units[3], source.Units[5] }
	local fixtureRoles = { roles.SEARCH_RADAR, roles.SEARCH_RADAR, roles.TRACK_RADAR, roles.LAUNCHER }
	battery.Units = {}
	for i = 1, #fixtureUnits do
		local unit = fixtureUnits[i]
		battery.Units[i] = Medusa.Entities.Battery.newUnit({
			UnitId = unit.UnitId,
			UnitName = unit.UnitName,
			UnitTypeName = unit.UnitTypeName,
			Position = unit.Position,
			Roles = { fixtureRoles[i] },
			AmmoCount = fixtureRoles[i] == roles.LAUNCHER and 24 or 0,
			AmmoTypes = fixtureRoles[i] == roles.LAUNCHER and {
				{ Count = 24, RangeMin = 5000, RangeMax = 100000, AltMin = 10, AltMax = 30000 },
			} or nil,
		})
	end
	local repository = iads:getAssetIndex():batteryRepository()
	repository:add(battery)
	iads._spatialIndex:syncBattery(battery)
	local now = 1000
	local confirmedDead = { [source.Units[1].UnitName] = true }
	GetTime = function()
		return now
	end
	GetUnitHealth = function(unitName)
		return { IsAlive = not confirmedDead[unitName] }
	end
	GetUnitPosition = function(unitName)
		for i = 1, #source.Units do
			if source.Units[i].UnitName == unitName then
				return source.Units[i].Position
			end
		end
		return nil
	end

	lu.assertTrue(iads:_runUnitPositionRefreshPhase())
	lu.assertEquals(battery.OperationalStatus, Medusa.Constants.BatteryOperationalStatus.ACTIVE)
	lu.assertNil(repository:getByUnitId(source.Units[1].UnitId))

	now = now + Medusa.Constants.LocalAircraftDetection.POSITION_REFRESH_MIN_INTERVAL_SEC
	confirmedDead[source.Units[2].UnitName] = true
	lu.assertTrue(iads:_runUnitPositionRefreshPhase())
	lu.assertEquals(battery.OperationalStatus, Medusa.Constants.BatteryOperationalStatus.ENGAGEMENT_IMPAIRED)
	lu.assertEquals(battery.EffectiveDetectionRangeMax, 0)
	lu.assertNil(repository:getByUnitId(source.Units[2].UnitId))
end

function TestIadsNetwork:test_initialize_registers_barrage_limit_before_start()
	local barrageState = Medusa.Services.AaaService.newBarrageState()
	local iads = Medusa.Core.IadsNetwork:new({
		id = "limit-net",
		coalitionId = COAL_RED,
		prefix = "iads",
		doctrine = { AAA = { MaxBarrageGroups = 7 } },
		aaaBarrageState = barrageState,
	})

	iads:initialize()

	lu.assertEquals(barrageState.limitsByNetwork["limit-net"], 7)
end

function TestIadsNetwork:test_start_contains_initialization_failure_and_leaves_the_network_stopped()
	local iads = makeIads()
	iads.initialize = function()
		error("injected initialization failure")
	end

	local contained, started = pcall(iads.start, iads)

	lu.assertTrue(contained)
	lu.assertFalse(started)
	lu.assertFalse(iads._running)
end

function TestIadsNetwork:test_start_rolls_back_partial_world_event_registration_and_can_retry()
	local iads = makeIads()
	iads:initialize()
	local bus = HarnessWorldEventBus
	local originalSub = bus.sub
	local calls = 0
	bus.sub = function(self, topic, queue, predicate)
		calls = calls + 1
		local subscriptionId = originalSub(self, topic, queue, predicate)
		if calls == 2 then
			error("injected world-event registration failure")
		end
		return subscriptionId
	end

	lu.assertFalse(iads:start())
	lu.assertFalse(iads._running)
	lu.assertEquals(bus._totalSubs, 0)
	lu.assertIsNil(next(bus._subscribers))

	bus.sub = originalSub
	lu.assertTrue(iads:_subscribeWorldEvents())
	lu.assertEquals(bus._totalSubs, 5)
	iads:_unsubscribeWorldEvents()
	lu.assertEquals(bus._totalSubs, 0)
end

function TestIadsNetwork:test_tick_schedule_failure_is_contained_and_stops_the_network()
	local iads = makeIads()
	iads:initialize()
	local battery = Medusa.Entities.Battery.new({
		BatteryId = "safe-stop-battery",
		NetworkId = "T",
		GroupId = 9001,
		GroupName = "iads.safe-stop-battery",
	})
	battery.CrewSuppressionTimerId = 73
	iads:getAssetIndex():batteries():add(battery)
	local cancelled = {}
	CancelSchedule = function(timerId)
		cancelled[timerId] = true
		return true
	end
	ScheduleOnce = function()
		return 91
	end
	lu.assertTrue(iads:start())
	lu.assertTrue(HarnessWorldEventBus._totalSubs > 0)
	lu.assertNotNil(iads._discovery._birthQueue)
	lu.assertNotNil(iads._hitSubscriptionId)

	ScheduleOnce = function()
		error("injected registration failure")
	end

	local ok, scheduled = pcall(iads._scheduleNext, iads)

	lu.assertTrue(ok)
	lu.assertFalse(scheduled)
	lu.assertFalse(iads._running)
	lu.assertIsNil(iads._timerId)
	lu.assertEquals(HarnessWorldEventBus._totalSubs, 0)
	lu.assertIsNil(iads._discovery._birthQueue)
	lu.assertIsNil(iads._hitSubscriptionId)
	lu.assertIsNil(battery.CrewSuppressionTimerId)
	lu.assertTrue(cancelled[73])
	lu.assertTrue(cancelled[91])
end

function TestIadsNetwork:test_post_tick_failure_is_contained_and_stops_without_rescheduling()
	local iads = makeIads()
	iads:initialize()
	iads._running = true
	iads.tick = function() end
	Medusa.Observability.MetricsService.set = function()
		error("injected metrics failure")
	end
	env.error = function()
		error("injected logger failure")
	end
	local scheduleCalls = 0
	ScheduleOnce = function()
		scheduleCalls = scheduleCalls + 1
		return 1
	end

	local ok = pcall(iads._onTick, iads)

	lu.assertTrue(ok)
	lu.assertFalse(iads._running)
	lu.assertIsNil(iads._timerId)
	lu.assertEquals(scheduleCalls, 0)
end

function TestIadsNetwork:test_recurring_owner_failure_resets_after_success()
	local iads = makeIads()
	iads:initialize()
	iads._running = true
	iads._failureLimit = 2
	iads._assignmentPhase = 0
	iads._phaseClassify = function()
		error("injected phase failure")
	end

	lu.assertFalse(iads:_runPhase())
	lu.assertEquals(iads._phaseFailures[0], 1)
	lu.assertTrue(iads._running)

	iads._assignmentPhase = 0
	iads._phaseClassify = function() end
	lu.assertTrue(iads:_runPhase())
	lu.assertEquals(iads._phaseFailures[0], 0)
	lu.assertTrue(iads._running)
end

function TestIadsNetwork:test_persistent_recurring_owner_failure_safe_stops_despite_other_success()
	local iads = makeIads()
	iads:initialize()
	iads._running = true
	iads._failureLimit = 2
	iads._assignmentPhase = 0
	iads._phaseClassify = function()
		error("injected persistent phase failure")
	end

	lu.assertFalse(iads:_runPhase())
	lu.assertTrue(iads:_runManpadPhase())
	lu.assertTrue(iads._running)
	lu.assertEquals(iads._phaseFailures[0], 1)

	iads._assignmentPhase = 0
	lu.assertFalse(iads:_runPhase())
	lu.assertEquals(iads._phaseFailures[0], 2)
	lu.assertFalse(iads._running)
end

function TestIadsNetwork:test_safe_stop_during_tick_does_not_register_another_callback()
	local iads = makeIads()
	iads:initialize()
	iads._running = true
	local scheduleCalls = 0
	ScheduleOnce = function()
		scheduleCalls = scheduleCalls + 1
		return scheduleCalls
	end
	iads.tick = function(network)
		network:_stopAfterPersistentFailure("injected owner", 2)
	end

	iads:_onTick()

	lu.assertFalse(iads._running)
	lu.assertEquals(scheduleCalls, 0)
end

function TestIadsNetwork:test_failed_bootstrap_retries_before_operational_ticks_continue()
	local iads = makeIads()
	iads:initialize()
	iads._running = true
	local now = 0
	GetTime = function()
		return now
	end
	local populate = iads._populateGeoGrid
	local populateCalls = 0
	iads._populateGeoGrid = function(self)
		populateCalls = populateCalls + 1
		if populateCalls == 1 then
			error("injected bootstrap failure")
		end
		return populate(self)
	end
	local scheduledCallback
	local scheduleCalls = 0
	ScheduleOnce = function(callback)
		scheduleCalls = scheduleCalls + 1
		scheduledCallback = callback
		return scheduleCalls
	end

	iads:_onTick()

	lu.assertFalse(iads._bootstrapComplete)
	lu.assertEquals(iads._tickCounter, 0)
	lu.assertEquals(scheduleCalls, 1)
	lu.assertEquals(iads._timerId, 1)

	now = Medusa.Constants.C2.BOOTSTRAP_RETRY_SEC
	scheduledCallback()

	lu.assertTrue(iads._bootstrapComplete)
	lu.assertEquals(iads._tickCounter, 1)
	lu.assertNotNil(iads:getHierarchy():getC2Topology())
	lu.assertNotNil(iads._partitionSnapshot.PartitionByCluster[""])
	lu.assertNotNil(iads._erectReadyAt)
	lu.assertEquals(scheduleCalls, 2)
	lu.assertEquals(iads._timerId, 2)
end

function TestIadsNetwork:test_partition_bootstrap_pairs_attempt_and_failure_metrics()
	local iads = makeIads()
	iads:initialize()
	iads:getHierarchy():freezeC2Topology()
	local counts = {}
	Medusa.Observability.MetricsService.inc = function(name)
		counts[name] = (counts[name] or 0) + 1
	end
	Medusa.Services.PartitionService.bootstrap = function()
		error("injected partition bootstrap failure")
	end

	lu.assertFalse(iads:_initializePartitionSnapshot())
	lu.assertEquals(counts.medusa_partition_refresh_attempts_total, 1)
	lu.assertEquals(counts.medusa_partition_refresh_failures_total, 1)
end

function TestIadsNetwork:test_bootstrap_freezes_topology_only_after_discovery_snapshot_succeeds()
	local iads = makeIads()
	iads:initialize()
	iads._running = true
	local now = 0
	GetTime = function()
		return now
	end
	local listCalls = 0
	iads._discovery._provider = {
		list = function()
			listCalls = listCalls + 1
			if listCalls == 1 then
				return nil
			end
			return {
				{
					groupId = 43,
					groupName = "iads.alpha.hq.command",
					coalitionId = COAL_RED,
					category = "ground",
				},
			}
		end,
	}
	local originalCreate = Medusa.Services.EntityFactory.createFromDTO
	local ok, err = pcall(function()
		Medusa.Services.EntityFactory.createFromDTO = function()
			return "sensor"
		end

		iads:tick()
		lu.assertFalse(iads._bootstrapComplete)
		lu.assertNil(iads:getHierarchy():getC2Topology())
		lu.assertEquals(listCalls, 1)

		now = Medusa.Constants.C2.BOOTSTRAP_RETRY_SEC / 2
		iads:tick()
		lu.assertFalse(iads._bootstrapComplete)
		lu.assertNil(iads:getHierarchy():getC2Topology())
		lu.assertEquals(listCalls, 1)

		now = Medusa.Constants.C2.BOOTSTRAP_RETRY_SEC
		iads:tick()
		local topology = iads:getHierarchy():getC2Topology()
		lu.assertTrue(iads._bootstrapComplete)
		lu.assertNotNil(topology)
		lu.assertEquals(#topology.Edges, 1)
		lu.assertEquals(topology.Edges[1].ChildKey, "alpha")
		lu.assertEquals(listCalls, 2)
	end)
	Medusa.Services.EntityFactory.createFromDTO = originalCreate
	lu.assertTrue(ok, tostring(err))
end

function TestIadsNetwork:test_initialize_and_tick_wires_discovery_to_hierarchy()
	local iads = makeIads()
	lu.assertTrue(iads:initialize())
	lu.assertTrue(iads:start())

	injectProvider(iads, {
		{
			groupId = 42,
			groupName = "iads.1bn.gci.alpha",
			coalitionId = COAL_RED,
			category = "ground",
		},
	})

	iads:_runScanAndLog()
	local node = iads:getHierarchy():getNode({ "1bn" })
	lu.assertNotNil(node)
	lu.assertTrue(node.groupsSet and node.groupsSet:contains(42))
end

function TestIadsNetwork:test_discovery_reports_the_hierarchy_tree_at_info_level()
	local iads = makeIads()
	lu.assertTrue(iads:initialize())
	local messages = {}
	env.info = function(message)
		messages[#messages + 1] = message
	end
	Medusa.Logger:setLevel(Medusa.Constants.LogLevel.INFO)
	injectProvider(iads, {
		{ groupId = 43, groupName = "iads.1bn.gci.info", coalitionId = COAL_RED, category = "ground" },
	})

	iads:_runScanAndLog()

	lu.assertStrContains(table.concat(messages, "\n"), "hierarchy tree:")
end

function TestIadsNetwork:test_discovery_creates_battery_for_non_role_group()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	injectProvider(iads, {
		{
			groupId = 100,
			groupName = "iads.alpha.sa6",
			coalitionId = COAL_RED,
			category = "ground",
		},
	})

	iads._tickCounter = 0
	iads:tick()

	local store = iads:getAssetIndex():batteries()
	lu.assertEquals(store:count(), 1)
	local battery = store:getByGroupId(100)
	lu.assertNotNil(battery)
	lu.assertEquals(battery.GroupName, "iads.alpha.sa6")
	lu.assertEquals(battery.NetworkId, "T")
end

function TestIadsNetwork:test_discovery_routes_gci_to_sensors()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	injectProvider(iads, {
		{
			groupId = 200,
			groupName = "iads.alpha.gci.site1",
			coalitionId = COAL_RED,
			category = "ground",
		},
	})

	iads._tickCounter = 0
	iads:tick()

	lu.assertEquals(iads:getAssetIndex():batteries():count(), 0)
	local sensorNames = iads:getAssetIndex():sensors():getUniqueGroupNames()
	lu.assertEquals(#sensorNames, 1)
	lu.assertEquals(sensorNames[1], "iads.alpha.gci.site1")
end

function TestIadsNetwork:test_same_id_sensor_rediscovery_restores_a_removed_group()
	local iads = makeIads()
	iads:initialize()
	iads._running = true
	local groups = {
		{ groupId = 205, groupName = "iads.alpha.gci.restore", coalitionId = COAL_RED, category = "ground" },
	}
	injectProvider(iads, groups)

	iads._tickCounter = 0
	iads:tick()
	local sensorStore = iads:getAssetIndex():sensors()
	local sensors = sensorStore:getByGroupName(groups[1].groupName)
	lu.assertNotEquals(#sensors, 0)
	local initialCount = #sensors

	for i = 1, #sensors do
		iads:_handleUnitDeath(sensors[i].UnitId)
	end
	lu.assertEquals(#sensorStore:getByGroupName(groups[1].groupName), 0)
	iads:_runScanAndLog()

	lu.assertEquals(#sensorStore:getByGroupName(groups[1].groupName), initialCount)
end

function TestIadsNetwork:test_same_name_new_group_id_atomically_replaces_the_battery_incarnation()
	local iads = makeIads()
	iads:initialize()
	local groups = {
		{ groupId = 920, groupName = "iads.alpha.sa6.replace", coalitionId = COAL_RED, category = "ground" },
	}
	local liveUnits = { { id = 9201, name = "retired-unit" } }
	for i = 1, #liveUnits do
		liveUnits[i].getName = function(unit)
			return unit.name
		end
	end
	injectProvider(iads, groups)
	GetGroupUnits = function()
		return liveUnits
	end
	GetUnitID = function(unit)
		return unit.id
	end
	GetUnitAmmo = function()
		return {
			{ count = 1, desc = { missileCategory = 1, typeName = "missile", rangeMaxAltMax = 1000 } },
		}
	end

	iads:_runScanAndLog()
	local retired = iads:getAssetIndex():batteryRepository():getByGroupName(groups[1].groupName)
	lu.assertEquals(retired.GroupId, 920)

	groups[1].groupId = 921
	liveUnits = { { id = 9211, name = "replacement-unit" } }
	liveUnits[1].getName = function(unit)
		return unit.name
	end
	iads:_runScanAndLog()

	local repository = iads:getAssetIndex():batteryRepository()
	local replacement = repository:getByGroupName(groups[1].groupName)
	lu.assertEquals(repository:count(), 1)
	lu.assertEquals(replacement.GroupId, 921)
	lu.assertEquals(replacement.Units[1].UnitName, "replacement-unit")
	lu.assertNil(repository:get(retired.BatteryId))
	lu.assertNil(iads:getHierarchy()._byGroupId[920])
	lu.assertNotNil(iads:getHierarchy()._byGroupId[921])
end

function TestIadsNetwork:test_same_group_identity_replaces_changed_battery_members_without_a_death_event()
	local iads = makeIads()
	iads:initialize()
	local groups = {
		{ groupId = 922, groupName = "iads.alpha.sa6.members", coalitionId = COAL_RED, category = "ground" },
	}
	local liveUnits = { { id = 9221, name = "retired-member" } }
	liveUnits[1].getName = function(unit)
		return unit.name
	end
	injectProvider(iads, groups)
	GetGroupUnits = function()
		return liveUnits
	end
	GetUnitID = function(unit)
		return unit.id
	end
	GetUnitAmmo = function()
		return { { count = 1, desc = { missileCategory = 1, typeName = "missile", rangeMaxAltMax = 1000 } } }
	end

	iads:_runScanAndLog()
	local repository = iads:getAssetIndex():batteryRepository()
	local retired = repository:getByGroupName(groups[1].groupName)
	liveUnits = { { id = 9222, name = "replacement-member" } }
	liveUnits[1].getName = function(unit)
		return unit.name
	end
	iads:_runScanAndLog()

	local replacement = repository:getByGroupName(groups[1].groupName)
	lu.assertEquals(repository:count(), 1)
	lu.assertNotEquals(replacement.BatteryId, retired.BatteryId)
	lu.assertEquals(replacement.GroupId, retired.GroupId)
	lu.assertEquals(replacement.Units[1].UnitId, 9222)
	lu.assertNil(repository:getByUnitId(9221))
end

function TestIadsNetwork:test_aaa_replacement_releases_local_capacity_after_failed_stop_request()
	local iads = makeIads()
	iads:initialize()
	local groups = {
		{ groupId = 923, groupName = "iads.alpha.aaa.replace", coalitionId = COAL_RED, category = "ground" },
	}
	local liveUnits = { { id = 9231, name = "retired-aaa" } }
	liveUnits[1].getName = function(unit)
		return unit.name
	end
	injectProvider(iads, groups)
	GetGroupUnits = function()
		return liveUnits
	end
	GetUnitID = function(unit)
		return unit.id
	end
	GetUnitDesc = function()
		return { attributes = { AAA = true } }
	end
	GetUnitAmmo = function()
		return { { count = 1, desc = { typeName = "shell", rangeMaxAltMax = 1000 } } }
	end
	iads:_runScanAndLog()
	local repository = iads:getAssetIndex():batteryRepository()
	local retired = repository:getByGroupName(groups[1].groupName)
	retired.Aaa.ResponseState = Medusa.Constants.Aaa.ResponseState.BARRAGE_FIRE
	retired.Aaa.LastFirePoint = { x = 1000, y = 100, z = 0 }
	retired.Aaa.BarrageUntil = 100
	retired.Aaa.InfectionTimerId = 71
	iads._aaaBarrageState.participants[retired.BatteryId] = retired
	GetGroupController = function()
		return {}
	end
	PopControllerTask = function()
		return false
	end
	local cancelled
	CancelSchedule = function(timerId)
		cancelled = timerId
		return true
	end

	groups[1].groupId = 924
	liveUnits = { { id = 9241, name = "replacement-aaa" } }
	liveUnits[1].getName = function(unit)
		return unit.name
	end
	iads:_runScanAndLog()

	local replacement = repository:getByGroupName(groups[1].groupName)
	lu.assertEquals(repository:count(), 1)
	lu.assertNotEquals(replacement.BatteryId, retired.BatteryId)
	lu.assertNil(iads._aaaBarrageState.participants[retired.BatteryId])
	lu.assertNil(retired.Aaa.LastFirePoint)
	lu.assertEquals(cancelled, 71)
end

function TestIadsNetwork:test_new_id_hq_sensor_restoration_keeps_its_frozen_child_cluster()
	local iads = makeIads()
	iads:initialize()
	iads._running = true
	local groupName = "iads.child.hq.gci.command"
	local groups = {
		{ groupId = 210, groupName = groupName, coalitionId = COAL_RED, category = "ground" },
	}
	local ids = {
		[groupName .. "#1"] = 2101,
		[groupName .. "#2"] = 2102,
	}
	GetUnitID = function(unitOrName)
		local name = type(unitOrName) == "string" and unitOrName or unitOrName:getName()
		return ids[name]
	end
	injectProvider(iads, groups)

	iads._tickCounter = 0
	iads:tick()
	local sensorStore = iads:getAssetIndex():sensors()
	local initialSensors = sensorStore:getByGroupName(groupName)
	lu.assertEquals(#initialSensors, 2)
	lu.assertEquals(iads:getAssetIndex():c2Nodes():count(), 1)

	for i = 1, #initialSensors do
		iads:_handleUnitDeath(initialSensors[i].UnitId)
	end
	groups[1].groupId = 211
	ids[groupName .. "#1"] = 2111
	ids[groupName .. "#2"] = 2112
	iads:_runScanAndLog()

	local restored = sensorStore:getByGroupName(groupName)
	lu.assertEquals(#restored, 2)
	lu.assertEquals(iads:getHierarchy():clusterKeyForGroup(211), "child")
	local c2Store = iads:getAssetIndex():c2Nodes()
	local unitIndex = iads:getAssetIndex():unitIndex()
	for i = 1, #restored do
		restored[i].Position = { x = 0, y = 0, z = 0 }
		restored[i].DetectionRangeMax = 1000
		local provider = unitIndex:getRegisteredOwner(restored[i].UnitId, Medusa.Constants.UnitOwnerKind.COMMAND_PROVIDER)
		c2Store:setProviderUnavailable(provider)
	end

	local battery = Medusa.Entities.Battery.new({
		BatteryId = "child-battery",
		NetworkId = "T",
		GroupId = 212,
		GroupName = "iads.child.sam.site",
		Role = Medusa.Constants.BatteryRole.LR_SAM,
		OperationalStatus = Medusa.Constants.BatteryOperationalStatus.ACTIVE,
		Position = { x = 0, y = 0, z = 0 },
		DetectionRangeMax = 100,
		EngagementRangeMax = 100,
		TotalAmmoStatus = 4,
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = 2121,
			UnitName = "child-battery-radar",
			Roles = { Medusa.Constants.BatteryUnitRole.SEARCH_RADAR },
		}),
	}
	iads:getHierarchy():upsertGroup({
		groupId = battery.GroupId,
		groupName = battery.GroupName,
		parsed = { echelonPath = { "child" }, roles = {}, isHQ = false },
	})
	iads:getAssetIndex():batteries():add(battery)
	iads._nextPartitionRefreshAt = 0
	for _ = 1, 5 do
		iads:_runPartitionStep(0)
	end

	local childPartition = iads._partitionSnapshot.PartitionByCluster.child
	lu.assertNotNil(childPartition)
	lu.assertEquals(battery.PartitionKey, childPartition.Key)
	lu.assertEquals(restored[1].PartitionKey, childPartition.Key)
	lu.assertEquals(battery.CoordinationState, Medusa.Constants.CoordinationState.COORDINATED)
end

function TestIadsNetwork:test_dynamic_sensor_uses_committed_local_partition_during_active_refresh()
	local iads = makeIads()
	iads:initialize()
	iads._running = true
	local groups = {
		{ groupId = 206, groupName = "iads.alpha.gci.initial", coalitionId = COAL_RED, category = "ground" },
	}
	injectProvider(iads, groups)

	iads._tickCounter = 0
	iads:tick()
	iads._nextPartitionRefreshAt = 0
	iads:_runPartitionStep(0)
	lu.assertNotNil(iads._partitionRefresh)
	groups[#groups + 1] = {
		groupId = 207,
		groupName = "iads.alpha.gci.dynamic",
		coalitionId = COAL_RED,
		category = "ground",
	}
	iads:_runScanAndLog()

	local dynamic = iads:getAssetIndex():sensors():getByGroupName(groups[2].groupName)[1]
	lu.assertNotNil(dynamic)
	lu.assertNotNil(dynamic.PartitionKey)
	lu.assertEquals(dynamic.PartitionKey, iads._partitionSnapshot.PartitionByCluster[""].Key)
end

function TestIadsNetwork:test_partition_commit_rekeys_assets_admitted_during_a_split_refresh()
	local iads = makeIads()
	iads:initialize()
	local hierarchy = iads:getHierarchy()
	hierarchy:upsertGroup({
		groupId = 208,
		groupName = "iads.root.ewr",
		parsed = { echelonPath = {}, roles = {}, isHQ = false },
	})
	hierarchy:upsertGroup({
		groupId = 209,
		groupName = "iads.child.hq",
		parsed = { echelonPath = { "child" }, roles = {}, isHQ = true },
	})
	hierarchy:upsertGroup({
		groupId = 210,
		groupName = "iads.child.sam",
		parsed = { echelonPath = { "child" }, roles = {}, isHQ = false },
	})
	iads:getAssetIndex():c2Nodes():add(Medusa.Entities.C2Node.new({
		NetworkId = "T",
		GroupId = 209,
		NodeName = "iads.child.hq",
		Providers = { { UnitId = 2091, UnitName = "child-hq", Available = false } },
	}))
	hierarchy:freezeC2Topology()
	local retired = Medusa.Entities.Partition.new({
		Key = "retired-connected",
		ClusterKeys = { "", "child" },
		Sustained = true,
	})
	local pending = Medusa.Services.PartitionService.begin(iads._partitionCtx, {
		PartitionByCluster = { [""] = retired, child = retired },
	})
	local sensor = Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 2081,
		UnitName = "root-ewr",
		GroupId = 208,
		GroupName = "iads.root.ewr",
		PartitionKey = retired.Key,
	})
	iads:getAssetIndex():sensors():add(sensor)
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 210,
		GroupName = "iads.child.sam",
		Role = Medusa.Constants.BatteryRole.LR_SAM,
		PartitionKey = retired.Key,
		TotalAmmoStatus = 1,
	})
	local batteryStore = iads:getAssetIndex():batteries()
	batteryStore:add(battery)
	while not Medusa.Services.PartitionService.step(pending) do
	end

	iads:_commitPartitionRefresh(pending)

	lu.assertNotEquals(sensor.PartitionKey, retired.Key)
	lu.assertNotEquals(battery.PartitionKey, retired.Key)
	lu.assertNotEquals(sensor.PartitionKey, battery.PartitionKey)
	lu.assertFalse(Medusa.Entities.Battery.canAcceptTrack(battery, { PartitionKey = sensor.PartitionKey }, iads._doctrine))
end

function TestIadsNetwork:test_discovery_routes_ewr_to_sensors()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	injectProvider(iads, {
		{
			groupId = 201,
			groupName = "iads.alpha.ewr.bigbird",
			coalitionId = COAL_RED,
			category = "ground",
		},
	})

	iads._tickCounter = 0
	iads:tick()

	lu.assertEquals(iads:getAssetIndex():batteries():count(), 0)
	local sensorNames = iads:getAssetIndex():sensors():getUniqueGroupNames()
	lu.assertEquals(#sensorNames, 1)
	lu.assertEquals(sensorNames[1], "iads.alpha.ewr.bigbird")
end

function TestIadsNetwork:test_battery_datalink_excludes_independent_aaa()
	local iads = makeIads()
	iads:initialize()
	iads._doctrine = { BatteryTargetDatalink = true }
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 202,
		GroupName = "iads.alpha.aaa.site1",
		Role = Medusa.Constants.BatteryRole.AAA,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
	})
	iads:getAssetIndex():batteries():add(battery)

	lu.assertEquals(iads:_buildPollList(), {})
end

function TestIadsNetwork:test_battery_datalink_polls_warm_radar_directed_aaa()
	local iads = makeIads()
	iads:initialize()
	iads._doctrine = { BatteryTargetDatalink = true }
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 203,
		GroupName = "iads.alpha.aaa.radar",
		Role = Medusa.Constants.BatteryRole.AAA,
		ActivationState = Medusa.Constants.ActivationState.STATE_WARM,
		DetectionRangeMax = 20000,
		PartitionKey = "partition-a",
	})
	battery.Units = {
		{ Roles = { Medusa.Constants.BatteryUnitRole.AAA } },
		{ Roles = { Medusa.Constants.BatteryUnitRole.SEARCH_RADAR } },
	}
	iads:getAssetIndex():batteries():add(battery)

	local pollList = iads:_buildPollList()

	lu.assertEquals(#pollList, 1)
	lu.assertEquals(pollList[1].groupName, battery.GroupName)
	lu.assertEquals(pollList[1].sourceType, Medusa.Constants.TrackSource.SAM_BATTERY)
end

function TestIadsNetwork:test_degraded_battery_keeps_local_radar_acquisition_without_datalink()
	local iads = makeIads()
	iads:initialize()
	iads._doctrine = { BatteryTargetDatalink = false }
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 204,
		GroupName = "iads.alpha.sam.local",
		Role = Medusa.Constants.BatteryRole.SR_SAM,
		ActivationState = Medusa.Constants.ActivationState.STATE_WARM,
		DetectionRangeMax = 20000,
		PartitionKey = "partition-a",
		CoordinationState = Medusa.Constants.CoordinationState.DEGRADED,
	})
	battery.Units = {
		{ Roles = { Medusa.Constants.BatteryUnitRole.SEARCH_RADAR } },
	}
	iads:getAssetIndex():batteries():add(battery)

	local pollList = iads:_buildPollList()

	lu.assertEquals(#pollList, 1)
	lu.assertEquals(pollList[1].groupName, battery.GroupName)
	lu.assertEquals(pollList[1].partitionKey, "partition-a")
end

function TestIadsNetwork:test_partition_commit_retains_allowed_self_defense_assignment()
	local iads = makeIads()
	iads:initialize()
	iads._doctrine.DegradedMode = Medusa.Constants.NetworkDegradationPolicy.REVERT_TO_SELF_DEFENSE
	local battery = Medusa.Entities.Battery.new({
		BatteryId = "battery",
		NetworkId = "T",
		GroupId = 205,
		GroupName = "iads.alpha.sam.defender",
		PartitionKey = "partition-a",
		CoordinationState = Medusa.Constants.CoordinationState.DEGRADED,
	})
	local track = Medusa.Entities.Track.new({
		TrackId = "harm",
		NetworkId = "track",
		PartitionKey = "partition-a",
		AssessedAircraftType = Medusa.Constants.AssessedAircraftType.HARM,
		Position = { x = 0, y = 0, z = 0 },
		Velocity = { x = 0, y = 0, z = 0 },
	})
	iads:getAssetIndex():batteries():add(battery)
	iads._trackManager:getStore():add(track)
	Medusa.Entities.Battery.assignTrack(battery, track, 10)

	iads:_commitPartitionRefresh({
		PartitionByCluster = {},
		Sensors = {},
		Batteries = {
			{
				BatteryId = "battery",
				PartitionKey = "partition-a",
				CoordinationState = Medusa.Constants.CoordinationState.DEGRADED,
			},
		},
		ProviderOverflowCount = 0,
	})

	lu.assertEquals(battery.CurrentTargetTrackId, track.TrackId)
	lu.assertTrue(track.AssignedBatteryIds:contains(battery.BatteryId))
end

function TestIadsNetwork:test_partition_split_and_rejoin_retire_obsolete_large_track_populations()
	local iads = makeIads()
	iads:initialize()
	iads._trackManager._displayIdAllocator = Medusa.Services.TrackDisplayIdAllocator:new()
	local trackManager = iads._trackManager
	local store = trackManager:getStore()
	local source = Medusa.Constants.TrackSource.EARLY_WARNING_RADAR
	local function report(contact, partitionKey)
		return {
			NetworkId = "contact-" .. tostring(contact),
			PartitionKey = partitionKey,
			SourceType = source,
			Position = { x = contact * 100, y = 1000, z = contact * 50 },
			Velocity = { x = 200, y = 0, z = 0 },
		}
	end
	local function commit(partitions)
		local byCluster = {}
		for clusterKey, partitionKey in pairs(partitions) do
			byCluster[clusterKey] = { Key = partitionKey }
		end
		iads:_commitPartitionRefresh({
			PartitionByCluster = byCluster,
			Sensors = {},
			Batteries = {},
			ProviderOverflowCount = 0,
		})
	end

	for contact = 1, 171 do
		lu.assertNotNil(trackManager:processReport(report(contact, "joined-1"), contact))
	end
	lu.assertEquals(store:count(), 171)

	commit({ east = "split-east", west = "split-west" })
	lu.assertEquals(store:count(), 0)
	for contact = 1, 171 do
		lu.assertNotNil(trackManager:processReport(report(contact, "split-east"), 200 + contact))
		lu.assertNotNil(trackManager:processReport(report(contact, "split-west"), 400 + contact))
	end
	lu.assertEquals(store:count(), 342)

	commit({ [""] = "joined-2" })
	lu.assertEquals(store:count(), 0)
	for contact = 1, 171 do
		lu.assertNotNil(trackManager:processReport(report(contact, "joined-2"), 600 + contact))
	end
	lu.assertEquals(store:count(), 171)
end

function TestIadsNetwork:test_bootstrap_partition_keeps_local_polling_after_first_refresh_failure()
	local iads = makeIads()
	iads:initialize()
	iads._doctrine.BatteryTargetDatalink = false
	local hierarchy = iads:getHierarchy()
	hierarchy:upsertGroup({
		groupId = 301,
		groupName = "root-sam",
		parsed = { echelonPath = {}, roles = {}, isHQ = false },
	})
	hierarchy:upsertGroup({
		groupId = 302,
		groupName = "child-hq",
		parsed = { echelonPath = { "child" }, roles = {}, isHQ = true },
	})
	hierarchy:upsertGroup({
		groupId = 303,
		groupName = "child-sam",
		parsed = { echelonPath = { "child" }, roles = {}, isHQ = false },
	})
	local function addRadarBattery(id, groupId)
		local battery = Medusa.Entities.Battery.new({
			BatteryId = id,
			NetworkId = "T",
			GroupId = groupId,
			GroupName = id,
			Role = Medusa.Constants.BatteryRole.SR_SAM,
			ActivationState = Medusa.Constants.ActivationState.STATE_WARM,
			DetectionRangeMax = 1000,
		})
		battery.Units = {
			Medusa.Entities.Battery.newUnit({
				UnitId = groupId * 10,
				Roles = { Medusa.Constants.BatteryUnitRole.SEARCH_RADAR },
			}),
		}
		iads:getAssetIndex():batteries():add(battery)
		return battery
	end
	local rootBattery = addRadarBattery("root-sam", 301)
	local childBattery = addRadarBattery("child-sam", 303)
	hierarchy:freezeC2Topology()
	lu.assertTrue(iads:_initializePartitionSnapshot())
	local rootKey = rootBattery.PartitionKey
	local childKey = childBattery.PartitionKey

	lu.assertNotNil(rootKey)
	lu.assertNotNil(childKey)
	lu.assertNotEquals(rootKey, childKey)
	lu.assertEquals(#iads:_buildPollList(), 2)
	lu.assertFalse(Medusa.Entities.Battery.canAcceptTrack(childBattery, { PartitionKey = rootKey }, iads._doctrine))

	Medusa.Services.PartitionService.begin = function()
		error("injected first-refresh failure")
	end
	iads._nextPartitionRefreshAt = 0
	iads:_runPartitionStep(0)

	lu.assertEquals(rootBattery.PartitionKey, rootKey)
	lu.assertEquals(childBattery.PartitionKey, childKey)
	lu.assertEquals(#iads:_buildPollList(), 2)
end

function TestIadsNetwork:test_partition_commit_failure_keeps_the_previous_snapshot_and_schedules_a_retry()
	local iads = makeIads()
	iads:initialize()
	local previous = iads._partitionSnapshot
	iads._partitionRefresh = { Pending = true }
	Medusa.Services.PartitionService.step = function()
		return true
	end
	iads._commitPartitionRefresh = function()
		error("injected commit failure")
	end

	local ok = pcall(function()
		iads:_runPartitionStep(5)
	end)

	lu.assertTrue(ok)
	lu.assertIsNil(iads._partitionRefresh)
	lu.assertEquals(iads._partitionSnapshot, previous)
	lu.assertEquals(iads._nextPartitionRefreshAt, 5 + Medusa.Constants.C2.REFRESH_INTERVAL_SEC)
end

function TestIadsNetwork:test_partition_commit_rolls_back_partial_asset_and_assignment_publication()
	local iads = makeIads()
	iads:initialize()
	local batteryStore = iads:getAssetIndex():batteries()
	local trackStore = iads._trackManager:getStore()
	local batteries = {}
	local tracks = {}
	for i = 1, 2 do
		local battery = Medusa.Entities.Battery.new({
			NetworkId = "T",
			GroupId = 420 + i,
			GroupName = "rollback-" .. i,
			PartitionKey = "old-partition",
			CoordinationState = Medusa.Constants.CoordinationState.COORDINATED,
			IsActingAsEWR = i == 1,
		})
		local track = {
			TrackId = "rollback-track-" .. i,
			TrackIdentification = "UNKNOWN",
			PartitionKey = "old-partition",
			AssignedBatteryIds = Set(),
		}
		batteryStore:add(battery)
		trackStore:add(track)
		Medusa.Entities.Battery.assignTrack(battery, track, 1, trackStore)
		batteries[i] = battery
		tracks[i] = track
	end
	local previousSnapshot = iads._partitionSnapshot
	local originalRelease = Medusa.Entities.Battery.releaseTrack
	local releaseCalls = 0
	Medusa.Entities.Battery.releaseTrack = function(...)
		releaseCalls = releaseCalls + 1
		if releaseCalls == 2 then
			error("injected release failure")
		end
		return originalRelease(...)
	end
	local committed, failure = pcall(function()
		iads:_commitPartitionRefresh({
			Sensors = {},
			Batteries = {
				{
					BatteryId = batteries[1].BatteryId,
					PartitionKey = "new-partition",
					CoordinationState = Medusa.Constants.CoordinationState.DEGRADED,
					IsActingAsEWR = false,
				},
				{
					BatteryId = batteries[2].BatteryId,
					PartitionKey = "new-partition",
					CoordinationState = Medusa.Constants.CoordinationState.DEGRADED,
					IsActingAsEWR = true,
				},
			},
			PartitionByCluster = { changed = true },
			ProviderOverflowCount = 0,
		})
	end)
	Medusa.Entities.Battery.releaseTrack = originalRelease

	lu.assertFalse(committed)
	lu.assertStrContains(tostring(failure), "injected release failure")
	lu.assertEquals(iads._partitionSnapshot, previousSnapshot)
	for i = 1, 2 do
		lu.assertEquals(batteries[i].PartitionKey, "old-partition")
		lu.assertEquals(batteries[i].CoordinationState, Medusa.Constants.CoordinationState.COORDINATED)
		lu.assertEquals(batteries[i].IsActingAsEWR, i == 1)
		lu.assertEquals(batteries[i].CurrentTargetTrackId, tracks[i].TrackId)
		lu.assertTrue(tracks[i].AssignedBatteryIds:contains(batteries[i].BatteryId))
	end
end

function TestIadsNetwork:test_partition_commit_rolls_back_when_track_retirement_fails()
	local iads = makeIads()
	iads:initialize()
	local battery = Medusa.Entities.Battery.new({
		BatteryId = "retirement-rollback-battery",
		NetworkId = "T",
		GroupId = 429,
		GroupName = "retirement-rollback-battery",
		PartitionKey = "old-partition",
		CoordinationState = Medusa.Constants.CoordinationState.COORDINATED,
		IsActingAsEWR = true,
	})
	iads:getAssetIndex():batteries():add(battery)
	local previousSnapshot = iads._partitionSnapshot
	local originalRetire = iads._trackManager.retirePartitionIncarnations
	iads._trackManager.retirePartitionIncarnations = function()
		error("injected retirement failure")
	end

	local committed, failure = pcall(function()
		iads:_commitPartitionRefresh({
			Sensors = {},
			Batteries = {
				{
					BatteryId = battery.BatteryId,
					PartitionKey = "new-partition",
					CoordinationState = Medusa.Constants.CoordinationState.DEGRADED,
					IsActingAsEWR = false,
				},
			},
			PartitionByCluster = {},
			ProviderOverflowCount = 0,
		})
	end)
	iads._trackManager.retirePartitionIncarnations = originalRetire

	lu.assertFalse(committed)
	lu.assertStrContains(tostring(failure), "injected retirement failure")
	lu.assertEquals(iads._partitionSnapshot, previousSnapshot)
	lu.assertEquals(battery.PartitionKey, "old-partition")
	lu.assertEquals(battery.CoordinationState, Medusa.Constants.CoordinationState.COORDINATED)
	lu.assertTrue(battery.IsActingAsEWR)
end

function TestIadsNetwork:test_poll_list_classifies_track_origin_sources()
	local iads = makeIads()
	iads:initialize()
	iads._doctrine = { BatteryTargetDatalink = true }
	local sensors = iads:getAssetIndex():sensors()
	local batteries = iads:getAssetIndex():batteries()
	local sensorType = Medusa.Constants.SensorType
	sensors:add(Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 1,
		UnitName = "awacs",
		GroupId = 1,
		GroupName = "awacs-group",
		SensorType = sensorType.AWACS,
		IsAirborne = true,
		GroupCategory = Group.Category.AIRPLANE,
		PartitionKey = "partition-a",
	}))
	sensors:add(Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 2,
		UnitName = "ewr",
		GroupId = 2,
		GroupName = "ewr-group",
		SensorType = sensorType.EWR,
		GroupCategory = Group.Category.GROUND,
		PartitionKey = "partition-a",
	}))
	sensors:add(Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 3,
		UnitName = "ship",
		GroupId = 3,
		GroupName = "ship-group",
		SensorType = sensorType.EWR,
		GroupCategory = Group.Category.SHIP,
		PartitionKey = "partition-a",
	}))
	sensors:add(Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 4,
		UnitName = "fighter",
		GroupId = 4,
		GroupName = "fighter-group",
		SensorType = sensorType.GCI,
		IsAirborne = true,
		GroupCategory = Group.Category.AIRPLANE,
		PartitionKey = "partition-a",
	}))
	batteries:add(Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 5,
		GroupName = "sam-group",
		GroupCategory = Group.Category.GROUND,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		PartitionKey = "partition-a",
	}))
	batteries:add(Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 6,
		GroupName = "sam-ship-group",
		GroupCategory = Group.Category.SHIP,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		PartitionKey = "partition-a",
	}))

	local byName = {}
	for _, source in ipairs(iads:_buildPollList()) do
		byName[source.groupName] = source.sourceType
	end

	local trackSource = Medusa.Constants.TrackSource
	lu.assertEquals(byName["awacs-group"], trackSource.AWACS)
	lu.assertEquals(byName["ewr-group"], trackSource.EARLY_WARNING_RADAR)
	lu.assertEquals(byName["ship-group"], trackSource.SHIPBORNE_RADAR)
	lu.assertEquals(byName["fighter-group"], trackSource.AIRBORNE_DATALINK)
	lu.assertEquals(byName["sam-group"], trackSource.SAM_BATTERY)
	lu.assertEquals(byName["sam-ship-group"], trackSource.SHIPBORNE_RADAR)
end

function TestIadsNetwork:test_sensor_poll_failures_degrade_then_recover_without_rediscovery()
	local iads = makeIads()
	iads:initialize()
	local hierarchy = iads:getHierarchy()
	hierarchy:upsertGroup({
		groupId = 1201,
		groupName = "root-ewr",
		parsed = { echelonPath = {}, roles = {}, isHQ = false },
	})
	hierarchy:upsertGroup({
		groupId = 1202,
		groupName = "root-battery",
		parsed = { echelonPath = {}, roles = {}, isHQ = false },
	})
	local sensor = Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 12011,
		UnitName = "root-ewr-unit",
		GroupId = 1201,
		GroupName = "root-ewr",
		SensorType = Medusa.Constants.SensorType.EWR,
		Position = { x = 0, y = 0, z = 0 },
		DetectionRangeMax = 10000,
	})
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 1202,
		GroupName = "root-battery",
		Role = Medusa.Constants.BatteryRole.LR_SAM,
		OperationalStatus = Medusa.Constants.BatteryOperationalStatus.ACTIVE,
		Position = { x = 0, y = 0, z = 0 },
		EngagementRangeMax = 1000,
	})
	iads:getAssetIndex():sensors():add(sensor)
	iads:getAssetIndex():batteries():add(battery)
	hierarchy:freezeC2Topology()
	lu.assertTrue(iads:_initializePartitionSnapshot())
	local function refresh(now)
		iads._nextPartitionRefreshAt = 0
		iads:_runPartitionStep(now)
		iads:_runPartitionStep(now)
	end
	refresh(0)
	lu.assertEquals(battery.CoordinationState, Medusa.Constants.CoordinationState.COORDINATED)

	GetTime = function()
		return 100
	end
	GetGroupController = function()
		return nil
	end
	iads:_pollSensors()
	lu.assertEquals(iads:getAssetIndex():sensors():count(), 1)
	lu.assertFalse(Medusa.Entities.SensorUnit.isAvailable(sensor))
	refresh(100)
	lu.assertEquals(battery.CoordinationState, Medusa.Constants.CoordinationState.DEGRADED)

	GetGroupController = function()
		return {}
	end
	GetControllerDetectedTargets = function()
		return {}
	end
	iads:_pollSensors()
	lu.assertTrue(Medusa.Entities.SensorUnit.isAvailable(sensor))
	refresh(115)
	lu.assertEquals(battery.CoordinationState, Medusa.Constants.CoordinationState.COORDINATED)

	GetControllerDetectedTargets = function()
		return nil
	end
	iads:_pollSensors()
	lu.assertFalse(Medusa.Entities.SensorUnit.isAvailable(sensor))
	refresh(130)
	lu.assertEquals(battery.CoordinationState, Medusa.Constants.CoordinationState.DEGRADED)

	GetControllerDetectedTargets = function()
		return {}
	end
	iads:_pollSensors()
	lu.assertTrue(Medusa.Entities.SensorUnit.isAvailable(sensor))
	refresh(145)
	lu.assertEquals(battery.CoordinationState, Medusa.Constants.CoordinationState.COORDINATED)
end

function TestIadsNetwork:test_last_poll_source_removal_clears_group_cursor_state()
	local iads = makeIads()
	iads:initialize()
	local battery = Medusa.Entities.Battery.new({
		BatteryId = "poll-battery",
		NetworkId = "T",
		GroupId = 1210,
		GroupName = "poll-group",
		Role = Medusa.Constants.BatteryRole.LR_SAM,
		OperationalStatus = Medusa.Constants.BatteryOperationalStatus.ACTIVE,
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = 12101,
			UnitName = "poll-battery-unit",
			Roles = { Medusa.Constants.BatteryUnitRole.SEARCH_RADAR },
		}),
	}
	local sensor = Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 12102,
		UnitName = "poll-sensor-unit",
		GroupId = 1210,
		GroupName = "poll-group",
		SensorType = Medusa.Constants.SensorType.EWR,
		Position = { x = 0, y = 0, z = 0 },
		DetectionRangeMax = 10000,
	})
	iads:getAssetIndex():batteries():add(battery)
	iads:getAssetIndex():sensors():add(sensor)
	iads._sensorDetectionOffsets["poll-group"] = 3
	iads._pollDetectionAccum["poll-group"] = 7

	iads:_handleUnitDeath(12101, "poll-battery-unit", { BatteryId = battery.BatteryId })
	lu.assertEquals(iads._sensorDetectionOffsets["poll-group"], 3)
	lu.assertEquals(iads._pollDetectionAccum["poll-group"], 7)

	iads:_handleUnitDeath(12102, "poll-sensor-unit", { SensorUnitId = sensor.SensorUnitId })
	lu.assertIsNil(iads._sensorDetectionOffsets["poll-group"])
	lu.assertIsNil(iads._pollDetectionAccum["poll-group"])
end

function TestIadsNetwork:test_airborne_position_failure_retains_sensor_for_recovery()
	local iads = makeIads()
	iads:initialize()
	local hierarchy = iads:getHierarchy()
	hierarchy:upsertGroup({
		groupId = 1202,
		groupName = "awacs-group",
		parsed = { echelonPath = {}, roles = {}, isHQ = false },
	})
	hierarchy:upsertGroup({
		groupId = 1203,
		groupName = "awacs-battery",
		parsed = { echelonPath = {}, roles = {}, isHQ = false },
	})
	local sensor = Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 12021,
		UnitName = "awacs-unit",
		GroupId = 1202,
		GroupName = "awacs-group",
		SensorType = Medusa.Constants.SensorType.AWACS,
		IsAirborne = true,
		DetectionRangeMax = 10000,
	})
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 1203,
		GroupName = "awacs-battery",
		Role = Medusa.Constants.BatteryRole.LR_SAM,
		OperationalStatus = Medusa.Constants.BatteryOperationalStatus.ACTIVE,
		Position = { x = 0, y = 0, z = 0 },
		EngagementRangeMax = 1000,
	})
	iads:getAssetIndex():sensors():add(sensor)
	iads:getAssetIndex():batteries():add(battery)
	hierarchy:freezeC2Topology()
	lu.assertTrue(iads:_initializePartitionSnapshot())
	local function refresh(now)
		iads._nextPartitionRefreshAt = 0
		iads:_runPartitionStep(now)
		iads:_runPartitionStep(now)
	end

	lu.assertEquals(iads:getAssetIndex():sensors():count(), 1)
	lu.assertFalse(Medusa.Entities.SensorUnit.isAvailable(sensor))
	refresh(0)
	lu.assertEquals(battery.CoordinationState, Medusa.Constants.CoordinationState.DEGRADED)

	GetUnitPosition = function()
		return { x = 4, y = 5, z = 6 }
	end
	iads:_updateSensorPositions()
	lu.assertTrue(Medusa.Entities.SensorUnit.isAvailable(sensor))
	lu.assertEquals(sensor.Position.x, 4)
	refresh(15)
	lu.assertEquals(battery.CoordinationState, Medusa.Constants.CoordinationState.COORDINATED)
end

function TestIadsNetwork:test_ground_sensor_retries_an_initially_unavailable_position()
	local iads = makeIads()
	iads:initialize()
	local sensor = Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 12022,
		UnitName = "ground-ewr-unit",
		GroupId = 1204,
		GroupName = "ground-ewr-group",
		SensorType = Medusa.Constants.SensorType.EWR,
	})
	iads:getAssetIndex():sensors():add(sensor)
	GetUnitPosition = function()
		return { x = 7, y = 0, z = 8 }
	end

	iads:_updateSensorPositions()

	lu.assertTrue(Medusa.Entities.SensorUnit.isAvailable(sensor))
	lu.assertEquals(sensor.Position, { x = 7, y = 0, z = 8 })
end

function TestIadsNetwork:test_sensor_detection_work_is_bounded_and_rotates()
	local iads = makeIads()
	iads:initialize()
	local sensor = Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 12031,
		UnitName = "bounded-ewr-unit",
		GroupId = 1203,
		GroupName = "bounded-ewr",
		SensorType = Medusa.Constants.SensorType.EWR,
		PartitionKey = "partition-a",
	})
	iads:getAssetIndex():sensors():add(sensor)
	local detections = {}
	for i = 1, Medusa.Constants.C2.DETECTION_PROCESSING_BUDGET + 3 do
		detections[i] = {
			object = {
				id_ = i,
				getCategory = function()
					return Object.Category.UNIT
				end,
				getPoint = function()
					return { x = i, y = 0, z = 0 }
				end,
				getVelocity = function()
					return { x = 1, y = 0, z = 0 }
				end,
			},
		}
	end
	GetGroupController = function()
		return {}
	end
	GetControllerDetectedTargets = function()
		return detections
	end
	local now = 100
	GetTime = function()
		return now
	end
	local processed = {}
	iads._trackManager.processReport = function(_, report)
		processed[#processed + 1] = report.NetworkId
	end

	iads:_pollSensors()
	lu.assertEquals(#processed, Medusa.Constants.C2.DETECTION_PROCESSING_BUDGET)
	lu.assertEquals(processed[1], 1)
	lu.assertEquals(processed[#processed], Medusa.Constants.C2.DETECTION_PROCESSING_BUDGET)

	processed = {}
	now = 106
	iads:_pollSensors()
	lu.assertEquals(#processed, Medusa.Constants.C2.DETECTION_PROCESSING_BUDGET)
	lu.assertEquals(processed[1], Medusa.Constants.C2.DETECTION_PROCESSING_BUDGET + 1)
	lu.assertEquals(processed[3], Medusa.Constants.C2.DETECTION_PROCESSING_BUDGET + 3)
end

function TestIadsNetwork:test_discovery_routes_hq_to_c2nodes()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	injectProvider(iads, {
		{
			groupId = 300,
			groupName = "iads.alpha.hq.cmd",
			coalitionId = COAL_RED,
			category = "ground",
		},
	})

	iads._tickCounter = 0
	iads:tick()

	lu.assertEquals(iads:getAssetIndex():batteries():count(), 0)
	lu.assertEquals(iads:getAssetIndex():sensors():count(), 0)
	lu.assertEquals(iads:getAssetIndex():c2Nodes():count(), 1)
end

function TestIadsNetwork:test_dynamic_hq_does_not_create_a_node_after_topology_freeze()
	local iads = makeIads()
	iads:initialize()
	iads._running = true
	local groups = {}
	injectProvider(iads, groups)
	iads._tickCounter = 0
	iads:tick()
	groups[1] = {
		groupId = 301,
		groupName = "iads.dynamic.hq.cmd",
		coalitionId = COAL_RED,
		category = "ground",
	}

	iads:_runScanAndLog()

	lu.assertEquals(iads:getAssetIndex():c2Nodes():count(), 0)
end

function TestIadsNetwork:test_dynamic_degraded_battery_retries_erect_then_becomes_warm()
	local iads = makeIads()
	iads:initialize()
	iads._running = true
	local groups = {}
	injectProvider(iads, groups)
	iads._tickCounter = 0
	iads:tick()
	iads._erectComplete = true
	GetGroupController = function()
		return {}
	end
	SetControllerOnOff = function()
		return true
	end
	ControllerSetROE = function()
		return true
	end
	ControllerSetAlarmState = function()
		return true
	end
	ControllerSetDisperseOnAttack = function()
		return false
	end
	EnableGroupEmissions = function()
		return true
	end
	groups[1] = {
		groupId = 302,
		groupName = "iads.dynamic.sa10",
		coalitionId = COAL_RED,
		category = "ground",
	}

	iads:_runScanAndLog()

	local battery = iads:getAssetIndex():batteries():getByGroupId(302)
	lu.assertNotNil(battery)
	lu.assertEquals(battery.CoordinationState, Medusa.Constants.CoordinationState.DEGRADED)
	lu.assertTrue(battery.ErectPending)
	lu.assertEquals(battery.ActivationState, Medusa.Constants.ActivationState.INITIALIZING)
	ControllerSetDisperseOnAttack = function()
		return true
	end
	iads:_retryPendingErects(2, GetTime() + 1)
	lu.assertFalse(battery.ErectPending)
	lu.assertEquals(battery.ActivationState, Medusa.Constants.ActivationState.STATE_WARM)
end

function TestIadsNetwork:test_dynamic_networked_battery_joins_derived_point_defense_on_next_harm_phase()
	local C = Medusa.Constants
	local iads = makeIads()
	iads:initialize()
	iads._running = true
	local groups = {}
	injectProvider(iads, groups)
	iads._tickCounter = 0
	iads:tick()
	groups[1] = {
		groupId = 305,
		groupName = "iads.dynamic.shorad",
		coalitionId = COAL_RED,
		category = "ground",
	}

	iads:_runScanAndLog()

	local provider = iads:getAssetIndex():batteries():getByGroupId(305)
	lu.assertNotNil(provider)
	provider.Role = C.BatteryRole.SR_SAM
	provider.Position = { x = 0, y = 0, z = 0 }
	provider.TotalAmmoStatus = 1
	local partitionKey = provider.PartitionKey
	local protected = Medusa.Entities.Battery.new({
		BatteryId = "dynamic-protected",
		NetworkId = "T",
		GroupId = 306,
		GroupName = "iads.dynamic.protected",
		Role = C.BatteryRole.LR_SAM,
		OperationalStatus = C.BatteryOperationalStatus.ACTIVE,
		Position = { x = 100, y = 0, z = 0 },
		PartitionKey = partitionKey,
		TotalAmmoStatus = 1,
	})
	iads:getAssetIndex():batteries():add(protected)
	iads._spatialIndex:syncBattery(provider)
	iads._spatialIndex:syncBattery(protected)
	iads._assignmentPhase = 1
	lu.assertNotNil(partitionKey)
	lu.assertEquals(provider.PartitionKey, protected.PartitionKey)
	lu.assertTrue(Medusa.Services.PointDefenseService.isProviderViable(provider))
	lu.assertTrue(Medusa.Services.PointDefenseService.isProviderViable(protected))

	iads:_runPhase()

	lu.assertEquals(iads._phaseFailures[1], 0)
	lu.assertTrue(provider.IsPointDefense)
end

function TestIadsNetwork:test_dynamic_battery_with_unknown_initial_ammunition_is_scheduled_for_reconciliation()
	local iads = makeIads()
	iads:initialize()
	iads._running = true
	local groups = {}
	injectProvider(iads, groups)
	iads._tickCounter = 0
	iads:tick()
	GetUnitAmmo = function()
		return nil
	end
	groups[1] = {
		groupId = 303,
		groupName = "iads.dynamic.sa10.unknown-ammo",
		coalitionId = COAL_RED,
		category = "ground",
	}

	iads:_runScanAndLog()

	local battery = iads:getAssetIndex():batteries():getByGroupId(303)
	lu.assertNotNil(battery)
	lu.assertFalse(battery.AmmoKnown)
	lu.assertTrue(iads._ammoReconcileSet[battery.BatteryId])
end

function TestIadsNetwork:test_dynamic_manpad_recovers_from_unknown_initial_ammunition()
	local iads = makeIads()
	iads:initialize()
	iads._running = true
	local groups = {}
	injectProvider(iads, groups)
	iads._tickCounter = 0
	iads:tick()
	GetUnitAmmo = function()
		return nil
	end
	GetUnitDesc = function()
		return { attributes = { MANPADS = true } }
	end
	groups[1] = {
		groupId = 304,
		groupName = "iads.dynamic.manpad.team",
		coalitionId = COAL_RED,
		category = "ground",
	}

	iads:_runScanAndLog()

	local battery = iads:getAssetIndex():manpads():getByGroupId(304)
	lu.assertNotNil(battery)
	lu.assertFalse(battery.AmmoKnown)
	lu.assertTrue(iads._ammoReconcileSet[battery.BatteryId])
	GetUnitAmmo = function()
		return {
			{
				count = 1,
				desc = { missileCategory = 1, typeName = "manpad-missile", rangeMaxAltMax = 5000 },
			},
		}
	end

	iads:_processAmmoReconciliation(2, 0)

	lu.assertTrue(battery.AmmoKnown)
	lu.assertEquals(battery.TotalAmmoStatus, 2)
	lu.assertNil(iads._ammoReconcileSet[battery.BatteryId])
end

function TestIadsNetwork:test_first_tick_initializes_batteries_cold()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	injectProvider(iads, {
		{
			groupId = 400,
			groupName = "iads.alpha.sa10",
			coalitionId = COAL_RED,
			category = "ground",
		},
		{
			groupId = 401,
			groupName = "iads.alpha.sa11",
			coalitionId = COAL_RED,
			category = "ground",
		},
	})

	iads._tickCounter = 0
	iads:tick()

	local store = iads:getAssetIndex():batteries()
	lu.assertEquals(store:count(), 2)
	local all = store:getAll()
	-- Batteries stay INITIALIZING after tick 1 (doctrine states deferred 60s for fast erect)
	for i = 1, #all do
		lu.assertEquals(all[i].ActivationState, Medusa.Constants.ActivationState.INITIALIZING)
	end
end

function TestIadsNetwork:test_delayed_initialization_retries_after_a_failed_battery_command()
	local iads = makeIads()
	iads:initialize()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 402,
		GroupName = "iads.alpha.sa6.retry",
	})
	iads:getAssetIndex():batteries():add(battery)
	GetGroupController = function()
		return {}
	end
	SetControllerOnOff = function()
		return true
	end
	ControllerSetAlarmState = function()
		return true
	end
	EnableGroupEmissions = function()
		return true
	end
	ControllerSetDisperseOnAttack = function()
		return true
	end
	ControllerSetROE = function()
		return false
	end

	lu.assertFalse(iads:_completeErectInitialization())
	lu.assertFalse(iads._erectComplete)
	lu.assertTrue(battery.ErectPending)
	lu.assertEquals(battery.ActivationState, Medusa.Constants.ActivationState.INITIALIZING)

	ControllerSetROE = function()
		return true
	end
	lu.assertTrue(iads:_completeErectInitialization())
	lu.assertTrue(iads._erectComplete)
	lu.assertFalse(battery.ErectPending)
	lu.assertEquals(battery.ActivationState, Medusa.Constants.ActivationState.STATE_WARM)
end

function TestIadsNetwork:test_initial_degraded_battery_uses_degraded_doctrine_before_emcon_phase()
	local iads = makeIads()
	iads:initialize()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 404,
		GroupName = "iads.alpha.sa6.degraded",
		Role = Medusa.Constants.BatteryRole.LR_SAM,
		CoordinationState = Medusa.Constants.CoordinationState.DEGRADED,
	})
	iads:getAssetIndex():batteries():add(battery)
	GetGroupController = function()
		return {}
	end
	SetControllerOnOff = function()
		return true
	end
	ControllerSetAlarmState = function()
		return true
	end
	EnableGroupEmissions = function()
		return true
	end
	ControllerSetDisperseOnAttack = function()
		return true
	end
	ControllerSetROE = function()
		return true
	end

	lu.assertTrue(iads:_initializeBatteryStates())
	lu.assertEquals(battery.ActivationState, Medusa.Constants.ActivationState.STATE_WARM)

	iads._doctrine.DegradedMode = Medusa.Constants.NetworkDegradationPolicy.GO_DARK
	battery.ActivationState = Medusa.Constants.ActivationState.INITIALIZING
	battery.LastStateChangeTime = nil
	lu.assertTrue(iads:_initializeBatteryStates())
	lu.assertEquals(battery.ActivationState, Medusa.Constants.ActivationState.STATE_COLD)
end

function TestIadsNetwork:test_rearmed_degraded_battery_returns_warm_before_emcon_phase()
	local iads = makeIads()
	iads:initialize()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 405,
		GroupName = "iads.alpha.sa6.rearmed",
		Role = Medusa.Constants.BatteryRole.LR_SAM,
		ActivationState = Medusa.Constants.ActivationState.STATE_COLD,
		OperationalStatus = Medusa.Constants.BatteryOperationalStatus.REARMING,
		CoordinationState = Medusa.Constants.CoordinationState.DEGRADED,
		RearmCheckTime = 100,
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = 4051,
			UnitName = "launcher-4051",
			Roles = { Medusa.Constants.BatteryUnitRole.LAUNCHER },
			AmmoCount = 0,
			AmmoTypes = {},
		}),
	}
	battery.RearmCheckTime = 100
	iads:getAssetIndex():batteries():add(battery)
	GetGroupController = function()
		return {}
	end
	SetControllerOnOff = function()
		return true
	end
	ControllerSetAlarmState = function()
		return true
	end
	EnableGroupEmissions = function()
		return true
	end
	ControllerSetROE = function()
		return true
	end
	GetUnitAmmo = function()
		return {
			{
				count = 2,
				desc = { missileCategory = 1, typeName = "missile", rangeMaxAltMax = 10000 },
			},
		}
	end

	iads:_checkRearming(100)

	lu.assertNil(battery.RearmCheckTime)
	lu.assertEquals(battery.ActivationState, Medusa.Constants.ActivationState.STATE_WARM)
end

function TestIadsNetwork:test_assignment_is_rolled_back_when_activation_is_not_confirmed()
	local iads = makeIads()
	local battery = Medusa.Entities.Battery.new({ NetworkId = "T", GroupId = 403, GroupName = "sam" })
	local track = { TrackId = "track", AssignedBatteryIds = Set() }
	local trackStore = {
		get = function(_, trackId)
			return trackId == track.TrackId and track or nil
		end,
	}
	local batteryStore = {
		get = function(_, batteryId)
			return batteryId == battery.BatteryId and battery or nil
		end,
		getAll = function()
			return { battery }
		end,
	}
	local originalSelfAssign = Medusa.Services.TargetAssigner.emconSelfAssign
	local originalAssign = Medusa.Services.TargetAssigner.assignTargets
	local originalGoHot = Medusa.Services.BatteryActivationService.goHot
	local ok, err = pcall(function()
		Medusa.Services.TargetAssigner.emconSelfAssign = function()
			Medusa.Entities.Battery.assignTrack(battery, track, 1, trackStore)
			return { { batteryId = battery.BatteryId, trackId = track.TrackId } }
		end
		Medusa.Services.TargetAssigner.assignTargets = function()
			return {}
		end
		Medusa.Services.BatteryActivationService.goHot = function()
			return false
		end
		iads:_phaseAssign({
			batteryStore = batteryStore,
			trackStore = trackStore,
			now = 1,
			hpt = function()
				return 0
			end,
			MS = { observe = function() end, inc = function() end },
		})
	end)
	Medusa.Services.TargetAssigner.emconSelfAssign = originalSelfAssign
	Medusa.Services.TargetAssigner.assignTargets = originalAssign
	Medusa.Services.BatteryActivationService.goHot = originalGoHot

	lu.assertTrue(ok, tostring(err))
	lu.assertNil(battery.CurrentTargetTrackId)
	lu.assertFalse(track.AssignedBatteryIds:contains(battery.BatteryId))
end

function TestIadsNetwork:test_existing_assignment_is_rolled_back_when_hot_retry_fails()
	local iads = makeIads()
	local battery = Medusa.Entities.Battery.new({ NetworkId = "T", GroupId = 404, GroupName = "sam" })
	local track = { TrackId = "track", AssignedBatteryIds = Set() }
	local trackStore = {
		get = function(_, trackId)
			return trackId == track.TrackId and track or nil
		end,
	}
	local batteryStore = {
		get = function(_, batteryId)
			return batteryId == battery.BatteryId and battery or nil
		end,
		getAll = function()
			return { battery }
		end,
	}
	Medusa.Entities.Battery.assignTrack(battery, track, 1, trackStore)
	local originalSelfAssign = Medusa.Services.TargetAssigner.emconSelfAssign
	local originalAssign = Medusa.Services.TargetAssigner.assignTargets
	local originalGoHot = Medusa.Services.BatteryActivationService.goHot
	local ok, err = pcall(function()
		Medusa.Services.TargetAssigner.emconSelfAssign = function()
			return {}
		end
		Medusa.Services.TargetAssigner.assignTargets = function()
			return {}
		end
		Medusa.Services.BatteryActivationService.goHot = function()
			return false
		end
		iads:_phaseAssign({
			batteryStore = batteryStore,
			trackStore = trackStore,
			now = 1,
			hpt = function()
				return 0
			end,
			MS = { observe = function() end, inc = function() end },
		})
	end)
	Medusa.Services.TargetAssigner.emconSelfAssign = originalSelfAssign
	Medusa.Services.TargetAssigner.assignTargets = originalAssign
	Medusa.Services.BatteryActivationService.goHot = originalGoHot

	lu.assertTrue(ok, tostring(err))
	lu.assertNil(battery.CurrentTargetTrackId)
	lu.assertFalse(track.AssignedBatteryIds:contains(battery.BatteryId))
end

function TestIadsNetwork:test_new_assignment_to_already_hot_battery_is_retained()
	local iads = makeIads()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 406,
		GroupName = "sam-hot",
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
	})
	local track = { TrackId = "track-hot", AssignedBatteryIds = Set() }
	local trackStore = {
		get = function(_, trackId)
			return trackId == track.TrackId and track or nil
		end,
	}
	local batteryStore = {
		get = function(_, batteryId)
			return batteryId == battery.BatteryId and battery or nil
		end,
		getAll = function()
			return { battery }
		end,
	}
	local originalSelfAssign = Medusa.Services.TargetAssigner.emconSelfAssign
	local originalAssign = Medusa.Services.TargetAssigner.assignTargets
	local originalGoHot = Medusa.Services.BatteryActivationService.goHot
	local goHotCalls = 0
	local ok, err = pcall(function()
		Medusa.Services.TargetAssigner.emconSelfAssign = function()
			Medusa.Entities.Battery.assignTrack(battery, track, 1, trackStore)
			return { { batteryId = battery.BatteryId, trackId = track.TrackId } }
		end
		Medusa.Services.TargetAssigner.assignTargets = function()
			return {}
		end
		Medusa.Services.BatteryActivationService.goHot = function()
			goHotCalls = goHotCalls + 1
			return false
		end
		iads:_phaseAssign({
			batteryStore = batteryStore,
			trackStore = trackStore,
			now = 1,
			hpt = function()
				return 0
			end,
			MS = { observe = function() end, inc = function() end },
		})
	end)
	Medusa.Services.TargetAssigner.emconSelfAssign = originalSelfAssign
	Medusa.Services.TargetAssigner.assignTargets = originalAssign
	Medusa.Services.BatteryActivationService.goHot = originalGoHot

	lu.assertTrue(ok, tostring(err))
	lu.assertEquals(goHotCalls, 0)
	lu.assertEquals(battery.CurrentTargetTrackId, track.TrackId)
	lu.assertTrue(track.AssignedBatteryIds:contains(battery.BatteryId))
end

function TestIadsNetwork:test_mixed_groups_route_correctly()
	local iads = makeIads()
	iads:initialize()
	iads._running = true

	injectProvider(iads, {
		{ groupId = 500, groupName = "iads.alpha.sa6", coalitionId = COAL_RED, category = "ground" },
		{ groupId = 501, groupName = "iads.alpha.gci.site1", coalitionId = COAL_RED, category = "ground" },
		{ groupId = 502, groupName = "iads.alpha.hq.cmd", coalitionId = COAL_RED, category = "ground" },
		{ groupId = 503, groupName = "iads.alpha.sa11", coalitionId = COAL_RED, category = "ground" },
		{ groupId = 504, groupName = "iads.alpha.ewr.bigbird", coalitionId = COAL_RED, category = "ground" },
	})

	iads._tickCounter = 0
	iads:tick()

	-- 2 batteries (sa6, sa11), 2 sensor groups (gci, ewr), 1 HQ -> c2node
	lu.assertEquals(iads:getAssetIndex():batteries():count(), 2)
	lu.assertEquals(#iads:getAssetIndex():sensors():getUniqueGroupNames(), 2)
	lu.assertEquals(iads:getAssetIndex():c2Nodes():count(), 1)
end

-- == Death Event Tests ==

local function localDefenseUnit(unitId, role)
	return Medusa.Entities.Battery.newUnit({
		UnitId = unitId,
		UnitName = "local-defense-" .. tostring(unitId),
		Roles = { role },
		AmmoCount = 10,
		AmmoTypes = {
			{
				Count = 10,
				RangeMax = 5000,
			},
		},
	})
end

function TestIadsNetwork:test_death_removes_sensor()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeWorldEvents()
	iads._running = true

	local sensorStore = iads:getAssetIndex():sensors()
	sensorStore:add(Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 50,
		UnitName = "ewr-1",
		GroupId = 600,
		GroupName = "iads.alpha.ewr.site1",
		SensorType = "EWR",
	}))
	lu.assertEquals(sensorStore:count(), 1)

	iads._deathQueue:enqueue({
		_unitId = 50,
		initiator = {
			getCoalition = function()
				return COAL_RED
			end,
		},
	})
	iads:_processDeathEvents(2)

	lu.assertEquals(sensorStore:count(), 0)
end

function TestIadsNetwork:test_death_removes_battery_unit()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeWorldEvents()
	iads._running = true

	local batteryStore = iads:getAssetIndex():batteries()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 700,
		GroupName = "iads.alpha.sa10",
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({ UnitId = 60 }),
		Medusa.Entities.Battery.newUnit({ UnitId = 61 }),
	}
	batteryStore:add(battery)
	lu.assertEquals(batteryStore:count(), 1)
	lu.assertEquals(#battery.Units, 2)

	iads._deathQueue:enqueue({
		_unitId = 60,
		initiator = {
			getCoalition = function()
				return COAL_RED
			end,
		},
	})
	iads:_processDeathEvents(2)

	lu.assertEquals(batteryStore:count(), 1)
	lu.assertEquals(#battery.Units, 1)
	lu.assertEquals(battery.Units[1].UnitId, 61)
end

function TestIadsNetwork:test_destroyed_aaa_member_suppresses_surviving_battery()
	ControllerSetROE = function()
		return true
	end
	ControllerSetAlarmState = function()
		return true
	end
	EnableGroupEmissions = function()
		return true
	end
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeWorldEvents()
	iads._running = true

	local batteryStore = iads:getAssetIndex():batteries()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 750,
		GroupName = "iads.alpha.aaa.site1",
		Role = Medusa.Constants.BatteryRole.AAA,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		GroupDiameterM = 0,
	})
	battery.Units = {
		localDefenseUnit(65, Medusa.Constants.BatteryUnitRole.AAA),
		localDefenseUnit(66, Medusa.Constants.BatteryUnitRole.AAA),
	}
	batteryStore:add(battery)

	iads._deathQueue:enqueue({ _unitId = 65 })
	iads:_processDeathEvents(2)

	lu.assertEquals(#battery.Units, 1)
	lu.assertEquals(battery.OperationalStatus, Medusa.Constants.BatteryOperationalStatus.ACTIVE)
	lu.assertEquals(battery.CrewSuppressionState, Medusa.Constants.CrewSuppressionState.SUPPRESSED)
	lu.assertEquals(battery.CrewSuppressionCause, Medusa.Constants.CrewSuppressionCause.DAMAGE)
	lu.assertNotNil(battery.CrewSuppressionTimerId)
	lu.assertEquals(battery.ActivationState, Medusa.Constants.ActivationState.STATE_COLD)
end

function TestIadsNetwork:test_destroyed_manpad_member_suppresses_surviving_group()
	ControllerSetROE = function()
		return true
	end
	ControllerSetAlarmState = function()
		return true
	end
	EnableGroupEmissions = function()
		return true
	end
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeWorldEvents()
	iads._running = true

	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 760,
		GroupName = "iads.alpha.manpad.team1",
		Role = Medusa.Constants.BatteryRole.MANPAD,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		GroupDiameterM = 0,
		Manpad = {
			SleepWakeState = Medusa.Constants.Manpad.SleepWakeState.HOT,
			WakeReason = Medusa.Constants.Manpad.WakeReason.IADS,
			AlertCycleCount = 0,
			AudioCueRangeM = Medusa.Constants.Manpad.AUDIO_RANGE_MAX_M,
			UnitHeadings = {},
			UnitHeadingCount = 0,
		},
	})
	battery.Units = {
		localDefenseUnit(67, Medusa.Constants.BatteryUnitRole.MANPAD),
		localDefenseUnit(68, Medusa.Constants.BatteryUnitRole.MANPAD),
	}
	iads:getAssetIndex():manpads():add(battery)

	iads._deathQueue:enqueue({ _unitId = 67 })
	iads:_processDeathEvents(2)

	lu.assertEquals(#battery.Units, 1)
	lu.assertEquals(battery.OperationalStatus, Medusa.Constants.BatteryOperationalStatus.ACTIVE)
	lu.assertEquals(battery.CrewSuppressionState, Medusa.Constants.CrewSuppressionState.SUPPRESSED)
	lu.assertEquals(battery.CrewSuppressionCause, Medusa.Constants.CrewSuppressionCause.DAMAGE)
	lu.assertNotNil(battery.CrewSuppressionTimerId)
	lu.assertEquals(battery.Manpad.SleepWakeState, Medusa.Constants.Manpad.SleepWakeState.ALERT)
	lu.assertEquals(battery.ActivationState, Medusa.Constants.ActivationState.STATE_COLD)
end

function TestIadsNetwork:test_death_removes_battery_when_all_dead()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeWorldEvents()
	iads._running = true

	local batteryStore = iads:getAssetIndex():batteries()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 800,
		GroupName = "iads.alpha.aaa.last",
		Role = Medusa.Constants.BatteryRole.AAA,
		GroupDiameterM = 0,
	})
	battery.Units = {
		localDefenseUnit(70, Medusa.Constants.BatteryUnitRole.AAA),
	}
	batteryStore:add(battery)

	iads._deathQueue:enqueue({
		_unitId = 70,
		initiator = {
			getCoalition = function()
				return COAL_RED
			end,
		},
	})
	iads:_processDeathEvents(2)

	lu.assertEquals(batteryStore:count(), 0)
	lu.assertEquals(battery.CrewSuppressionState, Medusa.Constants.CrewSuppressionState.CLEAR)
	lu.assertNil(battery.CrewSuppressionTimerId)
end

function TestIadsNetwork:test_death_ignores_unknown_unit()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeWorldEvents()
	iads._running = true

	local sensorStore = iads:getAssetIndex():sensors()
	local batteryStore = iads:getAssetIndex():batteries()

	iads._deathQueue:enqueue({
		_unitId = 999,
		initiator = {
			getCoalition = function()
				return COAL_RED
			end,
		},
	})
	iads:_processDeathEvents(2)

	lu.assertEquals(sensorStore:count(), 0)
	lu.assertEquals(batteryStore:count(), 0)
end

function TestIadsNetwork:test_stale_unit_events_do_not_affect_a_reused_id_and_name()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeWorldEvents()
	local battery = Medusa.Entities.Battery.new({
		BatteryId = "replacement",
		NetworkId = "T",
		GroupId = 900,
		GroupName = "iads.alpha.replacement",
		Role = Medusa.Constants.BatteryRole.SR_SAM,
		TotalAmmoStatus = 1,
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = 9001,
			UnitName = "replacement-unit",
			Roles = { Medusa.Constants.BatteryUnitRole.LAUNCHER },
			AmmoCount = 1,
			AmmoTypes = { { Count = 1, WeaponTypeName = "missile", RangeMax = 1000 } },
		}),
	}
	iads:getAssetIndex():batteries():add(battery)
	iads._rollingPkBuffer = { 0 }
	iads._rollingPkIndex = 1
	iads._rollingPkCount = 1

	local staleIdentity = {
		_unitId = 9001,
		_unitName = "replacement-unit",
		_identityCaptured = true,
		_batteryId = "retired-incarnation",
	}
	iads._deathQueue:enqueue(staleIdentity)
	staleIdentity._weaponTypeName = "missile"
	iads._shotQueue:enqueue(staleIdentity)
	iads._killQueue:enqueue(staleIdentity)
	iads:_processDeathEvents(1)
	iads:_processShotEvents(1)
	iads:_processKillEvents(1)

	lu.assertEquals(iads:getAssetIndex():batteries():get(battery.BatteryId), battery)
	lu.assertEquals(battery.TotalAmmoStatus, 1)
	lu.assertEquals(battery.ShotsFired, 0)
	lu.assertEquals(iads._rollingPkBuffer[1], 0)
end

function TestIadsNetwork:test_shot_attribution_rejection_logs_captured_and_current_owners()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeWorldEvents()
	local battery = Medusa.Entities.Battery.new({
		BatteryId = "current-battery",
		NetworkId = "T",
		GroupId = 910,
		GroupName = "iads.alpha.current",
		Role = Medusa.Constants.BatteryRole.SR_SAM,
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = 9101,
			UnitName = "current-launcher",
			Roles = { Medusa.Constants.BatteryUnitRole.LAUNCHER },
		}),
	}
	iads:getAssetIndex():batteries():add(battery)
	local messages = {}
	env.info = function(message)
		messages[#messages + 1] = message
	end
	Medusa.Logger:setLevel(Medusa.Constants.LogLevel.DEBUG)

	lu.assertTrue(iads._shotQueue:enqueue({
		_unitId = 9101,
		_unitName = "current-launcher",
		_weaponTypeName = "missile",
		_identityCaptured = true,
		_batteryId = "retired-battery",
	}))
	iads:_processShotEvents(1)

	local diagnostic = nil
	for i = 1, #messages do
		if string.find(messages[i], "SHOT attribution rejected:", 1, true) then
			diagnostic = messages[i]
			break
		end
	end
	lu.assertNotNil(diagnostic)
	lu.assertStrContains(diagnostic, "reason=battery-id-mismatch")
	lu.assertStrContains(diagnostic, "unitId=9101")
	lu.assertStrContains(diagnostic, "observedUnitName=current-launcher")
	lu.assertStrContains(diagnostic, "capturedBatteryId=retired-battery")
	lu.assertStrContains(diagnostic, "currentBatteryId=current-battery")
	lu.assertStrContains(diagnostic, "currentUnitName=current-launcher")
	lu.assertEquals(battery.ShotsFired, 0)
end

function TestIadsNetwork:test_scenario_one_shot_uses_exact_unit_name_when_event_id_differs()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeWorldEvents()
	local source = scenario.ProtectedSite.Units[10]
	local battery = Medusa.Entities.Battery.new({
		BatteryId = "scenario-one-sa10",
		NetworkId = "T",
		GroupId = scenario.ProtectedSite.GroupId,
		GroupName = scenario.ProtectedSite.GroupName,
		Role = Medusa.Constants.BatteryRole.LR_SAM,
		EngagementRangeMax = 75000,
		TotalAmmoStatus = 1,
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = source.UnitId + 100000,
			UnitName = source.UnitName,
			UnitTypeName = source.UnitTypeName,
			Roles = { Medusa.Constants.BatteryUnitRole.LAUNCHER },
			AmmoCount = 1,
			AmmoTypes = { { Count = 1, WeaponTypeName = "SA5B55", RangeMax = 75000 } },
		}),
	}
	iads:getAssetIndex():batteryRepository():add(battery)

	lu.assertTrue(iads._shotQueue:enqueue({
		_unitId = source.UnitId,
		_unitName = source.UnitName,
		_weaponTypeName = "SA5B55",
	}))
	iads:_processShotEvents(1)

	lu.assertEquals(battery.ShotsFired, 1)
	lu.assertEquals(battery.TotalAmmoStatus, 0)
end

function TestIadsNetwork:test_death_event_name_alias_removes_the_stored_unit_identity()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeWorldEvents()
	local source = scenario.ProtectedSite.Units[10]
	local battery = Medusa.Entities.Battery.new({
		BatteryId = "scenario-one-sa10",
		NetworkId = "T",
		GroupId = scenario.ProtectedSite.GroupId,
		GroupName = scenario.ProtectedSite.GroupName,
		Role = Medusa.Constants.BatteryRole.LR_SAM,
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = source.UnitId + 100000,
			UnitName = source.UnitName,
			Roles = { Medusa.Constants.BatteryUnitRole.LAUNCHER },
		}),
	}
	local repository = iads:getAssetIndex():batteryRepository()
	repository:add(battery)

	lu.assertTrue(iads._deathQueue:enqueue({
		_unitId = source.UnitId,
		_unitName = source.UnitName,
	}))
	iads:_processDeathEvents(1)

	lu.assertNil(repository:get(battery.BatteryId))
	lu.assertNil(repository:getByUnitId(source.UnitId))
	lu.assertNil(repository:getByUnitId(source.UnitId + 100000))
	lu.assertNil(repository:resolveUnit(nil, source.UnitName))
end

function TestIadsNetwork:test_death_overflow_recovers_the_managed_unit_with_bounded_work()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeWorldEvents()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 901,
		GroupName = "iads.alpha.sa6",
	})
	battery.Units = { Medusa.Entities.Battery.newUnit({ UnitId = 9011, UnitName = "dead-unit" }) }
	iads:getAssetIndex():batteries():add(battery)
	for unitId = 1, Medusa.Constants.WorldEventQueue.DEATH_CAPACITY do
		iads._deathQueue:enqueue({ _unitId = unitId })
	end

	iads._deathQueue:enqueue({ _unitId = 9011 })
	lu.assertNotNil(next(iads._deathOverflowSet))
	lu.assertEquals(iads:_processDeathOverflow(1), 1)
	lu.assertNil(iads:getAssetIndex():batteries():get(battery.BatteryId))
end

function TestIadsNetwork:test_death_drop_metric_counts_only_terminal_overflow()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeWorldEvents()
	local deathDrops = 0
	Medusa.Observability.MetricsService.inc = function(name, _, labels)
		if name == "medusa_world_events_dropped_total" and labels.event == "DEATH" then
			deathDrops = deathDrops + 1
		end
	end
	for unitId = 1, Medusa.Constants.WorldEventQueue.DEATH_CAPACITY do
		iads._deathQueue:enqueue({ _unitId = unitId })
	end

	local recovered = { _unitId = 8001, _unitName = "recovered" }
	iads._deathQueue:enqueue(recovered)
	iads._deathQueue:enqueue(recovered)
	for unitId = 1, Medusa.Constants.WorldEventQueue.DEATH_OVERFLOW_CAPACITY - 1 do
		iads._deathQueue:enqueue({ _unitId = 9000 + unitId })
	end

	lu.assertEquals(deathDrops, 0)
	lu.assertEquals(iads._deathOverflowQueue:size(), Medusa.Constants.WorldEventQueue.DEATH_OVERFLOW_CAPACITY)
	iads._deathQueue:enqueue({ _unitId = 99999 })
	lu.assertEquals(deathDrops, 1)
end

function TestIadsNetwork:test_death_overflow_terminal_drop_keeps_both_queues_bounded()
	local iads = makeIads()
	iads:initialize()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 906,
		GroupName = "iads.alpha.large-sam",
		Role = Medusa.Constants.BatteryRole.LR_SAM,
	})
	battery.Units = {}
	for index = 1, Medusa.Constants.WorldEventQueue.DEATH_OVERFLOW_CAPACITY + 1 do
		battery.Units[index] = Medusa.Entities.Battery.newUnit({
			UnitId = 906000 + index,
			UnitName = "large-sam-unit-" .. tostring(index),
			Roles = { Medusa.Constants.BatteryUnitRole.LAUNCHER },
		})
	end
	iads:getAssetIndex():batteries():add(battery)

	for index = 1, Medusa.Constants.WorldEventQueue.DEATH_OVERFLOW_CAPACITY do
		lu.assertTrue(iads:_queueDeathOverflow(battery.Units[index].UnitId))
	end
	lu.assertFalse(iads:_queueDeathOverflow(battery.Units[#battery.Units].UnitId))

	lu.assertEquals(iads._deathOverflowQueue:size(), Medusa.Constants.WorldEventQueue.DEATH_OVERFLOW_CAPACITY)
	for _ = 1, Medusa.Constants.WorldEventQueue.DEATH_OVERFLOW_CAPACITY / 2 do
		iads:_processDeathOverflow(Medusa.Constants.WorldEventQueue.DEATH_OVERFLOW_RECOVERY_BUDGET)
	end

	lu.assertEquals(iads._deathOverflowQueue:size(), 0)
	lu.assertIs(iads:getAssetIndex():batteries():get(battery.BatteryId), battery)
	lu.assertEquals(#battery.Units, 1)
	lu.assertEquals(battery.Units[1].UnitId, 906000 + Medusa.Constants.WorldEventQueue.DEATH_OVERFLOW_CAPACITY + 1)
end

function TestIadsNetwork:test_repeated_death_overflow_identity_is_coalesced_without_repository_scans()
	local iads = makeIads()
	iads:initialize()
	local node = Medusa.Entities.C2Node.new({
		NetworkId = "T",
		GroupId = 903,
		NodeName = "iads.alpha.hq",
		Providers = { { UnitId = 9031, UnitName = "hq-provider", Available = true } },
	})
	iads:getAssetIndex():c2Nodes():add(node)

	lu.assertTrue(iads:_queueDeathOverflow(9031))
	lu.assertEquals(iads:_processDeathOverflow(1), 1)
	lu.assertFalse(node.Providers[1].Available)

	lu.assertTrue(iads:_queueDeathOverflow(9031))
	for _ = 1, 99 do
		lu.assertTrue(iads:_queueDeathOverflow(9031))
	end
	lu.assertEquals(iads._deathOverflowQueue:size(), 1)
end

function TestIadsNetwork:test_shot_overflow_blocks_engagement_until_ammo_reconciliation()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeWorldEvents()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 902,
		GroupName = "iads.alpha.sa6",
		TotalAmmoStatus = 1,
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = 9021,
			UnitName = "launcher",
			Roles = { Medusa.Constants.BatteryUnitRole.LAUNCHER },
			AmmoCount = 1,
			AmmoTypes = { { Count = 1, RangeMax = 10000 } },
		}),
	}
	iads:getAssetIndex():batteries():add(battery)
	for unitId = 1, Medusa.Constants.WorldEventQueue.SHOT_CAPACITY do
		iads._shotQueue:enqueue({ _unitId = unitId })
	end

	iads._shotQueue:enqueue({ _unitId = 9021, _weaponTypeName = "missile" })
	lu.assertFalse(Medusa.Entities.Battery.hasKnownAmmo(battery))
	GetUnitAmmo = function()
		return {
			{
				count = 2,
				desc = { missileCategory = 1, typeName = "missile", rangeMaxAltMax = 10000 },
			},
		}
	end

	iads:_processAmmoReconciliation(1, 0)
	lu.assertTrue(Medusa.Entities.Battery.hasKnownAmmo(battery))
	lu.assertEquals(battery.TotalAmmoStatus, 2)
end

function TestIadsNetwork:test_shot_overflow_retains_flight_guard_after_assignment_release()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeWorldEvents()
	local now = 100
	GetTime = function()
		return now
	end
	local battery = Medusa.Entities.Battery.new({
		BatteryId = "shot-overflow-battery",
		NetworkId = "T",
		GroupId = 903,
		GroupName = "iads.alpha.sa6.flight-guard",
		Role = Medusa.Constants.BatteryRole.LR_SAM,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		OperationalStatus = Medusa.Constants.BatteryOperationalStatus.ACTIVE,
		CoordinationState = Medusa.Constants.CoordinationState.DEGRADED,
		PartitionKey = "partition-a",
		EngagementRangeMax = 8000,
		TotalAmmoStatus = 1,
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = 9031,
			UnitName = "launcher-9031",
			Roles = { Medusa.Constants.BatteryUnitRole.LAUNCHER },
			AmmoCount = 1,
			AmmoTypes = { { Count = 1, WeaponTypeName = "missile", RangeMax = 8000 } },
		}),
	}
	local track = Medusa.Entities.Track.new({
		TrackId = "shot-overflow-track",
		NetworkId = "T",
		PartitionKey = "partition-a",
		Position = { x = 0, y = 0, z = 0 },
		Velocity = { x = 0, y = 0, z = 0 },
	})
	local trackStore = iads._trackManager:getStore()
	iads:getAssetIndex():batteries():add(battery)
	trackStore:add(track)
	Medusa.Entities.Battery.assignTrack(battery, track, now, trackStore)
	for unitId = 1, Medusa.Constants.WorldEventQueue.SHOT_CAPACITY do
		iads._shotQueue:enqueue({ _unitId = unitId })
	end

	lu.assertFalse(iads._shotQueue:enqueue({
		_unitId = 9031,
		_unitName = "launcher-9031",
		_weaponTypeName = "missile",
	}))
	lu.assertEquals(battery.MissileInFlightUntil, 110)
	Medusa.Entities.Battery.releaseTrack(battery, trackStore)
	iads._doctrine.DegradedMode = Medusa.Constants.NetworkDegradationPolicy.GO_DARK
	iads._doctrine.HoldDownSec = 0
	local coldRequests = 0
	GetGroupController = function()
		return {}
	end
	GetGroup = function()
		return {}
	end
	ControllerSetROE = function()
		coldRequests = coldRequests + 1
		return true
	end
	ControllerSetAlarmState = function()
		return true
	end
	EnableGroupEmissions = function()
		return true
	end
	local ctx = {
		batteryStore = iads:getAssetIndex():batteries(),
		sensorStore = iads:getAssetIndex():sensors(),
		doctrine = iads._doctrine,
		now = now,
	}

	Medusa.Services.EmconService.applyPolicy(ctx)
	lu.assertEquals(coldRequests, 0)
	lu.assertEquals(battery.ActivationState, Medusa.Constants.ActivationState.STATE_HOT)
	now = battery.MissileInFlightUntil
	ctx.now = now
	Medusa.Services.EmconService.applyPolicy(ctx)
	lu.assertEquals(coldRequests, 1)
	lu.assertEquals(battery.ActivationState, Medusa.Constants.ActivationState.STATE_COLD)
end

function TestIadsNetwork:test_shot_admission_retains_flight_guard_before_firing_unit_death()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeWorldEvents()
	GetTime = function()
		return 100
	end
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 904,
		GroupName = "iads.alpha.sa6.death-order",
		Role = Medusa.Constants.BatteryRole.LR_SAM,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		EngagementRangeMax = 8000,
		TotalAmmoStatus = 2,
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = 9041,
			UnitName = "launcher-9041",
			Roles = { Medusa.Constants.BatteryUnitRole.LAUNCHER },
			AmmoCount = 1,
			AmmoTypes = { { Count = 1, WeaponTypeName = "missile", RangeMax = 8000 } },
		}),
		Medusa.Entities.Battery.newUnit({
			UnitId = 9042,
			UnitName = "launcher-9042",
			Roles = { Medusa.Constants.BatteryUnitRole.LAUNCHER },
			AmmoCount = 1,
			AmmoTypes = { { Count = 1, WeaponTypeName = "missile", RangeMax = 8000 } },
		}),
	}
	iads:getAssetIndex():batteries():add(battery)

	lu.assertTrue(iads._shotQueue:enqueue({
		_unitId = 9041,
		_unitName = "launcher-9041",
		_weaponTypeName = "missile",
	}))
	lu.assertEquals(battery.MissileInFlightUntil, 110)
	lu.assertTrue(iads._deathQueue:enqueue({ _unitId = 9041, _unitName = "launcher-9041" }))
	iads:_processDeathEvents(1)
	iads:_processShotEvents(1)

	lu.assertEquals(#battery.Units, 1)
	lu.assertEquals(battery.Units[1].UnitId, 9042)
	lu.assertEquals(battery.MissileInFlightUntil, 110)
end

function TestIadsNetwork:test_shot_admission_never_shortens_an_existing_flight_guard()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeWorldEvents()
	GetTime = function()
		return 100
	end
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 907,
		GroupName = "iads.alpha.sa6.existing-flight",
		Role = Medusa.Constants.BatteryRole.LR_SAM,
		EngagementRangeMax = 8000,
	})
	battery.MissileInFlightUntil = 120
	battery.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = 9071,
			UnitName = "launcher-9071",
			Roles = { Medusa.Constants.BatteryUnitRole.LAUNCHER },
			AmmoCount = 1,
			AmmoTypes = { { Count = 1, WeaponTypeName = "missile", RangeMax = 8000 } },
		}),
	}
	iads:getAssetIndex():batteries():add(battery)

	lu.assertTrue(iads._shotQueue:enqueue({
		_unitId = 9071,
		_unitName = "launcher-9071",
		_weaponTypeName = "missile",
	}))
	lu.assertEquals(battery.MissileInFlightUntil, 120)
end

function TestIadsNetwork:test_shot_admission_rejects_stale_and_non_missile_flight_facts()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeWorldEvents()
	local sam = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 905,
		GroupName = "iads.alpha.sa6.stale-shot",
		Role = Medusa.Constants.BatteryRole.LR_SAM,
		EngagementRangeMax = 8000,
	})
	sam.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = 9051,
			UnitName = "launcher-9051",
			Roles = { Medusa.Constants.BatteryUnitRole.LAUNCHER },
			AmmoCount = 1,
			AmmoTypes = { { Count = 1, WeaponTypeName = "missile", RangeMax = 8000 } },
		}),
	}
	local manpad = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 906,
		GroupName = "iads.alpha.manpad.non-missile",
		Role = Medusa.Constants.BatteryRole.MANPAD,
		EngagementRangeMax = 4000,
		Manpad = {
			SleepWakeState = Medusa.Constants.Manpad.SleepWakeState.ASLEEP,
			WakeReason = Medusa.Constants.Manpad.WakeReason.NONE,
			AlertCycleCount = 0,
			AudioCueRangeM = Medusa.Constants.Manpad.AUDIO_RANGE_MAX_M,
			UnitHeadings = {},
			UnitHeadingCount = 0,
		},
	})
	manpad.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = 9061,
			UnitName = "manpad-9061",
			Roles = { Medusa.Constants.BatteryUnitRole.MANPAD },
			AmmoCount = 1,
			AmmoTypes = { { Count = 1, WeaponTypeName = "missile", RangeMax = 4000 } },
		}),
	}
	iads:getAssetIndex():batteries():add(sam)
	iads:getAssetIndex():manpads():add(manpad)

	lu.assertTrue(iads._shotQueue:enqueue({
		_unitId = 9051,
		_unitName = "stale-launcher-name",
		_weaponTypeName = "missile",
	}))
	lu.assertTrue(iads._shotQueue:enqueue({
		_unitId = 9061,
		_unitName = "manpad-9061",
		_weaponTypeName = "rifle",
	}))

	lu.assertNil(sam.MissileInFlightUntil)
	lu.assertNil(manpad.MissileInFlightUntil)
end

function TestIadsNetwork:test_unknown_manpad_weapon_retains_flight_and_reconciles_ammunition()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeWorldEvents()
	GetTime = function()
		return 100
	end
	local manpad = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 908,
		GroupName = "iads.alpha.manpad.unknown-weapon",
		Role = Medusa.Constants.BatteryRole.MANPAD,
		ActivationState = Medusa.Constants.ActivationState.STATE_HOT,
		EngagementRangeMax = 4000,
		TotalAmmoStatus = 1,
		Manpad = {
			SleepWakeState = Medusa.Constants.Manpad.SleepWakeState.HOT,
			WakeReason = Medusa.Constants.Manpad.WakeReason.IADS,
			AlertCycleCount = 0,
			AudioCueRangeM = Medusa.Constants.Manpad.AUDIO_RANGE_MAX_M,
			UnitHeadings = {},
			UnitHeadingCount = 0,
		},
	})
	manpad.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = 9081,
			UnitName = "manpad-9081",
			Roles = { Medusa.Constants.BatteryUnitRole.MANPAD },
			AmmoCount = 1,
			AmmoTypes = { { Count = 1, WeaponTypeName = "missile", RangeMax = 4000 } },
		}),
	}
	iads:getAssetIndex():manpads():add(manpad)

	lu.assertTrue(iads._shotQueue:enqueue({
		_unitId = 9081,
		_unitName = "manpad-9081",
	}))
	lu.assertEquals(manpad.MissileInFlightUntil, 105)
	lu.assertFalse(Medusa.Entities.Battery.hasKnownAmmo(manpad))
	lu.assertFalse(Medusa.Entities.Battery.canDeactivate(manpad, 100))

	iads:_processShotEvents(1)
	lu.assertEquals(manpad.Units[1].AmmoCount, 1)
	lu.assertEquals(manpad.TotalAmmoStatus, 1)
	lu.assertEquals(manpad.ShotsFired, 1)
	lu.assertEquals(manpad.LastShotTime, 100)
	lu.assertTrue(iads._ammoReconcileSet[manpad.BatteryId])
end

function TestIadsNetwork:test_unknown_networked_sam_weapon_does_not_decrement_ammunition()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeWorldEvents()
	GetTime = function()
		return 100
	end
	local sam = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 909,
		GroupName = "iads.alpha.sam.unknown-weapon",
		Role = Medusa.Constants.BatteryRole.LR_SAM,
		OperationalStatus = Medusa.Constants.BatteryOperationalStatus.ACTIVE,
		EngagementRangeMax = 8000,
		TotalAmmoStatus = 2,
	})
	sam.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = 9091,
			UnitName = "sam-9091",
			Roles = { Medusa.Constants.BatteryUnitRole.LAUNCHER },
			AmmoCount = 2,
			AmmoTypes = { { Count = 2, WeaponTypeName = "missile", RangeMax = 8000 } },
		}),
	}
	iads:getAssetIndex():batteries():add(sam)

	lu.assertTrue(iads._shotQueue:enqueue({
		_unitId = 9091,
		_unitName = "sam-9091",
	}))
	lu.assertFalse(Medusa.Entities.Battery.hasKnownAmmo(sam))

	iads:_processShotEvents(1)
	lu.assertEquals(sam.Units[1].AmmoCount, 2)
	lu.assertEquals(sam.Units[1].AmmoTypes[1].Count, 2)
	lu.assertEquals(sam.TotalAmmoStatus, 2)
	lu.assertEquals(sam.ShotsFired, 1)
	lu.assertEquals(sam.LastShotTime, 100)
	lu.assertTrue(iads._ammoReconcileSet[sam.BatteryId])
end

function TestIadsNetwork:test_world_event_name_failure_keeps_incarnation_guard()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeWorldEvents()
	local store = iads:getAssetIndex():batteries()
	local function battery(id, groupId, groupName)
		local value = Medusa.Entities.Battery.new({
			BatteryId = id,
			NetworkId = "T",
			GroupId = groupId,
			GroupName = groupName,
			Role = Medusa.Constants.BatteryRole.LR_SAM,
			OperationalStatus = Medusa.Constants.BatteryOperationalStatus.ACTIVE,
		})
		value.Units = {
			Medusa.Entities.Battery.newUnit({
				UnitId = 9091,
				UnitName = groupName .. "-unit",
				Roles = { Medusa.Constants.BatteryUnitRole.LAUNCHER },
			}),
		}
		return value
	end
	local original = battery("old-battery", 909, "iads.alpha.old")
	store:add(original)
	local initiator = {
		getCoalition = function()
			return COAL_RED
		end,
		getID = function()
			return 9091
		end,
		getName = function()
			error("injected name lookup failure")
		end,
	}

	HarnessWorldEventBus:publish({ id = world.event.S_EVENT_DEAD, initiator = initiator })
	lu.assertEquals(iads._deathQueue:size(), 1)
	store:remove(original.BatteryId)
	local replacement = battery("new-battery", 910, "iads.alpha.new")
	store:add(replacement)

	iads:_processDeathEvents(1)
	lu.assertEquals(store:get(replacement.BatteryId), replacement)

	HarnessWorldEventBus:publish({ id = world.event.S_EVENT_DEAD, initiator = initiator })
	iads:_processDeathEvents(1)
	lu.assertNil(store:get(replacement.BatteryId))
end

function TestIadsNetwork:test_ammo_reconciliation_retries_when_an_ammo_unit_has_no_name()
	local iads = makeIads()
	iads:initialize()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 904,
		GroupName = "iads.alpha.unnamed-launcher",
		TotalAmmoStatus = 1,
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = 9041,
			Roles = { Medusa.Constants.BatteryUnitRole.LAUNCHER },
			AmmoCount = 1,
		}),
	}
	iads:getAssetIndex():batteries():add(battery)
	iads:_markAmmoUnknown(9041)

	lu.assertEquals(iads:_processAmmoReconciliation(1, 0), 1)

	lu.assertFalse(Medusa.Entities.Battery.hasKnownAmmo(battery))
	lu.assertEquals(battery.AmmoReconcileNextAt, Medusa.Constants.WorldEventQueue.AMMO_RECONCILIATION_RETRY_SEC)
end

function TestIadsNetwork:test_manpad_zero_ammo_reconciliation_cancels_a_pending_wake()
	local iads = makeIads()
	iads:initialize()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 907,
		GroupName = "iads.alpha.manpad",
		Role = Medusa.Constants.BatteryRole.MANPAD,
		TotalAmmoStatus = 1,
		AmmoKnown = false,
		Manpad = {
			SleepWakeState = Medusa.Constants.Manpad.SleepWakeState.ALERTING,
			WakeReason = Medusa.Constants.Manpad.WakeReason.IADS,
			WakeTimerId = 77,
			AlertCycleCount = 0,
			AudioCueRangeM = 3000,
			UnitHeadings = {},
			UnitHeadingCount = 0,
		},
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = 9071,
			UnitName = "manpad-soldier",
			Roles = { Medusa.Constants.BatteryUnitRole.MANPAD },
			AmmoCount = 1,
		}),
	}
	iads:getAssetIndex():manpads():add(battery)
	GetUnitAmmo = function()
		return {}
	end
	iads:_markAmmoUnknown(9071)

	iads:_processAmmoReconciliation(1, 10)

	lu.assertTrue(battery.AmmoKnown)
	lu.assertEquals(battery.TotalAmmoStatus, 0)
	lu.assertIsNil(battery.Manpad.WakeTimerId)
	lu.assertEquals(battery.Manpad.SleepWakeState, Medusa.Constants.Manpad.SleepWakeState.ASLEEP)
	lu.assertEquals(battery.Manpad.WakeReason, Medusa.Constants.Manpad.WakeReason.NONE)
end

function TestIadsNetwork:test_aaa_zero_ammo_reconciliation_releasesActiveBarrage()
	local C = Medusa.Constants
	local iads = makeIads()
	iads:initialize()
	local battery = Medusa.Entities.Battery.new({
		BatteryId = "aaa-reconcile",
		NetworkId = "T",
		GroupId = 908,
		GroupName = "iads.alpha.aaa-reconcile",
		Role = C.BatteryRole.AAA,
		ActivationState = C.ActivationState.STATE_COLD,
		TotalAmmoStatus = 1,
		AmmoKnown = false,
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = 9081,
			UnitName = "aaa-gunner",
			Roles = { C.BatteryUnitRole.AAA },
			AmmoCount = 1,
		}),
	}
	battery.Aaa.ResponseState = C.Aaa.ResponseState.BARRAGE_FIRE
	battery.Aaa.LastFirePoint = { x = 1000, y = 100, z = 0 }
	iads:getAssetIndex():batteries():add(battery)
	iads._aaaBarrageState.participants[battery.BatteryId] = battery
	GetUnitAmmo = function()
		return {}
	end
	GetGroupController = function()
		return {}
	end
	PopControllerTask = function()
		return true
	end
	iads:_markAmmoUnknown(9081)

	iads:_processAmmoReconciliation(1, 10)

	lu.assertEquals(battery.OperationalStatus, C.BatteryOperationalStatus.INOPERATIVE)
	lu.assertEquals(battery.Aaa.ResponseState, C.Aaa.ResponseState.IDLE)
	lu.assertNil(battery.Aaa.LastFirePoint)
	lu.assertNil(iads._aaaBarrageState.participants[battery.BatteryId])
end

function TestIadsNetwork:test_repeated_shot_overflow_restarts_an_in_progress_battery_scan()
	local iads = makeIads()
	iads:initialize()
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 905,
		GroupName = "iads.alpha.two-launchers",
		TotalAmmoStatus = 2,
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = 9051,
			UnitName = "launcher-1",
			Roles = { Medusa.Constants.BatteryUnitRole.LAUNCHER },
			AmmoCount = 1,
		}),
		Medusa.Entities.Battery.newUnit({
			UnitId = 9052,
			UnitName = "launcher-2",
			Roles = { Medusa.Constants.BatteryUnitRole.LAUNCHER },
			AmmoCount = 1,
		}),
	}
	iads:getAssetIndex():batteries():add(battery)
	local reads = { ["launcher-1"] = 0, ["launcher-2"] = 0 }
	GetUnitAmmo = function(unitName)
		reads[unitName] = reads[unitName] + 1
		return {
			{
				count = reads[unitName],
				desc = { missileCategory = 1, typeName = "missile", rangeMaxAltMax = 10000 },
			},
		}
	end

	iads:_markAmmoUnknown(9051)
	iads:_processAmmoReconciliation(1, 0)
	iads:_markAmmoUnknown(9051)
	iads:_processAmmoReconciliation(1, 0)

	lu.assertEquals(reads["launcher-1"], 2)
	lu.assertEquals(reads["launcher-2"], 0)
	lu.assertFalse(Medusa.Entities.Battery.hasKnownAmmo(battery))

	iads:_processAmmoReconciliation(1, 0)
	lu.assertTrue(Medusa.Entities.Battery.hasKnownAmmo(battery))
end

function TestIadsNetwork:test_kill_overflow_invalidates_adaptive_window()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeWorldEvents()
	iads:_recordShotOutcome(0)
	lu.assertEquals(iads._rollingPkCount, 1)
	for unitId = 1, Medusa.Constants.WorldEventQueue.KILL_CAPACITY do
		iads._killQueue:enqueue({ _unitId = unitId })
	end

	iads._killQueue:enqueue({ _unitId = 9999 })

	lu.assertEquals(iads._rollingPkCount, 0)
	lu.assertEquals(iads._effectivePkFloor, iads._doctrine.PkFloor)
end

function TestIadsNetwork:test_command_provider_loss_recomputes_partition_coverage_and_battery_mode_as_one_chain()
	local iads = makeIads()
	iads:initialize()
	local messages = {}
	env.info = function(message)
		messages[#messages + 1] = message
	end
	Medusa.Logger:setLevel(Medusa.Constants.LogLevel.INFO)
	local hierarchy = iads:getHierarchy()
	hierarchy:upsertGroup({
		groupId = 1001,
		groupName = "west-ewr",
		parsed = { echelonPath = { "west" }, roles = {}, isHQ = false },
	})
	hierarchy:upsertGroup({
		groupId = 1002,
		groupName = "east-hq",
		parsed = { echelonPath = { "east" }, roles = {}, isHQ = true },
	})
	hierarchy:upsertGroup({
		groupId = 1003,
		groupName = "east-sam",
		parsed = { echelonPath = { "east" }, roles = {}, isHQ = false },
	})
	local sensor = Medusa.Entities.SensorUnit.new({
		NetworkId = "T",
		UnitId = 10010,
		UnitName = "west-ewr",
		GroupId = 1001,
		GroupName = "west-ewr",
		SensorType = Medusa.Constants.SensorType.EWR,
		Position = { x = 0, y = 0, z = 0 },
		DetectionRangeMax = 1000,
	})
	local battery = Medusa.Entities.Battery.new({
		NetworkId = "T",
		GroupId = 1003,
		GroupName = "east-sam",
		Role = Medusa.Constants.BatteryRole.LR_SAM,
		ActivationState = Medusa.Constants.ActivationState.STATE_COLD,
		OperationalStatus = Medusa.Constants.BatteryOperationalStatus.ACTIVE,
		Position = { x = 100, y = 0, z = 0 },
		DetectionRangeMax = 100,
		EngagementRangeMax = 100,
		TotalAmmoStatus = 4,
	})
	battery.Units = {
		Medusa.Entities.Battery.newUnit({
			UnitId = 10030,
			UnitName = "east-sam-radar",
			Roles = { Medusa.Constants.BatteryUnitRole.SEARCH_RADAR },
		}),
	}
	local command = Medusa.Entities.C2Node.new({
		NetworkId = "T",
		GroupId = 1002,
		NodeName = "east-hq",
		Providers = { { UnitId = 10020, UnitName = "east-hq", Available = true } },
	})
	iads:getAssetIndex():sensors():add(sensor)
	iads:getAssetIndex():batteries():add(battery)
	iads:getAssetIndex():c2Nodes():add(command)
	hierarchy:freezeC2Topology()
	iads._nextPartitionRefreshAt = 0
	for _ = 1, 5 do
		iads:_runPartitionStep(0)
	end
	local connectedKey = battery.PartitionKey
	lu.assertEquals(battery.CoordinationState, Medusa.Constants.CoordinationState.COORDINATED)
	lu.assertStrContains(table.concat(messages, "\n"), "topology=[<root>+east:sustained]")

	iads:_handleUnitDeath(10020)
	for _ = 1, 5 do
		iads:_runPartitionStep(15)
	end

	local logOutput = table.concat(messages, "\n")
	lu.assertStrContains(logOutput, "command provider unavailable: east-hq (unitId=10020)")
	lu.assertStrContains(logOutput, "components=2, sustained=2, coordinated=1, degraded=0")
	lu.assertStrContains(logOutput, "topology=[<root>:sustained | east:sustained]")
	lu.assertFalse(command.Providers[1].Available)
	lu.assertIsNil(command.Providers[1].UnitId)
	lu.assertNil(iads:getAssetIndex():unitIndex():getRegisteredOwner(10020, Medusa.Constants.UnitOwnerKind.COMMAND_PROVIDER))
	lu.assertNotNil(battery.PartitionKey)
	lu.assertNotEquals(battery.PartitionKey, connectedKey)
	lu.assertTrue(battery.IsActingAsEWR)
	lu.assertEquals(battery.CoordinationState, Medusa.Constants.CoordinationState.COORDINATED)
	GetGroupController = function()
		return {}
	end
	SetControllerOnOff = function()
		return true
	end
	ControllerSetROE = function()
		return true
	end
	ControllerSetAlarmState = function()
		return true
	end
	EnableGroupEmissions = function()
		return true
	end
	iads._doctrine.DegradedMode = Medusa.Constants.NetworkDegradationPolicy.REVERT_TO_AUTONOMOUS
	iads._doctrine.EMCON = iads._doctrine.EMCON or {}
	iads._doctrine.EMCON[Medusa.Constants.BatteryRole.LR_SAM] = Medusa.Constants.EmissionControlPolicy.MINIMIZE
	Medusa.Services.EmconService.applyPolicy({
		batteryStore = iads:getAssetIndex():batteries(),
		sensorStore = iads:getAssetIndex():sensors(),
		doctrine = iads._doctrine,
		now = 15,
	})
	lu.assertEquals(battery.ActivationState, Medusa.Constants.ActivationState.STATE_WARM)

	lu.assertFalse(command.Providers[1].Available)
	lu.assertEquals(#command.Providers, 1)
	iads:getAssetIndex():c2Nodes():markProviderAvailable(command.Providers[1], 10021)
	lu.assertTrue(command.Providers[1].Available)
	lu.assertEquals(command.Providers[1].UnitId, 10021)
	local disconnectedKey = battery.PartitionKey
	for _ = 1, 5 do
		iads:_runPartitionStep(30)
	end
	lu.assertFalse(battery.IsActingAsEWR)
	lu.assertEquals(battery.CoordinationState, Medusa.Constants.CoordinationState.COORDINATED)
	lu.assertNotEquals(battery.PartitionKey, connectedKey)
	lu.assertNotEquals(battery.PartitionKey, disconnectedKey)
end

TestIadsSuppressionEvents = {}

function TestIadsSuppressionEvents:setUp()
	self.originalBus = HarnessWorldEventBus
	self.originalGetTime = GetTime
	self.originalInfo = env.info
	self.originalLogLevel = Medusa.Logger:getLevel()
	self.messages = {}
	env.info = function(message)
		self.messages[#self.messages + 1] = message
	end
	Medusa.Logger:setLevel(Medusa.Constants.LogLevel.DEBUG)
	self.now = 1000
	GetTime = function()
		return self.now
	end
	HarnessWorldEventBus = CreateHarnessWorldEventBus()
end

function TestIadsSuppressionEvents:tearDown()
	HarnessWorldEventBus:dispose()
	HarnessWorldEventBus = self.originalBus
	GetTime = self.originalGetTime
	env.info = self.originalInfo
	Medusa.Logger:setLevel(self.originalLogLevel)
end

local function hitEvent(unitId, coalitionId)
	return {
		initiator = {},
		target = {
			getCoalition = function()
				return coalitionId or COAL_RED
			end,
			getID = function()
				return unitId
			end,
		},
	}
end

function TestIadsSuppressionEvents:test_hit_boundary_rejects_missing_or_invalid_fields()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeSuppressionEvents()

	HarnessWorldEventBus:publish({ id = world.event.S_EVENT_HIT })
	HarnessWorldEventBus:publish({ id = world.event.S_EVENT_HIT, initiator = {} })
	HarnessWorldEventBus:publish(hitEvent(10, coalition.side.BLUE))
	HarnessWorldEventBus:publish({
		id = world.event.S_EVENT_HIT,
		initiator = {},
		target = {
			getCoalition = function()
				return COAL_RED
			end,
		},
	})

	lu.assertTrue(iads._hitQueue:isEmpty())
end

function TestIadsSuppressionEvents:test_hit_boundary_translates_to_bounded_unit_record()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeSuppressionEvents()
	local capacity = Medusa.Constants.CrewSuppression.HIT_EVENT_QUEUE_CAPACITY

	for unitId = 1, capacity + 1 do
		local event = hitEvent(unitId)
		event.id = world.event.S_EVENT_HIT
		HarnessWorldEventBus:publish(event)
	end

	lu.assertEquals(iads._hitQueue:size(), capacity)
	lu.assertEquals(iads._hitQueue:pop().TargetUnitId, 2)
end

function TestIadsSuppressionEvents:test_stale_hit_does_not_damage_replacement_unit_with_reused_id()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeSuppressionEvents()
	local repository = iads:getAssetIndex():batteryRepository()
	local function aaa(batteryId, groupId, groupName, unitName)
		local value = Medusa.Entities.Battery.new({
			BatteryId = batteryId,
			NetworkId = "T",
			GroupId = groupId,
			GroupName = groupName,
			Role = Medusa.Constants.BatteryRole.AAA,
			OperationalStatus = Medusa.Constants.BatteryOperationalStatus.ACTIVE,
			GroupDiameterM = 1,
		})
		value.Units = {
			Medusa.Entities.Battery.newUnit({
				UnitId = 20,
				UnitName = unitName,
				Roles = { Medusa.Constants.BatteryUnitRole.AAA },
				LastKnownLife = 100,
				InitialLife = 100,
			}),
		}
		return value
	end
	local original = aaa("old", 20, "old-group", "old-unit")
	repository:add(original)
	local event = hitEvent(20)
	event.id = world.event.S_EVENT_HIT
	HarnessWorldEventBus:publish(event)
	repository:remove(original.BatteryId)
	local replacement = aaa("replacement", 21, "replacement-group", "replacement-unit")
	repository:add(replacement)
	local originalGetUnitHealth = GetUnitHealth
	local healthReads = 0
	GetUnitHealth = function()
		healthReads = healthReads + 1
		return { IsAlive = true, CurrentLife = 50, InitialLife = 100 }
	end

	iads:_processHitEvents(1)

	GetUnitHealth = originalGetUnitHealth
	lu.assertEquals(healthReads, 0)
	lu.assertEquals(replacement.Units[1].LastKnownLife, 100)
	lu.assertFalse(Medusa.Entities.Battery.isCrewSuppressed(replacement))
end

function TestIadsSuppressionEvents:test_debug_trace_reports_hit_and_death_processing_paths()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeWorldEvents()
	iads:_subscribeSuppressionEvents()
	self.messages = {}

	local event = hitEvent(10)
	event.id = world.event.S_EVENT_HIT
	HarnessWorldEventBus:publish(event)
	iads:_processHitEvents(1)
	iads._deathQueue:enqueue({ _unitId = 10 })
	iads:_processDeathEvents(1)

	local output = table.concat(self.messages, "\n")
	lu.assertStrContains(output, "crew suppression HIT queued: targetUnitId=10")
	lu.assertStrContains(output, "processing crew suppression HIT: targetUnitId=10")
	lu.assertStrContains(output, "damage evaluation rejected: unitId=10 is not the captured owner")
	lu.assertStrContains(output, "crew suppression HIT processed: targetUnitId=10 applied=false")
	lu.assertStrContains(output, "processing death event: unitId=10")
	lu.assertStrContains(output, "death event ignored: unitId=10 is not managed")
end

function TestIadsSuppressionEvents:test_hit_processing_obeys_budget_and_expiry()
	local iads = makeIads()
	iads:initialize()
	iads:_subscribeSuppressionEvents()

	for unitId = 1, 3 do
		local event = hitEvent(unitId)
		event.id = world.event.S_EVENT_HIT
		HarnessWorldEventBus:publish(event)
	end
	lu.assertEquals(iads:_processHitEvents(2), 2)
	lu.assertEquals(iads._hitQueue:size(), 1)

	self.now = self.now + Medusa.Constants.CrewSuppression.HIT_EVENT_MAX_AGE_SEC + 1
	lu.assertEquals(iads:_processHitEvents(2), 1)
	lu.assertTrue(iads._hitQueue:isEmpty())
end

function TestIadsSuppressionEvents:test_stop_and_restart_replace_hit_subscription()
	local iads = makeIads()
	lu.assertTrue(iads:start())
	lu.assertEquals(#HarnessWorldEventBus._subscribers[world.event.S_EVENT_HIT], 1)
	for unitId = 1, 2 do
		local event = hitEvent(unitId)
		event.id = world.event.S_EVENT_HIT
		HarnessWorldEventBus:publish(event)
	end
	lu.assertEquals(iads:_processHitEvents(1), 1)
	lu.assertStrContains(Medusa.Observability.MetricsService.serialize(), 'medusa_crew_suppression_event_queue_depth{network="T"} 1')

	iads:stop()
	lu.assertIsNil(HarnessWorldEventBus._subscribers[world.event.S_EVENT_HIT])
	lu.assertTrue(iads._hitQueue:isEmpty())

	iads:start()
	iads:start()
	lu.assertEquals(#HarnessWorldEventBus._subscribers[world.event.S_EVENT_HIT], 1)
	iads:stop()
end

function TestIadsSuppressionEvents:test_disabled_doctrine_does_not_subscribe_to_hit_events()
	local iads = Medusa.Core.IadsNetwork:new({
		id = "T",
		coalitionId = COAL_RED,
		prefix = "iads",
		doctrine = { CrewSuppression = { Enabled = false } },
	})

	iads:initialize()

	lu.assertIsNil(HarnessWorldEventBus._subscribers[world.event.S_EVENT_HIT])
end
