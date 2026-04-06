/* utils.js -- Pure utility functions for Medusa Tactical Display */
"use strict";

window.MTD = window.MTD || {};

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

/* ---- Haversine distance in meters ---- */

MTD.haversineM = function (lat1, lon1, lat2, lon2) {
    var R = 6371000;
    var dLat = (lat2 - lat1) * Math.PI / 180;
    var dLon = (lon2 - lon1) * Math.PI / 180;
    var a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
            Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
            Math.sin(dLon / 2) * Math.sin(dLon / 2);
    return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
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
