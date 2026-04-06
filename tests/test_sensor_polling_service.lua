local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
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
	self.svc = Medusa.Services.SensorPollingService:new()
end

function TestSensorPollingServicePollSensor:test_returnsEmptyWhenNoController()
	GetGroupController = function(_)
		return nil
	end

	local reports = self.svc:pollSensor("missing-group", 100)
	lu.assertEquals(#reports, 0)
end

function TestSensorPollingServicePollSensor:test_returnsEmptyWhenNoDetections()
	GetGroupController = function(_)
		return {}
	end
	GetControllerDetectedTargets = function(_)
		return nil
	end

	local reports = self.svc:pollSensor("empty-group", 100)
	lu.assertEquals(#reports, 0)
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
	lu.assertEquals(reports[1].Position.x, 100)
	lu.assertEquals(reports[1].Position.y, 500)
	lu.assertEquals(reports[1].Position.z, 200)
	lu.assertEquals(reports[1].Velocity.x, 10)
	lu.assertEquals(reports[1].Velocity.y, 0)
	lu.assertEquals(reports[1].Velocity.z, 5)
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

function TestSensorPollingServicePollSensor:test_rejectsHighObjectId()
	local obj = {
		id_ = 50000000,
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
				object = makeDcsObject(
					"AGM-88C #001",
					{ x = 1, y = 500, z = 2 },
					{ x = 300, y = -50, z = 0 },
					Object.Category.WEAPON
				),
			},
		}
	end

	local reports = self.svc:pollSensor("sensor-group", 100)
	lu.assertEquals(#reports, 1)
	lu.assertEquals(reports[1].NetworkId, 1)
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
				object = makeDcsObject(
					"building-1",
					{ x = 1, y = 0, z = 2 },
					{ x = 0, y = 0, z = 0 },
					Object.Category.STATIC
				),
			},
		}
	end

	local reports = self.svc:pollSensor("sensor-group", 100)
	lu.assertEquals(#reports, 0)
end
