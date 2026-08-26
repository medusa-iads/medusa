local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("entities.Doctrine")
require("services.Services")
require("services.SensorPollingService")

-- == Helpers ==

local mockIdCounter = 0

local function makeDcsObject(name, pos, vel, category)
	mockIdCounter = mockIdCounter + 1
	return {
		id_ = mockIdCounter,
		getCategory = function(self)
			return category or Object.Category.UNIT
		end,
		getPoint = function(self)
			return pos
		end,
		getVelocity = function(self)
			return vel
		end,
		getName = function(self)
			return name
		end,
	}
end

local function setupMocks()
	Medusa.Logger._initialized = false
	Medusa.Logger:initialize()
end

-- == TestSensorPollingServicePollSensor ==

TestSensorPollingServicePollSensor = {}

function TestSensorPollingServicePollSensor:setUp()
	setupMocks()
	mockIdCounter = 0
	self.svc = Medusa.Services.SensorPollingService:new({
		PerTrackScanUpdateRate = 5,
		SensorCleanupSec = 30,
	})
end

function TestSensorPollingServicePollSensor:test_returnsNilWhenNoController()
	GetGroupController = function(_)
		return nil
	end

	local reports = self.svc:pollSensor("missing-group", 100)
	lu.assertNil(reports)
end

function TestSensorPollingServicePollSensor:test_returnsNilWhenDetectionReadFails()
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return nil
	end

	local reports = self.svc:pollSensor("empty-group", 100)
	lu.assertNil(reports)
end

function TestSensorPollingServicePollSensor:test_returnsEmptyWhenDetectionsEmpty()
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return {}
	end

	local reports = self.svc:pollSensor("empty-group", 100)
	lu.assertEquals(#reports, 0)
end

function TestSensorPollingServicePollSensor:test_buildsReportFromDetection()
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return {
			{
				object = makeDcsObject("target-1", { x = 100, y = 500, z = 200 }, { x = 10, y = 0, z = 5 }),
				visible = true,
				type = true,
				distance = true,
			},
		}
	end

	local reports = self.svc:pollSensor("sensor-group", 100)

	lu.assertEquals(#reports, 1)
	lu.assertEquals(reports[1].NetworkId, 1)
	lu.assertEquals(reports[1].SourceType, Medusa.Constants.TrackSource.EARLY_WARNING_RADAR)
	lu.assertIsNil(reports[1].ObjectCategory)
	lu.assertIsNil(reports[1].UnitCategory)
	lu.assertEquals(reports[1].Position.x, 100)
	lu.assertEquals(reports[1].Position.y, 500)
	lu.assertEquals(reports[1].Position.z, 200)
	lu.assertEquals(reports[1].Velocity.x, 10)
	lu.assertEquals(reports[1].Velocity.y, 0)
	lu.assertEquals(reports[1].Velocity.z, 5)
end

function TestSensorPollingServicePollSensor:test_default_doctrine_observes_one_track_every_two_seconds()
	self.svc = Medusa.Services.SensorPollingService:new(Medusa.Entities.Doctrine.new({}))
	local target = makeDcsObject("target-1", { x = 100, y = 500, z = 200 }, { x = 10, y = 0, z = 5 })
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return { { object = target } }
	end

	lu.assertEquals(#self.svc:pollSensor("sensor-group", 100), 1)
	lu.assertEquals(#self.svc:pollSensor("sensor-group", 101.999), 0)
	lu.assertEquals(#self.svc:pollSensor("sensor-group", 102), 1)
end

function TestSensorPollingServicePollSensor:test_includes_supplied_originating_source()
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return {
			{
				object = makeDcsObject("target-1", { x = 100, y = 500, z = 200 }, { x = 10, y = 0, z = 5 }),
			},
		}
	end

	local reports = self.svc:pollSensor("awacs-group", 100, Medusa.Constants.TrackSource.AWACS)

	lu.assertEquals(reports[1].SourceType, Medusa.Constants.TrackSource.AWACS)
end

function TestSensorPollingServicePollSensor:test_multipleDetections()
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return {
			{
				object = makeDcsObject("t1", { x = 1, y = 2, z = 3 }, { x = 4, y = 5, z = 6 }),
				visible = true,
			},
			{
				object = makeDcsObject("t2", { x = 7, y = 8, z = 9 }, { x = 10, y = 11, z = 12 }),
				visible = true,
			},
		}
	end

	local reports = self.svc:pollSensor("sensor-group", 100)

	lu.assertEquals(#reports, 2)
	lu.assertEquals(reports[1].NetworkId, 1)
	lu.assertEquals(reports[2].NetworkId, 2)
end

function TestSensorPollingServicePollSensor:test_detection_budget_rotates_across_stable_results()
	GetGroupController = function(_)
		return {}
	end
	local detections = {}
	for i = 1, 5 do
		detections[i] = {
			object = makeDcsObject("target-" .. i, { x = i, y = 0, z = 0 }, { x = 1, y = 0, z = 0 }),
		}
	end
	GetControllerDetectedTargets = function(_)
		return detections
	end

	local first, firstInspected, nextIndex = self.svc:pollSensor("sensor-group", 100, nil, nil, 2, 1)
	local second, secondInspected, finalIndex = self.svc:pollSensor("sensor-group", 106, nil, nil, 2, nextIndex)

	lu.assertEquals(firstInspected, 2)
	lu.assertEquals(#first, 2)
	lu.assertEquals(first[1].NetworkId, 1)
	lu.assertEquals(first[2].NetworkId, 2)
	lu.assertEquals(nextIndex, 3)
	lu.assertEquals(secondInspected, 2)
	lu.assertEquals(#second, 2)
	lu.assertEquals(second[1].NetworkId, 3)
	lu.assertEquals(second[2].NetworkId, 4)
	lu.assertEquals(finalIndex, 5)
end

function TestSensorPollingServicePollSensor:test_skipsDetectionWithNoObject()
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return {
			{ object = nil, visible = true },
		}
	end

	local reports = self.svc:pollSensor("sensor-group", 100)
	lu.assertEquals(#reports, 0)
end

function TestSensorPollingServicePollSensor:test_skipsDetectionWhenGetPointFails()
	local badObj = {
		id_ = 1,
		getCategory = function(self)
			return Object.Category.UNIT
		end,
		getPoint = function(self)
			error("destroyed")
		end,
		getVelocity = function(self)
			return { x = 0, y = 0, z = 0 }
		end,
	}

	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return { { object = badObj } }
	end

	local reports = self.svc:pollSensor("sensor-group", 100)
	lu.assertEquals(#reports, 0)
end

function TestSensorPollingServicePollSensor:test_skipsDetectionWhenGetVelocityFails()
	local badObj = {
		id_ = 1,
		getCategory = function(self)
			return Object.Category.UNIT
		end,
		getPoint = function(self)
			return { x = 1, y = 2, z = 3 }
		end,
		getVelocity = function(self)
			error("destroyed")
		end,
	}

	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return { { object = badObj } }
	end

	local reports = self.svc:pollSensor("sensor-group", 100)
	lu.assertEquals(#reports, 0)
end

function TestSensorPollingServicePollSensor:test_malformed_vector_does_not_throttle_later_valid_observation()
	local position = { x = "invalid", y = 0, z = 0 }
	local obj = {
		id_ = 71,
		getCategory = function()
			return Object.Category.UNIT
		end,
		getPoint = function()
			return position
		end,
		getVelocity = function()
			return { x = 1, y = 0, z = 0 }
		end,
	}
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return { { object = obj } }
	end

	local malformed, inspected = self.svc:pollSensor("sensor-group", 100)
	lu.assertEquals(#malformed, 0)
	lu.assertEquals(inspected, 1)

	position = { x = 10, y = 20, z = 30 }
	local valid = self.svc:pollSensor("sensor-group", 101)
	lu.assertEquals(#valid, 1)
	lu.assertEquals(valid[1].NetworkId, 71)
end

function TestSensorPollingServicePollSensor:test_malformed_detection_collection_and_entry_are_rejected()
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return "invalid"
	end
	local invalidCollection, collectionInspected = self.svc:pollSensor("sensor-group", 100)
	lu.assertIsNil(invalidCollection)
	lu.assertEquals(collectionInspected, 0)

	GetControllerDetectedTargets = function(_)
		return { "invalid-entry" }
	end
	local invalidEntry, entryInspected = self.svc:pollSensor("sensor-group", 101)
	lu.assertEquals(#invalidEntry, 0)
	lu.assertEquals(entryInspected, 1)
end

function TestSensorPollingServicePollSensor:test_scalar_detection_object_is_rejected_without_throttling_later_data()
	local detectionObject = 42
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return { { object = detectionObject } }
	end
	local malformed, inspected = self.svc:pollSensor("sensor-group", 100)
	lu.assertEquals(#malformed, 0)
	lu.assertEquals(inspected, 1)

	detectionObject = makeDcsObject("target", { x = 1, y = 2, z = 3 }, { x = 0, y = 0, z = 0 })
	local valid = self.svc:pollSensor("sensor-group", 101)
	lu.assertEquals(#valid, 1)
end

function TestSensorPollingServicePollSensor:test_scan_throttle_cache_evicts_at_fixed_capacity()
	local capacity = Medusa.Constants.C2.SENSOR_SCAN_CACHE_CAPACITY
	local detections = {}
	for i = 1, capacity + 1 do
		detections[i] = {
			object = makeDcsObject("target-" .. i, { x = i, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }),
		}
	end
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return detections
	end

	local reports, inspected = self.svc:pollSensor("sensor-group", 100, nil, nil, capacity + 1)

	local retained = 0
	for _ in pairs(self.svc._lastScanned) do
		retained = retained + 1
	end
	lu.assertEquals(#reports, capacity + 1)
	lu.assertEquals(inspected, capacity + 1)
	lu.assertEquals(retained, capacity)
	lu.assertEquals(self.svc._lastScannedOrder:size(), capacity)
	lu.assertIsNil(self.svc._lastScanned[1])
	lu.assertNotNil(self.svc._lastScanned[capacity + 1])
end

function TestSensorPollingServicePollSensor:test_rejectsNilObjectId()
	local obj = {
		id_ = nil,
		getCategory = function(self)
			return Object.Category.UNIT
		end,
		getPoint = function(self)
			return { x = 1, y = 2, z = 3 }
		end,
		getVelocity = function(self)
			return { x = 0, y = 0, z = 0 }
		end,
	}

	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return { { object = obj } }
	end

	local reports = self.svc:pollSensor("sensor-group", 100)
	lu.assertEquals(#reports, 0)
end

function TestSensorPollingServicePollSensor:test_partialFailuresStillReturnGood()
	local badObj = {
		id_ = 1,
		getCategory = function(self)
			return Object.Category.UNIT
		end,
		getPoint = function(self)
			error("boom")
		end,
		getVelocity = function(self)
			return { x = 0, y = 0, z = 0 }
		end,
	}

	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return {
			{ object = badObj },
			{
				object = makeDcsObject("good", { x = 50, y = 100, z = 150 }, { x = 1, y = 2, z = 3 }),
			},
		}
	end

	local reports = self.svc:pollSensor("sensor-group", 100)

	lu.assertEquals(#reports, 1)
	lu.assertEquals(reports[1].NetworkId, 1)
	lu.assertEquals(reports[1].Position.x, 50)
end

function TestSensorPollingServicePollSensor:test_acceptsWeaponObjects()
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return {
			{
				object = makeDcsObject("AGM-88C #001", { x = 1, y = 500, z = 2 }, { x = 300, y = -50, z = 0 }, Object.Category.WEAPON),
			},
		}
	end

	local reports = self.svc:pollSensor("sensor-group", 100)
	lu.assertEquals(#reports, 1)
	lu.assertEquals(reports[1].NetworkId, 1)
	lu.assertIsNil(reports[1].ObjectCategory)
	lu.assertIsNil(reports[1].UnitCategory)
	lu.assertEquals(reports[1].Position.x, 1)
	lu.assertEquals(reports[1].Velocity.x, 300)
end

function TestSensorPollingServicePollSensor:test_skipsStaticObjects()
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return {
			{
				object = makeDcsObject("building-1", { x = 1, y = 0, z = 2 }, { x = 0, y = 0, z = 0 }, Object.Category.STATIC),
			},
		}
	end

	local reports = self.svc:pollSensor("sensor-group", 100)
	lu.assertEquals(#reports, 0)
end
