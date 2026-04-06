--- DCS Harness — LuaLS type stubs (auto-generated)
--- Add this file's parent directory to workspace.library in .luarc.json
--- Do not edit by hand; regenerate with:
---   python build/scripts/export_harness_luacats.py

---@class EventBus
---@field _subscribers table<any, table> Map of topicKey -> array of subscriber records
---@field _nextSubId number
---@field _keySelector fun(event: table): any

---@class HarnessWorldEventBus : EventBus
---@field _handler table

---@class GeoGridLocation
---@field cx integer
---@field cz integer
---@field type string
---@field bucket string
---@field p { x: number, y: number, z: number }

---@class GeoGrid
---@field grid table<integer, table<integer, table<string, table<any, boolean>>>>
---@field idx table<any, GeoGridLocation>
---@field cell number
---@field types table<string, boolean>
---@field minX number
---@field minZ number
---@field maxX number
---@field maxZ number
---@field count integer
---@field has_bounds boolean
---@field add fun(self: GeoGrid, entityType: string, entityId: any, pos: { x: number, y: number|nil, z: number }): boolean
---@field remove fun(self: GeoGrid, entityId: any): boolean
---@field updatePosition fun(self: GeoGrid, entityId: any, pos: { x: number, y: number|nil, z: number }, defaultType?: string): boolean
---@field move fun(self: GeoGrid, entityId: any, pos: { x: number, y: number|nil, z: number }): boolean, table|nil, table|nil
---@field changeType fun(self: GeoGrid, entityId: any, newType: string): boolean
---@field queryRadius fun(self: GeoGrid, pos: { x: number, y: number|nil, z: number }, radius: number, types: string[]): table<string, table<any, boolean>>
---@field clear fun(self: GeoGrid)
---@field size fun(self: GeoGrid): integer
---@field has fun(self: GeoGrid, id: any): boolean
---@field toTable fun(self: GeoGrid): table
---@field fromTable fun(self: GeoGrid, t: table): boolean

---@class Logger
---@field namespace string
---@field info fun(message: string, caller?: string)
---@field warn fun(message: string, caller?: string)
---@field error fun(message: string, caller?: string)
---@field debug fun(message: string, caller?: string)

---@class HarnessInternal
---@field loggers table<string, Logger>
---@field defaultNamespace string

--- Get airbase by name
---@param airbaseName string? Name of the airbase
---@return table? airbase Airbase object if found, nil otherwise
---@usage local airbase = getAirbaseByName("Batumi")
function GetAirbaseByName(airbaseName) end

--- Get airbase descriptor
---@param airbase table? Airbase object
---@return table? descriptor Airbase descriptor if found, nil otherwise
---@usage local desc = getAirbaseDescriptor(airbase)
function GetAirbaseDescriptor(airbase) end

--- Get airbase callsign
---@param airbase table? Airbase object
---@return string? callsign Airbase callsign if found, nil otherwise
---@usage local callsign = getAirbaseCallsign(airbase)
function GetAirbaseCallsign(airbase) end

--- Get airbase unit
---@param airbase table? Airbase object
---@return table? unit Airbase unit if found, nil otherwise
---@usage local unit = getAirbaseUnit(airbase)
function GetAirbaseUnit(airbase, unitIndex) end

--- Get airbase category name
---@param airbase table? Airbase object
---@return string? category Category name if found, nil otherwise
---@usage local category = getAirbaseCategoryName(airbase)
function GetAirbaseCategoryName(airbase) end

--- Get airbase parking information
---@param airbase table? Airbase object
---@param available boolean? If true, only return available parking spots
---@return table? parking Parking information if found, nil otherwise
---@usage local parking = getAirbaseParking(airbase, true)
function GetAirbaseParking(airbase, available) end

--- Get airbase runways
---@param airbase table? Airbase object
---@return table? runways Runway information if found, nil otherwise
---@usage local runways = getAirbaseRunways(airbase)
function GetAirbaseRunways(airbase) end

--- Get airbase tech object positions
---@param airbase table? Airbase object
---@param techObjectType number Tech object type ID
---@return table? positions Tech object positions if found, nil otherwise
---@usage local positions = getAirbaseTechObjectPos(airbase, 1)
function GetAirbaseTechObjectPos(airbase, techObjectType) end

--- Get airbase dispatcher tower position
---@param airbase table? Airbase object
---@return table? position Tower position if found, nil otherwise
---@usage local towerPos = getAirbaseDispatcherTowerPos(airbase)
function GetAirbaseDispatcherTowerPos(airbase) end

--- Get airbase radio silent mode
---@param airbase table? Airbase object
---@return boolean? silent True if radio silent, nil on error
---@usage local isSilent = getAirbaseRadioSilentMode(airbase)
function GetAirbaseRadioSilentMode(airbase) end

--- Set airbase radio silent mode
---@param airbase table? Airbase object
---@param silent boolean Radio silent mode
---@return boolean? success True if set successfully, nil on error
---@usage SetAirbaseRadioSilentMode(airbase, true)
function SetAirbaseRadioSilentMode(airbase, silent) end

--- Get airbase beacon information
---@param airbase table? Airbase object
---@return table? beacon Beacon information if found, nil otherwise
---@usage local beacon = getAirbaseBeacon(airbase)
function GetAirbaseBeacon(airbase) end

--- Set airbase auto capture mode
---@param airbase table? Airbase object
---@param enabled boolean Auto capture enabled
---@return boolean? success True if set successfully, nil on error
---@usage AirbaseAutoCapture(airbase, true)
function AirbaseAutoCapture(airbase, enabled) end

--- Check if airbase auto capture is enabled
---@param airbase table? Airbase object
---@return boolean? enabled True if auto capture is on, nil on error
---@usage local isOn = airbaseAutoCaptureIsOn(airbase)
function AirbaseAutoCaptureIsOn(airbase) end

--- Set airbase coalition
---@param airbase table? Airbase object
---@param coalitionId number Coalition ID
---@return boolean? success True if set successfully, nil on error
---@usage SetAirbaseCoalition(airbase, coalition.side.BLUE)
function SetAirbaseCoalition(airbase, coalitionId) end

--- Get airbase warehouse
---@param airbase table? Airbase object
---@return table? warehouse Warehouse object if found, nil otherwise
---@usage local warehouse = getAirbaseWarehouse(airbase)
function GetAirbaseWarehouse(airbase) end

--- Get free parking terminal
---@param airbase table? Airbase object
---@param terminalType any? Terminal type filter
---@return table? terminal Free parking terminal if found, nil otherwise
---@usage local terminal = getAirbaseFreeParkingTerminal(airbase)
function GetAirbaseFreeParkingTerminal(airbase, terminalType) end

--- Get free parking terminals by type
---@param airbase table? Airbase object
---@param terminalType any? Terminal type filter
---@param multiple boolean? Return multiple terminals
---@return table? terminals Free parking terminals if found, nil otherwise
---@usage local terminals = getAirbaseFreeParkingTerminalByType(airbase, type, true)
function GetAirbaseFreeParkingTerminalByType(airbase, terminalType, multiple) end

--- Get free airbase parking terminal
---@param airbase table? Airbase object
---@param terminalType any? Terminal type filter
---@return table? terminal Free parking terminal if found, nil otherwise
---@usage local terminal = getFreeAirbaseParkingTerminal(airbase)
function GetFreeAirbaseParkingTerminal(airbase, terminalType) end

--- Get airbase parking terminal
---@param airbase table? Airbase object
---@param terminal number Terminal number
---@return table? terminal Parking terminal if found, nil otherwise
---@usage local terminal = getAirbaseParkingTerminal(airbase, 1)
function GetAirbaseParkingTerminal(airbase, terminal) end

--- Get airbase parking terminal by index
---@param airbase table? Airbase object
---@param index number Terminal index
---@return table? terminal Parking terminal if found, nil otherwise
---@usage local terminal = getAirbaseParkingTerminalByIndex(airbase, 1)
function GetAirbaseParkingTerminalByIndex(airbase, index) end

--- Get airbase parking count
---@param airbase table? Airbase object
---@return number? count Number of parking spots, nil on error
---@usage local count = getAirbaseParkingCount(airbase)
function GetAirbaseParkingCount(airbase) end

--- Get airbase runway details
---@param airbase table? Airbase object
---@param runwayIndex number? Specific runway index
---@return table? details Runway details if found, nil otherwise
---@usage local details = getAirbaseRunwayDetails(airbase, 1)
function GetAirbaseRunwayDetails(airbase, runwayIndex) end

--- Get airbase meteorological data
---@param airbase table? Airbase object
---@param height number? Height for weather data
---@return table? meteo Weather data if found, nil otherwise
---@usage local weather = getAirbaseMeteo(airbase, 100)
function GetAirbaseMeteo(airbase, height) end

--- Get airbase wind with turbulence
---@param airbase table? Airbase object
---@param height number? Height for wind data
---@return table? wind Wind data with turbulence if found, nil otherwise
---@usage local wind = getAirbaseWindWithTurbulence(airbase, 100)
function GetAirbaseWindWithTurbulence(airbase, height) end

--- Check if airbase provides service
---@param airbase table? Airbase object
---@param service number Service type ID
---@return boolean? provided True if service is provided, nil on error
---@usage local hasService = getAirbaseIsServiceProvided(airbase, 1)
function GetAirbaseIsServiceProvided(airbase, service) end

--- Get wind at a specific point
---@param point table? Vec3 position {x, y, z}
---@return table? wind Wind vector if successful, nil otherwise
---@usage local wind = GetWind(position)
function GetWind(point) end

--- Get wind with turbulence at a specific point
---@param point table? Vec3 position {x, y, z}
---@return table? wind Wind vector with turbulence if successful, nil otherwise
---@usage local wind = GetWindWithTurbulence(position)
function GetWindWithTurbulence(point) end

--- Get temperature and pressure at a specific point
---@param point table? Vec3 position {x, y, z}
---@return table? data Table with standardized fields if successful, nil otherwise
---        data.temperatureK number   -- Temperature in Kelvin (raw from DCS)
---        data.temperatureC number   -- Temperature in Celsius
---        data.pressurePa number     -- Pressure in Pascals (raw from DCS)
---        data.pressurehPa number    -- Pressure in hPa (millibars)
---        data.pressureInHg number   -- Pressure in inches of mercury
---@usage local data = GetTemperatureAndPressure(position)
function GetTemperatureAndPressure(point) end

--- Get wind (no turbulence) with heading and speed in knots
---@param point table Vec3 position {x, y, z}
---@return table? data { headingDeg, speedKts, vector }
---@usage local w = GetWindKnots(p) -- w.headingDeg, w.speedKts
function GetWindKnots(point) end

--- Get wind with turbulence, returning heading and speed in knots
---@param point table Vec3 position {x, y, z}
---@return table? data { headingDeg, speedKts, vector }
---@usage local w = GetWindWithTurbulenceKnots(p)
function GetWindWithTurbulenceKnots(point) end

--- Get temperature in Celsius at a point
---@param point table Vec3 position {x, y, z}
---@return number? celsius Temperature in °C or nil on error
function GetTemperatureC(point) end

--- Get temperature in Fahrenheit at a point
---@param point table Vec3 position {x, y, z}
---@return number? fahrenheit Temperature in °F or nil on error
function GetTemperatureF(point) end

--- Get pressure in inches of mercury at a point
---@param point table Vec3 position {x, y, z}
---@return number? inHg Pressure in inHg or nil on error
function GetPressureInHg(point) end

--- Get pressure in hectoPascals at a point
---@param point table Vec3 position {x, y, z}
---@return number? hPa Pressure in hPa or nil on error
function GetPressurehPa(point) end

--- Clear all caches
---@usage ClearAllCaches()
function ClearAllCaches() end

--- Clear unit cache
---@usage ClearUnitCache()
function ClearUnitCache() end

--- Clear group cache
---@usage ClearGroupCache()
function ClearGroupCache() end

--- Clear controller cache
---@usage ClearControllerCache()
function ClearControllerCache() end

--- Remove specific unit from cache
---@param unitName string Unit name
---@usage RemoveUnitFromCache("Pilot-1")
function RemoveUnitFromCache(unitName) end

--- Remove specific group from cache
---@param groupName string Group name
---@usage RemoveGroupFromCache("Blue Squadron")
function RemoveGroupFromCache(groupName) end

--- Get cache statistics
---@return table stats Cache statistics
---@usage local stats = GetCacheStats()
function GetCacheStats() end

--- Set cache configuration
---@param config table Configuration options
---@usage SetCacheConfig({maxUnits = 2000, ttl = 600})
function SetCacheConfig(config) end

--- Get direct access to cache tables (for advanced users)
---@return table caches All cache tables
---@usage local caches = GetCacheTables()
function GetCacheTables() end

--- Create a cached version of a function that returns DCS objects
---@param func function The function to cache
---@param getCacheKey function Function that generates cache key from arguments
---@param cacheType string Cache type: "unit", "group", "controller", or "generic"
---@param verifyFunc function? Optional function to verify cached object is still valid
---@return function cached Cached version of the function
---@usage local cachedGetUnit = CacheDecorator(Unit.getByName, function(name) return name end, "unit")
function CacheDecorator(func, getCacheKey, cacheType, verifyFunc) end

--- Get cached unit (convenience function for external users)
---@param unitName string Unit name
---@return table? unit Cached unit or nil
---@usage local unit = GetCachedUnit("Pilot-1")
function GetCachedUnit(unitName) end

--- Get cached group (convenience function for external users)
---@param groupName string Group name
---@return table? group Cached group or nil
---@usage local group = GetCachedGroup("Blue Squadron")
function GetCachedGroup(groupName) end

--- Get cached controller (convenience function for external users)
---@param key string Cache key
---@return table? controller Cached controller or nil
---@usage local controller = GetCachedController("unit:Pilot-1")
function GetCachedController(key) end

--- Build a unit entry for use in GroupSpawnData
--- @param typeName string DCS unit type name (e.g., "F-15C", "M-1 Abrams")
--- @param unitName string Unique unit name
--- @param posX number 2D map X coordinate (meters)
--- @param posY number 2D map Y coordinate (meters)
--- @param altitude number Altitude in meters AGL/MSL per alt_type
--- @param heading number Heading in radians (0 = east, math.pi/2 = north)
--- @param opts table|nil Optional overrides: { skill, payload, callsign, onboard_num, alt_type, psi }
--- @return table|nil unit Unit table suitable for GroupSpawnData or nil on error
function BuildUnitEntry(typeName, unitName, posX, posY, altitude, heading, opts) end

--- Build a standard Turning Point waypoint
--- @param x number 2D map X coordinate (meters)
--- @param y number 2D map Y coordinate (meters)
--- @param altitude number Altitude in meters
--- @param speed number Speed in m/s
--- @param tasks table|nil Optional array of task entries to attach (ComboTask)
--- @return table waypoint Waypoint table
function BuildWaypoint(x, y, altitude, speed, tasks) end

--- Build a route table for GroupSpawnData
--- @param waypoints table Array of waypoint tables (from BuildWaypoint or compatible)
--- @param opts table|nil Optional overrides: none currently, reserved for future
--- @return table route Route table with points array
function BuildRoute(waypoints, opts) end

--- Build a GroupSpawnData table
--- @param groupName string Unique group name
--- @param task string Group task (e.g., "CAP", "Ground Nothing")
--- @param units table Array of unit tables (from BuildUnitEntry or compatible)
--- @param routePoints table|nil Array of waypoint tables; if nil, an empty route is used
--- @param opts table|nil Optional overrides: { visible, taskSelected, communication, start_time, frequency, modulation }
--- @return table|nil groupData GroupSpawnData or nil on error
function BuildGroupData(groupName, task, units, routePoints, opts) end

--- Get the coalition ID for a given country
--- @param countryId number The country ID to query
--- @return number|nil coalitionId The coalition ID (0=neutral, 1=red, 2=blue) or nil on error
--- @usage local coalition = getCoalitionByCountry(country.id.USA)
function GetCoalitionByCountry(countryId) end

--- Get all players (clients) in a coalition
--- @param coalitionId number The coalition ID (1=red, 2=blue)
--- @return table|nil players Array of player units or nil on error
--- @usage local bluePlayers = getCoalitionPlayers(coalition.side.BLUE)
function GetCoalitionPlayers(coalitionId) end

--- Get all groups in a coalition, optionally filtered by category
--- @param coalitionId number The coalition ID (1=red, 2=blue)
--- @param categoryId number|nil Optional category filter (0=airplane, 1=helicopter, 2=ground, 3=ship, 4=structure)
--- @return table|nil groups Array of group objects or nil on error
--- @usage local redGroundGroups = getCoalitionGroups(coalition.side.RED, Group.Category.GROUND)
function GetCoalitionGroups(coalitionId, categoryId) end

--- Get all airbases controlled by a coalition
--- @param coalitionId number The coalition ID (0=neutral, 1=red, 2=blue)
--- @return table|nil airbases Array of airbase objects or nil on error
--- @usage local blueAirbases = getCoalitionAirbases(coalition.side.BLUE)
function GetCoalitionAirbases(coalitionId) end

--- Get all countries in a coalition
--- @param coalitionId number The coalition ID (1=red, 2=blue)
--- @return table|nil countries Array of country IDs or nil on error
--- @usage local redCountries = getCoalitionCountries(coalition.side.RED)
function GetCoalitionCountries(coalitionId) end

--- Get all static objects belonging to a coalition
--- @param coalitionId number The coalition ID (0=neutral, 1=red, 2=blue)
--- @return table|nil staticObjects Array of static object references or nil on error
--- @usage local blueStatics = getCoalitionStaticObjects(coalition.side.BLUE)
function GetCoalitionStaticObjects(coalitionId) end

--- Add a new group to the mission for a specific country
--- @param countryId number The country ID that will own the group
--- @param categoryId number The category ID (0=airplane, 1=helicopter, 2=ground, 3=ship)
--- @param groupData table The group definition table with units, route, etc.
--- @return table|nil group The created group object or nil on error
--- @usage local newGroup = addCoalitionGroup(country.id.USA, Group.Category.AIRPLANE, groupDefinition)
function AddCoalitionGroup(countryId, categoryId, groupData) end

--- Add a new static object to the mission for a specific country
--- @param countryId number The country ID that will own the static object
--- @param staticData table The static object definition table
--- @return table|nil staticObject The created static object or nil on error
--- @usage local newStatic = addCoalitionStaticObject(country.id.USA, staticDefinition)
function AddCoalitionStaticObject(countryId, staticData) end

--- Get all reference points for a coalition
--- @param coalitionId number The coalition ID (1=red, 2=blue)
--- @return table|nil refPoints Table of reference points or nil on error
--- @usage local blueRefPoints = getCoalitionRefPoints(coalition.side.BLUE)
function GetCoalitionRefPoints(coalitionId) end

--- Get the main reference point (bullseye) for a coalition
--- @param coalitionId number The coalition ID (1=red, 2=blue)
--- @return table|nil refPoint The main reference point with x, y, z coordinates or nil on error
--- @usage local blueBullseye = getCoalitionMainRefPoint(coalition.side.BLUE)
function GetCoalitionMainRefPoint(coalitionId) end

--- Get the bullseye coordinates for a coalition
--- @param coalitionId number The coalition ID (1=red, 2=blue)
--- @return table|nil bullseye The bullseye position with x, y, z coordinates or nil on error
--- @usage local redBullseye = getCoalitionBullseye(coalition.side.RED)
function GetCoalitionBullseye(coalitionId) end

--- Add a reference point for a coalition
--- @param coalitionId number The coalition ID (1=red, 2=blue)
--- @param refPointData table The reference point data table
--- @return table|nil refPoint The created reference point or nil on error
--- @usage local newRefPoint = addCoalitionRefPoint(coalition.side.BLUE, {callsign = "ALPHA", x = 100000, y = 0, z = 200000})
function AddCoalitionRefPoint(coalitionId, refPointData) end

--- Remove a reference point from a coalition
--- @param coalitionId number The coalition ID (1=red, 2=blue)
--- @param refPointId number|string The reference point ID to remove
--- @return boolean|nil success True if removed successfully, nil on error
--- @usage RemoveCoalitionRefPoint(coalition.side.BLUE, "ALPHA")
function RemoveCoalitionRefPoint(coalitionId, refPointId) end

--- Get service providers (tankers, AWACS, etc.) for a coalition
--- @param coalitionId number The coalition ID (1=red, 2=blue)
--- @param serviceType number The service type to query
--- @return table|nil providers Array of units providing the service or nil on error
--- @usage local blueTankers = getCoalitionServiceProviders(coalition.side.BLUE, coalition.service.TANKER)
function GetCoalitionServiceProviders(coalitionId, serviceType) end

--- Get controller domain from cache metadata if available
---@param controller table Controller object
---@return string? domain "Air"|"Ground"|"Naval" if known
function GetControllerDomain(controller) end

--- Enum aliases for tooltip-friendly options
---@alias ROEAir "WEAPON_FREE"|"OPEN_FIRE_WEAPON_FREE"|"OPEN_FIRE"|"RETURN_FIRE"|"WEAPON_HOLD"
---@alias ROEGround "OPEN_FIRE"|"RETURN_FIRE"|"WEAPON_HOLD"
---@alias ROENaval "OPEN_FIRE"|"RETURN_FIRE"|"WEAPON_HOLD"
---@alias ReactionOnThreat "NO_REACTION"|"PASSIVE_DEFENCE"|"EVADE_FIRE"|"BYPASS_AND_ESCAPE"|"ALLOW_ABORT_MISSION"
---@alias MissileAttackMode "MAX_RANGE"|"NEZ_RANGE"|"HALF_WAY_RMAX_NEZ"|"TARGET_THREAT_EST"|"RANDOM_RANGE"
---@alias AlarmState "AUTO"|"GREEN"|"RED"
--- Sets a task for the controller
---@param controller table The controller object
---@param task table The task table to set
---@return boolean? success Returns true if successful, nil on error
---@usage SetControllerTask(controller, {id="Mission", params={...}})
function SetControllerTask(controller, task) end

--- Resets the controller's current task
---@param controller table The controller object
---@return boolean? success Returns true if successful, nil on error
---@usage ResetControllerTask(controller)
function ResetControllerTask(controller) end

--- Pushes a task onto the controller's task queue
---@param controller table The controller object
---@param task table The task table to push
---@return boolean? success Returns true if successful, nil on error
---@usage PushControllerTask(controller, {id="EngageTargets", params={...}})
function PushControllerTask(controller, task) end

--- Pops a task from the controller's task queue
---@param controller table The controller object
---@return boolean? success Returns true if successful, nil on error
---@usage PopControllerTask(controller)
function PopControllerTask(controller) end

--- Checks if the controller has any tasks
---@param controller table The controller object
---@return boolean? hasTask Returns true if controller has tasks, false if not, nil on error
---@usage local hasTasks = hasControllerTask(controller)
function HasControllerTask(controller) end

--- Sets a command for the controller
---@param controller table The controller object
---@param command table The command table to set
---@return boolean? success Returns true if successful, nil on error
---@usage SetControllerCommand(controller, {id="Script", params={...}})
function SetControllerCommand(controller, command) end

--- Enables or disables the controller
---@param controller table The controller object
---@param onOff boolean True to enable, false to disable
---@return boolean? success Returns true if successful, nil on error
---@usage SetControllerOnOff(controller, false)
function SetControllerOnOff(controller, onOff) end

--- Sets the altitude for the controller
---@param controller table The controller object
---@param altitude number The altitude in meters
---@param keep boolean? If true, keep this altitude across waypoints
---@param altType string? Altitude type: "BARO" or "RADIO"
---@return boolean? success Returns true if successful, nil on error
---@usage SetControllerAltitude(controller, 5000, true, "BARO")
function SetControllerAltitude(controller, altitude, keep, altType) end

--- Sets the speed for the controller
---@param controller table The controller object
---@param speed number The speed in m/s
---@param keep boolean? If true, keep this speed across waypoints
---@return boolean? success Returns true if successful, nil on error
---@usage SetControllerSpeed(controller, 250, true)
function SetControllerSpeed(controller, speed, keep) end

--- Sets an option for the controller
---@param controller table The controller object
---@param optionId number The option ID
---@param optionValue any The value to set for the option
---@return boolean? success Returns true if successful, nil on error
---@usage SetControllerOption(controller, 0, AI.Option.Air.val.ROE.WEAPON_FREE)
function SetControllerOption(controller, optionId, optionValue) end

--- Convenience setters for common controller options
---@param controller table Controller object
---@param value integer|ROEAir|ROEGround|ROENaval ROE value or name
---@return boolean? success Returns true on success, nil on error
function ControllerSetROE(controller, value) end

--- Set AI reaction on threat
---@param controller table Controller object
---@param value integer|ReactionOnThreat Reaction value or name (e.g. "EVADE_FIRE")
---@return boolean? success Returns true on success, nil on error
function ControllerSetReactionOnThreat(controller, value) end

--- Set radar usage policy
---@param controller table Controller object
---@param value number Radar usage enum (AI.Option.Air.val.RADAR_USING.*)
---@return boolean? success Returns true on success, nil on error
function ControllerSetRadarUsing(controller, value) end

--- Set flare usage policy
---@param controller table Controller object
---@param value number Flare usage enum (AI.Option.Air.val.FLARE_USING.*)
---@return boolean? success Returns true on success, nil on error
function ControllerSetFlareUsing(controller, value) end

--- Set formation
---@param controller table Controller object
---@param value number Formation enum (AI.Option.Air.val.FORMATION.*)
---@return boolean? success Returns true on success, nil on error
function ControllerSetFormation(controller, value) end

--- Enable/disable RTB on bingo
---@param controller table Controller object
---@param value boolean
---@return boolean? success Returns true on success, nil on error
function ControllerSetRTBOnBingo(controller, value) end

--- Enable/disable radio silence
---@param controller table Controller object
---@param value boolean
---@return boolean? success Returns true on success, nil on error
function ControllerSetSilence(controller, value) end

--- Set alarm state
---@param controller table Controller object
---@param value integer|AlarmState Alarm state value or name (e.g. "RED")
---@return boolean? success Returns true on success, nil on error
function ControllerSetAlarmState(controller, value) end

--- Enable/disable ground disperse on attack
---@param controller table Controller object
---@param seconds number Dispersal time in seconds (0 disables)
---@return boolean? success Returns true on success, nil on error
---@usage ControllerSetDisperseOnAttack(controller, 120)
function ControllerSetDisperseOnAttack(controller, seconds) end

--- Enable/disable RTB on out of ammo
---@param controller table Controller object
---@param value boolean
---@return boolean? success Returns true on success, nil on error
function ControllerSetRTBOnOutOfAmmo(controller, value) end

--- Set ECM usage policy
---@param controller table Controller object
---@param value number ECM usage enum (AI.Option.Air.val.ECM_USING.*)
---@return boolean? success Returns true on success, nil on error
function ControllerSetECMUsing(controller, value) end

--- Enable/disable waypoint pass report (ID 14)
---@param controller table Controller object
---@param value boolean
---@return boolean? success Returns true on success, nil on error
function ControllerSetProhibitWPPassReport(controller, value) end

--- Enable/disable prohibit air-to-air
---@param controller table Controller object
---@param value boolean
---@return boolean? success Returns true on success, nil on error
function ControllerSetProhibitAA(controller, value) end

--- Enable/disable prohibit jettison
---@param controller table Controller object
---@param value boolean
---@return boolean? success Returns true on success, nil on error
function ControllerSetProhibitJettison(controller, value) end

--- Enable/disable prohibit afterburner
---@param controller table Controller object
---@param value boolean
---@return boolean? success Returns true on success, nil on error
function ControllerSetProhibitAB(controller, value) end

--- Enable/disable prohibit air-to-ground
---@param controller table Controller object
---@param value boolean
---@return boolean? success Returns true on success, nil on error
function ControllerSetProhibitAG(controller, value) end

--- Set missile attack policy
---@param controller table Controller object
---@param value integer|MissileAttackMode Missile attack enum or name
---@return boolean? success Returns true on success, nil on error
---@usage ControllerSetMissileAttack(controller, "NEZ_RANGE")
function ControllerSetMissileAttack(controller, value) end

--- Gets targets detected by the controller
---@param controller table The controller object
---@param detectionType any? Optional detection type filter
---@param categoryFilter any? Optional category filter
---@return table? targets Array of detected target objects or nil on error
---@usage local targets = getControllerDetectedTargets(controller)
function GetControllerDetectedTargets(controller, detectionType, categoryFilter) end

--- Makes the controller aware of a target
---@param controller table The controller object
---@param target table The target object
---@param typeKnown boolean? Whether the target type is known
---@param distanceKnown boolean? Whether the target distance is known
---@return boolean? success Returns true if successful, nil on error
---@usage KnowControllerTarget(controller, targetUnit, true, true)
function KnowControllerTarget(controller, target, typeKnown, distanceKnown) end

--- Checks if a target is detected by the controller
---@param controller table The controller object
---@param target table The target object to check
---@param detectionType any? Optional detection type
---@return boolean? isDetected Returns detection status or nil on error
---@usage local detected = isControllerTargetDetected(controller, targetUnit)
function IsControllerTargetDetected(controller, target, detectionType) end

--- Build an AI.Option task entry for Air domain
--- @param optionId number AI.Option.Air.id.* value
--- @param value number|boolean Enum or boolean as required by option
--- @return table taskEntry Option task entry suitable for waypoint ComboTask
function BuildAirOptionTask(optionId, value) end

--- Build an AI.Option task entry for Ground domain
--- @param optionId number AI.Option.Ground.id.* value
--- @param value number|boolean Enum or boolean as required by option
--- @return table taskEntry Option task entry suitable for waypoint ComboTask
function BuildGroundOptionTask(optionId, value) end

--- Build an AI.Option task entry for Naval domain
--- @param optionId number AI.Option.Naval.id.* value
--- @param value number|boolean Enum or boolean as required by option
--- @return table taskEntry Option task entry suitable for waypoint ComboTask
function BuildNavalOptionTask(optionId, value) end

--- Build a standard set of Air AI options as an array of Option tasks
--- @param overrides table|nil Optional overrides by key (e.g., { ROE = "WEAPON_FREE", RADAR_USING = 1 })
--- @return table tasks Array of Option task tables
function BuildAirOptions(overrides) end

--- Build a standard set of Ground AI options as an array of Option tasks
--- @param overrides table|nil Optional overrides (e.g., { ROE = "OPEN_FIRE", ALARM_STATE = "GREEN", DISPERSE_ON_ATTACK = 120 })
--- @return table tasks Array of Option task tables
function BuildGroundOptions(overrides) end

--- Build a standard set of Naval AI options as an array of Option tasks
--- @param overrides table|nil Optional overrides (e.g., { ROE = "OPEN_FIRE" })
--- @return table tasks Array of Option task tables
function BuildNavalOptions(overrides) end

--- Creates an orbit task for aircraft
---@param pattern string? Orbit pattern (default: "Circle")
---@param point table Position to orbit around
---@param altitude number Orbit altitude in meters
---@param speed number Orbit speed in m/s
---@param taskParams table? Additional task parameters
---@return table task The orbit task table
---@usage local task = createOrbitTask("Circle", {x=1000, y=0, z=2000}, 5000, 250)
function CreateOrbitTask(pattern, point, altitude, speed, taskParams) end

--- Creates a follow task to follow another group
---@param groupId number The ID of the group to follow
---@param position table? Relative position offset (default: {x=50, y=0, z=50})
---@param lastWaypointIndex number? Last waypoint index to follow to
---@return table? task The follow task table or nil on error
---@usage local task = createFollowTask(1001, {x=100, y=0, z=100})
function CreateFollowTask(groupId, position, lastWaypointIndex) end

--- Creates an escort task to escort another group
---@param groupId number The ID of the group to escort
---@param position table? Relative position offset (default: {x=50, y=0, z=50})
---@param lastWaypointIndex number? Last waypoint index to escort to
---@param engagementDistance number? Maximum engagement distance (default: 60000)
---@return table? task The escort task table or nil on error
---@usage local task = createEscortTask(1001, {x=200, y=0, z=0}, nil, 30000)
function CreateEscortTask(groupId, position, lastWaypointIndex, engagementDistance) end

--- Creates an attack group task
---@param groupId number The ID of the group to attack
---@param weaponType any? Weapon type to use
---@param groupAttack boolean? Whether to attack as a group (default: true)
---@param altitude number? Attack altitude
---@param attackQty number? Number of attacks
---@param direction number? Attack direction
---@return table? task The attack group task table or nil on error
---@usage local task = createAttackGroupTask(2001, nil, true)
function CreateAttackGroupTask(groupId, weaponType, groupAttack, altitude, attackQty, direction) end

--- Creates an attack unit task
---@param unitId number The ID of the unit to attack
---@param weaponType any? Weapon type to use
---@param groupAttack boolean? Whether to attack as a group (default: false)
---@param altitude number? Attack altitude
---@param attackQty number? Number of attacks
---@param direction number? Attack direction
---@return table? task The attack unit task table or nil on error
---@usage local task = createAttackUnitTask(3001)
function CreateAttackUnitTask(unitId, weaponType, groupAttack, altitude, attackQty, direction) end

--- Creates a bombing task for a specific point
---@param point table Target position with x, y, z coordinates
---@param weaponType any? Weapon type to use
---@param groupAttack boolean? Whether to attack as a group (default: false)
---@param altitude number? Attack altitude
---@param attackQty number? Number of attacks
---@param direction number? Attack direction
---@return table? task The bombing task table or nil on error
---@usage local task = createBombingTask({x=1000, y=0, z=2000})
function CreateBombingTask(point, weaponType, groupAttack, altitude, attackQty, direction) end

--- Creates a bombing runway task
---@param runwayId number The runway ID to attack
---@param weaponType any? Weapon type to use
---@param groupAttack boolean? Whether to attack as a group (default: false)
---@param altitude number? Attack altitude
---@param attackQty number? Number of attacks
---@param direction number? Attack direction
---@return table? task The bombing runway task table or nil on error
---@usage local task = createBombingRunwayTask(1)
function CreateBombingRunwayTask(runwayId, weaponType, groupAttack, altitude, attackQty, direction) end

--- Creates a land task at a specific point
---@param point table Landing position with x, y, z coordinates
---@param durationFlag boolean? Whether to use duration (default: false)
---@param duration number? Duration of landing in seconds
---@return table? task The land task table or nil on error
---@usage local task = createLandTask({x=1000, y=0, z=2000}, true, 300)
function CreateLandTask(point, durationFlag, duration) end

--- Creates a refueling task
---@return table task The refueling task table
---@usage local task = createRefuelingTask()
function CreateRefuelingTask() end

--- Creates a hold task
---@param template any? Template for holding pattern
---@return table task The hold task table
---@usage local task = createHoldTask()
function CreateHoldTask(template) end

--- Creates a go to waypoint task
---@param fromWaypointIndex number Starting waypoint index
---@param toWaypointIndex number Destination waypoint index
---@return table task The go to waypoint task table
---@usage local task = createGoToWaypointTask(1, 5)
function CreateGoToWaypointTask(fromWaypointIndex, toWaypointIndex) end

--- Creates a wrapped action task
---@param action table The action table to wrap
---@param stopFlag boolean? Whether to stop after action (default: false)
---@return table? task The wrapped action task table or nil on error
---@usage local task = createWrappedAction({id="Script", params={...}})
function CreateWrappedAction(action, stopFlag) end

--- Convert Celsius to Kelvin
---@param c number|string
---@return number
function CtoK(c) end

--- Convert Kelvin to Celsius
---@param k number|string
---@return number
function KtoC(k) end

--- Convert Celsius to Fahrenheit
---@param c number|string
---@return number
function CtoF(c) end

--- Convert Fahrenheit to Celsius
---@param f number|string
---@return number
function FtoC(f) end

--- Convert Kelvin to Fahrenheit
---@param k number|string
---@return number
function KtoF(k) end

--- Convert Fahrenheit to Kelvin
---@param f number|string
---@return number
function FtoK(f) end

--- Pascals to inches of mercury
---@param pa number|string
---@return number
function PaToInHg(pa) end

--- inches of mercury to Pascals
---@param inHg number|string
---@return number
function InHgToPa(inHg) end

--- Pascals to hectoPascals
---@param pa number|string
---@return number
function PaTohPa(pa) end

--- hectoPascals to Pascals
---@param hPa number|string
---@return number
function hPaToPa(hPa) end

--- Meters to Feet
---@param m number|string
---@return number
function MetersToFeet(m) end

--- Feet to Meters
---@param ft number|string
---@return number
function FeetToMeters(ft) end

--- Meters per second to Knots
---@param mps number|string
---@return number
function MpsToKnots(mps) end

--- Knots to meters per second
---@param knots number|string
---@return number
function KnotsToMps(knots) end

--- Airspeed (IAS) helper in knots to meters per second
---@param knots number|string
---@return number
function GetSpeedIAS(knots) end

--- Convert temperature value from one unit to another
---@param value number|string
---@param from string one of: "C","F","K"
---@param to string one of: "C","F","K"
---@return number
function ConvertTemperature(value, from, to) end

--- Convert pressure value from one unit to another
---@param value number|string
---@param from string one of: "Pa","hPa","inHg"
---@param to string one of: "Pa","hPa","inHg"
---@return number
function ConvertPressure(value, from, to) end

--- Convert distance/altitude value from one unit to another
---@param value number|string
---@param from string one of: "m","ft"
---@param to string one of: "m","ft"
---@return number
function ConvertDistance(value, from, to) end

--- Convert speed value from one unit to another
---@param value number|string
---@param from string one of: "mps","knots"
---@param to string one of: "mps","knots"
---@return number
function ConvertSpeed(value, from, to) end

--- Convert local coordinates to latitude/longitude
---@param vec3 table Vec3 position in local coordinates {x, y, z}
---@return table? latlon Table with latitude and longitude fields, nil on error
---@usage local ll = LOtoLL(position)
function LOtoLL(vec3) end

--- Convert latitude/longitude to local coordinates
---@param latitude number Latitude in degrees
---@param longitude number Longitude in degrees
---@param altitude number? Altitude in meters (default 0)
---@return table? vec3 Vec3 position in local coordinates, nil on error
---@usage local pos = LLtoLO(43.5, 41.2, 1000)
function LLtoLO(latitude, longitude, altitude) end

--- Convert local coordinates to MGRS string
---@param vec3 table Vec3 position in local coordinates {x, y, z}
---@return table? mgrs MGRS coordinate table, nil on error
---@usage local mgrs = LOtoMGRS(position)
function LOtoMGRS(vec3) end

--- Convert MGRS string to local coordinates
---@param mgrsString string MGRS coordinate string
---@return table? vec3 Vec3 position in local coordinates, nil on error
---@usage local pos = MGRStoLO("37T CK 12345 67890")
function MGRStoLO(mgrsString) end

--- Create a new Queue
---@return table queue New queue instance
---@usage local q = Queue()
function Queue() end

--- Create a new Stack
---@return table stack New stack instance
---@usage local s = Stack()
function Stack() end

--- Create a new advanced Cache with Redis-like features
---@param capacity number? Maximum number of items to cache (default: unlimited)
---@return table cache New cache instance
---@usage local cache = Cache()
function Cache(capacity) end

--- Create a memoized version of a function with LRU cache
---@param func function The function to memoize
---@param capacity number? Maximum number of cached results (default: 128)
---@param keyGenerator function? Custom key generator function(...) -> string (default: concatenate args)
---@return function memoized Memoized version of the function
---@usage local memoizedSin = Memoize(math.sin, 100)
function Memoize(func, capacity, keyGenerator) end

--- Create a new Heap (binary heap)
---@param isMinHeap boolean? True for min heap, false for max heap (default: true)
---@param compareFunc function? Custom comparison function(a, b) returns true if a should be higher
---@return table heap New heap instance
---@usage local minHeap = Heap() or local maxHeap = Heap(false)
function Heap(isMinHeap, compareFunc) end

--- Create a new Set
---@return table set New set instance
---@usage local set = Set()
function Set() end

--- Create a new Priority Queue
---@param compareFunc function? Comparison function(a, b) returns true if a has higher priority
---@return table pqueue New priority queue instance
---@usage local pq = PriorityQueue(function(a, b) return a.priority < b.priority end)
function PriorityQueue(compareFunc) end

--- Create a new RingBuffer
---@param capacity number Buffer capacity (> 0)
---@param overwrite boolean? Overwrite oldest when full (default: true)
---@return table ring New ring buffer instance
---@usage local rb = RingBuffer(3)
function RingBuffer(capacity, overwrite) end

--- Get all drawings from the mission
---@return table? drawings Table of all drawing layers and objects or nil on error
---@usage local drawings = GetDrawings()
function GetDrawings() end

--- Process drawing objects and extract geometry
---@param drawing table Drawing object to process
---@return table? geometry Processed geometry data or nil on error
function ProcessDrawingGeometry(drawing) end

--- Initialize drawing cache
---@return boolean success True if cache initialized successfully
function InitializeDrawingCache() end

--- Get all cached drawings
---@return table Array of all drawing geometries
function GetAllDrawings() end

--- Get drawing by exact name
---@param name string Drawing name
---@return table? drawing Drawing geometry or nil if not found
function GetDrawingByName(name) end

--- Find drawings by partial name
---@param pattern string Name pattern to search for
---@return table Array of matching drawing geometries
function FindDrawingsByName(pattern) end

--- Get all drawings of a specific type
---@param drawingType string Drawing type (Line, Polygon, Icon)
---@return table Array of drawing geometries of the specified type
function GetDrawingsByType(drawingType) end

--- Get all drawings in a specific layer
---@param layerName string Layer name
---@return table Array of drawing geometries in the specified layer
function GetDrawingsByLayer(layerName) end

--- Check if a point is inside a drawing shape
---@param drawing table Drawing geometry
---@param point table Point with x, z coordinates
---@return boolean isInside True if point is inside the shape
function IsPointInDrawing(drawing, point) end

--- Get units in drawing
---@param drawingName string The name of the drawing
---@param coalitionId number? Optional coalition ID to filter by (0=neutral, 1=red, 2=blue)
---@return table units Array of unit objects found in drawing
---@usage local units = GetUnitsInDrawing("Target Area", coalition.side.RED)
function GetUnitsInDrawing(drawingName, coalitionId) end

--- Get drawings containing a specific point
---@param point table Point with x, z coordinates
---@param drawingType string? Optional filter by drawing type
---@return table drawings Array of drawings containing the point
---@usage local drawings = GetDrawingsAtPoint({x=1000, z=2000})
function GetDrawingsAtPoint(point, drawingType) end

--- Clear drawing cache
function ClearDrawingCache() end

---@return table EventBus
function EventBus(keySelector) end

---@return table HarnessWorldEventBus
function CreateHarnessWorldEventBus() end

--- Initialize global HarnessWorldEventBus if not already created
function InitHarnessWorldEventBus() end

--- Get flag value
---@param flagName string? Name of the flag
---@return number value Flag value (0 if not found or error)
---@usage local value = GetFlag("myFlag")
function GetFlag(flagName) end

--- Set flag value
---@param flagName string? Name of the flag
---@param value number? Value to set (default 1)
---@return boolean success True if set successfully
---@usage SetFlag("myFlag", 5)
function SetFlag(flagName, value) end

--- Increment flag value
---@param flagName string Name of the flag
---@param amount number? Amount to increment (default 1)
---@return boolean success True if incremented successfully
---@usage IncFlag("counter", 5)
function IncFlag(flagName, amount) end

--- Decrement flag value
---@param flagName string Name of the flag
---@param amount number? Amount to decrement (default 1)
---@return boolean success True if decremented successfully
---@usage DecFlag("counter", 2)
function DecFlag(flagName, amount) end

--- Toggle flag between 0 and 1
---@param flagName string Name of the flag
---@return boolean success True if toggled successfully
---@usage ToggleFlag("switch")
function ToggleFlag(flagName) end

--- Check if flag is true (non-zero)
---@param flagName string Name of the flag
---@return boolean isTrue True if flag is non-zero
---@usage if IsFlagTrue("activated") then ... end
function IsFlagTrue(flagName) end

--- Check if flag is false (zero)
---@param flagName string Name of the flag
---@return boolean isFalse True if flag is zero
---@usage if IsFlagFalse("activated") then ... end
function IsFlagFalse(flagName) end

--- Check if flag equals value
---@param flagName string Name of the flag
---@param value number Value to compare
---@return boolean equals True if flag equals value
---@usage if FlagEquals("state", 3) then ... end
function FlagEquals(flagName, value) end

--- Check if flag is greater than value
---@param flagName string Name of the flag
---@param value number Value to compare
---@return boolean greater True if flag > value
---@usage if FlagGreaterThan("score", 100) then ... end
function FlagGreaterThan(flagName, value) end

--- Check if flag is less than value
---@param flagName string Name of the flag
---@param value number Value to compare
---@return boolean less True if flag < value
---@usage if FlagLessThan("health", 20) then ... end
function FlagLessThan(flagName, value) end

--- Check if flag is between values (inclusive)
---@param flagName string Name of the flag
---@param min number Minimum value (inclusive)
---@param max number Maximum value (inclusive)
---@return boolean between True if min <= flag <= max
---@usage if FlagBetween("temperature", 20, 30) then ... end
function FlagBetween(flagName, min, max) end

--- Set multiple flags at once
---@param flagTable table Table of flagName = value pairs
---@return boolean success True if all flags set successfully
---@usage SetFlags({flag1 = 10, flag2 = 20, flag3 = 0})
function SetFlags(flagTable) end

--- Get multiple flags at once
---@param flagNames table Array of flag names
---@return table values Table of flagName = value pairs
---@usage local vals = GetFlags({"flag1", "flag2", "flag3"})
function GetFlags(flagNames) end

--- Clear flag (set to 0)
---@param flagName string Name of the flag
---@return boolean success True if cleared successfully
---@usage ClearFlag("myFlag")
function ClearFlag(flagName) end

--- Clear multiple flags
---@param flagNames table Array of flag names to clear
---@return boolean success True if all flags cleared successfully
---@usage ClearFlags({"flag1", "flag2", "flag3"})
function ClearFlags(flagNames) end

---
---@param cellSizeMeters number|nil
---@param allowedTypes string[]
---@return GeoGrid
function GeoGrid(cellSizeMeters, allowedTypes) end

---Converts degrees to radians
---@param degrees number The angle in degrees
---@return number? radians The angle in radians, or nil if input is invalid
---@usage
--- local rad = DegToRad(90) -- Returns 1.5708 (π/2)
--- local rad2 = DegToRad(180) -- Returns 3.14159 (π)
function DegToRad(degrees) end

---Converts radians to degrees
---@param radians number The angle in radians
---@return number? degrees The angle in degrees, or nil if input is invalid
---@usage
--- local deg = RadToDeg(math.pi) -- Returns 180
--- local deg2 = RadToDeg(math.pi / 2) -- Returns 90
function RadToDeg(radians) end

---Converts nautical miles to meters
---@param nm number Distance in nautical miles
---@return number? meters Distance in meters, or nil if input is invalid
---@usage
--- local meters = NauticalMilesToMeters(10) -- Returns 18520 (10 nautical miles)
--- local range = NauticalMilesToMeters(50) -- Returns 92600 (50 nautical miles)
function NauticalMilesToMeters(nm) end

---Converts meters to nautical miles
---@param meters number Distance in meters
---@return number? nm Distance in nautical miles, or nil if input is invalid
---@usage
--- local nm = MetersToNauticalMiles(1852) -- Returns 1 (1 nautical mile)
--- local nm2 = MetersToNauticalMiles(92600) -- Returns 50 (50 nautical miles)
function MetersToNauticalMiles(meters) end

---Converts feet to meters
---@param feet number Height/distance in feet
---@return number? meters Height/distance in meters, or nil if input is invalid
---@usage
--- local meters = FeetToMeters(1000) -- Returns 304.8 (1000 feet)
--- local altitude = FeetToMeters(35000) -- Returns 10668 (FL350)
function FeetToMeters(feet) end

---Converts meters to feet
---@param meters number Height/distance in meters
---@return number? feet Height/distance in feet, or nil if input is invalid
---@usage
--- local feet = MetersToFeet(304.8) -- Returns 1000 (1000 feet)
--- local fl = MetersToFeet(10668) -- Returns 35000 (FL350)
function MetersToFeet(meters) end

---Calculates the 2D distance between two points (ignoring altitude)
---@param point1 table|Vec2|Vec3 First point with x and z coordinates
---@param point2 table|Vec2|Vec3 Second point with x and z coordinates
---@return number? distance Distance in meters, or nil if inputs are invalid
---@usage
--- local dist = Distance2D({x=0, z=0}, {x=100, z=100}) -- Returns 141.42 (diagonal)
--- local range = Distance2D(unit1:getPoint(), unit2:getPoint()) -- Distance between units
function Distance2D(point1, point2) end

---Calculates the 3D distance between two points (including altitude)
---@param point1 table|Vec3 First point with x, y, and z coordinates
---@param point2 table|Vec3 Second point with x, y, and z coordinates
---@return number? distance Distance in meters, or nil if inputs are invalid
---@usage
--- local dist = Distance3D({x=0, y=0, z=0}, {x=100, y=50, z=100}) -- Returns 158.11
--- local slantRange = Distance3D(aircraft:getPoint(), target:getPoint()) -- Slant range
function Distance3D(point1, point2) end

---Calculates the bearing from one point to another
---@param from table|Vec2|Vec3 Starting point
---@param to table|Vec2|Vec3 Target point
---@return number? bearing Aviation bearing in degrees (0=North, 90=East), or nil if invalid
---@usage
--- local bearing = BearingBetween({x=0, z=0}, {x=100, z=0}) -- Returns 90 (East)
--- local hdg = BearingBetween(myUnit:getPoint(), target:getPoint()) -- Bearing to target
--- local intercept = BearingBetween(fighter:getPoint(), bandit:getPoint()) -- Intercept heading
function BearingBetween(from, to) end

---Displaces a point by a given bearing and distance
---@param point table|Vec2|Vec3 Starting point
---@param bearingDeg number Aviation bearing in degrees (0=North, 90=East)
---@param distance number Distance to displace in meters
---@return table? point New point with x, y, z coordinates, or nil if invalid
---@usage
--- local newPos = DisplacePoint2D({x=0, z=0}, 90, 1000) -- 1km East: {x=1000, y=0, z=0}
--- local ip = DisplacePoint2D(airfield:getPoint(), 270, 10 * 1852) -- 10nm West of field
--- local orbit = DisplacePoint2D(tanker:getPoint(), hdg, 40 * 1852) -- 40nm ahead
function DisplacePoint2D(point, bearingDeg, distance) end

---Calculates the midpoint between two points
---@param point1 table|Vec2|Vec3 First point
---@param point2 table|Vec2|Vec3 Second point
---@return table? midpoint Point with x, y, z coordinates, or nil if invalid
---@usage
--- local mid = MidPoint({x=0, z=0}, {x=100, z=100}) -- Returns {x=50, y=0, z=50}
--- local center = MidPoint(wp1, wp2) -- Center point between waypoints
function MidPoint(point1, point2) end

---Rotates a point around a center point by a given angle
---@param point table|Vec2|Vec3 Point to rotate
---@param center table|Vec2|Vec3 Center of rotation
---@param angleDeg number Rotation angle in degrees (positive = clockwise)
---@return table? point Rotated point with x, y, z coordinates, or nil if invalid
---@usage
--- local rotated = RotatePoint2D({x=100, z=0}, {x=0, z=0}, 90) -- Returns {x=0, y=0, z=100}
--- local formation = RotatePoint2D(wingman, lead, 45) -- Rotate wingman 45° around lead
function RotatePoint2D(point, center, angleDeg) end

---Normalizes a 2D vector to unit length
---@param vector table|Vec2 Vector to normalize (must have x and z)
---@return table? normalized Unit vector with x, y, z coordinates, or nil if invalid
---@usage
--- local unit = NormalizeVector2D({x=3, z=4}) -- Returns {x=0.6, y=0, z=0.8}
--- local dir = NormalizeVector2D(velocity) -- Get direction from velocity
function NormalizeVector2D(vector) end

---Normalizes a 3D vector to unit length
---@param vector table|Vec3 Vector to normalize (must have x, y, and z)
---@return table? normalized Unit vector with x, y, z coordinates, or nil if invalid
---@usage
--- local unit = NormalizeVector3D({x=2, y=2, z=1}) -- Returns {x=0.667, y=0.667, z=0.333}
--- local dir = NormalizeVector3D(velocity) -- Get 3D direction from velocity
function NormalizeVector3D(vector) end

---Calculates the dot product of two 2D vectors
---@param v1 table|Vec2 First vector
---@param v2 table|Vec2 Second vector
---@return number? dot Dot product value, or nil if invalid
---@usage
--- local dot = DotProduct2D({x=1, z=0}, {x=0, z=1}) -- Returns 0 (perpendicular)
--- local dot2 = DotProduct2D({x=1, z=0}, {x=1, z=0}) -- Returns 1 (parallel)
function DotProduct2D(v1, v2) end

---Calculates the dot product of two 3D vectors
---@param v1 table|Vec3 First vector
---@param v2 table|Vec3 Second vector
---@return number? dot Dot product value, or nil if invalid
---@usage
--- local dot = DotProduct3D({x=1, y=0, z=0}, {x=0, y=1, z=0}) -- Returns 0
--- local align = DotProduct3D(forward, target) -- Check alignment with target
function DotProduct3D(v1, v2) end

---Calculates the cross product of two 3D vectors
---@param v1 table|Vec3 First vector
---@param v2 table|Vec3 Second vector
---@return table? cross Cross product vector with x, y, z, or nil if invalid
---@usage
--- local cross = CrossProduct3D({x=1, y=0, z=0}, {x=0, y=1, z=0}) -- Returns {x=0, y=0, z=1}
--- local normal = CrossProduct3D(edge1, edge2) -- Surface normal from two edges
function CrossProduct3D(v1, v2) end

---Calculates the angle between two 2D vectors
---@param v1 table|Vec2 First vector
---@param v2 table|Vec2 Second vector
---@return number? angle Angle in degrees (0-180), or nil if invalid
---@usage
--- local angle = AngleBetweenVectors2D({x=1, z=0}, {x=0, z=1}) -- Returns 90
--- local angle2 = AngleBetweenVectors2D({x=1, z=0}, {x=-1, z=0}) -- Returns 180
function AngleBetweenVectors2D(v1, v2) end

function PointInPolygon2D(point, polygon) end

function CircleLineIntersection2D(circleCenter, radius, lineStart, lineEnd) end

function PolygonArea2D(polygon) end

function PolygonCentroid2D(polygon) end

function ConvexHull2D(points) end

--- Estimate time of closest approach between a moving point and a fixed point (2D)
---@param pos table Vec2/Vec3 current position {x,z}
---@param vel table Vec2/Vec3 velocity vector {x,z} meters/second
---@param target table Vec2/Vec3 target point {x,z}
---@return number tStar Time in seconds to closest approach (>= 0)
---@return number distanceAtT Minimum distance at tStar (meters)
---@return table pointAtT Pos at tStar
function EstimateCPAToPoint(pos, vel, target) end

--- Estimate CPA to a circle region
---@param pos table {x,z}
---@param vel table {x,z}
---@param center table {x,z}
---@param radius number radius meters
---@return number tEntry Time when path first reaches minimum distance
---@return number distanceAtT Minimum distance at tEntry
---@return table pointAtT Position at tEntry
function EstimateCPAToCircle(pos, vel, center, radius) end

--- Estimate CPA to a polygon (2D). Approximates by CPA to edges and vertices.
---@param pos table {x,z}
---@param vel table {x,z}
---@param polygon table array of {x,z}
---@return number tStar Time of closest approach
---@return number distanceAtT Minimum distance to polygon boundary
---@return table pointAtT Position at tStar
function EstimateCPAToPolygon(pos, vel, polygon) end

--- Two-body closest point of approach (relative motion, 2D)
---@param posA table {x,z}
---@param velA table {x,z}
---@param posB table {x,z}
---@param velB table {x,z}
---@return number tStar Time of closest approach (>=0)
---@return number distanceAtT Distance at tStar
---@return table aAtT Position A at tStar
---@return table bAtT Position B at tStar
function EstimateTwoBodyCPA(posA, velA, posB, velB) end

--- Solve intercept for a pursuer with fixed speed (2D x/z)
---@param posA table {x,z} pursuer current position
---@param speedA number pursuer speed (m/s)
---@param posB table {x,z} target current position
---@param velB table {x,z} target velocity (m/s)
---@return number|nil tIntercept Time to intercept (seconds) or nil if no solution
---@return table|nil interceptPoint Intercept point {x,y,z} at time t
---@return table|nil requiredVelocity Required pursuer velocity vector {x,y,z}
function EstimateInterceptForSpeed(posA, speedA, posB, velB) end

--- Compute delta-velocity required for A to intercept B at given speed
---@param posA table {x,z}
---@param velA table {x,z}
---@param posB table {x,z}
---@param velB table {x,z}
---@param speedA number? If provided, solve using this speed; otherwise use |requiredVelocity|
---@return table|nil deltaV Vector {x,y,z} to add to velA; nil if no solution
---@return number|nil tIntercept Time to intercept
---@return table|nil interceptPoint Intercept position
---@return table|nil requiredVelocity Velocity vector needed
function EstimateInterceptDeltaV(posA, velA, posB, velB, speedA) end

--- Get group by name
---@param groupName string The name of the group to retrieve
---@return table? group The group object if found, nil otherwise
---@usage local group = GetGroup("Aerial-1")
function GetGroup(groupName) end

--- Check if group exists
---@param groupName string The name of the group to check
---@return boolean exists True if group exists, false otherwise
---@usage if GroupExists("Aerial-1") then ... end
function GroupExists(groupName) end

--- Get group units
---@param groupName string The name of the group
---@return table? units Array of unit objects if found, nil otherwise
---@usage local units = GetGroupUnits("Aerial-1")
function GetGroupUnits(groupName) end

--- Get group size
---@param groupName string The name of the group
---@return number size Current number of units in the group (0 if not found)
---@usage local size = GetGroupSize("Aerial-1")
function GetGroupSize(groupName) end

--- Get group initial size
---@param groupName string The name of the group
---@return number size Initial number of units in the group (0 if not found)
---@usage local initialSize = GetGroupInitialSize("Aerial-1")
function GetGroupInitialSize(groupName) end

--- Get group coalition
---@param groupName string The name of the group
---@return number? coalition The coalition ID if found, nil otherwise
---@usage local coalition = GetGroupCoalition("Aerial-1")
function GetGroupCoalition(groupName) end

--- Get group category
---@param groupName string The name of the group
---@return number? category The category ID if found, nil otherwise
---@usage local category = GetGroupCategory("Aerial-1")
function GetGroupCategory(groupName) end

--- Get group ID
---@param groupName string The name of the group
---@return number? id The group ID if found, nil otherwise
---@usage local id = GetGroupID("Aerial-1")
function GetGroupID(groupName) end

--- Get group controller
---@param groupName string The name of the group
---@return table? controller The controller object if found, nil otherwise
---@usage local controller = GetGroupController("Aerial-1")
function GetGroupController(groupName) end

--- Send message to group
---@param groupId number The group ID to send message to
---@param message string The message text
---@param duration number? Duration in seconds (default 20)
---@return boolean success True if message sent successfully
---@usage MessageToGroup(1, "Hello group", 10)
function MessageToGroup(groupId, message, duration) end

--- Send message to coalition
---@param coalitionId number The coalition ID to send message to
---@param message string The message text
---@param duration number? Duration in seconds (default 20)
---@return boolean success True if message sent successfully
---@usage MessageToCoalition(coalition.side.BLUE, "Hello blues", 10)
function MessageToCoalition(coalitionId, message, duration) end

--- Send message to all
---@param message string The message text
---@param duration number? Duration in seconds (default 20)
---@return boolean success True if message sent successfully
---@usage MessageToAll("Hello everyone", 10)
function MessageToAll(message, duration) end

--- Activate group
---@param groupName string The name of the group to activate
---@return boolean success True if group activated successfully
---@usage ActivateGroup("Aerial-1")
function ActivateGroup(groupName) end

--- Get all groups of coalition and category
---@param coalitionId number The coalition ID to query
---@param categoryId number? Optional category ID to filter by
---@return table groups Array of group objects (empty if error)
---@usage local blueAirGroups = GetCoalitionGroups(coalition.side.BLUE, Group.Category.AIRPLANE)
function GetCoalitionGroups(coalitionId, categoryId) end

--- Get group name
---@param group table Group object
---@return string? name Group name or nil on error
---@usage local name = GetGroupName(group)
function GetGroupName(group) end

--- Get unit by index
---@param group table Group object
---@param index number Unit index (1-based)
---@return table? unit Unit object or nil on error
---@usage local unit = GetGroupUnit(group, 1)
function GetGroupUnit(group, index) end

--- Get group category extended
---@param group table Group object
---@return number? category Extended category or nil on error
---@usage local cat = GetGroupCategoryEx(group)
function GetGroupCategoryEx(group) end

--- Enable/disable group emissions
---@param group table Group object
---@param enabled boolean True to enable emissions
---@return boolean success True if emissions were set
---@usage EnableGroupEmissions(group, false) -- Go dark
function EnableGroupEmissions(group, enabled) end

--- Destroy group without events
---@param group table Group object
---@return boolean success True if destroyed
---@usage DestroyGroup(group)
function DestroyGroup(group) end

--- Check if group is embarking
---@param group table Group object
---@return boolean? embarking True if embarking, nil on error
---@usage if IsGroupEmbarking(group) then ... end
function IsGroupEmbarking(group) end

--- Create map marker for group
---@param group table Group object
---@param point table Position for marker (Vec3)
---@param text string Marker text
---@return boolean success True if marker created
---@usage MarkGroup(group, position, "Enemy armor")
function MarkGroup(group, point, text) end

--- Generate a UUID v4 string (random)
---@return string uuid UUID v4 string (lowercase hex)
function NewUUIDv4() end

--- Generate a UUID v7 string (time-ordered)
---@return string uuid UUID v7 string (lowercase hex)
function NewUUIDv7() end

--- Generate a ULID string (Crockford Base32, 26 chars)
---@return string ulid ULID string
function NewULID() end

--- Create a new logger instance for a specific namespace
---@param namespace string? The namespace for this logger (defaults to "Harness")
---@return Logger logger Logger instance with info, warn, error, and debug methods
---@usage local myLogger = HarnessLogger("MyMod")
---@usage myLogger.info("Starting up")
function HarnessLogger(namespace) end

--- Deep copy a table
---@param original any Value to copy (tables are copied recursively)
---@return any copy Deep copy of the original
---@usage local copy = DeepCopy(myTable)
function DeepCopy(original) end

--- Shallow copy a table
---@param original any Value to copy (only first level for tables)
---@return any copy Shallow copy of the original
---@usage local copy = ShallowCopy(myTable)
function ShallowCopy(original) end

--- Check if table contains value
---@param table table Table to search in
---@param value any Value to search for
---@return boolean found True if value is in table
---@usage if Contains(myList, "item") then ... end
function Contains(table, value) end

--- Check if table contains key
---@param table table Table to search in
---@param key any Key to search for
---@return boolean found True if key exists in table
---@usage if ContainsKey(myTable, "key") then ... end
function ContainsKey(table, key) end

--- Get table size (works with non-sequential tables)
---@param t any Value to check (0 if not a table)
---@return number size Number of entries in table
---@usage local size = TableSize(myTable)
function TableSize(t) end

--- Get table keys
---@param t any Table to get keys from
---@return table keys Array of all keys in the table
---@usage local keys = TableKeys(myTable)
function TableKeys(t) end

--- Get table values
---@param t any Table to get values from
---@return table values Array of all values in the table
---@usage local values = TableValues(myTable)
function TableValues(t) end

--- Merge tables (second overwrites first)
---@param t1 any First table (or value)
---@param t2 any Second table to merge
---@return table merged Deep copy of t1 with t2 values merged in
---@usage local merged = MergeTables(defaults, options)
function MergeTables(t1, t2) end

--- Filter table by predicate function
---@param t any Table to filter
---@param predicate function Function(value, key) that returns true to keep
---@return table filtered New table with filtered entries
---@usage local evens = FilterTable(nums, function(v) return v % 2 == 0 end)
function FilterTable(t, predicate) end

--- Map table values with function
---@param t any Table to map
---@param func function Function(value, key) that returns new value
---@return table mapped New table with mapped values
---@usage local doubled = MapTable(nums, function(v) return v * 2 end)
function MapTable(t, func) end

--- Clamp value between min and max
---@param value number Value to clamp
---@param min number Minimum value
---@param max number Maximum value
---@return number clamped Value clamped between min and max
---@usage local health = Clamp(damage, 0, 100)
function Clamp(value, min, max) end

--- Linear interpolation
---@param a number Start value
---@param b number End value
---@param t number Interpolation factor (0 to 1)
---@return number interpolated Interpolated value
---@usage local mid = Lerp(0, 100, 0.5) -- 50
function Lerp(a, b, t) end

--- Round to decimal places
---@param value number Value to round
---@param decimals number? Number of decimal places (default 0)
---@return number rounded Rounded value
---@usage local rounded = Round(3.14159, 2) -- 3.14
function Round(value, decimals) end

--- Random float between min and max
---@param min number Minimum value
---@param max number Maximum value
---@return number random Random float between min and max
---@usage local rand = RandomFloat(0.0, 1.0)
function RandomFloat(min, max) end

--- Random integer between min and max (inclusive)
---@param min number Minimum value
---@param max number Maximum value
---@return number random Random integer between min and max (inclusive)
---@usage local dice = RandomInt(1, 6)
function RandomInt(min, max) end

--- Random choice from array
---@param choices table? Array to choose from
---@return any? choice Random element from array, nil if empty
---@usage local item = RandomChoice({"red", "green", "blue"})
function RandomChoice(choices) end

--- Shuffle array in place
---@param array any Array to shuffle (modified in place)
---@return any array The shuffled array (same reference)
---@usage Shuffle(myArray)
function Shuffle(array) end

--- Create shuffled copy of array
---@param array any Array to copy and shuffle
---@return table shuffled New shuffled array
---@usage local shuffled = ShuffledCopy(myArray)
function ShuffledCopy(array) end

--- Split string by delimiter, with option to include empty tokens
---@param str any String to split
---@param delimiter string? Delimiter (default ",")
---@param includeEmpty boolean? Include empty tokens when delimiters are adjacent or at ends (default false)
---@return table parts Array of string parts
---@usage local parts = SplitString("a,b,c", ",")
---@usage local partsWithEmpty = SplitString(",a,,b,", ",", true)
function SplitString(str, delimiter, includeEmpty) end

--- Trim whitespace from string
---@param str any String to trim
---@return string trimmed Trimmed string (empty if not string)
---@usage local clean = TrimString("  hello  ")
function TrimString(str) end

--- Check if a string starts with a given prefix (literal, supports multi-character)
---@param s any String to check
---@param prefix any Prefix to look for
---@return boolean starts True if s starts with prefix
---@usage if StringStartsWith("abc", "a") then ... end
function StringStartsWith(s, prefix) end

--- Check if a string contains a given substring (literal, supports multi-character)
---@param s any String to search
---@param needle any Substring to find
---@return boolean contains True if s contains needle
---@usage if StringContains("hello world", "lo w") then ... end
function StringContains(s, needle) end

--- Check if a string ends with a given suffix (literal, supports multi-character)
---@param s any String to check
---@param suffix any Suffix to look for
---@return boolean ends True if s ends with suffix
---@usage if StringEndsWith("file.lua", ".lua") then ... end
function StringEndsWith(s, suffix) end

--- Check if string starts with prefix
---@param str any String to check
---@param prefix any Prefix to look for
---@return boolean starts True if str starts with prefix
---@usage if StartsWith(filename, "test_") then ... end
function StartsWith(str, prefix) end

--- Check if string ends with suffix
---@param str any String to check
---@param suffix any Suffix to look for
---@return boolean ends True if str ends with suffix
---@usage if EndsWith(filename, ".lua") then ... end
function EndsWith(str, suffix) end

--- Normalize angle to 0-360 range
---@param angle number Angle in degrees
---@return number normalized Angle normalized to 0-360
---@usage local norm = NormalizeAngle(450) -- 90
function NormalizeAngle(angle) end

--- Get angle difference (shortest path)
---@param angle1 number First angle in degrees
---@param angle2 number Second angle in degrees
---@return number difference Shortest angle difference (-180 to 180)
---@usage local diff = AngleDiff(350, 10) -- 20
function AngleDiff(angle1, angle2) end

--- Simple table serialization for debugging
---@param tbl any Table to serialize
---@param indent number? Indentation level (default 0)
---@return string serialized String representation of table
---@usage print(TableToString(myTable))
function TableToString(tbl, indent) end

--- Shallow equality check between two values (tables compared by first-level keys/values)
---@param a any First value
---@param b any Second value
---@return boolean equal True if values are shallowly equal
---@usage
--- local same = ShallowEqual({a=1,b=2},{b=2,a=1}) -- true
function ShallowEqual(a, b) end

--- Encode a Lua value to JSON string
---@param value any Value to encode (tables, numbers, strings, booleans, nil)
---@return string|nil json JSON string on success, nil on error
---@usage local s = EncodeJson({a=1})
function EncodeJson(value) end

--- Decode a JSON string to Lua value
---@param json string JSON string to decode
---@return any value Decoded Lua value (or nil on error)
---@usage local t = DecodeJson('{"a":1}')
function DecodeJson(json) end

--- Retry decorator: retries function on failure
---@param func function Function to wrap
---@param options table? Options {retries:number, shouldRetry:function?, onRetry:function?}
---@return function wrapped Function that retries on error
---@usage
--- local unstable = function(x)
--- 	if math.random() < 0.5 then error("boom") end
--- 	return x * 2
--- end
--- local safe = Retry(unstable, {retries = 3})
--- local result = safe(10)
function Retry(func, options) end

--- Circuit breaker decorator: opens circuit after failures, with cooldown
---@param func function Function to wrap
---@param options table? Options {failureThreshold:number, cooldown:number, timeProvider:function?, shouldCountFailure:function?}
---@return function wrapped Wrapped function with breaker behavior
---@usage
--- local safe = CircuitBreaker(unstable, {failureThreshold=3, cooldown=30})
--- local result = safe(10)
function CircuitBreaker(func, options) end

--- Adds a command to the F10 radio menu
--- @param path table Array of menu path elements (numbers or strings)
--- @param menuItem table Menu item definition with name, enabled, and removable fields
--- @param handler function Function to call when menu item is selected
--- @param params any? Optional parameters to pass to the handler
--- @return number|nil commandId The command ID if successful, nil otherwise
--- @usage local cmdId = AddCommand({"Main", "SubMenu"}, {name="Test", enabled=true}, function() print("Selected") end)
function AddCommand(path, menuItem, handler, params) end

--- Adds a submenu to the F10 radio menu
--- @param path table Array of menu path elements (numbers or strings)
--- @param name string The name of the submenu to create
--- @return table|nil submenuPath The path to the new submenu if successful, nil otherwise
--- @usage local subPath = AddSubMenu({}, "My Menu")
function AddSubMenu(path, name) end

--- Removes a menu item or submenu from the F10 radio menu
--- @param path table Array of menu path elements to remove
--- @return boolean|nil success True if removed successfully, nil otherwise
--- @usage RemoveItem({"Main", "SubMenu", "Command"})
function RemoveItem(path) end

--- Adds a command to the F10 radio menu for a specific coalition
--- @param coalitionId number Coalition ID (coalition.side.RED or coalition.side.BLUE)
--- @param path table Array of menu path elements
--- @param menuItem table Menu item definition with name, enabled, and removable fields
--- @param handler function Function to call when menu item is selected
--- @param params any? Optional parameters to pass to the handler
--- @return number|nil commandId The command ID if successful, nil otherwise
--- @usage AddCommandForCoalition(coalition.side.BLUE, {}, {name="Intel"}, function() end)
function AddCommandForCoalition(coalitionId, path, menuItem, handler, params) end

--- Adds a submenu to the F10 radio menu for a specific coalition
--- @param coalitionId number Coalition ID (coalition.side.RED or coalition.side.BLUE)
--- @param path table Array of menu path elements
--- @param name string The name of the submenu to create
--- @return table|nil submenuPath The path to the new submenu if successful, nil otherwise
--- @usage AddSubMenuForCoalition(coalition.side.RED, {}, "Enemy Options")
function AddSubMenuForCoalition(coalitionId, path, name) end

--- Removes a menu item or submenu for a specific coalition
--- @param coalitionId number Coalition ID (coalition.side.RED or coalition.side.BLUE)
--- @param path table Array of menu path elements to remove
--- @return boolean|nil success True if removed successfully, nil otherwise
--- @usage RemoveItemForCoalition(coalition.side.BLUE, {"Intel", "Report"})
function RemoveItemForCoalition(coalitionId, path) end

--- Adds a command to the F10 radio menu for a specific group
--- @param groupId number Group ID from DCS
--- @param path table Array of menu path elements
--- @param menuItem table Menu item definition with name, enabled, and removable fields
--- @param handler function Function to call when menu item is selected
--- @param params any? Optional parameters to pass to the handler
--- @return number|nil commandId The command ID if successful, nil otherwise
--- @usage AddCommandForGroup(groupId, {}, {name="Request Support"}, function() end)
function AddCommandForGroup(groupId, path, menuItem, handler, params) end

--- Adds a submenu to the F10 radio menu for a specific group
--- @param groupId number Group ID from DCS
--- @param path table Array of menu path elements
--- @param name string The name of the submenu to create
--- @return table|nil submenuPath The path to the new submenu if successful, nil otherwise
--- @usage AddSubMenuForGroup(groupId, {}, "Flight Options")
function AddSubMenuForGroup(groupId, path, name) end

--- Removes a menu item or submenu for a specific group
--- @param groupId number Group ID from DCS
--- @param path table Array of menu path elements to remove
--- @return boolean|nil success True if removed successfully, nil otherwise
--- @usage RemoveItemForGroup(groupId, {"Flight Options", "RTB"})
function RemoveItemForGroup(groupId, path) end

--- Creates a menu item definition for use with AddCommand functions
--- @param name string The display name of the menu item
--- @param enabled boolean? Whether the item is enabled (default: true)
--- @param removable boolean? Whether the item can be removed (default: true)
--- @return table|nil menuItem Menu item definition or nil on error
--- @usage local item = CreateMenuItem("Launch Attack", true, false)
function CreateMenuItem(name, enabled, removable) end

--- Creates a menu path from variable arguments
--- @param ... string|number Path elements (strings or command IDs)
--- @return table|nil path Array of path elements or nil on error
--- @usage local path = CreateMenuPath("Main", "Options", "Graphics")
function CreateMenuPath(...) end

--- Send chat message to all players or coalition
---@param message string Message text to send
---@param all boolean True to send to all, false for coalition only
---@return boolean success True if message was sent
---@usage SendChat("Hello everyone!", true)
function SendChat(message, all) end

--- Send chat message to specific player
---@param message string Message text to send
---@param playerId number Target player ID
---@param fromId number? Sender player ID (optional)
---@return boolean success True if message was sent
---@usage SendChatTo("Private message", 2)
function SendChatTo(message, playerId, fromId) end

--- Get list of all connected players
---@return table players Array of player info tables
---@usage local players = GetPlayers()
function GetPlayers() end

--- Get information about specific player
---@param playerId number Player ID
---@return table? info Player info table or nil on error
---@usage local info = GetPlayerInfo(1)
function GetPlayerInfo(playerId) end

--- Kick player from server
---@param playerId number Player ID to kick
---@param reason string? Kick reason message
---@return boolean success True if kick command was sent
---@usage KickPlayer(3, "Team killing")
function KickPlayer(playerId, reason) end

--- Get player's network statistics
---@param playerId number Player ID
---@param statId number Statistic ID (use net.PS_* constants)
---@return number? value Statistic value or nil on error
---@usage local ping = GetPlayerStat(1, net.PS_PING)
function GetPlayerStat(playerId, statId) end

--- Check if running as server
---@return boolean isServer True if running as server
---@usage if IsServer() then ... end
function IsServer() end

--- Load a new mission
---@param missionPath string Path to mission file
---@return boolean success True if mission load was initiated
---@usage LoadMission("C:/Missions/my_mission.miz")
function LoadMission(missionPath) end

--- Load next mission in list
---@return boolean success True if next mission load was initiated
---@usage LoadNextMission()
function LoadNextMission() end

--- Get current mission name
---@return string? name Mission name or nil on error
---@usage local mission = GetMissionName()
function GetMissionName() end

--- Force player to slot
---@param playerId number Player ID
---@param side number Coalition side (0=neutral, 1=red, 2=blue)
---@param slotId string Slot ID string
---@return boolean success True if slot change was initiated
---@usage ForcePlayerSlot(2, 2, "blue_f16_pilot")
function ForcePlayerSlot(playerId, side, slotId) end

--- Initialize all shape caches (drawings and trigger zones)
---@return boolean success True if all caches initialized successfully
function InitializeShapeCache() end

--- Get all shapes (drawings and trigger zones)
---@return table shapes Table with drawings and triggerZones arrays
function GetAllShapes() end

--- Find shapes by name (partial match)
---@param pattern string Name pattern to search for
---@return table results Table with matching drawings and triggerZones
function FindShapesByName(pattern) end

--- Get shape by exact name (searches both drawings and zones)
---@param name string Shape name
---@return table? shape Shape data with type field or nil if not found
function GetShapeByName(name) end

--- Check if a point is inside any named shape
---@param point table Point with x, z coordinates
---@param shapeName string? Optional shape name to check specifically
---@return table results Array of shapes containing the point
function GetShapesAtPoint(point, shapeName) end

--- Get all circular shapes (both drawings and trigger zones)
---@return table circles Array of circular shapes
function GetAllCircularShapes() end

--- Get all polygon shapes (both drawings and trigger zones)
---@return table polygons Array of polygon shapes
function GetAllPolygonShapes() end

--- Get units in shape
---@param shapeName string Shape name (drawing or trigger zone)
---@return table Array of units inside the shape
function GetUnitsInShape(shapeName) end

--- Get shape statistics
---@return table stats Statistics about cached shapes
function GetShapeStatistics() end

--- Clear all shape caches
function ClearShapeCache() end

--- Automatically initialize shape cache on mission start
---@return boolean success
function AutoInitializeShapeCache() end

--- Creates an equilateral triangle shape
--- @param center table|Vec2 Center point of the triangle {x, z} or Vec2
--- @param size number? Length of each side in meters (default: 1000)
--- @param rotation number? Rotation angle in degrees (default: 0)
--- @return table|nil points Array of Vec2 points defining the triangle or nil on error
--- @usage local triangle = CreateTriangle({x=0, z=0}, 5000, 45)
function CreateTriangle(center, size, rotation) end

--- Creates a rectangle shape
--- @param center table|Vec2 Center point of the rectangle {x, z} or Vec2
--- @param width number? Width in meters (default: 2000)
--- @param height number? Height in meters (default: 1000)
--- @param rotation number? Rotation angle in degrees (default: 0)
--- @return table|nil points Array of Vec2 points defining the rectangle or nil on error
--- @usage local rect = CreateRectangle({x=0, z=0}, 5000, 3000, 90)
function CreateRectangle(center, width, height, rotation) end

--- Creates a square shape
--- @param center table|Vec2 Center point of the square {x, z} or Vec2
--- @param size number? Length of each side in meters
--- @param rotation number? Rotation angle in degrees (default: 0)
--- @return table|nil points Array of Vec2 points defining the square or nil on error
--- @usage local square = CreateSquare({x=0, z=0}, 2000, 45)
function CreateSquare(center, size, rotation) end

--- Creates an oval/ellipse shape
--- @param center table|Vec2 Center point of the oval {x, z} or Vec2
--- @param radiusX number? Radius along X axis in meters (default: 1000)
--- @param radiusZ number? Radius along Z axis in meters (default: radiusX)
--- @param numPoints number? Number of points to generate (default: 36)
--- @return table|nil points Array of Vec2 points defining the oval or nil on error
--- @usage local oval = CreateOval({x=0, z=0}, 2000, 1000, 48)
function CreateOval(center, radiusX, radiusZ, numPoints) end

--- Creates a circle shape
--- @param center table|Vec2 Center point of the circle {x, z} or Vec2
--- @param radius number? Radius in meters
--- @param numPoints number? Number of points to generate (default: 36)
--- @return table|nil points Array of Vec2 points defining the circle or nil on error
--- @usage local circle = CreateCircle({x=0, z=0}, 5000, 72)
function CreateCircle(center, radius, numPoints) end

--- Creates a fan/sector shape from an origin point
--- @param origin table|Vec2 Origin point of the fan {x, z} or Vec2
--- @param centerBearing number? Center bearing of the arc in degrees (default: 0)
--- @param arcDegrees number? Total arc width in degrees (default: 90)
--- @param distance number? Distance from origin in meters (default: 50 NM)
--- @param numPoints number? Number of arc points (default: based on arc size)
--- @return table|nil points Array of Vec2 points defining the fan or nil on error
--- @usage local fan = CreateFan({x=0, z=0}, 45, 60, 10000) -- 60° arc centered on bearing 45°
function CreateFan(origin, centerBearing, arcDegrees, distance, numPoints) end

--- Creates a trapezoid shape
--- @param center table|Vec2 Center point of the trapezoid {x, z} or Vec2
--- @param topWidth number? Width of top edge in meters (default: 1000)
--- @param bottomWidth number? Width of bottom edge in meters (default: 2000)
--- @param height number? Height in meters (default: 1000)
--- @param rotation number? Rotation angle in degrees (default: 0)
--- @return table|nil points Array of Vec2 points defining the trapezoid or nil on error
--- @usage local trap = CreateTrapezoid({x=0, z=0}, 1000, 3000, 2000)
function CreateTrapezoid(center, topWidth, bottomWidth, height, rotation) end

--- Creates a pill/capsule shape (rectangle with semicircular ends)
--- @param center table|Vec2 Center point of the pill {x, z} or Vec2
--- @param legBearing number? Direction of the long axis in degrees (default: 0)
--- @param legLength number? Length of the straight section in meters (default: 40 NM)
--- @param radius number? Radius of the semicircular ends in meters (default: 10 NM)
--- @param pointsPerCap number? Points per semicircle end (default: 19)
--- @return table|nil points Array of Vec2 points defining the pill or nil on error
--- @usage local pill = CreatePill({x=0, z=0}, 90, 20000, 5000)
function CreatePill(center, legBearing, legLength, radius, pointsPerCap) end

--- Creates a star shape
--- @param center table|Vec2 Center point of the star {x, z} or Vec2
--- @param outerRadius number? Radius to outer points in meters (default: 1000)
--- @param innerRadius number? Radius to inner points in meters (default: 400)
--- @param numPoints number? Number of star points (default: 5)
--- @param rotation number? Rotation angle in degrees (default: 0)
--- @return table|nil points Array of Vec2 points defining the star or nil on error
--- @usage local star = CreateStar({x=0, z=0}, 5000, 2000, 5, 0)
function CreateStar(center, outerRadius, innerRadius, numPoints, rotation) end

--- Creates a regular polygon shape
--- @param center table|Vec2 Center point of the polygon {x, z} or Vec2
--- @param radius number Radius to vertices in meters
--- @param numSides number Number of sides (minimum 3)
--- @param rotation number? Rotation angle in degrees (default: 0)
--- @return table|nil points Array of Vec2 points defining the polygon or nil on error
--- @usage local pentagon = CreatePolygon({x=0, z=0}, 3000, 5, 0)
function CreatePolygon(center, radius, numSides, rotation) end

--- Creates a hexagon shape
--- @param center table|Vec2 Center point of the hexagon {x, z} or Vec2
--- @param radius number Radius to vertices in meters
--- @param rotation number? Rotation angle in degrees (default: 0)
--- @return table|nil points Array of Vec2 points defining the hexagon or nil on error
--- @usage local hex = CreateHexagon({x=0, z=0}, 2000, 30)
function CreateHexagon(center, radius, rotation) end

--- Creates an octagon shape
--- @param center table|Vec2 Center point of the octagon {x, z} or Vec2
--- @param radius number Radius to vertices in meters
--- @param rotation number? Rotation angle in degrees (default: 0)
--- @return table|nil points Array of Vec2 points defining the octagon or nil on error
--- @usage local oct = CreateOctagon({x=0, z=0}, 2000, 0)
function CreateOctagon(center, radius, rotation) end

--- Creates an arc shape
--- @param center table|Vec2 Center point of the arc {x, z} or Vec2
--- @param radius number Radius in meters
--- @param startBearing number? Starting bearing in degrees (default: 0)
--- @param endBearing number? Ending bearing in degrees (default: 90)
--- @param numPoints number? Number of points (default: based on arc size)
--- @return table|nil points Array of Vec2 points defining the arc or nil on error
--- @usage local arc = CreateArc({x=0, z=0}, 5000, 0, 180, 37)
function CreateArc(center, radius, startBearing, endBearing, numPoints) end

--- Creates a spiral shape
--- @param center table|Vec2 Center point of the spiral {x, z} or Vec2
--- @param startRadius number? Starting radius in meters (default: 100)
--- @param endRadius number? Ending radius in meters (default: 1000)
--- @param numTurns number? Number of complete turns (default: 3)
--- @param pointsPerTurn number? Points per turn (default: 36)
--- @return table|nil points Array of Vec2 points defining the spiral or nil on error
--- @usage local spiral = CreateSpiral({x=0, z=0}, 100, 5000, 5, 72)
function CreateSpiral(center, startRadius, endRadius, numTurns, pointsPerTurn) end

--- Creates a ring/donut shape
--- @param center table|Vec2 Center point of the ring {x, z} or Vec2
--- @param outerRadius number Outer radius in meters
--- @param innerRadius number Inner radius in meters (must be less than outer)
--- @param numPoints number? Number of points per circle (default: 36)
--- @return table|nil points Array of Vec2 points defining the ring or nil on error
--- @usage local ring = CreateRing({x=0, z=0}, 5000, 3000, 72)
function CreateRing(center, outerRadius, innerRadius, numPoints) end

--- Creates a cross/plus shape
--- @param center table|Vec2 Center point of the cross {x, z} or Vec2
--- @param size number? Length of the cross arms in meters (default: 1000)
--- @param thickness number? Thickness of the arms in meters (default: 200)
--- @param rotation number? Rotation angle in degrees (default: 0)
--- @return table|nil points Array of Vec2 points defining the cross or nil on error
--- @usage local cross = CreateCross({x=0, z=0}, 2000, 400, 45)
function CreateCross(center, size, thickness, rotation) end

--- Converts shape points to Vec3 with specified altitude
--- @param shape table Array of Vec2 points
--- @param altitude number? Altitude in meters (default: 0)
--- @return table|nil points Array of Vec3 points or nil on error
--- @usage local shape3D = ShapeToVec3(triangle, 1000)
function ShapeToVec3(shape, altitude) end

--- Create a laser spot
---@param source table Unit or weapon that creates the spot
---@param target table Target position (Vec3)
---@param localRef table? Optional local reference Vec3 on source (schema localRef)
---@param code number Laser code (1111-1788)
---@return table? spot Created spot object or nil on error
---@usage local spot = CreateLaserSpot(jtac, targetPos, nil, 1688)
function CreateLaserSpot(source, target, localRef, code) end

--- Create an IR pointer spot
---@param source table Unit that creates the spot
---@param target table Target position (Vec3)
---@param localRef table? Optional local reference Vec3 on source (schema localRef)
---@return table? spot Created spot object or nil on error
---@usage local spot = CreateIRSpot(aircraft, targetPos)
function CreateIRSpot(source, target, localRef) end

--- Destroy a spot
---@param spot table Spot object to destroy
---@return boolean success True if destroyed
---@usage DestroySpot(laserSpot)
function DestroySpot(spot) end

--- Get spot point/position
---@param spot table Spot object
---@return table? point Spot position (Vec3) or nil on error
---@usage local pos = GetSpotPoint(laserSpot)
function GetSpotPoint(spot) end

--- Set spot point/position
---@param spot table Spot object
---@param point table New position (Vec3)
---@return boolean success True if position was set
---@usage SetSpotPoint(laserSpot, newTargetPos)
function SetSpotPoint(spot, point) end

--- Get laser code
---@param spot table Laser spot object
---@return number? code Laser code or nil on error
---@usage local code = GetLaserCode(laserSpot)
function GetLaserCode(spot) end

--- Set laser code
---@param spot table Laser spot object
---@param code number New laser code (1111-1788)
---@return boolean success True if code was set
---@usage SetLaserCode(laserSpot, 1688)
function SetLaserCode(spot, code) end

--- Check if spot exists/is active
---@param spot table Spot object
---@return boolean exists True if spot exists
---@usage if SpotExists(laserSpot) then ... end
function SpotExists(spot) end

--- Get spot category
---@param spot table Spot object
---@return number? category Spot category or nil on error
---@usage local cat = GetSpotCategory(spot)
function GetSpotCategory(spot) end

--- Gets a static object by its name
---@param name string The name of the static object
---@return table? staticObject The static object or nil if not found
---@usage local static = GetStaticByName("Warehouse01")
function GetStaticByName(name) end

--- Gets the ID of a static object
---@param staticObject table The static object
---@return number? id The ID of the static object or nil on error
---@usage local id = GetStaticID(staticObj)
function GetStaticID(staticObject) end

--- Gets the current life/health of a static object
---@param staticObject table The static object
---@return number? life The current life value or nil on error
---@usage local life = GetStaticLife(staticObj)
function GetStaticLife(staticObject) end

--- Gets the cargo display name of a static object
---@param staticObject table The static object
---@return string? displayName The cargo display name or nil on error
---@usage local cargoName = GetStaticCargoDisplayName(staticObj)
function GetStaticCargoDisplayName(staticObject) end

--- Gets the cargo weight of a static object
---@param staticObject table The static object
---@return number? weight The cargo weight in kg or nil on error
---@usage local weight = GetStaticCargoWeight(staticObj)
function GetStaticCargoWeight(staticObject) end

--- Destroys a static object
---@param staticObject table The static object to destroy
---@return boolean? success Returns true if successful, nil on error
---@usage DestroyStaticObject(staticObj)
function DestroyStaticObject(staticObject) end

--- Gets the category of a static object
---@param staticObject table The static object
---@return number? category The object category or nil on error
---@usage local category = GetStaticCategory(staticObj)
function GetStaticCategory(staticObject) end

--- Gets the type name of a static object
---@param staticObject table The static object
---@return string? typeName The type name or nil on error
---@usage local typeName = GetStaticTypeName(staticObj)
function GetStaticTypeName(staticObject) end

--- Gets the description of a static object
---@param staticObject table The static object
---@return table? desc The description table or nil on error
---@usage local desc = GetStaticDesc(staticObj)
function GetStaticDesc(staticObject) end

--- Checks if a static object exists
---@param staticObject table The static object to check
---@return boolean? exists Returns true if exists, false if not, nil on error
---@usage local exists = IsStaticExist(staticObj)
function IsStaticExist(staticObject) end

--- Gets the coalition of a static object
---@param staticObject table The static object
---@return number? coalition The coalition ID or nil on error
---@usage local coalition = GetStaticCoalition(staticObj)
function GetStaticCoalition(staticObject) end

--- Gets the country of a static object
---@param staticObject table The static object
---@return number? country The country ID or nil on error
---@usage local country = GetStaticCountry(staticObj)
function GetStaticCountry(staticObject) end

--- Gets the 3D position point of a static object
---@param staticObject table The static object
---@return table? point Position table with x, y, z coordinates or nil on error
---@usage local point = GetStaticPoint(staticObj)
function GetStaticPoint(staticObject) end

--- Gets the position and orientation of a static object
---@param staticObject table The static object
---@return table? position Position table with p (point) and x,y,z vectors or nil on error
---@usage local pos = GetStaticPosition(staticObj)
function GetStaticPosition(staticObject) end

--- Gets the velocity vector of a static object
---@param staticObject table The static object
---@return table? velocity Velocity vector with x, y, z components or nil on error
---@usage local vel = GetStaticVelocity(staticObj)
function GetStaticVelocity(staticObject) end

--- Creates a new static object (DCS-native signature)
---@param countryId number The country ID that will own the static object
---@param staticData table Static object data table with required fields: name, type, x, y
---@return table? staticObject The created static object or nil on error
---@usage local static = CreateStaticObject(country.id.USA, { name = "dyn", type = "Cafe", x = 1000, y = 2000 })
function CreateStaticObject(countryId, staticData) end

--- Get terrain height at position
---@param position table Vec2 or Vec3 position
---@return number height Terrain height at position (0 on error)
---@usage local height = GetTerrainHeight(position)
function GetTerrainHeight(position) end

--- Get altitude above ground level
---@param position table Vec3 position
---@return number agl Altitude above ground level (0 on error)
---@usage local agl = GetAGL(position)
function GetAGL(position) end

--- Set altitude to specific AGL
---@param position table Vec3 position
---@param agl number Desired altitude above ground level
---@return table newPosition Vec3 with adjusted altitude
---@usage local newPos = SetAGL(position, 100)
function SetAGL(position, agl) end

--- Check line of sight between two points
---@param from table Vec3 start position
---@param to table Vec3 end position
---@return boolean hasLOS True if line of sight exists
---@usage if HasLOS(pos1, pos2) then ... end
function HasLOS(from, to) end

--- Estimate terrain grade (slope) around a point by sampling heights
---@param point table Vec3 center position
---@param radius number? Sampling radius in meters (default: 5)
---@param step number? Angular step in degrees for ring sampling (default: 45)
---@return table result {slopeDeg:number, slopePercent:number, dzdx:number, dzdz:number}
---@usage local g = GetTerrainGrade(pos, 10, 30)
function GetTerrainGrade(point, radius, step) end

--- Get surface type at position
---@param position table Vec2 or Vec3 position
---@return number? surfaceType Surface type ID (1=land, 2=shallow water, 3=water, 4=road, 5=runway)
---@usage local surface = GetSurfaceType(position)
function GetSurfaceType(position) end

--- Check if position is over water
---@param position table Vec2 or Vec3 position
---@return boolean overWater True if over water or shallow water
---@usage if IsOverWater(position) then ... end
function IsOverWater(position) end

--- Check if position is over land
---@param position table Vec2 or Vec3 position
---@return boolean overLand True if over land, road, or runway
---@usage if IsOverLand(position) then ... end
function IsOverLand(position) end

--- Get intersection point of ray with terrain
---@param origin table Vec3 ray origin
---@param direction table Vec3 ray direction
---@param maxDistance number Maximum ray distance
---@return table? intersection Vec3 intersection point if found
---@usage local hit = GetTerrainIntersection(origin, direction, 10000)
function GetTerrainIntersection(origin, direction, maxDistance) end

--- Get terrain profile between two points
---@param from table Vec3 start position
---@param to table Vec3 end position
---@return table profile Array of profile points (empty on error)
---@usage local profile = GetTerrainProfile(pos1, pos2)
function GetTerrainProfile(from, to) end

--- Find closest point on roads
---@param position table Vec2 or Vec3 position
---@param roadType string? Road type ("roads" or "rails", default "roads")
---@return table? point Closest point on road if found
---@usage local roadPoint = GetClosestRoadPoint(position, "roads")
function GetClosestRoadPoint(position, roadType) end

--- Find path on roads between two points
---@param from table Vec2 or Vec3 start position
---@param to table Vec2 or Vec3 end position
---@param roadType string? Road type ("roads" or "railroads", default "roads")
---@return table path Array of path points (empty on error)
---@usage local path = FindRoadPath(start, finish, "roads")
function FindRoadPath(from, to, roadType) end

--- Get mission time
---@return number time Current mission time in seconds
---@usage local time = GetTime()
function GetTime() end

--- Get absolute time
---@return number time Absolute time in seconds since midnight
---@usage local absTime = GetAbsTime()
function GetAbsTime() end

--- Get mission start time
---@return number time Mission start time in seconds
---@usage local startTime = GetTime0()
function GetTime0() end

--- Format time as HH:MM:SS
---@param seconds number Time in seconds
---@return string formatted Time string in HH:MM:SS format
---@usage local timeStr = FormatTime(3661) -- "01:01:01"
function FormatTime(seconds) end

--- Format time as MM:SS
---@param seconds number Time in seconds
---@return string formatted Time string in MM:SS format
---@usage local timeStr = FormatTimeShort(125) -- "02:05"
function FormatTimeShort(seconds) end

--- Get current mission time as table
---@return table time Table with hours, minutes, seconds fields
---@usage local t = GetMissionTime() -- {hours=14, minutes=30, seconds=45}
function GetMissionTime() end

--- Check if current time is night (19:00-06:59)
---@return boolean isNight True if between 19:00 and 06:59
---@usage if IsNightTime() then ... end
function IsNightTime() end

--- Schedule a function (no recurring - pure function)
---@param func function Function to schedule
---@param args any? Arguments to pass to function
---@param delay number? Delay in seconds (default 0)
---@return number? timerId Timer ID for cancellation, nil on error
---@usage local id = ScheduleOnce(myFunc, {arg1, arg2}, 10)
function ScheduleOnce(func, args, delay) end

--- Cancel scheduled function
---@param timerId number? Timer ID to cancel
---@return boolean success True if cancelled successfully
---@usage CancelSchedule(timerId)
function CancelSchedule(timerId) end

--- Reschedule function
---@param timerId number Timer ID to reschedule
---@param newTime number New execution time in seconds
---@return boolean success True if rescheduled successfully
---@usage RescheduleFunction(timerId, GetTime() + 30)
function RescheduleFunction(timerId, newTime) end

--- Convert seconds to time components
---@param seconds number Time in seconds
---@return table components Table with hours, minutes, seconds fields
---@usage local t = SecondsToTime(3661) -- {hours=1, minutes=1, seconds=1}
function SecondsToTime(seconds) end

--- Convert time components to seconds
---@param hours number? Hours (default 0)
---@param minutes number? Minutes (default 0)
---@param seconds number? Seconds (default 0)
---@return number totalSeconds Total seconds
---@usage local secs = TimeToSeconds(1, 30, 45) -- 5445
function TimeToSeconds(hours, minutes, seconds) end

--- Get elapsed time since mission start
---@return number elapsed Mission elapsed time in seconds
---@usage local elapsed = GetElapsedTime()
function GetElapsedTime() end

--- Get elapsed real time since mission start
---@return number elapsed Real elapsed time in seconds
---@usage local realElapsed = GetElapsedRealTime()
function GetElapsedRealTime() end

--- Create a new Binary Search Tree
---@param compareFunc function? Custom comparison function(a, b) returns -1, 0, or 1
---@return table bst New BST instance
---@usage local bst = BinarySearchTree()
function BinarySearchTree(compareFunc) end

--- Create a new Red-Black Tree (self-balancing BST)
---@param compareFunc function? Custom comparison function(a, b) returns -1, 0, or 1
---@return table rbtree New RB tree instance
---@usage local rbt = RedBlackTree()
function RedBlackTree(compareFunc) end

--- Create a new Trie for string operations
---@return table trie New trie instance
---@usage local trie = Trie()
function Trie() end

--- Create a new AVL Tree
---@param compareFunc function? Custom comparison function(a, b) returns -1, 0, or 1
---@return table avl New AVL tree instance
---@usage local avl = AVLTree()
function AVLTree(compareFunc) end

--- Displays text message to all players
---@param text string The text message to display
---@param displayTime number? The time in seconds to display (default: 10)
---@param clearView boolean? Whether to clear the previous message (default: false)
---@return boolean? success Returns true if successful, nil on error
---@usage OutText("Hello World", 15, true)
function OutText(text, displayTime, clearView) end

--- Displays text message to a specific coalition
---@param coalitionId number The coalition ID (0=neutral, 1=red, 2=blue)
---@param text string The text message to display
---@param displayTime number? The time in seconds to display (default: 10)
---@param clearView boolean? Whether to clear the previous message (default: false)
---@return boolean? success Returns true if successful, nil on error
---@usage OutTextForCoalition(coalition.side.BLUE, "Blue team message", 20)
function OutTextForCoalition(coalitionId, text, displayTime, clearView) end

--- Displays text message to a specific group
---@param groupId number The group ID to display message to
---@param text string The text message to display
---@param displayTime number? The time in seconds to display (default: 10)
---@param clearView boolean? Whether to clear the previous message (default: false)
---@return boolean? success Returns true if successful, nil on error
---@usage OutTextForGroup(1001, "Group message", 15)
function OutTextForGroup(groupId, text, displayTime, clearView) end

--- Displays text message to a specific unit
---@param unitId number The unit ID to display message to
---@param text string The text message to display
---@param displayTime number? The time in seconds to display (default: 10)
---@param clearView boolean? Whether to clear the previous message (default: false)
---@return boolean? success Returns true if successful, nil on error
---@usage OutTextForUnit(2001, "Unit message", 10)
function OutTextForUnit(unitId, text, displayTime, clearView) end

--- Plays a sound file to all players
---@param soundFile string The path to the sound file to play
---@param soundType any? Optional sound type parameter
---@return boolean? success Returns true if successful, nil on error
---@usage OutSound("sounds/alarm.ogg")
function OutSound(soundFile, soundType) end

--- Plays a sound file to a specific coalition
---@param coalitionId number The coalition ID (0=neutral, 1=red, 2=blue)
---@param soundFile string The path to the sound file to play
---@param soundType any? Optional sound type parameter
---@return boolean? success Returns true if successful, nil on error
---@usage OutSoundForCoalition(coalition.side.RED, "sounds/warning.ogg")
function OutSoundForCoalition(coalitionId, soundFile, soundType) end

--- Creates an explosion at the specified position
---@param pos table Position table with x, y, z coordinates
---@param power number The explosion power/strength
---@return boolean? success Returns true if successful, nil on error
---@usage Explosion({x=1000, y=100, z=2000}, 500)
function Explosion(pos, power) end

--- Creates smoke effect at the specified position
---@param pos table Position table with x, y, z coordinates
---@param smokeColor number Smoke color enum value
---@param density number? Optional smoke density
---@param name string? Optional name for the smoke effect
---@return boolean? success Returns true if successful, nil on error
---@usage Smoke({x=1000, y=0, z=2000}, trigger.smokeColor.Red)
function Smoke(pos, smokeColor, density, name) end

--- Creates a big smoke effect at the specified position
---@param pos table Position table with x, y, z coordinates
---@param smokePreset number Smoke preset enum value
---@param density number? Optional smoke density
---@param name string? Optional name for the smoke effect
---@return boolean? success Returns true if successful, nil on error
---@usage EffectSmokeBig({x=1000, y=0, z=2000}, trigger.effectPresets.BigSmoke)
function EffectSmokeBig(pos, smokePreset, density, name) end

--- Stops a named smoke effect
---@param name string The name of the smoke effect to stop
---@return boolean? success Returns true if successful, nil on error
---@usage EffectSmokeStop("smoke1")
function EffectSmokeStop(name) end

--- Creates an illumination bomb at the specified position
---@param pos table Position table with x, y, z coordinates
---@param power number? The illumination power (default: 1000000)
---@return boolean? success Returns true if successful, nil on error
---@usage IlluminationBomb({x=1000, y=500, z=2000}, 2000000)
function IlluminationBomb(pos, power) end

--- Fires a signal flare at the specified position
---@param pos table Position table with x, y, z coordinates
---@param flareColor number Flare color enum value
---@param azimuth number? The azimuth direction in radians (default: 0)
---@return boolean? success Returns true if successful, nil on error
---@usage SignalFlare({x=1000, y=100, z=2000}, trigger.flareColor.Red, math.rad(45))
function SignalFlare(pos, flareColor, azimuth) end

--- Starts a radio transmission from a position
---@param filename string The audio file to transmit
---@param pos table Position table with x, y, z coordinates
---@param modulation number? Radio modulation type (default: 0)
---@param loop boolean? Whether to loop the transmission
---@param frequency number? Transmission frequency in Hz (default: 124000000)
---@param power number? Transmission power (default: 100)
---@param name string? Optional name for the transmission
---@return boolean? success Returns true if successful, nil on error
---@usage RadioTransmission("sounds/message.ogg", {x=1000, y=100, z=2000}, 0, true, 124000000, 100, "radio1")
function RadioTransmission(filename, pos, modulation, loop, frequency, power, name) end

--- Stops a named radio transmission
---@param name string The name of the transmission to stop
---@return boolean? success Returns true if successful, nil on error
---@usage StopRadioTransmission("radio1")
function StopRadioTransmission(name) end

--- Sets the radius of an existing map mark
---@param markId number The ID of the mark to modify
---@param radius number The new radius in meters
---@return boolean? success Returns true if successful, nil on error
---@usage SetMarkupRadius(1001, 5000)
function SetMarkupRadius(markId, radius) end

--- Sets the text of an existing map mark
---@param markId number The ID of the mark to modify
---@param text string The new text for the mark
---@return boolean? success Returns true if successful, nil on error
---@usage SetMarkupText(1001, "New target location")
function SetMarkupText(markId, text) end

--- Sets the color of an existing map mark
---@param markId number The ID of the mark to modify
---@param color table Color table with r, g, b, a values (0-1)
---@return boolean? success Returns true if successful, nil on error
---@usage SetMarkupColor(1001, {r=1, g=0, b=0, a=1})
function SetMarkupColor(markId, color) end

--- Sets the fill color of an existing map mark
---@param markId number The ID of the mark to modify
---@param colorFill table Color table with r, g, b, a values (0-1)
---@return boolean? success Returns true if successful, nil on error
---@usage SetMarkupColorFill(1001, {r=0, g=1, b=0, a=0.5})
function SetMarkupColorFill(markId, colorFill) end

--- Sets the font size of an existing map mark
---@param markId number The ID of the mark to modify
---@param fontSize number The font size in points
---@return boolean? success Returns true if successful, nil on error
---@usage SetMarkupFontSize(1001, 18)
function SetMarkupFontSize(markId, fontSize) end

--- Removes a map mark
---@param markId number The ID of the mark to remove
---@return boolean? success Returns true if successful, nil on error
---@usage RemoveMark(1001)
function RemoveMark(markId) end

--- Creates a map mark visible to all players
---@param markId number Unique ID for the mark
---@param text string? Text to display (default: "")
---@param pos table Position table with x, y, z coordinates
---@param readOnly boolean? Whether the mark is read-only
---@param message string? Optional message
---@return boolean? success Returns true if successful, nil on error
---@usage MarkToAll(1001, "Target", {x=1000, y=0, z=2000}, true)
function MarkToAll(markId, text, pos, readOnly, message) end

--- Creates a map mark visible to a specific coalition
---@param markId number Unique ID for the mark
---@param text string? Text to display (default: "")
---@param pos table Position table with x, y, z coordinates
---@param coalitionId number The coalition ID (0=neutral, 1=red, 2=blue)
---@param readOnly boolean? Whether the mark is read-only
---@param message string? Optional message
---@return boolean? success Returns true if successful, nil on error
---@usage MarkToCoalition(1001, "Enemy Base", {x=1000, y=0, z=2000}, coalition.side.RED, true)
function MarkToCoalition(markId, text, pos, coalitionId, readOnly, message) end

--- Creates a map mark visible to a specific group
---@param markId number Unique ID for the mark
---@param text string? Text to display (default: "")
---@param pos table Position table with x, y, z coordinates
---@param groupId number The group ID
---@param readOnly boolean? Whether the mark is read-only
---@param message string? Optional message
---@return boolean? success Returns true if successful, nil on error
---@usage MarkToGroup(1001, "Waypoint", {x=1000, y=0, z=2000}, 501, false)
function MarkToGroup(markId, text, pos, groupId, readOnly, message) end

--- Sets an AI task for a group
---@param group table The group object
---@param actionIndex number Group action index (as defined in mission editor)
---@return boolean? success Returns true if successful, nil on error
---@usage SetAITask(group, 1)
function SetAITask(group, actionIndex) end

--- Pushes an AI task to a group's task queue
---@param group table The group object
---@param actionIndex number Group action index (as defined in mission editor)
---@return boolean? success Returns true if successful, nil on error
---@usage PushAITask(group, 1)
function PushAITask(group, actionIndex) end

--- Activates a group using trigger action
---@param group table The group object to activate
---@return boolean? success Returns true if successful, nil on error
---@usage TriggerActivateGroup(group)
function TriggerActivateGroup(group) end

--- Deactivates a group using trigger action
---@param group table The group object to deactivate
---@return boolean? success Returns true if successful, nil on error
---@usage TriggerDeactivateGroup(group)
function TriggerDeactivateGroup(group) end

--- Enables AI for a group
---@param group table The group object
---@return boolean? success Returns true if successful, nil on error
---@usage SetGroupAIOn(group)
function SetGroupAIOn(group) end

--- Disables AI for a group
---@param group table The group object
---@return boolean? success Returns true if successful, nil on error
---@usage SetGroupAIOff(group)
function SetGroupAIOff(group) end

--- Stops a group from moving
---@param group table The group object
---@return boolean? success Returns true if successful, nil on error
---@usage GroupStopMoving(group)
function GroupStopMoving(group) end

--- Resumes movement for a stopped group
---@param group table The group object
---@return boolean? success Returns true if successful, nil on error
---@usage GroupContinueMoving(group)
function GroupContinueMoving(group) end

--- Creates a shape on the F10 map visible to all players
---@param shapeId number Shape type ID (1=Line, 2=Circle, 3=Rect, 4=Arrow, 5=Text, 6=Quad, 7=Freeform)
---@param coalition number Coalition ID (-1=All, 0=Neutral, 1=Red, 2=Blue)
---@param id number Unique ID for the shape (shared with mark panels)
---@param point1 table First point with x, y, z coordinates
---@param ... any Additional parameters depending on shape type
---@return boolean? success Returns true if successful, nil on error
---@usage MarkupToAll(2, -1, 1001, {x=1000, y=0, z=2000}, 500, {1, 0, 0, 1}, {1, 0, 0, 0.3}, 1, false, "Circle Zone")
---@usage MarkupToAll(7, -1, 1002, point1, point2, point3, point4, point5, point6, {0, .6, .6, 1}, {0.8, 0.8, 0.8, .3}, 4)
function MarkupToAll(shapeId, coalition, id, point1, ...) end

--- Get unit by name with validation and error handling
---@param unitName string The name of the unit to retrieve
---@return table? unit The unit object if found, nil otherwise
---@usage local unit = GetUnit("Player")
function GetUnit(unitName) end

--- Check if unit exists and is active
---@param unitName string The name of the unit to check
---@return boolean exists True if unit exists and is active, false otherwise
---@usage if UnitExists("Player") then ... end
function UnitExists(unitName) end

--- Get unit position
---@param unitOrName string|table The name of the unit or unit object
---@return table? position The position {x, y, z} if found, nil otherwise
---@usage local pos = GetUnitPosition("Player") or GetUnitPosition(unitObject)
function GetUnitPosition(unitOrName) end

--- Get unit heading in degrees
---@param unitName string The name of the unit
---@return number? heading The heading in degrees (0-360) if found, nil otherwise
---@usage local heading = GetUnitHeading("Player")
function GetUnitHeading(unitName) end

--- Get unit velocity
---@param unitName string The name of the unit
---@return table? velocity The velocity vector {x, y, z} if found, nil otherwise
---@usage local vel = GetUnitVelocity("Player")
function GetUnitVelocity(unitName) end

--- Get unit speed magnitude in meters per second
---@param unitName string
---@return number? speedMps
---@usage local v = GetUnitSpeedMps("Player")
function GetUnitSpeedMps(unitName) end

--- Get unit speed magnitude in knots
---@param unitName string
---@return number? speedKts
---@usage local kts = GetUnitSpeedKnots("Player")
function GetUnitSpeedKnots(unitName) end

--- Get unit vertical speed in feet per second
---@param unitName string
---@return number? feetPerSecond
---@usage local vs = GetUnitVerticalSpeedFeet("Player")
function GetUnitVerticalSpeedFeet(unitName) end

--- Get unit altitude MSL in feet
---@param unitName string
---@return number? feetMSL
---@usage local alt = GetUnitAltitudeMSLFeet("Player")
function GetUnitAltitudeMSLFeet(unitName) end

--- Get unit altitude AGL in feet
---@param unitName string
---@return number? feetAGL
---@usage local agl = GetUnitAltitudeAGLFeet("Player")
function GetUnitAltitudeAGLFeet(unitName) end

--- Get unit type name
---@param unitName string The name of the unit
---@return string? typeName The unit type name if found, nil otherwise
---@usage local type = GetUnitType("Player")
function GetUnitType(unitName) end

--- Get unit coalition
---@param unitOrName string|table The name of the unit or unit object
---@return number coalition The coalition ID (0 if unit not found or error)
---@usage local coalition = GetUnitCoalition("Player") or GetUnitCoalition(unitObject)
function GetUnitCoalition(unitOrName) end

--- Get unit country
---@param unitName string The name of the unit
---@return number? country The country ID if found, nil otherwise
---@usage local country = GetUnitCountry("Player")
function GetUnitCountry(unitName) end

--- Get unit group
---@param unitName string The name of the unit
---@return table? group The group object if found, nil otherwise
---@usage local group = GetUnitGroup("Player")
function GetUnitGroup(unitName) end

--- Get unit player name (if player controlled)
---@param unitName string The name of the unit
---@return string? playerName The player name if unit is player-controlled, nil otherwise
---@usage local playerName = GetUnitPlayerName("Player")
function GetUnitPlayerName(unitName) end

--- Get unit life/health
---@param unitName string The name of the unit
---@return number? life The current life/health if found, nil otherwise
---@usage local life = GetUnitLife("Player")
function GetUnitLife(unitName) end

--- Get unit maximum life/health
---@param unitName string The name of the unit
---@return number? maxLife The maximum life/health if found, nil otherwise
---@usage local maxLife = GetUnitLife0("Player")
function GetUnitLife0(unitName) end

--- Get unit fuel (0.0 to 1.0+)
---@param unitName string The name of the unit
---@return number? fuel The fuel level (0.0 to 1.0+) if found, nil otherwise
---@usage local fuel = GetUnitFuel("Player")
function GetUnitFuel(unitName) end

--- Check if unit is in air
---@param unitName string The name of the unit
---@return boolean inAir True if unit is in air, false otherwise
---@usage if IsUnitInAir("Player") then ... end
function IsUnitInAir(unitName) end

--- Get unit ammo
---@param unitName string The name of the unit
---@return table? ammo The ammo table if found, nil otherwise
---@usage local ammo = GetUnitAmmo("Player")
function GetUnitAmmo(unitName) end

--- Get unit ID
---@param unit table Unit object
---@return number? id Unit ID or nil on error
---@usage local id = GetUnitID(unit)
function GetUnitID(unit) end

--- Get unit number within group
---@param unit table Unit object
---@return number? number Unit number or nil on error
---@usage local num = GetUnitNumber(unit)
function GetUnitNumber(unit) end

--- Get unit callsign
---@param unit table Unit object
---@return string? callsign Unit callsign or nil on error
---@usage local callsign = GetUnitCallsign(unit)
function GetUnitCallsign(unit) end

--- Get unit object ID
---@param unit table Unit object
---@return number? objectId Object ID or nil on error
---@usage local objId = GetUnitObjectID(unit)
function GetUnitObjectID(unit) end

--- Get unit category extended
---@param unit table Unit object
---@return number? category Extended category or nil on error
---@usage local cat = GetUnitCategoryEx(unit)
function GetUnitCategoryEx(unit) end

--- Get unit description
---@param unit table Unit object
---@return table? desc Unit description table or nil on error
---@usage local desc = GetUnitDesc(unit)
function GetUnitDesc(unit) end

--- Get unit forces name
---@param unit table Unit object
---@return string? forcesName Forces name or nil on error
---@usage local forces = GetUnitForcesName(unit)
function GetUnitForcesName(unit) end

--- Check if unit is active
---@param unit table Unit object
---@return boolean active True if unit is active
---@usage if IsUnitActive(unit) then ... end
function IsUnitActive(unit) end

--- Get unit controller
---@param unit table Unit object
---@return table? controller Unit controller or nil on error
---@usage local controller = GetUnitController(unit)
function GetUnitController(unit) end

--- Get unit sensors
---@param unit table Unit object
---@return table? sensors Sensors table or nil on error
---@usage local sensors = GetUnitSensors(unit)
function GetUnitSensors(unit) end

--- Check if unit has sensors
---@param unit table Unit object
---@param sensorType number? Sensor type to check
---@param subCategory number? Sensor subcategory
---@return boolean hasSensors True if unit has specified sensors
---@usage if UnitHasSensors(unit, Sensor.RADAR) then ... end
function UnitHasSensors(unit, sensorType, subCategory) end

--- Get unit radar
---@param unit table Unit object
---@return boolean active True if radar is active
---@return table? target Tracked target or nil
---@usage local active, target = GetUnitRadar(unit)
function GetUnitRadar(unit) end

--- Enable/disable unit emissions
---@param unit table Unit object
---@param enabled boolean True to enable emissions
---@return boolean success True if emissions were set
---@usage EnableUnitEmissions(unit, false) -- Go dark
function EnableUnitEmissions(unit, enabled) end

--- Get nearest cargo objects
---@param unit table Unit object
---@return table cargos Array of nearby cargo objects
---@usage local cargos = GetUnitNearestCargos(unit)
function GetUnitNearestCargos(unit) end

--- Get cargo objects on board
---@param unit table Unit object
---@return table cargos Array of cargo objects on board
---@usage local cargos = GetUnitCargosOnBoard(unit)
function GetUnitCargosOnBoard(unit) end

--- Get unit descent capacity
---@param unit table Unit object
---@return number? capacity Infantry capacity or nil on error
---@usage local capacity = GetUnitDescentCapacity(unit)
function GetUnitDescentCapacity(unit) end

--- Get troops on board
---@param unit table Unit object
---@return table? troops Troops info or nil on error
---@usage local troops = GetUnitDescentOnBoard(unit)
function GetUnitDescentOnBoard(unit) end

--- Load cargo/troops on board
---@param unit table Unit object
---@param cargo table Cargo or troops to load
---@return boolean success True if loaded
---@usage LoadUnitCargo(transportUnit, cargoObject)
function LoadUnitCargo(unit, cargo) end

--- Unload cargo
---@param unit table Unit object
---@param cargo table? Specific cargo to unload or nil for all
---@return boolean success True if unloaded
---@usage UnloadUnitCargo(transportUnit)
function UnloadUnitCargo(unit, cargo) end

--- Open unit ramp
---@param unit table Unit object
---@return boolean success True if ramp opened
---@usage OpenUnitRamp(transportUnit)
function OpenUnitRamp(unit) end

--- Check if ramp is open
---@param unit table Unit object
---@return boolean? isOpen True if ramp is open, nil on error
---@usage if CheckUnitRampOpen(unit) then ... end
function CheckUnitRampOpen(unit) end

--- Start disembarking troops
---@param unit table Unit object
---@return boolean success True if disembarking started
---@usage DisembarkUnit(transportUnit)
function DisembarkUnit(unit) end

--- Mark disembarking task
---@param unit table Unit object
---@return boolean success True if marked
---@usage MarkUnitDisembarkingTask(transportUnit)
function MarkUnitDisembarkingTask(unit) end

--- Check if unit is embarking
---@param unit table Unit object
---@return boolean? embarking True if embarking, nil on error
---@usage if IsUnitEmbarking(unit) then ... end
function IsUnitEmbarking(unit) end

--- Get unit airbase
---@param unit table Unit object
---@return table? airbase Airbase object or nil
---@usage local airbase = GetUnitAirbase(unit)
function GetUnitAirbase(unit) end

--- Check if unit can land on ship
---@param unit table Unit object
---@return boolean? canLand True if can land on ship, nil on error
---@usage if UnitCanShipLanding(unit) then ... end
function UnitCanShipLanding(unit) end

--- Check if unit has carrier capabilities
---@param unit table Unit object
---@return boolean? hasCarrier True if has carrier capabilities, nil on error
---@usage if UnitHasCarrier(unit) then ... end
function UnitHasCarrier(unit) end

--- Get nearest cargo for aircraft
---@param unit table Unit object
---@return table cargos Array of cargo objects
---@usage local cargos = GetUnitNearestCargosForAircraft(unit)
function GetUnitNearestCargosForAircraft(unit) end

--- Get unit fuel low state
---@param unit table Unit object
---@return number? threshold Fuel low threshold or nil on error
---@usage local lowFuel = GetUnitFuelLowState(unit)
function GetUnitFuelLowState(unit) end

--- Show old carrier menu
---@param unit table Unit object
---@return boolean success True if shown
---@usage ShowUnitCarrierMenu(unit)
function ShowUnitCarrierMenu(unit) end

--- Get draw argument value
---@param unit table Unit object
---@param arg number Animation argument number
---@return number? value Draw argument value or nil on error
---@usage local gearPos = GetUnitDrawArgument(unit, 0) -- Landing gear
function GetUnitDrawArgument(unit, arg) end

--- Get unit communicator
---@param unit table Unit object
---@return table? communicator Communicator object or nil on error
---@usage local comm = GetUnitCommunicator(unit)
function GetUnitCommunicator(unit) end

--- Get unit seats
---@param unit table Unit object
---@return table? seats Seats info or nil on error
---@usage local seats = GetUnitSeats(unit)
function GetUnitSeats(unit) end

--- Creates a 2D vector (x, z coordinates)
---@param x number|table? X coordinate or table {x, z} or {[1], [2]}
---@param z number? Z coordinate (if x is not a table)
---@return table vec2 New Vec2 instance with metatables
---@usage local v = Vec2(100, 200) or Vec2({x=100, z=200})
function Vec2(x, z) end

--- Creates a 3D vector (x, y, z coordinates)
---@param x number|table? X coordinate or table {x, y, z} or {[1], [2], [3]}
---@param y number? Y coordinate (if x is not a table)
---@param z number? Z coordinate (if x is not a table)
---@return table vec3 New Vec3 instance with metatables
---@usage local v = Vec3(100, 50, 200) or Vec3({x=100, y=50, z=200})
function Vec3(x, y, z) end

--- Check if valid 3D vector (works with plain tables or Vec3 instances)
---@param vec any Value to check
---@return boolean isValid True if vec has numeric x, y, z components
---@usage if IsVec3(pos) then ... end
function IsVec3(vec) end

--- Check if valid 2D vector (works with plain tables or Vec2 instances)
---@param vec any Value to check
---@return boolean isValid True if vec has numeric x, z components (or x, y for DCS compat)
---@usage if IsVec2(pos) then ... end
function IsVec2(vec) end

--- Convert to Vec2 (from table, Vec2, or Vec3)
---@param t any Input value to convert
---@return table? vec2 Converted Vec2 or nil on error
---@usage local v2 = ToVec2({x=100, z=200})
function ToVec2(t) end

--- Convert to Vec3 (from table, Vec2, or Vec3)
---@param t any Input value to convert
---@param altitude number? Y coordinate for Vec2 to Vec3 conversion (default 0)
---@return table? vec3 Converted Vec3 or nil on error
---@usage local v3 = ToVec3({x=100, y=50, z=200})
function ToVec3(t, altitude) end

--- Add vectors
---@param a table First vector
---@param b table Second vector
---@return table result Vector sum of a + b
---@usage local sum = VecAdd(v1, v2)
function VecAdd(a, b) end

--- Subtract vectors
---@param a table First vector
---@param b table Second vector
---@return table result Vector difference of a - b
---@usage local diff = VecSub(v1, v2)
function VecSub(a, b) end

--- Multiply vector by scalar
---@param vec table Vector to scale
---@param scalar number Scale factor
---@return table result Scaled vector
---@usage local scaled = VecScale(v, 2.5)
function VecScale(vec, scalar) end

--- Divide vector by scalar
---@param vec table Vector to divide
---@param scalar number Divisor (must not be 0)
---@return table result Divided vector
---@usage local divided = VecDiv(v, 2)
function VecDiv(vec, scalar) end

--- Get vector length
---@param vec table Vector
---@return number length 3D length/magnitude
---@usage local len = VecLength(v)
function VecLength(vec) end

--- Get 2D vector length (ignoring Y)
---@param vec table Vector
---@return number length 2D length in XZ plane
---@usage local len2d = VecLength2D(v)
function VecLength2D(vec) end

--- Normalize vector
---@param vec table Vector to normalize
---@return table normalized Unit vector (length 1) or zero vector
---@usage local unit = VecNormalize(v)
function VecNormalize(vec) end

--- Normalize 2D vector (preserving Y)
---@param vec table Vec3 to normalize in XZ plane
---@return table normalized Vec3 with unit XZ, preserved Y
---@usage local unit2d = VecNormalize2D(v)
function VecNormalize2D(vec) end

--- Dot product
---@param a table First vector
---@param b table Second vector
---@return number dot Dot product a·b
---@usage local dot = VecDot(v1, v2)
function VecDot(a, b) end

--- Cross product (3D only)
---@param a table First Vec3
---@param b table Second Vec3
---@return table cross Vec3 cross product a×b
---@usage local cross = VecCross(v1, v2)
function VecCross(a, b) end

--- Get distance between two points
---@param a table First position
---@param b table Second position
---@return number distance 3D distance
---@usage local dist = Distance(pos1, pos2)
function Distance(a, b) end

--- Get 2D distance between two points
---@param a table First position
---@param b table Second position
---@return number distance 2D distance in XZ plane
---@usage local dist2d = Distance2D(pos1, pos2)
function Distance2D(a, b) end

--- Get squared distance (avoids sqrt)
---@param a table First position
---@param b table Second position
---@return number distanceSquared 3D distance squared
---@usage local distSq = DistanceSquared(pos1, pos2)
function DistanceSquared(a, b) end

--- Get squared 2D distance
---@param a table First position
---@param b table Second position
---@return number distanceSquared 2D distance squared in XZ plane
---@usage local dist2dSq = Distance2DSquared(pos1, pos2)
function Distance2DSquared(a, b) end

--- Get bearing from one point to another (degrees)
---@param from table Source position
---@param to table Target position
---@return number bearing Bearing in degrees (0-360)
---@usage local bearing = Bearing(myPos, targetPos)
function Bearing(from, to) end

--- Get position from bearing and distance
---@param origin table Origin position
---@param bearing number Bearing in degrees
---@param distance number Distance in meters
---@return table position New position
---@usage local newPos = FromBearingDistance(pos, 45, 1000)
function FromBearingDistance(origin, bearing, distance) end

--- Get angle between vectors (degrees)
---@param a table First vector
---@param b table Second vector
---@return number angle Angle in degrees (0-180)
---@usage local angle = AngleBetween(v1, v2)
function AngleBetween(a, b) end

--- Get midpoint between two points
---@param a table First position
---@param b table Second position
---@return table midpoint Position at center between a and b
---@usage local mid = Midpoint(pos1, pos2)
function Midpoint(a, b) end

--- Linear interpolation between vectors
---@param a table Start vector
---@param b table End vector
---@param t number Interpolation factor (0 to 1)
---@return table interpolated Vector between a and b
---@usage local interp = VecLerp(v1, v2, 0.5)
function VecLerp(a, b, t) end

--- Convert Vec3 to string for debugging
---@param vec table Vec3 to convert
---@param precision number? Decimal places (default 2)
---@return string formatted String representation "(x, y, z)"
---@usage print(Vec3ToString(pos, 1))
function Vec3ToString(vec, precision) end

--- Convert Vec2 to string for debugging
---@param vec table Vec2 to convert
---@param precision number? Decimal places (default 2)
---@return string formatted String representation "(x, z)"
---@usage print(Vec2ToString(pos, 1))
function Vec2ToString(vec, precision) end

--- Finds intersection point of two 2D line segments
--- @param p1 table First point of first line segment {x, z}
--- @param p2 table Second point of first line segment {x, z}
--- @param p3 table First point of second line segment {x, z}
--- @param p4 table Second point of second line segment {x, z}
--- @return table|nil intersection Point of intersection {x, y, z} or nil if no intersection
--- @usage local pt = LineSegmentIntersection2D({x=0,z=0}, {x=10,z=10}, {x=0,z=10}, {x=10,z=0})
function LineSegmentIntersection2D(p1, p2, p3, p4) end

--- Finds all intersection points between two polygons
--- @param poly1 table Array of points defining first polygon
--- @param poly2 table Array of points defining second polygon
--- @return table intersections Array of intersection data with point and edge info
--- @usage local intersections = FindPolygonIntersections(shape1, shape2)
function FindPolygonIntersections(poly1, poly2) end

--- Merges two polygons with option to keep interior points
--- @param poly1 table Array of points defining first polygon
--- @param poly2 table Array of points defining second polygon
--- @param keepInterior boolean? Whether to keep interior points (default: false)
--- @return table|nil merged Merged polygon points or nil on error
--- @usage local merged = MergePolygons(shape1, shape2, false)
function MergePolygons(poly1, poly2, keepInterior) end

--- Creates union of two polygons (combines and keeps outer boundary)
--- @param poly1 table Array of points defining first polygon
--- @param poly2 table Array of points defining second polygon
--- @return table|nil union Combined polygon boundary or nil on error
--- @usage local union = UnionPolygons(shape1, shape2)
function UnionPolygons(poly1, poly2) end

--- Creates intersection of two polygons (overlapping area)
--- @param poly1 table Array of points defining first polygon
--- @param poly2 table Array of points defining second polygon
--- @return table|nil intersection Overlapping area points or nil on error
--- @usage local overlap = IntersectPolygons(shape1, shape2)
function IntersectPolygons(poly1, poly2) end

--- Creates difference of two polygons (poly1 minus poly2)
--- @param poly1 table Array of points defining first polygon
--- @param poly2 table Array of points defining second polygon to subtract
--- @return table|nil difference Remaining area points or nil on error
--- @usage local diff = DifferencePolygons(shape1, shape2)
function DifferencePolygons(poly1, poly2) end

--- Simplifies a polygon by removing unnecessary points
--- @param polygon table Array of points defining the polygon
--- @param tolerance number? Maximum allowed deviation in meters (default: 1.0)
--- @return table simplified Simplified polygon points
--- @usage local simple = SimplifyPolygon(complexShape, 10)
function SimplifyPolygon(polygon, tolerance) end

--- Calculates perpendicular distance from point to line
--- @param point table Point to measure from {x, z}
--- @param lineStart table Start point of line {x, z}
--- @param lineEnd table End point of line {x, z}
--- @return number distance Distance in meters
--- @usage local dist = PerpendicularDistance2D({x=5,z=5}, {x=0,z=0}, {x=10,z=0})
function PerpendicularDistance2D(point, lineStart, lineEnd) end

--- Offsets a polygon by a specified distance (inward or outward)
--- @param polygon table Array of points defining the polygon
--- @param distance number Offset distance in meters (positive = outward)
--- @return table|nil offset Offset polygon points or nil on error
--- @usage local expanded = OffsetPolygon(shape, 100)
function OffsetPolygon(polygon, distance) end

--- Clips one polygon to another using Sutherland-Hodgman algorithm
--- @param subject table Array of points defining polygon to clip
--- @param clip table Array of points defining clipping polygon
--- @return table|nil clipped Clipped polygon points or nil on error
--- @usage local clipped = ClipPolygonToPolygon(shape, boundary)
function ClipPolygonToPolygon(subject, clip) end

--- Triangulates a polygon into triangles using ear clipping
--- @param polygon table Array of points defining the polygon
--- @return table triangles Array of triangles, each with 3 vertices
--- @usage local triangles = TriangulatePolygon(shape)
function TriangulatePolygon(polygon) end

--- Checks if a point is inside a 2D triangle
--- @param p table Point to test {x, z}
--- @param a table First vertex of triangle {x, z}
--- @param b table Second vertex of triangle {x, z}
--- @param c table Third vertex of triangle {x, z}
--- @return boolean inside True if point is inside triangle
--- @usage local inside = PointInTriangle2D({x=5,z=5}, {x=0,z=0}, {x=10,z=0}, {x=5,z=10})
function PointInTriangle2D(p, a, b, c) end

--- Gets the type name of a weapon
---@param weapon table The weapon object
---@return string? typeName The weapon type name or nil on error
---@usage local typeName = GetWeaponTypeName(weapon)
function GetWeaponTypeName(weapon) end

--- Gets the description of a weapon
---@param weapon table The weapon object
---@return table? desc The weapon description table or nil on error
---@usage local desc = GetWeaponDesc(weapon)
function GetWeaponDesc(weapon) end

--- Gets the launcher unit of a weapon
---@param weapon table The weapon object
---@return table? launcher The launcher unit object or nil on error
---@usage local launcher = GetWeaponLauncher(weapon)
function GetWeaponLauncher(weapon) end

--- Gets the target of a weapon
---@param weapon table The weapon object
---@return table? target The target object or nil if no target
---@usage local target = GetWeaponTarget(weapon)
function GetWeaponTarget(weapon) end

--- Gets the category of a weapon
---@param weapon table The weapon object
---@return number? category The weapon category or nil on error
---@usage local category = GetWeaponCategory(weapon)
function GetWeaponCategory(weapon) end

--- Checks if a weapon exists
---@param weapon table The weapon object to check
---@return boolean? exists Returns true if exists, false if not, nil on error
---@usage local exists = IsWeaponExist(weapon)
function IsWeaponExist(weapon) end

--- Gets the coalition of a weapon
---@param weapon table The weapon object
---@return number? coalition The coalition ID or nil on error
---@usage local coalition = GetWeaponCoalition(weapon)
function GetWeaponCoalition(weapon) end

--- Gets the country of a weapon
---@param weapon table The weapon object
---@return number? country The country ID or nil on error
---@usage local country = GetWeaponCountry(weapon)
function GetWeaponCountry(weapon) end

--- Gets the 3D position point of a weapon
---@param weapon table The weapon object
---@return table? point Position table with x, y, z coordinates or nil on error
---@usage local point = GetWeaponPoint(weapon)
function GetWeaponPoint(weapon) end

--- Gets the position and orientation of a weapon
---@param weapon table The weapon object
---@return table? position Position table with p (point) and x,y,z vectors or nil on error
---@usage local pos = GetWeaponPosition(weapon)
function GetWeaponPosition(weapon) end

--- Gets the velocity vector of a weapon
---@param weapon table The weapon object
---@return table? velocity Velocity vector with x, y, z components or nil on error
---@usage local vel = GetWeaponVelocity(weapon)
function GetWeaponVelocity(weapon) end

--- Gets the name of a weapon
---@param weapon table The weapon object
---@return string? name The weapon name or nil on error
---@usage local name = GetWeaponName(weapon)
function GetWeaponName(weapon) end

--- Destroys a weapon
---@param weapon table The weapon object to destroy
---@return boolean? success Returns true if successful, nil on error
---@usage DestroyWeapon(weapon)
function DestroyWeapon(weapon) end

--- Gets the category name of a weapon
---@param weapon table The weapon object
---@return string? categoryName The weapon category name or nil on error
---@usage local catName = GetWeaponCategoryName(weapon)
function GetWeaponCategoryName(weapon) end

--- Checks if a weapon is active
---@param weapon table The weapon object to check
---@return boolean? active Returns true if active, false if not, nil on error
---@usage local active = IsWeaponActive(weapon)
function IsWeaponActive(weapon) end

--- Adds an event handler to the world
---@param handler table Event handler table with onEvent function
---@return boolean? success Returns true if successful, nil on error
---@usage AddWorldEventHandler({onEvent = function(self, event) ... end})
function AddWorldEventHandler(handler) end

--- Removes an event handler from the world
---@param handler table The event handler table to remove
---@return boolean? success Returns true if successful, nil on error
---@usage RemoveWorldEventHandler(myHandler)
function RemoveWorldEventHandler(handler) end

--- Gets the player unit in the world
---@return table? player The player unit object or nil if not found
---@usage local player = GetWorldPlayer()
function GetWorldPlayer() end

--- Gets all airbases in the world
---@return table? airbases Array of airbase objects or nil on error
---@usage local airbases = GetWorldAirbases()
function GetWorldAirbases() end

--- Searches for objects in the world within a volume
---@param category number? Object category to search for
---@param volume table? Search volume definition
---@param objectFilter function? Filter function for objects
---@return table? objects Array of found objects or nil on error
---@usage local objects = SearchWorldObjects(Object.Category.UNIT, sphereVolume)
function SearchWorldObjects(category, volume, objectFilter) end

--- Gets all mark panels in the world
---@return table? panels Array of mark panel objects or nil on error
---@usage local panels = getMarkPanels()
function GetMarkPanels() end

--- Processes a world event
---@param event table The event table to process
---@return boolean? success Returns true if successful, nil on error
---@usage OnWorldEvent({id = world.event.S_EVENT_SHOT, ...})
function OnWorldEvent(event) end

--- Gets fog-related weather values if available (DCS 2.9.10+)
---@return table? weather Table with fog fields if available { fogThickness, fogVisibilityDistance, fogAnimationEnabled }
---@usage local weather = GetWorldWeather()
function GetWorldWeather() end

--- Get fog thickness in meters
---@return number? thickness Fog thickness in meters or nil if unsupported/error
---@usage local t = GetFogThickness()
function GetFogThickness() end

--- Set fog thickness in meters
---@param thickness number Non-negative thickness in meters
---@return boolean? success True on success, nil on error
---@usage SetFogThickness(300)
function SetFogThickness(thickness) end

--- Get fog visibility distance in meters
---@return number? distance Visibility distance in meters or nil if unsupported/error
---@usage local d = GetFogVisibilityDistance()
function GetFogVisibilityDistance() end

--- Set fog visibility distance in meters
---@param distance number Non-negative distance in meters
---@return boolean? success True on success, nil on error
---@usage SetFogVisibilityDistance(800)
function SetFogVisibilityDistance(distance) end

--- Enable or disable fog animation
---@param enabled boolean Whether to enable fog animation
---@return boolean? success True on success, nil on error
---@usage SetFogAnimation(true)
function SetFogAnimation(enabled) end

--- Removes junk objects within a search volume
---@param searchVolume table The search volume definition
---@return number? count Number of objects removed or nil on error
---@usage local removed = RemoveWorldJunk(sphereVolume)
function RemoveWorldJunk(searchVolume) end

--- Creates a world event handler with named event callbacks
---@param handlers table Table of event name to callback function mappings
---@return table? eventHandler Event handler object or nil on error
---@usage local handler = CreateWorldEventHandler({S_EVENT_SHOT = function(event) ... end})
function CreateWorldEventHandler(handlers) end

--- Gets all world event type constants
---@return table? eventTypes Table of event name to ID mappings or nil on error
---@usage local eventTypes = GetWorldEventTypes()
function GetWorldEventTypes() end

--- Gets all world volume type constants
---@return table? volumeTypes Table of volume type constants or nil on error
---@usage local volumeTypes = GetWorldVolumeTypes()
function GetWorldVolumeTypes() end

--- Creates a search volume for world object searches
---@param volumeType number The volume type constant
---@param params table Parameters for the volume type
---@return table? volume Volume definition or nil on error
---@usage local volume = CreateWorldSearchVolume(world.VolumeType.SPHERE, {point={x=0,y=0,z=0}, radius=1000})
function CreateWorldSearchVolume(volumeType, params) end

--- Creates a spherical search volume
---@param center table Center position with x, y, z coordinates
---@param radius number Sphere radius in meters
---@return table? volume Sphere volume definition or nil on error
---@usage local sphere = CreateSphereVolume({x=1000, y=100, z=2000}, 500)
function CreateSphereVolume(center, radius) end

--- Creates a box-shaped search volume
---@param min table Minimum corner position with x, y, z coordinates
---@param max table Maximum corner position with x, y, z coordinates
---@return table? volume Box volume definition or nil on error
---@usage local box = CreateBoxVolume({x=0, y=0, z=0}, {x=1000, y=500, z=1000})
function CreateBoxVolume(min, max) end

--- Creates a pyramid-shaped search volume
---@param pos table Position and orientation table
---@param length number Length of the pyramid in meters
---@param halfAngleHor number Horizontal half angle in radians
---@param halfAngleVer number Vertical half angle in radians
---@return table? volume Pyramid volume definition or nil on error
---@usage local pyramid = CreatePyramidVolume({x=0, y=100, z=0}, 5000, math.rad(30), math.rad(20))
function CreatePyramidVolume(pos, length, halfAngleHor, halfAngleVer) end

--- Creates a line segment search volume
---@param from table Start position with x, y, z coordinates
---@param to table End position with x, y, z coordinates
---@return table? volume Segment volume definition or nil on error
---@usage local segment = CreateSegmentVolume({x=0, y=100, z=0}, {x=1000, y=100, z=1000})
function CreateSegmentVolume(from, to) end

--- Get zone by name
---@param zoneName string The name of the zone to retrieve
---@return table? zone The zone object if found, nil otherwise
---@usage local zone = GetZone("LZ Alpha")
function GetZone(zoneName) end

--- Get zone position
---@param zoneName string The name of the zone
---@return table? position The zone center position as Vec3 if found, nil otherwise
---@usage local pos = GetZonePosition("LZ Alpha")
function GetZonePosition(zoneName) end

--- Get zone radius
---@param zoneName string The name of the zone
---@return number? radius The zone radius if found, nil otherwise
---@usage local radius = GetZoneRadius("LZ Alpha")
function GetZoneRadius(zoneName) end

--- Check if point is in zone
---@param position table Vec3 position to check
---@param zoneName string The name of the zone
---@return boolean inZone True if position is within zone (handles both circular and polygon zones)
---@usage if IsInZone(pos, "LZ Alpha") then ... end
function IsInZone(position, zoneName) end

--- Check if unit is in zone
---@param unitName string The name of the unit
---@param zoneName string The name of the zone
---@return boolean inZone True if unit is within zone radius
---@usage if IsUnitInZone("Player", "LZ Alpha") then ... end
function IsUnitInZone(unitName, zoneName) end

--- Check if group is in zone (any unit)
---@param groupName string The name of the group
---@param zoneName string The name of the zone
---@return boolean inZone True if any unit of the group is in zone
---@usage if IsGroupInZone("Aerial-1", "LZ Alpha") then ... end
function IsGroupInZone(groupName, zoneName) end

--- Check if entire group is in zone (all units)
---@param groupName string The name of the group
---@param zoneName string The name of the zone
---@return boolean inZone True if all units of the group are in zone
---@usage if IsGroupCompletelyInZone("Aerial-1", "LZ Alpha") then ... end
function IsGroupCompletelyInZone(groupName, zoneName) end

--- Get units in zone
---@param zoneName string The name of the zone
---@param coalitionId number? Optional coalition ID to filter by (0=neutral, 1=red, 2=blue)
---@return table units Array of unit objects found in zone
---@usage local units = GetUnitsInZone("LZ Alpha", coalition.side.BLUE)
function GetUnitsInZone(zoneName, coalitionId) end

--- Get groups in zone
---@param zoneName string The name of the zone
---@param coalitionId number? Optional coalition ID to filter by (0=neutral, 1=red, 2=blue)
---@return table groups Array of group objects found in zone
---@usage local groups = GetGroupsInZone("LZ Alpha", coalition.side.BLUE)
function GetGroupsInZone(zoneName, coalitionId) end

--- Create random position in zone
---@param zoneName string The name of the zone
---@param inner number? Minimum distance from center (default 0)
---@param outer number? Maximum distance from center (default zone radius)
---@return table? position Random Vec3 position within zone, nil if zone not found
---@usage local randPos = RandomPointInZone("LZ Alpha", 100, 500)
function RandomPointInZone(zoneName, inner, outer) end

--- Check if point is in polygon zone
---@param point table Vec3 position to check
---@param vertices table Array of Vec3 vertices defining the polygon
---@return boolean inZone True if point is inside the polygon
---@usage if IsInPolygonZone(pos, {v1, v2, v3, v4}) then ... end
function IsInPolygonZone(point, vertices) end

--- Get all trigger zones from the mission
---@return table? zones Array of trigger zone data or nil on error
function GetMissionZones() end

--- Process trigger zone geometry from mission data
---@param zone table Trigger zone data
---@return table? geometry Processed zone geometry or nil
function ProcessZoneGeometry(zone) end

--- Initialize trigger zone cache
---@return boolean success True if cache initialized successfully
function InitializeZoneCache() end

--- Get all cached trigger zones
---@return table Array of all trigger zone geometries
function GetAllZones() end

--- Get cached trigger zone by exact name
---@param name string Zone name
---@return table? zone Trigger zone geometry or nil if not found
function GetCachedZoneByName(name) end

--- Get cached trigger zone by ID
---@param zoneId number Zone ID
---@return table? zone Trigger zone geometry or nil if not found
function GetCachedZoneById(zoneId) end

--- Find cached trigger zones by partial name
---@param pattern string Name pattern to search for
---@return table Array of matching zone geometries
function FindZonesByName(pattern) end

--- Get all cached trigger zones of a specific type
---@param zoneType string Zone type (circle, polygon)
---@return table Array of zone geometries of the specified type
function GetZonesByType(zoneType) end

--- Check if a point is inside a cached trigger zone
---@param zone table Trigger zone geometry
---@param point table Point with x, z coordinates
---@return boolean isInside True if point is inside the zone
function IsPointInZoneGeometry(zone, point) end

--- Clear trigger zone cache
function ClearZoneCache() end

---@type EventBus
HarnessWorldEventBus = nil

