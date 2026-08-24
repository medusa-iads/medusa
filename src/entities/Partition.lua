require("_header")
require("entities.Entities")

Medusa.Entities.Partition = {}

--- Creates the partition identity and sustainment record published for the component described by data.
function Medusa.Entities.Partition.new(data)
	if not data or data.Key == nil then
		error("missing required field: Key")
	end
	if type(data.ClusterKeys) ~= "table" then
		error("missing required field: ClusterKeys")
	end
	return {
		Key = data.Key,
		ClusterKeys = data.ClusterKeys,
		Sustained = data.Sustained == true,
	}
end
