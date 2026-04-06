/* ui.js -- UI panels, keyboard, settings for Medusa Tactical Display */
"use strict";

window.MTD = window.MTD || {};

/* ---- Internal state for known networks ---- */
var _knownNetworks = [];

/* ---- Network dropdown refresh ---- */

MTD.refreshNetworks = async function () {
    try {
        var resp = await fetch("/api/v1/label/network/values");
        var data = await resp.json();
        var networks = (data.data || []).filter(function (n) { return n && n !== ""; });
        if (JSON.stringify(networks) !== JSON.stringify(_knownNetworks)) {
            _knownNetworks = networks;
            var sel = document.getElementById("iads-filter");
            var cur = sel.value;
            sel.innerHTML = '<option value="all">All Networks</option>';
            for (var i = 0; i < networks.length; i++) {
                var o = document.createElement("option");
                o.value = networks[i];
                o.textContent = networks[i];
                sel.appendChild(o);
            }
            sel.value = cur;
        }
    } catch (e) {
        /* network list fetch is non-critical */
    }
};

/* ---- Detail panel helpers ---- */

function detailRow(label, value) {
    return '<div class="detail-row"><span class="detail-label">' + label + '</span><span class="detail-value">' + (value !== undefined && value !== null && value !== "" ? value : "-") + '</span></div>';
}

function buildBatteryDetail(bName, data) {
    var batInfoMap  = data.batInfoMap || {};
    var batRangeMap = data.batRangeMap || {};
    var batShotsMap = data.batShotsMap || {};
    var batAmmoMap  = data.batAmmoMap || {};
    var info = batInfoMap[bName] || {};
    var shortName = MTD.shortName(bName);
    var html = '<h3>' + shortName + '</h3>';
    html += detailRow("Full Name", bName);
    html += detailRow("System", info.system || "-");
    html += detailRow("Role", info.role || "-");
    html += detailRow("State", info.state || "-");
    html += detailRow("Ammo", batAmmoMap[bName] !== undefined ? batAmmoMap[bName] : "-");
    html += detailRow("Shots Fired", batShotsMap[bName] !== undefined ? batShotsMap[bName] : "-");
    html += detailRow("Target", info.target || "-");
    var batWeaponRangeMap = data.batWeaponRangeMap || {};
    html += detailRow("Engagement Range", batRangeMap[bName] ? (batRangeMap[bName] / 1000).toFixed(1) + " km (" + (batRangeMap[bName] / 1852).toFixed(1) + " nm)" : "-");
    html += detailRow("Weapon Range", batWeaponRangeMap[bName] ? (batWeaponRangeMap[bName] / 1000).toFixed(1) + " km (" + (batWeaponRangeMap[bName] / 1852).toFixed(1) + " nm)" : "-");
    return html;
}

function buildTrackDetail(tName, data) {
    var trkInfoMap      = data.trkInfoMap || {};
    var bestPkByTrack   = data.bestPkByTrack || {};
    var secondPkByTrack = data.secondPkByTrack || {};
    var info = trkInfoMap[tName] || {};
    var bestPk = bestPkByTrack[tName];
    var secondPk = secondPkByTrack[tName];
    var html = '<h3>Track ' + tName + '</h3>';
    html += detailRow("Unit", info.unit || "-");
    html += detailRow("Airframe", info.aircraft_type || info.type || "-");
    html += detailRow("Identification", info.identification || "-");
    html += detailRow("Maneuver", info.maneuver || "-");
    html += detailRow("Best Pk", bestPk ? bestPk.pk.toFixed(3) + " (" + MTD.shortName(bestPk.battery) + ")" : "-");
    html += detailRow("2nd Pk", secondPk ? secondPk.pk.toFixed(3) + " (" + MTD.shortName(secondPk.battery) + ")" : "-");
    var trkSpeedMap = data.trkSpeedMap || {};
    var trkAltMap = data.trkAltMap || {};
    var speed = trkSpeedMap[tName];
    var alt = trkAltMap[tName];
    html += detailRow("Speed", speed !== undefined ? speed.toFixed(0) + " m/s (" + (speed * 1.944).toFixed(0) + " kts)" : "-");
    html += detailRow("Altitude", alt !== undefined ? alt.toFixed(0) + " m (" + (alt * 3.281).toFixed(0) + " ft)" : "-");
    return html;
}

var MAX_CARDS = 8;
MTD._openCards = []; /* array of { type, name, el } */

function cardKey(type, name) { return type + ":" + name; }

function buildCardHtml(type, name, data) {
    if (type === "battery") return buildBatteryDetail(name, data);
    if (type === "track") return buildTrackDetail(name, data);
    return "";
}

MTD.showDetailCard = function (type, name, data) {
    var key = cardKey(type, name);
    /* Don't open duplicates */
    for (var i = 0; i < MTD._openCards.length; i++) {
        if (cardKey(MTD._openCards[i].type, MTD._openCards[i].name) === key) return;
    }
    /* Evict oldest if at capacity */
    if (MTD._openCards.length >= MAX_CARDS) {
        var oldest = MTD._openCards.shift();
        if (oldest.el && oldest.el.parentNode) oldest.el.parentNode.removeChild(oldest.el);
    }
    var html = buildCardHtml(type, name, data);
    if (!html) return;
    var card = document.createElement("div");
    card.className = "detail-card panel";
    card.style.position = "relative";
    card.innerHTML = '<span class="close-btn">&times;</span>' + html;
    var deck = document.getElementById("card-deck");
    deck.appendChild(card);
    var entry = { type: type, name: name, el: card };
    MTD._openCards.push(entry);
    /* Use delegated click on card — survives innerHTML rewrites */
    (function (e) {
        card.addEventListener("click", function (ev) {
            if (ev.target.classList.contains("close-btn")) MTD.removeCard(e);
        });
    })(entry);
    MTD._lastDetailData = data;
};

/* Open both battery + track from a Pk line click */
MTD.showPkPairCards = function (batteryName, trackName, data) {
    MTD.showDetailCard("battery", batteryName, data);
    MTD.showDetailCard("track", trackName, data);
};

MTD.removeCard = function (entry) {
    if (entry.el && entry.el.parentNode) entry.el.parentNode.removeChild(entry.el);
    MTD._openCards = MTD._openCards.filter(function (c) { return c !== entry; });
};

MTD.hideDetailCard = function () {
    var deck = document.getElementById("card-deck");
    deck.innerHTML = "";
    MTD._openCards = [];
    MTD.selectedEntity = null;
};

MTD.refreshDetailPanel = function (data) {
    if (MTD._openCards.length === 0) return;
    MTD._lastDetailData = data;
    for (var i = 0; i < MTD._openCards.length; i++) {
        var c = MTD._openCards[i];
        var html = buildCardHtml(c.type, c.name, data);
        if (html && c.el) {
            c.el.innerHTML = '<span class="close-btn">&times;</span>' + html;
        }
    }
};

/* ---- Keyboard shortcuts ---- */

function toggle(id) {
    var el = document.getElementById(id);
    if (el) el.checked = !el.checked;
}

MTD.setupKeyboardShortcuts = function (debouncedRefresh) {
    document.addEventListener("keydown", function (e) {
        /* Don't trigger when focused on the select dropdown or other inputs */
        var tag = document.activeElement ? document.activeElement.tagName : "";
        if (tag === "SELECT" || tag === "INPUT" || tag === "TEXTAREA") return;

        var key = e.key.toUpperCase();
        var toggled = false;
        if (key === "R") { toggle("opt-threat-rings"); toggled = true; }
        else if (key === "P") { toggle("opt-best-pk"); toggled = true; }
        else if (key === "D") { toggle("opt-second-pk"); toggled = true; }
        else if (key === "L") { toggle("opt-pk-labels"); toggled = true; }
        else if (key === "T") { toggle("opt-track-labels"); toggled = true; }
        else if (key === "B") { toggle("opt-bat-labels"); toggled = true; }
        else if (key === "Z") { toggle("opt-border-zones"); toggled = true; }
        else if (key === "S") { toggle("opt-sensors"); toggled = true; }
        else if (key === "F") {
            /* Fit map to all visible entity bounds */
            var allBounds = [];
            var bNames = Object.keys(MTD.batteryMarkers);
            for (var i = 0; i < bNames.length; i++) {
                allBounds.push(MTD.batteryMarkers[bNames[i]].dot.getLatLng());
            }
            var tNames = Object.keys(MTD.trackMarkers);
            for (var j = 0; j < tNames.length; j++) {
                allBounds.push(MTD.trackMarkers[tNames[j]].icon.getLatLng());
            }
            if (allBounds.length > 0) {
                MTD.map.fitBounds(allBounds, { padding: [40, 40] });
            }
            return;
        }

        if (toggled) {
            debouncedRefresh();
        }
    });
};

/* ---- Settings listeners ---- */

MTD.setupSettingsListeners = function (debouncedRefresh) {
    document.getElementById("iads-filter").addEventListener("change", function () {
        MTD.prevFilter = "__force_zoom__"; /* force zoom on next refresh */
        debouncedRefresh();
    });
    ["opt-threat-rings", "opt-best-pk", "opt-second-pk", "opt-pk-labels", "opt-track-labels", "opt-bat-labels", "opt-border-zones", "opt-sensors"].forEach(function(id) {
        document.getElementById(id).addEventListener("change", debouncedRefresh);
    });
};

/* ---- Stats panel update ---- */

MTD.updateStats = function (data) {
    document.getElementById("stat-hot").textContent = data.hotCount;
    document.getElementById("stat-total-bat").textContent = data.totalBat;
    document.getElementById("stat-tracks").textContent = data.trackCount;

    var totalShots = 0;
    var shotsResult = data.shotsResult || [];
    for (var sh = 0; sh < shotsResult.length; sh++) {
        totalShots += parseFloat(shotsResult[sh].value[1]);
    }
    var totalKills = 0;
    var killsResult = data.killsResult || [];
    for (var ki = 0; ki < killsResult.length; ki++) {
        totalKills += parseFloat(killsResult[ki].value[1]);
    }
    document.getElementById("stat-shots").textContent = totalShots;
    document.getElementById("stat-kills").textContent = totalKills;

    var postureEl = document.getElementById("stat-posture");
    if (postureEl) {
        var posture = data.posture || "-";
        postureEl.textContent = posture;
        var postureColors = { HOT_WAR: "#e05555", WARM_WAR: "#c8a030", COLD_WAR: "#5588aa" };
        postureEl.style.color = postureColors[posture] || "#fff";
    }
};

/* ---- Wire up close button ---- */

/* Close buttons are wired per-card in showDetailCard() */

/* ---- Escape closes detail card + clears ruler ---- */

document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") {
        MTD.hideDetailCard();
        clearRuler();
    }
});

/* ---- Middle-click ruler ---- */

var _rulerLine = null;
var _rulerLabel = null;
var _rulerStart = null;
var _rulerActive = false;
var _rulerDotStart = null;
var _rulerDotEnd = null;
var _RULER_COLOR = "#ffd740";

function clearRuler() {
    if (_rulerLine) { MTD.map.removeLayer(_rulerLine); _rulerLine = null; }
    if (_rulerLabel) { MTD.map.removeLayer(_rulerLabel); _rulerLabel = null; }
    if (_rulerDotStart) { MTD.map.removeLayer(_rulerDotStart); _rulerDotStart = null; }
    if (_rulerDotEnd) { MTD.map.removeLayer(_rulerDotEnd); _rulerDotEnd = null; }
    _rulerStart = null;
    _rulerActive = false;
}

function updateRulerLabel(start, end) {
    var distM = MTD.haversineM(start.lat, start.lng, end.lat, end.lng);
    var distNm = (distM / 1852).toFixed(1);
    var distKm = (distM / 1000).toFixed(1);
    var midLat = (start.lat + end.lat) / 2;
    var midLng = (start.lng + end.lng) / 2;
    var text = distNm + " nm / " + distKm + " km";
    if (_rulerLabel) {
        _rulerLabel.setLatLng([midLat, midLng]);
        _rulerLabel.setIcon(L.divIcon({
            className: "",
            html: '<div style="background:rgba(20,20,30,0.85);color:' + _RULER_COLOR + ';font-size:12px;font-weight:600;padding:2px 8px;border-radius:4px;white-space:nowrap;text-shadow:0 0 3px #000;">' + text + '</div>',
            iconSize: [0, 0],
            iconAnchor: [0, 0]
        }));
    } else {
        _rulerLabel = L.marker([midLat, midLng], {
            icon: L.divIcon({
                className: "",
                html: '<div style="background:rgba(20,20,30,0.85);color:' + _RULER_COLOR + ';font-size:12px;font-weight:600;padding:2px 8px;border-radius:4px;white-space:nowrap;text-shadow:0 0 3px #000;">' + text + '</div>',
                iconSize: [0, 0],
                iconAnchor: [0, 0]
            }),
            interactive: false
        }).addTo(MTD.map);
    }
    if (_rulerDotEnd) {
        _rulerDotEnd.setLatLng([end.lat, end.lng]);
    } else {
        _rulerDotEnd = L.circleMarker([end.lat, end.lng], {
            radius: 4, color: _RULER_COLOR, fillColor: _RULER_COLOR, fillOpacity: 1, weight: 1
        }).addTo(MTD.map);
    }
}

/* Intercept ALL middle-click events at document level before anything else */
document.addEventListener("mousedown", function (e) {
    if (e.button !== 1) return;
    /* Check if click is on the map */
    var mapEl = MTD.map.getContainer();
    if (!mapEl.contains(e.target)) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    MTD.map.dragging.disable();
    clearRuler();
    _rulerStart = MTD.map.mouseEventToLatLng(e);
    _rulerActive = true;
    _rulerLine = L.polyline([_rulerStart, _rulerStart], {
        color: _RULER_COLOR,
        weight: 2,
        opacity: 0.9,
        dashArray: "6 4"
    }).addTo(MTD.map);
    _rulerDotStart = L.circleMarker([_rulerStart.lat, _rulerStart.lng], {
        radius: 4, color: _RULER_COLOR, fillColor: _RULER_COLOR, fillOpacity: 1, weight: 1
    }).addTo(MTD.map);
}, true);

document.addEventListener("mousemove", function (e) {
    if (!_rulerActive || !_rulerStart) return;
    var current = MTD.map.mouseEventToLatLng(e);
    _rulerLine.setLatLngs([_rulerStart, current]);
    updateRulerLabel(_rulerStart, current);
}, true);

document.addEventListener("mouseup", function (e) {
    if (e.button !== 1 || !_rulerActive) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    _rulerActive = false;
    MTD.map.dragging.enable();
}, true);

/* Suppress Chrome autoscroll icon on middle-click */
document.addEventListener("auxclick", function (e) {
    if (e.button === 1 && MTD.map.getContainer().contains(e.target)) {
        e.preventDefault();
    }
}, true);

/* ---- Sticky entity-locked ruler (right-click) ---- */

var _STICKY_COLOR = "#ffd740";
MTD._stickyRuler = null;  /* { startType, startName, endType, endName, line, label, dotA, dotB } */
MTD._stickyPending = null; /* { type, name } — waiting for second right-click */

function clearStickyRuler() {
    var sr = MTD._stickyRuler;
    if (sr) {
        if (sr.line) MTD.map.removeLayer(sr.line);
        if (sr.label) MTD.map.removeLayer(sr.label);
        if (sr.dotA) MTD.map.removeLayer(sr.dotA);
        if (sr.dotB) MTD.map.removeLayer(sr.dotB);
    }
    MTD._stickyRuler = null;
    MTD._stickyPending = null;
}

function getEntityPos(type, name) {
    var data = MTD._lastRefreshData;
    if (!data) return null;
    if (type === "battery") {
        var lat = data.batLatMap[name];
        var lon = data.batLonMap[name];
        if (lat !== undefined && lon !== undefined) return [lat, lon];
    } else if (type === "track") {
        var tlat = data.trkLatMap[name];
        var tlon = data.trkLonMap[name];
        if (tlat !== undefined && tlon !== undefined) return [tlat, tlon];
    }
    return null;
}

MTD.updateStickyRuler = function () {
    var sr = MTD._stickyRuler;
    if (!sr) return;
    var posA = getEntityPos(sr.startType, sr.startName);
    var posB = getEntityPos(sr.endType, sr.endName);
    if (!posA || !posB) return;
    sr.line.setLatLngs([posA, posB]);
    sr.dotA.setLatLng(posA);
    sr.dotB.setLatLng(posB);
    var distM = MTD.haversineM(posA[0], posA[1], posB[0], posB[1]);
    var text = (distM / 1852).toFixed(1) + " nm / " + (distM / 1000).toFixed(1) + " km";
    var midLat = (posA[0] + posB[0]) / 2;
    var midLon = (posA[1] + posB[1]) / 2;
    sr.label.setLatLng([midLat, midLon]);
    sr.label.setIcon(L.divIcon({
        className: "",
        html: '<div style="background:rgba(20,20,30,0.85);color:' + _STICKY_COLOR + ';font-size:12px;font-weight:600;padding:2px 8px;border-radius:4px;white-space:nowrap;text-shadow:0 0 3px #000;">' + text + '</div>',
        iconSize: [0, 0],
        iconAnchor: [0, 0]
    }));
};

function completeStickyRuler(startType, startName, endType, endName) {
    clearStickyRuler();
    var posA = getEntityPos(startType, startName);
    var posB = getEntityPos(endType, endName);
    if (!posA || !posB) return;
    var line = L.polyline([posA, posB], {
        color: _STICKY_COLOR,
        weight: 2,
        opacity: 0.9,
        dashArray: "6 4"
    }).addTo(MTD.map);
    var distM = MTD.haversineM(posA[0], posA[1], posB[0], posB[1]);
    var text = (distM / 1852).toFixed(1) + " nm / " + (distM / 1000).toFixed(1) + " km";
    var midLat = (posA[0] + posB[0]) / 2;
    var midLon = (posA[1] + posB[1]) / 2;
    var label = L.marker([midLat, midLon], {
        icon: L.divIcon({
            className: "",
            html: '<div style="background:rgba(20,20,30,0.85);color:' + _STICKY_COLOR + ';font-size:12px;font-weight:600;padding:2px 8px;border-radius:4px;white-space:nowrap;text-shadow:0 0 3px #000;">' + text + '</div>',
            iconSize: [0, 0],
            iconAnchor: [0, 0]
        }),
        interactive: false
    }).addTo(MTD.map);
    var dotA = L.circleMarker(posA, {
        radius: 4, color: _STICKY_COLOR, fillColor: _STICKY_COLOR, fillOpacity: 1, weight: 1
    }).addTo(MTD.map);
    var dotB = L.circleMarker(posB, {
        radius: 4, color: _STICKY_COLOR, fillColor: _STICKY_COLOR, fillOpacity: 1, weight: 1
    }).addTo(MTD.map);
    /* Right-click the line to remove */
    line.on("contextmenu", function (e) {
        L.DomEvent.stopPropagation(e);
        L.DomEvent.preventDefault(e);
        clearStickyRuler();
    });
    MTD._stickyRuler = {
        startType: startType, startName: startName,
        endType: endType, endName: endName,
        line: line, label: label, dotA: dotA, dotB: dotB
    };
}

/* Called from render.js when an entity is right-clicked */
MTD.onEntityRightClick = function (type, name, e) {
    L.DomEvent.stopPropagation(e);
    L.DomEvent.preventDefault(e);
    if (MTD._stickyPending) {
        /* Second right-click — complete the ruler */
        var start = MTD._stickyPending;
        MTD._stickyPending = null;
        if (start.type === type && start.name === name) return; /* same entity */
        completeStickyRuler(start.type, start.name, type, name);
    } else {
        /* First right-click — set pending */
        clearStickyRuler();
        MTD._stickyPending = { type: type, name: name };
        MTD.toast("Ruler: right-click another entity to measure", 2000);
    }
};

/* Find nearest entity within pixel threshold */
function findNearestEntity(latlng, pixelThreshold) {
    var map = MTD.map;
    var clickPt = map.latLngToContainerPoint(latlng);
    var best = null;
    var bestDist = pixelThreshold + 1;
    /* Check batteries */
    var bNames = Object.keys(MTD.batteryMarkers);
    for (var bi = 0; bi < bNames.length; bi++) {
        var bm = MTD.batteryMarkers[bNames[bi]];
        if (bm && bm.dot) {
            var bPt = map.latLngToContainerPoint(bm.dot.getLatLng());
            var bd = Math.sqrt(Math.pow(clickPt.x - bPt.x, 2) + Math.pow(clickPt.y - bPt.y, 2));
            if (bd < bestDist) { bestDist = bd; best = { type: "battery", name: bNames[bi] }; }
        }
    }
    /* Check tracks */
    var tNames = Object.keys(MTD.trackMarkers);
    for (var ti = 0; ti < tNames.length; ti++) {
        var tm = MTD.trackMarkers[tNames[ti]];
        if (tm && tm.icon) {
            var tPt = map.latLngToContainerPoint(tm.icon.getLatLng());
            var td = Math.sqrt(Math.pow(clickPt.x - tPt.x, 2) + Math.pow(clickPt.y - tPt.y, 2));
            if (td < bestDist) { bestDist = td; best = { type: "track", name: tNames[ti] }; }
        }
    }
    return best;
}

/* Map-level right-click handler with proximity snap */
MTD.map.on("contextmenu", function (e) {
    L.DomEvent.preventDefault(e);
    var nearest = findNearestEntity(e.latlng, 40);
    if (nearest) {
        MTD.onEntityRightClick(nearest.type, nearest.name, e);
        return;
    }
    /* No entity nearby — cancel pending if any */
    if (MTD._stickyPending) {
        MTD._stickyPending = null;
        MTD.toast("Ruler cancelled", 1500);
    }
});
