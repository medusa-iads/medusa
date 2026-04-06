-- Mock DCS Environment for Testing
-- This file provides mock implementations of DCS APIs for unit testing

-- Mock global functions and tables
env = {
	info = function(msg) end,
	warning = function(msg) end,
	error = function(msg) end,
}

timer = {
	getTime = function()
		return 1000.0
	end,
	getAbsTime = function()
		return 50000.0
	end,
	getTime0 = function()
		return 43200.0
	end,
	scheduleFunction = function(func, args, time)
		return math.random(1, 1000)
	end,
	removeFunction = function(timerId)
		return true
	end,
	setFunctionTime = function(timerId, newTime)
		return true
	end,
}

land = {
	getHeight = function(vec2)
		return 100.0
	end,
	isVisible = function(from, to)
		return true
	end,
	getSurfaceType = function(vec2)
		return 1
	end,
	getIP = function(origin, direction, maxDistance)
		return { x = 100, y = 50, z = 200 }
	end,
	profile = function(from, to)
		return { { x = 0, y = 100 }, { x = 100, y = 120 } }
	end,
	getClosestPointOnRoads = function(roadType, x, y)
		return { x = x, y = 0, z = y }
	end,
	findPathOnRoads = function(roadType, x1, y1, x2, y2)
		return { { x = x1, y = 0, z = y1 }, { x = x2, y = 0, z = y2 } }
	end,
	SurfaceType = {
		LAND = 1,
		SHALLOW_WATER = 2,
		WATER = 3,
		ROAD = 4,
		RUNWAY = 5,
	},
}

coord = {
	LOtoLL = function(vec3)
		return { latitude = 43.5, longitude = 41.2 }
	end,
	LLtoLO = function(lat, lon, alt)
		return { x = 1000, y = alt or 0, z = 2000 }
	end,
	-- Provide only documented functions; test code composes through LL
	LLtoMGRS = function(lat, lon)
		return { UTMZone = "37T", MGRSDigraph = "CK", Easting = 12345, Northing = 67890 }
	end,
	MGRStoLL = function(mgrsString)
		return { lat = 43.5, lon = 41.2 }
	end,
}

trigger = {
	misc = {
		getZone = function(name)
			return { point = { x = 0, y = 0, z = 0 }, radius = 1000 }
		end,
		getUserFlag = function(name)
			return 0
		end,
	},
	action = {
		-- Track function calls for testing
		_called = {},
		_callCount = 0,
		_trackCall = function(funcName, ...)
			trigger.action._callCount = trigger.action._callCount + 1
			trigger.action._called[trigger.action._callCount] = { func = funcName, args = { ... } }
		end,

		setUserFlag = function(name, value)
			trigger.action._trackCall("setUserFlag", name, value)
			return true
		end,
		outText = function(text, time, clear)
			trigger.action._trackCall("outText", text, time, clear)
			return true
		end,
		outTextForCoalition = function(coalition, text, time, clear)
			trigger.action._trackCall("outTextForCoalition", coalition, text, time, clear)
			return true
		end,
		outTextForGroup = function(group, text, time, clear)
			trigger.action._trackCall("outTextForGroup", group, text, time, clear)
			return true
		end,
		outTextForUnit = function(unit, text, time, clear)
			trigger.action._trackCall("outTextForUnit", unit, text, time, clear)
			return true
		end,
		outSound = function(soundFile, soundType)
			trigger.action._trackCall("outSound", soundFile, soundType)
			return true
		end,
		outSoundForCoalition = function(coalition, soundFile, soundType)
			trigger.action._trackCall("outSoundForCoalition", coalition, soundFile, soundType)
			return true
		end,
		explosion = function(pos, power)
			trigger.action._trackCall("explosion", pos, power)
			return true
		end,
		smoke = function(pos, color, density, name)
			trigger.action._trackCall("smoke", pos, color, density, name)
			return true
		end,
		effectSmokeBig = function(pos, preset, density, name)
			trigger.action._trackCall("effectSmokeBig", pos, preset, density, name)
			return true
		end,
		effectSmokeStop = function(name)
			trigger.action._trackCall("effectSmokeStop", name)
			return true
		end,
		signalFlare = function(pos, color, azimuth)
			trigger.action._trackCall("signalFlare", pos, color, azimuth)
			return true
		end,
		illuminationBomb = function(pos, power)
			trigger.action._trackCall("illuminationBomb", pos, power)
			return true
		end,
		radioTransmission = function(filename, pos, modulation, loop, frequency, power, name)
			trigger.action._trackCall("radioTransmission", filename, pos, modulation, loop, frequency, power, name)
			return true
		end,
		stopRadioTransmission = function(name)
			trigger.action._trackCall("stopRadioTransmission", name)
			return true
		end,
		setMarkupRadius = function(id, radius)
			trigger.action._trackCall("setMarkupRadius", id, radius)
			return true
		end,
		setMarkupText = function(id, text)
			trigger.action._trackCall("setMarkupText", id, text)
			return true
		end,
		setMarkupColor = function(id, color)
			trigger.action._trackCall("setMarkupColor", id, color)
			return true
		end,
		setMarkupColorFill = function(id, colorFill)
			trigger.action._trackCall("setMarkupColorFill", id, colorFill)
			return true
		end,
		setMarkupFontSize = function(id, fontSize)
			trigger.action._trackCall("setMarkupFontSize", id, fontSize)
			return true
		end,
		removeMark = function(id)
			trigger.action._trackCall("removeMark", id)
			return true
		end,
		markToAll = function(id, text, pos, readOnly, message)
			trigger.action._trackCall("markToAll", id, text, pos, readOnly, message)
			return true
		end,
		markToCoalition = function(id, text, pos, coalition, readOnly, message)
			trigger.action._trackCall("markToCoalition", id, text, pos, coalition, readOnly, message)
			return true
		end,
		markToGroup = function(id, text, pos, groupId, readOnly, message)
			trigger.action._trackCall("markToGroup", id, text, pos, groupId, readOnly, message)
			return true
		end,
		lineToAll = function(coalition, id, startPoint, endPoint, color, lineType, readOnly, message)
			trigger.action._trackCall(
				"lineToAll",
				coalition,
				id,
				startPoint,
				endPoint,
				color,
				lineType,
				readOnly,
				message
			)
			return true
		end,
		circleToAll = function(coalition, id, center, radius, color, fillColor, lineType, readOnly, message)
			trigger.action._trackCall(
				"circleToAll",
				coalition,
				id,
				center,
				radius,
				color,
				fillColor,
				lineType,
				readOnly,
				message
			)
			return true
		end,
		rectToAll = function(coalition, id, startPoint, endPoint, color, fillColor, lineType, readOnly, message)
			trigger.action._trackCall(
				"rectToAll",
				coalition,
				id,
				startPoint,
				endPoint,
				color,
				fillColor,
				lineType,
				readOnly,
				message
			)
			return true
		end,
		quadToAll = function(
			coalition,
			id,
			point1,
			point2,
			point3,
			point4,
			color,
			fillColor,
			lineType,
			readOnly,
			message
		)
			trigger.action._trackCall(
				"quadToAll",
				coalition,
				id,
				point1,
				point2,
				point3,
				point4,
				color,
				fillColor,
				lineType,
				readOnly,
				message
			)
			return true
		end,
		textToAll = function(coalition, id, point, color, fillColor, fontSize, readOnly, text)
			trigger.action._trackCall("textToAll", coalition, id, point, color, fillColor, fontSize, readOnly, text)
			return true
		end,
		arrowToAll = function(coalition, id, startPoint, endPoint, color, fillColor, lineType, readOnly, message)
			trigger.action._trackCall(
				"arrowToAll",
				coalition,
				id,
				startPoint,
				endPoint,
				color,
				fillColor,
				lineType,
				readOnly,
				message
			)
			return true
		end,
		markupToAll = function(...)
			trigger.action._trackCall("markupToAll", ...)
			return true
		end,
		setAITask = function(group, task)
			trigger.action._trackCall("setAITask", group, task)
			return true
		end,
		pushAITask = function(group, task)
			trigger.action._trackCall("pushAITask", group, task)
			return true
		end,
		activateGroup = function(group)
			trigger.action._trackCall("activateGroup", group)
			return true
		end,
		deactivateGroup = function(group)
			trigger.action._trackCall("deactivateGroup", group)
			return true
		end,
		setGroupAIOn = function(group)
			trigger.action._trackCall("setGroupAIOn", group)
			return true
		end,
		setGroupAIOff = function(group)
			trigger.action._trackCall("setGroupAIOff", group)
			return true
		end,
		groupStopMoving = function(group)
			trigger.action._trackCall("groupStopMoving", group)
			return true
		end,
		groupContinueMoving = function(group)
			trigger.action._trackCall("groupContinueMoving", group)
			return true
		end,
	},
	smokeColor = {
		Green = 0,
		Red = 1,
		White = 2,
		Orange = 3,
		Blue = 4,
	},
	flareColor = {
		Green = 0,
		Red = 1,
		White = 2,
		Yellow = 3,
	},
}

local _mockUnitIdCounter = 0
local _mockUnitIdByName = {}

Unit = {
	getByName = function(name)
		if not _mockUnitIdByName[name] then
			_mockUnitIdCounter = _mockUnitIdCounter + 1
			_mockUnitIdByName[name] = _mockUnitIdCounter
		end
		local unitId = _mockUnitIdByName[name]
		return {
			isExist = function(self)
				return true
			end,
			getPosition = function(self)
				return { p = { x = 100, y = 50, z = 200 }, x = { x = 1, y = 0, z = 0 } }
			end,
			getVelocity = function(self)
				return { x = 10, y = 0, z = 5 }
			end,
			getTypeName = function(self)
				return "F-16C"
			end,
			getCoalition = function(self)
				return 2
			end,
			getCountry = function(self)
				return 1
			end,
			getGroup = function(self)
				return {}
			end,
			getPlayerName = function(self)
				return "TestPlayer"
			end,
			getLife = function(self)
				return 1.0
			end,
			getLife0 = function(self)
				return 1.0
			end,
			getFuel = function(self)
				return 0.8
			end,
			inAir = function(self)
				return true
			end,
			getAmmo = function(self)
				return {}
			end,
			getName = function(self)
				return name
			end,
			getID = function(self)
				return unitId
			end,
			getNumber = function(self)
				return unitId
			end,
			getCallsign = function(self)
				return "Enfield 1-1"
			end,
			getObjectID = function(self)
				return 1000 + unitId
			end,
			getCategoryEx = function(self)
				return 0
			end,
			getDesc = function(self)
				return {}
			end,
			getForcesName = function(self)
				return "USA"
			end,
			isActive = function(self)
				return true
			end,
			getController = function(self)
				return {}
			end,
			getSensors = function(self)
				return {}
			end,
			hasSensors = function(self, sensorType, subCategory)
				return true
			end,
			getRadar = function(self)
				return true, nil
			end,
			enableEmission = function(self, enabled)
				return true
			end,
			getNearestCargos = function(self)
				return {}
			end,
			getCargosOnBoard = function(self)
				return {}
			end,
			getDescentCapacity = function(self)
				return 10
			end,
			getDescentOnBoard = function(self)
				return {}
			end,
			LoadOnBoard = function(self, cargo)
				return true
			end,
			UnloadCargo = function(self, cargo)
				return true
			end,
			openRamp = function(self)
				return true
			end,
			checkOpenRamp = function(self)
				return false
			end,
			disembarking = function(self)
				return true
			end,
			markDisembarkingTask = function(self)
				return true
			end,
			embarking = function(self)
				return false
			end,
			getAirbase = function(self)
				return nil
			end,
			canShipLanding = function(self)
				return false
			end,
			hasCarrier = function(self)
				return false
			end,
			getNearestCargosForAircraft = function(self)
				return {}
			end,
			getFuelLowState = function(self)
				return 0.25
			end,
			OldCarrierMenuShow = function(self)
				return true
			end,
			getDrawArgumentValue = function(self, arg)
				return 0
			end,
			getCommunicator = function(self)
				return {}
			end,
			getSeats = function(self)
				return {}
			end,
			getCategory = function(self)
				return 1
			end,
		}
	end,
	Category = {
		AIRPLANE = 0,
		HELICOPTER = 1,
		GROUND_UNIT = 2,
		SHIP = 3,
		STRUCTURE = 4,
	},
}

Group = {
	getByName = function(name)
		return {
			isExist = function(self)
				return true
			end,
			getUnits = function(self)
				return { Unit.getByName(name .. "#1"), Unit.getByName(name .. "#2") }
			end,
			getSize = function(self)
				return 2
			end,
			getInitialSize = function(self)
				return 2
			end,
			getCoalition = function(self)
				return 2
			end,
			getCategory = function(self)
				return 0
			end,
			getID = function(self)
				return 1
			end,
			getController = function(self)
				return {}
			end,
			activate = function(self)
				return true
			end,
			getName = function(self)
				return name
			end,
		}
	end,
	Category = {
		AIRPLANE = 0,
		HELICOPTER = 1,
		GROUND = 2,
		SHIP = 3,
		STRUCTURE = 4,
	},
}

coalition = {
	getGroups = function(coalitionId, categoryId)
		return {}
	end,
	side = {
		NEUTRAL = 0,
		RED = 1,
		BLUE = 2,
	},
}

atmosphere = {
	getWind = function(point)
		return { x = 5, y = 0, z = 2 }
	end,
	getWindWithTurbulence = function(point)
		return { x = 5, y = 1, z = 2 }
	end,
	getTemperatureAndPressure = function(point)
		return { temperature = 15, pressure = 101325 }
	end,
}

Airbase = {
	getByName = function(name)
		return {
			getDescriptor = function(self)
				return {}
			end,
			getCallsign = function(self)
				return "Batumi"
			end,
			getUnit = function(self)
				return nil
			end,
			getCategoryName = function(self)
				return "AIRBASE"
			end,
			getParking = function(self, available)
				return {}
			end,
			getRunways = function(self)
				return {}
			end,
			getRadioSilentMode = function(self)
				return false
			end,
			setRadioSilentMode = function(self, silent)
				return true
			end,
		}
	end,
}

missionCommands = {
	addCommand = function(path, menuItem, handler, params)
		return math.random(1, 1000)
	end,
	addSubMenu = function(path, name)
		return math.random(1, 1000)
	end,
	removeItem = function(path)
		return true
	end,
	addCommandForCoalition = function(coalition, path, menuItem, handler, params)
		return math.random(1, 1000)
	end,
	addSubMenuForCoalition = function(coalition, path, name)
		return math.random(1, 1000)
	end,
	removeItemForCoalition = function(coalition, path)
		return true
	end,
	addCommandForGroup = function(group, path, menuItem, handler, params)
		return math.random(1, 1000)
	end,
	addSubMenuForGroup = function(group, path, name)
		return math.random(1, 1000)
	end,
	removeItemForGroup = function(group, path)
		return true
	end,
}

world = {
	addEventHandler = function(handler)
		return true
	end,
	removeEventHandler = function(handler)
		return true
	end,
	getPlayer = function()
		return Unit.getByName("Player")
	end,
	getAirbases = function(coalition)
		return {}
	end,
	searchObjects = function(category, volume, handler)
		-- Mock implementation that delegates to global SearchWorldObjects if it exists
		-- This allows tests to override SearchWorldObjects behavior while still
		-- going through the proper world.searchObjects call path
		if _G.SearchWorldObjects then
			return _G.SearchWorldObjects(category, volume, handler)
		end
		return {}
	end,
	getMarkPanels = function()
		return {}
	end,
	getWeather = function()
		return { temperature = 15, pressure = 101325 }
	end,
	removeJunk = function(searchVolume)
		return 0
	end,
	onEvent = function(event)
		return true
	end,
	VolumeType = {
		SEGMENT = 0,
		BOX = 1,
		SPHERE = 2,
		PYRAMID = 3,
	},
	event = {
		S_EVENT_SHOT = 1,
		S_EVENT_HIT = 2,
		S_EVENT_TAKEOFF = 3,
		S_EVENT_LAND = 4,
		S_EVENT_CRASH = 5,
		S_EVENT_EJECTION = 6,
		S_EVENT_REFUELING = 7,
		S_EVENT_DEAD = 8,
		S_EVENT_PILOT_DEAD = 9,
		S_EVENT_BASE_CAPTURED = 10,
		S_EVENT_MISSION_START = 15,
		S_EVENT_MISSION_END = 16,
		S_EVENT_TOOK_CONTROL = 17,
		S_EVENT_REFUELING_STOP = 18,
		S_EVENT_BIRTH = 20,
		S_EVENT_HUMAN_FAILURE = 21,
		S_EVENT_ENGINE_STARTUP = 23,
		S_EVENT_ENGINE_SHUTDOWN = 24,
		S_EVENT_PLAYER_ENTER_UNIT = 25,
		S_EVENT_PLAYER_LEAVE_UNIT = 26,
		S_EVENT_PLAYER_COMMENT = 27,
		S_EVENT_SHOOTING_START = 28,
		S_EVENT_SHOOTING_END = 29,
		S_EVENT_MARK_ADDED = 30,
		S_EVENT_MARK_CHANGE = 31,
		S_EVENT_MARK_REMOVED = 32,
		S_EVENT_KILL = 33,
		S_EVENT_SCORE = 34,
		S_EVENT_UNIT_LOST = 35,
		S_EVENT_LANDING_AFTER_EJECTION = 36,
	},
}

country = {
	id = {
		USA = 1,
		RUSSIA = 2,
	},
}

-- Object category constants
Object = {
	Category = {
		VOID = 0,
		UNIT = 1,
		WEAPON = 2,
		STATIC = 3,
		BASE = 4,
		SCENERY = 5,
		CARGO = 6,
	},
}

-- StaticObject API
StaticObject = {
	getByName = function(name)
		return {
			getID = function(self)
				return 1
			end,
			getLife = function(self)
				return 1.0
			end,
			getCargoDisplayName = function(self)
				return "Cargo"
			end,
			getCargoWeight = function(self)
				return 1000
			end,
			destroy = function(self)
				return true
			end,
			getCategory = function(self)
				return 3
			end,
			getTypeName = function(self)
				return "Warehouse"
			end,
			getDesc = function(self)
				return {}
			end,
			isExist = function(self)
				return true
			end,
			getCoalition = function(self)
				return 2
			end,
			getCountry = function(self)
				return 1
			end,
			getPoint = function(self)
				return { x = 100, y = 0, z = 200 }
			end,
			getPosition = function(self)
				return { p = { x = 100, y = 0, z = 200 }, x = { x = 1, y = 0, z = 0 } }
			end,
			getVelocity = function(self)
				return { x = 0, y = 0, z = 0 }
			end,
			getName = function(self)
				return name
			end,
		}
	end,
	Category = {
		VOID = 0,
		UNIT = 1,
		WEAPON = 2,
		STATIC = 3,
		BASE = 4,
		SCENERY = 5,
		CARGO = 6,
	},
}

-- Weapon API
Weapon = {
	Category = {
		SHELL = 0,
		MISSILE = 1,
		ROCKET = 2,
		BOMB = 3,
		TORPEDO = 4,
	},
	getDesc = function(self)
		return {}
	end,
	getLauncher = function(self)
		return Unit.getByName("launcher")
	end,
	getTarget = function(self)
		return nil
	end,
	getCategory = function(self)
		return 2
	end, -- Weapon.Category.MISSILE
	isExist = function(self)
		return true
	end,
	getCoalition = function(self)
		return 2
	end,
	getCountry = function(self)
		return 1
	end,
	getPoint = function(self)
		return { x = 100, y = 50, z = 200 }
	end,
	getPosition = function(self)
		return { p = { x = 100, y = 50, z = 200 }, x = { x = 1, y = 0, z = 0 } }
	end,
	getVelocity = function(self)
		return { x = 200, y = -10, z = 0 }
	end,
	getName = function(self)
		return "AGM-65"
	end,
	getCategoryName = function(self)
		return "MISSILE"
	end,
	isActive = function(self)
		return true
	end,
	destroy = function(self)
		return true
	end,
}

-- Controller API
Controller = {
	setTask = function(self, task)
		return true
	end,
	resetTask = function(self)
		return true
	end,
	pushTask = function(self, task)
		return true
	end,
	popTask = function(self)
		return true
	end,
	hasTask = function(self)
		return true
	end,
	setCommand = function(self, command)
		return true
	end,
	setOnOff = function(self, onOff)
		return true
	end,
	setAltitude = function(self, altitude, altitudeType)
		return true
	end,
	setSpeed = function(self, speed, speedType)
		return true
	end,
	setOption = function(self, optionId, optionValue)
		return true
	end,
	getDetectedTargets = function(self, detectionType, categoryFilter)
		return {}
	end,
	knowTarget = function(self, target, typeKnown, distanceKnown)
		return true
	end,
	isTargetDetected = function(self, target, detectionType)
		return true
	end,
}

-- AI Constants
AI = {
	Option = {
		Air = {
			id = {
				ROE = 0,
				REACTION_ON_THREAT = 1,
				RADAR_USING = 3,
				FLARE_USING = 4,
				FORMATION = 5,
				RTB_ON_BINGO = 6,
				SILENCE = 7,
				ALARM_STATE = 9,
				RTB_ON_OUT_OF_AMMO = 10,
				ECM_USING = 13,
				PROHIBIT_AA = 14,
				PROHIBIT_JETT = 15,
				PROHIBIT_AB = 16,
				PROHIBIT_AG = 17,
				MISSILE_ATTACK = 18,
				PROHIBIT_WP_PASS_REPORT = 19,
				-- Removed unsupported: PROHIBIT_WP_PASS_REPORT2, DISPERSAL_ON_ATTACK
			},
			val = {
				ROE = {
					WEAPON_FREE = 0,
					OPEN_FIRE_WEAPON_FREE = 1,
					OPEN_FIRE = 2,
					RETURN_FIRE = 3,
					WEAPON_HOLD = 4,
				},
				REACTION_ON_THREAT = {
					NO_REACTION = 0,
					PASSIVE_DEFENCE = 1,
					EVADE_FIRE = 2,
					BYPASS_AND_ESCAPE = 3,
					ALLOW_ABORT_MISSION = 4,
				},
				MISSILE_ATTACK = {
					MAX_RANGE = 0,
					NEZ_RANGE = 1,
					HALF_WAY_RMAX_NEZ = 2,
					TARGET_THREAT_EST = 3,
					RANDOM_RANGE = 4,
				},
			},
		},
		Ground = {
			id = {
				ALARM_STATE = 9,
				ROE = 0,
				DISPERSE_ON_ATTACK = 8,
			},
			val = {
				ALARM_STATE = {
					AUTO = 0,
					GREEN = 1,
					RED = 2,
				},
				ROE = {
					OPEN_FIRE = 2,
					RETURN_FIRE = 3,
					WEAPON_HOLD = 4,
				},
			},
		},
		Naval = {
			id = {
				ROE = 0,
			},
			val = {
				ROE = {
					OPEN_FIRE = 2,
					RETURN_FIRE = 3,
					WEAPON_HOLD = 4,
				},
			},
		},
	},
	Skill = {
		AVERAGE = "Average",
		GOOD = "Good",
		HIGH = "High",
		EXCELLENT = "Excellent",
		RANDOM = "Random",
	},
}

-- Sensor Constants
Sensor = {
	RADAR = 1,
	IRST = 2,
	OPTIC = 3,
	RWR = 4,
}

-- Spot API
Spot = {
	createLaser = function(source, spotType, code)
		return {
			destroy = function(self)
				return true
			end,
			getPoint = function(self)
				return { x = 100, y = 0, z = 200 }
			end,
			setPoint = function(self, point)
				return true
			end,
			getCode = function(self)
				return 1688
			end,
			setCode = function(self, code)
				return true
			end,
			isExist = function(self)
				return true
			end,
			getCategory = function(self)
				return 0, 0
			end,
		}
	end,
	createInfraRed = function(source, target)
		return {
			destroy = function(self)
				return true
			end,
			getPoint = function(self)
				return { x = 100, y = 0, z = 200 }
			end,
			setPoint = function(self, point)
				return true
			end,
			isExist = function(self)
				return true
			end,
			getCategory = function(self)
				return 0, 1
			end,
		}
	end,
	LaserSpotType = {
		LASER = 0,
	},
	Category = {
		LASER = 0,
		INFRARED = 1,
	},
}

-- Initialize random seed
math.randomseed(os.time())

-- Return as a module for require consumers while keeping globals available
return {
	env = env,
	timer = timer,
	land = land,
	coord = coord,
	trigger = trigger,
	Unit = Unit,
	Group = Group,
	coalition = coalition,
	atmosphere = atmosphere,
	Airbase = Airbase,
	missionCommands = missionCommands,
	world = world,
	country = country,
	Object = Object,
	StaticObject = StaticObject,
	Weapon = Weapon,
	Controller = Controller,
	AI = AI,
	Sensor = Sensor,
	Spot = Spot,
}
