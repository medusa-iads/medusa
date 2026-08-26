local lu = require("luaunit")

local fixture = require("scenario_one_syria")

TestScenarioOneSyria = {}

function TestScenarioOneSyria:test_contains_every_ground_group_from_the_source_mission()
	lu.assertEquals(fixture.ScenarioId, "scenario_one_syria")
	lu.assertEquals(fixture.SourceMission, "medusa_integration_test_syria_load_test.miz")
	lu.assertEquals(fixture.SourceSha256, "62b7f54a6c83310e28e0162690d91ec208793227660ab5ebc1fa46514bbde04d")
	lu.assertEquals(#fixture.GroundGroups, 264)

	for i = 1, #fixture.GroundGroups do
		local group = fixture.GroundGroups[i]
		lu.assertEquals(fixture.ByName[group.GroupName], group)
		lu.assertNotNil(group.GroupId)
		lu.assertNotNil(group.GroupPosition)
		lu.assertTrue(#group.Units > 0)
	end
end

function TestScenarioOneSyria:test_exposes_the_606_zrp_litmus_groups_without_runtime_name_policy()
	lu.assertEquals(fixture.ProtectedSite.GroupName, "pvo.4d.606zrp.1bn")
	lu.assertEquals(fixture.NearbyPointDefense.GroupName, "pvo.4d.606zrp.2bn.1c")
	lu.assertEquals(fixture.FarPointDefense.GroupName, "pvo.4d.606zrp.2bn.2c")
end
