local lu = require("luaunit")

require("mocks.mock_dcs")
require("_header")
require("core.Constants")
require("services.stores.MissionUnitSkillIndex")

TestMissionUnitSkillIndex = {}

function TestMissionUnitSkillIndex:test_maps_named_ground_unit_skills_and_ignores_unusable_values()
	local mission = {
		coalition = {
			red = {
				country = {
					{
						vehicle = {
							group = {
								{
									units = {
										{ name = "average", skill = "Average" },
										{ name = "good", skill = "Good" },
										{ name = "high", skill = "High" },
										{ name = "excellent", skill = "Excellent" },
										{ name = "random", skill = "Random" },
										{ name = "unknown", skill = "ModSkill" },
									},
								},
							},
						},
					},
				},
			},
		},
	}

	local index = Medusa.Services.MissionUnitSkillIndex.new(mission)

	lu.assertEquals(index:get("average"), Medusa.Constants.CrewSkill.AVERAGE)
	lu.assertEquals(index:get("good"), Medusa.Constants.CrewSkill.GOOD)
	lu.assertEquals(index:get("high"), Medusa.Constants.CrewSkill.HIGH)
	lu.assertEquals(index:get("excellent"), Medusa.Constants.CrewSkill.EXCELLENT)
	lu.assertNil(index:get("random"))
	lu.assertNil(index:get("unknown"))
	lu.assertNil(index:get("dynamic-unit"))
end
