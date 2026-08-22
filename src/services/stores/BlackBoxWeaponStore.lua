require("_header")
require("services.Services")

Medusa.Services.BlackBoxWeaponStore = {}

do
	local Store = Medusa.Services.BlackBoxWeaponStore

	function Store:new(capacity)
		if type(capacity) ~= "number" or capacity < 1 then
			error("BlackBoxWeaponStore capacity must be positive")
		end
		local o = {
			_capacity = math.floor(capacity),
			_tracks = RingBuffer(math.floor(capacity), false),
			_byWeapon = {},
			_nextImpactId = 0,
			_nextUpdateAt = nil,
			_eventBus = nil,
			_shotSubscriptionId = nil,
			_hitSubscriptionId = nil,
			_shotSink = nil,
			_hitSink = nil,
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
		return self._tracks:size() >= self._capacity
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

	function Store:beginUpdate(now, intervalSec)
		if self._nextUpdateAt and now < self._nextUpdateAt then
			return false
		end
		self._nextUpdateAt = now + intervalSec
		return true
	end

	function Store:clear()
		self._tracks:clear()
		self._byWeapon = {}
		self._nextUpdateAt = nil
	end

	function Store:nextImpactId()
		self._nextImpactId = self._nextImpactId + 1
		return self._nextImpactId
	end

	function Store:isStarted()
		return self._shotSubscriptionId ~= nil or self._hitSubscriptionId ~= nil
	end

	function Store:setSubscriptions(bus, shotId, hitId, shotSink, hitSink)
		self._eventBus = bus
		self._shotSubscriptionId = shotId
		self._hitSubscriptionId = hitId
		self._shotSink = shotSink
		self._hitSink = hitSink
	end

	function Store:clearSubscriptions()
		local bus = self._eventBus
		local shotId = self._shotSubscriptionId
		local hitId = self._hitSubscriptionId
		self._eventBus = nil
		self._shotSubscriptionId = nil
		self._hitSubscriptionId = nil
		self._shotSink = nil
		self._hitSink = nil
		return bus, shotId, hitId
	end
end
