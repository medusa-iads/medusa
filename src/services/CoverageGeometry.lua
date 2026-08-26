require("_header")
require("services.Services")
require("core.Constants")

--[[
██████╗ ██████╗ ██╗   ██╗███████╗██████╗  █████╗  ██████╗ ███████╗
██╔════╝██╔═══██╗██║   ██║██╔════╝██╔══██╗██╔══██╗██╔════╝ ██╔════╝
██║     ██║   ██║██║   ██║█████╗  ██████╔╝███████║██║  ███╗█████╗
██║     ██║   ██║╚██╗ ██╔╝██╔══╝  ██╔══██╗██╔══██║██║   ██║██╔══╝
╚██████╗╚██████╔╝ ╚████╔╝ ███████╗██║  ██║██║  ██║╚██████╔╝███████╗
╚═════╝ ╚═════╝   ╚═══╝  ╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝

██████╗ ███████╗ ██████╗ ███╗   ███╗███████╗████████╗██████╗ ██╗   ██╗
██╔════╝ ██╔════╝██╔═══██╗████╗ ████║██╔════╝╚══██╔══╝██╔══██╗╚██╗ ██╔╝
██║  ███╗█████╗  ██║   ██║██╔████╔██║█████╗     ██║   ██████╔╝ ╚████╔╝
██║   ██║██╔══╝  ██║   ██║██║╚██╔╝██║██╔══╝     ██║   ██╔══██╗  ╚██╔╝
╚██████╔╝███████╗╚██████╔╝██║ ╚═╝ ██║███████╗   ██║   ██║  ██║   ██║
╚═════╝ ╚══════╝ ╚═════╝ ╚═╝     ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝   ╚═╝

    What this module does
    - Calculates how much of a battery's horizontal engagement envelope is covered by radar-provider circles.
    - Classifies coverage as sufficient only when valid providers cover more than half of that envelope.

    How others use it
    - PartitionService supplies intersecting provider circles from the battery's current partition.
    - PartitionService uses the result to mark the battery coordinated or degraded.
]]

Medusa.Services.CoverageGeometry = {}

local TWO_PI = 2 * math.pi
local EPSILON = 0.000000001

--- Protects coverage-area calculations from a non-finite coordinate or radius value.
local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

--- Defines the valid horizontal center and positive radius domain for a coverage circle.
local function validCircle(circle)
	return circle and isFinite(circle.x) and isFinite(circle.z) and isFinite(circle.radius) and circle.radius > 0
end

--- Keeps a trigonometric input or coverage percentage within its valid minimum and maximum.
local function clamp(value, minimum, maximum)
	return math.max(minimum, math.min(maximum, value))
end

--- Adds the angular interval from first through last radians to intervals, split at zero when necessary.
local function addInterval(intervals, first, last)
	while first < 0 do
		first = first + TWO_PI
		last = last + TWO_PI
	end
	while first >= TWO_PI do
		first = first - TWO_PI
		last = last - TWO_PI
	end
	if last <= TWO_PI then
		intervals[#intervals + 1] = { first, last }
	else
		intervals[#intervals + 1] = { first, TWO_PI }
		intervals[#intervals + 1] = { 0, last - TWO_PI }
	end
end

--- Returns the arcs of circle covered by the other circles and whether another circle fully contains it.
local function coveredIntervals(circle, circles, circleIndex)
	local intervals = {}
	for otherIndex = 1, #circles do
		if otherIndex ~= circleIndex then
			local other = circles[otherIndex]
			local dx = other.x - circle.x
			local dz = other.z - circle.z
			local distance = math.sqrt(dx * dx + dz * dz)
			if distance <= math.abs(other.radius - circle.radius) + EPSILON then
				if other.radius > circle.radius or (math.abs(other.radius - circle.radius) <= EPSILON and otherIndex < circleIndex) then
					return nil, true
				end
			elseif distance < other.radius + circle.radius - EPSILON then
				local centerAngle = math.atan2(dz, dx)
				local cosine = clamp((distance * distance + circle.radius * circle.radius - other.radius * other.radius) / (2 * distance * circle.radius), -1, 1)
				local halfAngle = math.acos(cosine)
				addInterval(intervals, centerAngle - halfAngle, centerAngle + halfAngle)
			end
		end
	end
	return intervals, false
end

--- Returns intervals merged into ascending, non-overlapping angular spans.
local function mergedIntervals(intervals)
	table.sort(intervals, function(left, right)
		return left[1] < right[1]
	end)
	local merged = {}
	for i = 1, #intervals do
		local interval = intervals[i]
		local previous = merged[#merged]
		if previous and interval[1] <= previous[2] + EPSILON then
			previous[2] = math.max(previous[2], interval[2])
		else
			merged[#merged + 1] = { interval[1], interval[2] }
		end
	end
	return merged
end

--- Returns the signed area contribution of the circle boundary arc from first through last radians.
local function arcArea(circle, first, last)
	local radius = circle.radius
	return 0.5 * (radius * circle.x * (math.sin(last) - math.sin(first)) + radius * circle.z * (math.cos(first) - math.cos(last)) + radius * radius * (last - first))
end

--- Returns the analytic floating-point union area of circles within the 128-provider ceiling.
local function unionArea(circles)
	local area = 0
	for i = 1, #circles do
		local circle = circles[i]
		local intervals, contained = coveredIntervals(circle, circles, i)
		if not contained then
			local cursor = 0
			local merged = mergedIntervals(intervals)
			for j = 1, #merged do
				local interval = merged[j]
				if interval[1] > cursor + EPSILON then
					area = area + arcArea(circle, cursor, interval[1])
				end
				cursor = math.max(cursor, interval[2])
			end
			if cursor < TWO_PI - EPSILON then
				area = area + arcArea(circle, cursor, TWO_PI)
			end
		end
	end
	return math.max(0, area)
end

--- Returns SUFFICIENT only above 50 percent provider coverage and reports fixed-capacity overflow separately.
function Medusa.Services.CoverageGeometry.evaluate(envelope, providers)
	local insufficient = Medusa.Constants.CoverageClass.INSUFFICIENT
	if not validCircle(envelope) or type(providers) ~= "table" then
		return insufficient, false
	end
	if #providers > Medusa.Constants.C2.PROVIDER_CAPACITY then
		return insufficient, true
	end
	for i = 1, #providers do
		if not validCircle(providers[i]) then
			return insufficient, false
		end
	end
	if #providers == 0 then
		return insufficient, false
	end
	local combined = { envelope }
	for i = 1, #providers do
		combined[#combined + 1] = providers[i]
	end
	local envelopeArea = math.pi * envelope.radius * envelope.radius
	local coveredArea = envelopeArea + unionArea(providers) - unionArea(combined)
	if not isFinite(envelopeArea) or envelopeArea <= 0 or not isFinite(coveredArea) then
		return insufficient, false
	end
	local percent = clamp(coveredArea / envelopeArea * 100, 0, 100)
	return percent > 50 and Medusa.Constants.CoverageClass.SUFFICIENT or insufficient, false
end
