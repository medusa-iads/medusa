local Support = {}

function Support.applyManpadOverrides(battery, overrides)
	for key, value in pairs(overrides or {}) do
		if key == "Manpad" then
			for stateKey, stateValue in pairs(value) do
				battery.Manpad[stateKey] = stateValue
			end
		else
			battery[key] = value
		end
	end
	return battery
end

function Support.newManpadView()
	return Medusa.Services.BatteryStore:new():manpads()
end

function Support.makeQueryGeoGrid(result)
	return {
		queryRadius = function()
			return result or {}
		end,
	}
end

function Support.evaluateSingle(battery, trackStore, geoGrid, now, posture, decaySec)
	local store = Support.newManpadView()
	store:add(battery)
	Medusa.Services.ManpadService.evaluate({
		manpadStore = store,
		trackStore = trackStore,
		networkedGeoGrid = geoGrid,
		now = now,
		posture = posture,
		doctrine = {
			MANPADAlertnessDecaySec = decaySec == nil and 14400 or decaySec,
			MANPADFieldRadioRangeM = 5000,
		},
	})
end

function Support.newTimerHarness()
	local harness = {}

	function harness:install()
		self.scheduledCallbacks = {}
		self.cancelledIds = {}
		self.timerIdCounter = 0
		self.time = 0
		self.originalScheduleOnce = ScheduleOnce
		self.originalCancelSchedule = CancelSchedule
		self.originalGetTime = GetTime

		ScheduleOnce = function(fn, args, delaySec)
			self.timerIdCounter = self.timerIdCounter + 1
			local id = string.format("timer-%d", self.timerIdCounter)
			self.scheduledCallbacks[#self.scheduledCallbacks + 1] = {
				fn = fn,
				args = args,
				delay = delaySec,
				id = id,
			}
			return id
		end
		CancelSchedule = function(timerId)
			self.cancelledIds[#self.cancelledIds + 1] = timerId
			return true
		end
		GetTime = function()
			return self.time
		end
	end

	function harness:restore()
		ScheduleOnce = self.originalScheduleOnce
		CancelSchedule = self.originalCancelSchedule
		GetTime = self.originalGetTime
	end

	return harness
end

return Support
