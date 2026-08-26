require("_header")
require("services.Services")

--[[
██╗   ██╗███╗   ██╗██╗████████╗     ██████╗ ███████╗ ██████╗  ██████╗ ██████╗ ██╗██████╗
██║   ██║████╗  ██║██║╚══██╔══╝    ██╔════╝ ██╔════╝██╔═══██╗██╔════╝ ██╔══██╗██║██╔══██╗
██║   ██║██╔██╗ ██║██║   ██║       ██║  ███╗█████╗  ██║   ██║██║  ███╗██████╔╝██║██║  ██║
██║   ██║██║╚██╗██║██║   ██║       ██║   ██║██╔══╝  ██║   ██║██║   ██║██╔══██╗██║██║  ██║
╚██████╔╝██║ ╚████║██║   ██║       ╚██████╔╝███████╗╚██████╔╝╚██████╔╝██║  ██║██║██████╔╝
 ╚═════╝ ╚═╝  ╚═══╝╚═╝   ╚═╝        ╚═════╝ ╚══════╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚═╝╚═════╝

]]

Medusa.Services.UnitGeoGrid = {}

do
	local Grid = Medusa.Services.UnitGeoGrid
	local floor = math.floor

	local function validPosition(position)
		return type(position) == "table"
			and type(position.x) == "number"
			and position.x == position.x
			and position.x > -math.huge
			and position.x < math.huge
			and type(position.y) == "number"
			and position.y == position.y
			and position.y > -math.huge
			and position.y < math.huge
			and type(position.z) == "number"
			and position.z == position.z
			and position.z > -math.huge
			and position.z < math.huge
	end

	local function copyPosition(position)
		return { x = position.x, y = position.y, z = position.z }
	end

	function Grid:new(cellSizeMeters)
		if type(cellSizeMeters) ~= "number" or cellSizeMeters <= 0 then
			error("UnitGeoGrid cell size must be positive")
		end
		local o = {
			_cellSizeMeters = cellSizeMeters,
			_cells = {},
			_locations = {},
			_count = 0,
		}
		setmetatable(o, { __index = self })
		return o
	end

	function Grid:_cellCoordinates(position)
		return floor(position.x / self._cellSizeMeters), floor(position.z / self._cellSizeMeters)
	end

	function Grid:_getCell(cx, cz, create)
		local column = self._cells[cx]
		if not column and create then
			column = {}
			self._cells[cx] = column
		end
		local cell = column and column[cz]
		if not cell and create then
			cell = { UnitIds = {} }
			column[cz] = cell
		end
		return cell
	end

	function Grid:_unlink(unitId, location)
		local ids = location.Cell.UnitIds
		local lastIndex = #ids
		local movedId = ids[lastIndex]
		ids[location.Index] = movedId
		ids[lastIndex] = nil
		if movedId and movedId ~= unitId then
			self._locations[movedId].Index = location.Index
		end
		local column = self._cells[location.Cx]
		if #ids == 0 and column then
			column[location.Cz] = nil
			if next(column) == nil then
				self._cells[location.Cx] = nil
			end
		end
		self._locations[unitId] = nil
	end

	function Grid:add(unitId, position)
		if unitId == nil or not validPosition(position) or self._locations[unitId] then
			return false
		end
		local cx, cz = self:_cellCoordinates(position)
		local cell = self:_getCell(cx, cz, true)
		local index = #cell.UnitIds + 1
		cell.UnitIds[index] = unitId
		self._locations[unitId] = {
			Cell = cell,
			Cx = cx,
			Cz = cz,
			Index = index,
			Position = copyPosition(position),
		}
		self._count = self._count + 1
		return true
	end

	function Grid:update(unitId, position)
		if unitId == nil or not validPosition(position) then
			return false
		end
		local location = self._locations[unitId]
		if not location then
			return self:add(unitId, position)
		end
		local cx, cz = self:_cellCoordinates(position)
		if cx == location.Cx and cz == location.Cz then
			location.Position = copyPosition(position)
			return true
		end
		self:_unlink(unitId, location)
		self._count = self._count - 1
		return self:add(unitId, position)
	end

	function Grid:remove(unitId)
		local location = self._locations[unitId]
		if not location then
			return false
		end
		self:_unlink(unitId, location)
		self._count = self._count - 1
		return true
	end

	function Grid:beginQuery(position, radiusMeters)
		if not validPosition(position) or type(radiusMeters) ~= "number" or radiusMeters < 0 or radiusMeters > self._cellSizeMeters then
			return nil
		end
		local cells = {}
		local minCx = floor((position.x - radiusMeters) / self._cellSizeMeters)
		local maxCx = floor((position.x + radiusMeters) / self._cellSizeMeters)
		local minCz = floor((position.z - radiusMeters) / self._cellSizeMeters)
		local maxCz = floor((position.z + radiusMeters) / self._cellSizeMeters)
		for cx = minCx, maxCx do
			for cz = minCz, maxCz do
				local cell = self:_getCell(cx, cz, false)
				if cell then
					cells[#cells + 1] = { Cell = cell, Index = 1, Limit = #cell.UnitIds }
				end
			end
		end
		return {
			Cells = cells,
			CellIndex = 1,
			Position = copyPosition(position),
			RadiusSquared = radiusMeters * radiusMeters,
			NearestVisitedDistanceSquared = nil,
		}
	end

	local function clear(output)
		for i = #output, 1, -1 do
			output[i] = nil
		end
	end

	local function nextUnit(cursor)
		while cursor.CellIndex <= #cursor.Cells do
			local state = cursor.Cells[cursor.CellIndex]
			local ids = state.Cell.UnitIds
			if state.Index <= state.Limit and state.Index <= #ids then
				local unitId = ids[state.Index]
				state.Index = state.Index + 1
				return unitId
			end
			cursor.CellIndex = cursor.CellIndex + 1
		end
		return nil
	end

	function Grid:continueQuery(cursor, visitBudget, output)
		local result = output or {}
		clear(result)
		if type(cursor) ~= "table" or type(visitBudget) ~= "number" or visitBudget < 1 then
			return 0, 0, true
		end
		local written = 0
		local visited = 0
		while visited < visitBudget do
			local unitId = nextUnit(cursor)
			if unitId == nil then
				break
			end
			visited = visited + 1
			local location = self._locations[unitId]
			if location then
				local dx = location.Position.x - cursor.Position.x
				local dy = location.Position.y - cursor.Position.y
				local dz = location.Position.z - cursor.Position.z
				local horizontalDistanceSquared = dx * dx + dz * dz
				local distanceSquared = horizontalDistanceSquared + dy * dy
				if not cursor.NearestVisitedDistanceSquared or distanceSquared < cursor.NearestVisitedDistanceSquared then
					cursor.NearestVisitedDistanceSquared = distanceSquared
				end
				if horizontalDistanceSquared <= cursor.RadiusSquared then
					written = written + 1
					result[written] = unitId
				end
			end
		end
		return written, visited, cursor.CellIndex > #cursor.Cells
	end

	function Grid:size()
		return self._count
	end
end
