/* render.js -- Map entity rendering for Medusa Tactical Display */
"use strict";

window.MTD = window.MTD || {};

/* ---- Inoperative battery icon (⊘ circle-slash) ---- */

function _inopIcon(color) {
    return L.divIcon({
        className: "",
        html: '<svg width="16" height="16" viewBox="0 0 16 16">' +
              '<circle cx="8" cy="8" r="6" fill="none" stroke="' + color + '" stroke-width="1.5" opacity="0.7"/>' +
              '<line x1="3" y1="13" x2="13" y2="3" stroke="' + color + '" stroke-width="1.5" opacity="0.7"/>' +
              '</svg>',
        iconSize: [16, 16],
        iconAnchor: [8, 8]
    });
}

/* ---- Batteries ---- */

MTD.renderBatteries = function (data) {
    var batteryLayer  = MTD.batteryLayer;
    var labelLayer    = MTD.labelLayer;
    var batteryMarkers = MTD.batteryMarkers;
    var batLatMap     = data.batLatMap;
    var batLonMap     = data.batLonMap;
    var batInfoMap    = data.batInfoMap;
    var batRangeMap   = data.batRangeMap;
    var batShotsMap   = data.batShotsMap;
    var showThreatRings = MTD.opt("opt-threat-rings");
    var showBatLabels   = MTD.opt("opt-bat-labels");

    var bounds   = [];
    var hotCount = 0;
    var totalBat = 0;
    var currentBatteryStatus = {};

    /* Reset ringsByBattery for this cycle */
    MTD.ringsByBattery = {};

    var currentBatterySet = {};

    var batteryNames = Object.keys(batLatMap);
    for (var bi = 0; bi < batteryNames.length; bi++) {
        var bName = batteryNames[bi];
        if (batLonMap[bName] === undefined) continue;

        var bPos = [batLatMap[bName], batLonMap[bName]];
        bounds.push(bPos);
        totalBat++;
        currentBatterySet[bName] = true;

        var info   = batInfoMap[bName] || {};
        var state  = info.state || "COLD";
        var system = info.system || "unknown";
        var target = info.target || "";

        var isHot = state === "STATE_HOT";
        if (isHot) hotCount++;

        var status = info.status || "ACTIVE";
        var isInop = status !== "ACTIVE";
        var radius = isHot ? 7 : 4;
        var color  = isHot ? "#4caf50" : "#4a90d9";

        var tooltip = bName + "\n" + system;
        if (isInop) {
            tooltip += "\n" + status;
        }
        if (isHot && target) {
            tooltip += "\nTarget: " + target;
        }

        var existing = batteryMarkers[bName];

        if (existing) {
            /* Swap marker type if inop state changed */
            if (isInop !== existing.isInop) {
                batteryLayer.removeLayer(existing.dot);
                existing.dot = null;
            }
            if (!existing.dot) {
                if (isInop) {
                    existing.dot = L.marker(bPos, { icon: _inopIcon(color) }).addTo(batteryLayer);
                } else {
                    existing.dot = L.circleMarker(bPos, { radius: radius, color: color, fillColor: color, fillOpacity: 0.8, weight: 1 }).addTo(batteryLayer);
                }
                existing.isInop = isInop;
            }
            /* Update existing marker position and style */
            existing.dot.setLatLng(bPos);
            if (!isInop) {
                existing.dot.setRadius(radius);
                existing.dot.setStyle({ color: color, fillColor: color });
            } else {
                existing.dot.setIcon(_inopIcon(color));
            }
            var tooltipHtml = tooltip.replace(/\n/g, "<br>");
            if (existing._lastTooltip !== tooltipHtml) {
                existing.dot.unbindTooltip();
                existing.dot.bindTooltip(tooltipHtml);
                existing._lastTooltip = tooltipHtml;
            }

            /* Update or remove range ring -- only recreate if range or position changed */
        } else {
            /* Create new battery marker */
            var batMarker;
            if (isInop) {
                batMarker = L.marker(bPos, { icon: _inopIcon(color) }).bindTooltip(tooltip.replace(/\n/g, "<br>")).addTo(batteryLayer);
            } else {
                batMarker = L.circleMarker(bPos, {
                    radius: radius,
                    color: color,
                    fillColor: color,
                    fillOpacity: 0.8,
                    weight: 1
                }).bindTooltip(tooltip.replace(/\n/g, "<br>")).addTo(batteryLayer);
            }

            /* Click + right-click handlers */
            (function (bn) {
                batMarker.on("click", function () {
                    MTD.selectedEntity = { type: "battery", name: bn };
                    MTD.showDetailCard("battery", bn, data);
                });
                batMarker.on("contextmenu", function (e) {
                    MTD.onEntityRightClick("battery", bn, e);
                });
            })(bName);

            existing = { dot: batMarker, ring: null, label: null, isInop: isInop };
            batteryMarkers[bName] = existing;
        }

        /* Engagement range ring + cluster visuals (created once, updated in place) */
        var rangeM = batRangeMap[bName];
        var role = info.role || "";
        var ringColor = role === "LR_SAM" ? "#e53935"
                      : role === "MR_SAM" ? "#ff9800"
                      : "#ffeb3b";
        var hasClusters = !!(data.clusterMap || {})[bName];

        if (!existing._ringBuilt) {
            /* First time: build ring and cluster visuals */
            existing._clusterLayers = [];

            if (hasClusters) {
                var clusters = data.clusterMap[bName];
                var clusterKeys = Object.keys(clusters);
                var clusterCircles = [];
                for (var ci = 0; ci < clusterKeys.length; ci++) {
                    var cl = clusters[clusterKeys[ci]];
                    if (cl.lat === undefined || cl.lon === undefined) continue;
                    var cPos = [cl.lat, cl.lon];
                    var diamondIcon = L.divIcon({
                        className: "",
                        html: '<svg width="10" height="10" viewBox="0 0 10 10">' +
                              '<polygon points="5,0 10,5 5,10 0,5" fill="' + color + '" opacity="0.7"/></svg>',
                        iconSize: [10, 10],
                        iconAnchor: [5, 5]
                    });
                    var dm = L.marker(cPos, { icon: diamondIcon, interactive: false }).addTo(batteryLayer);
                    existing._clusterLayers.push(dm);
                    var dl = L.polyline([cPos, bPos], {
                        color: color, weight: 1, opacity: 0.4, dashArray: "4 4", interactive: false
                    }).addTo(batteryLayer);
                    existing._clusterLayers.push(dl);
                    var clRangeM = cl.rangeM || rangeM;
                    if (showThreatRings && clRangeM && clRangeM > 0 && typeof turf !== "undefined") {
                        clusterCircles.push(turf.circle([cl.lon, cl.lat], clRangeM / 1000, { steps: 64 }));
                    }
                }
                if (clusterCircles.length > 0) {
                    var merged = clusterCircles[0];
                    for (var mi = 1; mi < clusterCircles.length; mi++) {
                        try { merged = turf.union(turf.featureCollection([merged, clusterCircles[mi]])); } catch (e) { break; }
                    }
                    var coords = merged.geometry.type === "MultiPolygon"
                        ? merged.geometry.coordinates
                        : [merged.geometry.coordinates];
                    var latLngs = [];
                    for (var ri = 0; ri < coords.length; ri++) {
                        var cring = coords[ri][0];
                        var pts = [];
                        for (var pi = 0; pi < cring.length; pi++) {
                            pts.push([cring[pi][1], cring[pi][0]]);
                        }
                        latLngs.push(pts);
                    }
                    existing.ring = L.polygon(latLngs, {
                        color: ringColor || "#ffeb3b", fill: false,
                        weight: 1, opacity: 0.4, interactive: false
                    }).addTo(batteryLayer);
                    MTD.ringsByBattery[bName] = existing.ring;
                }
            } else if (showThreatRings && rangeM && rangeM > 0) {
                existing.ring = L.circle(bPos, {
                    radius: rangeM, color: ringColor,
                    fill: false, weight: 1, opacity: 0.4
                }).addTo(batteryLayer);
                MTD.ringsByBattery[bName] = existing.ring;
            }

            /* Hover handlers: bind once */
            if (existing.ring) {
                (function (dot, ring) {
                    dot.on("mouseover", function () { ring.setStyle({ weight: 2, opacity: 0.7 }); });
                    dot.on("mouseout",  function () { ring.setStyle({ weight: 1, opacity: 0.4 }); });
                })(existing.dot, existing.ring);
            }
            existing._ringBuilt = true;
        } else if (existing.ring && !hasClusters) {
            /* Update existing circle ring position */
            existing.ring.setLatLng(bPos);
        }

        /* Battery label */
        if (showBatLabels) {
            var shortBatName = MTD.shortName(bName);
            if (existing.label) {
                existing.label.setLatLng(bPos);
            } else {
                existing.label = L.marker(bPos, {
                    icon: L.divIcon({
                        className: "",
                        html: '<div style="color:' + color + ';font-size:9px;text-shadow:0 0 3px #000,0 0 3px #000;white-space:nowrap;margin-left:10px;">' + shortBatName + '</div>',
                        iconSize: [60, 12],
                        iconAnchor: [-2, 6]
                    }),
                    interactive: false
                }).addTo(labelLayer);
            }
        } else if (existing.label) {
            labelLayer.removeLayer(existing.label);
            existing.label = null;
        }

        /* Pulse on shot -- one pulse per new shot, staggered 1s apart, max 5 */
        var curShots  = batShotsMap[bName] || 0;
        var prevShots = (MTD.prevShotsMap || {})[bName] || 0;
        var newShots  = curShots - prevShots;
        if (newShots > 0 && prevShots > 0) {
            var pulseCount = Math.min(newShots, 5);
            var pulseRadius = rangeM || 20000;
            for (var ps = 0; ps < pulseCount; ps++) {
                (function (delay, c, p, maxR) {
                    setTimeout(function () {
                        var circle = L.circle(p, {
                            radius: 100,
                            color: c,
                            fill: false,
                            weight: 2,
                            opacity: 0.8,
                            interactive: false
                        }).addTo(MTD.killLayer);
                        var startTime = Date.now();
                        var duration = 1500;
                        var anim = setInterval(function () {
                            var elapsed = Date.now() - startTime;
                            var t = Math.min(elapsed / duration, 1);
                            circle.setRadius(100 + t * maxR);
                            circle.setStyle({ opacity: 0.8 * (1 - t), weight: 2 * (1 - t * 0.5) });
                            if (t >= 1) {
                                clearInterval(anim);
                                MTD.killLayer.removeLayer(circle);
                            }
                        }, 30);
                    }, delay);
                })(ps * 1000, color, bPos, pulseRadius);
            }
        }

        /* Red pulse on damage — status changed from ACTIVE to something else */
        var prevStatus = (MTD.prevBatteryStatus || {})[bName];
        var curStatus = (info.status || "ACTIVE");
        if (prevStatus === "ACTIVE" && curStatus !== "ACTIVE") {
            var dmgRadius = rangeM || 20000;
            (function (p, maxR) {
                for (var dp = 0; dp < 3; dp++) {
                    (function (delay) {
                        setTimeout(function () {
                            var circle = L.circle(p, {
                                radius: 100,
                                color: "#e53935",
                                fill: false,
                                weight: 3,
                                opacity: 0.9,
                                interactive: false
                            }).addTo(MTD.killLayer);
                            var startTime = Date.now();
                            var duration = 1500;
                            var anim = setInterval(function () {
                                var elapsed = Date.now() - startTime;
                                var t = Math.min(elapsed / duration, 1);
                                circle.setRadius(100 + t * maxR);
                                circle.setStyle({ opacity: 0.9 * (1 - t), weight: 3 * (1 - t * 0.5) });
                                if (t >= 1) {
                                    clearInterval(anim);
                                    MTD.killLayer.removeLayer(circle);
                                }
                            }, 30);
                        }, delay);
                    })(dp * 1000);
                }
            })(bPos, dmgRadius);
        }
        currentBatteryStatus[bName] = curStatus;
    }

    /* Remove batteries that are gone */
    var existingBatNames = Object.keys(batteryMarkers);
    for (var rbi = 0; rbi < existingBatNames.length; rbi++) {
        var rbName = existingBatNames[rbi];
        if (!currentBatterySet[rbName]) {
            var rmBat = batteryMarkers[rbName];
            batteryLayer.removeLayer(rmBat.dot);
            if (rmBat.ring) batteryLayer.removeLayer(rmBat.ring);
            if (rmBat._clusterLayers) {
                for (var cli = 0; cli < rmBat._clusterLayers.length; cli++) {
                    batteryLayer.removeLayer(rmBat._clusterLayers[cli]);
                }
            }
            if (rmBat.label) labelLayer.removeLayer(rmBat.label);
            delete batteryMarkers[rbName];
        }
    }

    MTD.prevBatteryStatus = currentBatteryStatus;
    return { bounds: bounds, hotCount: hotCount, totalBat: totalBat };
};

/* ---- Tracks ---- */

MTD.renderTracks = function (data, trackHeadings) {
    var trackLayer   = MTD.trackLayer;
    var labelLayer   = MTD.labelLayer;
    var trackMarkers = MTD.trackMarkers;
    var trkLatMap    = data.trkLatMap;
    var trkLonMap    = data.trkLonMap;
    var trkInfoMap   = data.trkInfoMap;
    var batLatMap    = data.batLatMap;
    var batLonMap    = data.batLonMap;
    var batRangeMap  = data.batRangeMap;
    var showTrackLabels = MTD.opt("opt-track-labels");

    var bounds = [];
    var currentTrackSet = {};

    var trackNames = Object.keys(trkLatMap);
    for (var tj = 0; tj < trackNames.length; tj++) {
        var tName2 = trackNames[tj];
        if (trkLonMap[tName2] === undefined) continue;

        var tPos     = [trkLatMap[tName2], trkLonMap[tName2]];
        bounds.push(tPos);
        var tInfo2   = trkInfoMap[tName2] || {};
        var unitName = tInfo2.unit || "";
        var aircraftType   = tInfo2.aircraft_type || tInfo2.type || "";
        var identification = tInfo2.identification || "UNKNOWN";
        var isHarm   = aircraftType === "HARM";
        var heading  = (trackHeadings || {})[tName2] || 0;
        currentTrackSet[tName2] = true;

        var tTooltip = "Track " + tName2;
        if (unitName) tTooltip += "\n" + unitName;
        if (isHarm) tTooltip += "\nHARM";
        else if (aircraftType) tTooltip += "\n" + aircraftType;
        tTooltip += "\n" + identification;

        var existingTrk = trackMarkers[tName2];
        if (existingTrk) {
            /* Update existing track marker */
            existingTrk.icon.setLatLng(tPos);
            existingTrk.icon.setIcon(MTD.trackIconForId(identification, heading, isHarm));
            var tTooltipHtml = tTooltip.replace(/\n/g, "<br>");
            if (existingTrk._lastTooltip !== tTooltipHtml) {
                existingTrk.icon.unbindTooltip();
                existingTrk.icon.bindTooltip(tTooltipHtml);
                existingTrk._lastTooltip = tTooltipHtml;
            }
        } else {
            /* Create new track marker */
            var tMarker = L.marker(tPos, { icon: MTD.trackIconForId(identification, heading, isHarm) })
                .bindTooltip(tTooltip.replace(/\n/g, "<br>"))
                .addTo(trackLayer);

            /* Click + right-click handlers */
            (function (tn2) {
                tMarker.on("click", function () {
                    MTD.selectedEntity = { type: "track", name: tn2 };
                    MTD.showDetailCard("track", tn2, data);
                });
                tMarker.on("contextmenu", function (e) {
                    MTD.onEntityRightClick("track", tn2, e);
                });
            })(tName2);

            /* Mouseover handler for engagement ring highlight */
            (function (tn2) {
                tMarker.on("mouseover", function () {
                    if (trkLatMap[tn2] === undefined || trkLonMap[tn2] === undefined) return;
                    var tLat = trkLatMap[tn2];
                    var tLon = trkLonMap[tn2];
                    var bNames = Object.keys(MTD.ringsByBattery);
                    for (var rhi = 0; rhi < bNames.length; rhi++) {
                        var rbn = bNames[rhi];
                        var ring = MTD.ringsByBattery[rbn];
                        if (!ring) continue;
                        var bLat = batLatMap[rbn];
                        var bLon = batLonMap[rbn];
                        if (bLat === undefined || bLon === undefined) continue;
                        var dist = MTD.haversineM(bLat, bLon, tLat, tLon);
                        var engRange = batRangeMap[rbn] || 0;
                        if (engRange > 0 && dist <= engRange) {
                            ring.setStyle({ weight: 2, opacity: 0.8 });
                        }
                    }
                });
                tMarker.on("mouseout", function () {
                    var bNames = Object.keys(MTD.ringsByBattery);
                    for (var rhi = 0; rhi < bNames.length; rhi++) {
                        var ring = MTD.ringsByBattery[bNames[rhi]];
                        if (ring) {
                            ring.setStyle({ weight: 1, opacity: 0.4 });
                        }
                    }
                });
            })(tName2);

            existingTrk = { icon: tMarker, label: null };
            trackMarkers[tName2] = existingTrk;
        }

        /* Track callsign label */
        if (showTrackLabels && unitName) {
            if (existingTrk.label) {
                existingTrk.label.setLatLng(tPos);
            } else {
                existingTrk.label = L.marker(tPos, {
                    icon: L.divIcon({
                        className: "",
                        html: '<div style="color:#fff;font-size:10px;text-shadow:0 0 3px #000,0 0 3px #000;white-space:nowrap;margin-left:10px;">' + unitName + '</div>',
                        iconSize: [80, 14],
                        iconAnchor: [-2, 7]
                    }),
                    interactive: false
                }).addTo(labelLayer);
            }
        } else if (existingTrk.label) {
            labelLayer.removeLayer(existingTrk.label);
            existingTrk.label = null;
        }
    }

    /* Remove tracks that are gone */
    var existingTrkNames = Object.keys(trackMarkers);
    for (var rti = 0; rti < existingTrkNames.length; rti++) {
        var rtName = existingTrkNames[rti];
        if (!currentTrackSet[rtName]) {
            var rmTrk = trackMarkers[rtName];
            trackLayer.removeLayer(rmTrk.icon);
            if (rmTrk.label) labelLayer.removeLayer(rmTrk.label);
            delete trackMarkers[rtName];
        }
    }

    return { bounds: bounds };
};

/* ---- Engagement lines (best Pk and 2nd Pk) ---- */

MTD.renderEngagementLines = function (data) {
    var trailLayer      = MTD.trailLayer;
    var bestPkResults   = data.bestPkResults;
    var secondPkResults = data.secondPkResults;
    var trkLatMap       = data.trkLatMap;
    var trkLonMap       = data.trkLonMap;
    var trkInfoMap      = data.trkInfoMap;
    var batLatMap       = data.batLatMap;
    var batLonMap       = data.batLonMap;
    var batInfoMap      = data.batInfoMap;
    var showBestPk      = MTD.opt("opt-best-pk");
    var showSecondPk    = MTD.opt("opt-second-pk");
    var showPkLabels    = MTD.opt("opt-pk-labels");

    /* Best Pk engagement lines */
    if (showBestPk) {
        for (var pi = 0; pi < bestPkResults.length; pi++) {
            var pkr       = bestPkResults[pi];
            var pkTrack   = pkr.metric.track;
            var pkBattery = pkr.metric.battery;
            var pkVal     = parseFloat(pkr.value[1]);

            if (trkLatMap[pkTrack] === undefined || trkLonMap[pkTrack] === undefined) continue;
            if (batLatMap[pkBattery] === undefined || batLonMap[pkBattery] === undefined) continue;

            var trkPos = [trkLatMap[pkTrack], trkLonMap[pkTrack]];
            var batPos = [batLatMap[pkBattery], batLonMap[pkBattery]];
            /* For clustered batteries, draw line from nearest cluster */
            var clusters = (data.clusterMap || {})[pkBattery];
            if (clusters) {
                var bestDist = Infinity;
                var clKeys = Object.keys(clusters);
                for (var cli = 0; cli < clKeys.length; cli++) {
                    var cl = clusters[clKeys[cli]];
                    if (cl.lat !== undefined && cl.lon !== undefined) {
                        var cd = MTD.haversineM(cl.lat, cl.lon, trkPos[0], trkPos[1]);
                        if (cd < bestDist) { bestDist = cd; batPos = [cl.lat, cl.lon]; }
                    }
                }
            }
            var bInfo  = batInfoMap[pkBattery] || {};
            var isActiveTarget = bInfo.target === pkTrack;

            /* Tooltip with distance */
            var distM = MTD.haversineM(batPos[0], batPos[1], trkPos[0], trkPos[1]);
            var distNm = (distM / 1852).toFixed(1);
            var shortBat = MTD.shortName(pkBattery);
            var trkUnit = (trkInfoMap[pkTrack] || {}).unit || pkTrack;
            var lineTooltip = shortBat + " \u2192 " + trkUnit + ", Pk=" + pkVal.toFixed(2) + ", dist=" + distNm + "nm";

            L.polyline([batPos, trkPos], {
                color: isActiveTarget ? "#e53935" : "#4fc3f7",
                weight: isActiveTarget ? 2 : 1.5,
                opacity: isActiveTarget ? 0.8 : 0.6,
                dashArray: isActiveTarget ? "6 6" : "10 6"
            }).bindTooltip(lineTooltip).addTo(trailLayer);

            if (showPkLabels) {
                var midLat = (batPos[0] + trkPos[0]) / 2;
                var midLon = (batPos[1] + trkPos[1]) / 2;
                var labelColor = isActiveTarget ? "#ff6659" : "#fff";
                var pkMarker = L.marker([midLat, midLon], {
                    icon: L.divIcon({
                        className: "",
                        html: '<div style="color:' + labelColor + ';font-size:10px;text-shadow:0 0 3px #000;cursor:pointer;">' + pkVal.toFixed(2) + '</div>',
                        iconSize: [30, 14],
                        iconAnchor: [15, 7]
                    })
                }).addTo(trailLayer);
                (function (bat, trk) {
                    pkMarker.on("click", function () {
                        MTD.showPkPairCards(bat, trk, data);
                    });
                })(pkBattery, pkTrack);
            }
        }
    }

    /* 2nd Best Pk engagement lines */
    if (showSecondPk) {
        for (var si2 = 0; si2 < secondPkResults.length; si2++) {
            var spk       = secondPkResults[si2];
            var spkTrack  = spk.metric.track;
            var spkBatt   = spk.metric.battery;

            if (trkLatMap[spkTrack] === undefined || trkLonMap[spkTrack] === undefined) continue;
            if (batLatMap[spkBatt] === undefined || batLonMap[spkBatt] === undefined) continue;

            var sTrkPos = [trkLatMap[spkTrack], trkLonMap[spkTrack]];
            var sBatPos = [batLatMap[spkBatt], batLonMap[spkBatt]];
            var sClusters = (data.clusterMap || {})[spkBatt];
            if (sClusters) {
                var sBestDist = Infinity;
                var sClKeys = Object.keys(sClusters);
                for (var sci = 0; sci < sClKeys.length; sci++) {
                    var scl = sClusters[sClKeys[sci]];
                    if (scl.lat !== undefined && scl.lon !== undefined) {
                        var scd = MTD.haversineM(scl.lat, scl.lon, sTrkPos[0], sTrkPos[1]);
                        if (scd < sBestDist) { sBestDist = scd; sBatPos = [scl.lat, scl.lon]; }
                    }
                }
            }

            /* Tooltip with distance */
            var sDistM = MTD.haversineM(sBatPos[0], sBatPos[1], sTrkPos[0], sTrkPos[1]);
            var sDistNm = (sDistM / 1852).toFixed(1);
            var sShortBat = MTD.shortName(spkBatt);
            var sTrkUnit = (trkInfoMap[spkTrack] || {}).unit || spkTrack;
            var spkVal2  = parseFloat(spk.value[1]);
            var sLineTooltip = sShortBat + " \u2192 " + sTrkUnit + ", Pk=" + spkVal2.toFixed(2) + ", dist=" + sDistNm + "nm";

            L.polyline([sBatPos, sTrkPos], {
                color: "#888888",
                weight: 1,
                opacity: 0.5,
                dashArray: "4 8"
            }).bindTooltip(sLineTooltip).addTo(trailLayer);

            if (showPkLabels) {
                var sMidLat = (sBatPos[0] + sTrkPos[0]) / 2;
                var sMidLon = (sBatPos[1] + sTrkPos[1]) / 2;
                var spkMarker = L.marker([sMidLat, sMidLon], {
                    icon: L.divIcon({
                        className: "",
                        html: '<div style="color:#999;font-size:9px;text-shadow:0 0 3px #000;cursor:pointer;">' + spkVal2.toFixed(2) + '</div>',
                        iconSize: [30, 14],
                        iconAnchor: [15, 7]
                    })
                }).addTo(trailLayer);
                (function (bat, trk) {
                    spkMarker.on("click", function () {
                        MTD.showPkPairCards(bat, trk, data);
                    });
                })(spkBatt, spkTrack);
            }
        }
    }
};

/* ---- Track trails (altitude-colored + velocity vectors) ---- */

MTD._trailCache = MTD._trailCache || {};
MTD._trailLastQuery = 0;

MTD.renderTrails = async function (data) {
    var trailLayer = MTD.trailLayer;
    var trkLatMap  = data.trkLatMap;
    var trkLonMap  = data.trkLonMap;
    MTD._trackHeadings = MTD._trackHeadings || {};
    var trackHeadings = MTD._trackHeadings;

    var trackNames = Object.keys(trkLatMap);
    if (trackNames.length === 0) return trackHeadings;

    try {
        var now = Math.floor(Date.now() / 1000);
        var maxAge = 180;
        var cutoff = now - maxAge;
        /* First query: full lookback. Subsequent: only since last query. */
        var queryStart = MTD._trailLastQuery > 0 ? MTD._trailLastQuery - 2 : now - maxAge;
        var trailResults = await Promise.all([
            MTD.queryRange(MTD.netExpr("medusa_track_lat"), queryStart, now, 5),
            MTD.queryRange(MTD.netExpr("medusa_track_lon"), queryStart, now, 5),
            MTD.queryRange(MTD.netExpr("medusa_track_pos_y"), queryStart, now, 5)
        ]);
        MTD._trailLastQuery = now;

        /* Merge new data into cache */
        var cache = MTD._trailCache;
        for (var tl = 0; tl < trailResults[0].length; tl++) {
            var trk0 = trailResults[0][tl].metric.track;
            if (!cache[trk0]) cache[trk0] = { lat: {}, lon: {}, alt: {} };
            var vals0 = trailResults[0][tl].values;
            for (var v0 = 0; v0 < vals0.length; v0++) cache[trk0].lat[vals0[v0][0]] = parseFloat(vals0[v0][1]);
        }
        for (var tln = 0; tln < trailResults[1].length; tln++) {
            var trk1 = trailResults[1][tln].metric.track;
            if (!cache[trk1]) cache[trk1] = { lat: {}, lon: {}, alt: {} };
            var vals1 = trailResults[1][tln].values;
            for (var v1 = 0; v1 < vals1.length; v1++) cache[trk1].lon[vals1[v1][0]] = parseFloat(vals1[v1][1]);
        }
        for (var ta = 0; ta < trailResults[2].length; ta++) {
            var trk2 = trailResults[2][ta].metric.track;
            if (!cache[trk2]) cache[trk2] = { lat: {}, lon: {}, alt: {} };
            var vals2 = trailResults[2][ta].values;
            for (var v2 = 0; v2 < vals2.length; v2++) cache[trk2].alt[vals2[v2][0]] = parseFloat(vals2[v2][1]);
        }

        /* Evict old data from cache */
        var cacheKeys = Object.keys(cache);
        for (var ck = 0; ck < cacheKeys.length; ck++) {
            var entry = cache[cacheKeys[ck]];
            for (var ts in entry.lat) { if (ts < cutoff) { delete entry.lat[ts]; delete entry.lon[ts]; delete entry.alt[ts]; } }
            if (Object.keys(entry.lat).length === 0) delete cache[cacheKeys[ck]];
        }

        /* Build trail data from cache */
        var trailLat = {};
        var trailLon = {};
        var trailAlt = {};
        for (var tk in cache) {
            var e = cache[tk];
            var timestamps = Object.keys(e.lat).sort();
            if (timestamps.length === 0) continue;
            trailLat[tk] = [];
            trailLon[tk] = [];
            trailAlt[tk] = [];
            for (var ti = 0; ti < timestamps.length; ti++) {
                var t = timestamps[ti];
                trailLat[tk].push([t, e.lat[t]]);
                if (e.lon[t] !== undefined) trailLon[tk].push([t, e.lon[t]]);
                trailAlt[tk].push([t, e.alt[t] || 0]);
            }
        }

        var trailTracks = Object.keys(trailLat);
        for (var tt = 0; tt < trailTracks.length; tt++) {
            var trk = trailTracks[tt];
            if (!trailLon[trk]) continue;

            var latVals = trailLat[trk];
            var lonVals = trailLon[trk];

            /* Build timestamp-indexed maps */
            var lonByTime = {};
            for (var li = 0; li < lonVals.length; li++) {
                lonByTime[lonVals[li][0]] = parseFloat(lonVals[li][1]);
            }
            var altByTime = {};
            if (trailAlt[trk]) {
                for (var ai = 0; ai < trailAlt[trk].length; ai++) {
                    altByTime[trailAlt[trk][ai][0]] = parseFloat(trailAlt[trk][ai][1]);
                }
            }

            /* Assemble ordered trail points */
            var trailPoints = [];
            var trailAlts = [];
            for (var xi = 0; xi < latVals.length; xi++) {
                var ts   = latVals[xi][0];
                var latv = parseFloat(latVals[xi][1]);
                if (lonByTime[ts] !== undefined) {
                    trailPoints.push([latv, lonByTime[ts]]);
                    trailAlts.push(altByTime[ts] || 0);
                }
            }

            /* Draw segments colored by altitude */
            var isGone       = trkLatMap[trk] === undefined;
            var trailOpacity = isGone ? 0.35 : 0.7;
            var trailWeight  = isGone ? 1.5 : 2.5;
            for (var seg = 0; seg < trailPoints.length - 1; seg++) {
                var segDist = MTD.haversineM(
                    trailPoints[seg][0], trailPoints[seg][1],
                    trailPoints[seg + 1][0], trailPoints[seg + 1][1]
                );
                if (segDist > 50000) continue; /* skip >50km jumps (mission reset artifact) */
                L.polyline([trailPoints[seg], trailPoints[seg + 1]], {
                    color: MTD.altitudeColor(trailAlts[seg]),
                    weight: trailWeight,
                    opacity: trailOpacity
                }).addTo(trailLayer);
            }

            /* Connect trail to current instant position */
            var curLat = trkLatMap[trk];
            var curLon = trkLonMap[trk];
            if (curLat !== undefined && curLon !== undefined && trailPoints.length >= 1) {
                var lastTrail = trailPoints[trailPoints.length - 1];
                var curPos = [curLat, curLon];
                var bridgeDist = MTD.haversineM(lastTrail[0], lastTrail[1], curPos[0], curPos[1]);
                if (bridgeDist < 50000) {
                    L.polyline([lastTrail, curPos], {
                        color: MTD.altitudeColor(trailAlts[trailAlts.length - 1] || 0),
                        weight: trailWeight,
                        opacity: trailOpacity
                    }).addTo(trailLayer);
                }
            }

            /* Velocity vector + heading from last two trail points, drawn from current position */
            if (trailPoints.length >= 2 && curLat !== undefined && curLon !== undefined) {
                var p1 = trailPoints[trailPoints.length - 2];
                var p2 = trailPoints[trailPoints.length - 1];
                var t1 = parseFloat(latVals[latVals.length - 2][0]);
                var t2 = parseFloat(latVals[latVals.length - 1][0]);
                var dt = t2 - t1;
                if (dt > 0) {
                    var dLat = (p2[0] - p1[0]) / dt;
                    var dLon = (p2[1] - p1[1]) / dt;
                    trackHeadings[trk] = Math.atan2(dLon, dLat) * 180 / Math.PI;
                    var projLat = curLat + dLat * 30;
                    var projLon = curLon + dLon * 30;
                    L.polyline([[curLat, curLon], [projLat, projLon]], {
                        color: "#ffffff",
                        weight: 1.5,
                        opacity: 0.6
                    }).addTo(trailLayer);
                }
            }
        }
    } catch (trailErr) {
        /* Trail fetch failed -- non-critical */
    }

    /* Clean up headings for expired tracks */
    for (var hk in trackHeadings) {
        if (trkLatMap[hk] === undefined) {
            delete trackHeadings[hk];
        }
    }

    return trackHeadings;
};

/* ---- Kill markers ---- */

MTD.renderKills = function (prevPositions, currentPositions) {
    var killLayer = MTD.killLayer;
    var prevTrackNames = Object.keys(prevPositions);
    for (var pti = 0; pti < prevTrackNames.length; pti++) {
        var ptn = prevTrackNames[pti];
        if (!currentPositions[ptn]) {
            /* Track disappeared -- place kill marker */
            var killPos = prevPositions[ptn];
            var killMarker = L.marker(killPos, {
                icon: L.divIcon({
                    className: "",
                    html: '<div class="kill-marker">&times;</div>',
                    iconSize: [24, 24],
                    iconAnchor: [12, 12]
                }),
                interactive: false
            }).addTo(killLayer);
            /* Fade out after 30 seconds */
            (function (km) {
                setTimeout(function () {
                    killLayer.removeLayer(km);
                }, 30000);
            })(killMarker);
        }
    }
};

/* ---- Border zones ---- */

/* Convex hull (Andrew's monotone chain) for ADIZ smoothing */
MTD._convexHull = function (points) {
    if (points.length < 3) return points.slice();
    var pts = points.slice().sort(function (a, b) { return a[0] - b[0] || a[1] - b[1]; });
    var cross = function (O, A, B) { return (A[0] - O[0]) * (B[1] - O[1]) - (A[1] - O[1]) * (B[0] - O[0]); };
    var lower = [];
    for (var li = 0; li < pts.length; li++) {
        while (lower.length >= 2 && cross(lower[lower.length - 2], lower[lower.length - 1], pts[li]) <= 0) lower.pop();
        lower.push(pts[li]);
    }
    var upper = [];
    for (var ui = pts.length - 1; ui >= 0; ui--) {
        while (upper.length >= 2 && cross(upper[upper.length - 2], upper[upper.length - 1], pts[ui]) <= 0) upper.pop();
        upper.push(pts[ui]);
    }
    lower.pop();
    upper.pop();
    return lower.concat(upper);
};

/* Expand polygon outward by bufferDeg (approx degrees) and return convex hull */
MTD._expandAndHull = function (latlngs, bufferDeg) {
    if (latlngs.length < 3 || bufferDeg <= 0) return null;
    /* Compute centroid */
    var cLat = 0, cLon = 0;
    for (var ci = 0; ci < latlngs.length; ci++) { cLat += latlngs[ci][0]; cLon += latlngs[ci][1]; }
    cLat /= latlngs.length;
    cLon /= latlngs.length;
    /* Push each vertex outward from centroid by bufferDeg */
    var expanded = [];
    for (var ei = 0; ei < latlngs.length; ei++) {
        var dlat = latlngs[ei][0] - cLat;
        var dlon = latlngs[ei][1] - cLon;
        var dist = Math.sqrt(dlat * dlat + dlon * dlon);
        if (dist < 1e-9) { expanded.push([latlngs[ei][0] + bufferDeg, latlngs[ei][1]]); continue; }
        var scale = (dist + bufferDeg) / dist;
        expanded.push([cLat + dlat * scale, cLon + dlon * scale]);
    }
    return MTD._convexHull(expanded);
};

MTD.renderBorderZones = function (data) {
    var zoneLayer = MTD.zoneLayer;
    var showZones = MTD.opt("opt-border-zones");
    var zoneResult = data.zoneResult || [];
    var postureResult = data.postureResult || [];

    if (!showZones) {
        zoneLayer.clearLayers();
        MTD.prevZoneVertices = "";
        return;
    }

    /* Build posture + ADIZ config lookup by network */
    var postureByNet = {};
    var adizByNet = {};
    for (var pi = 0; pi < postureResult.length; pi++) {
        var pm = postureResult[pi].metric;
        postureByNet[pm.network] = pm.posture || "HOT_WAR";
        adizByNet[pm.network] = {
            enabled: pm.adiz_enabled === "true",
            nm: parseFloat(pm.adiz_nm) || 12
        };
    }

    /* Build fingerprint to detect changes */
    var fingerprint = "";
    for (var zi = 0; zi < zoneResult.length; zi++) {
        var zm = zoneResult[zi].metric;
        fingerprint += (zm.network || "") + ":" + (zm.zone_idx || "") + ":" + (zm.vertices || "") + ";";
    }
    for (var pk in postureByNet) {
        var ac = adizByNet[pk] || {};
        fingerprint += pk + "=" + postureByNet[pk] + ":" + (ac.enabled ? "1" : "0") + ":" + (ac.nm || 0) + ";";
    }

    if (fingerprint === MTD.prevZoneVertices) return;
    MTD.prevZoneVertices = fingerprint;
    zoneLayer.clearLayers();

    var ZONE_STYLES = {
        HOT_WAR:  { color: "#e05555", fillOpacity: 0.04, borderOpacity: 0.5 },
        WARM_WAR: { color: "#c8a030", fillOpacity: 0.04, borderOpacity: 0.45 },
        COLD_WAR: { color: "#5588aa", fillOpacity: 0.04, borderOpacity: 0.4 }
    };

    /* Collect all latlngs per network for ADIZ computation */
    var zonesByNet = {};

    for (var i = 0; i < zoneResult.length; i++) {
        var metric = zoneResult[i].metric;
        var verticesStr = metric.vertices || "";
        var network = metric.network || "";
        var posture = postureByNet[network] || "HOT_WAR";

        if (!verticesStr) continue;

        var pairs = verticesStr.split(";");
        var latlngs = [];
        for (var vi = 0; vi < pairs.length; vi++) {
            var parts = pairs[vi].split(",");
            if (parts.length >= 2) {
                var lat = parseFloat(parts[0]);
                var lon = parseFloat(parts[1]);
                if (!isNaN(lat) && !isNaN(lon)) {
                    latlngs.push([lat, lon]);
                }
            }
        }

        if (latlngs.length < 3) continue;

        var style = ZONE_STYLES[posture] || ZONE_STYLES.HOT_WAR;

        /* Border zone polygon */
        L.polygon(latlngs, {
            color: style.color,
            weight: 1.5,
            opacity: style.borderOpacity,
            dashArray: "8 4",
            fillColor: style.color,
            fillOpacity: style.fillOpacity,
            interactive: false
        }).bindTooltip(network + " (" + posture + ")").addTo(zoneLayer);

        /* Collect for ADIZ */
        if (!zonesByNet[network]) zonesByNet[network] = [];
        for (var ai = 0; ai < latlngs.length; ai++) {
            zonesByNet[network].push(latlngs[ai]);
        }
    }

    /* ADIZ projection per network */
    for (var net in zonesByNet) {
        var adizCfg = adizByNet[net];
        if (!adizCfg || !adizCfg.enabled || adizCfg.nm <= 0) continue;

        var allPts = zonesByNet[net];
        if (allPts.length < 3) continue;

        var posStyle = ZONE_STYLES[postureByNet[net]] || ZONE_STYLES.HOT_WAR;
        /* Convert nm to approximate degrees (1nm ~ 1/60 degree latitude) */
        var bufferDeg = adizCfg.nm / 60.0;

        var adizHull = MTD._expandAndHull(allPts, bufferDeg);
        if (adizHull && adizHull.length >= 3) {
            L.polygon(adizHull, {
                color: posStyle.color,
                weight: 1,
                opacity: posStyle.borderOpacity * 0.6,
                dashArray: "4 6",
                fill: false,
                interactive: false
            }).bindTooltip(net + " ADIZ (" + adizCfg.nm + "nm)").addTo(zoneLayer);
        }
    }
};

/* ---- Sensors (EWR, GCI, AWACS) ---- */

var _SENSOR_COLOR = "#4fc3f7";
var _SENSOR_DIM   = "#4fc3f766";

function _ewrIcon(color) {
    return L.divIcon({
        className: "",
        html: '<svg width="16" height="16" viewBox="0 0 16 16">' +
              '<polygon points="8,1 14.5,4.5 14.5,11.5 8,15 1.5,11.5 1.5,4.5" fill="' + color + '" fill-opacity="0.3" stroke="' + color + '" stroke-width="1.2"/>' +
              '</svg>',
        iconSize: [16, 16],
        iconAnchor: [8, 8]
    });
}

function _awacsIcon(color) {
    return L.divIcon({
        className: "",
        html: '<div class="awacs-spin"><svg width="18" height="18" viewBox="0 0 18 18">' +
              '<circle cx="9" cy="9" r="7" fill="' + color + '" fill-opacity="0.2" stroke="' + color + '" stroke-width="1.5"/>' +
              '<line x1="3.5" y1="14.5" x2="14.5" y2="3.5" stroke="' + color + '" stroke-width="1.5"/>' +
              '</svg></div>',
        iconSize: [18, 18],
        iconAnchor: [9, 9]
    });
}

MTD.renderSensors = function (data) {
    var sensorLayer   = MTD.sensorLayer;
    var sensorMarkers = MTD.sensorMarkers;
    var sensorRings   = MTD.sensorRings;
    var showSensors   = MTD.opt("opt-sensors");
    var sensorLatMap  = data.sensorLatMap || {};
    var sensorLonMap  = data.sensorLonMap || {};
    var sensorInfoMap = data.sensorInfoMap || {};
    var sensorRangeMap = data.sensorRangeMap || {};

    if (!showSensors) {
        sensorLayer.clearLayers();
        MTD.sensorMarkers = {};
        MTD.sensorRings = {};
        return;
    }

    var currentSensorSet = {};
    var sensorNames = Object.keys(sensorLatMap);

    for (var si = 0; si < sensorNames.length; si++) {
        var sName = sensorNames[si];
        if (sensorLonMap[sName] === undefined) continue;

        var sPos = [sensorLatMap[sName], sensorLonMap[sName]];
        var info = sensorInfoMap[sName] || {};
        var sType = info.type || "EWR";
        var airborne = info.airborne === "true";
        var status = info.status || "ACTIVE";
        var radar = info.radar || "DARK";
        var isInop = status === "INOPERATIVE";
        var isEmitting = radar === "ACTIVE";
        var color = isInop ? _SENSOR_DIM : isEmitting ? "#4caf50" : _SENSOR_COLOR;

        currentSensorSet[sName] = true;

        var tooltip = sName + "\n" + sType;
        if (airborne) tooltip += "\nAirborne";
        if (isInop) tooltip += "\nINOPERATIVE";

        var icon = sType === "AWACS" ? _awacsIcon(color) : _ewrIcon(color);

        var existing = sensorMarkers[sName];
        if (existing) {
            existing.setLatLng(sPos);
            if (existing._lastColor !== color) {
                existing.setIcon(icon);
                existing._lastColor = color;
            }
            var sTooltipHtml = tooltip.replace(/\n/g, "<br>");
            if (existing._lastTooltip !== sTooltipHtml) {
                existing.unbindTooltip();
                existing.bindTooltip(sTooltipHtml);
                existing._lastTooltip = sTooltipHtml;
            }
        } else {
            var marker = L.marker(sPos, { icon: icon })
                .bindTooltip(tooltip.replace(/\n/g, "<br>"))
                .addTo(sensorLayer);
            marker._lastColor = color;
            sensorMarkers[sName] = marker;
        }

        /* Detection range ring */
        var rangeM = sensorRangeMap[sName];
        var existingRing = sensorRings[sName];
        if (rangeM && rangeM > 0) {
            if (existingRing) {
                existingRing.setLatLng(sPos);
                existingRing.setRadius(rangeM);
            } else {
                var ring = L.circle(sPos, {
                    radius: rangeM,
                    color: "#ffffff",
                    weight: 1,
                    opacity: 0.3,
                    dashArray: "6 4",
                    fill: false,
                    interactive: false
                }).addTo(sensorLayer);
                sensorRings[sName] = ring;

                /* Hover highlight on sensor marker */
                (function (r) {
                    var m = sensorMarkers[sName];
                    if (m) {
                        m.on("mouseover", function () { r.setStyle({ weight: 2, opacity: 0.7 }); });
                        m.on("mouseout",  function () { r.setStyle({ weight: 1, opacity: 0.3 }); });
                    }
                })(ring);
            }
        } else if (existingRing) {
            sensorLayer.removeLayer(existingRing);
            delete sensorRings[sName];
        }
    }

    /* Remove sensors that are gone */
    var existingSensorNames = Object.keys(sensorMarkers);
    for (var rsi = 0; rsi < existingSensorNames.length; rsi++) {
        var rsName = existingSensorNames[rsi];
        if (!currentSensorSet[rsName]) {
            sensorLayer.removeLayer(sensorMarkers[rsName]);
            delete sensorMarkers[rsName];
        }
    }

    /* Remove stale rings */
    var existingRingNames = Object.keys(sensorRings);
    for (var rri = 0; rri < existingRingNames.length; rri++) {
        var rrName = existingRingNames[rri];
        if (!currentSensorSet[rrName]) {
            sensorLayer.removeLayer(sensorRings[rrName]);
            delete sensorRings[rrName];
        }
    }
};

/* ---- AWACS trails (altitude-colored) ---- */

MTD.renderSensorTrails = async function (data) {
    var trailLayer    = MTD.trailLayer;
    var sensorLatMap  = data.sensorLatMap || {};
    var sensorLonMap  = data.sensorLonMap || {};
    var sensorInfoMap = data.sensorInfoMap || {};
    var showSensors   = MTD.opt("opt-sensors");

    if (!showSensors) return;

    /* Only proceed if there are airborne sensors */
    var airborneNames = [];
    var allSensorNames = Object.keys(sensorLatMap);
    for (var ani = 0; ani < allSensorNames.length; ani++) {
        var asn = allSensorNames[ani];
        var asInfo = sensorInfoMap[asn] || {};
        if (asInfo.airborne === "true") {
            airborneNames.push(asn);
        }
    }
    if (airborneNames.length === 0) return;

    try {
        var now = Math.floor(Date.now() / 1000);
        var lookback = (data.missionTime > 0) ? Math.min(300, data.missionTime) : 300;
        var startTime = now - lookback;
        var trailResults = await Promise.all([
            MTD.queryRange(MTD.netExpr("medusa_sensor_lat"), startTime, now, 15),
            MTD.queryRange(MTD.netExpr("medusa_sensor_lon"), startTime, now, 15),
            MTD.queryRange(MTD.netExpr("medusa_sensor_pos_y"), startTime, now, 15)
        ]);

        var trailLat = {};
        var trailLon = {};
        var trailAlt = {};

        for (var tl = 0; tl < trailResults[0].length; tl++) {
            trailLat[trailResults[0][tl].metric.sensor] = trailResults[0][tl].values;
        }
        for (var tln = 0; tln < trailResults[1].length; tln++) {
            trailLon[trailResults[1][tln].metric.sensor] = trailResults[1][tln].values;
        }
        for (var ta = 0; ta < trailResults[2].length; ta++) {
            trailAlt[trailResults[2][ta].metric.sensor] = trailResults[2][ta].values;
        }

        for (var sti = 0; sti < airborneNames.length; sti++) {
            var sName = airborneNames[sti];
            if (!trailLat[sName] || !trailLon[sName]) continue;

            var latVals = trailLat[sName];
            var lonVals = trailLon[sName];

            /* Build timestamp-indexed lon and alt maps */
            var lonByTime = {};
            for (var li = 0; li < lonVals.length; li++) {
                lonByTime[lonVals[li][0]] = parseFloat(lonVals[li][1]);
            }
            var altByTime = {};
            if (trailAlt[sName]) {
                for (var ai = 0; ai < trailAlt[sName].length; ai++) {
                    altByTime[trailAlt[sName][ai][0]] = parseFloat(trailAlt[sName][ai][1]);
                }
            }

            /* Assemble ordered trail points */
            var trailPoints = [];
            var trailAlts = [];
            for (var xi = 0; xi < latVals.length; xi++) {
                var ts   = latVals[xi][0];
                var latv = parseFloat(latVals[xi][1]);
                if (lonByTime[ts] !== undefined) {
                    trailPoints.push([latv, lonByTime[ts]]);
                    trailAlts.push(altByTime[ts] || 0);
                }
            }

            /* Draw segments colored by altitude (same as track trails) */
            for (var seg = 0; seg < trailPoints.length - 1; seg++) {
                var segDist = MTD.haversineM(
                    trailPoints[seg][0], trailPoints[seg][1],
                    trailPoints[seg + 1][0], trailPoints[seg + 1][1]
                );
                if (segDist > 50000) continue;
                L.polyline([trailPoints[seg], trailPoints[seg + 1]], {
                    color: MTD.altitudeColor(trailAlts[seg]),
                    weight: 2.5,
                    opacity: 0.7
                }).addTo(trailLayer);
            }

            /* Connect trail to current instant position */
            var curLat = sensorLatMap[sName];
            var curLon = sensorLonMap[sName];
            if (curLat !== undefined && curLon !== undefined && trailPoints.length >= 1) {
                var lastTrail = trailPoints[trailPoints.length - 1];
                var curPos = [curLat, curLon];
                var bridgeDist = MTD.haversineM(lastTrail[0], lastTrail[1], curPos[0], curPos[1]);
                if (bridgeDist < 50000) {
                    L.polyline([lastTrail, curPos], {
                        color: MTD.altitudeColor(trailAlts[trailAlts.length - 1] || 0),
                        weight: 2.5,
                        opacity: 0.7
                    }).addTo(trailLayer);
                }
            }
        }
    } catch (trailErr) {
        /* Sensor trail fetch failed -- non-critical */
    }
};
