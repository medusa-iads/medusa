-- Medusa Prometheus Metrics Exporter
--
-- Periodically exports Medusa IADS metrics in Prometheus text exposition format.
-- A node_exporter textfile collector or similar can scrape the output file.
--
-- Install: copy this file to Saved Games/DCS/Scripts/Hooks/

local medusaMetrics = {}
local INTERVAL_SEC = 10
local lastExport = 0
local LOG_TAG = "MEDUSA_METRICS"

local function logInfo(msg)
    log.write(LOG_TAG, log.INFO, msg)
end

function medusaMetrics.onSimulationStart()
    lastExport = 0
    logInfo("onSimulationStart: reset export timer")
end

function medusaMetrics.onSimulationStop()
    lastExport = 0
    logInfo("onSimulationStop: reset export timer")
end

function medusaMetrics.onSimulationFrame()
    local now = DCS.getModelTime()
    if now - lastExport < INTERVAL_SEC then
        return
    end
    lastExport = now

    local ok, result = pcall(net.dostring_in, "mission",
        [[return a_do_script("return _G.MedusaMetricsData or ''")]])

    if not ok then
        logInfo("dostring_in failed: " .. tostring(result))
        return
    end
    if not result or result == "" then
        logInfo("dostring_in returned empty (fn exists=" ..
            tostring(result ~= nil) .. ", len=" .. tostring(result and #result or "nil") .. ")")
        return
    end

    logInfo("serialize returned " .. tostring(#result) .. " bytes")

    local path = lfs.writedir() .. "Logs/medusa_metrics.prom"
    local f = io.open(path, "w")
    if f then
        f:write(result)
        f:write("\n")
        f:close()
        logInfo("wrote " .. path)
    else
        logInfo("io.open failed for " .. path)
    end
end

DCS.setUserCallbacks(medusaMetrics)
