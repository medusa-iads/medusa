require("_header")
require("services.Services")

--[[
            ███╗   ███╗███████╗████████╗██████╗ ██╗ ██████╗███████╗    ███████╗███████╗██████╗ ██╗   ██╗██╗ ██████╗███████╗
            ████╗ ████║██╔════╝╚══██╔══╝██╔══██╗██║██╔════╝██╔════╝    ██╔════╝██╔════╝██╔══██╗██║   ██║██║██╔════╝██╔════╝
            ██╔████╔██║█████╗     ██║   ██████╔╝██║██║     ███████╗    ███████╗█████╗  ██████╔╝██║   ██║██║██║     █████╗
            ██║╚██╔╝██║██╔══╝     ██║   ██╔══██╗██║██║     ╚════██║    ╚════██║██╔══╝  ██╔══██╗╚██╗ ██╔╝██║██║     ██╔══╝
            ██║ ╚═╝ ██║███████╗   ██║   ██║  ██║██║╚██████╗███████║    ███████║███████╗██║  ██║ ╚████╔╝ ██║╚██████╗███████╗
            ╚═╝     ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝ ╚═════╝╚══════╝    ╚══════╝╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚═╝ ╚═════╝╚══════╝

    What this service does
    - Provides a Prometheus-compatible metrics registry with counters, gauges, summaries, histograms, and info types.
    - Supports labeled and unlabeled series, snapshot callbacks, and serialization to Prometheus text format.

    How others use it
    - Every service calls inc, set, or observe to record operational metrics.
    - The Entrypoint calls serialize on a timer to write metrics to disk for Grafana scraping.
--]]

Medusa.Services.MetricsService = {}
Medusa.Services.MetricsService._registry = {}
Medusa.Services.MetricsService._snapshotCallbacks = {}
Medusa.Services.MetricsService._context = nil
Medusa.Services.MetricsService._extendedBlock = ""

function Medusa.Services.MetricsService.setExtended(text)
	Medusa.Services.MetricsService._extendedBlock = text or ""
end

function Medusa.Services.MetricsService.setContext(labels)
	Medusa.Services.MetricsService._context = labels
end

local function makeLabelKey(labelKeys, labels)
	local parts = {}
	for i = 1, #labelKeys do
		local k = labelKeys[i]
		parts[i] = string.format('%s="%s"', k, tostring(labels[k] or ""))
	end
	return table.concat(parts, ",")
end

function Medusa.Services.MetricsService.onSnapshot(fn)
	local cbs = Medusa.Services.MetricsService._snapshotCallbacks
	cbs[#cbs + 1] = fn
end

function Medusa.Services.MetricsService.counter(name, help, labelKeys)
	if labelKeys then
		Medusa.Services.MetricsService._registry[name] =
			{ type = "counter", help = help or "", label_keys = labelKeys, series = {} }
	else
		Medusa.Services.MetricsService._registry[name] = { type = "counter", help = help or "", value = 0 }
	end
end

function Medusa.Services.MetricsService.gauge(name, help, labelKeys)
	if labelKeys then
		Medusa.Services.MetricsService._registry[name] =
			{ type = "gauge", help = help or "", label_keys = labelKeys, series = {} }
	else
		Medusa.Services.MetricsService._registry[name] = { type = "gauge", help = help or "", value = 0 }
	end
end

function Medusa.Services.MetricsService.info(name, help, labelKey)
	Medusa.Services.MetricsService._registry[name] = {
		type = "info",
		help = help or "",
		label_key = labelKey,
		value = "",
	}
end

function Medusa.Services.MetricsService.setInfo(name, value)
	local entry = Medusa.Services.MetricsService._registry[name]
	if not entry then
		return
	end
	entry.value = value or ""
end

function Medusa.Services.MetricsService.summary(name, help, quantiles, windowSize, labelKeys)
	local q = quantiles or { 0.5, 0.9, 0.99 }
	local ws = windowSize or 1000
	if labelKeys then
		Medusa.Services.MetricsService._registry[name] = {
			type = "summary",
			help = help or "",
			quantiles = q,
			window_size = ws,
			label_keys = labelKeys,
			series = {},
		}
	else
		Medusa.Services.MetricsService._registry[name] = {
			type = "summary",
			help = help or "",
			quantiles = q,
			window_size = ws,
			observations = {},
			obs_idx = 0,
			sum = 0,
			count = 0,
		}
	end
end

function Medusa.Services.MetricsService.histogram(name, help, buckets, labelKeys)
	local sorted = {}
	for i = 1, #buckets do
		sorted[i] = buckets[i]
	end
	table.sort(sorted)
	if labelKeys then
		Medusa.Services.MetricsService._registry[name] = {
			type = "histogram",
			help = help or "",
			label_keys = labelKeys,
			buckets = sorted,
			series = {},
		}
	else
		local counts = {}
		for i = 1, #sorted do
			counts[i] = 0
		end
		Medusa.Services.MetricsService._registry[name] = {
			type = "histogram",
			help = help or "",
			buckets = sorted,
			counts = counts,
			inf_count = 0,
			sum = 0,
		}
	end
end

function Medusa.Services.MetricsService.inc(name, delta, labels)
	local entry = Medusa.Services.MetricsService._registry[name]
	if not entry then
		return
	end
	if entry.label_keys then
		local effectiveLabels = labels or Medusa.Services.MetricsService._context
		if not effectiveLabels then
			return
		end
		local key = makeLabelKey(entry.label_keys, effectiveLabels)
		local s = entry.series[key]
		if not s then
			s = { value = 0 }
			entry.series[key] = s
		end
		s.value = s.value + (delta or 1)
	else
		entry.value = entry.value + (delta or 1)
	end
end

function Medusa.Services.MetricsService.set(name, value, labels)
	local entry = Medusa.Services.MetricsService._registry[name]
	if not entry then
		return
	end
	if entry.label_keys then
		local effectiveLabels = labels or Medusa.Services.MetricsService._context
		if not effectiveLabels then
			return
		end
		local key = makeLabelKey(entry.label_keys, effectiveLabels)
		local s = entry.series[key]
		if not s then
			s = { value = 0 }
			entry.series[key] = s
		end
		s.value = value
	else
		entry.value = value
	end
end

local function observeSummary(s, value, windowSize)
	local idx = (s.obs_idx % windowSize) + 1
	s.observations[idx] = value
	s.obs_idx = s.obs_idx + 1
	s.sum = s.sum + value
	s.count = s.count + 1
end

function Medusa.Services.MetricsService.observe(name, value, labels)
	local entry = Medusa.Services.MetricsService._registry[name]
	if not entry then
		return
	end
	if entry.label_keys then
		local effectiveLabels = labels or Medusa.Services.MetricsService._context
		if not effectiveLabels then
			return
		end
		local key = makeLabelKey(entry.label_keys, effectiveLabels)
		local s = entry.series[key]
		if entry.type == "summary" then
			if not s then
				s = { observations = {}, obs_idx = 0, sum = 0, count = 0 }
				entry.series[key] = s
			end
			observeSummary(s, value, entry.window_size)
		else
			if not s then
				local counts = {}
				for i = 1, #entry.buckets do
					counts[i] = 0
				end
				s = { counts = counts, inf_count = 0, sum = 0 }
				entry.series[key] = s
			end
			for i = 1, #entry.buckets do
				if value <= entry.buckets[i] then
					s.counts[i] = s.counts[i] + 1
				end
			end
			s.inf_count = s.inf_count + 1
			s.sum = s.sum + value
		end
	else
		if entry.type == "summary" then
			observeSummary(entry, value, entry.window_size)
		else
			local buckets = entry.buckets
			local counts = entry.counts
			for i = 1, #buckets do
				if value <= buckets[i] then
					counts[i] = counts[i] + 1
				end
			end
			entry.inf_count = entry.inf_count + 1
			entry.sum = entry.sum + value
		end
	end
end

local function serializeHistogram(name, entry)
	local lines = {}
	local n = 0
	n = n + 1
	lines[n] = string.format("# HELP %s %s", name, entry.help)
	n = n + 1
	lines[n] = string.format("# TYPE %s histogram", name)
	for i = 1, #entry.buckets do
		n = n + 1
		lines[n] = string.format('%s_bucket{le="%g"} %d', name, entry.buckets[i], entry.counts[i])
	end
	n = n + 1
	lines[n] = string.format('%s_bucket{le="+Inf"} %d', name, entry.inf_count)
	n = n + 1
	lines[n] = string.format("%s_sum %s", name, tostring(entry.sum))
	n = n + 1
	lines[n] = string.format("%s_count %d", name, entry.inf_count)
	return table.concat(lines, "\n")
end

local function serializeLabeledMetric(name, entry)
	local lines = {}
	local n = 0
	n = n + 1
	lines[n] = string.format("# HELP %s %s", name, entry.help)
	n = n + 1
	lines[n] = string.format("# TYPE %s %s", name, entry.type)
	for key, s in pairs(entry.series) do
		n = n + 1
		lines[n] = string.format("%s{%s} %s", name, key, tostring(s.value))
	end
	return table.concat(lines, "\n")
end

local function serializeLabeledHistogram(name, entry)
	local lines = {}
	local n = 0
	n = n + 1
	lines[n] = string.format("# HELP %s %s", name, entry.help)
	n = n + 1
	lines[n] = string.format("# TYPE %s histogram", name)
	for key, s in pairs(entry.series) do
		for i = 1, #entry.buckets do
			n = n + 1
			lines[n] = string.format('%s_bucket{%s,le="%g"} %d', name, key, entry.buckets[i], s.counts[i])
		end
		n = n + 1
		lines[n] = string.format('%s_bucket{%s,le="+Inf"} %d', name, key, s.inf_count)
		n = n + 1
		lines[n] = string.format("%s_sum{%s} %s", name, key, tostring(s.sum))
		n = n + 1
		lines[n] = string.format("%s_count{%s} %d", name, key, s.inf_count)
	end
	return table.concat(lines, "\n")
end

local function computeQuantiles(observations, obsIdx, windowSize, quantiles)
	local n = math.min(obsIdx, windowSize)
	if n == 0 then
		return nil
	end
	local sorted = {}
	for i = 1, n do
		sorted[i] = observations[i]
	end
	table.sort(sorted)
	local result = {}
	for i = 1, #quantiles do
		-- ceil biases toward next-higher sample, giving conservative (pessimistic) percentile estimates
		local idx = math.max(1, math.ceil(quantiles[i] * n))
		result[i] = sorted[idx]
	end
	return result
end

local function serializeSummary(name, entry)
	local lines = {}
	local n = 0
	n = n + 1
	lines[n] = string.format("# HELP %s %s", name, entry.help)
	n = n + 1
	lines[n] = string.format("# TYPE %s summary", name)
	local qVals = computeQuantiles(entry.observations, entry.obs_idx, entry.window_size, entry.quantiles)
	if qVals then
		for i = 1, #entry.quantiles do
			n = n + 1
			lines[n] = string.format('%s{quantile="%s"} %s', name, tostring(entry.quantiles[i]), tostring(qVals[i]))
		end
	end
	n = n + 1
	lines[n] = string.format("%s_sum %s", name, tostring(entry.sum))
	n = n + 1
	lines[n] = string.format("%s_count %d", name, entry.count)
	return table.concat(lines, "\n")
end

local function serializeLabeledSummary(name, entry)
	local lines = {}
	local n = 0
	n = n + 1
	lines[n] = string.format("# HELP %s %s", name, entry.help)
	n = n + 1
	lines[n] = string.format("# TYPE %s summary", name)
	for key, s in pairs(entry.series) do
		local qVals = computeQuantiles(s.observations, s.obs_idx, entry.window_size, entry.quantiles)
		if qVals then
			for i = 1, #entry.quantiles do
				n = n + 1
				lines[n] = string.format(
					'%s{%s,quantile="%s"} %s',
					name,
					key,
					tostring(entry.quantiles[i]),
					tostring(qVals[i])
				)
			end
		end
		n = n + 1
		lines[n] = string.format("%s_sum{%s} %s", name, key, tostring(s.sum))
		n = n + 1
		lines[n] = string.format("%s_count{%s} %d", name, key, s.count)
	end
	return table.concat(lines, "\n")
end

function Medusa.Services.MetricsService.serialize()
	local cbs = Medusa.Services.MetricsService._snapshotCallbacks
	for i = 1, #cbs do
		cbs[i]()
	end

	local hpt = Medusa.hpTimer
	local t0 = hpt()
	local parts = {}
	local n = 0
	for name, entry in pairs(Medusa.Services.MetricsService._registry) do
		n = n + 1
		if entry.label_keys then
			if entry.type == "histogram" then
				parts[n] = serializeLabeledHistogram(name, entry)
			elseif entry.type == "summary" then
				parts[n] = serializeLabeledSummary(name, entry)
			else
				parts[n] = serializeLabeledMetric(name, entry)
			end
		else
			if entry.type == "histogram" then
				parts[n] = serializeHistogram(name, entry)
			elseif entry.type == "summary" then
				parts[n] = serializeSummary(name, entry)
			elseif entry.type == "info" then
				if entry.value == "" then
					parts[n] = string.format("# HELP %s %s\n# TYPE %s gauge", name, entry.help, name)
				else
					parts[n] = string.format(
						'# HELP %s %s\n# TYPE %s gauge\n%s{%s="%s"} 1',
						name,
						entry.help,
						name,
						name,
						entry.label_key,
						entry.value
					)
				end
			else
				parts[n] = string.format(
					"# HELP %s %s\n# TYPE %s %s\n%s %s",
					name,
					entry.help,
					name,
					entry.type,
					name,
					tostring(entry.value)
				)
			end
		end
	end
	-- Heartbeat: epoch seconds so Grafana can detect stale data
	n = n + 1
	parts[n] = string.format(
		"# HELP medusa_heartbeat_epoch Unix epoch of last export\n# TYPE medusa_heartbeat_epoch gauge\nmedusa_heartbeat_epoch %d",
		os.time()
	)

	local result = table.concat(parts, "\n")

	local ext = Medusa.Services.MetricsService._extendedBlock
	if ext and #ext > 0 then
		result = result .. "\n" .. ext
	end

	-- Self-time: observe duration (appears in next scrape)
	Medusa.Services.MetricsService.observe("medusa_serialize_duration_seconds", hpt() - t0)
	return result
end

function Medusa.Services.MetricsService.reset()
	for _, entry in pairs(Medusa.Services.MetricsService._registry) do
		if entry.label_keys then
			for _, s in pairs(entry.series) do
				if entry.type == "histogram" then
					for i = 1, #s.counts do
						s.counts[i] = 0
					end
					s.inf_count = 0
					s.sum = 0
				elseif entry.type == "summary" then
					s.observations = {}
					s.obs_idx = 0
					s.sum = 0
					s.count = 0
				else
					s.value = 0
				end
			end
		else
			if entry.type == "histogram" then
				for i = 1, #entry.counts do
					entry.counts[i] = 0
				end
				entry.inf_count = 0
				entry.sum = 0
			elseif entry.type == "summary" then
				entry.observations = {}
				entry.obs_idx = 0
				entry.sum = 0
				entry.count = 0
			elseif entry.type == "info" then
				entry.value = ""
			else
				entry.value = 0
			end
		end
	end
	Medusa.Services.MetricsService._snapshotCallbacks = {}
	Medusa.Services.MetricsService._context = nil
	Medusa.Services.MetricsService._extendedBlock = ""
end
