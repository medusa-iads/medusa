/* icons.js -- SVG icon factories for Medusa Tactical Display */
"use strict";

window.MTD = window.MTD || {};

/* ---- Track icon factory ---- */

MTD.trackIconForId = function (identification, headingDeg, isHarm) {
    var svg;
    if (isHarm) {
        svg = '<polygon points="7,1 13,7 7,13 1,7" fill="#ff00ff" stroke="#aa00aa" stroke-width="1.5"/>';
    } else if (identification === "HOSTILE") {
        svg = '<polygon points="7,1 13,13 1,13" fill="#e53935" stroke="#b71c1c" stroke-width="1"/>';
    } else if (identification === "BANDIT") {
        svg = '<polygon points="7,1 13,13 1,13" fill="none" stroke="#e53935" stroke-width="1.5"/>';
    } else {
        svg = '<polygon points="7,1 13,13 1,13" fill="none" stroke="#ffffff" stroke-width="1.5"/>';
    }
    var rot = headingDeg || 0;
    return L.divIcon({
        className: "",
        html: '<svg width="14" height="14" viewBox="0 0 14 14" style="transform:rotate(' + rot + 'deg)">' + svg + '</svg>',
        iconSize: [14, 14],
        iconAnchor: [7, 7]
    });
};
