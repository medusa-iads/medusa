/* utils.js -- Pure utility functions for Medusa Tactical Display */
"use strict";

window.MTD = window.MTD || {};

var EARTH_RADIUS_METERS = 6371000;

/* ---- Prometheus API helpers ---- */

MTD.query = async function (expr) {
    var resp = await fetch("/api/v1/query?query=" + encodeURIComponent(expr));
    var data = await resp.json();
    return data.data.result;
};

MTD.queryRange = async function (expr, start, end, step) {
    var url = "/api/v1/query_range?query=" + encodeURIComponent(expr) +
        "&start=" + start + "&end=" + end + "&step=" + step;
    var resp = await fetch(url);
    var data = await resp.json();
    return data.data.result;
};

/* ---- Label/info map builders ---- */

MTD.buildLabelMap = function (results, labelKey) {
    var m = {};
    for (var i = 0; i < results.length; i++) {
        var r = results[i];
        m[r.metric[labelKey]] = parseFloat(r.value[1]);
    }
    return m;
};

MTD.buildInfoMap = function (results, labelKey) {
    var m = {};
    for (var i = 0; i < results.length; i++) {
        var r = results[i];
        m[r.metric[labelKey]] = r.metric;
    }
    return m;
};

MTD.scopedEntityKey = function (network, name) {
    return (network || "") + "\u0000" + (name || "");
};

MTD.buildScopedLabelMap = function (results, labelKey) {
    var m = {};
    for (var i = 0; i < results.length; i++) {
        var r = results[i];
        var key = MTD.scopedEntityKey(r.metric.network, r.metric[labelKey]);
        m[key] = parseFloat(r.value[1]);
    }
    return m;
};

MTD.buildScopedInfoMap = function (results, labelKey) {
    var m = {};
    for (var i = 0; i < results.length; i++) {
        var r = results[i];
        var key = MTD.scopedEntityKey(r.metric.network, r.metric[labelKey]);
        m[key] = r.metric;
    }
    return m;
};

MTD.buildScopedIndexedValues = function (results, labelKey, indexKey) {
    var m = {};
    for (var i = 0; i < results.length; i++) {
        var r = results[i];
        var key = MTD.scopedEntityKey(r.metric.network, r.metric[labelKey]);
        if (!m[key]) m[key] = [];
        m[key].push({
            index: parseInt(r.metric[indexKey], 10),
            value: parseFloat(r.value[1])
        });
    }
    var keys = Object.keys(m);
    for (var ki = 0; ki < keys.length; ki++) {
        m[keys[ki]].sort(function (a, b) { return a.index - b.index; });
    }
    return m;
};

MTD.firstMetricValue = function (results) {
    return results.length > 0 ? parseFloat(results[0].value[1]) : undefined;
};

/* ---- Haversine distance in meters ---- */

MTD.haversineM = function (lat1, lon1, lat2, lon2) {
    var dLat = (lat2 - lat1) * Math.PI / 180;
    var dLon = (lon2 - lon1) * Math.PI / 180;
    var a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
            Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
            Math.sin(dLon / 2) * Math.sin(dLon / 2);
    return EARTH_RADIUS_METERS * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
};

MTD.destinationPoint = function (lat, lon, bearingDegrees, distanceMeters) {
    var angularDistance = distanceMeters / EARTH_RADIUS_METERS;
    var bearing = bearingDegrees * Math.PI / 180;
    var lat1 = lat * Math.PI / 180;
    var lon1 = lon * Math.PI / 180;
    var lat2 = Math.asin(
        Math.sin(lat1) * Math.cos(angularDistance) +
        Math.cos(lat1) * Math.sin(angularDistance) * Math.cos(bearing)
    );
    var lon2 = lon1 + Math.atan2(
        Math.sin(bearing) * Math.sin(angularDistance) * Math.cos(lat1),
        Math.cos(angularDistance) - Math.sin(lat1) * Math.sin(lat2)
    );
    var normalizedLon = ((lon2 * 180 / Math.PI + 540) % 360) - 180;
    return [lat2 * 180 / Math.PI, normalizedLon];
};

MTD.buildSectorPolygon = function (lat, lon, headingDegrees, rangeMeters, halfAngleDegrees, arcSegments) {
    var segments = Math.max(1, Math.floor(arcSegments || 12));
    var points = [[lat, lon]];
    for (var i = 0; i <= segments; i++) {
        var bearing = headingDegrees - halfAngleDegrees + (2 * halfAngleDegrees * i / segments);
        points.push(MTD.destinationPoint(lat, lon, bearing, rangeMeters));
    }
    points.push([lat, lon]);
    return points;
};

var MANPAD_DETECTION_BY_MODE = {
    NONE: { narrow: false, wide: false },
    NARROW: { narrow: true, wide: false },
    FULL: { narrow: true, wide: true }
};

MTD.manpadDetectionProfile = function (mode) {
    return MANPAD_DETECTION_BY_MODE[mode] || MANPAD_DETECTION_BY_MODE.NONE;
};

/* ---- Altitude color scale ---- */

MTD.altitudeColor = function (altMeters) {
    var alt = Math.max(0, Math.min(15000, altMeters));
    var hue;
    if (alt <= 10000) {
        hue = 120 - (alt / 10000) * 120;         /* green(120) -> red(0) */
    } else {
        hue = 360 - ((alt - 10000) / 5000) * 60; /* red(360) -> magenta(300) */
    }
    return "hsl(" + Math.round(hue) + ", 100%, 50%)";
};

/* ---- Settings helpers ---- */

MTD.opt = function (id) {
    var el = document.getElementById(id);
    return el ? el.checked : true;
};

MTD.getNetworkFilter = function () {
    var sel = document.getElementById("iads-filter");
    return sel ? sel.value : "all";
};

MTD.toast = function (msg, durationMs) {
    var el = document.getElementById("toast");
    if (!el) return;
    el.textContent = msg;
    el.style.display = "block";
    el.style.opacity = "1";
    setTimeout(function () {
        el.style.opacity = "0";
        setTimeout(function () { el.style.display = "none"; }, 500);
    }, durationMs || 3000);
};

MTD.netExpr = function (metric, extra) {
    var net = MTD.getNetworkFilter();
    var filter = net === "all" ? "" : 'network="' + net + '",';
    return metric + "{" + filter + (extra || "") + "}";
};

MTD.shortName = function (fullName) {
    return (fullName || "").split(".").pop();
};
