"use strict";

var assert = require("node:assert/strict");

global.window = { MTD: {} };
global.MTD = global.window.MTD;
require("./render.js");

assert.equal(window.MTD.trackDisplayId("01HXYZ", { display_track: "AW0001" }), "AW0001");
assert.equal(window.MTD.trackDisplayId("01HXYZ", {}), "UNSET");
assert.equal(window.MTD.trackLabelText("01HXYZ", { display_track: "AW0001", unit: "Bandit 1" }), "AW0001 Bandit 1");

assert.equal(window.MTD.manpadMarkerColor("ALERT", "AUDIO", false), "#42a5f5");
assert.equal(window.MTD.manpadMarkerColor("HOT", "AUDIO", true), "#4caf50");
assert.equal(window.MTD.manpadMarkerColor("HOT", "AUDIO", false), "#ff7043");
assert.equal(window.MTD.manpadMarkerColor("ALERT", "IADS", false), "#ffbf47");
assert.equal(window.MTD.manpadMarkerColor("ASLEEP", "NONE", false), "#8a7f65");

assert.equal(
    window.MTD.manpadTooltip('<team & "one">', "HOT", "VISUAL", true, "red's network"),
    "&lt;team &amp; &quot;one&quot;&gt;<br>HOT<br>Wake: VISUAL<br>Can fire: YES<br>red&#39;s network"
);

assert.equal(window.MTD.isValidManpadGeometry(90, 8000, 30), true);
assert.equal(window.MTD.isValidManpadGeometry(undefined, 8000, 30), false);
assert.equal(window.MTD.isValidManpadGeometry(90, undefined, 30), false);
assert.equal(window.MTD.isValidManpadGeometry(90, 8000, NaN), false);
assert.equal(window.MTD.isValidManpadGeometry(90, Infinity, 30), false);

assert.equal(window.MTD.aaaMarkerColor("INDEPENDENT", "IDLE", "STATE_COLD"), "#6d7f8b");
assert.equal(window.MTD.aaaMarkerColor("INDEPENDENT", "ALERT", "STATE_COLD"), "#ffbf47");
assert.equal(window.MTD.aaaMarkerColor("INDEPENDENT", "AREA_FIRE", "STATE_HOT"), "#ff7043");
assert.equal(window.MTD.aaaMarkerColor("INDEPENDENT", "BARRAGE_FIRE", "STATE_HOT"), "#e53935");
assert.equal(window.MTD.aaaMarkerColor("INDEPENDENT", "BARRAGE_PAUSE", "STATE_HOT"), "#ab47bc");
assert.equal(window.MTD.aaaMarkerColor("INDEPENDENT", "LOCAL_ACQUISITION", "STATE_HOT"), "#4caf50");
assert.equal(window.MTD.aaaMarkerColor("RADAR_DIRECTED", "IDLE", "STATE_HOT"), "#4caf50");

assert.equal(
    window.MTD.aaaTooltip('<gun & "one">', "INDEPENDENT", "AREA_FIRE", "red's network"),
    "&lt;gun &amp; &quot;one&quot;&gt;<br>INDEPENDENT<br>AREA FIRE<br>red&#39;s network"
);

assert.equal(window.MTD.isValidAaaGeometry(0, 8000, 35), true);
assert.equal(window.MTD.isValidAaaGeometry(undefined, 8000, 35), false);
assert.equal(window.MTD.isValidAaaGeometry(0, NaN, 35), false);
assert.equal(window.MTD.isValidAaaGeometry(0, 8000, undefined), false);
