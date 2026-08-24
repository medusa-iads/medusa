local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Config")
require("core.IadsNetwork")
require("services.BlackBoxService")
require("observability.MetricsSnapshot")
require("services.stores.BlackBoxWeaponStore")
require("services.stores.MissionUnitSkillIndex")

TestEntrypoint = {}

function TestEntrypoint:setUp()
	self.originalConfigInitialize = Medusa.Config.initialize
	self.originalGetNetworks = Medusa.Config.getNetworks
	self.originalConfigGet = Medusa.Config.get
	self.originalGetLogLevel = Medusa.Config.getLogLevel
	self.originalNetworkNew = Medusa.Core.IadsNetwork.new
	self.originalBarrageStateNew = Medusa.Services.AaaService.newBarrageState
	self.originalWeaponStoreNew = Medusa.Services.BlackBoxWeaponStore.new
	self.originalSkillIndexNew = Medusa.Services.MissionUnitSkillIndex.new
	self.originalBlackBoxStart = Medusa.Services.BlackBoxService.start
	self.originalInstallSnapshot = Medusa.Observability.MetricsSnapshot.installSnapshot
	self.originalSerialize = Medusa.Observability.MetricsService.serialize
	self.originalIadsById = Medusa.Core.IadsById
	self.originalApi = Medusa.API
	self.originalScheduleOnce = ScheduleOnce
	self.originalIoOpen = io.open
	self.originalOsRename = os.rename
	self.originalOsRemove = os.remove
	self.originalLfs = lfs
	self.originalAddWorldEventHandler = AddWorldEventHandler
	self.originalRemoveWorldEventHandler = RemoveWorldEventHandler
	self.originalGetWorldEventTypes = GetWorldEventTypes
	self.originalRawWorldEventTraceHandler = Medusa.Core.RawWorldEventTraceHandler
	self.originalEnvInfo = env.info
	self.originalLogLevel = Medusa.Logger:getLevel()
end

function TestEntrypoint:tearDown()
	Medusa.Config.initialize = self.originalConfigInitialize
	Medusa.Config.getNetworks = self.originalGetNetworks
	Medusa.Config.get = self.originalConfigGet
	Medusa.Config.getLogLevel = self.originalGetLogLevel
	Medusa.Core.IadsNetwork.new = self.originalNetworkNew
	Medusa.Services.AaaService.newBarrageState = self.originalBarrageStateNew
	Medusa.Services.BlackBoxWeaponStore.new = self.originalWeaponStoreNew
	Medusa.Services.MissionUnitSkillIndex.new = self.originalSkillIndexNew
	Medusa.Services.BlackBoxService.start = self.originalBlackBoxStart
	Medusa.Observability.MetricsSnapshot.installSnapshot = self.originalInstallSnapshot
	Medusa.Observability.MetricsService.serialize = self.originalSerialize
	Medusa.Core.IadsById = self.originalIadsById
	Medusa.API = self.originalApi
	ScheduleOnce = self.originalScheduleOnce
	io.open = self.originalIoOpen
	os.rename = self.originalOsRename
	os.remove = self.originalOsRemove
	lfs = self.originalLfs
	AddWorldEventHandler = self.originalAddWorldEventHandler
	RemoveWorldEventHandler = self.originalRemoveWorldEventHandler
	GetWorldEventTypes = self.originalGetWorldEventTypes
	Medusa.Core.RawWorldEventTraceHandler = self.originalRawWorldEventTraceHandler
	env.info = self.originalEnvInfo
	Medusa.Logger:setLevel(self.originalLogLevel)
end

function TestEntrypoint:test_trace_observer_reports_known_and_unknown_world_events()
	Medusa.Config.initialize = function()
		return true
	end
	Medusa.Config.getNetworks = function()
		return {}
	end
	Medusa.Config.get = function()
		return { PrometheusEnabled = false }
	end
	Medusa.Config.getLogLevel = function()
		return Medusa.Constants.LogLevel.TRACE
	end
	Medusa.Services.AaaService.newBarrageState = function()
		return {}
	end
	Medusa.Services.BlackBoxWeaponStore.new = function()
		return {}
	end
	Medusa.Services.MissionUnitSkillIndex.new = function()
		return {}
	end
	Medusa.Observability.MetricsSnapshot.installSnapshot = function()
		return true
	end
	local previousHandler = {}
	Medusa.Core.RawWorldEventTraceHandler = previousHandler
	local removedHandler
	RemoveWorldEventHandler = function(handler)
		removedHandler = handler
		return true
	end
	local installedHandler
	AddWorldEventHandler = function(handler)
		installedHandler = handler
		return true
	end
	GetWorldEventTypes = function()
		return { S_EVENT_DEAD = world.event.S_EVENT_DEAD }
	end
	local messages = {}
	env.info = function(message)
		messages[#messages + 1] = message
	end
	Medusa.Logger:setLevel(Medusa.Constants.LogLevel.TRACE)

	dofile("./src/_Entrypoint.lua")

	lu.assertIs(removedHandler, previousHandler)
	lu.assertNotNil(installedHandler)
	installedHandler:onEvent({ id = world.event.S_EVENT_DEAD, time = 42 })
	installedHandler:onEvent({ id = 999, time = 43 })
	local output = table.concat(messages, "\n")
	lu.assertStrContains(output, "raw DCS event S_EVENT_DEAD:")
	lu.assertStrContains(output, "raw DCS event UNKNOWN_ID_999:")
end

function TestEntrypoint:test_metrics_export_publishes_complete_snapshot_after_closing_temporary_file()
	Medusa.Config.initialize = function()
		return true
	end
	Medusa.Config.getNetworks = function()
		return {}
	end
	Medusa.Config.get = function()
		return { PrometheusEnabled = true, PrometheusExtendEnabled = true }
	end
	Medusa.Services.AaaService.newBarrageState = function()
		return {}
	end
	Medusa.Services.BlackBoxWeaponStore.new = function()
		return {}
	end
	Medusa.Services.MissionUnitSkillIndex.new = function()
		return {}
	end
	Medusa.Observability.MetricsSnapshot.installSnapshot = function()
		return true
	end
	Medusa.Observability.MetricsService.serialize = function()
		return "metric_one 1\nmetric_two 2"
	end
	lfs = {
		writedir = function()
			return "C:/Saved Games/DCS/"
		end,
	}
	local callbacks = {}
	ScheduleOnce = function(callback)
		callbacks[#callbacks + 1] = callback
		return #callbacks
	end
	local opened = {}
	local written = {}
	local temporarySize = 0
	local closed = false
	io.open = function(path, mode)
		opened[#opened + 1] = { path = path, mode = mode }
		local file = {}
		file.write = function(_, value)
			written[#written + 1] = value
			temporarySize = temporarySize + #value
		end
		file.close = function()
			closed = true
		end
		return file
	end
	lfs.attributes = function(path, attribute)
		lu.assertEquals(path, "C:/Saved Games/DCS/Logs/medusa_metrics.prom.tmp")
		lu.assertEquals(attribute, "size")
		return temporarySize
	end
	local renamed = {}
	os.rename = function(from, to)
		renamed[#renamed + 1] = { from = from, to = to, afterClose = closed }
		if #renamed == 1 then
			return nil, "destination exists"
		end
		return true
	end
	local removed = {}
	os.remove = function(path)
		removed[#removed + 1] = path
		return true
	end

	dofile("./src/_Entrypoint.lua")
	callbacks[1]()

	lu.assertEquals(opened, {
		{ path = "C:/Saved Games/DCS/Logs/medusa_metrics.prom.tmp", mode = "w" },
	})
	lu.assertEquals(written, { "metric_one 1\nmetric_two 2\n" })
	lu.assertEquals(renamed, {
		{
			from = "C:/Saved Games/DCS/Logs/medusa_metrics.prom.tmp",
			to = "C:/Saved Games/DCS/Logs/medusa_metrics.prom",
			afterClose = true,
		},
		{
			from = "C:/Saved Games/DCS/Logs/medusa_metrics.prom",
			to = "C:/Saved Games/DCS/Logs/medusa_metrics.prom.previous",
			afterClose = true,
		},
		{
			from = "C:/Saved Games/DCS/Logs/medusa_metrics.prom.tmp",
			to = "C:/Saved Games/DCS/Logs/medusa_metrics.prom",
			afterClose = true,
		},
	})
	lu.assertEquals(removed, {
		"C:/Saved Games/DCS/Logs/medusa_metrics.prom.previous",
		"C:/Saved Games/DCS/Logs/medusa_metrics.prom.previous",
	})
end

function TestEntrypoint:test_prometheus_timer_registration_failure_is_contained()
	Medusa.Config.initialize = function()
		return true
	end
	Medusa.Config.getNetworks = function()
		return {}
	end
	Medusa.Config.get = function()
		return { PrometheusEnabled = true, PrometheusExtendEnabled = false }
	end
	Medusa.Services.AaaService.newBarrageState = function()
		return {}
	end
	Medusa.Services.BlackBoxWeaponStore.new = function()
		return {}
	end
	Medusa.Services.MissionUnitSkillIndex.new = function()
		return {}
	end
	Medusa.Observability.MetricsSnapshot.installSnapshot = function()
		return true
	end
	ScheduleOnce = function()
		error("injected metrics registration failure")
	end

	local contained = pcall(dofile, "./src/_Entrypoint.lua")

	lu.assertTrue(contained)
end

function TestEntrypoint:test_metrics_snapshot_installation_failure_is_contained()
	Medusa.Config.initialize = function()
		return true
	end
	Medusa.Config.getNetworks = function()
		return {}
	end
	Medusa.Config.get = function()
		return { PrometheusEnabled = false }
	end
	Medusa.Services.AaaService.newBarrageState = function()
		return {}
	end
	Medusa.Services.BlackBoxWeaponStore.new = function()
		return {}
	end
	Medusa.Services.MissionUnitSkillIndex.new = function()
		return {}
	end
	Medusa.Observability.MetricsSnapshot.installSnapshot = function()
		error("injected snapshot installation failure")
	end

	local contained = pcall(dofile, "./src/_Entrypoint.lua")

	lu.assertTrue(contained)
end

function TestEntrypoint:test_network_construction_and_initialization_failures_do_not_prevent_a_healthy_network()
	local networks = {
		{ id = "construction-failed", coalitionId = nil, prefix = "failed" },
		{ id = "initialization-failed", coalitionId = 1, prefix = "failed" },
		{ id = "healthy", coalitionId = 1, prefix = "healthy" },
	}
	local instances = {}
	local barrageState = { participants = {}, limitsByNetwork = {} }
	local emptyStore = {
		getAll = function()
			return {}
		end,
	}
	for i = 2, #networks do
		instances[i] = self.originalNetworkNew(Medusa.Core.IadsNetwork, {
			id = networks[i].id,
			coalitionId = networks[i].coalitionId,
			prefix = networks[i].prefix,
		})
	end
	instances[2]._aaaBarrageState = barrageState
	instances[2].initialize = function(self)
		self._assetIndex = {
			batteries = function()
				return emptyStore
			end,
			manpads = function()
				return emptyStore
			end,
		}
		Medusa.Services.AaaService.setBarrageLimit(barrageState, self._id, 0)
		error("injected initialization failure")
	end
	instances[3].initialize = function(self)
		self._initialized = true
		self._doctrine = { CrewSuppression = { Enabled = false } }
		Medusa.Services.AaaService.setBarrageLimit(barrageState, self._id, 7)
		return true
	end
	instances[3].getDoctrine = function(self)
		return self._doctrine
	end
	instances[3].start = function(self)
		self._running = true
		return true
	end
	Medusa.Config.initialize = function()
		return true
	end
	Medusa.Config.getNetworks = function()
		return networks
	end
	Medusa.Config.get = function()
		return { PrometheusEnabled = false }
	end
	local nextNetwork = 0
	Medusa.Core.IadsNetwork.new = function()
		nextNetwork = nextNetwork + 1
		if nextNetwork == 1 then
			error("injected construction failure")
		end
		return instances[nextNetwork]
	end
	Medusa.Services.AaaService.newBarrageState = function()
		return barrageState
	end
	Medusa.Services.BlackBoxWeaponStore.new = function()
		return {}
	end
	Medusa.Services.MissionUnitSkillIndex.new = function()
		return {}
	end
	Medusa.Services.BlackBoxService.start = function()
		return true
	end
	Medusa.Observability.MetricsSnapshot.installSnapshot = function()
		return true
	end

	dofile("./src/_Entrypoint.lua")

	lu.assertNil(Medusa.Core.IadsById["construction-failed"])
	lu.assertFalse(instances[2]._running)
	lu.assertNil(Medusa.Core.IadsById["initialization-failed"])
	lu.assertNil(barrageState.limitsByNetwork["initialization-failed"])
	lu.assertTrue(instances[3]._running)
	lu.assertEquals(Medusa.Core.IadsById.healthy, instances[3])
	lu.assertEquals(barrageState.limitsByNetwork.healthy, 7)
end

function TestEntrypoint:test_start_failure_unpublishes_only_the_failed_network()
	local networks = {
		{ id = "start-failed", coalitionId = 1, prefix = "failed" },
		{ id = "healthy", coalitionId = 1, prefix = "healthy" },
	}
	local failed = { stopped = false }
	local healthy = { stopped = false }
	for _, instance in ipairs({ failed, healthy }) do
		instance.initialize = function(self)
			self.doctrine = { CrewSuppression = { Enabled = false } }
			return true
		end
		instance.getDoctrine = function(self)
			return self.doctrine
		end
		instance.stop = function(self)
			self.stopped = true
			return true
		end
	end
	failed.start = function()
		return false
	end
	healthy.start = function()
		return true
	end
	Medusa.Config.initialize = function()
		return true
	end
	Medusa.Config.getNetworks = function()
		return networks
	end
	Medusa.Config.get = function()
		return { PrometheusEnabled = false }
	end
	local nextNetwork = 0
	Medusa.Core.IadsNetwork.new = function()
		nextNetwork = nextNetwork + 1
		return nextNetwork == 1 and failed or healthy
	end
	Medusa.Services.AaaService.newBarrageState = function()
		return {}
	end
	Medusa.Services.BlackBoxWeaponStore.new = function()
		return {}
	end
	Medusa.Services.MissionUnitSkillIndex.new = function()
		return {}
	end
	Medusa.Services.BlackBoxService.start = function()
		return true
	end
	Medusa.Observability.MetricsSnapshot.installSnapshot = function()
		return true
	end

	dofile("./src/_Entrypoint.lua")

	lu.assertTrue(failed.stopped)
	lu.assertNil(Medusa.Core.IadsById["start-failed"])
	lu.assertFalse(healthy.stopped)
	lu.assertIs(Medusa.Core.IadsById.healthy, healthy)
end
