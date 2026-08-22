require("_header")
require("services.Services")
require("core.Constants")

Medusa.Services.BlackBoxWeaponStore = {}

do
	local Store = Medusa.Services.BlackBoxWeaponStore

	function Store:new(capacity, cannonCapacity)
		if type(capacity) ~= "number" or capacity < 1 then
			error("BlackBoxWeaponStore capacity must be positive")
		end
		cannonCapacity = cannonCapacity or Medusa.Constants.CrewSuppression.CANNON_CANDIDATE_CAPACITY
		if type(cannonCapacity) ~= "number" or cannonCapacity < 1 then
			error("BlackBoxWeaponStore cannon capacity must be positive")
		end
		local o = {
			_tracks = RingBuffer(math.floor(capacity), false),
			_byWeapon = {},
			_cannonCandidates = RingBuffer(math.floor(cannonCapacity), false),
			_nextTerminalEventId = 0,
			_nextUpdateAt = nil,
			_eventBus = nil,
			_shotSubscriptionId = nil,
			_hitSubscriptionId = nil,
			_shootingStartSubscriptionId = nil,
		}
		setmetatable(o, { __index = self })
		return o
	end

	function Store:admit(weapon, observedAt)
		if weapon == nil or type(observedAt) ~= "number" then
			return false
		end
		if self._byWeapon[weapon] then
			return false
		end
		local record = {
			Weapon = weapon,
			ObservedAt = observedAt,
		}
		local accepted = self._tracks:push(record)
		if not accepted then
			return false
		end
		self._byWeapon[weapon] = record
		return true
	end

	function Store:get(weapon)
		return self._byWeapon[weapon]
	end

	function Store:isFull()
		return self._tracks:isFull()
	end

	function Store:markHit(weapon, position, observedAt)
		local record = self._byWeapon[weapon]
		if not record then
			return false
		end
		record.HitPosition = { x = position.x, y = position.y, z = position.z }
		record.HitObservedAt = observedAt
		return true
	end

	function Store:pop()
		return self._tracks:pop()
	end

	function Store:requeue(record)
		return self._tracks:push(record)
	end

	function Store:discard(record)
		if not record then
			return false
		end
		if self._byWeapon[record.Weapon] == record then
			self._byWeapon[record.Weapon] = nil
		end
		record.Weapon = nil
		return true
	end

	function Store:size()
		return self._tracks:size()
	end

	function Store:admitCannon(initiator, observedAt)
		return self._cannonCandidates:push({
			Initiator = initiator,
			ObservedAt = observedAt,
		})
	end

	function Store:popCannon()
		return self._cannonCandidates:pop()
	end

	function Store:cannonSize()
		return self._cannonCandidates:size()
	end

	function Store:beginUpdate(now, intervalSec)
		if self._nextUpdateAt and now < self._nextUpdateAt then
			return false
		end
		self._nextUpdateAt = now + intervalSec
		return true
	end

	function Store:clear()
		self._tracks:clear()
		self._cannonCandidates:clear()
		self._byWeapon = {}
		self._nextUpdateAt = nil
	end

	function Store:nextTerminalEventId()
		self._nextTerminalEventId = self._nextTerminalEventId + 1
		return self._nextTerminalEventId
	end

	function Store:isStarted()
		return self._eventBus ~= nil
	end

	function Store:setSubscriptions(bus, shotId, hitId, shootingStartId)
		self._eventBus = bus
		self._shotSubscriptionId = shotId
		self._hitSubscriptionId = hitId
		self._shootingStartSubscriptionId = shootingStartId
	end

	function Store:clearSubscriptions()
		local bus = self._eventBus
		local shotId = self._shotSubscriptionId
		local hitId = self._hitSubscriptionId
		local shootingStartId = self._shootingStartSubscriptionId
		self._eventBus = nil
		self._shotSubscriptionId = nil
		self._hitSubscriptionId = nil
		self._shootingStartSubscriptionId = nil
		return bus, shotId, hitId, shootingStartId
	end
end
