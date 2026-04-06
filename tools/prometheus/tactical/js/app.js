/* app.js -- Init, refresh loop, orchestration for Medusa Tactical Display */
"use strict";

window.MTD = window.MTD || {};

/* ---- Map setup ---- */

MTD.map = L.map("map", {
    center: [35.15, 35.85],
    zoom: 8,
    zoomControl: true
});

L.tileLayer("https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png", {
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OSM</a> &copy; <a href="https://carto.com/">CARTO</a>',
    subdomains: "abcd",
    maxZoom: 19
}).addTo(MTD.map);

/* ---- Layer groups ---- */

MTD.zoneLayer    = L.layerGroup().addTo(MTD.map);
MTD.sensorLayer  = L.layerGroup().addTo(MTD.map);
MTD.batteryLayer = L.layerGroup().addTo(MTD.map);
MTD.trackLayer   = L.layerGroup().addTo(MTD.map);
MTD.trailLayer   = L.layerGroup().addTo(MTD.map);
MTD.killLayer    = L.layerGroup().addTo(MTD.map);
MTD.labelLayer   = L.layerGroup().addTo(MTD.map);

/* ---- Shared state ---- */

MTD.hasCentered        = false;
MTD.prevShotsMap       = {};
MTD.prevTrackPositions = {};
MTD.prevFilter         = "all";
MTD.batteryMarkers     = {};
MTD.trackMarkers       = {};
MTD.ringsByBattery     = {};
MTD.selectedEntity     = null;
MTD.prevBatteryStatus  = {};
MTD.prevMissionTime    = -1;
MTD.prevZoneVertices   = "";
MTD.sensorMarkers      = {};
MTD.sensorRings        = {};

/* ---- Main update loop ---- */

var _refreshing = false;

async function refresh() {
    if (_refreshing) return;
    _refreshing = true;
    try {
        await MTD.refreshNetworks();

        var results = await Promise.all([
            MTD.query(MTD.netExpr("medusa_battery_lat")).catch(function () { return []; }),             // 0
            MTD.query(MTD.netExpr("medusa_battery_lon")).catch(function () { return []; }),             // 1
            MTD.query(MTD.netExpr("medusa_battery_info")).catch(function () { return []; }),            // 2
            MTD.query(MTD.netExpr("medusa_track_lat")).catch(function () { return []; }),               // 3
            MTD.query(MTD.netExpr("medusa_track_lon")).catch(function () { return []; }),               // 4
            MTD.query(MTD.netExpr("medusa_track_info")).catch(function () { return []; }),              // 5
            MTD.query("medusa:live").catch(function () { return []; }),                                 // 6
            MTD.query("medusa_shots_fired_total").catch(function () { return []; }),                 // 7
            MTD.query("medusa_kills_total").catch(function () { return []; }),                       // 8
            MTD.query(MTD.netExpr("medusa_battery_engagement_range_m")).catch(function () { return []; }),  // 9
            MTD.query(MTD.netExpr("medusa_battery_shots_fired")).catch(function () { return []; }),         // 10
            MTD.query(MTD.netExpr("medusa_track_best_pk") + " > 0").catch(function () { return []; }),     // 11
            MTD.query(MTD.netExpr("medusa_track_second_pk") + " > 0").catch(function () { return []; }),   // 12
            MTD.query(MTD.netExpr("medusa_ammo_remaining")).catch(function () { return []; }),              // 13
            MTD.query("medusa_mission_time_seconds").catch(function () { return []; }),                    // 14
            MTD.query(MTD.netExpr("medusa_track_speed")).catch(function () { return []; }),                    // 15
            MTD.query(MTD.netExpr("medusa_track_pos_y")).catch(function () { return []; }),                    // 16
            MTD.query(MTD.netExpr("medusa_battery_weapon_range_m")).catch(function () { return []; }),         // 17
            MTD.query(MTD.netExpr("medusa_battery_ammo")).catch(function () { return []; }),                   // 18
            MTD.query("medusa_border_zone").catch(function () { return []; }),                                // 19
            MTD.query("medusa_posture").catch(function () { return []; }),                                    // 20
            MTD.query(MTD.netExpr("medusa_sensor_lat")).catch(function () { return []; }),                    // 21
            MTD.query(MTD.netExpr("medusa_sensor_lon")).catch(function () { return []; }),                    // 22
            MTD.query(MTD.netExpr("medusa_sensor_info")).catch(function () { return []; }),                   // 23
            MTD.query(MTD.netExpr("medusa_sensor_detection_range_m")).catch(function () { return []; }),    // 24
            MTD.query(MTD.netExpr("medusa_battery_cluster_lat")).catch(function () { return []; }),     // 25
            MTD.query(MTD.netExpr("medusa_battery_cluster_lon")).catch(function () { return []; }),     // 26
            MTD.query(MTD.netExpr("medusa_battery_cluster_range_m")).catch(function () { return []; })  // 27
        ]);

        var batLat          = results[0];
        var batLon          = results[1];
        var batInfo         = results[2];
        var trkLat          = results[3];
        var trkLon          = results[4];
        var trkInfo         = results[5];
        var liveResult      = results[6];
        var shotsResult     = results[7];
        var killsResult     = results[8];
        var batRange        = results[9];
        var batShots        = results[10];
        var bestPkResults   = results[11];
        var secondPkResults = results[12];
        var ammoResults     = results[13];
        var missionTimeResult = results[14];
        var trackSpeedResult  = results[15];
        var trackAltResult    = results[16];
        var batWeaponRange    = results[17];
        var batAmmoResult     = results[18];
        var zoneResult        = results[19];
        var postureResult     = results[20];
        var sensorLatResult   = results[21];
        var sensorLonResult   = results[22];
        var sensorInfoResult  = results[23];
        var sensorRangeResult = results[24];
        var clusterLatResult   = results[25];
        var clusterLonResult   = results[26];
        var clusterRangeResult = results[27];

        /* Liveness check */
        var isLive = false;
        if (liveResult.length > 0) {
            isLive = parseFloat(liveResult[0].value[1]) > 0;
        }
        document.getElementById("offline-banner").style.display = isLive ? "none" : "block";

        /* Mission reset detection: if mission time went backwards, wipe everything */
        var missionTime = missionTimeResult.length > 0 ? parseFloat(missionTimeResult[0].value[1]) : -1;
        if (MTD.prevMissionTime > 0 && missionTime >= 0 && missionTime < MTD.prevMissionTime) {
            MTD.prevShotsMap = {};
            MTD.prevTrackPositions = {};
            MTD.killLayer.clearLayers();
            MTD.batteryLayer.clearLayers();
            MTD.trackLayer.clearLayers();
            MTD.trailLayer.clearLayers();
            MTD.labelLayer.clearLayers();
            MTD.batteryMarkers = {};
            MTD.trackMarkers = {};
            MTD.ringsByBattery = {};
            MTD.zoneLayer.clearLayers();
            MTD.sensorLayer.clearLayers();
            MTD.sensorMarkers = {};
            MTD.sensorRings = {};
            MTD.prevZoneVertices = "";
            MTD.hasCentered = false;
            MTD.hideDetailCard();
            if (MTD._stickyRuler) {
                var sr = MTD._stickyRuler;
                if (sr.line) MTD.map.removeLayer(sr.line);
                if (sr.label) MTD.map.removeLayer(sr.label);
                if (sr.dotA) MTD.map.removeLayer(sr.dotA);
                if (sr.dotB) MTD.map.removeLayer(sr.dotB);
                MTD._stickyRuler = null;
            }
            MTD._stickyPending = null;
            MTD.prevBatteryStatus = {};
            MTD._trackHeadings = {};
            MTD._trailCache = {};
            MTD._trailLastQuery = 0;
            MTD.toast("Mission reset detected — state cleared", 4000);
            console.log("Mission reset detected (time " + MTD.prevMissionTime.toFixed(0) + "s -> " + missionTime.toFixed(0) + "s), cleared all state");
        }
        MTD.prevMissionTime = missionTime;

        /* Build lookup maps */
        var batLatMap   = MTD.buildLabelMap(batLat, "battery");
        var batLonMap   = MTD.buildLabelMap(batLon, "battery");
        var batInfoMap  = MTD.buildInfoMap(batInfo, "battery");
        var trkLatMap   = MTD.buildLabelMap(trkLat, "track");
        var trkLonMap   = MTD.buildLabelMap(trkLon, "track");
        var trkInfoMap  = MTD.buildInfoMap(trkInfo, "track");
        var batRangeMap = MTD.buildLabelMap(batRange, "battery");
        var batShotsMap = MTD.buildLabelMap(batShots, "battery");
        var ammoMap     = MTD.buildLabelMap(ammoResults, "battery");
        var trkSpeedMap = MTD.buildLabelMap(trackSpeedResult, "track");
        var trkAltMap   = MTD.buildLabelMap(trackAltResult, "track");
        var batWeaponRangeMap = MTD.buildLabelMap(batWeaponRange, "battery");
        var batAmmoMap       = MTD.buildLabelMap(batAmmoResult, "battery");
        var sensorLatMap     = MTD.buildLabelMap(sensorLatResult, "sensor");
        var sensorLonMap     = MTD.buildLabelMap(sensorLonResult, "sensor");
        var sensorInfoMap    = MTD.buildInfoMap(sensorInfoResult, "sensor");
        var sensorRangeMap   = MTD.buildLabelMap(sensorRangeResult, "sensor");

        /* Build cluster map: { batteryName: [ {lat, lon}, ... ] } */
        var clusterMap = {};
        for (var cli = 0; cli < clusterLatResult.length; cli++) {
            var clr = clusterLatResult[cli];
            var clBat = clr.metric.battery;
            var clIdx = clr.metric.cluster;
            if (!clusterMap[clBat]) clusterMap[clBat] = {};
            if (!clusterMap[clBat][clIdx]) clusterMap[clBat][clIdx] = {};
            clusterMap[clBat][clIdx].lat = parseFloat(clr.value[1]);
        }
        for (var coi = 0; coi < clusterLonResult.length; coi++) {
            var cor = clusterLonResult[coi];
            var coBat = cor.metric.battery;
            var coIdx = cor.metric.cluster;
            if (!clusterMap[coBat]) clusterMap[coBat] = {};
            if (!clusterMap[coBat][coIdx]) clusterMap[coBat][coIdx] = {};
            clusterMap[coBat][coIdx].lon = parseFloat(cor.value[1]);
        }
        for (var cri = 0; cri < clusterRangeResult.length; cri++) {
            var crr = clusterRangeResult[cri];
            var crBat = crr.metric.battery;
            var crIdx = crr.metric.cluster;
            if (!clusterMap[crBat]) clusterMap[crBat] = {};
            if (!clusterMap[crBat][crIdx]) clusterMap[crBat][crIdx] = {};
            clusterMap[crBat][crIdx].rangeM = parseFloat(crr.value[1]);
        }

        /* Build best/second pk lookup by track for detail panel */
        var bestPkByTrack = {};
        for (var bpi = 0; bpi < bestPkResults.length; bpi++) {
            var bpk = bestPkResults[bpi];
            bestPkByTrack[bpk.metric.track] = {
                pk: parseFloat(bpk.value[1]),
                battery: bpk.metric.battery
            };
        }
        var secondPkByTrack = {};
        for (var spi = 0; spi < secondPkResults.length; spi++) {
            var spkd = secondPkResults[spi];
            secondPkByTrack[spkd.metric.track] = {
                pk: parseFloat(spkd.value[1]),
                battery: spkd.metric.battery
            };
        }

        /* Shared data object for all render functions */
        var data = {
            batLatMap: batLatMap,
            batLonMap: batLonMap,
            batInfoMap: batInfoMap,
            batRangeMap: batRangeMap,
            batShotsMap: batShotsMap,
            ammoMap: ammoMap,
            trkLatMap: trkLatMap,
            trkLonMap: trkLonMap,
            trkInfoMap: trkInfoMap,
            bestPkResults: bestPkResults,
            secondPkResults: secondPkResults,
            bestPkByTrack: bestPkByTrack,
            secondPkByTrack: secondPkByTrack,
            shotsResult: shotsResult,
            killsResult: killsResult,
            missionTime: missionTime,
            trkSpeedMap: trkSpeedMap,
            trkAltMap: trkAltMap,
            batWeaponRangeMap: batWeaponRangeMap,
            batAmmoMap: batAmmoMap,
            zoneResult: zoneResult,
            postureResult: postureResult,
            sensorLatMap: sensorLatMap,
            sensorLonMap: sensorLonMap,
            sensorInfoMap: sensorInfoMap,
            sensorRangeMap: sensorRangeMap,
            clusterMap: clusterMap
        };

        /* Kill markers: detect disappeared tracks */
        var currentTrackPositions = {};
        var currentTrackNames = Object.keys(trkLatMap);
        for (var kti = 0; kti < currentTrackNames.length; kti++) {
            var ktn = currentTrackNames[kti];
            if (trkLonMap[ktn] !== undefined) {
                currentTrackPositions[ktn] = [trkLatMap[ktn], trkLonMap[ktn]];
            }
        }
        MTD.renderKills(MTD.prevTrackPositions, currentTrackPositions);
        MTD.prevTrackPositions = currentTrackPositions;

        /* Clear trail layer (redrawn from cache each cycle) */
        MTD.trailLayer.clearLayers();

        /* Render border zones (behind everything) */
        MTD.renderBorderZones(data);

        /* Render sensors (behind batteries) */
        MTD.renderSensors(data);

        /* Render AWACS trails */
        await MTD.renderSensorTrails(data);

        /* Render batteries */
        var batResult = MTD.renderBatteries(data);

        /* Render engagement lines */
        MTD.renderEngagementLines(data);

        /* Render trails (async -- returns headings) */
        var trackHeadings = await MTD.renderTrails(data);

        /* Render tracks (needs headings from trails) */
        var trkResult = MTD.renderTracks(data, trackHeadings);

        /* Combine bounds */
        var bounds = batResult.bounds.concat(trkResult.bounds);

        /* Stats */
        var posture = "-";
        if (postureResult.length > 0) {
            posture = postureResult[0].metric.posture || "-";
        }

        MTD.updateStats({
            hotCount: batResult.hotCount,
            totalBat: batResult.totalBat,
            trackCount: currentTrackNames.length,
            shotsResult: shotsResult,
            killsResult: killsResult,
            posture: posture
        });

        /* Save shots for pulse detection next cycle */
        MTD.prevShotsMap = batShotsMap;

        /* Zoom to IADS on filter change */
        var currentFilter = MTD.getNetworkFilter();
        if (currentFilter !== MTD.prevFilter) {
            if (bounds.length > 0) {
                MTD.map.fitBounds(bounds, { padding: [40, 40] });
            }
            MTD.prevFilter = currentFilter;
        } else if (!MTD.hasCentered && bounds.length > 0) {
            /* Auto-center on first successful load */
            MTD.map.fitBounds(bounds, { padding: [40, 40] });
            MTD.hasCentered = true;
        }

        /* Update timestamp */
        document.getElementById("last-update").textContent =
            "Updated: " + new Date().toLocaleTimeString();

        /* Store data for sticky ruler position lookups */
        MTD._lastRefreshData = data;

        /* Refresh detail panel if open */
        MTD.refreshDetailPanel(data);

        /* Update sticky ruler positions */
        MTD.updateStickyRuler();

    } catch (err) {
        console.error("Refresh failed:", err);
        document.getElementById("offline-banner").style.display = "block";
        document.getElementById("last-update").textContent =
            "Error: " + err.message;
    } finally {
        _refreshing = false;
    }
}

/* ---- Debounced refresh ---- */

var debounceTimer = null;
function debouncedRefresh() {
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(refresh, 150);
}

/* ---- Wire up event listeners ---- */

MTD.setupKeyboardShortcuts(debouncedRefresh);
MTD.setupSettingsListeners(debouncedRefresh);

/* ---- Initial load + dynamic poll interval ---- */

var pollTimer = null;

function getRefreshMs() {
    var sel = document.getElementById("refresh-rate");
    return sel ? parseInt(sel.value, 10) * 1000 : 5000;
}

function schedulePoll() {
    if (pollTimer) clearTimeout(pollTimer);
    pollTimer = setTimeout(function () {
        refresh().then(schedulePoll).catch(schedulePoll);
    }, getRefreshMs());
}

document.getElementById("refresh-rate").addEventListener("change", function () {
    schedulePoll();
});

refresh().then(schedulePoll).catch(schedulePoll);
