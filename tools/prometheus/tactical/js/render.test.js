"use strict";

var assert = require("node:assert/strict");

global.window = { MTD: {} };
global.MTD = global.window.MTD;
require("./render.js");

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
