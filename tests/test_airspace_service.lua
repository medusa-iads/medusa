local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Logger")
require("services.Services")
require("services.AirspaceService")
require("services.SpatialQuery")

TestAirspaceHarnessGeometry = {}

function TestAirspaceHarnessGeometry:setUp()
	self.originalMission = env.mission
	env.mission = {
		triggers = {
			zones = {
				{
					name = "border",
					type = 2,
					verticies = {
						{ x = 0, y = 0 },
						{ x = 1000, y = 0 },
						{ x = 1000, y = 1000 },
						{ x = 0, y = 1000 },
					},
				},
			},
		},
	}
end

function TestAirspaceHarnessGeometry:tearDown()
	env.mission = self.originalMission
end

function TestAirspaceHarnessGeometry:test_discoveredAndExpandedPolygons_useGroundVec3()
	local polygons = Medusa.Services.AirspaceService.discover({ "border" })

	lu.assertEquals(#polygons, 1)
	for i = 1, #polygons[1] do
		lu.assertEquals(polygons[1][i].y, 0)
	end
	lu.assertTrue(Medusa.Services.SpatialQuery.pointInBorderZones(polygons, { x = 500, y = 5000, z = 500 }))

	local adiz = Medusa.Services.AirspaceService.computeADIZ(polygons, 1)

	lu.assertNotNil(adiz)
	lu.assertTrue(#adiz >= 3)
	for i = 1, #adiz do
		lu.assertEquals(adiz[i].y, 0)
	end
end
