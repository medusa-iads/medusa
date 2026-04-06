require("_header")
require("services.Services")
require("core.Constants")
require("core.Logger")

--[[
             █████╗ ██╗██████╗ ███████╗██████╗  █████╗  ██████╗███████╗
            ██╔══██╗██║██╔══██╗██╔════╝██╔══██╗██╔══██╗██╔════╝██╔════╝
            ███████║██║██████╔╝███████╗██████╔╝███████║██║     █████╗
            ██╔══██║██║██╔══██╗╚════██║██╔═══╝ ██╔══██║██║     ██╔══╝
            ██║  ██║██║██║  ██║███████║██║     ██║  ██║╚██████╗███████╗
            ╚═╝  ╚═╝╚═╝╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝  ╚═╝ ╚═════╝╚══════╝

    What this service does
    - Discovers border zone polygons from ME trigger zones and drawings by name.
    - Computes the ADIZ polygon as a convex hull expansion of the border.
    - Pre-converts border polygon vertices to lat/lon for metrics export.

    How others use it
    - IadsNetwork calls discover and computeADIZ at init time.
    - TrackClassifier uses the resulting polygons for zone containment checks.
    - MetricsSnapshotService reads the pre-converted lat/lon vertices for export.
--]]

Medusa.Services.AirspaceService = {}

local _logger = Medusa.Logger:ns("AirspaceService")

--- Discover border zone polygons from ME trigger zones and drawings.
--- @param zoneNames string[] List of zone/drawing names to find
--- @return table[] polygons List of polygon tables, each a list of {x, z} points
function Medusa.Services.AirspaceService.discover(zoneNames)
	local polygons = {}
	if not zoneNames or #zoneNames == 0 then
		return polygons
	end

	local nameSet = {}
	for i = 1, #zoneNames do
		nameSet[zoneNames[i]] = true
	end
	local found = {}

	-- Source 1: ME trigger zones (env.mission.triggers.zones)
	local zones = nil
	pcall(function()
		zones = env and env.mission and env.mission.triggers and env.mission.triggers.zones
	end)
	if zones then
		for _, zone in pairs(zones) do
			if zone.name and nameSet[zone.name] and not found[zone.name] then
				if zone.type == 0 then
					local cx, cz = zone.x, zone.y
					local r = zone.radius or 0
					if r > 0 then
						local poly = {}
						for s = 0, 31 do
							local angle = (s / 32) * 2 * math.pi
							poly[#poly + 1] = { x = cx + r * math.cos(angle), z = cz + r * math.sin(angle) }
						end
						polygons[#polygons + 1] = poly
						found[zone.name] = true
						_logger:info(string.format("'%s': trigger circle r=%.0fm, 32 vertices", zone.name, r))
					end
				elseif zone.type == 2 then
					local verts = zone.verticies
					if verts and #verts > 0 then
						local poly = {}
						for v = 1, #verts do
							poly[#poly + 1] = { x = verts[v].x, z = verts[v].y }
						end
						polygons[#polygons + 1] = poly
						found[zone.name] = true
						_logger:info(string.format("'%s': trigger polygon, %d vertices", zone.name, #poly))
					end
				end
			end
		end
	end

	-- Source 2: ME drawings (env.mission.drawings.layers[].objects[])
	local drawings = nil
	pcall(function()
		drawings = env and env.mission and env.mission.drawings and env.mission.drawings.layers
	end)
	if drawings then
		for _, layer in pairs(drawings) do
			local objects = layer.objects
			if objects then
				for _, obj in pairs(objects) do
					if obj.name and nameSet[obj.name] and not found[obj.name] then
						local pts = obj.points
						local mapX = obj.mapX or 0
						local mapY = obj.mapY or 0
						if pts and #pts >= 3 then
							local poly = {}
							for p = 1, #pts do
								poly[#poly + 1] = { x = mapX + (pts[p].x or 0), z = mapY + (pts[p].y or 0) }
							end
							polygons[#polygons + 1] = poly
							found[obj.name] = true
							_logger:info(string.format("'%s': drawing polygon, %d vertices", obj.name, #poly))
						end
					end
				end
			end
		end
	end

	for i = 1, #zoneNames do
		if not found[zoneNames[i]] then
			_logger:info(string.format("'%s': NOT FOUND in triggers or drawings", zoneNames[i]))
		end
	end

	return polygons
end

--- Compute the ADIZ polygon as a convex hull expansion of border polygons.
--- The convex hull smooths concave notches so the ADIZ is always at least
--- as smooth as the border and never overlaps inward.
--- @param borderPolygons table[] List of border polygon vertex lists
--- @param bufferNm number Buffer distance in nautical miles
--- @return table|nil adizPolygon Convex hull polygon or nil if insufficient points
function Medusa.Services.AirspaceService.computeADIZ(borderPolygons, bufferNm)
	local allPoints = {}
	for pi = 1, #borderPolygons do
		local poly = borderPolygons[pi]
		for vi = 1, #poly do
			allPoints[#allPoints + 1] = poly[vi]
		end
	end
	if #allPoints < 3 then
		return nil
	end

	local cx, cz = 0, 0
	for i = 1, #allPoints do
		cx = cx + allPoints[i].x
		cz = cz + allPoints[i].z
	end
	cx = cx / #allPoints
	cz = cz / #allPoints

	local bufferM = bufferNm * 1852
	local expanded = {}
	for i = 1, #allPoints do
		local dx = allPoints[i].x - cx
		local dz = allPoints[i].z - cz
		local dist = math.sqrt(dx * dx + dz * dz)
		if dist < 1 then
			expanded[#expanded + 1] = { x = allPoints[i].x + bufferM, z = allPoints[i].z }
		else
			local scale = (dist + bufferM) / dist
			expanded[#expanded + 1] = { x = cx + dx * scale, z = cz + dz * scale }
		end
	end

	local hull = ConvexHull2D(expanded)
	if hull and #hull >= 3 then
		return hull
	end
	return nil
end

--- Pre-convert border polygon vertices from DCS world coords to lat/lon.
--- Called once at init to avoid repeated pcall(coord.LOtoLL) in metrics export.
--- @param borderPolygons table[] List of border polygon vertex lists in DCS {x, z} coords
--- @return table[] latLonPolygons Parallel list of polygons with {lat, lon} vertices
function Medusa.Services.AirspaceService.convertToLatLon(borderPolygons)
	local result = {}
	for pi = 1, #borderPolygons do
		local poly = borderPolygons[pi]
		local llPoly = {}
		for vi = 1, #poly do
			local okLL, lat, lon = pcall(coord.LOtoLL, { x = poly[vi].x, y = 0, z = poly[vi].z })
			if okLL and lat and lon then
				llPoly[#llPoly + 1] = { lat = lat, lon = lon }
			end
		end
		result[#result + 1] = llPoly
	end
	return result
end
