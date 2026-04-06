-- harness: 0.7.0 loading...
-- ==== BEGIN: src/_header.lua ====
-- Version
HARNESS_VERSION = "0.7.0"
-- Internal namespace for logger
_HarnessInternal = _HarnessInternal or {}

-- ==== END: src/_header.lua ====

-- ==== BEGIN: src/datastructures.lua ====
--[[
==================================================================================================
    DATA STRUCTURES MODULE
    Common data structures optimized for DCS World scripting
    
    Structures Provided:
    - Queue
    - Stack
    - Cache
    - Heap/PriorityQueue
    - Set
    - Memoize
==================================================================================================
]]

-- Queue Implementation (FIFO - First In First Out)
--- Create a new Queue
---@return table queue New queue instance
---@usage local q = Queue()
function Queue()
    local queue = {
        _items = {},
        _first = 1,
        _last = 0,
    }

    --- Add item to back of queue
    ---@param item any Item to enqueue
    ---@usage queue:enqueue("item")
    function queue:enqueue(item)
        self._last = self._last + 1
        self._items[self._last] = item
    end

    --- Remove and return item from front of queue
    ---@return any? item Dequeued item or nil if empty
    ---@usage local item = queue:dequeue()
    function queue:dequeue()
        if self:isEmpty() then
            return nil
        end

        local item = self._items[self._first]
        self._items[self._first] = nil
        self._first = self._first + 1

        -- Reset indices when queue is empty to prevent index growth
        if self._first > self._last then
            self._first = 1
            self._last = 0
        end

        return item
    end

    --- Peek at front item without removing
    ---@return any? item Front item or nil if empty
    ---@usage local front = queue:peek()
    function queue:peek()
        if self:isEmpty() then
            return nil
        end
        return self._items[self._first]
    end

    --- Check if queue is empty
    ---@return boolean empty True if queue is empty
    ---@usage if queue:isEmpty() then ... end
    function queue:isEmpty()
        return self._first > self._last
    end

    --- Get number of items in queue
    ---@return number size Number of items
    ---@usage local size = queue:size()
    function queue:size()
        if self:isEmpty() then
            return 0
        end
        return self._last - self._first + 1
    end

    --- Clear all items from queue
    ---@usage queue:clear()
    function queue:clear()
        self._items = {}
        self._first = 1
        self._last = 0
    end

    return queue
end

-- Stack Implementation (LIFO - Last In First Out)
--- Create a new Stack
---@return table stack New stack instance
---@usage local s = Stack()
function Stack()
    local stack = {
        _items = {},
        _top = 0,
    }

    --- Push item onto stack
    ---@param item any Item to push
    ---@usage stack:push("item")
    function stack:push(item)
        self._top = self._top + 1
        self._items[self._top] = item
    end

    --- Pop and return top item from stack
    ---@return any? item Popped item or nil if empty
    ---@usage local item = stack:pop()
    function stack:pop()
        if self:isEmpty() then
            return nil
        end

        local item = self._items[self._top]
        self._items[self._top] = nil
        self._top = self._top - 1
        return item
    end

    --- Peek at top item without removing
    ---@return any? item Top item or nil if empty
    ---@usage local top = stack:peek()
    function stack:peek()
        if self:isEmpty() then
            return nil
        end
        return self._items[self._top]
    end

    --- Check if stack is empty
    ---@return boolean empty True if stack is empty
    ---@usage if stack:isEmpty() then ... end
    function stack:isEmpty()
        return self._top == 0
    end

    --- Get number of items in stack
    ---@return number size Number of items
    ---@usage local size = stack:size()
    function stack:size()
        return self._top
    end

    --- Clear all items from stack
    ---@usage stack:clear()
    function stack:clear()
        self._items = {}
        self._top = 0
    end

    return stack
end

-- Advanced Cache Implementation (Redis-like KV Store)
--- Create a new advanced Cache with Redis-like features
---@param capacity number? Maximum number of items to cache (default: unlimited)
---@return table cache New cache instance
---@usage local cache = Cache()
function Cache(capacity)
    -- Validate capacity
    if capacity ~= nil and type(capacity) ~= "number" then
        _HarnessInternal.log.error("Cache capacity must be a number", "DataStructures.Cache")
        capacity = nil
    end
    if capacity and capacity < 1 then
        _HarnessInternal.log.error("Cache capacity must be positive", "DataStructures.Cache")
        capacity = nil
    end

    local cache = {
        _capacity = capacity or math.huge,
        _items = {},
        _order = {},
        _size = 0,
        _ttls = {}, -- TTL expiration times
        _types = {}, -- Track data types
    }

    -- Internal: Check and remove expired items
    local function checkExpired(key)
        local ttl = cache._ttls[key]
        if ttl and timer and timer.getTime and timer.getTime() > ttl then
            cache:del(key)
            return true
        end
        return false
    end

    -- Internal: Get current time (DCS compatible)
    local function getCurrentTime()
        if timer and timer.getTime then
            return timer.getTime()
        end
        return os.time()
    end

    --- Get value from cache
    ---@param key string Cache key
    ---@return any? value Cached value or nil
    ---@usage local value = cache:get("key")
    function cache:get(key)
        if checkExpired(key) then
            return nil
        end

        local item = self._items[key]
        if not item then
            return nil
        end

        -- Move to front (most recently used) if capacity is limited
        if self._capacity ~= math.huge then
            self:_moveToFront(key)
        end

        return item.value
    end

    --- Set key-value pair with optional TTL
    ---@param key string Cache key
    ---@param value any Value to cache
    ---@param ttl number? Time to live in seconds
    ---@return boolean success Always returns true
    ---@usage cache:set("key", "value", 60) -- expires in 60 seconds
    function cache:set(key, value, ttl)
        local isNew = self._items[key] == nil

        if isNew and self._size >= self._capacity then
            -- Remove least recently used
            self:_removeLRU()
        end

        self._items[key] = { value = value }
        self._types[key] = type(value)

        if ttl and ttl > 0 then
            self._ttls[key] = getCurrentTime() + ttl
        else
            self._ttls[key] = nil
        end

        if self._capacity ~= math.huge then
            if isNew then
                table.insert(self._order, 1, key)
                self._size = self._size + 1
            else
                self:_moveToFront(key)
            end
        elseif isNew then
            self._size = self._size + 1
        end

        return true
    end

    --- Set key only if it doesn't exist
    ---@param key string Cache key
    ---@param value any Value to cache
    ---@param ttl number? Time to live in seconds
    ---@return boolean success True if set, false if key exists
    ---@usage cache:setnx("key", "value")
    function cache:setnx(key, value, ttl)
        if self:exists(key) then
            return false
        end
        return self:set(key, value, ttl)
    end

    --- Set with expiration time
    ---@param key string Cache key
    ---@param seconds number TTL in seconds
    ---@param value any Value to cache
    ---@return boolean success Always returns true
    ---@usage cache:setex("key", 60, "value")
    function cache:setex(key, seconds, value)
        return self:set(key, value, seconds)
    end

    --- Delete key(s)
    ---@param ... string Keys to delete
    ---@return number count Number of keys deleted
    ---@usage cache:del("key1", "key2")
    function cache:del(...)
        local count = 0
        for i = 1, select("#", ...) do
            local key = select(i, ...)
            if self._items[key] then
                self._items[key] = nil
                self._types[key] = nil
                self._ttls[key] = nil
                if self._capacity ~= math.huge then
                    self:_removeFromOrder(key)
                end
                self._size = self._size - 1
                count = count + 1
            end
        end
        return count
    end

    --- Check if key exists
    ---@param key string Cache key
    ---@return boolean exists True if key exists and not expired
    ---@usage if cache:exists("key") then ... end
    function cache:exists(key)
        if checkExpired(key) then
            return false
        end
        return self._items[key] ~= nil
    end

    --- Set expiration time
    ---@param key string Cache key
    ---@param seconds number TTL in seconds
    ---@return boolean success True if expiration was set
    ---@usage cache:expire("key", 60)
    function cache:expire(key, seconds)
        if not self:exists(key) then
            return false
        end
        self._ttls[key] = getCurrentTime() + seconds
        return true
    end

    --- Get remaining TTL
    ---@param key string Cache key
    ---@return number ttl Seconds until expiration, -1 if no TTL, -2 if not exists
    ---@usage local ttl = cache:ttl("key")
    function cache:ttl(key)
        if not self._items[key] then
            return -2
        end

        local ttl = self._ttls[key]
        if not ttl then
            return -1
        end

        local remaining = ttl - getCurrentTime()
        if remaining <= 0 then
            self:del(key)
            return -2
        end

        return math.floor(remaining)
    end

    --- Remove expiration
    ---@param key string Cache key
    ---@return boolean success True if expiration was removed
    ---@usage cache:persist("key")
    function cache:persist(key)
        if not self:exists(key) then
            return false
        end
        self._ttls[key] = nil
        return true
    end

    --- Increment numeric value
    ---@param key string Cache key
    ---@param increment number? Amount to increment (default: 1)
    ---@return number? value New value or nil if not numeric
    ---@usage local newVal = cache:incr("counter")
    function cache:incr(key, increment)
        increment = increment or 1
        local value = self:get(key) or 0

        if type(value) ~= "number" then
            _HarnessInternal.log.error("INCR requires numeric value", "DataStructures.Cache")
            return nil
        end

        local newValue = value + increment
        self:set(key, newValue)
        return newValue
    end

    --- Decrement numeric value
    ---@param key string Cache key
    ---@param decrement number? Amount to decrement (default: 1)
    ---@return number? value New value or nil if not numeric
    ---@usage local newVal = cache:decr("counter")
    function cache:decr(key, decrement)
        return self:incr(key, -(decrement or 1))
    end

    --- Get all keys matching pattern
    ---@param pattern string? Lua pattern (default: ".*" for all)
    ---@return table keys Array of matching keys
    ---@usage local keys = cache:keys("user:*")
    function cache:keys(pattern)
        pattern = pattern or ".*"
        local keys = {}

        for key, _ in pairs(self._items) do
            if not checkExpired(key) and string.match(key, pattern) then
                table.insert(keys, key)
            end
        end

        return keys
    end

    --- Get data type of key
    ---@param key string Cache key
    ---@return string type Type of value ("string", "number", "table", etc) or "none"
    ---@usage local type = cache:type("key")
    function cache:type(key)
        if not self:exists(key) then
            return "none"
        end
        return self._types[key] or type(self._items[key].value)
    end

    --- Clear all items (flush database)
    ---@usage cache:flushdb()
    function cache:flushdb()
        self._items = {}
        self._order = {}
        self._size = 0
        self._ttls = {}
        self._types = {}
    end

    --- Get current cache size
    ---@return number size Number of cached items
    ---@usage local size = cache:dbsize()
    function cache:dbsize()
        -- Clean up expired items first
        for key, _ in pairs(self._ttls) do
            checkExpired(key)
        end
        return self._size
    end

    -- Internal: Move key to front of order list (for LRU)
    function cache:_moveToFront(key)
        self:_removeFromOrder(key)
        table.insert(self._order, 1, key)
    end

    -- Internal: Remove key from order list
    function cache:_removeFromOrder(key)
        for i, k in ipairs(self._order) do
            if k == key then
                table.remove(self._order, i)
                break
            end
        end
    end

    -- Internal: Remove least recently used item
    function cache:_removeLRU()
        local lru = table.remove(self._order)
        if lru then
            self:del(lru)
        end
    end

    return cache
end

-- Memoize Decorator (LRU Cache for Functions)
--- Create a memoized version of a function with LRU cache
---@param func function The function to memoize
---@param capacity number? Maximum number of cached results (default: 128)
---@param keyGenerator function? Custom key generator function(...) -> string (default: concatenate args)
---@return function memoized Memoized version of the function
---@usage local memoizedSin = Memoize(math.sin, 100)
function Memoize(func, capacity, keyGenerator)
    if type(func) ~= "function" then
        _HarnessInternal.log.error("Memoize requires a function", "DataStructures.Memoize")
        return func
    end

    capacity = capacity or 128

    -- Default key generator: convert args to string and concatenate
    keyGenerator = keyGenerator
        or function(...)
            local args = { ... }
            local key = ""
            for i = 1, select("#", ...) do
                if i > 1 then
                    key = key .. "|"
                end
                local arg = args[i]
                local argType = type(arg)
                if argType == "nil" then
                    key = key .. "nil"
                elseif argType == "boolean" then
                    key = key .. tostring(arg)
                elseif argType == "number" or argType == "string" then
                    key = key .. arg
                elseif argType == "table" then
                    -- Simple table serialization (not recursive)
                    key = key .. "table:" .. tostring(arg)
                else
                    key = key .. argType .. ":" .. tostring(arg)
                end
            end
            return key
        end

    local cache = {
        _capacity = capacity,
        _items = {},
        _order = {},
        _size = 0,
    }

    -- Internal: Move key to front of order list
    local function moveToFront(key)
        for i, k in ipairs(cache._order) do
            if k == key then
                table.remove(cache._order, i)
                break
            end
        end
        table.insert(cache._order, 1, key)
    end

    -- Internal: Remove least recently used item
    local function removeLRU()
        local lru = table.remove(cache._order)
        if lru then
            cache._items[lru] = nil
            cache._size = cache._size - 1
        end
    end

    -- Memoized function
    return function(...)
        local key = keyGenerator(...)

        -- Check cache
        local cached = cache._items[key]
        if cached then
            moveToFront(key)
            return unpack(cached.results, 1, cached.n)
        end

        -- Call original function and capture all returns
        local function captureReturns(...)
            return select("#", ...), { ... }
        end

        local n, results = captureReturns(func(...))

        -- Store in cache
        if cache._size >= cache._capacity then
            removeLRU()
        end

        cache._items[key] = { results = results, n = n }
        table.insert(cache._order, 1, key)
        cache._size = cache._size + 1

        return unpack(results, 1, n)
    end
end

-- Min/Max Heap Implementation
--- Create a new Heap (binary heap)
---@param isMinHeap boolean? True for min heap, false for max heap (default: true)
---@param compareFunc function? Custom comparison function(a, b) returns true if a should be higher
---@return table heap New heap instance
---@usage local minHeap = Heap() or local maxHeap = Heap(false)
function Heap(isMinHeap, compareFunc)
    -- Validate parameters
    if isMinHeap ~= nil and type(isMinHeap) ~= "boolean" then
        _HarnessInternal.log.error("Heap isMinHeap must be boolean", "DataStructures.Heap")
        isMinHeap = true
    end
    if compareFunc ~= nil and type(compareFunc) ~= "function" then
        _HarnessInternal.log.error("Heap compareFunc must be a function", "DataStructures.Heap")
        compareFunc = nil
    end

    isMinHeap = isMinHeap ~= false -- Default to min heap

    local heap = {
        _items = {},
        _size = 0,
        _compare = compareFunc or function(a, b)
            if isMinHeap then
                return a < b
            else
                return a > b
            end
        end,
    }

    --- Insert item into heap
    ---@param item any Item to insert
    ---@usage heap:insert(5)
    function heap:insert(item)
        self._size = self._size + 1
        self._items[self._size] = item
        self:_bubbleUp(self._size)
    end

    --- Remove and return top item (min or max)
    ---@return any? item Top item or nil if empty
    ---@usage local top = heap:extract()
    function heap:extract()
        if self:isEmpty() then
            return nil
        end

        local top = self._items[1]
        self._items[1] = self._items[self._size]
        self._items[self._size] = nil
        self._size = self._size - 1

        if self._size > 0 then
            self:_bubbleDown(1)
        end

        return top
    end

    --- Peek at top item without removing
    ---@return any? item Top item or nil if empty
    ---@usage local top = heap:peek()
    function heap:peek()
        return self._items[1]
    end

    --- Check if heap is empty
    ---@return boolean empty True if heap is empty
    ---@usage if heap:isEmpty() then ... end
    function heap:isEmpty()
        return self._size == 0
    end

    --- Get number of items in heap
    ---@return number size Number of items
    ---@usage local size = heap:size()
    function heap:size()
        return self._size
    end

    --- Clear all items from heap
    ---@usage heap:clear()
    function heap:clear()
        self._items = {}
        self._size = 0
    end

    -- Internal: Bubble up to maintain heap property
    function heap:_bubbleUp(index)
        while index > 1 do
            local parent = math.floor(index / 2)
            if self._compare(self._items[index], self._items[parent]) then
                self._items[index], self._items[parent] = self._items[parent], self._items[index]
                index = parent
            else
                break
            end
        end
    end

    -- Internal: Bubble down to maintain heap property
    function heap:_bubbleDown(index)
        while true do
            local smallest = index
            local left = 2 * index
            local right = 2 * index + 1

            if left <= self._size and self._compare(self._items[left], self._items[smallest]) then
                smallest = left
            end

            if right <= self._size and self._compare(self._items[right], self._items[smallest]) then
                smallest = right
            end

            if smallest ~= index then
                self._items[index], self._items[smallest] =
                    self._items[smallest], self._items[index]
                index = smallest
            else
                break
            end
        end
    end

    return heap
end

-- Set Implementation (unique values)
--- Create a new Set
---@return table set New set instance
---@usage local set = Set()
function Set()
    local set = {
        _items = {},
        _size = 0,
    }

    --- Add item to set
    ---@param item any Item to add
    ---@return boolean added True if item was added (not already present)
    ---@usage set:add("item")
    function set:add(item)
        if self._items[item] ~= nil then
            return false
        end
        self._items[item] = true
        self._size = self._size + 1
        return true
    end

    --- Remove item from set
    ---@param item any Item to remove
    ---@return boolean removed True if item was removed
    ---@usage set:remove("item")
    function set:remove(item)
        if self._items[item] == nil then
            return false
        end
        self._items[item] = nil
        self._size = self._size - 1
        return true
    end

    --- Check if set contains item
    ---@param item any Item to check
    ---@return boolean contains True if set contains item
    ---@usage if set:contains("item") then ... end
    function set:contains(item)
        return self._items[item] ~= nil
    end

    --- Get number of items in set
    ---@return number size Number of items
    ---@usage local size = set:size()
    function set:size()
        return self._size
    end

    --- Check if set is empty
    ---@return boolean empty True if set is empty
    ---@usage if set:isEmpty() then ... end
    function set:isEmpty()
        return self._size == 0
    end

    --- Clear all items from set
    ---@usage set:clear()
    function set:clear()
        self._items = {}
        self._size = 0
    end

    --- Get array of all items
    ---@return table items Array of set items
    ---@usage local items = set:toArray()
    function set:toArray()
        local array = {}
        for item, _ in pairs(self._items) do
            table.insert(array, item)
        end
        return array
    end

    --- Create union with another set
    ---@param other table Another set
    ---@return table union New set containing items from both sets
    ---@usage local union = set1:union(set2)
    function set:union(other)
        local result = Set()
        for item, _ in pairs(self._items) do
            result:add(item)
        end
        for item, _ in pairs(other._items) do
            result:add(item)
        end
        return result
    end

    --- Create intersection with another set
    ---@param other table Another set
    ---@return table intersection New set containing common items
    ---@usage local common = set1:intersection(set2)
    function set:intersection(other)
        local result = Set()
        for item, _ in pairs(self._items) do
            if other:contains(item) then
                result:add(item)
            end
        end
        return result
    end

    --- Create difference with another set
    ---@param other table Another set
    ---@return table difference New set containing items in this but not other
    ---@usage local diff = set1:difference(set2)
    function set:difference(other)
        local result = Set()
        for item, _ in pairs(self._items) do
            if not other:contains(item) then
                result:add(item)
            end
        end
        return result
    end

    return set
end

-- Priority Queue Implementation (using heap)
--- Create a new Priority Queue
---@param compareFunc function? Comparison function(a, b) returns true if a has higher priority
---@return table pqueue New priority queue instance
---@usage local pq = PriorityQueue(function(a, b) return a.priority < b.priority end)
function PriorityQueue(compareFunc)
    -- Validate compareFunc
    if compareFunc ~= nil and type(compareFunc) ~= "function" then
        _HarnessInternal.log.error(
            "PriorityQueue compareFunc must be a function",
            "DataStructures.PriorityQueue"
        )
        compareFunc = nil
    end

    local heapCompareFunc = nil
    if not compareFunc then
        -- Default comparison for items with priority field
        heapCompareFunc = function(a, b)
            return a.priority < b.priority
        end
    end

    local pqueue = {
        _heap = Heap(true, heapCompareFunc or compareFunc),
    }

    --- Add item with priority
    ---@param item any Item to add
    ---@param priority number? Priority (used if no compareFunc provided)
    ---@usage pqueue:enqueue(task, 5)
    function pqueue:enqueue(item, priority)
        if not compareFunc and priority then
            self._heap:insert({ item = item, priority = priority })
        else
            self._heap:insert(item)
        end
    end

    --- Remove and return highest priority item
    ---@return any? item Highest priority item or nil if empty
    ---@usage local task = pqueue:dequeue()
    function pqueue:dequeue()
        local result = self._heap:extract()
        if result and result.item then
            return result.item
        end
        return result
    end

    --- Peek at highest priority item
    ---@return any? item Highest priority item or nil if empty
    ---@usage local next = pqueue:peek()
    function pqueue:peek()
        local result = self._heap:peek()
        if result and result.item then
            return result.item
        end
        return result
    end

    --- Check if queue is empty
    ---@return boolean empty True if queue is empty
    ---@usage if pqueue:isEmpty() then ... end
    function pqueue:isEmpty()
        return self._heap:isEmpty()
    end

    --- Get number of items
    ---@return number size Number of items
    ---@usage local size = pqueue:size()
    function pqueue:size()
        return self._heap:size()
    end

    --- Clear all items
    ---@usage pqueue:clear()
    function pqueue:clear()
        self._heap:clear()
    end

    return pqueue
end

-- RingBuffer Implementation (fixed-capacity circular buffer)
--- Create a new RingBuffer
---@param capacity number Buffer capacity (> 0)
---@param overwrite boolean? Overwrite oldest when full (default: true)
---@return table ring New ring buffer instance
---@usage local rb = RingBuffer(3)
function RingBuffer(capacity, overwrite)
    if type(capacity) ~= "number" or capacity < 1 then
        _HarnessInternal.log.error(
            "RingBuffer capacity must be positive number",
            "DataStructures.RingBuffer"
        )
        capacity = 1
    end

    local ring = {
        _items = {},
        _capacity = math.floor(capacity),
        _size = 0,
        _head = 1, -- index of logical front
        _tail = 0, -- index of last inserted
        _overwrite = overwrite ~= false, -- default true
    }

    local function nextIndex(index)
        if index >= ring._capacity then
            return 1
        end
        return index + 1
    end

    --- Add item to buffer tail
    ---@param item any Item to push
    ---@return boolean success True if inserted (or overwritten)
    ---@return any? evicted Evicted item if overwrite occurred
    ---@usage local ok, evicted = ring:push(value)
    function ring:push(item)
        if self._size < self._capacity then
            self._tail = nextIndex(self._tail)
            self._items[self._tail] = item
            self._size = self._size + 1
            return true, nil
        end

        if self._overwrite then
            local evicted = self._items[self._head]
            self._head = nextIndex(self._head)
            self._tail = nextIndex(self._tail)
            self._items[self._tail] = item
            return true, evicted
        end

        return false, nil
    end

    --- Remove and return item from buffer head
    ---@return any? item Popped item or nil if empty
    ---@usage local item = ring:pop()
    function ring:pop()
        if self:isEmpty() then
            return nil
        end

        local item = self._items[self._head]
        self._items[self._head] = nil
        self._head = nextIndex(self._head)
        self._size = self._size - 1

        if self._size == 0 then
            -- reset indices for cleanliness
            self._head = 1
            self._tail = 0
        end

        return item
    end

    --- Peek at head item without removing
    ---@return any? item Head item or nil if empty
    ---@usage local front = ring:peek()
    function ring:peek()
        if self:isEmpty() then
            return nil
        end
        return self._items[self._head]
    end

    --- Get logical item by 1-based index (1 = head)
    ---@param index number 1-based index into buffer contents
    ---@return any? item Item at index or nil
    function ring:get(index)
        if type(index) ~= "number" or index < 1 or index > self._size then
            return nil
        end
        local pos = self._head
        for _ = 2, index do
            pos = nextIndex(pos)
        end
        return self._items[pos]
    end

    --- Convert contents to array (head to tail order)
    ---@return table items Array of items
    function ring:toArray()
        local arr = {}
        local pos = self._head
        for i = 1, self._size do
            arr[i] = self._items[pos]
            pos = nextIndex(pos)
        end
        return arr
    end

    --- Check if buffer is empty
    ---@return boolean empty True if empty
    function ring:isEmpty()
        return self._size == 0
    end

    --- Check if buffer is full
    ---@return boolean full True if full
    function ring:isFull()
        return self._size == self._capacity
    end

    --- Current number of items
    ---@return number size Number of items
    function ring:size()
        return self._size
    end

    --- Buffer capacity
    ---@return number capacity Capacity
    function ring:capacity()
        return self._capacity
    end

    --- Clear all items
    function ring:clear()
        self._items = {}
        self._size = 0
        self._head = 1
        self._tail = 0
    end

    return ring
end
-- ==== END: src/datastructures.lua ====

-- ==== BEGIN: src/eventbus.lua ====
--[[
    EventBus Module - minimal pub/sub for events

    - Subscribe by arbitrary topic key (number/string/any non-nil)
    - Optional predicate(event) -> boolean filters deliveries
    - Delivery enqueues the event table directly into the provided Queue
    - Supports multiple subscribers per event ID
    - Key selection is customizable; defaults to `event.id`
    - HarnessWorldEventBus integrates with `world.addEventHandler` lazily
]]

-- Single-handler approach: one handler instance per mission
local ACTIVE_HANDLER = nil

---@class EventBus
---@field _subscribers table<any, table> Map of topicKey -> array of subscriber records
---@field _nextSubId number
---@field _keySelector fun(event: table): any
---@return table EventBus
function EventBus(keySelector)
    local selector = nil
    if type(keySelector) == "function" then
        selector = keySelector
    else
        selector = function(event)
            return event and event.id
        end
    end

    local bus = { _subscribers = {}, _nextSubId = 1, _keySelector = selector }

    --- Subscribe to a topic key with optional predicate and a target queue
    ---@param topicKey any topic key to route on (must be non-nil)
    ---@param queue table Queue() instance receiving DTOs via :enqueue
    ---@param predicate fun(event: table): boolean Optional predicate to filter deliveries
    ---@return number? subscriptionId Returns an id to later unsubscribe, or nil on error
    function bus:subscribe(topicKey, queue, predicate)
        if topicKey == nil then
            return nil
        end
        if type(queue) ~= "table" or type(queue.enqueue) ~= "function" then
            return nil
        end
        if predicate ~= nil and type(predicate) ~= "function" then
            return nil
        end

        if not self._subscribers[topicKey] then
            self._subscribers[topicKey] = {}
        end

        local id = self._nextSubId
        self._nextSubId = self._nextSubId + 1

        table.insert(self._subscribers[topicKey], {
            id = id,
            queue = queue,
            predicate = predicate,
        })
        return id
    end

    --- Unsubscribe a previously created subscription id
    ---@param subscriptionId number
    ---@return boolean removed True if removed
    function bus:unsubscribe(subscriptionId)
        if type(subscriptionId) ~= "number" then
            return false
        end
        for eventId, list in pairs(self._subscribers) do
            for i = #list, 1, -1 do
                if list[i].id == subscriptionId then
                    table.remove(list, i)
                    if #list == 0 then
                        self._subscribers[eventId] = nil
                    end
                    return true
                end
            end
        end
        return false
    end

    -- Idiomatic aliases
    function bus:sub(topicKey, queue, predicate)
        return self:subscribe(topicKey, queue, predicate)
    end
    function bus:unsub(subscriptionId)
        return self:unsubscribe(subscriptionId)
    end

    --- Publish an event to subscribers of its derived topic key
    ---@param event table Event payload
    function bus:publish(event)
        if type(event) ~= "table" then
            return
        end
        local key = self._keySelector(event)
        if key == nil then
            return
        end
        local list = self._subscribers[key]
        if not list or #list == 0 then
            return
        end

        for i = 1, #list do
            local sub = list[i]
            local deliver = true
            if sub.predicate ~= nil then
                local ok, result = pcall(sub.predicate, event)
                deliver = ok and result == true
            end
            if deliver then
                pcall(sub.queue.enqueue, sub.queue, event)
            end
        end
    end

    return bus
end

---@class HarnessWorldEventBus : EventBus
---@field _handler table
---@return table HarnessWorldEventBus
function CreateHarnessWorldEventBus()
    local bus = EventBus()
    bus._registered = false
    bus._totalSubs = 0

    bus._handler = {
        onEvent = function(self, event)
            bus:publish(event)
        end,
    }

    local baseSubscribe = bus.subscribe
    function bus:subscribe(eventId, queue, predicate)
        local id = baseSubscribe(self, eventId, queue, predicate)
        if id then
            self._totalSubs = self._totalSubs + 1
            if (not self._registered) and world and type(world.addEventHandler) == "function" then
                world.addEventHandler(self._handler)
                self._registered = true
                ACTIVE_HANDLER = self._handler
            end
        end
        return id
    end

    local baseUnsubscribe = bus.unsubscribe
    function bus:unsubscribe(subscriptionId)
        local removed = baseUnsubscribe(self, subscriptionId)
        if removed then
            self._totalSubs = self._totalSubs - 1
            if self._totalSubs < 0 then
                self._totalSubs = 0
            end
            if
                self._registered
                and self._totalSubs == 0
                and world
                and type(world.removeEventHandler) == "function"
            then
                if ACTIVE_HANDLER == self._handler then
                    world.removeEventHandler(self._handler)
                    ACTIVE_HANDLER = nil
                end
                self._registered = false
            end
        end
        return removed
    end

    function bus:dispose()
        if self._registered and world and type(world.removeEventHandler) == "function" then
            if ACTIVE_HANDLER == self._handler then
                world.removeEventHandler(self._handler)
                ACTIVE_HANDLER = nil
            end
        end
        self._registered = false
        self._totalSubs = 0
    end

    return bus
end

-- Provide a globally accessible singleton for harness initialization if desired
HarnessWorldEventBus = nil
-- Back-compat alias
HarnessWorldEventBusInstance = nil

--- Initialize global HarnessWorldEventBus if not already created
function InitHarnessWorldEventBus()
    if not HarnessWorldEventBus then
        HarnessWorldEventBus = CreateHarnessWorldEventBus()
        HarnessWorldEventBusInstance = HarnessWorldEventBus
    end
    return HarnessWorldEventBus
end

-- Lazy init only creates the instance; it will not register with world
InitHarnessWorldEventBus()
-- ==== END: src/eventbus.lua ====

-- ==== BEGIN: src/geogrid.lua ====
--[[
==================================================================================================
    GEOGRID MODULE
    Spatial grid for indexing and querying entities by position
==================================================================================================
]]

---@class GeoGridLocation
---@field cx integer
---@field cz integer
---@field type string
---@field bucket string
---@field p { x: number, y: number, z: number }

---@class GeoGrid
---@field grid table<integer, table<integer, table<string, table<any, boolean>>>>
---@field idx table<any, GeoGridLocation>
---@field cell number
---@field types table<string, boolean>
---@field minX number
---@field minZ number
---@field maxX number
---@field maxZ number
---@field count integer
---@field has_bounds boolean
---@field add fun(self: GeoGrid, entityType: string, entityId: any, pos: { x: number, y: number|nil, z: number }): boolean
---@field remove fun(self: GeoGrid, entityId: any): boolean
---@field updatePosition fun(self: GeoGrid, entityId: any, pos: { x: number, y: number|nil, z: number }, defaultType?: string): boolean
---@field move fun(self: GeoGrid, entityId: any, pos: { x: number, y: number|nil, z: number }): boolean, table|nil, table|nil
---@field changeType fun(self: GeoGrid, entityId: any, newType: string): boolean
---@field queryRadius fun(self: GeoGrid, pos: { x: number, y: number|nil, z: number }, radius: number, types: string[]): table<string, table<any, boolean>>
---@field clear fun(self: GeoGrid)
---@field size fun(self: GeoGrid): integer
---@field has fun(self: GeoGrid, id: any): boolean
---@field toTable fun(self: GeoGrid): table
---@field fromTable fun(self: GeoGrid, t: table): boolean
local floor = math.floor

---@param t any
---@return string|nil et
local function norm_type(t)
    if type(t) ~= "string" then
        return nil
    end
    t = (t:gsub("%s+", "")):gsub("Ids$", "")
    return t ~= "" and t or nil
end

local GeoGridProto = {}

--- Compute integer cell coordinates for a position
---@param p { x: number|nil, y: number|nil, z: number|nil }
---@return integer cx
---@return integer cz
function GeoGridProto:_cell_coords(p)
    return floor((p.x or 0) / self.cell), floor((p.z or 0) / self.cell)
end

--- Ensure a cell exists and expand bounds as needed
---@param cx integer
---@param cz integer
---@return table cell
function GeoGridProto:_ensure_cell(cx, cz)
    local col = self.grid[cx]
    if not col then
        col = {}
        self.grid[cx] = col
    end
    local cell = col[cz]
    if not cell then
        cell = {}
        col[cz] = cell
        local x0, x1 = cx * self.cell, (cx + 1) * self.cell
        local z0, z1 = cz * self.cell, (cz + 1) * self.cell
        if not self.has_bounds then
            self.minX, self.maxX, self.minZ, self.maxZ, self.has_bounds = x0, x1, z0, z1, true
        else
            if x0 < self.minX then
                self.minX = x0
            end
            if x1 > self.maxX then
                self.maxX = x1
            end
            if z0 < self.minZ then
                self.minZ = z0
            end
            if z1 > self.maxZ then
                self.maxZ = z1
            end
        end
    end
    return cell
end

--- Add an entity to the grid (idempotent for same type)
---@param entityType string
---@param entityId any
---@param pos { x: number, y: number|nil, z: number }
---@return boolean ok
function GeoGridProto:add(entityType, entityId, pos)
    if type(pos) ~= "table" or type(pos.x) ~= "number" or type(pos.z) ~= "number" then
        return false
    end
    local et = norm_type(entityType)
    if not et then
        return false
    end
    if not (self.types and self.types[et]) then
        return false
    end

    local loc = self.idx[entityId]
    if loc then
        if loc.type ~= et then
            return false
        end
        return self:updatePosition(entityId, pos)
    end

    local cx, cz = self:_cell_coords(pos)
    local cell = self:_ensure_cell(cx, cz)
    local bucket = et .. "Ids"
    cell[bucket] = cell[bucket] or {}
    if not cell[bucket][entityId] then
        cell[bucket][entityId] = true
        self.count = self.count + 1
    end
    self.idx[entityId] = {
        cx = cx,
        cz = cz,
        type = et,
        bucket = bucket,
        p = { x = pos.x, y = pos.y or 0, z = pos.z },
    }
    return true
end

--- Remove an entity from the grid
---@param entityId any
---@return boolean ok
function GeoGridProto:remove(entityId)
    local loc = self.idx[entityId]
    if not loc then
        return false
    end
    local col = self.grid[loc.cx]
    local cell = col and col[loc.cz]
    if cell and cell[loc.bucket] and cell[loc.bucket][entityId] then
        cell[loc.bucket][entityId] = nil
        self.count = self.count - 1
    end
    self.idx[entityId] = nil
    return true
end

--- Update an entity position (optionally upsert with defaultType)
---@param entityId any
---@param pos { x: number, y: number|nil, z: number }
---@param defaultType string|nil
---@return boolean ok
function GeoGridProto:updatePosition(entityId, pos, defaultType)
    local loc = self.idx[entityId]
    if not loc then
        return defaultType and self:add(defaultType, entityId, pos) or false
    end
    if type(pos) ~= "table" or type(pos.x) ~= "number" or type(pos.z) ~= "number" then
        return false
    end

    local ncx, ncz = self:_cell_coords(pos)
    loc.p.x, loc.p.y, loc.p.z = pos.x, pos.y or 0, pos.z
    if ncx == loc.cx and ncz == loc.cz then
        return true
    end

    local ocol = self.grid[loc.cx]
    local ocell = ocol and ocol[loc.cz]
    if ocell and ocell[loc.bucket] then
        ocell[loc.bucket][entityId] = nil
    end

    local ncell = self:_ensure_cell(ncx, ncz)
    ncell[loc.bucket] = ncell[loc.bucket] or {}
    ncell[loc.bucket][entityId] = true
    loc.cx, loc.cz = ncx, ncz
    return true
end

--- Move an entity and return from/to cell indices
---@param entityId any
---@param pos { x: number, y: number|nil, z: number }
---@return boolean ok
---@return table|nil from
---@return table|nil to
function GeoGridProto:move(entityId, pos)
    local loc = self.idx[entityId]
    local from = loc and { cx = loc.cx, cz = loc.cz } or nil
    local ok = self:updatePosition(entityId, pos)
    loc = self.idx[entityId]
    local to = loc and { cx = loc.cx, cz = loc.cz } or nil
    return ok, from, to
end

--- Change the entity type without re-adding
---@param entityId any
---@param newType string
---@return boolean ok
function GeoGridProto:changeType(entityId, newType)
    local loc = self.idx[entityId]
    if not loc then
        return false
    end
    local et = norm_type(newType)
    if not et then
        return false
    end
    if not (self.types and self.types[et]) then
        return false
    end
    if et == loc.type then
        return true
    end
    local col = self.grid[loc.cx]
    local cell = col and col[loc.cz]
    if not cell then
        return false
    end

    if cell[loc.bucket] then
        cell[loc.bucket][entityId] = nil
    end
    local nb = et .. "Ids"
    cell[nb] = cell[nb] or {}
    cell[nb][entityId] = true
    loc.type, loc.bucket = et, nb
    return true
end

--- Query entities within radius; exact distance (2D) filter applied
---@param pos { x: number, y: number|nil, z: number }
---@param radius number
---@param types string[]
---@return table<string, table<any, boolean>> out
function GeoGridProto:queryRadius(pos, radius, types)
    local out = {}
    if type(pos) ~= "table" or type(radius) ~= "number" or radius < 0 or type(types) ~= "table" then
        return out
    end
    local keys = {}
    for i = 1, #types do
        local et = norm_type(types[i])
        if et and self.types and self.types[et] then
            local k = et .. "Ids"
            out[k] = {}
            keys[#keys + 1] = k
        end
    end
    if #keys == 0 then
        return out
    end

    local ccx, ccz = self:_cell_coords(pos)
    local cr = math.ceil(radius / self.cell)
    local r2 = radius * radius
    local px, pz = pos.x or 0, pos.z or 0

    for dx = -cr, cr do
        local col = self.grid[ccx + dx]
        if col then
            for dz = -cr, cr do
                local cell = col[ccz + dz]
                if cell then
                    for k = 1, #keys do
                        local b = cell[keys[k]]
                        if b then
                            for id in pairs(b) do
                                local loc = self.idx[id]
                                local lp = loc and loc.p
                                if lp then
                                    local dxp, dzp = lp.x - px, lp.z - pz
                                    if dxp * dxp + dzp * dzp <= r2 then
                                        out[keys[k]][id] = true
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return out
end

--- Reset grid state
---@return nil
function GeoGridProto:clear()
    self.grid, self.idx, self.count, self.has_bounds = {}, {}, 0, false
    self.minX, self.minZ, self.maxX, self.maxZ = 0, 0, 0, 0
end

--- Get total number of entities
---@return integer n
function GeoGridProto:size()
    return self.count
end

--- Check if an entity exists
---@param id any
---@return boolean hasIt
function GeoGridProto:has(id)
    return self.idx[id] ~= nil
end

--- Serialize grid to a plain table for persistence
---@return table t
function GeoGridProto:toTable()
    local t = {
        cellSize = self.cell,
        minX = self.minX,
        minZ = self.minZ,
        maxX = self.maxX,
        maxZ = self.maxZ,
        entities = {},
    }
    local i = 0
    for id, loc in pairs(self.idx) do
        i = i + 1
        t.entities[i] =
            { id = id, entityType = loc.type, position = { x = loc.p.x, y = loc.p.y, z = loc.p.z } }
    end
    return t
end

--- Restore grid from a plain table
---@param t table
---@return boolean ok
function GeoGridProto:fromTable(t)
    if type(t) ~= "table" or type(t.cellSize) ~= "number" then
        return false
    end
    self:clear()
    self.cell = t.cellSize
    self.minX, self.minZ, self.maxX, self.maxZ, self.has_bounds =
        t.minX or 0, t.minZ or 0, t.maxX or 0, t.maxZ or 0, true
    local es = t.entities
    if type(es) == "table" then
        for i = 1, #es do
            local e = es[i]
            if e and e.entityType and e.id and e.position then
                self:add(e.entityType, e.id, e.position)
            end
        end
    end
    return true
end

---
---@param cellSizeMeters number|nil
---@param allowedTypes string[]
---@return GeoGrid
function GeoGrid(cellSizeMeters, allowedTypes)
    local typesSet = {}
    if type(allowedTypes) == "table" then
        for i = 1, #allowedTypes do
            local et = norm_type(allowedTypes[i])
            if et then
                typesSet[et] = true
            end
        end
    end
    return setmetatable({
        grid = {},
        idx = {},
        cell = (type(cellSizeMeters) == "number" and cellSizeMeters > 0) and cellSizeMeters
            or 10000,
        types = typesSet,
        minX = 0,
        minZ = 0,
        maxX = 0,
        maxZ = 0,
        count = 0,
        has_bounds = false,
    }, { __index = GeoGridProto })
end
-- ==== END: src/geogrid.lua ====

-- ==== BEGIN: src/id.lua ====
--[[
==================================================================================================
    ID MODULE
    Utilities for generating IDs: UUID v4, UUID v7, and ULID
==================================================================================================
]]

-- Note: module does not depend on logger to remain lightweight and side-effect free

-- Internal PRNG (LCG) with a time- and address-based seed to avoid relying on math.random state
local function _seed32()
    local t = (timer and timer.getTime and timer.getTime()) or 0
    local addr = tonumber((tostring({}):match("0x(%x+)") or "0"), 16) or 0
    local s = math.max(1, math.floor(t * 1e6))
    return ((s % 2147483647) * 1103515245 + (addr % 2147483647) + 12345) % 2147483647
end

local _rng_state = _seed32()

local function _lcg32()
    _rng_state = (1103515245 * _rng_state + 12345) % 2147483648
    return _rng_state
end

local function _rand_byte()
    -- Scale a 31-bit LCG state into a byte
    return math.floor(_lcg32() / 8388608) % 256 -- 2^23
end

local function _to_hex_byte(b)
    local hex = "0123456789abcdef"
    local hi, lo = math.floor(b / 16) + 1, (b % 16) + 1
    return string.sub(hex, hi, hi) .. string.sub(hex, lo, lo)
end

--- Generate a UUID v4 string (random)
---@return string uuid UUID v4 string (lowercase hex)
function NewUUIDv4()
    local b = {}
    for i = 1, 16 do
        b[i] = _rand_byte()
    end
    -- Set version (0100) and variant (10xx)
    b[7] = (b[7] % 16) + 0x40
    b[9] = (b[9] % 64) + 0x80

    local parts =
        {
            _to_hex_byte(b[1]) .. _to_hex_byte(b[2]) .. _to_hex_byte(b[3]) .. _to_hex_byte(b[4]),
            _to_hex_byte(b[5]) .. _to_hex_byte(b[6]),
            _to_hex_byte(b[7]) .. _to_hex_byte(b[8]),
            _to_hex_byte(b[9]) .. _to_hex_byte(b[10]),
            _to_hex_byte(b[11]) .. _to_hex_byte(b[12]) .. _to_hex_byte(b[13]) .. _to_hex_byte(
                b[14]
            ) .. _to_hex_byte(b[15]) .. _to_hex_byte(b[16]),
        }
    return table.concat(parts, "-")
end

--- Generate a UUID v7 string (time-ordered)
---@return string uuid UUID v7 string (lowercase hex)
function NewUUIDv7()
    local ms = math.floor(((timer and timer.getTime and timer.getTime()) or 0) * 1000)
    local b = {}
    -- 48-bit big-endian timestamp
    for i = 6, 1, -1 do
        b[i] = ms % 256
        ms = math.floor(ms / 256)
    end
    -- 10 random bytes
    for i = 7, 16 do
        b[i] = _rand_byte()
    end

    -- Set version (0111) and variant (10xx)
    b[7] = (b[7] % 16) + 0x70
    b[9] = (b[9] % 64) + 0x80

    local parts =
        {
            _to_hex_byte(b[1]) .. _to_hex_byte(b[2]) .. _to_hex_byte(b[3]) .. _to_hex_byte(b[4]),
            _to_hex_byte(b[5]) .. _to_hex_byte(b[6]),
            _to_hex_byte(b[7]) .. _to_hex_byte(b[8]),
            _to_hex_byte(b[9]) .. _to_hex_byte(b[10]),
            _to_hex_byte(b[11]) .. _to_hex_byte(b[12]) .. _to_hex_byte(b[13]) .. _to_hex_byte(
                b[14]
            ) .. _to_hex_byte(b[15]) .. _to_hex_byte(b[16]),
        }
    return table.concat(parts, "-")
end

--- Generate a ULID string (Crockford Base32, 26 chars)
---@return string ulid ULID string
function NewULID()
    local ms = math.floor(((timer and timer.getTime and timer.getTime()) or 0) * 1000)
    local b = {}
    -- 6-byte big-endian timestamp
    for i = 6, 1, -1 do
        b[i] = ms % 256
        ms = math.floor(ms / 256)
    end
    -- 10 bytes randomness
    for i = 7, 16 do
        b[i] = _rand_byte()
    end

    -- Crockford Base32 alphabet
    local alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    -- Convert 16 bytes to bit array
    local bits = {}
    for i = 1, 16 do
        local v = b[i]
        for j = 7, 0, -1 do
            bits[#bits + 1] = math.floor(v / 2 ^ j) % 2
        end
    end

    -- Pad to 130 bits (ULID encodes to 26 base32 chars)
    bits[#bits + 1] = 0
    bits[#bits + 1] = 0

    local out = {}
    for i = 1, 26 do
        local idx = 0
        for j = 0, 4 do
            idx = idx * 2 + bits[(i - 1) * 5 + j + 1]
        end
        out[i] = string.sub(alphabet, idx + 1, idx + 1)
    end

    return table.concat(out)
end
-- ==== END: src/id.lua ====

-- ==== BEGIN: src/logger.lua ====
--[[==================================================================================================
    LOGGER MODULE
    Configurable logging system with namespace support
==================================================================================================
]]

---@class Logger
---@field namespace string
---@field info fun(message: string, caller?: string)
---@field warn fun(message: string, caller?: string)
---@field error fun(message: string, caller?: string)
---@field debug fun(message: string, caller?: string)

---@class HarnessInternal
---@field loggers table<string, Logger>
---@field defaultNamespace string

-- Logger storage
---@type HarnessInternal
_HarnessInternal = _HarnessInternal or {}
_HarnessInternal.loggers = {}
_HarnessInternal.defaultNamespace = "Harness"

--- Internal function to format messages
---@param namespace string The namespace for the log message
---@param message string The message to log
---@param caller string? Optional caller identifier
---@return string formatted The formatted log message
local function formatMessage(namespace, message, caller)
    if not caller then
        return string.format("[%s]: %s", namespace, message)
    end
    return string.format("[%s : %s]: %s", namespace, caller, message)
end

--- Create a new logger instance for a specific namespace
---@param namespace string? The namespace for this logger (defaults to "Harness")
---@return Logger logger Logger instance with info, warn, error, and debug methods
---@usage local myLogger = HarnessLogger("MyMod")
---@usage myLogger.info("Starting up")
function HarnessLogger(namespace)
    if not namespace or type(namespace) ~= "string" then
        namespace = _HarnessInternal.defaultNamespace
    end

    -- Return existing logger if already created
    if _HarnessInternal.loggers[namespace] then
        return _HarnessInternal.loggers[namespace]
    end

    ---@type Logger
    local logger = {
        namespace = namespace,
    }

    --- Log an info message
    ---@param message string The message to log
    ---@param caller string? Optional caller identifier
    function logger.info(message, caller)
        env.info(formatMessage(namespace, message, caller))
    end

    --- Log a warning message
    ---@param message string The message to log
    ---@param caller string? Optional caller identifier
    function logger.warn(message, caller)
        env.warning(formatMessage(namespace, message, caller))
    end

    --- Log an error message
    ---@param message string The message to log
    ---@param caller string? Optional caller identifier
    function logger.error(message, caller)
        env.error(formatMessage(namespace, message, caller))
    end

    --- Log a debug message
    ---@param message string The message to log
    ---@param caller string? Optional caller identifier
    function logger.debug(message, caller)
        env.info(formatMessage(namespace .. " : DEBUG", message, caller))
    end

    _HarnessInternal.loggers[namespace] = logger
    return logger
end

-- Create internal logger for Harness use
---@type Logger
_HarnessInternal.log = HarnessLogger("Harness")

-- Create global Log object that can be configured with a namespace
-- Projects should call: Log = HarnessLogger("MyProject")
-- Or if they just use Log without configuration, it defaults to "Script"
---@type Logger
Log = HarnessLogger("Script")
-- ==== END: src/logger.lua ====

-- ==== BEGIN: src/airbase.lua ====
--[[
    Airbase Module - DCS World Airbase API Wrappers
    
    This module provides validated wrapper functions for DCS airbase operations,
    including runway queries, parking spots, and airbase information.
]]
--- Get airbase by name
---@param airbaseName string? Name of the airbase
---@return table? airbase Airbase object if found, nil otherwise
---@usage local airbase = getAirbaseByName("Batumi")
function GetAirbaseByName(airbaseName)
    if not airbaseName or type(airbaseName) ~= "string" then
        _HarnessInternal.log.error(
            "GetAirbaseByName requires valid airbase name",
            "Airbase.GetByName"
        )
        return nil
    end

    local success, result = pcall(Airbase.getByName, airbaseName)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get airbase by name: " .. tostring(result),
            "Airbase.GetByName"
        )
        return nil
    end

    return result
end

--- Get airbase descriptor
---@param airbase table? Airbase object
---@return table? descriptor Airbase descriptor if found, nil otherwise
---@usage local desc = getAirbaseDescriptor(airbase)
function GetAirbaseDescriptor(airbase)
    if not airbase then
        _HarnessInternal.log.error(
            "GetAirbaseDescriptor requires valid airbase",
            "Airbase.GetDescriptor"
        )
        return nil
    end

    local success, result = pcall(airbase.getDesc, airbase)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get airbase descriptor: " .. tostring(result),
            "Airbase.GetDesc"
        )
        return nil
    end

    return result
end

--- Get airbase callsign
---@param airbase table? Airbase object
---@return string? callsign Airbase callsign if found, nil otherwise
---@usage local callsign = getAirbaseCallsign(airbase)
function GetAirbaseCallsign(airbase)
    if not airbase then
        _HarnessInternal.log.error(
            "GetAirbaseCallsign requires valid airbase",
            "Airbase.GetCallsign"
        )
        return nil
    end

    local success, result = pcall(airbase.getCallsign, airbase)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get airbase callsign: " .. tostring(result),
            "Airbase.GetCallsign"
        )
        return nil
    end

    return result
end

--- Get airbase unit
---@param airbase table? Airbase object
---@return table? unit Airbase unit if found, nil otherwise
---@usage local unit = getAirbaseUnit(airbase)
function GetAirbaseUnit(airbase, unitIndex)
    if not airbase then
        _HarnessInternal.log.error("GetAirbaseUnit requires valid airbase", "Airbase.GetUnit")
        return nil
    end

    local success, result = pcall(airbase.getUnit, airbase, unitIndex)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get airbase unit: " .. tostring(result),
            "Airbase.GetUnit"
        )
        return nil
    end

    return result
end

--- Get airbase category name
---@param airbase table? Airbase object
---@return string? category Category name if found, nil otherwise
---@usage local category = getAirbaseCategoryName(airbase)
function GetAirbaseCategoryName(airbase)
    if not airbase then
        _HarnessInternal.log.error(
            "GetAirbaseCategoryName requires valid airbase",
            "Airbase.GetCategoryName"
        )
        return nil
    end

    local success, categoryValue = pcall(airbase.getCategoryEx, airbase)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get airbase category: " .. tostring(categoryValue),
            "Airbase.GetCategoryEx"
        )
        return nil
    end

    local names = {}
    local cat = (Airbase and Airbase.Category) or nil
    if cat then
        names[cat.AIRDROME] = "AIRDROME"
        names[cat.HELIPAD] = "HELIPAD"
        local farp = rawget(cat, "FARP")
        if farp ~= nil then
            names[farp] = "FARP"
        end
        local ship = cat["SHIP"]
        if ship ~= nil then
            names[ship] = "SHIP"
        end
        local oil = rawget(cat, "OIL_PLATFORM")
        if oil ~= nil then
            names[oil] = "OIL_PLATFORM"
        end
    end

    return names[categoryValue] or tostring(categoryValue)
end

--- Get airbase parking information
---@param airbase table? Airbase object
---@param available boolean? If true, only return available parking spots
---@return table? parking Parking information if found, nil otherwise
---@usage local parking = getAirbaseParking(airbase, true)
function GetAirbaseParking(airbase, available)
    if not airbase then
        _HarnessInternal.log.error("GetAirbaseParking requires valid airbase", "Airbase.GetParking")
        return nil
    end

    local success, result = pcall(airbase.getParking, airbase, available)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get airbase parking: " .. tostring(result),
            "Airbase.GetParking"
        )
        return nil
    end

    return result
end

--- Get airbase runways
---@param airbase table? Airbase object
---@return table? runways Runway information if found, nil otherwise
---@usage local runways = getAirbaseRunways(airbase)
function GetAirbaseRunways(airbase)
    if not airbase then
        _HarnessInternal.log.error("GetAirbaseRunways requires valid airbase", "Airbase.GetRunways")
        return nil
    end

    local success, result = pcall(airbase.getRunways, airbase)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get airbase runways: " .. tostring(result),
            "Airbase.GetRunways"
        )
        return nil
    end

    return result
end

--- Get airbase tech object positions
---@param airbase table? Airbase object
---@param techObjectType number Tech object type ID
---@return table? positions Tech object positions if found, nil otherwise
---@usage local positions = getAirbaseTechObjectPos(airbase, 1)
function GetAirbaseTechObjectPos(airbase, techObjectType)
    if not airbase then
        _HarnessInternal.log.error(
            "GetAirbaseTechObjectPos requires valid airbase",
            "Airbase.GetTechObjectPos"
        )
        return nil
    end

    if not techObjectType or type(techObjectType) ~= "number" then
        _HarnessInternal.log.error(
            "GetAirbaseTechObjectPos requires valid tech object type",
            "Airbase.GetTechObjectPos"
        )
        return nil
    end

    local success, result = pcall(airbase.getTechObjectPos, airbase, techObjectType)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get tech object positions: " .. tostring(result),
            "Airbase.GetTechObjectPos"
        )
        return nil
    end

    return result
end

--- Get airbase dispatcher tower position
---@param airbase table? Airbase object
---@return table? position Tower position if found, nil otherwise
---@usage local towerPos = getAirbaseDispatcherTowerPos(airbase)
function GetAirbaseDispatcherTowerPos(airbase)
    if not airbase then
        _HarnessInternal.log.error(
            "GetAirbaseDispatcherTowerPos requires valid airbase",
            "Airbase.GetDispatcherTowerPos"
        )
        return nil
    end

    local success, result = pcall(airbase.getDispatcherTowerPos, airbase)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get dispatcher tower position: " .. tostring(result),
            "Airbase.GetDispatcherTowerPos"
        )
        return nil
    end

    return result
end

--- Get airbase radio silent mode
---@param airbase table? Airbase object
---@return boolean? silent True if radio silent, nil on error
---@usage local isSilent = getAirbaseRadioSilentMode(airbase)
function GetAirbaseRadioSilentMode(airbase)
    if not airbase then
        _HarnessInternal.log.error(
            "GetAirbaseRadioSilentMode requires valid airbase",
            "Airbase.GetRadioSilentMode"
        )
        return nil
    end

    local success, result = pcall(airbase.getRadioSilentMode, airbase)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get radio silent mode: " .. tostring(result),
            "Airbase.GetRadioSilentMode"
        )
        return nil
    end

    return result
end

--- Set airbase radio silent mode
---@param airbase table? Airbase object
---@param silent boolean Radio silent mode
---@return boolean? success True if set successfully, nil on error
---@usage SetAirbaseRadioSilentMode(airbase, true)
function SetAirbaseRadioSilentMode(airbase, silent)
    if not airbase then
        _HarnessInternal.log.error(
            "SetAirbaseRadioSilentMode requires valid airbase",
            "Airbase.SetRadioSilentMode"
        )
        return nil
    end

    if type(silent) ~= "boolean" then
        _HarnessInternal.log.error(
            "SetAirbaseRadioSilentMode requires boolean silent value",
            "Airbase.SetRadioSilentMode"
        )
        return nil
    end

    local success, result = pcall(airbase.setRadioSilentMode, airbase, silent)
    if not success then
        _HarnessInternal.log.error(
            "Failed to set radio silent mode: " .. tostring(result),
            "Airbase.SetRadioSilentMode"
        )
        return nil
    end

    return true
end

--- Get airbase beacon information
---@param airbase table? Airbase object
---@return table? beacon Beacon information if found, nil otherwise
---@usage local beacon = getAirbaseBeacon(airbase)
function GetAirbaseBeacon(airbase)
    if not airbase then
        _HarnessInternal.log.error("GetAirbaseBeacon requires valid airbase", "Airbase.GetBeacon")
        return nil
    end

    local success, result = pcall(airbase.getBeacon, airbase)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get airbase beacon: " .. tostring(result),
            "Airbase.GetBeacon"
        )
        return nil
    end

    return result
end

--- Set airbase auto capture mode
---@param airbase table? Airbase object
---@param enabled boolean Auto capture enabled
---@return boolean? success True if set successfully, nil on error
---@usage AirbaseAutoCapture(airbase, true)
function AirbaseAutoCapture(airbase, enabled)
    if not airbase then
        _HarnessInternal.log.error(
            "AirbaseAutoCapture requires valid airbase",
            "Airbase.AutoCapture"
        )
        return nil
    end

    if type(enabled) ~= "boolean" then
        _HarnessInternal.log.error(
            "AirbaseAutoCapture requires boolean enabled value",
            "Airbase.AutoCapture"
        )
        return nil
    end

    local success, result = pcall(airbase.autoCapture, airbase, enabled)
    if not success then
        _HarnessInternal.log.error(
            "Failed to set auto capture: " .. tostring(result),
            "Airbase.AutoCapture"
        )
        return nil
    end

    return true
end

--- Check if airbase auto capture is enabled
---@param airbase table? Airbase object
---@return boolean? enabled True if auto capture is on, nil on error
---@usage local isOn = airbaseAutoCaptureIsOn(airbase)
function AirbaseAutoCaptureIsOn(airbase)
    if not airbase then
        _HarnessInternal.log.error(
            "AirbaseAutoCaptureIsOn requires valid airbase",
            "Airbase.AutoCaptureIsOn"
        )
        return nil
    end

    local success, result = pcall(airbase.autoCaptureIsOn, airbase)
    if not success then
        _HarnessInternal.log.error(
            "Failed to check auto capture status: " .. tostring(result),
            "Airbase.AutoCaptureIsOn"
        )
        return nil
    end

    return result
end

--- Set airbase coalition
---@param airbase table? Airbase object
---@param coalitionId number Coalition ID
---@return boolean? success True if set successfully, nil on error
---@usage SetAirbaseCoalition(airbase, coalition.side.BLUE)
function SetAirbaseCoalition(airbase, coalitionId)
    if not airbase then
        _HarnessInternal.log.error(
            "SetAirbaseCoalition requires valid airbase",
            "Airbase.SetCoalition"
        )
        return nil
    end

    if not coalitionId or type(coalitionId) ~= "number" then
        _HarnessInternal.log.error(
            "SetAirbaseCoalition requires valid coalition ID",
            "Airbase.SetCoalition"
        )
        return nil
    end

    local success, result = pcall(airbase.setCoalition, airbase, coalitionId)
    if not success then
        _HarnessInternal.log.error(
            "Failed to set airbase coalition: " .. tostring(result),
            "Airbase.SetCoalition"
        )
        return nil
    end

    return true
end

--- Get airbase warehouse
---@param airbase table? Airbase object
---@return table? warehouse Warehouse object if found, nil otherwise
---@usage local warehouse = getAirbaseWarehouse(airbase)
function GetAirbaseWarehouse(airbase)
    if not airbase then
        _HarnessInternal.log.error(
            "GetAirbaseWarehouse requires valid airbase",
            "Airbase.GetWarehouse"
        )
        return nil
    end

    local success, result = pcall(airbase.getWarehouse, airbase)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get airbase warehouse: " .. tostring(result),
            "Airbase.GetWarehouse"
        )
        return nil
    end

    return result
end

--- Get free parking terminal
---@param airbase table? Airbase object
---@param terminalType any? Terminal type filter
---@return table? terminal Free parking terminal if found, nil otherwise
---@usage local terminal = getAirbaseFreeParkingTerminal(airbase)
function GetAirbaseFreeParkingTerminal(airbase, terminalType)
    if not airbase then
        _HarnessInternal.log.error(
            "GetAirbaseFreeParkingTerminal requires valid airbase",
            "Airbase.GetFreeParkingTerminal"
        )
        return nil
    end

    local success, result = pcall(airbase.getFreeParkingTerminal, airbase, terminalType)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get free parking terminal: " .. tostring(result),
            "Airbase.GetFreeParkingTerminal"
        )
        return nil
    end

    return result
end

--- Get free parking terminals by type
---@param airbase table? Airbase object
---@param terminalType any? Terminal type filter
---@param multiple boolean? Return multiple terminals
---@return table? terminals Free parking terminals if found, nil otherwise
---@usage local terminals = getAirbaseFreeParkingTerminalByType(airbase, type, true)
function GetAirbaseFreeParkingTerminalByType(airbase, terminalType, multiple)
    if not airbase then
        _HarnessInternal.log.error(
            "GetAirbaseFreeParkingTerminalByType requires valid airbase",
            "Airbase.GetFreeParkingTerminalByType"
        )
        return nil
    end

    local success, result = pcall(airbase.getFreeParkingTerminal, airbase, terminalType, multiple)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get free parking terminals by type: " .. tostring(result),
            "Airbase.GetFreeParkingTerminalByType"
        )
        return nil
    end

    return result
end

--- Get free airbase parking terminal
---@param airbase table? Airbase object
---@param terminalType any? Terminal type filter
---@return table? terminal Free parking terminal if found, nil otherwise
---@usage local terminal = getFreeAirbaseParkingTerminal(airbase)
function GetFreeAirbaseParkingTerminal(airbase, terminalType)
    if not airbase then
        _HarnessInternal.log.error(
            "GetFreeAirbaseParkingTerminal requires valid airbase",
            "Airbase.GetFreeAirbaseParkingTerminal"
        )
        return nil
    end

    local success, result = pcall(airbase.getFreeAirbaseParkingTerminal, airbase, terminalType)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get free airbase parking terminal: " .. tostring(result),
            "Airbase.GetFreeAirbaseParkingTerminal"
        )
        return nil
    end

    return result
end

--- Get airbase parking terminal
---@param airbase table? Airbase object
---@param terminal number Terminal number
---@return table? terminal Parking terminal if found, nil otherwise
---@usage local terminal = getAirbaseParkingTerminal(airbase, 1)
function GetAirbaseParkingTerminal(airbase, terminal)
    if not airbase then
        _HarnessInternal.log.error(
            "GetAirbaseParkingTerminal requires valid airbase",
            "Airbase.GetParkingTerminal"
        )
        return nil
    end

    if not terminal or type(terminal) ~= "number" then
        _HarnessInternal.log.error(
            "GetAirbaseParkingTerminal requires valid terminal number",
            "Airbase.GetParkingTerminal"
        )
        return nil
    end

    local success, result = pcall(airbase.getParkingTerminal, airbase, terminal)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get parking terminal: " .. tostring(result),
            "Airbase.GetParkingTerminal"
        )
        return nil
    end

    return result
end

--- Get airbase parking terminal by index
---@param airbase table? Airbase object
---@param index number Terminal index
---@return table? terminal Parking terminal if found, nil otherwise
---@usage local terminal = getAirbaseParkingTerminalByIndex(airbase, 1)
function GetAirbaseParkingTerminalByIndex(airbase, index)
    if not airbase then
        _HarnessInternal.log.error(
            "GetAirbaseParkingTerminalByIndex requires valid airbase",
            "Airbase.GetParkingTerminalByIndex"
        )
        return nil
    end

    if not index or type(index) ~= "number" then
        _HarnessInternal.log.error(
            "GetAirbaseParkingTerminalByIndex requires valid index",
            "Airbase.GetParkingTerminalByIndex"
        )
        return nil
    end

    local success, result = pcall(airbase.getParkingTerminalByIndex, airbase, index)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get parking terminal by index: " .. tostring(result),
            "Airbase.GetParkingTerminalByIndex"
        )
        return nil
    end

    return result
end

--- Get airbase parking count
---@param airbase table? Airbase object
---@return number? count Number of parking spots, nil on error
---@usage local count = getAirbaseParkingCount(airbase)
function GetAirbaseParkingCount(airbase)
    if not airbase then
        _HarnessInternal.log.error(
            "GetAirbaseParkingCount requires valid airbase",
            "Airbase.GetParkingCount"
        )
        return nil
    end

    local success, result = pcall(airbase.getParkingCount, airbase)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get parking count: " .. tostring(result),
            "Airbase.GetParkingCount"
        )
        return nil
    end

    return result
end

--- Get airbase runway details
---@param airbase table? Airbase object
---@param runwayIndex number? Specific runway index
---@return table? details Runway details if found, nil otherwise
---@usage local details = getAirbaseRunwayDetails(airbase, 1)
function GetAirbaseRunwayDetails(airbase, runwayIndex)
    if not airbase then
        _HarnessInternal.log.error(
            "GetAirbaseRunwayDetails requires valid airbase",
            "Airbase.GetRunwayDetails"
        )
        return nil
    end

    if runwayIndex and type(runwayIndex) ~= "number" then
        _HarnessInternal.log.error(
            "getAirbaseRunwayDetails runway index must be a number if provided",
            "Airbase.GetRunwayDetails"
        )
        return nil
    end

    local success, result = pcall(airbase.getRunwayDetails, airbase, runwayIndex)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get runway details: " .. tostring(result),
            "Airbase.GetRunwayDetails"
        )
        return nil
    end

    return result
end

--- Get airbase meteorological data
---@param airbase table? Airbase object
---@param height number? Height for weather data
---@return table? meteo Weather data if found, nil otherwise
---@usage local weather = getAirbaseMeteo(airbase, 100)
function GetAirbaseMeteo(airbase, height)
    if not airbase then
        _HarnessInternal.log.error("GetAirbaseMeteo requires valid airbase", "Airbase.GetMeteo")
        return nil
    end

    local success, result = pcall(airbase.getMeteo, airbase, height)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get airbase meteo: " .. tostring(result),
            "Airbase.GetMeteo"
        )
        return nil
    end

    return result
end

--- Get airbase wind with turbulence
---@param airbase table? Airbase object
---@param height number? Height for wind data
---@return table? wind Wind data with turbulence if found, nil otherwise
---@usage local wind = getAirbaseWindWithTurbulence(airbase, 100)
function GetAirbaseWindWithTurbulence(airbase, height)
    if not airbase then
        _HarnessInternal.log.error(
            "GetAirbaseWindWithTurbulence requires valid airbase",
            "Airbase.GetWindWithTurbulence"
        )
        return nil
    end

    local success, result = pcall(airbase.getWindWithTurbulence, airbase, height)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get wind with turbulence: " .. tostring(result),
            "Airbase.GetWindWithTurbulence"
        )
        return nil
    end

    return result
end

--- Check if airbase provides service
---@param airbase table? Airbase object
---@param service number Service type ID
---@return boolean? provided True if service is provided, nil on error
---@usage local hasService = getAirbaseIsServiceProvided(airbase, 1)
function GetAirbaseIsServiceProvided(airbase, service)
    if not airbase then
        _HarnessInternal.log.error(
            "GetAirbaseIsServiceProvided requires valid airbase",
            "Airbase.GetIsServiceProvided"
        )
        return nil
    end

    if not service or type(service) ~= "number" then
        _HarnessInternal.log.error(
            "GetAirbaseIsServiceProvided requires valid service type",
            "Airbase.GetIsServiceProvided"
        )
        return nil
    end

    local success, result = pcall(airbase.getIsServiceProvided, airbase, service)
    if not success then
        _HarnessInternal.log.error(
            "Failed to check service availability: " .. tostring(result),
            "Airbase.GetIsServiceProvided"
        )
        return nil
    end

    return result
end
-- ==== END: src/airbase.lua ====

-- ==== BEGIN: src/cache.lua ====
--[[
==================================================================================================
    CACHE MODULE
    Internal caching system for DCS object handles
==================================================================================================
]]
-- Ensure cache tables exist (may have been initialized in _header.lua)
_HarnessInternal.cache = _HarnessInternal.cache
    or {
        units = {},
        groups = {},
        controllers = {},
        airbases = {},

        -- Statistics
        stats = {
            hits = 0,
            misses = 0,
            evictions = 0,
        },
    }

-- Cache configuration
_HarnessInternal.cache.config = _HarnessInternal.cache.config
    or {
        maxUnits = 1000,
        maxGroups = 500,
        maxControllers = 500,
        maxAirbases = 100,
        ttl = 300, -- 5 minutes default TTL
    }

--- Clear all caches
---@usage ClearAllCaches()
function ClearAllCaches()
    local count = 0
    for _ in pairs(_HarnessInternal.cache.units) do
        count = count + 1
    end
    for _ in pairs(_HarnessInternal.cache.groups) do
        count = count + 1
    end
    for _ in pairs(_HarnessInternal.cache.controllers) do
        count = count + 1
    end
    for _ in pairs(_HarnessInternal.cache.airbases) do
        count = count + 1
    end

    _HarnessInternal.cache.units = {}
    _HarnessInternal.cache.groups = {}
    _HarnessInternal.cache.controllers = {}
    _HarnessInternal.cache.airbases = {}

    if count > 0 then
        _HarnessInternal.cache.stats.evictions = _HarnessInternal.cache.stats.evictions + count
    end

    _HarnessInternal.log.info("Cleared all caches (" .. count .. " entries)", "ClearAllCaches")
end

--- Clear unit cache
---@usage ClearUnitCache()
function ClearUnitCache()
    local count = 0
    for _ in pairs(_HarnessInternal.cache.units) do
        count = count + 1
    end
    _HarnessInternal.cache.units = {}
    _HarnessInternal.cache.stats.evictions = _HarnessInternal.cache.stats.evictions + count
    _HarnessInternal.log.info("Cleared unit cache (" .. count .. " entries)", "ClearUnitCache")
end

--- Clear group cache
---@usage ClearGroupCache()
function ClearGroupCache()
    local count = 0
    for _ in pairs(_HarnessInternal.cache.groups) do
        count = count + 1
    end
    _HarnessInternal.cache.groups = {}
    _HarnessInternal.cache.stats.evictions = _HarnessInternal.cache.stats.evictions + count
    _HarnessInternal.log.info("Cleared group cache (" .. count .. " entries)", "ClearGroupCache")
end

--- Clear controller cache
---@usage ClearControllerCache()
function ClearControllerCache()
    local count = 0
    for _ in pairs(_HarnessInternal.cache.controllers) do
        count = count + 1
    end
    _HarnessInternal.cache.controllers = {}
    _HarnessInternal.cache.stats.evictions = _HarnessInternal.cache.stats.evictions + count
    _HarnessInternal.log.info(
        "Cleared controller cache (" .. count .. " entries)",
        "ClearControllerCache"
    )
end

--- Remove specific unit from cache
---@param unitName string Unit name
---@usage RemoveUnitFromCache("Pilot-1")
function RemoveUnitFromCache(unitName)
    if unitName and _HarnessInternal.cache.units[unitName] then
        _HarnessInternal.cache.units[unitName] = nil
        _HarnessInternal.cache.stats.evictions = _HarnessInternal.cache.stats.evictions + 1
        _HarnessInternal.log.debug("Removed unit from cache: " .. unitName, "RemoveUnitFromCache")
    end
end

--- Remove specific group from cache
---@param groupName string Group name
---@usage RemoveGroupFromCache("Blue Squadron")
function RemoveGroupFromCache(groupName)
    if groupName and _HarnessInternal.cache.groups[groupName] then
        _HarnessInternal.cache.groups[groupName] = nil
        _HarnessInternal.cache.stats.evictions = _HarnessInternal.cache.stats.evictions + 1
        _HarnessInternal.log.debug(
            "Removed group from cache: " .. groupName,
            "RemoveGroupFromCache"
        )
    end
end

--- Get cache statistics
---@return table stats Cache statistics
---@usage local stats = GetCacheStats()
function GetCacheStats()
    local stats = {
        hits = _HarnessInternal.cache.stats.hits,
        misses = _HarnessInternal.cache.stats.misses,
        evictions = _HarnessInternal.cache.stats.evictions,
        hitRate = 0,
        units = 0,
        groups = 0,
        controllers = 0,
        airbases = 0,
    }

    -- Count entries
    for _ in pairs(_HarnessInternal.cache.units) do
        stats.units = stats.units + 1
    end
    for _ in pairs(_HarnessInternal.cache.groups) do
        stats.groups = stats.groups + 1
    end
    for _ in pairs(_HarnessInternal.cache.controllers) do
        stats.controllers = stats.controllers + 1
    end
    for _ in pairs(_HarnessInternal.cache.airbases) do
        stats.airbases = stats.airbases + 1
    end

    -- Calculate hit rate
    local total = stats.hits + stats.misses
    if total > 0 then
        stats.hitRate = stats.hits / total
    end

    return stats
end

--- Set cache configuration
---@param config table Configuration options
---@usage SetCacheConfig({maxUnits = 2000, ttl = 600})
function SetCacheConfig(config)
    if type(config) ~= "table" then
        _HarnessInternal.log.error("SetCacheConfig requires table", "SetCacheConfig")
        return
    end

    if config.maxUnits and type(config.maxUnits) == "number" then
        _HarnessInternal.cache.config.maxUnits = config.maxUnits
    end
    if config.maxGroups and type(config.maxGroups) == "number" then
        _HarnessInternal.cache.config.maxGroups = config.maxGroups
    end
    if config.maxControllers and type(config.maxControllers) == "number" then
        _HarnessInternal.cache.config.maxControllers = config.maxControllers
    end
    if config.maxAirbases and type(config.maxAirbases) == "number" then
        _HarnessInternal.cache.config.maxAirbases = config.maxAirbases
    end
    if config.ttl and type(config.ttl) == "number" then
        _HarnessInternal.cache.config.ttl = config.ttl
    end

    _HarnessInternal.log.info("Updated cache configuration", "SetCacheConfig")
end

--- Get direct access to cache tables (for advanced users)
---@return table caches All cache tables
---@usage local caches = GetCacheTables()
function GetCacheTables()
    return {
        units = _HarnessInternal.cache.units,
        groups = _HarnessInternal.cache.groups,
        controllers = _HarnessInternal.cache.controllers,
        airbases = _HarnessInternal.cache.airbases,
    }
end

-- Internal cache management functions

--- Check if cache entry is expired
---@param entry table Cache entry
---@return boolean expired True if expired
function _HarnessInternal.cache.isExpired(entry)
    if not entry or not entry.time then
        return true
    end

    local currentTime = timer and timer.getTime and timer.getTime() or os.time()
    return (currentTime - entry.time) > _HarnessInternal.cache.config.ttl
end

--- Add unit to cache
---@param name string Unit name
---@param unit table Unit object
function _HarnessInternal.cache.addUnit(name, unit)
    if not name or not unit then
        return
    end

    -- Check cache size
    local count = 0
    for _ in pairs(_HarnessInternal.cache.units) do
        count = count + 1
    end

    if count >= _HarnessInternal.cache.config.maxUnits then
        -- Evict oldest entry
        local oldestKey, oldestTime = nil, math.huge
        for k, v in pairs(_HarnessInternal.cache.units) do
            if v.time < oldestTime then
                oldestKey = k
                oldestTime = v.time
            end
        end
        if oldestKey then
            _HarnessInternal.cache.units[oldestKey] = nil
            _HarnessInternal.cache.stats.evictions = _HarnessInternal.cache.stats.evictions + 1
        end
    end

    _HarnessInternal.cache.units[name] = {
        object = unit,
        time = timer and timer.getTime and timer.getTime() or os.time(),
    }
end

--- Get unit from cache
---@param name string Unit name
---@return table? unit Unit object or nil
function _HarnessInternal.cache.getUnit(name)
    if not name then
        return nil
    end

    local entry = _HarnessInternal.cache.units[name]
    if not entry then
        _HarnessInternal.cache.stats.misses = _HarnessInternal.cache.stats.misses + 1
        return nil
    end

    -- Check expiration
    if _HarnessInternal.cache.isExpired(entry) then
        _HarnessInternal.cache.units[name] = nil
        _HarnessInternal.cache.stats.evictions = _HarnessInternal.cache.stats.evictions + 1
        _HarnessInternal.cache.stats.misses = _HarnessInternal.cache.stats.misses + 1
        return nil
    end

    _HarnessInternal.cache.stats.hits = _HarnessInternal.cache.stats.hits + 1
    return entry.object
end

--- Add group to cache
---@param name string Group name
---@param group table Group object
function _HarnessInternal.cache.addGroup(name, group)
    if not name or not group then
        return
    end

    -- Check cache size
    local count = 0
    for _ in pairs(_HarnessInternal.cache.groups) do
        count = count + 1
    end

    if count >= _HarnessInternal.cache.config.maxGroups then
        -- Evict oldest entry
        local oldestKey, oldestTime = nil, math.huge
        for k, v in pairs(_HarnessInternal.cache.groups) do
            if v.time < oldestTime then
                oldestKey = k
                oldestTime = v.time
            end
        end
        if oldestKey then
            _HarnessInternal.cache.groups[oldestKey] = nil
            _HarnessInternal.cache.stats.evictions = _HarnessInternal.cache.stats.evictions + 1
        end
    end

    _HarnessInternal.cache.groups[name] = {
        object = group,
        time = timer and timer.getTime and timer.getTime() or os.time(),
    }
end

--- Get group from cache
---@param name string Group name
---@return table? group Group object or nil
function _HarnessInternal.cache.getGroup(name)
    if not name then
        return nil
    end

    local entry = _HarnessInternal.cache.groups[name]
    if not entry then
        _HarnessInternal.cache.stats.misses = _HarnessInternal.cache.stats.misses + 1
        return nil
    end

    -- Check expiration
    if _HarnessInternal.cache.isExpired(entry) then
        _HarnessInternal.cache.groups[name] = nil
        _HarnessInternal.cache.stats.evictions = _HarnessInternal.cache.stats.evictions + 1
        _HarnessInternal.cache.stats.misses = _HarnessInternal.cache.stats.misses + 1
        return nil
    end

    _HarnessInternal.cache.stats.hits = _HarnessInternal.cache.stats.hits + 1
    return entry.object
end

--- Add controller to cache
---@param key string Cache key (unit/group name + type)
---@param controller table Controller object
function _HarnessInternal.cache.addController(key, controller)
    if not key or not controller then
        return
    end

    -- Check cache size
    local count = 0
    for _ in pairs(_HarnessInternal.cache.controllers) do
        count = count + 1
    end

    if count >= _HarnessInternal.cache.config.maxControllers then
        -- Evict oldest entry
        local oldestKey, oldestTime = nil, math.huge
        for k, v in pairs(_HarnessInternal.cache.controllers) do
            if v.time < oldestTime then
                oldestKey = k
                oldestTime = v.time
            end
        end
        if oldestKey then
            _HarnessInternal.cache.controllers[oldestKey] = nil
            _HarnessInternal.cache.stats.evictions = _HarnessInternal.cache.stats.evictions + 1
        end
    end

    _HarnessInternal.cache.controllers[key] = {
        object = controller,
        time = timer and timer.getTime and timer.getTime() or os.time(),
    }
end

--- Get controller from cache
---@param key string Cache key
---@return table? controller Controller object or nil
function _HarnessInternal.cache.getController(key)
    if not key then
        return nil
    end

    local entry = _HarnessInternal.cache.controllers[key]
    if not entry then
        _HarnessInternal.cache.stats.misses = _HarnessInternal.cache.stats.misses + 1
        return nil
    end

    -- Check expiration
    if _HarnessInternal.cache.isExpired(entry) then
        _HarnessInternal.cache.controllers[key] = nil
        _HarnessInternal.cache.stats.evictions = _HarnessInternal.cache.stats.evictions + 1
        _HarnessInternal.cache.stats.misses = _HarnessInternal.cache.stats.misses + 1
        return nil
    end

    _HarnessInternal.cache.stats.hits = _HarnessInternal.cache.stats.hits + 1
    return entry.object
end

-- Caching Decorator

--- Create a cached version of a function that returns DCS objects
---@param func function The function to cache
---@param getCacheKey function Function that generates cache key from arguments
---@param cacheType string Cache type: "unit", "group", "controller", or "generic"
---@param verifyFunc function? Optional function to verify cached object is still valid
---@return function cached Cached version of the function
---@usage local cachedGetUnit = CacheDecorator(Unit.getByName, function(name) return name end, "unit")
function CacheDecorator(func, getCacheKey, cacheType, verifyFunc)
    if type(func) ~= "function" then
        _HarnessInternal.log.error("CacheDecorator requires a function", "CacheDecorator")
        return func
    end

    if type(getCacheKey) ~= "function" then
        _HarnessInternal.log.error("CacheDecorator requires getCacheKey function", "CacheDecorator")
        return func
    end

    local validTypes = { unit = true, group = true, controller = true, generic = true }
    if not validTypes[cacheType] then
        _HarnessInternal.log.error("Invalid cache type: " .. tostring(cacheType), "CacheDecorator")
        return func
    end

    -- Default verify function checks isExist()
    verifyFunc = verifyFunc
        or function(obj)
            local success, exists = pcall(function()
                return obj:isExist()
            end)
            return success and exists
        end

    return function(...)
        local cacheKey = getCacheKey(...)
        if not cacheKey then
            return func(...)
        end

        -- Check appropriate cache
        local cached = nil
        if cacheType == "unit" then
            cached = _HarnessInternal.cache.getUnit(cacheKey)
        elseif cacheType == "group" then
            cached = _HarnessInternal.cache.getGroup(cacheKey)
        elseif cacheType == "controller" then
            cached = _HarnessInternal.cache.getController(cacheKey)
        end

        -- Verify cached object is still valid
        if cached and verifyFunc(cached) then
            return cached
        elseif cached then
            -- Remove invalid object from cache
            if cacheType == "unit" then
                RemoveUnitFromCache(cacheKey)
            elseif cacheType == "group" then
                RemoveGroupFromCache(cacheKey)
            elseif cacheType == "controller" then
                _HarnessInternal.cache.controllers[cacheKey] = nil
                _HarnessInternal.cache.stats.evictions = _HarnessInternal.cache.stats.evictions + 1
            end
        end

        -- Call original function
        local result = func(...)

        -- Cache the result if valid
        if result then
            if cacheType == "unit" then
                _HarnessInternal.cache.addUnit(cacheKey, result)
            elseif cacheType == "group" then
                _HarnessInternal.cache.addGroup(cacheKey, result)
            elseif cacheType == "controller" then
                _HarnessInternal.cache.addController(cacheKey, result)
            end
        end

        return result
    end
end

--- Get cached unit (convenience function for external users)
---@param unitName string Unit name
---@return table? unit Cached unit or nil
---@usage local unit = GetCachedUnit("Pilot-1")
function GetCachedUnit(unitName)
    return _HarnessInternal.cache.getUnit(unitName)
end

--- Get cached group (convenience function for external users)
---@param groupName string Group name
---@return table? group Cached group or nil
---@usage local group = GetCachedGroup("Blue Squadron")
function GetCachedGroup(groupName)
    return _HarnessInternal.cache.getGroup(groupName)
end

--- Get cached controller (convenience function for external users)
---@param key string Cache key
---@return table? controller Cached controller or nil
---@usage local controller = GetCachedController("unit:Pilot-1")
function GetCachedController(key)
    return _HarnessInternal.cache.getController(key)
end
-- ==== END: src/cache.lua ====

-- ==== BEGIN: src/coalition.lua ====
--[[
    Coalition Module - DCS World Coalition API Wrappers
    
    This module provides validated wrapper functions for DCS coalition operations,
    including country queries, group management, and unit spawning.
]]
--- Build a unit entry for use in GroupSpawnData
--- @param typeName string DCS unit type name (e.g., "F-15C", "M-1 Abrams")
--- @param unitName string Unique unit name
--- @param posX number 2D map X coordinate (meters)
--- @param posY number 2D map Y coordinate (meters)
--- @param altitude number Altitude in meters AGL/MSL per alt_type
--- @param heading number Heading in radians (0 = east, math.pi/2 = north)
--- @param opts table|nil Optional overrides: { skill, payload, callsign, onboard_num, alt_type, psi }
--- @return table|nil unit Unit table suitable for GroupSpawnData or nil on error
function BuildUnitEntry(typeName, unitName, posX, posY, altitude, heading, opts)
    if type(typeName) ~= "string" or type(unitName) ~= "string" then
        _HarnessInternal.log.error(
            "BuildUnitEntry requires string typeName and unitName",
            "Coalition.BuildUnitEntry"
        )
        return nil
    end
    if type(posX) ~= "number" or type(posY) ~= "number" then
        _HarnessInternal.log.error(
            "BuildUnitEntry requires numeric posX and posY",
            "Coalition.BuildUnitEntry"
        )
        return nil
    end
    if type(altitude) ~= "number" or type(heading) ~= "number" then
        _HarnessInternal.log.error(
            "BuildUnitEntry requires numeric altitude and heading",
            "Coalition.BuildUnitEntry"
        )
        return nil
    end

    local options = opts or {}

    local unit = {
        type = typeName,
        skill = options.skill or (AI and AI.Skill and AI.Skill.AVERAGE) or "Average",
        y = posY,
        x = posX,
        alt = altitude,
        heading = heading,
        payload = options.payload or {},
        name = unitName,
        alt_type = options.alt_type or "BARO",
        callsign = options.callsign,
        psi = options.psi or 0,
        onboard_num = options.onboard_num,
    }

    return unit
end

--- Build a standard Turning Point waypoint
--- @param x number 2D map X coordinate (meters)
--- @param y number 2D map Y coordinate (meters)
--- @param altitude number Altitude in meters
--- @param speed number Speed in m/s
--- @param tasks table|nil Optional array of task entries to attach (ComboTask)
--- @return table waypoint Waypoint table
function BuildWaypoint(x, y, altitude, speed, tasks)
    local wp = {
        x = x,
        y = altitude,
        z = y,
        action = "Turning Point",
        speed = speed,
        type = "Turning Point",
        ETA = 0,
        ETA_locked = false,
        formation_template = "",
        alt = altitude,
        alt_type = "BARO",
        speed_locked = true,
        task = { id = "ComboTask", params = { tasks = {} } },
    }

    if tasks and type(tasks) == "table" then
        for _, t in ipairs(tasks) do
            wp.task.params.tasks[#wp.task.params.tasks + 1] = t
        end
    end

    return wp
end

--- Build a route table for GroupSpawnData
--- @param waypoints table Array of waypoint tables (from BuildWaypoint or compatible)
--- @param opts table|nil Optional overrides: none currently, reserved for future
--- @return table route Route table with points array
function BuildRoute(waypoints, opts)
    if type(waypoints) ~= "table" then
        _HarnessInternal.log.error("BuildRoute requires waypoints array", "Coalition.BuildRoute")
        return { points = {} }
    end
    return { points = waypoints }
end

--- Build a GroupSpawnData table
--- @param groupName string Unique group name
--- @param task string Group task (e.g., "CAP", "Ground Nothing")
--- @param units table Array of unit tables (from BuildUnitEntry or compatible)
--- @param routePoints table|nil Array of waypoint tables; if nil, an empty route is used
--- @param opts table|nil Optional overrides: { visible, taskSelected, communication, start_time, frequency, modulation }
--- @return table|nil groupData GroupSpawnData or nil on error
function BuildGroupData(groupName, task, units, routePoints, opts)
    if type(groupName) ~= "string" or groupName == "" then
        _HarnessInternal.log.error(
            "BuildGroupData requires non-empty string groupName",
            "Coalition.BuildGroupData"
        )
        return nil
    end
    if type(task) ~= "string" or task == "" then
        _HarnessInternal.log.error(
            "BuildGroupData requires non-empty string task",
            "Coalition.BuildGroupData"
        )
        return nil
    end
    if type(units) ~= "table" or #units == 0 then
        _HarnessInternal.log.error(
            "BuildGroupData requires non-empty units array",
            "Coalition.BuildGroupData"
        )
        return nil
    end

    local options = opts or {}
    local groupData = {
        visible = options.visible == nil and false or not not options.visible,
        taskSelected = options.taskSelected == nil and true or not not options.taskSelected,
        task = task,
        modulation = options.modulation or 0,
        units = units,
        name = groupName,
        communication = options.communication == nil and true or not not options.communication,
        start_time = options.start_time or 0,
        route = { points = routePoints or {} },
        frequency = options.frequency,
    }

    return groupData
end
--- Get the coalition ID for a given country
--- @param countryId number The country ID to query
--- @return number|nil coalitionId The coalition ID (0=neutral, 1=red, 2=blue) or nil on error
--- @usage local coalition = getCoalitionByCountry(country.id.USA)
function GetCoalitionByCountry(countryId)
    if not countryId or type(countryId) ~= "number" then
        _HarnessInternal.log.error(
            "GetCoalitionByCountry requires valid country ID",
            "Coalition.GetCoalitionByCountry"
        )
        return nil
    end

    local success, result = pcall(coalition.getCountryCoalition, countryId)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get coalition for country: " .. tostring(result),
            "Coalition.GetCoalitionByCountry"
        )
        return nil
    end

    return result
end

--- Get all players (clients) in a coalition
--- @param coalitionId number The coalition ID (1=red, 2=blue)
--- @return table|nil players Array of player units or nil on error
--- @usage local bluePlayers = getCoalitionPlayers(coalition.side.BLUE)
function GetCoalitionPlayers(coalitionId)
    if not coalitionId or type(coalitionId) ~= "number" then
        _HarnessInternal.log.error(
            "GetCoalitionPlayers requires valid coalition ID",
            "Coalition.GetCoalitionPlayers"
        )
        return nil
    end

    local success, result = pcall(coalition.getPlayers, coalitionId)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get coalition players: " .. tostring(result),
            "Coalition.GetCoalitionPlayers"
        )
        return nil
    end

    return result
end

--- Get all groups in a coalition, optionally filtered by category
--- @param coalitionId number The coalition ID (1=red, 2=blue)
--- @param categoryId number|nil Optional category filter (0=airplane, 1=helicopter, 2=ground, 3=ship, 4=structure)
--- @return table|nil groups Array of group objects or nil on error
--- @usage local redGroundGroups = getCoalitionGroups(coalition.side.RED, Group.Category.GROUND)
function GetCoalitionGroups(coalitionId, categoryId)
    if not coalitionId or type(coalitionId) ~= "number" then
        _HarnessInternal.log.error(
            "GetCoalitionGroups requires valid coalition ID",
            "Coalition.GetCoalitionGroups"
        )
        return nil
    end

    if categoryId and type(categoryId) ~= "number" then
        _HarnessInternal.log.error(
            "categoryId must be a number if provided",
            "Coalition.GetCoalitionGroups"
        )
        return nil
    end

    local success, result = pcall(coalition.getGroups, coalitionId, categoryId)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get coalition groups: " .. tostring(result),
            "Coalition.GetCoalitionGroups"
        )
        return {}
    end

    return result or {}
end

--- Get all airbases controlled by a coalition
--- @param coalitionId number The coalition ID (0=neutral, 1=red, 2=blue)
--- @return table|nil airbases Array of airbase objects or nil on error
--- @usage local blueAirbases = getCoalitionAirbases(coalition.side.BLUE)
function GetCoalitionAirbases(coalitionId)
    if not coalitionId or type(coalitionId) ~= "number" then
        _HarnessInternal.log.error(
            "GetCoalitionAirbases requires valid coalition ID",
            "Coalition.GetCoalitionAirbases"
        )
        return nil
    end

    local success, result = pcall(coalition.getAirbases, coalitionId)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get coalition airbases: " .. tostring(result),
            "Coalition.GetCoalitionAirbases"
        )
        return nil
    end

    return result
end

--- Get all countries in a coalition
--- @param coalitionId number The coalition ID (1=red, 2=blue)
--- @return table|nil countries Array of country IDs or nil on error
--- @usage local redCountries = getCoalitionCountries(coalition.side.RED)
function GetCoalitionCountries(coalitionId)
    if not coalitionId or type(coalitionId) ~= "number" then
        _HarnessInternal.log.error(
            "GetCoalitionCountries requires valid coalition ID",
            "Coalition.GetCoalitionCountries"
        )
        return nil
    end

    -- Derive based on documented APIs: iterate country.id and match coalition
    local countries = {}
    if not country or not country.id then
        return countries
    end
    for _, id in pairs(country.id) do
        if type(id) == "number" then
            local ok, side = pcall(coalition.getCountryCoalition, id)
            if ok and side == coalitionId then
                table.insert(countries, id)
            end
        end
    end
    return countries
end

--- Get all static objects belonging to a coalition
--- @param coalitionId number The coalition ID (0=neutral, 1=red, 2=blue)
--- @return table|nil staticObjects Array of static object references or nil on error
--- @usage local blueStatics = getCoalitionStaticObjects(coalition.side.BLUE)
function GetCoalitionStaticObjects(coalitionId)
    if not coalitionId or type(coalitionId) ~= "number" then
        _HarnessInternal.log.error(
            "GetCoalitionStaticObjects requires valid coalition ID",
            "Coalition.GetCoalitionStaticObjects"
        )
        return nil
    end

    local success, result = pcall(coalition.getStaticObjects, coalitionId)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get coalition static objects: " .. tostring(result),
            "Coalition.GetCoalitionStaticObjects"
        )
        return nil
    end

    return result
end

--- Add a new group to the mission for a specific country
--- @param countryId number The country ID that will own the group
--- @param categoryId number The category ID (0=airplane, 1=helicopter, 2=ground, 3=ship)
--- @param groupData table The group definition table with units, route, etc.
--- @return table|nil group The created group object or nil on error
--- @usage local newGroup = addCoalitionGroup(country.id.USA, Group.Category.AIRPLANE, groupDefinition)
function AddCoalitionGroup(countryId, categoryId, groupData)
    if not countryId or type(countryId) ~= "number" then
        _HarnessInternal.log.error(
            "AddCoalitionGroup requires valid country ID",
            "Coalition.AddGroup"
        )
        return nil
    end

    if not categoryId or type(categoryId) ~= "number" then
        _HarnessInternal.log.error(
            "AddCoalitionGroup requires valid category ID",
            "Coalition.AddGroup"
        )
        return nil
    end

    if not groupData or type(groupData) ~= "table" then
        _HarnessInternal.log.error(
            "AddCoalitionGroup requires valid group data table",
            "Coalition.AddGroup"
        )
        return nil
    end

    local success, result = pcall(coalition.addGroup, countryId, categoryId, groupData)
    if not success then
        _HarnessInternal.log.error(
            "Failed to add coalition group: " .. tostring(result),
            "Coalition.AddGroup"
        )
        return nil
    end

    return result
end

--- Add a new static object to the mission for a specific country
--- @param countryId number The country ID that will own the static object
--- @param staticData table The static object definition table
--- @return table|nil staticObject The created static object or nil on error
--- @usage local newStatic = addCoalitionStaticObject(country.id.USA, staticDefinition)
function AddCoalitionStaticObject(countryId, staticData)
    if not countryId or type(countryId) ~= "number" then
        _HarnessInternal.log.error(
            "AddCoalitionStaticObject requires valid country ID",
            "Coalition.AddStaticObject"
        )
        return nil
    end

    if not staticData or type(staticData) ~= "table" then
        _HarnessInternal.log.error(
            "AddCoalitionStaticObject requires valid static object data",
            "Coalition.AddStaticObject"
        )
        return nil
    end

    local success, result = pcall(coalition.addStaticObject, countryId, staticData)
    if not success then
        _HarnessInternal.log.error(
            "Failed to add coalition static object: " .. tostring(result),
            "Coalition.AddStaticObject"
        )
        return nil
    end

    return result
end

--- Get all reference points for a coalition
--- @param coalitionId number The coalition ID (1=red, 2=blue)
--- @return table|nil refPoints Table of reference points or nil on error
--- @usage local blueRefPoints = getCoalitionRefPoints(coalition.side.BLUE)
function GetCoalitionRefPoints(coalitionId)
    if not coalitionId or type(coalitionId) ~= "number" then
        _HarnessInternal.log.error(
            "GetCoalitionRefPoints requires valid coalition ID",
            "Coalition.GetRefPoints"
        )
        return nil
    end

    local success, result = pcall(coalition.getRefPoints, coalitionId)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get coalition reference points: " .. tostring(result),
            "Coalition.GetRefPoints"
        )
        return nil
    end

    return result
end

--- Get the main reference point (bullseye) for a coalition
--- @param coalitionId number The coalition ID (1=red, 2=blue)
--- @return table|nil refPoint The main reference point with x, y, z coordinates or nil on error
--- @usage local blueBullseye = getCoalitionMainRefPoint(coalition.side.BLUE)
function GetCoalitionMainRefPoint(coalitionId)
    if not coalitionId or type(coalitionId) ~= "number" then
        _HarnessInternal.log.error(
            "GetCoalitionMainRefPoint requires valid coalition ID",
            "Coalition.GetMainRefPoint"
        )
        return nil
    end

    local success, result = pcall(coalition.getMainRefPoint, coalitionId)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get coalition main reference point: " .. tostring(result),
            "Coalition.GetMainRefPoint"
        )
        return nil
    end

    return result
end

--- Get the bullseye coordinates for a coalition
--- @param coalitionId number The coalition ID (1=red, 2=blue)
--- @return table|nil bullseye The bullseye position with x, y, z coordinates or nil on error
--- @usage local redBullseye = getCoalitionBullseye(coalition.side.RED)
function GetCoalitionBullseye(coalitionId)
    if not coalitionId or type(coalitionId) ~= "number" then
        _HarnessInternal.log.error(
            "GetCoalitionBullseye requires valid coalition ID",
            "Coalition.GetBullseye"
        )
        return nil
    end

    -- Authoritative API name is getMainRefPoint (bullseye)
    local success, result = pcall(coalition.getMainRefPoint, coalitionId)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get coalition bullseye: " .. tostring(result),
            "Coalition.GetCoalitionBullseye"
        )
        return nil
    end

    return result
end

--- Add a reference point for a coalition
--- @param coalitionId number The coalition ID (1=red, 2=blue)
--- @param refPointData table The reference point data table
--- @return table|nil refPoint The created reference point or nil on error
--- @usage local newRefPoint = addCoalitionRefPoint(coalition.side.BLUE, {callsign = "ALPHA", x = 100000, y = 0, z = 200000})
function AddCoalitionRefPoint(coalitionId, refPointData)
    if not coalitionId or type(coalitionId) ~= "number" then
        _HarnessInternal.log.error(
            "AddCoalitionRefPoint requires valid coalition ID",
            "Coalition.AddRefPoint"
        )
        return nil
    end

    if not refPointData or type(refPointData) ~= "table" then
        _HarnessInternal.log.error(
            "AddCoalitionRefPoint requires valid reference point data",
            "Coalition.AddRefPoint"
        )
        return nil
    end

    local success, result = pcall(coalition.addRefPoint, coalitionId, refPointData)
    if not success then
        _HarnessInternal.log.error(
            "Failed to add coalition reference point: " .. tostring(result),
            "Coalition.AddRefPoint"
        )
        return nil
    end

    return result
end

--- Remove a reference point from a coalition
--- @param coalitionId number The coalition ID (1=red, 2=blue)
--- @param refPointId number|string The reference point ID to remove
--- @return boolean|nil success True if removed successfully, nil on error
--- @usage RemoveCoalitionRefPoint(coalition.side.BLUE, "ALPHA")
function RemoveCoalitionRefPoint(coalitionId, refPointId)
    if not coalitionId or type(coalitionId) ~= "number" then
        _HarnessInternal.log.error(
            "RemoveCoalitionRefPoint requires valid coalition ID",
            "Coalition.RemoveRefPoint"
        )
        return nil
    end

    if not refPointId then
        _HarnessInternal.log.error(
            "RemoveCoalitionRefPoint requires valid reference point ID",
            "Coalition.RemoveRefPoint"
        )
        return nil
    end

    local remover = rawget(coalition, "removeRefPoint")
    if type(remover) ~= "function" then
        _HarnessInternal.log.error(
            "coalition.removeRefPoint not available",
            "Coalition.RemoveRefPoint"
        )
        return nil
    end

    local success, result = pcall(remover, coalitionId, refPointId)
    if not success then
        _HarnessInternal.log.error(
            "Failed to remove coalition reference point: " .. tostring(result),
            "Coalition.RemoveRefPoint"
        )
        return nil
    end

    return result
end

--- Get service providers (tankers, AWACS, etc.) for a coalition
--- @param coalitionId number The coalition ID (1=red, 2=blue)
--- @param serviceType number The service type to query
--- @return table|nil providers Array of units providing the service or nil on error
--- @usage local blueTankers = getCoalitionServiceProviders(coalition.side.BLUE, coalition.service.TANKER)
function GetCoalitionServiceProviders(coalitionId, serviceType)
    if not coalitionId or type(coalitionId) ~= "number" then
        _HarnessInternal.log.error(
            "GetCoalitionServiceProviders requires valid coalition ID",
            "Coalition.GetServiceProviders"
        )
        return nil
    end

    if not serviceType or type(serviceType) ~= "number" then
        _HarnessInternal.log.error(
            "GetCoalitionServiceProviders requires valid service type",
            "Coalition.GetServiceProviders"
        )
        return nil
    end

    local success, result = pcall(coalition.getServiceProviders, coalitionId, serviceType)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get coalition service providers: " .. tostring(result),
            "Coalition.GetServiceProviders"
        )
        return nil
    end

    return result
end
-- ==== END: src/coalition.lua ====

-- ==== BEGIN: src/controller.lua ====
--[[
    Controller Module - DCS World Controller API Wrappers
    
    This module provides validated wrapper functions for DCS controller operations,
    including AI tasking, commands, and behavior management.
]]
-- Resolve a domain string for a controller.
-- Prefers explicitDomain, then cached domain (if available), else falls back.
local function _resolveControllerDomain(controller, explicitDomain, defaultDomain)
    if explicitDomain == "Air" or explicitDomain == "Ground" or explicitDomain == "Naval" then
        return explicitDomain
    end
    if type(GetControllerDomain) == "function" then
        local cached = GetControllerDomain(controller)
        if cached == "Air" or cached == "Ground" or cached == "Naval" then
            return cached
        end
    end
    return defaultDomain
end

--- Get controller domain from cache metadata if available
---@param controller table Controller object
---@return string? domain "Air"|"Ground"|"Naval" if known
function GetControllerDomain(controller)
    if not controller then
        return nil
    end
    local controllers = _HarnessInternal
        and _HarnessInternal.cache
        and _HarnessInternal.cache.controllers
    if type(controllers) ~= "table" then
        return nil
    end
    for _, entry in pairs(controllers) do
        if entry and entry.object == controller and entry.domain then
            return entry.domain
        end
    end
    return nil
end

--- Enum aliases for tooltip-friendly options
---@alias ROEAir "WEAPON_FREE"|"OPEN_FIRE_WEAPON_FREE"|"OPEN_FIRE"|"RETURN_FIRE"|"WEAPON_HOLD"
---@alias ROEGround "OPEN_FIRE"|"RETURN_FIRE"|"WEAPON_HOLD"
---@alias ROENaval "OPEN_FIRE"|"RETURN_FIRE"|"WEAPON_HOLD"
---@alias ReactionOnThreat "NO_REACTION"|"PASSIVE_DEFENCE"|"EVADE_FIRE"|"BYPASS_AND_ESCAPE"|"ALLOW_ABORT_MISSION"
---@alias MissileAttackMode "MAX_RANGE"|"NEZ_RANGE"|"HALF_WAY_RMAX_NEZ"|"TARGET_THREAT_EST"|"RANDOM_RANGE"
---@alias AlarmState "AUTO"|"GREEN"|"RED"
--- Sets a task for the controller
---@param controller table The controller object
---@param task table The task table to set
---@return boolean? success Returns true if successful, nil on error
---@usage SetControllerTask(controller, {id="Mission", params={...}})
function SetControllerTask(controller, task)
    if not controller then
        _HarnessInternal.log.error(
            "SetControllerTask requires valid controller",
            "Controller.SetTask"
        )
        return nil
    end

    if not task or type(task) ~= "table" then
        _HarnessInternal.log.error(
            "SetControllerTask requires valid task table",
            "Controller.SetTask"
        )
        return nil
    end

    local success, result = pcall(controller.setTask, controller, task)
    if not success then
        _HarnessInternal.log.error(
            "Failed to set controller task: " .. tostring(result),
            "Controller.SetTask"
        )
        return nil
    end

    return true
end

--- Resets the controller's current task
---@param controller table The controller object
---@return boolean? success Returns true if successful, nil on error
---@usage ResetControllerTask(controller)
function ResetControllerTask(controller)
    if not controller then
        _HarnessInternal.log.error(
            "ResetControllerTask requires valid controller",
            "Controller.ResetTask"
        )
        return nil
    end

    local success, result = pcall(controller.resetTask, controller)
    if not success then
        _HarnessInternal.log.error(
            "Failed to reset controller task: " .. tostring(result),
            "Controller.ResetTask"
        )
        return nil
    end

    return true
end

--- Pushes a task onto the controller's task queue
---@param controller table The controller object
---@param task table The task table to push
---@return boolean? success Returns true if successful, nil on error
---@usage PushControllerTask(controller, {id="EngageTargets", params={...}})
function PushControllerTask(controller, task)
    if not controller then
        _HarnessInternal.log.error(
            "PushControllerTask requires valid controller",
            "Controller.PushTask"
        )
        return nil
    end

    if not task or type(task) ~= "table" then
        _HarnessInternal.log.error(
            "PushControllerTask requires valid task table",
            "Controller.PushTask"
        )
        return nil
    end

    local success, result = pcall(controller.pushTask, controller, task)
    if not success then
        _HarnessInternal.log.error(
            "Failed to push controller task: " .. tostring(result),
            "Controller.PushTask"
        )
        return nil
    end

    return true
end

--- Pops a task from the controller's task queue
---@param controller table The controller object
---@return boolean? success Returns true if successful, nil on error
---@usage PopControllerTask(controller)
function PopControllerTask(controller)
    if not controller then
        _HarnessInternal.log.error(
            "PopControllerTask requires valid controller",
            "Controller.PopTask"
        )
        return nil
    end

    local success, result = pcall(controller.popTask, controller)
    if not success then
        _HarnessInternal.log.error(
            "Failed to pop controller task: " .. tostring(result),
            "Controller.PopTask"
        )
        return nil
    end

    return true
end

--- Checks if the controller has any tasks
---@param controller table The controller object
---@return boolean? hasTask Returns true if controller has tasks, false if not, nil on error
---@usage local hasTasks = hasControllerTask(controller)
function HasControllerTask(controller)
    if not controller then
        _HarnessInternal.log.error(
            "HasControllerTask requires valid controller",
            "Controller.HasTask"
        )
        return nil
    end

    local success, result = pcall(controller.hasTask, controller)
    if not success then
        _HarnessInternal.log.error(
            "Failed to check controller task: " .. tostring(result),
            "Controller.HasTask"
        )
        return nil
    end

    return result
end

--- Sets a command for the controller
---@param controller table The controller object
---@param command table The command table to set
---@return boolean? success Returns true if successful, nil on error
---@usage SetControllerCommand(controller, {id="Script", params={...}})
function SetControllerCommand(controller, command)
    if not controller then
        _HarnessInternal.log.error(
            "SetControllerCommand requires valid controller",
            "Controller.SetCommand"
        )
        return nil
    end

    if not command or type(command) ~= "table" then
        _HarnessInternal.log.error(
            "SetControllerCommand requires valid command table",
            "Controller.SetCommand"
        )
        return nil
    end

    local success, result = pcall(controller.setCommand, controller, command)
    if not success then
        _HarnessInternal.log.error(
            "Failed to set controller command: " .. tostring(result),
            "Controller.SetCommand"
        )
        return nil
    end

    return true
end

--- Enables or disables the controller
---@param controller table The controller object
---@param onOff boolean True to enable, false to disable
---@return boolean? success Returns true if successful, nil on error
---@usage SetControllerOnOff(controller, false)
function SetControllerOnOff(controller, onOff)
    if not controller then
        _HarnessInternal.log.error(
            "SetControllerOnOff requires valid controller",
            "Controller.SetOnOff"
        )
        return nil
    end

    if type(onOff) ~= "boolean" then
        _HarnessInternal.log.error(
            "SetControllerOnOff requires boolean value",
            "Controller.SetOnOff"
        )
        return nil
    end

    local success, result = pcall(controller.setOnOff, controller, onOff)
    if not success then
        _HarnessInternal.log.error(
            "Failed to set controller on/off: " .. tostring(result),
            "Controller.SetOnOff"
        )
        return nil
    end

    return true
end

--- Sets the altitude for the controller
---@param controller table The controller object
---@param altitude number The altitude in meters
---@param keep boolean? If true, keep this altitude across waypoints
---@param altType string? Altitude type: "BARO" or "RADIO"
---@return boolean? success Returns true if successful, nil on error
---@usage SetControllerAltitude(controller, 5000, true, "BARO")
function SetControllerAltitude(controller, altitude, keep, altType)
    if not controller then
        _HarnessInternal.log.error(
            "SetControllerAltitude requires valid controller",
            "Controller.SetAltitude"
        )
        return nil
    end

    if not altitude or type(altitude) ~= "number" then
        _HarnessInternal.log.error(
            "SetControllerAltitude requires valid altitude",
            "Controller.SetAltitude"
        )
        return nil
    end

    local success, result = pcall(controller.setAltitude, controller, altitude, keep, altType)
    if not success then
        _HarnessInternal.log.error(
            "Failed to set controller altitude: " .. tostring(result),
            "Controller.SetAltitude"
        )
        return nil
    end

    return true
end

--- Sets the speed for the controller
---@param controller table The controller object
---@param speed number The speed in m/s
---@param keep boolean? If true, keep this speed across waypoints
---@return boolean? success Returns true if successful, nil on error
---@usage SetControllerSpeed(controller, 250, true)
function SetControllerSpeed(controller, speed, keep)
    if not controller then
        _HarnessInternal.log.error(
            "SetControllerSpeed requires valid controller",
            "Controller.SetSpeed"
        )
        return nil
    end

    if not speed or type(speed) ~= "number" then
        _HarnessInternal.log.error("SetControllerSpeed requires valid speed", "Controller.SetSpeed")
        return nil
    end

    local success, result = pcall(controller.setSpeed, controller, speed, keep)
    if not success then
        _HarnessInternal.log.error(
            "Failed to set controller speed: " .. tostring(result),
            "Controller.SetSpeed"
        )
        return nil
    end

    return true
end

--- Sets an option for the controller
---@param controller table The controller object
---@param optionId number The option ID
---@param optionValue any The value to set for the option
---@return boolean? success Returns true if successful, nil on error
---@usage SetControllerOption(controller, 0, AI.Option.Air.val.ROE.WEAPON_FREE)
function SetControllerOption(controller, optionId, optionValue)
    if not controller then
        _HarnessInternal.log.error(
            "SetControllerOption requires valid controller",
            "Controller.SetOption"
        )
        return nil
    end

    if not optionId or type(optionId) ~= "number" then
        _HarnessInternal.log.error(
            "SetControllerOption requires valid option ID",
            "Controller.SetOption"
        )
        return nil
    end

    local success, result = pcall(controller.setOption, controller, optionId, optionValue)
    if not success then
        _HarnessInternal.log.error(
            "Failed to set controller option: " .. tostring(result),
            "Controller.SetOption"
        )
        return nil
    end

    return true
end

--- Convenience setters for common controller options
---@param controller table Controller object
---@param value integer|ROEAir|ROEGround|ROENaval ROE value or name
---@return boolean? success Returns true on success, nil on error
function ControllerSetROE(controller, value)
    local d = _resolveControllerDomain(controller, nil, "Air")
    local opt = AI and AI.Option and AI.Option[d]
    if not opt or not opt.id or not opt.id.ROE then
        _HarnessInternal.log.error(
            "AI.Option." .. d .. ".id.ROE not available",
            "Controller.SetROE"
        )
        return nil
    end
    if type(value) == "string" and opt.val and opt.val.ROE then
        local upper = string.upper(value)
        value = opt.val.ROE[upper]
    end
    if type(value) ~= "number" then
        _HarnessInternal.log.error(
            "ControllerSetROE requires numeric or valid string ROE",
            "Controller.SetROE"
        )
        return nil
    end
    return SetControllerOption(controller, opt.id.ROE, value)
end

--- Set AI reaction on threat
---@param controller table Controller object
---@param value integer|ReactionOnThreat Reaction value or name (e.g. "EVADE_FIRE")
---@return boolean? success Returns true on success, nil on error
function ControllerSetReactionOnThreat(controller, value)
    local opt = AI and AI.Option and AI.Option.Air
    if not opt or not opt.id or not opt.id.REACTION_ON_THREAT then
        _HarnessInternal.log.error(
            "AI.Option.Air.id.REACTION_ON_THREAT not available",
            "Controller.SetReactionOnThreat"
        )
        return nil
    end
    if type(value) == "string" and opt.val and opt.val.REACTION_ON_THREAT then
        local upper = string.upper(value)
        value = opt.val.REACTION_ON_THREAT[upper]
    end
    if type(value) ~= "number" then
        _HarnessInternal.log.error(
            "ControllerSetReactionOnThreat requires numeric or valid string value",
            "Controller.SetReactionOnThreat"
        )
        return nil
    end
    return SetControllerOption(controller, opt.id.REACTION_ON_THREAT, value)
end

--- Set radar usage policy
---@param controller table Controller object
---@param value number Radar usage enum (AI.Option.Air.val.RADAR_USING.*)
---@return boolean? success Returns true on success, nil on error
function ControllerSetRadarUsing(controller, value)
    local opt = AI and AI.Option and AI.Option.Air
    if not opt or not opt.id or not opt.id.RADAR_USING then
        _HarnessInternal.log.error(
            "AI.Option.Air.id.RADAR_USING not available",
            "Controller.SetRadarUsing"
        )
        return nil
    end
    if type(value) ~= "number" then
        _HarnessInternal.log.error(
            "ControllerSetRadarUsing requires numeric enum value",
            "Controller.SetRadarUsing"
        )
        return nil
    end
    return SetControllerOption(controller, opt.id.RADAR_USING, value)
end

--- Set flare usage policy
---@param controller table Controller object
---@param value number Flare usage enum (AI.Option.Air.val.FLARE_USING.*)
---@return boolean? success Returns true on success, nil on error
function ControllerSetFlareUsing(controller, value)
    local opt = AI and AI.Option and AI.Option.Air
    if not opt or not opt.id or not opt.id.FLARE_USING then
        _HarnessInternal.log.error(
            "AI.Option.Air.id.FLARE_USING not available",
            "Controller.SetFlareUsing"
        )
        return nil
    end
    if type(value) ~= "number" then
        _HarnessInternal.log.error(
            "ControllerSetFlareUsing requires numeric enum value",
            "Controller.SetFlareUsing"
        )
        return nil
    end
    return SetControllerOption(controller, opt.id.FLARE_USING, value)
end

--- Set formation
---@param controller table Controller object
---@param value number Formation enum (AI.Option.Air.val.FORMATION.*)
---@return boolean? success Returns true on success, nil on error
function ControllerSetFormation(controller, value)
    local opt = AI and AI.Option and AI.Option.Air
    if not opt or not opt.id or not opt.id.FORMATION then
        _HarnessInternal.log.error(
            "AI.Option.Air.id.FORMATION not available",
            "Controller.SetFormation"
        )
        return nil
    end
    if type(value) ~= "number" then
        _HarnessInternal.log.error(
            "ControllerSetFormation requires numeric enum value",
            "Controller.SetFormation"
        )
        return nil
    end
    return SetControllerOption(controller, opt.id.FORMATION, value)
end

--- Enable/disable RTB on bingo
---@param controller table Controller object
---@param value boolean
---@return boolean? success Returns true on success, nil on error
function ControllerSetRTBOnBingo(controller, value)
    local opt = AI and AI.Option and AI.Option.Air
    if not opt or not opt.id or not opt.id.RTB_ON_BINGO then
        _HarnessInternal.log.error(
            "AI.Option.Air.id.RTB_ON_BINGO not available",
            "Controller.SetRTBOnBingo"
        )
        return nil
    end
    if type(value) ~= "boolean" then
        _HarnessInternal.log.error(
            "ControllerSetRTBOnBingo requires boolean",
            "Controller.SetRTBOnBingo"
        )
        return nil
    end
    return SetControllerOption(controller, opt.id.RTB_ON_BINGO, value)
end

--- Enable/disable radio silence
---@param controller table Controller object
---@param value boolean
---@return boolean? success Returns true on success, nil on error
function ControllerSetSilence(controller, value)
    local opt = AI and AI.Option and AI.Option.Air
    if not opt or not opt.id or not opt.id.SILENCE then
        _HarnessInternal.log.error(
            "AI.Option.Air.id.SILENCE not available",
            "Controller.SetSilence"
        )
        return nil
    end
    if type(value) ~= "boolean" then
        _HarnessInternal.log.error("ControllerSetSilence requires boolean", "Controller.SetSilence")
        return nil
    end
    return SetControllerOption(controller, opt.id.SILENCE, value)
end

--- Set alarm state
---@param controller table Controller object
---@param value integer|AlarmState Alarm state value or name (e.g. "RED")
---@return boolean? success Returns true on success, nil on error
function ControllerSetAlarmState(controller, value)
    local d = _resolveControllerDomain(controller, nil, "Ground")
    local opt = AI and AI.Option and AI.Option[d]
    if not opt or not opt.id or not opt.id.ALARM_STATE then
        _HarnessInternal.log.error(
            "AI.Option." .. d .. ".id.ALARM_STATE not available",
            "Controller.SetAlarmState"
        )
        return nil
    end
    if type(value) == "string" and opt.val and opt.val.ALARM_STATE then
        local upper = string.upper(value)
        value = opt.val.ALARM_STATE[upper]
    end
    if type(value) ~= "number" then
        _HarnessInternal.log.error(
            "ControllerSetAlarmState requires numeric or valid string value",
            "Controller.SetAlarmState"
        )
        return nil
    end
    return SetControllerOption(controller, opt.id.ALARM_STATE, value)
end

--- Enable/disable ground disperse on attack
---@param controller table Controller object
---@param seconds number Dispersal time in seconds (0 disables)
---@return boolean? success Returns true on success, nil on error
---@usage ControllerSetDisperseOnAttack(controller, 120)
function ControllerSetDisperseOnAttack(controller, seconds)
    local opt = AI and AI.Option and AI.Option.Ground
    if not opt or not opt.id or not opt.id.DISPERSE_ON_ATTACK then
        _HarnessInternal.log.error(
            "AI.Option.Ground.id.DISPERSE_ON_ATTACK not available",
            "Controller.SetDisperseOnAttack"
        )
        return nil
    end
    if type(seconds) ~= "number" or seconds < 0 then
        _HarnessInternal.log.error(
            "ControllerSetDisperseOnAttack requires non-negative number of seconds",
            "Controller.SetDisperseOnAttack"
        )
        return nil
    end
    return SetControllerOption(controller, opt.id.DISPERSE_ON_ATTACK, seconds)
end

--- Enable/disable RTB on out of ammo
---@param controller table Controller object
---@param value boolean
---@return boolean? success Returns true on success, nil on error
function ControllerSetRTBOnOutOfAmmo(controller, value)
    local opt = AI and AI.Option and AI.Option.Air
    if not opt or not opt.id or not opt.id.RTB_ON_OUT_OF_AMMO then
        _HarnessInternal.log.error(
            "AI.Option.Air.id.RTB_ON_OUT_OF_AMMO not available",
            "Controller.SetRTBOnOutOfAmmo"
        )
        return nil
    end
    if type(value) ~= "boolean" then
        _HarnessInternal.log.error(
            "ControllerSetRTBOnOutOfAmmo requires boolean",
            "Controller.SetRTBOnOutOfAmmo"
        )
        return nil
    end
    return SetControllerOption(controller, opt.id.RTB_ON_OUT_OF_AMMO, value)
end

--- Set ECM usage policy
---@param controller table Controller object
---@param value number ECM usage enum (AI.Option.Air.val.ECM_USING.*)
---@return boolean? success Returns true on success, nil on error
function ControllerSetECMUsing(controller, value)
    local opt = AI and AI.Option and AI.Option.Air
    if not opt or not opt.id or not opt.id.ECM_USING then
        _HarnessInternal.log.error(
            "AI.Option.Air.id.ECM_USING not available",
            "Controller.SetECMUsing"
        )
        return nil
    end
    if type(value) ~= "number" then
        _HarnessInternal.log.error(
            "ControllerSetECMUsing requires numeric enum value",
            "Controller.SetECMUsing"
        )
        return nil
    end
    return SetControllerOption(controller, opt.id.ECM_USING, value)
end

--- Enable/disable waypoint pass report (ID 14)
---@param controller table Controller object
---@param value boolean
---@return boolean? success Returns true on success, nil on error
function ControllerSetProhibitWPPassReport(controller, value)
    local opt = AI and AI.Option and AI.Option.Air
    if not opt or not opt.id or not opt.id.PROHIBIT_WP_PASS_REPORT then
        _HarnessInternal.log.error(
            "AI.Option.Air.id.PROHIBIT_WP_PASS_REPORT not available",
            "Controller.SetProhibitWPPassReport"
        )
        return nil
    end
    if type(value) ~= "boolean" then
        _HarnessInternal.log.error(
            "ControllerSetProhibitWPPassReport requires boolean",
            "Controller.SetProhibitWPPassReport"
        )
        return nil
    end
    return SetControllerOption(controller, opt.id.PROHIBIT_WP_PASS_REPORT, value)
end

--- Enable/disable prohibit air-to-air
---@param controller table Controller object
---@param value boolean
---@return boolean? success Returns true on success, nil on error
function ControllerSetProhibitAA(controller, value)
    local opt = AI and AI.Option and AI.Option.Air
    if not opt or not opt.id or not opt.id.PROHIBIT_AA then
        _HarnessInternal.log.error(
            "AI.Option.Air.id.PROHIBIT_AA not available",
            "Controller.SetProhibitAA"
        )
        return nil
    end
    if type(value) ~= "boolean" then
        _HarnessInternal.log.error(
            "ControllerSetProhibitAA requires boolean",
            "Controller.SetProhibitAA"
        )
        return nil
    end
    return SetControllerOption(controller, opt.id.PROHIBIT_AA, value)
end

--- Enable/disable prohibit jettison
---@param controller table Controller object
---@param value boolean
---@return boolean? success Returns true on success, nil on error
function ControllerSetProhibitJettison(controller, value)
    local opt = AI and AI.Option and AI.Option.Air
    if not opt or not opt.id or not opt.id.PROHIBIT_JETT then
        _HarnessInternal.log.error(
            "AI.Option.Air.id.PROHIBIT_JETT not available",
            "Controller.SetProhibitJettison"
        )
        return nil
    end
    if type(value) ~= "boolean" then
        _HarnessInternal.log.error(
            "ControllerSetProhibitJettison requires boolean",
            "Controller.SetProhibitJettison"
        )
        return nil
    end
    return SetControllerOption(controller, opt.id.PROHIBIT_JETT, value)
end

--- Enable/disable prohibit afterburner
---@param controller table Controller object
---@param value boolean
---@return boolean? success Returns true on success, nil on error
function ControllerSetProhibitAB(controller, value)
    local opt = AI and AI.Option and AI.Option.Air
    if not opt or not opt.id or not opt.id.PROHIBIT_AB then
        _HarnessInternal.log.error(
            "AI.Option.Air.id.PROHIBIT_AB not available",
            "Controller.SetProhibitAB"
        )
        return nil
    end
    if type(value) ~= "boolean" then
        _HarnessInternal.log.error(
            "ControllerSetProhibitAB requires boolean",
            "Controller.SetProhibitAB"
        )
        return nil
    end
    return SetControllerOption(controller, opt.id.PROHIBIT_AB, value)
end

--- Enable/disable prohibit air-to-ground
---@param controller table Controller object
---@param value boolean
---@return boolean? success Returns true on success, nil on error
function ControllerSetProhibitAG(controller, value)
    local opt = AI and AI.Option and AI.Option.Air
    if not opt or not opt.id or not opt.id.PROHIBIT_AG then
        _HarnessInternal.log.error(
            "AI.Option.Air.id.PROHIBIT_AG not available",
            "Controller.SetProhibitAG"
        )
        return nil
    end
    if type(value) ~= "boolean" then
        _HarnessInternal.log.error(
            "ControllerSetProhibitAG requires boolean",
            "Controller.SetProhibitAG"
        )
        return nil
    end
    return SetControllerOption(controller, opt.id.PROHIBIT_AG, value)
end

--- Set missile attack policy
---@param controller table Controller object
---@param value integer|MissileAttackMode Missile attack enum or name
---@return boolean? success Returns true on success, nil on error
---@usage ControllerSetMissileAttack(controller, "NEZ_RANGE")
function ControllerSetMissileAttack(controller, value)
    local opt = AI and AI.Option and AI.Option.Air
    if not opt or not opt.id or not opt.id.MISSILE_ATTACK then
        _HarnessInternal.log.error(
            "AI.Option.Air.id.MISSILE_ATTACK not available",
            "Controller.SetMissileAttack"
        )
        return nil
    end
    if type(value) == "string" and opt.val and opt.val.MISSILE_ATTACK then
        local upper = string.upper(value)
        value = opt.val.MISSILE_ATTACK[upper]
    end
    if type(value) ~= "number" then
        _HarnessInternal.log.error(
            "ControllerSetMissileAttack requires numeric or valid string enum value",
            "Controller.SetMissileAttack"
        )
        return nil
    end
    return SetControllerOption(controller, opt.id.MISSILE_ATTACK, value)
end

-- Removed unsupported options in current DCS builds: PROHIBIT_WP_PASS_REPORT2, DISPERSAL_ON_ATTACK

--- Gets targets detected by the controller
---@param controller table The controller object
---@param detectionType any? Optional detection type filter
---@param categoryFilter any? Optional category filter
---@return table? targets Array of detected target objects or nil on error
---@usage local targets = getControllerDetectedTargets(controller)
function GetControllerDetectedTargets(controller, detectionType, categoryFilter)
    if not controller then
        _HarnessInternal.log.error(
            "GetControllerDetectedTargets requires valid controller",
            "Controller.GetDetectedTargets"
        )
        return nil
    end

    local success, result =
        pcall(controller.getDetectedTargets, controller, detectionType, categoryFilter)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get detected targets: " .. tostring(result),
            "Controller.GetDetectedTargets"
        )
        return nil
    end

    return result
end

--- Makes the controller aware of a target
---@param controller table The controller object
---@param target table The target object
---@param typeKnown boolean? Whether the target type is known
---@param distanceKnown boolean? Whether the target distance is known
---@return boolean? success Returns true if successful, nil on error
---@usage KnowControllerTarget(controller, targetUnit, true, true)
function KnowControllerTarget(controller, target, typeKnown, distanceKnown)
    if not controller then
        _HarnessInternal.log.error(
            "KnowControllerTarget requires valid controller",
            "Controller.KnowTarget"
        )
        return nil
    end

    if not target then
        _HarnessInternal.log.error(
            "KnowControllerTarget requires valid target",
            "Controller.KnowTarget"
        )
        return nil
    end

    local success, result =
        pcall(controller.knowTarget, controller, target, typeKnown, distanceKnown)
    if not success then
        _HarnessInternal.log.error(
            "Failed to know target: " .. tostring(result),
            "Controller.KnowTarget"
        )
        return nil
    end

    return true
end

--- Checks if a target is detected by the controller
---@param controller table The controller object
---@param target table The target object to check
---@param detectionType any? Optional detection type
---@return boolean? isDetected Returns detection status or nil on error
---@usage local detected = isControllerTargetDetected(controller, targetUnit)
function IsControllerTargetDetected(controller, target, detectionType)
    if not controller then
        _HarnessInternal.log.error(
            "IsControllerTargetDetected requires valid controller",
            "Controller.IsTargetDetected"
        )
        return nil
    end

    if not target then
        _HarnessInternal.log.error(
            "IsControllerTargetDetected requires valid target",
            "Controller.IsTargetDetected"
        )
        return nil
    end

    local success, result = pcall(controller.isTargetDetected, controller, target, detectionType)
    if not success then
        _HarnessInternal.log.error(
            "Failed to check target detection: " .. tostring(result),
            "Controller.IsTargetDetected"
        )
        return nil
    end

    return result
end

--- Build an AI.Option task entry for Air domain
--- @param optionId number AI.Option.Air.id.* value
--- @param value number|boolean Enum or boolean as required by option
--- @return table taskEntry Option task entry suitable for waypoint ComboTask
function BuildAirOptionTask(optionId, value)
    return {
        id = "Option",
        params = {
            enable = true,
            name = optionId,
            value = value,
            variantIndex = 0,
        },
    }
end

--- Build an AI.Option task entry for Ground domain
--- @param optionId number AI.Option.Ground.id.* value
--- @param value number|boolean Enum or boolean as required by option
--- @return table taskEntry Option task entry suitable for waypoint ComboTask
function BuildGroundOptionTask(optionId, value)
    return {
        id = "Option",
        params = {
            enable = true,
            name = optionId,
            value = value,
            variantIndex = 0,
        },
    }
end

--- Build an AI.Option task entry for Naval domain
--- @param optionId number AI.Option.Naval.id.* value
--- @param value number|boolean Enum or boolean as required by option
--- @return table taskEntry Option task entry suitable for waypoint ComboTask
function BuildNavalOptionTask(optionId, value)
    return {
        id = "Option",
        params = {
            enable = true,
            name = optionId,
            value = value,
            variantIndex = 0,
        },
    }
end

--- Build a standard set of Air AI options as an array of Option tasks
--- @param overrides table|nil Optional overrides by key (e.g., { ROE = "WEAPON_FREE", RADAR_USING = 1 })
--- @return table tasks Array of Option task tables
function BuildAirOptions(overrides)
    local opt = AI and AI.Option and AI.Option.Air
    local val = opt and opt.val or {}
    local id = opt and opt.id or {}
    local o = overrides or {}

    local function mapVal(tbl, key, v)
        if tbl and tbl[key] and type(v) == "string" then
            local upper = string.upper(v)
            return tbl[key][upper]
        end
        return v
    end

    local tasks = {}
    -- ROE
    local roe = mapVal(val, "ROE", o.ROE) or (val.ROE and val.ROE.RETURN_FIRE) or 3
    if id and id.ROE then
        table.insert(tasks, BuildAirOptionTask(id.ROE, roe))
    end
    -- Reaction on threat
    local rot = mapVal(val, "REACTION_ON_THREAT", o.REACTION_ON_THREAT)
        or (val.REACTION_ON_THREAT and val.REACTION_ON_THREAT.EVADE_FIRE)
        or 2
    if id and id.REACTION_ON_THREAT then
        table.insert(tasks, BuildAirOptionTask(id.REACTION_ON_THREAT, rot))
    end
    -- Radar using
    local radar = o.RADAR_USING or 1
    if id and id.RADAR_USING then
        table.insert(tasks, BuildAirOptionTask(id.RADAR_USING, radar))
    end
    -- Flare using
    local flare = o.FLARE_USING or 1
    if id and id.FLARE_USING then
        table.insert(tasks, BuildAirOptionTask(id.FLARE_USING, flare))
    end
    -- Formation (leave nil unless provided)
    if o.FORMATION and id and id.FORMATION then
        table.insert(tasks, BuildAirOptionTask(id.FORMATION, o.FORMATION))
    end
    -- RTB policies
    local rtbBingo = (o.RTB_ON_BINGO ~= nil) and o.RTB_ON_BINGO or true
    if id and id.RTB_ON_BINGO then
        table.insert(tasks, BuildAirOptionTask(id.RTB_ON_BINGO, rtbBingo))
    end
    local rtbAmmo = (o.RTB_ON_OUT_OF_AMMO ~= nil) and o.RTB_ON_OUT_OF_AMMO or true
    if id and id.RTB_ON_OUT_OF_AMMO then
        table.insert(tasks, BuildAirOptionTask(id.RTB_ON_OUT_OF_AMMO, rtbAmmo))
    end
    -- Silence/ECM
    local silence = (o.SILENCE ~= nil) and o.SILENCE or false
    if id and id.SILENCE then
        table.insert(tasks, BuildAirOptionTask(id.SILENCE, silence))
    end
    local ecm = o.ECM_USING or 0
    if id and id.ECM_USING then
        table.insert(tasks, BuildAirOptionTask(id.ECM_USING, ecm))
    end
    -- Alarm state (optional for Air)
    if o.ALARM_STATE and id and id.ALARM_STATE then
        local alarm = mapVal(val, "ALARM_STATE", o.ALARM_STATE)
        if alarm ~= nil then
            table.insert(tasks, BuildAirOptionTask(id.ALARM_STATE, alarm))
        end
    end
    -- Prohibits
    if id and id.PROHIBIT_AA then
        table.insert(
            tasks,
            BuildAirOptionTask(id.PROHIBIT_AA, (o.PROHIBIT_AA ~= nil) and o.PROHIBIT_AA or false)
        )
    end
    if id and id.PROHIBIT_AB then
        table.insert(
            tasks,
            BuildAirOptionTask(id.PROHIBIT_AB, (o.PROHIBIT_AB ~= nil) and o.PROHIBIT_AB or false)
        )
    end
    if id and id.PROHIBIT_JETT then
        table.insert(
            tasks,
            BuildAirOptionTask(
                id.PROHIBIT_JETT,
                (o.PROHIBIT_JETT ~= nil) and o.PROHIBIT_JETT or false
            )
        )
    end
    if id and id.PROHIBIT_AG then
        table.insert(
            tasks,
            BuildAirOptionTask(id.PROHIBIT_AG, (o.PROHIBIT_AG ~= nil) and o.PROHIBIT_AG or false)
        )
    end
    -- Missile attack policy
    local ma = mapVal(val, "MISSILE_ATTACK", o.MISSILE_ATTACK)
        or (val.MISSILE_ATTACK and val.MISSILE_ATTACK.NEZ_RANGE)
        or 1
    if id and id.MISSILE_ATTACK then
        table.insert(tasks, BuildAirOptionTask(id.MISSILE_ATTACK, ma))
    end

    return tasks
end

--- Build a standard set of Ground AI options as an array of Option tasks
--- @param overrides table|nil Optional overrides (e.g., { ROE = "OPEN_FIRE", ALARM_STATE = "GREEN", DISPERSE_ON_ATTACK = 120 })
--- @return table tasks Array of Option task tables
function BuildGroundOptions(overrides)
    local opt = AI and AI.Option and AI.Option.Ground
    local val = opt and opt.val or {}
    local id = opt and opt.id or {}
    local o = overrides or {}

    local function mapVal(tbl, key, v)
        if tbl and tbl[key] and type(v) == "string" then
            local upper = string.upper(v)
            return tbl[key][upper]
        end
        return v
    end

    local tasks = {}
    -- ROE
    local roe = mapVal(val, "ROE", o.ROE) or (val.ROE and val.ROE.RETURN_FIRE) or 3
    if id and id.ROE then
        table.insert(tasks, BuildGroundOptionTask(id.ROE, roe))
    end
    -- Alarm State
    local alarm = mapVal(val, "ALARM_STATE", o.ALARM_STATE)
        or (val.ALARM_STATE and val.ALARM_STATE.AUTO)
        or 0
    if id and id.ALARM_STATE then
        table.insert(tasks, BuildGroundOptionTask(id.ALARM_STATE, alarm))
    end
    -- Disperse on attack (seconds)
    local disperse = o.DISPERSE_ON_ATTACK or 0
    if id and id.DISPERSE_ON_ATTACK then
        table.insert(tasks, BuildGroundOptionTask(id.DISPERSE_ON_ATTACK, disperse))
    end

    return tasks
end

--- Build a standard set of Naval AI options as an array of Option tasks
--- @param overrides table|nil Optional overrides (e.g., { ROE = "OPEN_FIRE" })
--- @return table tasks Array of Option task tables
function BuildNavalOptions(overrides)
    local opt = AI and AI.Option and AI.Option.Naval
    local val = opt and opt.val or {}
    local id = opt and opt.id or {}
    local o = overrides or {}

    local function mapVal(tbl, key, v)
        if tbl and tbl[key] and type(v) == "string" then
            local upper = string.upper(v)
            return tbl[key][upper]
        end
        return v
    end

    local tasks = {}
    local roe = mapVal(val, "ROE", o.ROE) or (val.ROE and val.ROE.RETURN_FIRE) or 3
    if id and id.ROE then
        table.insert(tasks, BuildNavalOptionTask(id.ROE, roe))
    end
    return tasks
end

--- Creates an orbit task for aircraft
---@param pattern string? Orbit pattern (default: "Circle")
---@param point table Position to orbit around
---@param altitude number Orbit altitude in meters
---@param speed number Orbit speed in m/s
---@param taskParams table? Additional task parameters
---@return table task The orbit task table
---@usage local task = createOrbitTask("Circle", {x=1000, y=0, z=2000}, 5000, 250)
function CreateOrbitTask(pattern, point, altitude, speed, taskParams)
    local task = {
        id = "Orbit",
        params = {
            pattern = pattern or "Circle",
            point = point,
            altitude = altitude,
            speed = speed,
        },
    }

    if taskParams then
        for k, v in pairs(taskParams) do
            task.params[k] = v
        end
    end

    return task
end

--- Creates a follow task to follow another group
---@param groupId number The ID of the group to follow
---@param position table? Relative position offset (default: {x=50, y=0, z=50})
---@param lastWaypointIndex number? Last waypoint index to follow to
---@return table? task The follow task table or nil on error
---@usage local task = createFollowTask(1001, {x=100, y=0, z=100})
function CreateFollowTask(groupId, position, lastWaypointIndex)
    if not groupId then
        _HarnessInternal.log.error(
            "CreateFollowTask requires valid group ID",
            "Controller.CreateFollowTask"
        )
        return nil
    end

    local task = {
        id = "follow",
        params = {
            groupId = groupId,
            pos = position or { x = 50, y = 0, z = 50 },
            lastWptIndexFlag = lastWaypointIndex ~= nil,
            lastWptIndex = lastWaypointIndex,
        },
    }

    return task
end

--- Creates an escort task to escort another group
---@param groupId number The ID of the group to escort
---@param position table? Relative position offset (default: {x=50, y=0, z=50})
---@param lastWaypointIndex number? Last waypoint index to escort to
---@param engagementDistance number? Maximum engagement distance (default: 60000)
---@return table? task The escort task table or nil on error
---@usage local task = createEscortTask(1001, {x=200, y=0, z=0}, nil, 30000)
function CreateEscortTask(groupId, position, lastWaypointIndex, engagementDistance)
    if not groupId then
        _HarnessInternal.log.error(
            "CreateEscortTask requires valid group ID",
            "Controller.CreateEscortTask"
        )
        return nil
    end

    local task = {
        id = "escort",
        params = {
            groupId = groupId,
            pos = position or { x = 50, y = 0, z = 50 },
            lastWptIndexFlag = lastWaypointIndex ~= nil,
            lastWptIndex = lastWaypointIndex,
            engagementDistMax = engagementDistance or 60000,
        },
    }

    return task
end

--- Creates an attack group task
---@param groupId number The ID of the group to attack
---@param weaponType any? Weapon type to use
---@param groupAttack boolean? Whether to attack as a group (default: true)
---@param altitude number? Attack altitude
---@param attackQty number? Number of attacks
---@param direction number? Attack direction
---@return table? task The attack group task table or nil on error
---@usage local task = createAttackGroupTask(2001, nil, true)
function CreateAttackGroupTask(groupId, weaponType, groupAttack, altitude, attackQty, direction)
    if not groupId then
        _HarnessInternal.log.error(
            "CreateAttackGroupTask requires valid group ID",
            "Controller.CreateAttackGroupTask"
        )
        return nil
    end

    local task = {
        id = "AttackGroup",
        params = {
            groupId = groupId,
            weaponType = weaponType,
            groupAttack = (groupAttack == nil) and true or groupAttack,
            altitude = altitude,
            attackQty = attackQty,
            direction = direction,
        },
    }

    return task
end

--- Creates an attack unit task
---@param unitId number The ID of the unit to attack
---@param weaponType any? Weapon type to use
---@param groupAttack boolean? Whether to attack as a group (default: false)
---@param altitude number? Attack altitude
---@param attackQty number? Number of attacks
---@param direction number? Attack direction
---@return table? task The attack unit task table or nil on error
---@usage local task = createAttackUnitTask(3001)
function CreateAttackUnitTask(unitId, weaponType, groupAttack, altitude, attackQty, direction)
    if not unitId then
        _HarnessInternal.log.error(
            "CreateAttackUnitTask requires valid unit ID",
            "Controller.CreateAttackUnitTask"
        )
        return nil
    end

    local task = {
        id = "AttackUnit",
        params = {
            unitId = unitId,
            weaponType = weaponType,
            groupAttack = groupAttack or false,
            altitude = altitude,
            attackQty = attackQty,
            direction = direction,
        },
    }

    return task
end

--- Creates a bombing task for a specific point
---@param point table Target position with x, y, z coordinates
---@param weaponType any? Weapon type to use
---@param groupAttack boolean? Whether to attack as a group (default: false)
---@param altitude number? Attack altitude
---@param attackQty number? Number of attacks
---@param direction number? Attack direction
---@return table? task The bombing task table or nil on error
---@usage local task = createBombingTask({x=1000, y=0, z=2000})
function CreateBombingTask(point, weaponType, groupAttack, altitude, attackQty, direction)
    if not point or type(point) ~= "table" or not point.x or not point.y or not point.z then
        _HarnessInternal.log.error(
            "CreateBombingTask requires valid point with x, y, z",
            "Controller.CreateBombingTask"
        )
        return nil
    end

    local task = {
        id = "Bombing",
        params = {
            point = point,
            weaponType = weaponType,
            groupAttack = groupAttack or false,
            altitude = altitude,
            attackQty = attackQty,
            direction = direction,
        },
    }

    return task
end

--- Creates a bombing runway task
---@param runwayId number The runway ID to attack
---@param weaponType any? Weapon type to use
---@param groupAttack boolean? Whether to attack as a group (default: false)
---@param altitude number? Attack altitude
---@param attackQty number? Number of attacks
---@param direction number? Attack direction
---@return table? task The bombing runway task table or nil on error
---@usage local task = createBombingRunwayTask(1)
function CreateBombingRunwayTask(runwayId, weaponType, groupAttack, altitude, attackQty, direction)
    if not runwayId then
        _HarnessInternal.log.error(
            "CreateBombingRunwayTask requires valid runway ID",
            "Controller.CreateBombingRunwayTask"
        )
        return nil
    end

    local task = {
        id = "BombingRunway",
        params = {
            runwayId = runwayId,
            weaponType = weaponType,
            groupAttack = groupAttack or false,
            altitude = altitude,
            attackQty = attackQty,
            direction = direction,
        },
    }

    return task
end

--- Creates a land task at a specific point
---@param point table Landing position with x, y, z coordinates
---@param durationFlag boolean? Whether to use duration (default: false)
---@param duration number? Duration of landing in seconds
---@return table? task The land task table or nil on error
---@usage local task = createLandTask({x=1000, y=0, z=2000}, true, 300)
function CreateLandTask(point, durationFlag, duration)
    if not point or type(point) ~= "table" or not point.x or not point.y or not point.z then
        _HarnessInternal.log.error(
            "createLandTask requires valid point with x, y, z",
            "Controller.CreateLandTask"
        )
        return nil
    end

    local task = {
        id = "land",
        params = {
            point = point,
            durationFlag = durationFlag or false,
            duration = duration,
        },
    }

    return task
end

--- Creates a refueling task
---@return table task The refueling task table
---@usage local task = createRefuelingTask()
function CreateRefuelingTask()
    local task = {
        id = "refueling",
        params = {},
    }

    return task
end

--- Creates a Forward Air Controller (FAC) attack group task
---@param groupId number The ID of the group to designate for attack
---@param priority number? Task priority
---@param designation any? Designation type
---@param datalink boolean? Whether to use datalink
---@param frequency number? Radio frequency
---@param modulation number? Radio modulation
---@param callsign number? Callsign number
---@return table? task The FAC attack group task table or nil on error
---@usage local task = createFACAttackGroupTask(2001)
function CreateFACAttackGroupTask(
    groupId,
    priority,
    designation,
    datalink,
    frequency,
    modulation,
    callsign
)
    if not groupId then
        _HarnessInternal.log.error(
            "createFACAttackGroupTask requires valid group ID",
            "Controller.CreateFACAttackGroupTask"
        )
        return nil
    end

    local task = {
        id = "FAC_AttackGroup",
        params = {
            groupId = groupId,
            priority = priority,
            designation = designation,
            datalink = datalink,
            frequency = frequency,
            modulation = modulation,
            callsign = callsign,
        },
    }

    return task
end

--- Creates a fire at point task for artillery or naval units
---@param point table Target position with x, y, z coordinates
---@param radius number? Radius of fire area (default: 50)
---@param expendQty number? Quantity to expend
---@param expendQtyEnabled boolean? Whether to limit quantity (default: false)
---@param altitude number? Altitude for indirect fire
---@param altitudeEnabled boolean? Whether to use altitude
---@return table? task The fire at point task table or nil on error
---@usage local task = createFireAtPointTask({x=1000, y=0, z=2000}, 100)
function CreateFireAtPointTask(
    point,
    radius,
    expendQty,
    expendQtyEnabled,
    altitude,
    altitudeEnabled
)
    if not point or type(point) ~= "table" or not point.x or not point.y or not point.z then
        _HarnessInternal.log.error(
            "createFireAtPointTask requires valid point with x, y, z",
            "Controller.CreateFireAtPointTask"
        )
        return nil
    end

    local task = {
        id = "fireAtPoint",
        params = {
            point = point,
            radius = radius or 50,
            expendQty = expendQty,
            expendQtyEnabled = expendQtyEnabled or false,
            altitude = altitude,
            alt_type = altitudeEnabled and 1 or 0,
        },
    }

    return task
end

--- Creates a hold task
---@param template any? Template for holding pattern
---@return table task The hold task table
---@usage local task = createHoldTask()
function CreateHoldTask(template)
    local task = {
        id = "Hold",
        params = {
            templateFlag = template ~= nil,
            template = template,
        },
    }

    return task
end

--- Creates a go to waypoint task
---@param fromWaypointIndex number Starting waypoint index
---@param toWaypointIndex number Destination waypoint index
---@return table task The go to waypoint task table
---@usage local task = createGoToWaypointTask(1, 5)
function CreateGoToWaypointTask(fromWaypointIndex, toWaypointIndex)
    local task = {
        id = "goToWaypoint",
        params = {
            fromWaypointIndex = fromWaypointIndex,
            goToWaypointIndex = toWaypointIndex,
        },
    }

    return task
end

--- Creates a wrapped action task
---@param action table The action table to wrap
---@param stopFlag boolean? Whether to stop after action (default: false)
---@return table? task The wrapped action task table or nil on error
---@usage local task = createWrappedAction({id="Script", params={...}})
function CreateWrappedAction(action, stopFlag)
    if not action or type(action) ~= "table" then
        _HarnessInternal.log.error(
            "createWrappedAction requires valid action table",
            "Controller.CreateWrappedAction"
        )
        return nil
    end

    local task = {
        id = "WrappedAction",
        params = {
            action = action,
            stopFlag = stopFlag or false,
        },
    }

    return task
end
-- ==== END: src/controller.lua ====

-- ==== BEGIN: src/conversion.lua ====
--[[
==================================================================================================
    CONVERSION MODULE
    Unit conversion helpers with strict validation and predictable behavior
==================================================================================================
]]

-- Internal safe number parser
local function toNumberOrNil(value)
    if type(value) == "number" then
        return value
    end
    if type(value) == "string" then
        local n = tonumber(value)
        return n
    end
    return nil
end

--[[
Temperature conversions
]]

--- Convert Celsius to Kelvin
---@param c number|string
---@return number
function CtoK(c)
    local n = toNumberOrNil(c)
    if n == nil then
        _HarnessInternal.log.error("CtoK requires number", "Conversion.CtoK")
        return 0
    end
    return n + 273.15
end

--- Convert Kelvin to Celsius
---@param k number|string
---@return number
function KtoC(k)
    local n = toNumberOrNil(k)
    if n == nil then
        _HarnessInternal.log.error("KtoC requires number", "Conversion.KtoC")
        return 0
    end
    return n - 273.15
end

--- Convert Celsius to Fahrenheit
---@param c number|string
---@return number
function CtoF(c)
    local n = toNumberOrNil(c)
    if n == nil then
        _HarnessInternal.log.error("CtoF requires number", "Conversion.CtoF")
        return 0
    end
    return (n * 9 / 5) + 32
end

--- Convert Fahrenheit to Celsius
---@param f number|string
---@return number
function FtoC(f)
    local n = toNumberOrNil(f)
    if n == nil then
        _HarnessInternal.log.error("FtoC requires number", "Conversion.FtoC")
        return 0
    end
    return (n - 32) * 5 / 9
end

--- Convert Kelvin to Fahrenheit
---@param k number|string
---@return number
function KtoF(k)
    return CtoF(KtoC(k))
end

--- Convert Fahrenheit to Kelvin
---@param f number|string
---@return number
function FtoK(f)
    return CtoK(FtoC(f))
end

--[[
Pressure conversions
]]

--- Pascals to inches of mercury
---@param pa number|string
---@return number
function PaToInHg(pa)
    local n = toNumberOrNil(pa)
    if n == nil then
        _HarnessInternal.log.error("PaToInHg requires number", "Conversion.PaToInHg")
        return 0
    end
    return n / 3386.389
end

--- inches of mercury to Pascals
---@param inHg number|string
---@return number
function InHgToPa(inHg)
    local n = toNumberOrNil(inHg)
    if n == nil then
        _HarnessInternal.log.error("InHgToPa requires number", "Conversion.InHgToPa")
        return 0
    end
    return n * 3386.389
end

--- Pascals to hectoPascals
---@param pa number|string
---@return number
function PaTohPa(pa)
    local n = toNumberOrNil(pa)
    if n == nil then
        _HarnessInternal.log.error("PaTohPa requires number", "Conversion.PaTohPa")
        return 0
    end
    return n / 100.0
end

--- hectoPascals to Pascals
---@param hPa number|string
---@return number
function hPaToPa(hPa)
    local n = toNumberOrNil(hPa)
    if n == nil then
        _HarnessInternal.log.error("hPaToPa requires number", "Conversion.hPaToPa")
        return 0
    end
    return n * 100.0
end

--[[
Distance / altitude
]]

--- Meters to Feet
---@param m number|string
---@return number
function MetersToFeet(m)
    local n = toNumberOrNil(m)
    if n == nil then
        _HarnessInternal.log.error("MetersToFeet requires number", "Conversion.MetersToFeet")
        return 0
    end
    return n * 3.280839895
end

--- Feet to Meters
---@param ft number|string
---@return number
function FeetToMeters(ft)
    local n = toNumberOrNil(ft)
    if n == nil then
        _HarnessInternal.log.error("FeetToMeters requires number", "Conversion.FeetToMeters")
        return 0
    end
    return n / 3.280839895
end

--[[
Speed
]]

--- Meters per second to Knots
---@param mps number|string
---@return number
function MpsToKnots(mps)
    local n = toNumberOrNil(mps)
    if n == nil then
        _HarnessInternal.log.error("MpsToKnots requires number", "Conversion.MpsToKnots")
        return 0
    end
    return n * 1.943844492
end

--- Knots to meters per second
---@param knots number|string
---@return number
function KnotsToMps(knots)
    local n = toNumberOrNil(knots)
    if n == nil then
        _HarnessInternal.log.error("KnotsToMps requires number", "Conversion.KnotsToMps")
        return 0
    end
    return n / 1.943844492
end

--- Airspeed (IAS) helper in knots to meters per second
---@param knots number|string
---@return number
function GetSpeedIAS(knots)
    return KnotsToMps(knots)
end

--[[
Generic helpers for UI / Getters
]]

--- Convert temperature value from one unit to another
---@param value number|string
---@param from string one of: "C","F","K"
---@param to string one of: "C","F","K"
---@return number
function ConvertTemperature(value, from, to)
    local f = string.upper(tostring(from or ""))
    local t = string.upper(tostring(to or ""))
    if f == t then
        return toNumberOrNil(value) or 0
    end
    if f == "C" and t == "F" then
        return CtoF(value)
    elseif f == "F" and t == "C" then
        return FtoC(value)
    elseif f == "C" and t == "K" then
        return CtoK(value)
    elseif f == "K" and t == "C" then
        return KtoC(value)
    elseif f == "F" and t == "K" then
        return FtoK(value)
    elseif f == "K" and t == "F" then
        return KtoF(value)
    end
    _HarnessInternal.log.error("ConvertTemperature invalid units", "Conversion.ConvertTemperature")
    return 0
end

--- Convert pressure value from one unit to another
---@param value number|string
---@param from string one of: "Pa","hPa","inHg"
---@param to string one of: "Pa","hPa","inHg"
---@return number
function ConvertPressure(value, from, to)
    local f = string.upper(tostring(from or ""))
    local t = string.upper(tostring(to or ""))
    if f == t then
        return toNumberOrNil(value) or 0
    end
    if f == "PA" and t == "INHG" then
        return PaToInHg(value)
    elseif f == "INHG" and t == "PA" then
        return InHgToPa(value)
    elseif f == "PA" and t == "HPA" then
        return PaTohPa(value)
    elseif f == "HPA" and t == "PA" then
        return hPaToPa(value)
    elseif f == "HPA" and t == "INHG" then
        return PaToInHg(hPaToPa(value))
    elseif f == "INHG" and t == "HPA" then
        return PaTohPa(InHgToPa(value))
    end
    _HarnessInternal.log.error("ConvertPressure invalid units", "Conversion.ConvertPressure")
    return 0
end

--- Convert distance/altitude value from one unit to another
---@param value number|string
---@param from string one of: "m","ft"
---@param to string one of: "m","ft"
---@return number
function ConvertDistance(value, from, to)
    local f = string.lower(tostring(from or ""))
    local t = string.lower(tostring(to or ""))
    if f == t then
        return toNumberOrNil(value) or 0
    end
    if f == "m" and t == "ft" then
        return MetersToFeet(value)
    elseif f == "ft" and t == "m" then
        return FeetToMeters(value)
    end
    _HarnessInternal.log.error("ConvertDistance invalid units", "Conversion.ConvertDistance")
    return 0
end

--- Convert speed value from one unit to another
---@param value number|string
---@param from string one of: "mps","knots"
---@param to string one of: "mps","knots"
---@return number
function ConvertSpeed(value, from, to)
    local f = string.lower(tostring(from or ""))
    local t = string.lower(tostring(to or ""))
    if f == t then
        return toNumberOrNil(value) or 0
    end
    if f == "mps" and t == "knots" then
        return MpsToKnots(value)
    elseif f == "knots" and t == "mps" then
        return KnotsToMps(value)
    end
    _HarnessInternal.log.error("ConvertSpeed invalid units", "Conversion.ConvertSpeed")
    return 0
end
-- ==== END: src/conversion.lua ====

-- ==== BEGIN: src/flag.lua ====
--[[
==================================================================================================
    FLAG MODULE
    User flag utilities
==================================================================================================
]]
--- Get flag value
---@param flagName string? Name of the flag
---@return number value Flag value (0 if not found or error)
---@usage local value = GetFlag("myFlag")
function GetFlag(flagName)
    if not flagName then
        _HarnessInternal.log.error("GetFlag requires flag name", "GetFlag")
        return 0
    end

    local success, value = pcall(trigger.misc.getUserFlag, flagName)
    if not success then
        _HarnessInternal.log.error("Failed to get flag: " .. tostring(value), "GetFlag")
        return 0
    end

    return value
end

--- Set flag value
---@param flagName string? Name of the flag
---@param value number? Value to set (default 1)
---@return boolean success True if set successfully
---@usage SetFlag("myFlag", 5)
function SetFlag(flagName, value)
    if not flagName then
        _HarnessInternal.log.error("SetFlag requires flag name", "SetFlag")
        return false
    end

    value = value or 1

    local success, result = pcall(trigger.action.setUserFlag, flagName, value)
    if not success then
        _HarnessInternal.log.error("Failed to set flag: " .. tostring(result), "SetFlag")
        return false
    end

    return true
end

--- Increment flag value
---@param flagName string Name of the flag
---@param amount number? Amount to increment (default 1)
---@return boolean success True if incremented successfully
---@usage IncFlag("counter", 5)
function IncFlag(flagName, amount)
    amount = amount or 1

    local currentValue = GetFlag(flagName)
    return SetFlag(flagName, currentValue + amount)
end

--- Decrement flag value
---@param flagName string Name of the flag
---@param amount number? Amount to decrement (default 1)
---@return boolean success True if decremented successfully
---@usage DecFlag("counter", 2)
function DecFlag(flagName, amount)
    amount = amount or 1

    local currentValue = GetFlag(flagName)
    return SetFlag(flagName, currentValue - amount)
end

--- Toggle flag between 0 and 1
---@param flagName string Name of the flag
---@return boolean success True if toggled successfully
---@usage ToggleFlag("switch")
function ToggleFlag(flagName)
    local currentValue = GetFlag(flagName)
    return SetFlag(flagName, currentValue == 0 and 1 or 0)
end

--- Check if flag is true (non-zero)
---@param flagName string Name of the flag
---@return boolean isTrue True if flag is non-zero
---@usage if IsFlagTrue("activated") then ... end
function IsFlagTrue(flagName)
    return GetFlag(flagName) ~= 0
end

--- Check if flag is false (zero)
---@param flagName string Name of the flag
---@return boolean isFalse True if flag is zero
---@usage if IsFlagFalse("activated") then ... end
function IsFlagFalse(flagName)
    return GetFlag(flagName) == 0
end

--- Check if flag equals value
---@param flagName string Name of the flag
---@param value number Value to compare
---@return boolean equals True if flag equals value
---@usage if FlagEquals("state", 3) then ... end
function FlagEquals(flagName, value)
    return GetFlag(flagName) == value
end

--- Check if flag is greater than value
---@param flagName string Name of the flag
---@param value number Value to compare
---@return boolean greater True if flag > value
---@usage if FlagGreaterThan("score", 100) then ... end
function FlagGreaterThan(flagName, value)
    return GetFlag(flagName) > value
end

--- Check if flag is less than value
---@param flagName string Name of the flag
---@param value number Value to compare
---@return boolean less True if flag < value
---@usage if FlagLessThan("health", 20) then ... end
function FlagLessThan(flagName, value)
    return GetFlag(flagName) < value
end

--- Check if flag is between values (inclusive)
---@param flagName string Name of the flag
---@param min number Minimum value (inclusive)
---@param max number Maximum value (inclusive)
---@return boolean between True if min <= flag <= max
---@usage if FlagBetween("temperature", 20, 30) then ... end
function FlagBetween(flagName, min, max)
    local value = GetFlag(flagName)
    return value >= min and value <= max
end

--- Set multiple flags at once
---@param flagTable table Table of flagName = value pairs
---@return boolean success True if all flags set successfully
---@usage SetFlags({flag1 = 10, flag2 = 20, flag3 = 0})
function SetFlags(flagTable)
    if type(flagTable) ~= "table" then
        _HarnessInternal.log.error("SetFlags requires table of flag name/value pairs", "SetFlags")
        return false
    end

    local allSuccess = true

    for flagName, value in pairs(flagTable) do
        if not SetFlag(flagName, value) then
            allSuccess = false
        end
    end

    return allSuccess
end

--- Get multiple flags at once
---@param flagNames table Array of flag names
---@return table values Table of flagName = value pairs
---@usage local vals = GetFlags({"flag1", "flag2", "flag3"})
function GetFlags(flagNames)
    if type(flagNames) ~= "table" then
        _HarnessInternal.log.error("GetFlags requires table of flag names", "GetFlags")
        return {}
    end

    local values = {}

    for _, flagName in ipairs(flagNames) do
        values[flagName] = GetFlag(flagName)
    end

    return values
end

--- Clear flag (set to 0)
---@param flagName string Name of the flag
---@return boolean success True if cleared successfully
---@usage ClearFlag("myFlag")
function ClearFlag(flagName)
    return SetFlag(flagName, 0)
end

--- Clear multiple flags
---@param flagNames table Array of flag names to clear
---@return boolean success True if all flags cleared successfully
---@usage ClearFlags({"flag1", "flag2", "flag3"})
function ClearFlags(flagNames)
    if type(flagNames) ~= "table" then
        _HarnessInternal.log.error("ClearFlags requires table of flag names", "ClearFlags")
        return false
    end

    local allSuccess = true

    for _, flagName in ipairs(flagNames) do
        if not ClearFlag(flagName) then
            allSuccess = false
        end
    end

    return allSuccess
end
-- ==== END: src/flag.lua ====

-- ==== BEGIN: src/misc.lua ====
--[[
==================================================================================================
    MISC MODULE
    Miscellaneous utility functions
==================================================================================================
]]
--- Deep copy a table
---@param original any Value to copy (tables are copied recursively)
---@return any copy Deep copy of the original
---@usage local copy = DeepCopy(myTable)
function DeepCopy(original)
    if type(original) ~= "table" then
        return original
    end

    local copy = {}
    for key, value in pairs(original) do
        copy[key] = DeepCopy(value)
    end

    -- Preserve metatable from original table
    local mt = getmetatable(original)
    if mt ~= nil then
        setmetatable(copy, mt)
    end

    return copy
end

--- Shallow copy a table
---@param original any Value to copy (only first level for tables)
---@return any copy Shallow copy of the original
---@usage local copy = ShallowCopy(myTable)
function ShallowCopy(original)
    if type(original) ~= "table" then
        return original
    end

    local copy = {}
    for key, value in pairs(original) do
        copy[key] = value
    end

    return copy
end

--- Check if table contains value
---@param table table Table to search in
---@param value any Value to search for
---@return boolean found True if value is in table
---@usage if Contains(myList, "item") then ... end
function Contains(table, value)
    if type(table) ~= "table" then
        return false
    end

    for _, v in pairs(table) do
        if v == value then
            return true
        end
    end

    return false
end

--- Check if table contains key
---@param table table Table to search in
---@param key any Key to search for
---@return boolean found True if key exists in table
---@usage if ContainsKey(myTable, "key") then ... end
function ContainsKey(table, key)
    if type(table) ~= "table" then
        return false
    end

    return table[key] ~= nil
end

--- Get table size (works with non-sequential tables)
---@param t any Value to check (0 if not a table)
---@return number size Number of entries in table
---@usage local size = TableSize(myTable)
function TableSize(t)
    if type(t) ~= "table" then
        return 0
    end

    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end

    return count
end

--- Get table keys
---@param t any Table to get keys from
---@return table keys Array of all keys in the table
---@usage local keys = TableKeys(myTable)
function TableKeys(t)
    if type(t) ~= "table" then
        return {}
    end

    local keys = {}
    for key, _ in pairs(t) do
        table.insert(keys, key)
    end

    return keys
end

--- Get table values
---@param t any Table to get values from
---@return table values Array of all values in the table
---@usage local values = TableValues(myTable)
function TableValues(t)
    if type(t) ~= "table" then
        return {}
    end

    local values = {}
    for _, value in pairs(t) do
        table.insert(values, value)
    end

    return values
end

--- Merge tables (second overwrites first)
---@param t1 any First table (or value)
---@param t2 any Second table to merge
---@return table merged Deep copy of t1 with t2 values merged in
---@usage local merged = MergeTables(defaults, options)
function MergeTables(t1, t2)
    if type(t1) ~= "table" then
        t1 = {}
    end

    if type(t2) ~= "table" then
        return t1
    end

    local merged = DeepCopy(t1)

    for key, value in pairs(t2) do
        merged[key] = value
    end

    return merged
end

--- Filter table by predicate function
---@param t any Table to filter
---@param predicate function Function(value, key) that returns true to keep
---@return table filtered New table with filtered entries
---@usage local evens = FilterTable(nums, function(v) return v % 2 == 0 end)
function FilterTable(t, predicate)
    if type(t) ~= "table" or type(predicate) ~= "function" then
        return {}
    end

    local filtered = {}

    for key, value in pairs(t) do
        if predicate(value, key) then
            filtered[key] = value
        end
    end

    return filtered
end

--- Map table values with function
---@param t any Table to map
---@param func function Function(value, key) that returns new value
---@return table mapped New table with mapped values
---@usage local doubled = MapTable(nums, function(v) return v * 2 end)
function MapTable(t, func)
    if type(t) ~= "table" or type(func) ~= "function" then
        return {}
    end

    local mapped = {}

    for key, value in pairs(t) do
        mapped[key] = func(value, key)
    end

    return mapped
end

--- Clamp value between min and max
---@param value number Value to clamp
---@param min number Minimum value
---@param max number Maximum value
---@return number clamped Value clamped between min and max
---@usage local health = Clamp(damage, 0, 100)
function Clamp(value, min, max)
    if type(value) ~= "number" or type(min) ~= "number" or type(max) ~= "number" then
        _HarnessInternal.log.error("Clamp requires three numbers", "Clamp")
        return min
    end

    return math.max(min, math.min(max, value))
end

--- Linear interpolation
---@param a number Start value
---@param b number End value
---@param t number Interpolation factor (0 to 1)
---@return number interpolated Interpolated value
---@usage local mid = Lerp(0, 100, 0.5) -- 50
function Lerp(a, b, t)
    if type(a) ~= "number" or type(b) ~= "number" or type(t) ~= "number" then
        _HarnessInternal.log.error("Lerp requires three numbers", "Lerp")
        return a or 0
    end

    return a + (b - a) * t
end

--- Round to decimal places
---@param value number Value to round
---@param decimals number? Number of decimal places (default 0)
---@return number rounded Rounded value
---@usage local rounded = Round(3.14159, 2) -- 3.14
function Round(value, decimals)
    if type(value) ~= "number" then
        _HarnessInternal.log.error("Round requires number", "Round")
        return 0
    end

    decimals = decimals or 0
    local mult = 10 ^ decimals
    return math.floor(value * mult + 0.5) / mult
end

--- Random float between min and max
---@param min number Minimum value
---@param max number Maximum value
---@return number random Random float between min and max
---@usage local rand = RandomFloat(0.0, 1.0)
function RandomFloat(min, max)
    if type(min) ~= "number" or type(max) ~= "number" then
        _HarnessInternal.log.error("RandomFloat requires two numbers", "RandomFloat")
        return 0
    end

    return min + math.random() * (max - min)
end

--- Random integer between min and max (inclusive)
---@param min number Minimum value
---@param max number Maximum value
---@return number random Random integer between min and max (inclusive)
---@usage local dice = RandomInt(1, 6)
function RandomInt(min, max)
    if type(min) ~= "number" or type(max) ~= "number" then
        _HarnessInternal.log.error("RandomInt requires two numbers", "RandomInt")
        return 0
    end

    return math.random(min, max)
end

--- Random choice from array
---@param choices table? Array to choose from
---@return any? choice Random element from array, nil if empty
---@usage local item = RandomChoice({"red", "green", "blue"})
function RandomChoice(choices)
    if type(choices) ~= "table" or #choices == 0 then
        return nil
    end

    return choices[math.random(1, #choices)]
end

--- Shuffle array in place
---@param array any Array to shuffle (modified in place)
---@return any array The shuffled array (same reference)
---@usage Shuffle(myArray)
function Shuffle(array)
    if type(array) ~= "table" then
        return array
    end

    local n = #array
    for i = n, 2, -1 do
        local j = math.random(1, i)
        array[i], array[j] = array[j], array[i]
    end

    return array
end

--- Create shuffled copy of array
---@param array any Array to copy and shuffle
---@return table shuffled New shuffled array
---@usage local shuffled = ShuffledCopy(myArray)
function ShuffledCopy(array)
    if type(array) ~= "table" then
        return {}
    end

    local copy = {}
    for i, v in ipairs(array) do
        copy[i] = v
    end

    return Shuffle(copy)
end

--- Split string by delimiter, with option to include empty tokens
---@param str any String to split
---@param delimiter string? Delimiter (default ",")
---@param includeEmpty boolean? Include empty tokens when delimiters are adjacent or at ends (default false)
---@return table parts Array of string parts
---@usage local parts = SplitString("a,b,c", ",")
---@usage local partsWithEmpty = SplitString(",a,,b,", ",", true)
function SplitString(str, delimiter, includeEmpty)
    if type(str) ~= "string" then
        return {}
    end

    delimiter = delimiter or ","
    includeEmpty = includeEmpty == true
    if delimiter == "" then
        return { str }
    end

    local result = {}
    local startIndex = 1
    local delimLen = #delimiter

    while true do
        local i, j = string.find(str, delimiter, startIndex, true) -- plain find (no patterns)
        if not i then
            local tail = string.sub(str, startIndex)
            if includeEmpty or tail ~= "" then
                table.insert(result, tail)
            end
            break
        end
        local segment = string.sub(str, startIndex, i - 1)
        if includeEmpty or segment ~= "" then
            table.insert(result, segment)
        end
        startIndex = j + 1
    end

    return result
end

--- Trim whitespace from string
---@param str any String to trim
---@return string trimmed Trimmed string (empty if not string)
---@usage local clean = TrimString("  hello  ")
function TrimString(str)
    if type(str) ~= "string" then
        return ""
    end

    return str:match("^%s*(.-)%s*$")
end

--- Check if a string starts with a given prefix (literal, supports multi-character)
---@param s any String to check
---@param prefix any Prefix to look for
---@return boolean starts True if s starts with prefix
---@usage if StringStartsWith("abc", "a") then ... end
function StringStartsWith(s, prefix)
    if type(s) ~= "string" or type(prefix) ~= "string" then
        return false
    end
    local lp = #prefix
    if lp == 0 then
        return true
    end
    return string.sub(s, 1, lp) == prefix
end

--- Check if a string contains a given substring (literal, supports multi-character)
---@param s any String to search
---@param needle any Substring to find
---@return boolean contains True if s contains needle
---@usage if StringContains("hello world", "lo w") then ... end
function StringContains(s, needle)
    if type(s) ~= "string" or type(needle) ~= "string" then
        return false
    end
    if needle == "" then
        return true
    end
    local i = string.find(s, needle, 1, true) -- plain find
    return i ~= nil
end

--- Check if a string ends with a given suffix (literal, supports multi-character)
---@param s any String to check
---@param suffix any Suffix to look for
---@return boolean ends True if s ends with suffix
---@usage if StringEndsWith("file.lua", ".lua") then ... end
function StringEndsWith(s, suffix)
    if type(s) ~= "string" or type(suffix) ~= "string" then
        return false
    end
    local ls = #suffix
    if ls == 0 then
        return false
    end
    return string.sub(s, -ls) == suffix
end

--- Check if string starts with prefix
---@param str any String to check
---@param prefix any Prefix to look for
---@return boolean starts True if str starts with prefix
---@usage if StartsWith(filename, "test_") then ... end
function StartsWith(str, prefix)
    return StringStartsWith(str, prefix)
end

--- Check if string ends with suffix
---@param str any String to check
---@param suffix any Suffix to look for
---@return boolean ends True if str ends with suffix
---@usage if EndsWith(filename, ".lua") then ... end
function EndsWith(str, suffix)
    return StringEndsWith(str, suffix)
end

-- Note: DegToRad and RadToDeg functions are available in geomath.lua

--- Normalize angle to 0-360 range
---@param angle number Angle in degrees
---@return number normalized Angle normalized to 0-360
---@usage local norm = NormalizeAngle(450) -- 90
function NormalizeAngle(angle)
    if type(angle) ~= "number" then
        _HarnessInternal.log.error("NormalizeAngle requires number", "NormalizeAngle")
        return 0
    end

    while angle < 0 do
        angle = angle + 360
    end

    while angle >= 360 do
        angle = angle - 360
    end

    return angle
end

--- Get angle difference (shortest path)
---@param angle1 number First angle in degrees
---@param angle2 number Second angle in degrees
---@return number difference Shortest angle difference (-180 to 180)
---@usage local diff = AngleDiff(350, 10) -- 20
function AngleDiff(angle1, angle2)
    if type(angle1) ~= "number" or type(angle2) ~= "number" then
        _HarnessInternal.log.error("AngleDiff requires two numbers", "AngleDiff")
        return 0
    end

    local diff = angle2 - angle1

    while diff > 180 do
        diff = diff - 360
    end

    while diff < -180 do
        diff = diff + 360
    end

    return diff
end

--- Simple table serialization for debugging
---@param tbl any Table to serialize
---@param indent number? Indentation level (default 0)
---@return string serialized String representation of table
---@usage print(TableToString(myTable))
function TableToString(tbl, indent)
    if type(tbl) ~= "table" then
        return tostring(tbl)
    end

    indent = indent or 0
    local indentStr = string.rep("  ", indent)
    local result = "{\n"

    for key, value in pairs(tbl) do
        result = result .. indentStr .. "  [" .. tostring(key) .. "] = "

        if type(value) == "table" then
            result = result .. TableToString(value, indent + 1)
        else
            result = result .. tostring(value)
        end

        result = result .. ",\n"
    end

    result = result .. indentStr .. "}"

    return result
end

--- Shallow equality check between two values (tables compared by first-level keys/values)
---@param a any First value
---@param b any Second value
---@return boolean equal True if values are shallowly equal
---@usage
--- local same = ShallowEqual({a=1,b=2},{b=2,a=1}) -- true
function ShallowEqual(a, b)
    if a == b then
        return true
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    for k, v in pairs(a) do
        if b[k] ~= v then
            return false
        end
    end
    for k, v in pairs(b) do
        if a[k] ~= v then
            return false
        end
    end
    return true
end

--- Encode a Lua value to JSON string
---@param value any Value to encode (tables, numbers, strings, booleans, nil)
---@return string|nil json JSON string on success, nil on error
---@usage local s = EncodeJson({a=1})
function EncodeJson(value)
    -- Prefer DCS-provided implementation if available
    if net and type(net.lua2json) == "function" then
        local ok, res = pcall(net.lua2json, value)
        if ok then
            return res
        end
        _HarnessInternal.log.error(
            "EncodeJson failed via net.lua2json: " .. tostring(res),
            "EncodeJson"
        )
        return nil
    end

    -- Minimal fallback encoder (sufficient for simple tables without cycles or functions)
    local t = type(value)
    if t == "nil" then
        return "null"
    elseif t == "number" or t == "boolean" then
        return tostring(value)
    elseif t == "string" then
        local s = value
        s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r")
        return '"' .. s .. '"'
    elseif t == "table" then
        -- Detect array-like table
        local isArray = true
        local count = 0
        for k, _ in pairs(value) do
            count = count + 1
            if type(k) ~= "number" then
                isArray = false
                break
            end
        end
        if isArray then
            local parts = {}
            for i = 1, #value do
                parts[#parts + 1] = EncodeJson(value[i]) or "null"
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(value) do
                local keyType = type(k)
                if keyType ~= "string" then
                    -- JSON keys must be strings; stringify others
                    k = tostring(k)
                end
                local keyJson = EncodeJson(k)
                local valJson = EncodeJson(v) or "null"
                parts[#parts + 1] = tostring(keyJson) .. ":" .. valJson
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end

    _HarnessInternal.log.error("EncodeJson cannot encode type: " .. t, "EncodeJson")
    return nil
end

--- Decode a JSON string to Lua value
---@param json string JSON string to decode
---@return any value Decoded Lua value (or nil on error)
---@usage local t = DecodeJson('{"a":1}')
function DecodeJson(json)
    if type(json) ~= "string" then
        _HarnessInternal.log.error("DecodeJson requires string", "DecodeJson")
        return nil
    end

    -- Prefer DCS-provided implementation if available
    if net and type(net.json2lua) == "function" then
        local ok, res = pcall(net.json2lua, json)
        if ok then
            return res
        end
        _HarnessInternal.log.error(
            "DecodeJson failed via net.json2lua: " .. tostring(res),
            "DecodeJson"
        )
        return nil
    end

    -- Extremely small fallback: handle null, booleans, numbers, quoted strings, simple arrays/objects
    local str = json:match("^%s*(.-)%s*$")
    if str == "null" then
        return nil
    end
    if str == "true" then
        return true
    end
    if str == "false" then
        return false
    end
    -- number
    local num = tonumber(str)
    if num ~= nil then
        return num
    end
    -- quoted string
    local s = str:match('^"(.*)"$')
    if s ~= nil then
        s = s:gsub("\\n", "\n"):gsub("\\r", "\r"):gsub('\\"', '"'):gsub("\\\\", "\\")
        return s
    end

    -- Very naive parser for flat arrays/objects without nesting or spaces inside keys
    local function splitTopLevel(content)
        local parts = {}
        local buf = {}
        local inString = false
        local escape = false
        for i = 1, #content do
            local ch = content:sub(i, i)
            if inString then
                table.insert(buf, ch)
                if escape then
                    escape = false
                elseif ch == "\\" then
                    escape = true
                elseif ch == '"' then
                    inString = false
                end
            else
                if ch == '"' then
                    inString = true
                    table.insert(buf, ch)
                elseif ch == "," then
                    parts[#parts + 1] = table.concat(buf)
                    buf = {}
                else
                    table.insert(buf, ch)
                end
            end
        end
        if #buf > 0 then
            parts[#parts + 1] = table.concat(buf)
        end
        return parts
    end

    -- Array [a,b,c]
    local inner = str:match("^%[(.*)%]$")
    if inner ~= nil then
        local items = splitTopLevel(inner)
        local result = {}
        for i = 1, #items do
            local v = DecodeJson(items[i])
            result[#result + 1] = v
        end
        return result
    end

    -- Object {"k":v,...} (flat only)
    inner = str:match("^%{(.*)%}$")
    if inner ~= nil then
        local items = splitTopLevel(inner)
        local obj = {}
        for _, item in ipairs(items) do
            local k, v = item:match("^%s*(.-)%s*:%s*(.-)%s*$")
            if k ~= nil then
                local key = DecodeJson(k)
                obj[key] = DecodeJson(v)
            end
        end
        return obj
    end

    _HarnessInternal.log.error("DecodeJson fallback cannot parse input", "DecodeJson")
    return nil
end

--- Retry decorator: retries function on failure
---@param func function Function to wrap
---@param options table? Options {retries:number, shouldRetry:function?, onRetry:function?}
---@return function wrapped Function that retries on error
---@usage
--- local unstable = function(x)
--- 	if math.random() < 0.5 then error("boom") end
--- 	return x * 2
--- end
--- local safe = Retry(unstable, {retries = 3})
--- local result = safe(10)
function Retry(func, options)
    if type(func) ~= "function" then
        _HarnessInternal.log.error("Retry requires function", "Retry")
        return func
    end

    options = options or {}
    local maxRetries = tonumber(options.retries) or 3
    local shouldRetry = options.shouldRetry -- function(success, ...): boolean
    local onRetry = options.onRetry -- function(attempt, err)

    return function(...)
        local args = { ... }
        local attempt = 0
        while true do
            local results = { pcall(func, unpack(args)) }
            local ok = results[1]
            if ok then
                local ret = {}
                for i = 2, #results do
                    ret[i - 1] = results[i]
                end
                local shouldRetryNow = false
                if type(shouldRetry) == "function" then
                    local ok2, decision = pcall(shouldRetry, true, unpack(ret))
                    if ok2 then
                        shouldRetryNow = decision and attempt < maxRetries
                    end
                end
                if shouldRetryNow then
                    attempt = attempt + 1
                    if type(onRetry) == "function" then
                        pcall(onRetry, attempt, nil)
                    end
                    -- loop to retry
                else
                    return unpack(ret)
                end
            else
                local err = results[2]
                if attempt >= maxRetries then
                    _HarnessInternal.log.error(
                        "Retry exhausted after "
                            .. tostring(attempt)
                            .. " attempts: "
                            .. tostring(err),
                        "Retry"
                    )
                    return nil
                end
                attempt = attempt + 1
                if type(onRetry) == "function" then
                    pcall(onRetry, attempt, err)
                end
                _HarnessInternal.log.warn(
                    "Retry attempt " .. tostring(attempt) .. " after error: " .. tostring(err),
                    "Retry"
                )
                -- loop to retry
            end
        end
    end
end

--- Circuit breaker decorator: opens circuit after failures, with cooldown
---@param func function Function to wrap
---@param options table? Options {failureThreshold:number, cooldown:number, timeProvider:function?, shouldCountFailure:function?}
---@return function wrapped Wrapped function with breaker behavior
---@usage
--- local safe = CircuitBreaker(unstable, {failureThreshold=3, cooldown=30})
--- local result = safe(10)
function CircuitBreaker(func, options)
    if type(func) ~= "function" then
        _HarnessInternal.log.error("CircuitBreaker requires function", "CircuitBreaker")
        return func
    end

    options = options or {}
    local failureThreshold = tonumber(options.failureThreshold) or 5
    local cooldown = tonumber(options.cooldown) or 30
    local timeProvider = options.timeProvider
    if type(timeProvider) ~= "function" then
        timeProvider = function()
            return GetTime()
        end
    end
    local shouldCountFailure = options.shouldCountFailure -- function(success, ...) -> boolean (count as failure?)

    local state = {
        status = "closed", -- "closed" | "open" | "half_open"
        consecutiveFailures = 0,
        openedAt = nil,
    }

    local function transitionToOpen(now)
        state.status = "open"
        state.openedAt = now
        _HarnessInternal.log.warn("Circuit opened after failures", "CircuitBreaker")
    end

    local function transitionToHalfOpen()
        state.status = "half_open"
        _HarnessInternal.log.info("Circuit half-open: trial call permitted", "CircuitBreaker")
    end

    local function transitionToClosed()
        state.status = "closed"
        state.consecutiveFailures = 0
        state.openedAt = nil
        _HarnessInternal.log.info("Circuit closed", "CircuitBreaker")
    end

    return function(...)
        local now = timeProvider()

        -- Handle open state cooldown expiry
        if state.status == "open" then
            if cooldown <= 0 or (state.openedAt and now - state.openedAt >= cooldown) then
                transitionToHalfOpen()
            else
                _HarnessInternal.log.warn("Call short-circuited (circuit open)", "CircuitBreaker")
                return nil
            end
        end

        -- Allow single trial in half-open
        local trial = state.status == "half_open"
        local packed = { pcall(func, ...) }
        local ok = packed[1]
        if ok then
            local ret = {}
            for i = 2, #packed do
                ret[i - 1] = packed[i]
            end
            -- Success: optionally consult shouldCountFailure (if provided) to treat as failure
            local countAsFailure = false
            if type(shouldCountFailure) == "function" then
                local ok2, decision = pcall(shouldCountFailure, true, unpack(ret))
                if ok2 then
                    countAsFailure = decision
                end
            end
            if countAsFailure then
                state.consecutiveFailures = state.consecutiveFailures + 1
                if state.consecutiveFailures >= failureThreshold then
                    transitionToOpen(now)
                end
                return unpack(ret)
            end
            transitionToClosed()
            return unpack(ret)
        else
            -- Failure
            local err = packed[2]
            state.consecutiveFailures = state.consecutiveFailures + 1
            _HarnessInternal.log.warn(
                "Function error (failure "
                    .. tostring(state.consecutiveFailures)
                    .. "): "
                    .. tostring(err),
                "CircuitBreaker"
            )
            if trial or state.consecutiveFailures >= failureThreshold then
                transitionToOpen(now)
            end
            return nil
        end
    end
end
-- ==== END: src/misc.lua ====

-- ==== BEGIN: src/missioncommands.lua ====
--[[
    MissionCommands Module - DCS World Mission Commands API Wrappers
    
    This module provides validated wrapper functions for DCS F10 radio menu operations,
    including menu creation, command handling, and menu removal.
]]
--- Adds a command to the F10 radio menu
--- @param path table Array of menu path elements (numbers or strings)
--- @param menuItem table Menu item definition with name, enabled, and removable fields
--- @param handler function Function to call when menu item is selected
--- @param params any? Optional parameters to pass to the handler
--- @return number|nil commandId The command ID if successful, nil otherwise
--- @usage local cmdId = AddCommand({"Main", "SubMenu"}, {name="Test", enabled=true}, function() print("Selected") end)
function AddCommand(path, menuItem, handler, params)
    if not path or type(path) ~= "table" then
        _HarnessInternal.log.error(
            "AddCommand requires valid path table",
            "MissionCommands.AddCommand"
        )
        return nil
    end

    if not menuItem or type(menuItem) ~= "table" then
        _HarnessInternal.log.error(
            "AddCommand requires valid menu item table",
            "MissionCommands.AddCommand"
        )
        return nil
    end

    if not handler or type(handler) ~= "function" then
        _HarnessInternal.log.error(
            "AddCommand requires valid handler function",
            "MissionCommands.AddCommand"
        )
        return nil
    end

    local success, result = pcall(missionCommands.addCommand, path, menuItem, handler, params)
    if not success then
        _HarnessInternal.log.error(
            "Failed to add command: " .. tostring(result),
            "MissionCommands.AddCommand"
        )
        return nil
    end

    return result
end

--- Adds a submenu to the F10 radio menu
--- @param path table Array of menu path elements (numbers or strings)
--- @param name string The name of the submenu to create
--- @return table|nil submenuPath The path to the new submenu if successful, nil otherwise
--- @usage local subPath = AddSubMenu({}, "My Menu")
function AddSubMenu(path, name)
    if not path or type(path) ~= "table" then
        _HarnessInternal.log.error(
            "AddSubMenu requires valid path table",
            "MissionCommands.AddSubMenu"
        )
        return nil
    end

    if not name or type(name) ~= "string" then
        _HarnessInternal.log.error(
            "AddSubMenu requires valid name string",
            "MissionCommands.AddSubMenu"
        )
        return nil
    end

    local success, result = pcall(missionCommands.addSubMenu, name, path)
    if not success then
        _HarnessInternal.log.error(
            "Failed to add submenu: " .. tostring(result),
            "MissionCommands.AddSubMenu"
        )
        return nil
    end

    return result
end

--- Removes a menu item or submenu from the F10 radio menu
--- @param path table Array of menu path elements to remove
--- @return boolean|nil success True if removed successfully, nil otherwise
--- @usage RemoveItem({"Main", "SubMenu", "Command"})
function RemoveItem(path)
    if not path or type(path) ~= "table" then
        _HarnessInternal.log.error(
            "RemoveItem requires valid path table",
            "MissionCommands.RemoveItem"
        )
        return nil
    end

    local success, result = pcall(missionCommands.removeItem, path)
    if not success then
        _HarnessInternal.log.error(
            "Failed to remove item: " .. tostring(result),
            "MissionCommands.RemoveItem"
        )
        return nil
    end

    return true
end

--- Adds a command to the F10 radio menu for a specific coalition
--- @param coalitionId number Coalition ID (coalition.side.RED or coalition.side.BLUE)
--- @param path table Array of menu path elements
--- @param menuItem table Menu item definition with name, enabled, and removable fields
--- @param handler function Function to call when menu item is selected
--- @param params any? Optional parameters to pass to the handler
--- @return number|nil commandId The command ID if successful, nil otherwise
--- @usage AddCommandForCoalition(coalition.side.BLUE, {}, {name="Intel"}, function() end)
function AddCommandForCoalition(coalitionId, path, menuItem, handler, params)
    if not coalitionId or type(coalitionId) ~= "number" then
        _HarnessInternal.log.error(
            "AddCommandForCoalition requires valid coalition ID",
            "MissionCommands.AddCommandForCoalition"
        )
        return nil
    end

    if not path or type(path) ~= "table" then
        _HarnessInternal.log.error(
            "AddCommandForCoalition requires valid path table",
            "MissionCommands.AddCommandForCoalition"
        )
        return nil
    end

    if not menuItem or type(menuItem) ~= "table" then
        _HarnessInternal.log.error(
            "AddCommandForCoalition requires valid menu item table",
            "MissionCommands.AddCommandForCoalition"
        )
        return nil
    end

    if not handler or type(handler) ~= "function" then
        _HarnessInternal.log.error(
            "AddCommandForCoalition requires valid handler function",
            "MissionCommands.AddCommandForCoalition"
        )
        return nil
    end

    local success, result =
        pcall(missionCommands.addCommandForCoalition, coalitionId, path, menuItem, handler, params)
    if not success then
        _HarnessInternal.log.error(
            "Failed to add coalition command: " .. tostring(result),
            "MissionCommands.AddCommandForCoalition"
        )
        return nil
    end

    return result
end

--- Adds a submenu to the F10 radio menu for a specific coalition
--- @param coalitionId number Coalition ID (coalition.side.RED or coalition.side.BLUE)
--- @param path table Array of menu path elements
--- @param name string The name of the submenu to create
--- @return table|nil submenuPath The path to the new submenu if successful, nil otherwise
--- @usage AddSubMenuForCoalition(coalition.side.RED, {}, "Enemy Options")
function AddSubMenuForCoalition(coalitionId, path, name)
    if not coalitionId or type(coalitionId) ~= "number" then
        _HarnessInternal.log.error(
            "AddSubMenuForCoalition requires valid coalition ID",
            "MissionCommands.AddSubMenuForCoalition"
        )
        return nil
    end

    if not path or type(path) ~= "table" then
        _HarnessInternal.log.error(
            "AddSubMenuForCoalition requires valid path table",
            "MissionCommands.AddSubMenuForCoalition"
        )
        return nil
    end

    if not name or type(name) ~= "string" then
        _HarnessInternal.log.error(
            "AddSubMenuForCoalition requires valid name string",
            "MissionCommands.AddSubMenuForCoalition"
        )
        return nil
    end

    local success, result = pcall(missionCommands.addSubMenuForCoalition, coalitionId, name, path)
    if not success then
        _HarnessInternal.log.error(
            "Failed to add coalition submenu: " .. tostring(result),
            "MissionCommands.AddSubMenuForCoalition"
        )
        return nil
    end

    return result
end

--- Removes a menu item or submenu for a specific coalition
--- @param coalitionId number Coalition ID (coalition.side.RED or coalition.side.BLUE)
--- @param path table Array of menu path elements to remove
--- @return boolean|nil success True if removed successfully, nil otherwise
--- @usage RemoveItemForCoalition(coalition.side.BLUE, {"Intel", "Report"})
function RemoveItemForCoalition(coalitionId, path)
    if not coalitionId or type(coalitionId) ~= "number" then
        _HarnessInternal.log.error(
            "RemoveItemForCoalition requires valid coalition ID",
            "MissionCommands.RemoveItemForCoalition"
        )
        return nil
    end

    if not path or type(path) ~= "table" then
        _HarnessInternal.log.error(
            "RemoveItemForCoalition requires valid path table",
            "MissionCommands.RemoveItemForCoalition"
        )
        return nil
    end

    local success, result = pcall(missionCommands.removeItemForCoalition, coalitionId, path)
    if not success then
        _HarnessInternal.log.error(
            "Failed to remove coalition item: " .. tostring(result),
            "MissionCommands.RemoveItemForCoalition"
        )
        return nil
    end

    return true
end

--- Adds a command to the F10 radio menu for a specific group
--- @param groupId number Group ID from DCS
--- @param path table Array of menu path elements
--- @param menuItem table Menu item definition with name, enabled, and removable fields
--- @param handler function Function to call when menu item is selected
--- @param params any? Optional parameters to pass to the handler
--- @return number|nil commandId The command ID if successful, nil otherwise
--- @usage AddCommandForGroup(groupId, {}, {name="Request Support"}, function() end)
function AddCommandForGroup(groupId, path, menuItem, handler, params)
    if not groupId or type(groupId) ~= "number" then
        _HarnessInternal.log.error(
            "AddCommandForGroup requires valid group ID",
            "MissionCommands.AddCommandForGroup"
        )
        return nil
    end

    if not path or type(path) ~= "table" then
        _HarnessInternal.log.error(
            "AddCommandForGroup requires valid path table",
            "MissionCommands.AddCommandForGroup"
        )
        return nil
    end

    if not menuItem or type(menuItem) ~= "table" then
        _HarnessInternal.log.error(
            "AddCommandForGroup requires valid menu item table",
            "MissionCommands.AddCommandForGroup"
        )
        return nil
    end

    if not handler or type(handler) ~= "function" then
        _HarnessInternal.log.error(
            "AddCommandForGroup requires valid handler function",
            "MissionCommands.AddCommandForGroup"
        )
        return nil
    end

    local success, result =
        pcall(missionCommands.addCommandForGroup, groupId, path, menuItem, handler, params)
    if not success then
        _HarnessInternal.log.error(
            "Failed to add group command: " .. tostring(result),
            "MissionCommands.AddCommandForGroup"
        )
        return nil
    end

    return result
end

--- Adds a submenu to the F10 radio menu for a specific group
--- @param groupId number Group ID from DCS
--- @param path table Array of menu path elements
--- @param name string The name of the submenu to create
--- @return table|nil submenuPath The path to the new submenu if successful, nil otherwise
--- @usage AddSubMenuForGroup(groupId, {}, "Flight Options")
function AddSubMenuForGroup(groupId, path, name)
    if not groupId or type(groupId) ~= "number" then
        _HarnessInternal.log.error(
            "AddSubMenuForGroup requires valid group ID",
            "MissionCommands.AddSubMenuForGroup"
        )
        return nil
    end

    if not path or type(path) ~= "table" then
        _HarnessInternal.log.error(
            "AddSubMenuForGroup requires valid path table",
            "MissionCommands.AddSubMenuForGroup"
        )
        return nil
    end

    if not name or type(name) ~= "string" then
        _HarnessInternal.log.error(
            "AddSubMenuForGroup requires valid name string",
            "MissionCommands.AddSubMenuForGroup"
        )
        return nil
    end

    local success, result = pcall(missionCommands.addSubMenuForGroup, groupId, path, name)
    if not success then
        _HarnessInternal.log.error(
            "Failed to add group submenu: " .. tostring(result),
            "MissionCommands.AddSubMenuForGroup"
        )
        return nil
    end

    return result
end

--- Removes a menu item or submenu for a specific group
--- @param groupId number Group ID from DCS
--- @param path table Array of menu path elements to remove
--- @return boolean|nil success True if removed successfully, nil otherwise
--- @usage RemoveItemForGroup(groupId, {"Flight Options", "RTB"})
function RemoveItemForGroup(groupId, path)
    if not groupId or type(groupId) ~= "number" then
        _HarnessInternal.log.error(
            "RemoveItemForGroup requires valid group ID",
            "MissionCommands.RemoveItemForGroup"
        )
        return nil
    end

    if not path or type(path) ~= "table" then
        _HarnessInternal.log.error(
            "RemoveItemForGroup requires valid path table",
            "MissionCommands.RemoveItemForGroup"
        )
        return nil
    end

    local success, result = pcall(missionCommands.removeItemForGroup, groupId, path)
    if not success then
        _HarnessInternal.log.error(
            "Failed to remove group item: " .. tostring(result),
            "MissionCommands.RemoveItemForGroup"
        )
        return nil
    end

    return true
end

--- Creates a menu item definition for use with AddCommand functions
--- @param name string The display name of the menu item
--- @param enabled boolean? Whether the item is enabled (default: true)
--- @param removable boolean? Whether the item can be removed (default: true)
--- @return table|nil menuItem Menu item definition or nil on error
--- @usage local item = CreateMenuItem("Launch Attack", true, false)
function CreateMenuItem(name, enabled, removable)
    if not name or type(name) ~= "string" then
        _HarnessInternal.log.error(
            "CreateMenuItem requires valid name string",
            "MissionCommands.CreateMenuItem"
        )
        return nil
    end

    if enabled == nil then
        enabled = true
    end

    if removable == nil then
        removable = true
    end

    return {
        name = name,
        enabled = enabled,
        removable = removable,
    }
end

--- Creates a menu path from variable arguments
--- @param ... string|number Path elements (strings or command IDs)
--- @return table|nil path Array of path elements or nil on error
--- @usage local path = CreateMenuPath("Main", "Options", "Graphics")
function CreateMenuPath(...)
    local path = {}
    for i, v in ipairs({ ... }) do
        if type(v) == "number" or type(v) == "string" then
            table.insert(path, v)
        else
            _HarnessInternal.log.error(
                "CreateMenuPath requires number or string path elements",
                "MissionCommands.CreateMenuPath"
            )
            return nil
        end
    end
    return path
end
-- ==== END: src/missioncommands.lua ====

-- ==== BEGIN: src/namespace.lua ====
-- Harness is globally available when this build is loaded
-- ==== END: src/namespace.lua ====

-- ==== BEGIN: src/net.lua ====
--[[
==================================================================================================
    NET MODULE
    Multiplayer networking utilities
==================================================================================================
]]
--- Send chat message to all players or coalition
---@param message string Message text to send
---@param all boolean True to send to all, false for coalition only
---@return boolean success True if message was sent
---@usage SendChat("Hello everyone!", true)
function SendChat(message, all)
    if not message or type(message) ~= "string" then
        _HarnessInternal.log.error("SendChat requires string message", "SendChat")
        return false
    end

    if type(all) ~= "boolean" then
        _HarnessInternal.log.error("SendChat requires boolean for 'all' parameter", "SendChat")
        return false
    end

    local success, result = pcall(net.send_chat, message, all)
    if not success then
        _HarnessInternal.log.error("Failed to send chat: " .. tostring(result), "SendChat")
        return false
    end

    _HarnessInternal.log.info("Sent chat message", "SendChat")
    return true
end

--- Send chat message to specific player
---@param message string Message text to send
---@param playerId number Target player ID
---@param fromId number? Sender player ID (optional)
---@return boolean success True if message was sent
---@usage SendChatTo("Private message", 2)
function SendChatTo(message, playerId, fromId)
    if not message or type(message) ~= "string" then
        _HarnessInternal.log.error("SendChatTo requires string message", "SendChatTo")
        return false
    end

    if not playerId or type(playerId) ~= "number" then
        _HarnessInternal.log.error("SendChatTo requires numeric player ID", "SendChatTo")
        return false
    end

    if fromId and type(fromId) ~= "number" then
        _HarnessInternal.log.error("SendChatTo fromId must be numeric", "SendChatTo")
        return false
    end

    local success, result = pcall(net.send_chat_to, message, playerId, fromId)
    if not success then
        _HarnessInternal.log.error(
            "Failed to send chat to player: " .. tostring(result),
            "SendChatTo"
        )
        return false
    end

    _HarnessInternal.log.info("Sent chat to player " .. playerId, "SendChatTo")
    return true
end

--- Get list of all connected players
---@return table players Array of player info tables
---@usage local players = GetPlayers()
function GetPlayers()
    local success, players = pcall(net.get_player_list)
    if not success then
        _HarnessInternal.log.error("Failed to get player list: " .. tostring(players), "GetPlayers")
        return {}
    end

    return players or {}
end

--- Get information about specific player
---@param playerId number Player ID
---@return table? info Player info table or nil on error
---@usage local info = GetPlayerInfo(1)
function GetPlayerInfo(playerId)
    if not playerId or type(playerId) ~= "number" then
        _HarnessInternal.log.error("GetPlayerInfo requires numeric player ID", "GetPlayerInfo")
        return nil
    end

    local success, info = pcall(net.get_player_info, playerId)
    if not success then
        _HarnessInternal.log.error("Failed to get player info: " .. tostring(info), "GetPlayerInfo")
        return nil
    end

    return info
end

--- Kick player from server
---@param playerId number Player ID to kick
---@param reason string? Kick reason message
---@return boolean success True if kick command was sent
---@usage KickPlayer(3, "Team killing")
function KickPlayer(playerId, reason)
    if not playerId or type(playerId) ~= "number" then
        _HarnessInternal.log.error("KickPlayer requires numeric player ID", "KickPlayer")
        return false
    end

    reason = reason or "Kicked by server"

    local success, result = pcall(net.kick, playerId, reason)
    if not success then
        _HarnessInternal.log.error("Failed to kick player: " .. tostring(result), "KickPlayer")
        return false
    end

    _HarnessInternal.log.info("Kicked player " .. playerId .. ": " .. reason, "KickPlayer")
    return true
end

--- Get player's network statistics
---@param playerId number Player ID
---@param statId number Statistic ID (use net.PS_* constants)
---@return number? value Statistic value or nil on error
---@usage local ping = GetPlayerStat(1, net.PS_PING)
function GetPlayerStat(playerId, statId)
    if not playerId or type(playerId) ~= "number" then
        _HarnessInternal.log.error("GetPlayerStat requires numeric player ID", "GetPlayerStat")
        return nil
    end

    if not statId or type(statId) ~= "number" then
        _HarnessInternal.log.error("GetPlayerStat requires numeric stat ID", "GetPlayerStat")
        return nil
    end

    local success, value = pcall(net.get_stat, playerId, statId)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get player stat: " .. tostring(value),
            "GetPlayerStat"
        )
        return nil
    end

    return value
end

--- Check if running as server
---@return boolean isServer True if running as server
---@usage if IsServer() then ... end
function IsServer()
    -- Prefer the official DCS API when available
    if DCS and type(DCS.isServer) == "function" then
        local successDcs, resultDcs = pcall(DCS.isServer)
        if not successDcs then
            _HarnessInternal.log.error(
                "Failed to check server status via DCS.isServer: " .. tostring(resultDcs),
                "IsServer"
            )
            return false
        end
        return resultDcs == true
    end
    return false
end

--- Load a new mission
---@param missionPath string Path to mission file
---@return boolean success True if mission load was initiated
---@usage LoadMission("C:/Missions/my_mission.miz")
function LoadMission(missionPath)
    if not missionPath or type(missionPath) ~= "string" then
        _HarnessInternal.log.error("LoadMission requires string mission path", "LoadMission")
        return false
    end

    local success, result = pcall(net.load_mission, missionPath)
    if not success then
        _HarnessInternal.log.error("Failed to load mission: " .. tostring(result), "LoadMission")
        return false
    end

    _HarnessInternal.log.info("Loading mission: " .. missionPath, "LoadMission")
    return true
end

--- Load next mission in list
---@return boolean success True if next mission load was initiated
---@usage LoadNextMission()
function LoadNextMission()
    local success, result = pcall(net.load_next_mission)
    if not success then
        _HarnessInternal.log.error(
            "Failed to load next mission: " .. tostring(result),
            "LoadNextMission"
        )
        return false
    end

    _HarnessInternal.log.info("Loading next mission", "LoadNextMission")
    return true
end

--- Get current mission name
---@return string? name Mission name or nil on error
---@usage local mission = GetMissionName()
function GetMissionName()
    if DCS and type(DCS.getMissionName) == "function" then
        local success, name = pcall(net.dostring_in("gui", "return DCS.getMissionName()"))
        if not success then
            _HarnessInternal.log.error(
                "Failed to get mission name: " .. tostring(name),
                "GetMissionName"
            )
            return nil
        end
        return name
    end

    return nil
end
--- Force player to slot
---@param playerId number Player ID
---@param side number Coalition side (0=neutral, 1=red, 2=blue)
---@param slotId string Slot ID string
---@return boolean success True if slot change was initiated
---@usage ForcePlayerSlot(2, 2, "blue_f16_pilot")
function ForcePlayerSlot(playerId, side, slotId)
    if not playerId or type(playerId) ~= "number" then
        _HarnessInternal.log.error("ForcePlayerSlot requires numeric player ID", "ForcePlayerSlot")
        return false
    end

    if not side or type(side) ~= "number" then
        _HarnessInternal.log.error("ForcePlayerSlot requires numeric side", "ForcePlayerSlot")
        return false
    end

    if not slotId or type(slotId) ~= "string" then
        _HarnessInternal.log.error("ForcePlayerSlot requires string slot ID", "ForcePlayerSlot")
        return false
    end

    local success, result = pcall(net.force_player_slot, playerId, side, slotId)
    if not success then
        _HarnessInternal.log.error(
            "Failed to force player slot: " .. tostring(result),
            "ForcePlayerSlot"
        )
        return false
    end

    _HarnessInternal.log.info(
        "Forced player " .. playerId .. " to slot " .. slotId,
        "ForcePlayerSlot"
    )
    return true
end
-- ==== END: src/net.lua ====

-- ==== BEGIN: src/staticobject.lua ====
--[[
    StaticObject Module - DCS World Static Object API Wrappers
    
    This module provides validated wrapper functions for DCS static object operations,
    including object queries, destruction, and property access.
]]

--- Gets a static object by its name
---@param name string The name of the static object
---@return table? staticObject The static object or nil if not found
---@usage local static = GetStaticByName("Warehouse01")
function GetStaticByName(name)
    if not name or type(name) ~= "string" then
        _HarnessInternal.log.error(
            "GetStaticByName requires valid name string",
            "StaticObject.GetByName"
        )
        return nil
    end

    local success, result = pcall(StaticObject.getByName, name)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get static object by name: " .. tostring(result),
            "StaticObject.GetByName"
        )
        return nil
    end

    return result
end

--- Gets the ID of a static object
---@param staticObject table The static object
---@return number? id The ID of the static object or nil on error
---@usage local id = GetStaticID(staticObj)
function GetStaticID(staticObject)
    if not staticObject then
        _HarnessInternal.log.error("GetStaticID requires valid static object", "StaticObject.GetID")
        return nil
    end

    local success, result = pcall(staticObject.getID, staticObject)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get static object ID: " .. tostring(result),
            "StaticObject.GetID"
        )
        return nil
    end

    return result
end

--- Gets the current life/health of a static object
---@param staticObject table The static object
---@return number? life The current life value or nil on error
---@usage local life = GetStaticLife(staticObj)
function GetStaticLife(staticObject)
    if not staticObject then
        _HarnessInternal.log.error(
            "GetStaticLife requires valid static object",
            "StaticObject.GetLife"
        )
        return nil
    end

    local success, result = pcall(staticObject.getLife, staticObject)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get static object life: " .. tostring(result),
            "StaticObject.GetLife"
        )
        return nil
    end

    return result
end

--- Gets the cargo display name of a static object
---@param staticObject table The static object
---@return string? displayName The cargo display name or nil on error
---@usage local cargoName = GetStaticCargoDisplayName(staticObj)
function GetStaticCargoDisplayName(staticObject)
    if not staticObject then
        _HarnessInternal.log.error(
            "GetStaticCargoDisplayName requires valid static object",
            "StaticObject.GetCargoDisplayName"
        )
        return nil
    end

    local success, result = pcall(staticObject.getCargoDisplayName, staticObject)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get cargo display name: " .. tostring(result),
            "StaticObject.GetCargoDisplayName"
        )
        return nil
    end

    return result
end

--- Gets the cargo weight of a static object
---@param staticObject table The static object
---@return number? weight The cargo weight in kg or nil on error
---@usage local weight = GetStaticCargoWeight(staticObj)
function GetStaticCargoWeight(staticObject)
    if not staticObject then
        _HarnessInternal.log.error(
            "GetStaticCargoWeight requires valid static object",
            "StaticObject.GetCargoWeight"
        )
        return nil
    end

    local success, result = pcall(staticObject.getCargoWeight, staticObject)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get cargo weight: " .. tostring(result),
            "StaticObject.GetCargoWeight"
        )
        return nil
    end

    return result
end

--- Destroys a static object
---@param staticObject table The static object to destroy
---@return boolean? success Returns true if successful, nil on error
---@usage DestroyStaticObject(staticObj)
function DestroyStaticObject(staticObject)
    if not staticObject then
        _HarnessInternal.log.error(
            "DestroyStatic requires valid static object",
            "StaticObject.Destroy"
        )
        return nil
    end

    -- Log that delete API was triggered
    _HarnessInternal.log.info("DestroyStaticObject triggered", "StaticObject.Destroy")

    local success, result = pcall(staticObject.destroy, staticObject)
    if not success then
        _HarnessInternal.log.error(
            "Failed to destroy static object: " .. tostring(result),
            "StaticObject.Destroy"
        )
        return nil
    end

    _HarnessInternal.log.info("Static object destroyed", "StaticObject.Destroy")
    return true
end

--- Gets the category of a static object
---@param staticObject table The static object
---@return number? category The object category or nil on error
---@usage local category = GetStaticCategory(staticObj)
function GetStaticCategory(staticObject)
    if not staticObject then
        _HarnessInternal.log.error(
            "GetStaticCategory requires valid static object",
            "StaticObject.GetCategory"
        )
        return nil
    end

    local success, result = pcall(staticObject.getCategory, staticObject)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get static object category: " .. tostring(result),
            "StaticObject.GetCategory"
        )
        return nil
    end

    return result
end

--- Gets the type name of a static object
---@param staticObject table The static object
---@return string? typeName The type name or nil on error
---@usage local typeName = GetStaticTypeName(staticObj)
function GetStaticTypeName(staticObject)
    if not staticObject then
        _HarnessInternal.log.error(
            "GetStaticTypeName requires valid static object",
            "StaticObject.GetTypeName"
        )
        return nil
    end

    local success, result = pcall(staticObject.getTypeName, staticObject)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get static object type name: " .. tostring(result),
            "StaticObject.GetTypeName"
        )
        return nil
    end

    return result
end

--- Gets the description of a static object
---@param staticObject table The static object
---@return table? desc The description table or nil on error
---@usage local desc = GetStaticDesc(staticObj)
function GetStaticDesc(staticObject)
    if not staticObject then
        _HarnessInternal.log.error(
            "GetStaticDesc requires valid static object",
            "StaticObject.GetDesc"
        )
        return nil
    end

    local success, result = pcall(staticObject.getDesc, staticObject)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get static object description: " .. tostring(result),
            "StaticObject.GetDesc"
        )
        return nil
    end

    return result
end

--- Checks if a static object exists
---@param staticObject table The static object to check
---@return boolean? exists Returns true if exists, false if not, nil on error
---@usage local exists = IsStaticExist(staticObj)
function IsStaticExist(staticObject)
    if not staticObject then
        _HarnessInternal.log.error(
            "IsStaticExist requires valid static object",
            "StaticObject.IsExist"
        )
        return nil
    end

    local success, result = pcall(staticObject.isExist, staticObject)
    if not success then
        _HarnessInternal.log.error(
            "Failed to check static object existence: " .. tostring(result),
            "StaticObject.IsExist"
        )
        return nil
    end

    return result
end

--- Gets the coalition of a static object
---@param staticObject table The static object
---@return number? coalition The coalition ID or nil on error
---@usage local coalition = GetStaticCoalition(staticObj)
function GetStaticCoalition(staticObject)
    if not staticObject then
        _HarnessInternal.log.error(
            "GetStaticCoalition requires valid static object",
            "StaticObject.GetCoalition"
        )
        return nil
    end

    local success, result = pcall(staticObject.getCoalition, staticObject)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get static object coalition: " .. tostring(result),
            "StaticObject.GetCoalition"
        )
        return nil
    end

    return result
end

--- Gets the country of a static object
---@param staticObject table The static object
---@return number? country The country ID or nil on error
---@usage local country = GetStaticCountry(staticObj)
function GetStaticCountry(staticObject)
    if not staticObject then
        _HarnessInternal.log.error(
            "GetStaticCountry requires valid static object",
            "StaticObject.GetCountry"
        )
        return nil
    end

    local success, result = pcall(staticObject.getCountry, staticObject)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get static object country: " .. tostring(result),
            "StaticObject.GetCountry"
        )
        return nil
    end

    return result
end

--- Gets the 3D position point of a static object
---@param staticObject table The static object
---@return table? point Position table with x, y, z coordinates or nil on error
---@usage local point = GetStaticPoint(staticObj)
function GetStaticPoint(staticObject)
    if not staticObject then
        _HarnessInternal.log.error(
            "GetStaticPoint requires valid static object",
            "StaticObject.GetPoint"
        )
        return nil
    end

    local success, result = pcall(staticObject.getPoint, staticObject)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get static object point: " .. tostring(result),
            "StaticObject.GetPoint"
        )
        return nil
    end

    return result
end

--- Gets the position and orientation of a static object
---@param staticObject table The static object
---@return table? position Position table with p (point) and x,y,z vectors or nil on error
---@usage local pos = GetStaticPosition(staticObj)
function GetStaticPosition(staticObject)
    if not staticObject then
        _HarnessInternal.log.error(
            "GetStaticPosition requires valid static object",
            "StaticObject.GetPosition"
        )
        return nil
    end

    local success, result = pcall(staticObject.getPosition, staticObject)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get static object position: " .. tostring(result),
            "StaticObject.GetPosition"
        )
        return nil
    end

    return result
end

--- Gets the velocity vector of a static object
---@param staticObject table The static object
---@return table? velocity Velocity vector with x, y, z components or nil on error
---@usage local vel = GetStaticVelocity(staticObj)
function GetStaticVelocity(staticObject)
    if not staticObject then
        _HarnessInternal.log.error(
            "GetStaticVelocity requires valid static object",
            "StaticObject.GetVelocity"
        )
        return nil
    end

    local success, result = pcall(staticObject.getVelocity, staticObject)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get static object velocity: " .. tostring(result),
            "StaticObject.GetVelocity"
        )
        return nil
    end

    return result
end

--- Creates a new static object (DCS-native signature)
---@param countryId number The country ID that will own the static object
---@param staticData table Static object data table with required fields: name, type, x, y
---@return table? staticObject The created static object or nil on error
---@usage local static = CreateStaticObject(country.id.USA, { name = "dyn", type = "Cafe", x = 1000, y = 2000 })
function CreateStaticObject(countryId, staticData)
    if not countryId or type(countryId) ~= "number" then
        _HarnessInternal.log.error(
            "CreateStaticObject requires valid numeric country ID",
            "StaticObject.Create"
        )
        return nil
    end

    if not staticData or type(staticData) ~= "table" then
        _HarnessInternal.log.error(
            "CreateStaticObject requires valid static data table",
            "StaticObject.Create"
        )
        return nil
    end

    -- Validate required DCS fields
    if not staticData.type or type(staticData.type) ~= "string" then
        _HarnessInternal.log.error(
            "CreateStaticObject requires valid type in static data",
            "StaticObject.Create"
        )
        return nil
    end

    if type(staticData.x) ~= "number" or type(staticData.y) ~= "number" then
        _HarnessInternal.log.error(
            "CreateStaticObject requires valid x and y coordinates",
            "StaticObject.Create"
        )
        return nil
    end

    -- Heading is radians per schema; default to 0 if missing or invalid
    if staticData.heading ~= nil and type(staticData.heading) ~= "number" then
        _HarnessInternal.log.error(
            "CreateStaticObject heading must be a number (radians) if provided",
            "StaticObject.Create"
        )
        return nil
    end
    if staticData.heading == nil then
        staticData.heading = 0
    end

    -- Log that create API was triggered
    _HarnessInternal.log.info(
        "CreateStaticObject triggered: type="
            .. tostring(staticData.type)
            .. " country="
            .. tostring(countryId)
            .. " name="
            .. tostring(staticData.name),
        "StaticObject.Create"
    )

    local created = AddCoalitionStaticObject(countryId, staticData)
    if created then
        _HarnessInternal.log.info("Static object created", "StaticObject.Create")
    end
    return created
end
-- ==== END: src/staticobject.lua ====

-- ==== BEGIN: src/time.lua ====
--[[
==================================================================================================
    TIME MODULE
    Time and scheduling utilities
==================================================================================================
]]
--- Get mission time
---@return number time Current mission time in seconds
---@usage local time = GetTime()
function GetTime()
    local success, time = pcall(timer.getTime)
    if not success then
        _HarnessInternal.log.error("Failed to get mission time: " .. tostring(time), "GetTime")
        return 0
    end

    return time
end

--- Get absolute time
---@return number time Absolute time in seconds since midnight
---@usage local absTime = GetAbsTime()
function GetAbsTime()
    local success, time = pcall(timer.getAbsTime)
    if not success then
        _HarnessInternal.log.error("Failed to get absolute time: " .. tostring(time), "GetAbsTime")
        return 0
    end

    return time
end

--- Get mission start time
---@return number time Mission start time in seconds
---@usage local startTime = GetTime0()
function GetTime0()
    local success, time = pcall(timer.getTime0)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get mission start time: " .. tostring(time),
            "GetTime0"
        )
        return 0
    end

    return time
end

--- Format time as HH:MM:SS
---@param seconds number Time in seconds
---@return string formatted Time string in HH:MM:SS format
---@usage local timeStr = FormatTime(3661) -- "01:01:01"
function FormatTime(seconds)
    if type(seconds) ~= "number" then
        _HarnessInternal.log.error("FormatTime requires number", "FormatTime")
        return "00:00:00"
    end

    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = math.floor(seconds % 60)

    return string.format("%02d:%02d:%02d", hours, minutes, secs)
end

--- Format time as MM:SS
---@param seconds number Time in seconds
---@return string formatted Time string in MM:SS format
---@usage local timeStr = FormatTimeShort(125) -- "02:05"
function FormatTimeShort(seconds)
    if type(seconds) ~= "number" then
        _HarnessInternal.log.error("FormatTimeShort requires number", "FormatTimeShort")
        return "00:00"
    end

    local minutes = math.floor(seconds / 60)
    local secs = math.floor(seconds % 60)

    return string.format("%02d:%02d", minutes, secs)
end

--- Get current mission time as table
---@return table time Table with hours, minutes, seconds fields
---@usage local t = GetMissionTime() -- {hours=14, minutes=30, seconds=45}
function GetMissionTime()
    local currentTime = GetAbsTime()

    local hours = math.floor(currentTime / 3600)
    local minutes = math.floor((currentTime % 3600) / 60)
    local seconds = math.floor(currentTime % 60)

    return {
        hours = hours,
        minutes = minutes,
        seconds = seconds,
    }
end

--- Check if current time is night (19:00-06:59)
---@return boolean isNight True if between 19:00 and 06:59
---@usage if IsNightTime() then ... end
function IsNightTime()
    local absTime = GetAbsTime()
    local secondsInDay = absTime % 86400
    local hour = math.floor(secondsInDay / 3600)

    return hour >= 19 or hour < 7
end

--- Schedule a function (no recurring - pure function)
---@param func function Function to schedule
---@param args any? Arguments to pass to function
---@param delay number? Delay in seconds (default 0)
---@return number? timerId Timer ID for cancellation, nil on error
---@usage local id = ScheduleOnce(myFunc, {arg1, arg2}, 10)
function ScheduleOnce(func, args, delay)
    if type(func) ~= "function" then
        _HarnessInternal.log.error("ScheduleOnce requires function", "ScheduleOnce")
        return nil
    end

    delay = delay or 0
    local time = GetTime() + delay

    local success, timerId = pcall(timer.scheduleFunction, func, args, time)
    if not success then
        _HarnessInternal.log.error(
            "Failed to schedule function: " .. tostring(timerId),
            "ScheduleOnce"
        )
        return nil
    end

    return timerId
end

--- Cancel scheduled function
---@param timerId number? Timer ID to cancel
---@return boolean success True if cancelled successfully
---@usage CancelSchedule(timerId)
function CancelSchedule(timerId)
    if not timerId then
        return false
    end

    local success, result = pcall(timer.removeFunction, timerId)
    if not success then
        _HarnessInternal.log.warn(
            "Failed to cancel scheduled function: " .. tostring(result),
            "CancelSchedule"
        )
        return false
    end

    return true
end

--- Reschedule function
---@param timerId number Timer ID to reschedule
---@param newTime number New execution time in seconds
---@return boolean success True if rescheduled successfully
---@usage RescheduleFunction(timerId, GetTime() + 30)
function RescheduleFunction(timerId, newTime)
    if not timerId or type(newTime) ~= "number" then
        _HarnessInternal.log.error(
            "RescheduleFunction requires timerId and new time",
            "RescheduleFunction"
        )
        return false
    end

    local success, result = pcall(timer.setFunctionTime, timerId, newTime)
    if not success then
        _HarnessInternal.log.error(
            "Failed to reschedule function: " .. tostring(result),
            "RescheduleFunction"
        )
        return false
    end

    return true
end

--- Convert seconds to time components
---@param seconds number Time in seconds
---@return table components Table with hours, minutes, seconds fields
---@usage local t = SecondsToTime(3661) -- {hours=1, minutes=1, seconds=1}
function SecondsToTime(seconds)
    if type(seconds) ~= "number" then
        _HarnessInternal.log.error("SecondsToTime requires number", "SecondsToTime")
        return { hours = 0, minutes = 0, seconds = 0 }
    end

    return {
        hours = math.floor(seconds / 3600),
        minutes = math.floor((seconds % 3600) / 60),
        seconds = math.floor(seconds % 60),
    }
end

--- Convert time components to seconds
---@param hours number? Hours (default 0)
---@param minutes number? Minutes (default 0)
---@param seconds number? Seconds (default 0)
---@return number totalSeconds Total seconds
---@usage local secs = TimeToSeconds(1, 30, 45) -- 5445
function TimeToSeconds(hours, minutes, seconds)
    hours = hours or 0
    minutes = minutes or 0
    seconds = seconds or 0

    if type(hours) ~= "number" or type(minutes) ~= "number" or type(seconds) ~= "number" then
        _HarnessInternal.log.error("TimeToSeconds requires numeric values", "TimeToSeconds")
        return 0
    end

    return hours * 3600 + minutes * 60 + seconds
end

--- Get elapsed time since mission start
---@return number elapsed Mission elapsed time in seconds
---@usage local elapsed = GetElapsedTime()
function GetElapsedTime()
    return GetTime()
end

--- Get elapsed real time since mission start
---@return number elapsed Real elapsed time in seconds
---@usage local realElapsed = GetElapsedRealTime()
function GetElapsedRealTime()
    return GetAbsTime() - GetTime0()
end
-- ==== END: src/time.lua ====

-- ==== BEGIN: src/trees.lua ====
--[[
==================================================================================================
    TREE STRUCTURES MODULE
    Tree data structures for DCS World scripting
==================================================================================================
]]

-- Binary Search Tree Node
local function BSTNode(key, value)
    return {
        key = key,
        value = value,
        left = nil,
        right = nil,
        parent = nil,
    }
end

-- Binary Search Tree Implementation
--- Create a new Binary Search Tree
---@param compareFunc function? Custom comparison function(a, b) returns -1, 0, or 1
---@return table bst New BST instance
---@usage local bst = BinarySearchTree()
function BinarySearchTree(compareFunc)
    local bst = {
        _root = nil,
        _size = 0,
        _compare = compareFunc or function(a, b)
            if a < b then
                return -1
            elseif a > b then
                return 1
            else
                return 0
            end
        end,
    }

    --- Insert key-value pair
    ---@param key any Key to insert
    ---@param value any? Value associated with key
    ---@usage bst:insert(5, "five")
    function bst:insert(key, value)
        local newNode = BSTNode(key, value)

        if not self._root then
            self._root = newNode
            self._size = self._size + 1
            return
        end

        local current = self._root
        while true do
            local cmp = self._compare(key, current.key)
            if cmp == 0 then
                -- Update existing value
                current.value = value
                return
            elseif cmp < 0 then
                if not current.left then
                    current.left = newNode
                    newNode.parent = current
                    self._size = self._size + 1
                    return
                end
                current = current.left
            else
                if not current.right then
                    current.right = newNode
                    newNode.parent = current
                    self._size = self._size + 1
                    return
                end
                current = current.right
            end
        end
    end

    --- Find value by key
    ---@param key any Key to search for
    ---@return any? value Value if found, nil otherwise
    ---@usage local value = bst:find(5)
    function bst:find(key)
        local node = self:_findNode(key)
        return node and node.value or nil
    end

    --- Remove key from tree
    ---@param key any Key to remove
    ---@return boolean removed True if key was removed
    ---@usage bst:remove(5)
    function bst:remove(key)
        local node = self:_findNode(key)
        if not node then
            return false
        end

        self:_removeNode(node)
        self._size = self._size - 1
        return true
    end

    --- Get minimum key
    ---@return any? key Minimum key or nil if empty
    ---@usage local min = bst:min()
    function bst:min()
        if not self._root then
            return nil
        end
        local node = self:_minNode(self._root)
        return node.key
    end

    --- Get maximum key
    ---@return any? key Maximum key or nil if empty
    ---@usage local max = bst:max()
    function bst:max()
        if not self._root then
            return nil
        end
        local node = self:_maxNode(self._root)
        return node.key
    end

    --- Check if tree contains key
    ---@param key any Key to check
    ---@return boolean contains True if tree contains key
    ---@usage if bst:contains(5) then ... end
    function bst:contains(key)
        return self:_findNode(key) ~= nil
    end

    --- Get number of nodes
    ---@return number size Number of nodes
    ---@usage local size = bst:size()
    function bst:size()
        return self._size
    end

    --- Check if tree is empty
    ---@return boolean empty True if tree is empty
    ---@usage if bst:isEmpty() then ... end
    function bst:isEmpty()
        return self._size == 0
    end

    --- Clear all nodes
    ---@usage bst:clear()
    function bst:clear()
        self._root = nil
        self._size = 0
    end

    --- In-order traversal
    ---@param callback function Function(key, value) called for each node
    ---@usage bst:inorder(function(k, v) print(k, v) end)
    function bst:inorder(callback)
        self:_inorderRecursive(self._root, callback)
    end

    --- Get array of keys in sorted order
    ---@return table keys Array of keys
    ---@usage local keys = bst:keys()
    function bst:keys()
        local keys = {}
        self:inorder(function(k, v)
            table.insert(keys, k)
        end)
        return keys
    end

    -- Internal methods
    function bst:_findNode(key)
        local current = self._root
        while current do
            local cmp = self._compare(key, current.key)
            if cmp == 0 then
                return current
            elseif cmp < 0 then
                current = current.left
            else
                current = current.right
            end
        end
        return nil
    end

    function bst:_minNode(node)
        while node.left do
            node = node.left
        end
        return node
    end

    function bst:_maxNode(node)
        while node.right do
            node = node.right
        end
        return node
    end

    function bst:_removeNode(node)
        if not node.left and not node.right then
            -- Leaf node
            if node.parent then
                if node.parent.left == node then
                    node.parent.left = nil
                else
                    node.parent.right = nil
                end
            else
                self._root = nil
            end
        elseif not node.left or not node.right then
            -- One child
            local child = node.left or node.right
            if node.parent then
                if node.parent.left == node then
                    node.parent.left = child
                else
                    node.parent.right = child
                end
                child.parent = node.parent
            else
                self._root = child
                child.parent = nil
            end
        else
            -- Two children - replace with inorder successor
            local successor = self:_minNode(node.right)
            node.key = successor.key
            node.value = successor.value
            self:_removeNode(successor)
        end
    end

    function bst:_inorderRecursive(node, callback)
        if not node then
            return
        end
        self:_inorderRecursive(node.left, callback)
        callback(node.key, node.value)
        self:_inorderRecursive(node.right, callback)
    end

    return bst
end

-- Red-Black Tree Node
local RBColor = { RED = 1, BLACK = 2 }

local function RBNode(key, value)
    return {
        key = key,
        value = value,
        color = RBColor.RED,
        left = nil,
        right = nil,
        parent = nil,
    }
end

-- Sentinel node for RB tree
local RBNil = {
    color = RBColor.BLACK,
    left = nil,
    right = nil,
    parent = nil,
}

-- Red-Black Tree Implementation
--- Create a new Red-Black Tree (self-balancing BST)
---@param compareFunc function? Custom comparison function(a, b) returns -1, 0, or 1
---@return table rbtree New RB tree instance
---@usage local rbt = RedBlackTree()
function RedBlackTree(compareFunc)
    local rbt = {
        _root = RBNil,
        _size = 0,
        _compare = compareFunc or function(a, b)
            if a < b then
                return -1
            elseif a > b then
                return 1
            else
                return 0
            end
        end,
    }

    --- Insert key-value pair
    ---@param key any Key to insert
    ---@param value any? Value associated with key
    ---@usage rbt:insert(5, "five")
    function rbt:insert(key, value)
        local newNode = RBNode(key, value)
        newNode.left = RBNil
        newNode.right = RBNil

        local parent = nil
        local current = self._root

        while current ~= RBNil do
            parent = current
            local cmp = self._compare(key, current.key)
            if cmp == 0 then
                -- Update existing value
                current.value = value
                return
            elseif cmp < 0 then
                current = current.left
            else
                current = current.right
            end
        end

        newNode.parent = parent

        if parent == nil then
            self._root = newNode
        elseif self._compare(key, parent.key) < 0 then
            parent.left = newNode
        else
            parent.right = newNode
        end

        self._size = self._size + 1
        self:_insertFixup(newNode)
    end

    --- Find value by key
    ---@param key any Key to search for
    ---@return any? value Value if found, nil otherwise
    ---@usage local value = rbt:find(5)
    function rbt:find(key)
        local node = self:_findNode(key)
        return (node ~= RBNil) and node.value or nil
    end

    --- Remove key from tree
    ---@param key any Key to remove
    ---@return boolean removed True if key was removed
    ---@usage rbt:remove(5)
    function rbt:remove(key)
        local node = self:_findNode(key)
        if node == RBNil then
            return false
        end

        self:_removeNode(node)
        self._size = self._size - 1
        return true
    end

    --- Get minimum key
    ---@return any? key Minimum key or nil if empty
    ---@usage local min = rbt:min()
    function rbt:min()
        if self._root == RBNil then
            return nil
        end
        local node = self:_minNode(self._root)
        return node.key
    end

    --- Get maximum key
    ---@return any? key Maximum key or nil if empty
    ---@usage local max = rbt:max()
    function rbt:max()
        if self._root == RBNil then
            return nil
        end
        local node = self:_maxNode(self._root)
        return node.key
    end

    --- Get number of nodes
    ---@return number size Number of nodes
    ---@usage local size = rbt:size()
    function rbt:size()
        return self._size
    end

    --- Check if tree is empty
    ---@return boolean empty True if tree is empty
    ---@usage if rbt:isEmpty() then ... end
    function rbt:isEmpty()
        return self._size == 0
    end

    --- Clear all nodes
    ---@usage rbt:clear()
    function rbt:clear()
        self._root = RBNil
        self._size = 0
    end

    -- Internal methods
    function rbt:_findNode(key)
        local current = self._root
        while current ~= RBNil do
            local cmp = self._compare(key, current.key)
            if cmp == 0 then
                return current
            elseif cmp < 0 then
                current = current.left
            else
                current = current.right
            end
        end
        return RBNil
    end

    function rbt:_minNode(node)
        while node.left ~= RBNil do
            node = node.left
        end
        return node
    end

    function rbt:_maxNode(node)
        while node.right ~= RBNil do
            node = node.right
        end
        return node
    end

    function rbt:_rotateLeft(x)
        local y = x.right
        x.right = y.left

        if y.left ~= RBNil then
            y.left.parent = x
        end

        y.parent = x.parent

        if x.parent == nil then
            self._root = y
        elseif x == x.parent.left then
            x.parent.left = y
        else
            x.parent.right = y
        end

        y.left = x
        x.parent = y
    end

    function rbt:_rotateRight(x)
        local y = x.left
        x.left = y.right

        if y.right ~= RBNil then
            y.right.parent = x
        end

        y.parent = x.parent

        if x.parent == nil then
            self._root = y
        elseif x == x.parent.right then
            x.parent.right = y
        else
            x.parent.left = y
        end

        y.right = x
        x.parent = y
    end

    function rbt:_insertFixup(z)
        while z.parent and z.parent.color == RBColor.RED do
            if z.parent == z.parent.parent.left then
                local y = z.parent.parent.right
                if y.color == RBColor.RED then
                    z.parent.color = RBColor.BLACK
                    y.color = RBColor.BLACK
                    z.parent.parent.color = RBColor.RED
                    z = z.parent.parent
                else
                    if z == z.parent.right then
                        z = z.parent
                        self:_rotateLeft(z)
                    end
                    z.parent.color = RBColor.BLACK
                    z.parent.parent.color = RBColor.RED
                    self:_rotateRight(z.parent.parent)
                end
            else
                local y = z.parent.parent.left
                if y.color == RBColor.RED then
                    z.parent.color = RBColor.BLACK
                    y.color = RBColor.BLACK
                    z.parent.parent.color = RBColor.RED
                    z = z.parent.parent
                else
                    if z == z.parent.left then
                        z = z.parent
                        self:_rotateRight(z)
                    end
                    z.parent.color = RBColor.BLACK
                    z.parent.parent.color = RBColor.RED
                    self:_rotateLeft(z.parent.parent)
                end
            end
        end
        self._root.color = RBColor.BLACK
    end

    function rbt:_removeNode(z)
        local y = z
        local yOrigColor = y.color
        local x

        if z.left == RBNil then
            x = z.right
            self:_transplant(z, z.right)
        elseif z.right == RBNil then
            x = z.left
            self:_transplant(z, z.left)
        else
            y = self:_minNode(z.right)
            yOrigColor = y.color
            x = y.right

            if y.parent == z then
                x.parent = y
            else
                self:_transplant(y, y.right)
                y.right = z.right
                y.right.parent = y
            end

            self:_transplant(z, y)
            y.left = z.left
            y.left.parent = y
            y.color = z.color
        end

        if yOrigColor == RBColor.BLACK then
            self:_deleteFixup(x)
        end
    end

    function rbt:_transplant(u, v)
        if u.parent == nil then
            self._root = v
        elseif u == u.parent.left then
            u.parent.left = v
        else
            u.parent.right = v
        end
        v.parent = u.parent
    end

    function rbt:_deleteFixup(x)
        while x ~= self._root and x.color == RBColor.BLACK do
            if x == x.parent.left then
                local w = x.parent.right
                if w.color == RBColor.RED then
                    w.color = RBColor.BLACK
                    x.parent.color = RBColor.RED
                    self:_rotateLeft(x.parent)
                    w = x.parent.right
                end

                if w.left.color == RBColor.BLACK and w.right.color == RBColor.BLACK then
                    w.color = RBColor.RED
                    x = x.parent
                else
                    if w.right.color == RBColor.BLACK then
                        w.left.color = RBColor.BLACK
                        w.color = RBColor.RED
                        self:_rotateRight(w)
                        w = x.parent.right
                    end
                    w.color = x.parent.color
                    x.parent.color = RBColor.BLACK
                    w.right.color = RBColor.BLACK
                    self:_rotateLeft(x.parent)
                    x = self._root
                end
            else
                local w = x.parent.left
                if w.color == RBColor.RED then
                    w.color = RBColor.BLACK
                    x.parent.color = RBColor.RED
                    self:_rotateRight(x.parent)
                    w = x.parent.left
                end

                if w.right.color == RBColor.BLACK and w.left.color == RBColor.BLACK then
                    w.color = RBColor.RED
                    x = x.parent
                else
                    if w.left.color == RBColor.BLACK then
                        w.right.color = RBColor.BLACK
                        w.color = RBColor.RED
                        self:_rotateLeft(w)
                        w = x.parent.left
                    end
                    w.color = x.parent.color
                    x.parent.color = RBColor.BLACK
                    w.left.color = RBColor.BLACK
                    self:_rotateRight(x.parent)
                    x = self._root
                end
            end
        end
        x.color = RBColor.BLACK
    end

    return rbt
end

-- Trie (Prefix Tree) Implementation
--- Create a new Trie for string operations
---@return table trie New trie instance
---@usage local trie = Trie()
function Trie()
    local trie = {
        _root = { children = {}, isEnd = false },
        _size = 0,
    }

    --- Insert word into trie
    ---@param word string Word to insert
    ---@usage trie:insert("hello")
    function trie:insert(word)
        if type(word) ~= "string" then
            _HarnessInternal.log.error("Trie:insert requires string", "Trees.Trie")
            return
        end

        local node = self._root
        local isNew = false

        for i = 1, #word do
            local char = word:sub(i, i)
            if not node.children[char] then
                node.children[char] = { children = {}, isEnd = false }
                isNew = true
            end
            node = node.children[char]
        end

        if not node.isEnd then
            node.isEnd = true
            self._size = self._size + 1
        end
    end

    --- Search for word in trie
    ---@param word string Word to search for
    ---@return boolean found True if word exists
    ---@usage if trie:search("hello") then ... end
    function trie:search(word)
        if type(word) ~= "string" then
            return false
        end

        local node = self._root
        for i = 1, #word do
            local char = word:sub(i, i)
            if not node.children[char] then
                return false
            end
            node = node.children[char]
        end

        return node.isEnd
    end

    --- Check if any word starts with prefix
    ---@param prefix string Prefix to check
    ---@return boolean hasPrefix True if any word has this prefix
    ---@usage if trie:startsWith("hel") then ... end
    function trie:startsWith(prefix)
        if type(prefix) ~= "string" then
            return false
        end

        local node = self._root
        for i = 1, #prefix do
            local char = prefix:sub(i, i)
            if not node.children[char] then
                return false
            end
            node = node.children[char]
        end

        return true
    end

    --- Get all words with given prefix
    ---@param prefix string? Prefix to search (empty for all words)
    ---@return table words Array of words with prefix
    ---@usage local words = trie:wordsWithPrefix("hel")
    function trie:wordsWithPrefix(prefix)
        prefix = prefix or ""
        if type(prefix) ~= "string" then
            return {}
        end

        local node = self._root
        for i = 1, #prefix do
            local char = prefix:sub(i, i)
            if not node.children[char] then
                return {}
            end
            node = node.children[char]
        end

        local words = {}
        self:_collectWords(node, prefix, words)
        return words
    end

    --- Delete word from trie
    ---@param word string Word to delete
    ---@return boolean deleted True if word was deleted
    ---@usage trie:delete("hello")
    function trie:delete(word)
        if type(word) ~= "string" then
            return false
        end

        if not self:search(word) then
            return false
        end

        self:_deleteHelper(self._root, word, 1)
        self._size = self._size - 1
        return true
    end

    --- Get number of words in trie
    ---@return number size Number of words
    ---@usage local count = trie:size()
    function trie:size()
        return self._size
    end

    --- Check if trie is empty
    ---@return boolean empty True if trie is empty
    ---@usage if trie:isEmpty() then ... end
    function trie:isEmpty()
        return self._size == 0
    end

    --- Clear all words
    ---@usage trie:clear()
    function trie:clear()
        self._root = { children = {}, isEnd = false }
        self._size = 0
    end

    -- Internal methods
    function trie:_collectWords(node, prefix, words)
        if node.isEnd then
            table.insert(words, prefix)
        end

        for char, child in pairs(node.children) do
            self:_collectWords(child, prefix .. char, words)
        end
    end

    function trie:_deleteHelper(node, word, index)
        if index > #word then
            node.isEnd = false
            return next(node.children) == nil and not node.isEnd
        end

        local char = word:sub(index, index)
        local child = node.children[char]

        if not child then
            return false
        end

        local shouldDelete = self:_deleteHelper(child, word, index + 1)

        if shouldDelete then
            node.children[char] = nil
            return next(node.children) == nil and not node.isEnd
        end

        return false
    end

    return trie
end

-- AVL Tree Node
local function AVLNode(key, value)
    return {
        key = key,
        value = value,
        height = 1,
        left = nil,
        right = nil,
    }
end

-- AVL Tree Implementation (self-balancing BST)
--- Create a new AVL Tree
---@param compareFunc function? Custom comparison function(a, b) returns -1, 0, or 1
---@return table avl New AVL tree instance
---@usage local avl = AVLTree()
function AVLTree(compareFunc)
    local avl = {
        _root = nil,
        _size = 0,
        _compare = compareFunc or function(a, b)
            if a < b then
                return -1
            elseif a > b then
                return 1
            else
                return 0
            end
        end,
    }

    --- Insert key-value pair
    ---@param key any Key to insert
    ---@param value any? Value associated with key
    ---@usage avl:insert(5, "five")
    function avl:insert(key, value)
        self._root = self:_insertNode(self._root, key, value)
    end

    --- Find value by key
    ---@param key any Key to search for
    ---@return any? value Value if found, nil otherwise
    ---@usage local value = avl:find(5)
    function avl:find(key)
        local node = self:_findNode(self._root, key)
        return node and node.value or nil
    end

    --- Remove key from tree
    ---@param key any Key to remove
    ---@return boolean removed True if key was removed
    ---@usage avl:remove(5)
    function avl:remove(key)
        local oldSize = self._size
        self._root = self:_removeNode(self._root, key)
        return self._size < oldSize
    end

    --- Get number of nodes
    ---@return number size Number of nodes
    ---@usage local size = avl:size()
    function avl:size()
        return self._size
    end

    --- Check if tree is empty
    ---@return boolean empty True if tree is empty
    ---@usage if avl:isEmpty() then ... end
    function avl:isEmpty()
        return self._size == 0
    end

    --- Clear all nodes
    ---@usage avl:clear()
    function avl:clear()
        self._root = nil
        self._size = 0
    end

    -- Internal methods
    function avl:_getHeight(node)
        return node and node.height or 0
    end

    function avl:_updateHeight(node)
        if node then
            node.height = 1 + math.max(self:_getHeight(node.left), self:_getHeight(node.right))
        end
    end

    function avl:_getBalance(node)
        return node and (self:_getHeight(node.left) - self:_getHeight(node.right)) or 0
    end

    function avl:_rotateRight(y)
        local x = y.left
        local T2 = x.right

        x.right = y
        y.left = T2

        self:_updateHeight(y)
        self:_updateHeight(x)

        return x
    end

    function avl:_rotateLeft(x)
        local y = x.right
        local T2 = y.left

        y.left = x
        x.right = T2

        self:_updateHeight(x)
        self:_updateHeight(y)

        return y
    end

    function avl:_insertNode(node, key, value)
        if not node then
            self._size = self._size + 1
            return AVLNode(key, value)
        end

        local cmp = self._compare(key, node.key)
        if cmp < 0 then
            node.left = self:_insertNode(node.left, key, value)
        elseif cmp > 0 then
            node.right = self:_insertNode(node.right, key, value)
        else
            -- Update existing value
            node.value = value
            return node
        end

        self:_updateHeight(node)

        local balance = self:_getBalance(node)

        -- Left Left
        if balance > 1 and self._compare(key, node.left.key) < 0 then
            return self:_rotateRight(node)
        end

        -- Right Right
        if balance < -1 and self._compare(key, node.right.key) > 0 then
            return self:_rotateLeft(node)
        end

        -- Left Right
        if balance > 1 and self._compare(key, node.left.key) > 0 then
            node.left = self:_rotateLeft(node.left)
            return self:_rotateRight(node)
        end

        -- Right Left
        if balance < -1 and self._compare(key, node.right.key) < 0 then
            node.right = self:_rotateRight(node.right)
            return self:_rotateLeft(node)
        end

        return node
    end

    function avl:_findNode(node, key)
        if not node then
            return nil
        end

        local cmp = self._compare(key, node.key)
        if cmp < 0 then
            return self:_findNode(node.left, key)
        elseif cmp > 0 then
            return self:_findNode(node.right, key)
        else
            return node
        end
    end

    function avl:_minNode(node)
        while node.left do
            node = node.left
        end
        return node
    end

    function avl:_removeNode(node, key)
        if not node then
            return nil
        end

        local cmp = self._compare(key, node.key)
        if cmp < 0 then
            node.left = self:_removeNode(node.left, key)
        elseif cmp > 0 then
            node.right = self:_removeNode(node.right, key)
        else
            self._size = self._size - 1

            if not node.left or not node.right then
                return node.left or node.right
            end

            local temp = self:_minNode(node.right)
            node.key = temp.key
            node.value = temp.value
            node.right = self:_removeNode(node.right, temp.key)
            self._size = self._size + 1 -- Compensate for double decrement
        end

        self:_updateHeight(node)

        local balance = self:_getBalance(node)

        -- Left Left
        if balance > 1 and self:_getBalance(node.left) >= 0 then
            return self:_rotateRight(node)
        end

        -- Left Right
        if balance > 1 and self:_getBalance(node.left) < 0 then
            node.left = self:_rotateLeft(node.left)
            return self:_rotateRight(node)
        end

        -- Right Right
        if balance < -1 and self:_getBalance(node.right) <= 0 then
            return self:_rotateLeft(node)
        end

        -- Right Left
        if balance < -1 and self:_getBalance(node.right) > 0 then
            node.right = self:_rotateRight(node.right)
            return self:_rotateLeft(node)
        end

        return node
    end

    return avl
end
-- ==== END: src/trees.lua ====

-- ==== BEGIN: src/vector.lua ====
--[[
==================================================================================================
    VECTOR MODULE
    Vector types, operations, and utilities
==================================================================================================
]]

-- Vec2 Type Definition with metatables for operator overloading
local Vec2_mt = {}
Vec2_mt.__index = Vec2_mt

--- Creates a 2D vector (x, z coordinates)
---@param x number|table? X coordinate or table {x, z} or {[1], [2]}
---@param z number? Z coordinate (if x is not a table)
---@return table vec2 New Vec2 instance with metatables
---@usage local v = Vec2(100, 200) or Vec2({x=100, z=200})
function Vec2(x, z)
    if type(x) == "table" then
        -- Handle table input {x=1, z=2} or {1, 2} or {x=1, y=2} for DCS compat
        z = x.z or x.y or x[2] or 0
        x = x.x or x[1] or 0
    end

    local self = {
        x = x or 0,
        z = z or 0,
    }

    setmetatable(self, Vec2_mt)
    return self
end

-- Vec3 Type Definition with metatables for operator overloading
local Vec3_mt = {}
Vec3_mt.__index = Vec3_mt

--- Creates a 3D vector (x, y, z coordinates)
---@param x number|table? X coordinate or table {x, y, z} or {[1], [2], [3]}
---@param y number? Y coordinate (if x is not a table)
---@param z number? Z coordinate (if x is not a table)
---@return table vec3 New Vec3 instance with metatables
---@usage local v = Vec3(100, 50, 200) or Vec3({x=100, y=50, z=200})
function Vec3(x, y, z)
    if type(x) == "table" then
        -- Handle table input {x=1, y=2, z=3} or {1, 2, 3}
        z = x.z or x[3] or 0
        y = x.y or x[2] or 0
        x = x.x or x[1] or 0
    end

    local self = {
        x = x or 0,
        y = y or 0,
        z = z or 0,
    }

    setmetatable(self, Vec3_mt)
    return self
end

-- Type checking functions
--- Check if valid 3D vector (works with plain tables or Vec3 instances)
---@param vec any Value to check
---@return boolean isValid True if vec has numeric x, y, z components
---@usage if IsVec3(pos) then ... end
function IsVec3(vec)
    if not vec or type(vec) ~= "table" then
        return false
    end
    return type(vec.x) == "number" and type(vec.y) == "number" and type(vec.z) == "number"
end

--- Check if valid 2D vector (works with plain tables or Vec2 instances)
---@param vec any Value to check
---@return boolean isValid True if vec has numeric x, z components (or x, y for DCS compat)
---@usage if IsVec2(pos) then ... end
function IsVec2(vec)
    if not vec or type(vec) ~= "table" then
        return false
    end
    -- Support both x,z and x,y formats
    return type(vec.x) == "number" and (type(vec.z) == "number" or type(vec.y) == "number")
end

-- Conversion functions
--- Convert to Vec2 (from table, Vec2, or Vec3)
---@param t any Input value to convert
---@return table? vec2 Converted Vec2 or nil on error
---@usage local v2 = ToVec2({x=100, z=200})
function ToVec2(t)
    if not t then
        return nil
    end

    if getmetatable(t) == Vec2_mt then
        return t
    elseif getmetatable(t) == Vec3_mt then
        return Vec2(t.x, t.z)
    elseif type(t) == "table" then
        -- Support both {x,z} and {x,y} formats
        local z = t.z or t.y or t[2]
        return Vec2(t.x or t[1], z)
    else
        _HarnessInternal.log.error("ToVec2 requires table or vector type", "Vector.ToVec2")
        return nil
    end
end

--- Convert to Vec3 (from table, Vec2, or Vec3)
---@param t any Input value to convert
---@param altitude number? Y coordinate for Vec2 to Vec3 conversion (default 0)
---@return table? vec3 Converted Vec3 or nil on error
---@usage local v3 = ToVec3({x=100, y=50, z=200})
function ToVec3(t, altitude)
    if not t then
        return nil
    end

    if getmetatable(t) == Vec3_mt then
        return t
    elseif getmetatable(t) == Vec2_mt then
        return Vec3(t.x, altitude or 0, t.z)
    elseif type(t) == "table" then
        if t.y then
            -- Already has y component
            return Vec3(t.x or t[1], t.y or t[2], t.z or t[3])
        else
            -- Vec2-like table, use altitude parameter
            return Vec3(t.x or t[1], altitude or 0, t.z or t[2])
        end
    else
        _HarnessInternal.log.error("ToVec3 requires table or vector type", "Vector.ToVec3")
        return nil
    end
end

-- Basic vector operations (work with both plain tables and vector types)
--- Add vectors
---@param a table First vector
---@param b table Second vector
---@return table result Vector sum of a + b
---@usage local sum = VecAdd(v1, v2)
function VecAdd(a, b)
    if IsVec3(a) and IsVec3(b) then
        return Vec3(a.x + b.x, a.y + b.y, a.z + b.z)
    elseif IsVec2(a) and IsVec2(b) then
        return Vec2(a.x + b.x, (a.z or a.y) + (b.z or b.y))
    else
        _HarnessInternal.log.error(
            "VecAdd requires two valid vectors of same type",
            "Vector.VecAdd"
        )
        return Vec3()
    end
end

--- Subtract vectors
---@param a table First vector
---@param b table Second vector
---@return table result Vector difference of a - b
---@usage local diff = VecSub(v1, v2)
function VecSub(a, b)
    if IsVec3(a) and IsVec3(b) then
        return Vec3(a.x - b.x, a.y - b.y, a.z - b.z)
    elseif IsVec2(a) and IsVec2(b) then
        return Vec2(a.x - b.x, (a.z or a.y) - (b.z or b.y))
    else
        _HarnessInternal.log.error(
            "VecSub requires two valid vectors of same type",
            "Vector.VecSub"
        )
        return Vec3()
    end
end

--- Multiply vector by scalar
---@param vec table Vector to scale
---@param scalar number Scale factor
---@return table result Scaled vector
---@usage local scaled = VecScale(v, 2.5)
function VecScale(vec, scalar)
    if type(scalar) ~= "number" then
        _HarnessInternal.log.error("VecScale requires valid vector and number", "Vector.VecScale")
        return Vec3()
    end

    if IsVec3(vec) then
        return Vec3(vec.x * scalar, vec.y * scalar, vec.z * scalar)
    elseif IsVec2(vec) then
        return Vec2(vec.x * scalar, (vec.z or vec.y) * scalar)
    else
        _HarnessInternal.log.error("VecScale requires valid vector", "Vector.VecScale")
        return Vec3()
    end
end

--- Divide vector by scalar
---@param vec table Vector to divide
---@param scalar number Divisor (must not be 0)
---@return table result Divided vector
---@usage local divided = VecDiv(v, 2)
function VecDiv(vec, scalar)
    if type(scalar) ~= "number" or scalar == 0 then
        _HarnessInternal.log.error(
            "VecDiv requires valid vector and non-zero number",
            "Vector.VecDiv"
        )
        return IsVec3(vec) and Vec3() or Vec2()
    end

    return VecScale(vec, 1 / scalar)
end

--- Get vector length
---@param vec table Vector
---@return number length 3D length/magnitude
---@usage local len = VecLength(v)
function VecLength(vec)
    if IsVec3(vec) then
        return math.sqrt(vec.x * vec.x + vec.y * vec.y + vec.z * vec.z)
    elseif IsVec2(vec) then
        local z = vec.z or vec.y
        return math.sqrt(vec.x * vec.x + z * z)
    else
        _HarnessInternal.log.error("VecLength requires valid vector", "Vector.VecLength")
        return 0
    end
end

--- Get 2D vector length (ignoring Y)
---@param vec table Vector
---@return number length 2D length in XZ plane
---@usage local len2d = VecLength2D(v)
function VecLength2D(vec)
    if not vec or type(vec) ~= "table" then
        _HarnessInternal.log.error("VecLength2D requires valid vector", "Vector.VecLength2D")
        return 0
    end

    local z = vec.z or vec.y or 0
    return math.sqrt(vec.x * vec.x + z * z)
end

--- Normalize vector
---@param vec table Vector to normalize
---@return table normalized Unit vector (length 1) or zero vector
---@usage local unit = VecNormalize(v)
function VecNormalize(vec)
    local length = VecLength(vec)
    if length == 0 then
        return IsVec3(vec) and Vec3() or Vec2()
    end

    return VecScale(vec, 1 / length)
end

--- Normalize 2D vector (preserving Y)
---@param vec table Vec3 to normalize in XZ plane
---@return table normalized Vec3 with unit XZ, preserved Y
---@usage local unit2d = VecNormalize2D(v)
function VecNormalize2D(vec)
    if not IsVec3(vec) then
        _HarnessInternal.log.error("VecNormalize2D requires valid Vec3", "Vector.VecNormalize2D")
        return Vec3()
    end

    local length = VecLength2D(vec)
    if length == 0 then
        return Vec3(0, vec.y, 0)
    end

    return Vec3(vec.x / length, vec.y, vec.z / length)
end

--- Dot product
---@param a table First vector
---@param b table Second vector
---@return number dot Dot product a·b
---@usage local dot = VecDot(v1, v2)
function VecDot(a, b)
    if IsVec3(a) and IsVec3(b) then
        return a.x * b.x + a.y * b.y + a.z * b.z
    elseif IsVec2(a) and IsVec2(b) then
        return a.x * b.x + (a.z or a.y) * (b.z or b.y)
    else
        _HarnessInternal.log.error(
            "VecDot requires two valid vectors of same type",
            "Vector.VecDot"
        )
        return 0
    end
end

--- Cross product (3D only)
---@param a table First Vec3
---@param b table Second Vec3
---@return table cross Vec3 cross product a×b
---@usage local cross = VecCross(v1, v2)
function VecCross(a, b)
    if not IsVec3(a) or not IsVec3(b) then
        _HarnessInternal.log.error("VecCross requires two valid Vec3", "Vector.VecCross")
        return Vec3()
    end

    return Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
end

--- Get distance between two points
---@param a table First position
---@param b table Second position
---@return number distance 3D distance
---@usage local dist = Distance(pos1, pos2)
function Distance(a, b)
    if IsVec3(a) and IsVec3(b) then
        local dx = b.x - a.x
        local dy = b.y - a.y
        local dz = b.z - a.z
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    else
        return Distance2D(a, b)
    end
end

--- Get 2D distance between two points
---@param a table First position
---@param b table Second position
---@return number distance 2D distance in XZ plane
---@usage local dist2d = Distance2D(pos1, pos2)
function Distance2D(a, b)
    if not a or not b or type(a) ~= "table" or type(b) ~= "table" then
        _HarnessInternal.log.error("Distance2D requires two valid positions", "Vector.Distance2D")
        return 0
    end

    local dx = b.x - a.x
    local az = a.z or a.y or 0
    local bz = b.z or b.y or 0
    local dz = bz - az
    return math.sqrt(dx * dx + dz * dz)
end

--- Get squared distance (avoids sqrt)
---@param a table First position
---@param b table Second position
---@return number distanceSquared 3D distance squared
---@usage local distSq = DistanceSquared(pos1, pos2)
function DistanceSquared(a, b)
    if not IsVec3(a) or not IsVec3(b) then
        _HarnessInternal.log.error(
            "DistanceSquared requires two valid Vec3",
            "Vector.DistanceSquared"
        )
        return 0
    end

    local dx = b.x - a.x
    local dy = b.y - a.y
    local dz = b.z - a.z
    return dx * dx + dy * dy + dz * dz
end

--- Get squared 2D distance
---@param a table First position
---@param b table Second position
---@return number distanceSquared 2D distance squared in XZ plane
---@usage local dist2dSq = Distance2DSquared(pos1, pos2)
function Distance2DSquared(a, b)
    if not a or not b or type(a) ~= "table" or type(b) ~= "table" then
        _HarnessInternal.log.error(
            "Distance2DSquared requires two valid positions",
            "Vector.Distance2DSquared"
        )
        return 0
    end

    local dx = b.x - a.x
    local az = a.z or a.y or 0
    local bz = b.z or b.y or 0
    local dz = bz - az
    return dx * dx + dz * dz
end

--- Get bearing from one point to another (degrees)
---@param from table Source position
---@param to table Target position
---@return number bearing Bearing in degrees (0-360)
---@usage local bearing = Bearing(myPos, targetPos)
function Bearing(from, to)
    if not from or not to or type(from) ~= "table" or type(to) ~= "table" then
        _HarnessInternal.log.error("Bearing requires two valid positions", "Vector.Bearing")
        return 0
    end

    local dx = to.x - from.x
    local fz = from.z or from.y or 0
    local tz = to.z or to.y or 0
    local dz = tz - fz
    local bearing = math.atan2(dx, dz) * 180 / math.pi

    if bearing < 0 then
        bearing = bearing + 360
    end

    return bearing
end

--- Get position from bearing and distance
---@param origin table Origin position
---@param bearing number Bearing in degrees
---@param distance number Distance in meters
---@return table position New position
---@usage local newPos = FromBearingDistance(pos, 45, 1000)
function FromBearingDistance(origin, bearing, distance)
    if
        not origin
        or type(origin) ~= "table"
        or type(bearing) ~= "number"
        or type(distance) ~= "number"
    then
        _HarnessInternal.log.error(
            "FromBearingDistance requires origin, bearing, and distance",
            "Vector.FromBearingDistance"
        )
        return Vec3()
    end

    local angle = bearing * math.pi / 180
    local dx = distance * math.sin(angle)
    local dz = distance * math.cos(angle)

    if IsVec3(origin) then
        return Vec3(origin.x + dx, origin.y, origin.z + dz)
    else
        local oz = origin.z or origin.y or 0
        return Vec2(origin.x + dx, oz + dz)
    end
end

--- Get angle between vectors (degrees)
---@param a table First vector
---@param b table Second vector
---@return number angle Angle in degrees (0-180)
---@usage local angle = AngleBetween(v1, v2)
function AngleBetween(a, b)
    local normA = VecNormalize(a)
    local normB = VecNormalize(b)
    local dot = VecDot(normA, normB)

    -- Clamp to avoid floating point errors with acos
    dot = math.max(-1, math.min(1, dot))

    return math.acos(dot) * 180 / math.pi
end

--- Get midpoint between two points
---@param a table First position
---@param b table Second position
---@return table midpoint Position at center between a and b
---@usage local mid = Midpoint(pos1, pos2)
function Midpoint(a, b)
    if IsVec3(a) and IsVec3(b) then
        return Vec3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
    elseif IsVec2(a) and IsVec2(b) then
        return Vec2((a.x + b.x) / 2, ((a.z or a.y) + (b.z or b.y)) / 2)
    else
        _HarnessInternal.log.error(
            "Midpoint requires two valid vectors of same type",
            "Vector.Midpoint"
        )
        return Vec3()
    end
end

--- Linear interpolation between vectors
---@param a table Start vector
---@param b table End vector
---@param t number Interpolation factor (0 to 1)
---@return table interpolated Vector between a and b
---@usage local interp = VecLerp(v1, v2, 0.5)
function VecLerp(a, b, t)
    if type(t) ~= "number" then
        _HarnessInternal.log.error("VecLerp requires number for t", "Vector.VecLerp")
        return a
    end

    if IsVec3(a) and IsVec3(b) then
        return Vec3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t)
    elseif IsVec2(a) and IsVec2(b) then
        return Vec2(a.x + (b.x - a.x) * t, (a.z or a.y) + ((b.z or b.y) - (a.z or a.y)) * t)
    else
        _HarnessInternal.log.error(
            "VecLerp requires two valid vectors of same type",
            "Vector.VecLerp"
        )
        return Vec3()
    end
end

--- Convert Vec3 to string for debugging
---@param vec table Vec3 to convert
---@param precision number? Decimal places (default 2)
---@return string formatted String representation "(x, y, z)"
---@usage print(Vec3ToString(pos, 1))
function Vec3ToString(vec, precision)
    if not IsVec3(vec) then
        return "(invalid)"
    end

    precision = precision or 2
    local format = "%." .. precision .. "f"

    return string.format(
        "(" .. format .. ", " .. format .. ", " .. format .. ")",
        vec.x,
        vec.y,
        vec.z
    )
end

--- Convert Vec2 to string for debugging
---@param vec table Vec2 to convert
---@param precision number? Decimal places (default 2)
---@return string formatted String representation "(x, z)"
---@usage print(Vec2ToString(pos, 1))
function Vec2ToString(vec, precision)
    if not IsVec2(vec) then
        return "(invalid)"
    end

    precision = precision or 2
    local format = "%." .. precision .. "f"
    local z = vec.z or vec.y

    return string.format("(" .. format .. ", " .. format .. ")", vec.x, z)
end

-- Vec2 Methods (for metatabled instances)
--- Convert Vec2 to Vec3 with specified altitude
---@param y number? Y coordinate/altitude (default: 0)
---@return table vec3 New Vec3 instance
function Vec2_mt:toVec3(y)
    return Vec3(self.x, y or 0, self.z)
end

--- Get the length/magnitude of this Vec2
---@return number length 2D length
function Vec2_mt:length()
    return VecLength(self)
end

--- Get a normalized (unit) version of this Vec2
---@return table vec2 Normalized Vec2 with length 1
function Vec2_mt:normalized()
    return VecNormalize(self)
end

--- Calculate dot product with another Vec2
---@param other table Another Vec2
---@return number dot Dot product result
function Vec2_mt:dot(other)
    return VecDot(self, other)
end

--- Calculate distance to another Vec2
---@param other table Another Vec2 position
---@return number distance 2D distance in meters
function Vec2_mt:distanceTo(other)
    return Distance2D(self, other)
end

--- Calculate bearing to another Vec2
---@param other table Another Vec2 position
---@return number bearing Bearing in degrees (0-360)
function Vec2_mt:bearingTo(other)
    return Bearing(self, other)
end

--- Get position displaced by bearing and distance
---@param bearingDeg number Bearing in degrees
---@param distance number Distance in meters
---@return table vec2 New displaced position
function Vec2_mt:displace(bearingDeg, distance)
    return FromBearingDistance(self, bearingDeg, distance)
end

--- Get midpoint between this and another Vec2
---@param other table Another Vec2 position
---@return table vec2 Midpoint position
function Vec2_mt:midpointTo(other)
    return Midpoint(self, other)
end

--- Calculate angle between this and another Vec2
---@param other table Another Vec2
---@return number angle Angle in degrees (0-180)
function Vec2_mt:angleTo(other)
    return AngleBetween(self, other)
end

--- Rotate this Vec2 around origin by angle
---@param angleDeg number Rotation angle in degrees (positive = clockwise)
---@return table vec2 New rotated Vec2
function Vec2_mt:rotate(angleDeg)
    local angleRad = angleDeg * math.pi / 180
    local cos_a = math.cos(angleRad)
    local sin_a = math.sin(angleRad)
    return Vec2(self.x * cos_a - self.z * sin_a, self.x * sin_a + self.z * cos_a)
end

-- Vec2 Operators
function Vec2_mt.__add(a, b)
    return Vec2(a.x + b.x, a.z + b.z)
end

function Vec2_mt.__sub(a, b)
    return Vec2(a.x - b.x, a.z - b.z)
end

function Vec2_mt.__mul(a, b)
    if type(a) == "number" then
        return Vec2(a * b.x, a * b.z)
    elseif type(b) == "number" then
        return Vec2(a.x * b, a.z * b)
    else
        return Vec2(a.x * b.x, a.z * b.z)
    end
end

function Vec2_mt.__div(a, b)
    if type(b) == "number" then
        return Vec2(a.x / b, a.z / b)
    else
        return Vec2(a.x / b.x, a.z / b.z)
    end
end

function Vec2_mt.__unm(a)
    return Vec2(-a.x, -a.z)
end

function Vec2_mt.__eq(a, b)
    return math.abs(a.x - b.x) < 1e-6 and math.abs(a.z - b.z) < 1e-6
end

function Vec2_mt.__tostring(a)
    return string.format("Vec2(%.3f, %.3f)", a.x, a.z)
end

-- Vec3 Methods (for metatabled instances)
--- Convert Vec3 to Vec2 (drops Y coordinate)
---@return table vec2 New Vec2 with x and z from this Vec3
function Vec3_mt:toVec2()
    return Vec2(self.x, self.z)
end

--- Get the 3D length/magnitude of this Vec3
---@return number length 3D length
function Vec3_mt:length()
    return VecLength(self)
end

--- Get the 2D length/magnitude (ignoring Y)
---@return number length 2D length in XZ plane
function Vec3_mt:length2D()
    return VecLength2D(self)
end

--- Get a normalized (unit) version of this Vec3
---@return table vec3 Normalized Vec3 with length 1
function Vec3_mt:normalized()
    return VecNormalize(self)
end

--- Get a 2D normalized version (normalized in XZ plane, preserving Y)
---@return table vec3 Vec3 with unit XZ and preserved Y
function Vec3_mt:normalized2D()
    return VecNormalize2D(self)
end

--- Calculate dot product with another Vec3
---@param other table Another Vec3
---@return number dot Dot product result
function Vec3_mt:dot(other)
    return VecDot(self, other)
end

--- Calculate cross product with another Vec3
---@param other table Another Vec3
---@return table vec3 Cross product result
function Vec3_mt:cross(other)
    return VecCross(self, other)
end

--- Calculate 3D distance to another Vec3
---@param other table Another Vec3 position
---@return number distance 3D distance in meters
function Vec3_mt:distanceTo(other)
    return Distance(self, other)
end

--- Calculate 2D distance to another position (ignoring Y)
---@param other table Another position
---@return number distance 2D distance in XZ plane
function Vec3_mt:distance2DTo(other)
    return Distance2D(self, other)
end

--- Calculate bearing to another position
---@param other table Another position
---@return number bearing Bearing in degrees (0-360)
function Vec3_mt:bearingTo(other)
    return Bearing(self, other)
end

--- Get position displaced by bearing and distance (preserving Y)
---@param bearingDeg number Bearing in degrees
---@param distance number Distance in meters
---@return table vec3 New displaced position
function Vec3_mt:displace2D(bearingDeg, distance)
    return FromBearingDistance(self, bearingDeg, distance)
end

--- Get midpoint between this and another Vec3
---@param other table Another Vec3 position
---@return table vec3 Midpoint position
function Vec3_mt:midpointTo(other)
    return Midpoint(self, other)
end

--- Calculate angle between this and another Vec3
---@param other table Another Vec3
---@return number angle Angle in degrees (0-180)
function Vec3_mt:angleTo(other)
    return AngleBetween(self, other)
end

-- Vec3 Operators
function Vec3_mt.__add(a, b)
    return Vec3(a.x + b.x, a.y + b.y, a.z + b.z)
end

function Vec3_mt.__sub(a, b)
    return Vec3(a.x - b.x, a.y - b.y, a.z - b.z)
end

function Vec3_mt.__mul(a, b)
    if type(a) == "number" then
        return Vec3(a * b.x, a * b.y, a * b.z)
    elseif type(b) == "number" then
        return Vec3(a.x * b, a.y * b, a.z * b)
    else
        return Vec3(a.x * b.x, a.y * b.y, a.z * b.z)
    end
end

function Vec3_mt.__div(a, b)
    if type(b) == "number" then
        return Vec3(a.x / b, a.y / b, a.z / b)
    else
        return Vec3(a.x / b.x, a.y / b.y, a.z / b.z)
    end
end

function Vec3_mt.__unm(a)
    return Vec3(-a.x, -a.y, -a.z)
end

function Vec3_mt.__eq(a, b)
    return math.abs(a.x - b.x) < 1e-6 and math.abs(a.y - b.y) < 1e-6 and math.abs(a.z - b.z) < 1e-6
end

function Vec3_mt.__tostring(a)
    return string.format("Vec3(%.3f, %.3f, %.3f)", a.x, a.y, a.z)
end
-- ==== END: src/vector.lua ====

-- ==== BEGIN: src/atmosphere.lua ====
--[[
    Atmosphere Module - DCS World Atmosphere API Wrappers
    
    This module provides validated wrapper functions for DCS atmosphere operations,
    including wind, temperature, and pressure queries.
]]

--- Get wind at a specific point
---@param point table? Vec3 position {x, y, z}
---@return table? wind Wind vector if successful, nil otherwise
---@usage local wind = GetWind(position)
function GetWind(point)
    if not point or type(point) ~= "table" or not point.x or not point.y or not point.z then
        _HarnessInternal.log.error(
            "GetWind requires valid point with x, y, z",
            "Atmosphere.GetWind"
        )
        return nil
    end

    local success, result = pcall(atmosphere.getWind, point)
    if not success then
        _HarnessInternal.log.error("Failed to get wind: " .. tostring(result), "Atmosphere.GetWind")
        return nil
    end

    return result
end

--- Get wind with turbulence at a specific point
---@param point table? Vec3 position {x, y, z}
---@return table? wind Wind vector with turbulence if successful, nil otherwise
---@usage local wind = GetWindWithTurbulence(position)
function GetWindWithTurbulence(point)
    if not point or type(point) ~= "table" or not point.x or not point.y or not point.z then
        _HarnessInternal.log.error(
            "GetWindWithTurbulence requires valid point with x, y, z",
            "Atmosphere.GetWindWithTurbulence"
        )
        return nil
    end

    local success, result = pcall(atmosphere.getWindWithTurbulence, point)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get wind with turbulence: " .. tostring(result),
            "Atmosphere.GetWindWithTurbulence"
        )
        return nil
    end

    return result
end

--- Get temperature and pressure at a specific point
---@param point table? Vec3 position {x, y, z}
---@return table? data Table with standardized fields if successful, nil otherwise
---        data.temperatureK number   -- Temperature in Kelvin (raw from DCS)
---        data.temperatureC number   -- Temperature in Celsius
---        data.pressurePa number     -- Pressure in Pascals (raw from DCS)
---        data.pressurehPa number    -- Pressure in hPa (millibars)
---        data.pressureInHg number   -- Pressure in inches of mercury
---@usage local data = GetTemperatureAndPressure(position)
function GetTemperatureAndPressure(point)
    if not point or type(point) ~= "table" or not point.x or not point.y or not point.z then
        _HarnessInternal.log.error(
            "GetTemperatureAndPressure requires valid point with x, y, z",
            "Atmosphere.GetTemperatureAndPressure"
        )
        return nil
    end

    -- DCS returns two numbers (temperature in Kelvin, pressure in Pascals)
    local success, temperatureK, pressurePa = pcall(atmosphere.getTemperatureAndPressure, point)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get temperature and pressure: " .. tostring(temperatureK),
            "Atmosphere.GetTemperatureAndPressure"
        )
        return nil
    end

    -- Some environments may return a single number or a table; normalize
    local tK = nil
    local pPa = nil
    if type(temperatureK) == "number" and type(pressurePa) == "number" then
        tK = temperatureK
        pPa = pressurePa
    elseif type(temperatureK) == "table" then
        tK = tonumber(temperatureK.temperature or temperatureK.temp or temperatureK.t)
        pPa = tonumber(temperatureK.pressure or temperatureK.p or temperatureK.qnh)
    elseif type(temperatureK) == "number" then
        tK = temperatureK
    end

    if not tK and not pPa then
        _HarnessInternal.log.error(
            "Temperature/pressure response could not be interpreted",
            "Atmosphere.GetTemperatureAndPressure"
        )
        return nil
    end

    local data = {}
    if tK then
        data.temperatureK = tK
        data.temperatureC = tK - 273.15
    end
    if pPa then
        data.pressurePa = pPa
        data.pressurehPa = pPa / 100.0
        -- 1 inHg = 3386.389 Pa
        data.pressureInHg = pPa / 3386.389
    end

    return data
end

-- ================================================================================================
-- Convenience getters with built-in unit conversions for UI use
-- ================================================================================================

--- Compute heading (direction to) in degrees from a wind vector
---@param wind table Wind vector {x,y,z}
---@return number headingDeg Heading in degrees (0..360), where 0=N, 90=E
local function _ComputeHeadingDeg(wind)
    if not wind or type(wind.x) ~= "number" or type(wind.z) ~= "number" then
        return 0
    end
    local deg = math.deg(math.atan2(wind.x, wind.z))
    return (deg + 360) % 360
end

--- Compute horizontal wind speed in meters per second from a vector
---@param wind table Wind vector {x,y,z}
---@return number mps Horizontal speed in m/s
local function _HorizontalSpeedMps(wind)
    if not wind or type(wind.x) ~= "number" or type(wind.z) ~= "number" then
        return 0
    end
    return math.sqrt((wind.x * wind.x) + (wind.z * wind.z))
end

--- Get wind (no turbulence) with heading and speed in knots
---@param point table Vec3 position {x, y, z}
---@return table? data { headingDeg, speedKts, vector }
---@usage local w = GetWindKnots(p) -- w.headingDeg, w.speedKts
function GetWindKnots(point)
    local wind = GetWind(point)
    if not wind then
        return nil
    end
    local kts = MpsToKnots(_HorizontalSpeedMps(wind))
    return {
        headingDeg = _ComputeHeadingDeg(wind),
        speedKts = kts,
        vector = wind,
    }
end

--- Get wind with turbulence, returning heading and speed in knots
---@param point table Vec3 position {x, y, z}
---@return table? data { headingDeg, speedKts, vector }
---@usage local w = GetWindWithTurbulenceKnots(p)
function GetWindWithTurbulenceKnots(point)
    local wind = GetWindWithTurbulence(point)
    if not wind then
        return nil
    end
    local kts = MpsToKnots(_HorizontalSpeedMps(wind))
    return {
        headingDeg = _ComputeHeadingDeg(wind),
        speedKts = kts,
        vector = wind,
    }
end

--- Get temperature in Celsius at a point
---@param point table Vec3 position {x, y, z}
---@return number? celsius Temperature in °C or nil on error
function GetTemperatureC(point)
    local tp = GetTemperatureAndPressure(point)
    if not tp or type(tp.temperatureK) ~= "number" then
        return nil
    end
    return KtoC(tp.temperatureK)
end

--- Get temperature in Fahrenheit at a point
---@param point table Vec3 position {x, y, z}
---@return number? fahrenheit Temperature in °F or nil on error
function GetTemperatureF(point)
    local c = GetTemperatureC(point)
    return c and CtoF(c) or nil
end

--- Get pressure in inches of mercury at a point
---@param point table Vec3 position {x, y, z}
---@return number? inHg Pressure in inHg or nil on error
function GetPressureInHg(point)
    local tp = GetTemperatureAndPressure(point)
    if not tp or type(tp.pressurePa) ~= "number" then
        return nil
    end
    return PaToInHg(tp.pressurePa)
end

--- Get pressure in hectoPascals at a point
---@param point table Vec3 position {x, y, z}
---@return number? hPa Pressure in hPa or nil on error
function GetPressurehPa(point)
    local tp = GetTemperatureAndPressure(point)
    if not tp or type(tp.pressurePa) ~= "number" then
        return nil
    end
    return PaTohPa(tp.pressurePa)
end
-- ==== END: src/atmosphere.lua ====

-- ==== BEGIN: src/coord.lua ====
--[[
    Coord Module - DCS World Coordinate API Wrappers
    
    This module provides validated wrapper functions for DCS coordinate conversions,
    including Lat/Long, MGRS, and XYZ coordinate transformations.
]]

--- Convert local coordinates to latitude/longitude
---@param vec3 table Vec3 position in local coordinates {x, y, z}
---@return table? latlon Table with latitude and longitude fields, nil on error
---@usage local ll = LOtoLL(position)
function LOtoLL(vec3)
    if not vec3 or type(vec3) ~= "table" or not vec3.x or not vec3.y or not vec3.z then
        _HarnessInternal.log.error("LOtoLL requires valid vec3 with x, y, z", "Coord.LOtoLL")
        return nil
    end

    local success, result = pcall(coord.LOtoLL, vec3)
    if not success then
        _HarnessInternal.log.error(
            "Failed to convert LO to LL: " .. tostring(result),
            "Coord.LOtoLL"
        )
        return nil
    end

    return result
end

--- Convert latitude/longitude to local coordinates
---@param latitude number Latitude in degrees
---@param longitude number Longitude in degrees
---@param altitude number? Altitude in meters (default 0)
---@return table? vec3 Vec3 position in local coordinates, nil on error
---@usage local pos = LLtoLO(43.5, 41.2, 1000)
function LLtoLO(latitude, longitude, altitude)
    if not latitude or type(latitude) ~= "number" then
        _HarnessInternal.log.error("LLtoLO requires valid latitude", "Coord.LLtoLO")
        return nil
    end

    if not longitude or type(longitude) ~= "number" then
        _HarnessInternal.log.error("LLtoLO requires valid longitude", "Coord.LLtoLO")
        return nil
    end

    altitude = altitude or 0

    local success, result = pcall(coord.LLtoLO, latitude, longitude, altitude)
    if not success then
        _HarnessInternal.log.error(
            "Failed to convert LL to LO: " .. tostring(result),
            "Coord.LLtoLO"
        )
        return nil
    end

    return result
end

--- Convert local coordinates to MGRS string
---@param vec3 table Vec3 position in local coordinates {x, y, z}
---@return table? mgrs MGRS coordinate table, nil on error
---@usage local mgrs = LOtoMGRS(position)
function LOtoMGRS(vec3)
    if not vec3 or type(vec3) ~= "table" or not vec3.x or not vec3.y or not vec3.z then
        _HarnessInternal.log.error("LOtoMGRS requires valid vec3 with x, y, z", "Coord.LOtoMGRS")
        return nil
    end

    -- DCS does not expose coord.LOtoMGRS; compose LO->LL->MGRS
    local okLL, ll = pcall(coord.LOtoLL, vec3)
    if not okLL or not ll or type(ll.latitude) ~= "number" or type(ll.longitude) ~= "number" then
        _HarnessInternal.log.error("Failed to convert LO to LL: " .. tostring(ll), "Coord.LOtoMGRS")
        return nil
    end

    local okMGRS, mgrs = pcall(coord.LLtoMGRS, ll.latitude, ll.longitude)
    if not okMGRS then
        _HarnessInternal.log.error(
            "Failed to convert LL to MGRS: " .. tostring(mgrs),
            "Coord.LOtoMGRS"
        )
        return nil
    end

    return mgrs
end

--- Convert MGRS string to local coordinates
---@param mgrsString string MGRS coordinate string
---@return table? vec3 Vec3 position in local coordinates, nil on error
---@usage local pos = MGRStoLO("37T CK 12345 67890")
function MGRStoLO(mgrsString)
    if not mgrsString or type(mgrsString) ~= "string" or mgrsString == "" then
        _HarnessInternal.log.error("MGRStoLO requires valid MGRS string", "Coord.MGRStoLO")
        return nil
    end

    -- DCS does not expose coord.MGRStoLO; compose MGRS->LL->LO
    local okLL, ll = pcall(coord.MGRStoLL, mgrsString)
    if not okLL or not ll or type(ll.lat) ~= "number" or type(ll.lon) ~= "number" then
        _HarnessInternal.log.error(
            "Failed to convert MGRS to LL: " .. tostring(ll),
            "Coord.MGRStoLO"
        )
        return nil
    end

    local okLO, lo = pcall(coord.LLtoLO, ll.lat, ll.lon)
    if not okLO then
        _HarnessInternal.log.error("Failed to convert LL to LO: " .. tostring(lo), "Coord.MGRStoLO")
        return nil
    end

    return lo
end
-- ==== END: src/coord.lua ====

-- ==== BEGIN: src/geomath.lua ====
--[[
    GeoMath Module - Geospatial Mathematics and Calculations
    
    This module provides comprehensive geospatial calculations and utilities
    for DCS World scripting, including distance calculations, bearing computations,
    coordinate transformations, and geometric operations.
]]

-- Constants
local NM_TO_METERS = 1852
local METERS_TO_NM = 1 / 1852
local FEET_TO_METERS = 0.3048
local METERS_TO_FEET = 1 / 0.3048
local KM_TO_METERS = 1000
local METERS_TO_KM = 0.001
local EARTH_RADIUS_M = 6371000
local DEG_TO_RAD = math.pi / 180
local RAD_TO_DEG = 180 / math.pi

---Converts degrees to radians
---@param degrees number The angle in degrees
---@return number? radians The angle in radians, or nil if input is invalid
---@usage
--- local rad = DegToRad(90) -- Returns 1.5708 (π/2)
--- local rad2 = DegToRad(180) -- Returns 3.14159 (π)
function DegToRad(degrees)
    if not degrees or type(degrees) ~= "number" then
        _HarnessInternal.log.error("DegToRad requires valid degrees", "GeoMath.DegToRad")
        return nil
    end
    return degrees * DEG_TO_RAD
end

---Converts radians to degrees
---@param radians number The angle in radians
---@return number? degrees The angle in degrees, or nil if input is invalid
---@usage
--- local deg = RadToDeg(math.pi) -- Returns 180
--- local deg2 = RadToDeg(math.pi / 2) -- Returns 90
function RadToDeg(radians)
    if not radians or type(radians) ~= "number" then
        _HarnessInternal.log.error("RadToDeg requires valid radians", "GeoMath.RadToDeg")
        return nil
    end
    return radians * RAD_TO_DEG
end

---Converts nautical miles to meters
---@param nm number Distance in nautical miles
---@return number? meters Distance in meters, or nil if input is invalid
---@usage
--- local meters = NauticalMilesToMeters(10) -- Returns 18520 (10 nautical miles)
--- local range = NauticalMilesToMeters(50) -- Returns 92600 (50 nautical miles)
function NauticalMilesToMeters(nm)
    if not nm or type(nm) ~= "number" then
        _HarnessInternal.log.error(
            "NauticalMilesToMeters requires valid nautical miles",
            "GeoMath.NauticalMilesToMeters"
        )
        return nil
    end
    return nm * NM_TO_METERS
end

---Converts meters to nautical miles
---@param meters number Distance in meters
---@return number? nm Distance in nautical miles, or nil if input is invalid
---@usage
--- local nm = MetersToNauticalMiles(1852) -- Returns 1 (1 nautical mile)
--- local nm2 = MetersToNauticalMiles(92600) -- Returns 50 (50 nautical miles)
function MetersToNauticalMiles(meters)
    if not meters or type(meters) ~= "number" then
        _HarnessInternal.log.error(
            "MetersToNauticalMiles requires valid meters",
            "GeoMath.MetersToNauticalMiles"
        )
        return nil
    end
    return meters * METERS_TO_NM
end

---Converts feet to meters
---@param feet number Height/distance in feet
---@return number? meters Height/distance in meters, or nil if input is invalid
---@usage
--- local meters = FeetToMeters(1000) -- Returns 304.8 (1000 feet)
--- local altitude = FeetToMeters(35000) -- Returns 10668 (FL350)
function FeetToMeters(feet)
    if not feet or type(feet) ~= "number" then
        _HarnessInternal.log.error("FeetToMeters requires valid feet", "GeoMath.FeetToMeters")
        return nil
    end
    return feet * FEET_TO_METERS
end

---Converts meters to feet
---@param meters number Height/distance in meters
---@return number? feet Height/distance in feet, or nil if input is invalid
---@usage
--- local feet = MetersToFeet(304.8) -- Returns 1000 (1000 feet)
--- local fl = MetersToFeet(10668) -- Returns 35000 (FL350)
function MetersToFeet(meters)
    if not meters or type(meters) ~= "number" then
        _HarnessInternal.log.error("MetersToFeet requires valid meters", "GeoMath.MetersToFeet")
        return nil
    end
    return meters * METERS_TO_FEET
end

---Calculates the 2D distance between two points (ignoring altitude)
---@param point1 table|Vec2|Vec3 First point with x and z coordinates
---@param point2 table|Vec2|Vec3 Second point with x and z coordinates
---@return number? distance Distance in meters, or nil if inputs are invalid
---@usage
--- local dist = Distance2D({x=0, z=0}, {x=100, z=100}) -- Returns 141.42 (diagonal)
--- local range = Distance2D(unit1:getPoint(), unit2:getPoint()) -- Distance between units
function Distance2D(point1, point2)
    if not point1 or not point2 then
        _HarnessInternal.log.error("Distance2D requires two valid points", "GeoMath.Distance2D")
        return nil
    end

    if not point1.x or not point1.z or not point2.x or not point2.z then
        _HarnessInternal.log.error(
            "Distance2D points must have x and z coordinates",
            "GeoMath.Distance2D"
        )
        return nil
    end

    local dx = point2.x - point1.x
    local dz = point2.z - point1.z
    return math.sqrt(dx * dx + dz * dz)
end

---Calculates the 3D distance between two points (including altitude)
---@param point1 table|Vec3 First point with x, y, and z coordinates
---@param point2 table|Vec3 Second point with x, y, and z coordinates
---@return number? distance Distance in meters, or nil if inputs are invalid
---@usage
--- local dist = Distance3D({x=0, y=0, z=0}, {x=100, y=50, z=100}) -- Returns 158.11
--- local slantRange = Distance3D(aircraft:getPoint(), target:getPoint()) -- Slant range
function Distance3D(point1, point2)
    if not point1 or not point2 then
        _HarnessInternal.log.error("Distance3D requires two valid points", "GeoMath.Distance3D")
        return nil
    end

    if
        not point1.x
        or not point1.y
        or not point1.z
        or not point2.x
        or not point2.y
        or not point2.z
    then
        _HarnessInternal.log.error(
            "Distance3D points must have x, y, and z coordinates",
            "GeoMath.Distance3D"
        )
        return nil
    end

    local dx = point2.x - point1.x
    local dy = point2.y - point1.y
    local dz = point2.z - point1.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

---Calculates the bearing from one point to another
---@param from table|Vec2|Vec3 Starting point
---@param to table|Vec2|Vec3 Target point
---@return number? bearing Aviation bearing in degrees (0=North, 90=East), or nil if invalid
---@usage
--- local bearing = BearingBetween({x=0, z=0}, {x=100, z=0}) -- Returns 90 (East)
--- local hdg = BearingBetween(myUnit:getPoint(), target:getPoint()) -- Bearing to target
--- local intercept = BearingBetween(fighter:getPoint(), bandit:getPoint()) -- Intercept heading
function BearingBetween(from, to)
    if not from or not to then
        _HarnessInternal.log.error(
            "BearingBetween requires two valid points",
            "GeoMath.BearingBetween"
        )
        return nil
    end

    if not from.x or not from.z or not to.x or not to.z then
        _HarnessInternal.log.error(
            "BearingBetween points must have x and z coordinates",
            "GeoMath.BearingBetween"
        )
        return nil
    end

    local dx = to.x - from.x
    local dz = to.z - from.z

    -- Calculate mathematical angle (0 = East, counterclockwise)
    local mathAngleRad = math.atan2(dz, dx)

    -- Convert to aviation bearing (0 = North, clockwise)
    local aviationBearingRad = math.pi / 2 - mathAngleRad
    local aviationBearingDeg = RadToDeg(aviationBearingRad)

    -- Normalize to 0-360
    return (aviationBearingDeg + 360) % 360
end

---Displaces a point by a given bearing and distance
---@param point table|Vec2|Vec3 Starting point
---@param bearingDeg number Aviation bearing in degrees (0=North, 90=East)
---@param distance number Distance to displace in meters
---@return table? point New point with x, y, z coordinates, or nil if invalid
---@usage
--- local newPos = DisplacePoint2D({x=0, z=0}, 90, 1000) -- 1km East: {x=1000, y=0, z=0}
--- local ip = DisplacePoint2D(airfield:getPoint(), 270, 10 * 1852) -- 10nm West of field
--- local orbit = DisplacePoint2D(tanker:getPoint(), hdg, 40 * 1852) -- 40nm ahead
function DisplacePoint2D(point, bearingDeg, distance)
    if not point or not bearingDeg or not distance then
        _HarnessInternal.log.error(
            "DisplacePoint2D requires point, bearing, and distance",
            "GeoMath.DisplacePoint2D"
        )
        return nil
    end

    if not point.x or not point.z then
        _HarnessInternal.log.error(
            "DisplacePoint2D point must have x and z coordinates",
            "GeoMath.DisplacePoint2D"
        )
        return nil
    end

    -- Convert aviation bearing to mathematical angle
    local mathAngleDeg = (90 - bearingDeg + 360) % 360
    local angleRad = DegToRad(mathAngleDeg)

    local dx = math.cos(angleRad) * distance
    local dz = math.sin(angleRad) * distance

    -- Mitigate floating point errors
    if math.abs(dx) < 1e-6 then
        dx = 0
    end
    if math.abs(dz) < 1e-6 then
        dz = 0
    end

    return {
        x = point.x + dx,
        y = point.y or 0,
        z = point.z + dz,
    }
end

---Calculates the midpoint between two points
---@param point1 table|Vec2|Vec3 First point
---@param point2 table|Vec2|Vec3 Second point
---@return table? midpoint Point with x, y, z coordinates, or nil if invalid
---@usage
--- local mid = MidPoint({x=0, z=0}, {x=100, z=100}) -- Returns {x=50, y=0, z=50}
--- local center = MidPoint(wp1, wp2) -- Center point between waypoints
function MidPoint(point1, point2)
    if not point1 or not point2 then
        _HarnessInternal.log.error("MidPoint requires two valid points", "GeoMath.MidPoint")
        return nil
    end

    return {
        x = (point1.x + point2.x) / 2,
        y = ((point1.y or 0) + (point2.y or 0)) / 2,
        z = (point1.z + point2.z) / 2,
    }
end

---Rotates a point around a center point by a given angle
---@param point table|Vec2|Vec3 Point to rotate
---@param center table|Vec2|Vec3 Center of rotation
---@param angleDeg number Rotation angle in degrees (positive = clockwise)
---@return table? point Rotated point with x, y, z coordinates, or nil if invalid
---@usage
--- local rotated = RotatePoint2D({x=100, z=0}, {x=0, z=0}, 90) -- Returns {x=0, y=0, z=100}
--- local formation = RotatePoint2D(wingman, lead, 45) -- Rotate wingman 45° around lead
function RotatePoint2D(point, center, angleDeg)
    if not point or not center or not angleDeg then
        _HarnessInternal.log.error(
            "RotatePoint2D requires point, center, and angle",
            "GeoMath.RotatePoint2D"
        )
        return nil
    end

    local angleRad = DegToRad(angleDeg)
    local cos_a = math.cos(angleRad)
    local sin_a = math.sin(angleRad)

    -- Translate to origin
    local dx = point.x - center.x
    local dz = point.z - center.z

    -- Rotate
    local new_dx = dx * cos_a - dz * sin_a
    local new_dz = dx * sin_a + dz * cos_a

    -- Translate back
    return {
        x = center.x + new_dx,
        y = point.y or 0,
        z = center.z + new_dz,
    }
end

---Normalizes a 2D vector to unit length
---@param vector table|Vec2 Vector to normalize (must have x and z)
---@return table? normalized Unit vector with x, y, z coordinates, or nil if invalid
---@usage
--- local unit = NormalizeVector2D({x=3, z=4}) -- Returns {x=0.6, y=0, z=0.8}
--- local dir = NormalizeVector2D(velocity) -- Get direction from velocity
function NormalizeVector2D(vector)
    if not vector or not vector.x or not vector.z then
        _HarnessInternal.log.error(
            "NormalizeVector2D requires valid vector with x and z",
            "GeoMath.NormalizeVector2D"
        )
        return nil
    end

    local magnitude = math.sqrt(vector.x * vector.x + vector.z * vector.z)

    if magnitude < 1e-6 then
        return { x = 0, y = 0, z = 0 }
    end

    return {
        x = vector.x / magnitude,
        y = vector.y or 0,
        z = vector.z / magnitude,
    }
end

---Normalizes a 3D vector to unit length
---@param vector table|Vec3 Vector to normalize (must have x, y, and z)
---@return table? normalized Unit vector with x, y, z coordinates, or nil if invalid
---@usage
--- local unit = NormalizeVector3D({x=2, y=2, z=1}) -- Returns {x=0.667, y=0.667, z=0.333}
--- local dir = NormalizeVector3D(velocity) -- Get 3D direction from velocity
function NormalizeVector3D(vector)
    if not vector or not vector.x or not vector.y or not vector.z then
        _HarnessInternal.log.error(
            "NormalizeVector3D requires valid vector with x, y, and z",
            "GeoMath.NormalizeVector3D"
        )
        return nil
    end

    local magnitude = math.sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)

    if magnitude < 1e-6 then
        return { x = 0, y = 0, z = 0 }
    end

    return {
        x = vector.x / magnitude,
        y = vector.y / magnitude,
        z = vector.z / magnitude,
    }
end

---Calculates the dot product of two 2D vectors
---@param v1 table|Vec2 First vector
---@param v2 table|Vec2 Second vector
---@return number? dot Dot product value, or nil if invalid
---@usage
--- local dot = DotProduct2D({x=1, z=0}, {x=0, z=1}) -- Returns 0 (perpendicular)
--- local dot2 = DotProduct2D({x=1, z=0}, {x=1, z=0}) -- Returns 1 (parallel)
function DotProduct2D(v1, v2)
    if not v1 or not v2 then
        _HarnessInternal.log.error(
            "DotProduct2D requires two valid vectors",
            "GeoMath.DotProduct2D"
        )
        return nil
    end

    return (v1.x or 0) * (v2.x or 0) + (v1.z or 0) * (v2.z or 0)
end

---Calculates the dot product of two 3D vectors
---@param v1 table|Vec3 First vector
---@param v2 table|Vec3 Second vector
---@return number? dot Dot product value, or nil if invalid
---@usage
--- local dot = DotProduct3D({x=1, y=0, z=0}, {x=0, y=1, z=0}) -- Returns 0
--- local align = DotProduct3D(forward, target) -- Check alignment with target
function DotProduct3D(v1, v2)
    if not v1 or not v2 then
        _HarnessInternal.log.error(
            "DotProduct3D requires two valid vectors",
            "GeoMath.DotProduct3D"
        )
        return nil
    end

    return (v1.x or 0) * (v2.x or 0) + (v1.y or 0) * (v2.y or 0) + (v1.z or 0) * (v2.z or 0)
end

---Calculates the cross product of two 3D vectors
---@param v1 table|Vec3 First vector
---@param v2 table|Vec3 Second vector
---@return table? cross Cross product vector with x, y, z, or nil if invalid
---@usage
--- local cross = CrossProduct3D({x=1, y=0, z=0}, {x=0, y=1, z=0}) -- Returns {x=0, y=0, z=1}
--- local normal = CrossProduct3D(edge1, edge2) -- Surface normal from two edges
function CrossProduct3D(v1, v2)
    if not v1 or not v2 then
        _HarnessInternal.log.error(
            "CrossProduct3D requires two valid vectors",
            "GeoMath.CrossProduct3D"
        )
        return nil
    end

    return {
        x = (v1.y or 0) * (v2.z or 0) - (v1.z or 0) * (v2.y or 0),
        y = (v1.z or 0) * (v2.x or 0) - (v1.x or 0) * (v2.z or 0),
        z = (v1.x or 0) * (v2.y or 0) - (v1.y or 0) * (v2.x or 0),
    }
end

---Calculates the angle between two 2D vectors
---@param v1 table|Vec2 First vector
---@param v2 table|Vec2 Second vector
---@return number? angle Angle in degrees (0-180), or nil if invalid
---@usage
--- local angle = AngleBetweenVectors2D({x=1, z=0}, {x=0, z=1}) -- Returns 90
--- local angle2 = AngleBetweenVectors2D({x=1, z=0}, {x=-1, z=0}) -- Returns 180
function AngleBetweenVectors2D(v1, v2)
    if not v1 or not v2 then
        _HarnessInternal.log.error(
            "AngleBetweenVectors2D requires two valid vectors",
            "GeoMath.AngleBetweenVectors2D"
        )
        return nil
    end

    local dot = DotProduct2D(v1, v2)
    local mag1 = math.sqrt((v1.x or 0) ^ 2 + (v1.z or 0) ^ 2)
    local mag2 = math.sqrt((v2.x or 0) ^ 2 + (v2.z or 0) ^ 2)

    if mag1 < 1e-6 or mag2 < 1e-6 then
        return 0
    end

    local cosAngle = dot / (mag1 * mag2)
    cosAngle = math.max(-1, math.min(1, cosAngle)) -- Clamp to [-1, 1]

    return RadToDeg(math.acos(cosAngle))
end

function PointInPolygon2D(point, polygon)
    if not point or not polygon or type(polygon) ~= "table" or #polygon < 3 then
        _HarnessInternal.log.error(
            "PointInPolygon2D requires valid point and polygon with at least 3 vertices",
            "GeoMath.PointInPolygon2D"
        )
        return nil
    end

    local x, z = point.x, point.z
    local inside = false

    local p1x, p1z = polygon[1].x, polygon[1].z

    for i = 1, #polygon do
        local p2x, p2z = polygon[i % #polygon + 1].x, polygon[i % #polygon + 1].z

        if z > math.min(p1z, p2z) and z <= math.max(p1z, p2z) and x <= math.max(p1x, p2x) then
            if p1z ~= p2z then
                local xinters = (z - p1z) * (p2x - p1x) / (p2z - p1z) + p1x
                if p1x == p2x or x <= xinters then
                    inside = not inside
                end
            end
        end

        p1x, p1z = p2x, p2z
    end

    return inside
end

function CircleLineIntersection2D(circleCenter, radius, lineStart, lineEnd)
    if not circleCenter or not radius or not lineStart or not lineEnd then
        _HarnessInternal.log.error(
            "CircleLineIntersection2D requires all parameters",
            "GeoMath.CircleLineIntersection2D"
        )
        return nil
    end

    local dx = lineEnd.x - lineStart.x
    local dz = lineEnd.z - lineStart.z
    local fx = lineStart.x - circleCenter.x
    local fz = lineStart.z - circleCenter.z

    local a = dx * dx + dz * dz
    local b = 2 * (fx * dx + fz * dz)
    local c = (fx * fx + fz * fz) - radius * radius

    local discriminant = b * b - 4 * a * c

    if discriminant < 0 then
        return {} -- No intersection
    end

    local discriminantSqrt = math.sqrt(discriminant)
    local t1 = (-b - discriminantSqrt) / (2 * a)
    local t2 = (-b + discriminantSqrt) / (2 * a)

    local intersections = {}

    if t1 >= 0 and t1 <= 1 then
        table.insert(intersections, {
            x = lineStart.x + t1 * dx,
            y = lineStart.y or 0,
            z = lineStart.z + t1 * dz,
        })
    end

    if t2 >= 0 and t2 <= 1 and math.abs(t2 - t1) > 1e-6 then
        table.insert(intersections, {
            x = lineStart.x + t2 * dx,
            y = lineStart.y or 0,
            z = lineStart.z + t2 * dz,
        })
    end

    return intersections
end

function PolygonArea2D(polygon)
    if not polygon or type(polygon) ~= "table" or #polygon < 3 then
        _HarnessInternal.log.error(
            "PolygonArea2D requires polygon with at least 3 vertices",
            "GeoMath.PolygonArea2D"
        )
        return nil
    end

    local area = 0
    local n = #polygon

    for i = 1, n do
        local j = (i % n) + 1
        area = area + polygon[i].x * polygon[j].z
        area = area - polygon[j].x * polygon[i].z
    end

    return math.abs(area) / 2
end

function PolygonCentroid2D(polygon)
    if not polygon or type(polygon) ~= "table" or #polygon < 3 then
        _HarnessInternal.log.error(
            "PolygonCentroid2D requires polygon with at least 3 vertices",
            "GeoMath.PolygonCentroid2D"
        )
        return nil
    end

    local cx, cz = 0, 0
    local area = 0

    for i = 1, #polygon do
        local j = (i % #polygon) + 1
        local a = polygon[i].x * polygon[j].z - polygon[j].x * polygon[i].z
        area = area + a
        cx = cx + (polygon[i].x + polygon[j].x) * a
        cz = cz + (polygon[i].z + polygon[j].z) * a
    end

    area = area / 2

    if math.abs(area) < 1e-6 then
        -- Degenerate polygon, return average of points
        for _, p in ipairs(polygon) do
            cx = cx + p.x
            cz = cz + p.z
        end
        return { x = cx / #polygon, y = 0, z = cz / #polygon }
    end

    return { x = cx / (6 * area), y = 0, z = cz / (6 * area) }
end

function ConvexHull2D(points)
    if not points or type(points) ~= "table" or #points < 3 then
        _HarnessInternal.log.error(
            "ConvexHull2D requires at least 3 points",
            "GeoMath.ConvexHull2D"
        )
        return points or {}
    end

    -- Find the leftmost point
    local start = 1
    for i = 2, #points do
        if
            points[i].x < points[start].x
            or (points[i].x == points[start].x and points[i].z < points[start].z)
        then
            start = i
        end
    end

    local hull = {}
    local current = start

    repeat
        table.insert(hull, points[current])
        local next = 1

        for i = 1, #points do
            if i ~= current then
                if next == current then
                    next = i
                else
                    local cross = (points[i].x - points[current].x)
                            * (points[next].z - points[current].z)
                        - (points[i].z - points[current].z)
                            * (points[next].x - points[current].x)

                    if
                        cross > 0
                        or (
                            cross == 0
                            and Distance2D(points[current], points[i])
                                > Distance2D(points[current], points[next])
                        )
                    then
                        next = i
                    end
                end
            end
        end

        current = next
    until current == start

    return hull
end

-- ==================== Closest Point of Approach (CPA) Utilities ====================

--- Estimate time of closest approach between a moving point and a fixed point (2D)
---@param pos table Vec2/Vec3 current position {x,z}
---@param vel table Vec2/Vec3 velocity vector {x,z} meters/second
---@param target table Vec2/Vec3 target point {x,z}
---@return number tStar Time in seconds to closest approach (>= 0)
---@return number distanceAtT Minimum distance at tStar (meters)
---@return table pointAtT Pos at tStar
function EstimateCPAToPoint(pos, vel, target)
    if not pos or not vel or not target then
        _HarnessInternal.log.error(
            "EstimateCPAToPoint requires pos, vel, target",
            "GeoMath.CPA.Point"
        )
        return 0, math.huge, pos
    end
    local rx = ((pos and pos.x) or 0) - ((target and target.x) or 0)
    local rz = ((pos and pos.z) or 0) - ((target and target.z) or 0)
    local vx = (vel and vel.x) or 0
    local vz = (vel and vel.z) or 0
    local v2 = vx * vx + vz * vz
    local tStar = 0
    if v2 > 1e-9 then
        tStar = math.max(0, -((rx * vx + rz * vz) / v2))
    end
    local px = ((pos and pos.x) or 0) + vx * tStar
    local pz = ((pos and pos.z) or 0) + vz * tStar
    local dx = px - ((target and target.x) or 0)
    local dz = pz - ((target and target.z) or 0)
    local d = math.sqrt(dx * dx + dz * dz)
    return tStar, d, { x = px, y = pos.y or 0, z = pz }
end

--- Estimate CPA to a circle region
---@param pos table {x,z}
---@param vel table {x,z}
---@param center table {x,z}
---@param radius number radius meters
---@return number tEntry Time when path first reaches minimum distance
---@return number distanceAtT Minimum distance at tEntry
---@return table pointAtT Position at tEntry
function EstimateCPAToCircle(pos, vel, center, radius)
    local r = radius or 0
    local vx = (vel and vel.x) or 0
    local vz = (vel and vel.z) or 0
    local fx = ((pos and pos.x) or 0) - ((center and center.x) or 0)
    local fz = ((pos and pos.z) or 0) - ((center and center.z) or 0)
    local a = vx * vx + vz * vz
    local b = 2 * (fx * vx + fz * vz)
    local c = (fx * fx + fz * fz) - r * r

    if a > 1e-12 then
        local disc = b * b - 4 * a * c
        if disc >= 0 then
            local sqrtDisc = math.sqrt(disc)
            local t1 = (-b - sqrtDisc) / (2 * a)
            local t2 = (-b + sqrtDisc) / (2 * a)
            local tEntry = math.huge
            if t1 >= 0 then
                tEntry = math.min(tEntry, t1)
            end
            if t2 >= 0 then
                tEntry = math.min(tEntry, t2)
            end
            if tEntry < math.huge then
                local px = (((pos and pos.x) or 0) + vx * tEntry)
                local pz = (((pos and pos.z) or 0) + vz * tEntry)
                return tEntry, 0, { x = px, y = (pos and pos.y) or 0, z = pz }
            end
        end
    end

    -- Fallback to CPA to center if no intersection
    local tStar, d, p = EstimateCPAToPoint(pos, vel, center)
    return tStar, math.max(0, d - r), p
end

--- Estimate CPA to a polygon (2D). Approximates by CPA to edges and vertices.
---@param pos table {x,z}
---@param vel table {x,z}
---@param polygon table array of {x,z}
---@return number tStar Time of closest approach
---@return number distanceAtT Minimum distance to polygon boundary
---@return table pointAtT Position at tStar
function EstimateCPAToPolygon(pos, vel, polygon)
    if not polygon or #polygon == 0 then
        return EstimateCPAToPoint(pos, vel, pos)
    end
    local bestT, bestD, bestP = math.huge, math.huge, pos
    -- Check vertices
    for i = 1, #polygon do
        local t, d, p = EstimateCPAToPoint(pos, vel, polygon[i])
        if d < bestD or (math.abs(d - bestD) < 1e-6 and t < bestT) then
            bestD, bestT, bestP = d, t, p
        end
    end
    -- Check edges by projecting CPA point onto segments at time tStar
    -- Sample a few times near bestT to improve robustness
    local samples = { math.max(0, bestT - 5), bestT, bestT + 5 }
    for _, t in ipairs(samples) do
        local px = (((pos and pos.x) or 0) + (((vel and vel.x) or 0) * t))
        local pz = (((pos and pos.z) or 0) + (((vel and vel.z) or 0) * t))
        for i = 1, #polygon do
            local j = (i % #polygon) + 1
            local ax, az = (polygon[i].x or 0), (polygon[i].z or 0)
            local bx, bz = (polygon[j].x or 0), (polygon[j].z or 0)
            local abx, abz = bx - ax, bz - az
            local apx, apz = px - ax, pz - az
            local ab2 = abx * abx + abz * abz
            local u = 0
            if ab2 > 1e-9 then
                u = math.max(0, math.min(1, (apx * abx + apz * abz) / ab2))
            end
            local cx = ax + u * abx
            local cz = az + u * abz
            local dx = px - cx
            local dz = pz - cz
            local d = math.sqrt(dx * dx + dz * dz)
            if d < bestD or (math.abs(d - bestD) < 1e-6 and t < bestT) then
                bestD, bestT, bestP = d, t, { x = px, y = (pos and pos.y) or 0, z = pz }
            end
        end
    end
    return bestT, bestD, bestP
end

--- Two-body closest point of approach (relative motion, 2D)
---@param posA table {x,z}
---@param velA table {x,z}
---@param posB table {x,z}
---@param velB table {x,z}
---@return number tStar Time of closest approach (>=0)
---@return number distanceAtT Distance at tStar
---@return table aAtT Position A at tStar
---@return table bAtT Position B at tStar
function EstimateTwoBodyCPA(posA, velA, posB, velB)
    if not posA or not velA or not posB or not velB then
        _HarnessInternal.log.error(
            "EstimateTwoBodyCPA requires posA, velA, posB, velB",
            "GeoMath.CPA.TwoBody"
        )
        return 0, math.huge, posA, posB
    end
    local rx = (((posA and posA.x) or 0) - ((posB and posB.x) or 0))
    local rz = (((posA and posA.z) or 0) - ((posB and posB.z) or 0))
    local vx = (((velA and velA.x) or 0) - ((velB and velB.x) or 0))
    local vz = (((velA and velA.z) or 0) - ((velB and velB.z) or 0))
    local v2 = vx * vx + vz * vz
    local tStar = 0
    if v2 > 1e-9 then
        tStar = math.max(0, -((rx * vx + rz * vz) / v2))
    end
    local aAtT = {
        x = (((posA and posA.x) or 0) + (((velA and velA.x) or 0) * tStar)),
        y = (posA and posA.y) or 0,
        z = (((posA and posA.z) or 0) + (((velA and velA.z) or 0) * tStar)),
    }
    local bAtT = {
        x = (((posB and posB.x) or 0) + (((velB and velB.x) or 0) * tStar)),
        y = (posB and posB.y) or 0,
        z = (((posB and posB.z) or 0) + (((velB and velB.z) or 0) * tStar)),
    }
    local dx = aAtT.x - bAtT.x
    local dz = aAtT.z - bAtT.z
    local d = math.sqrt(dx * dx + dz * dz)
    return tStar, d, aAtT, bAtT
end

-- ==================== Intercept Solvers ====================

--- Solve intercept for a pursuer with fixed speed (2D x/z)
---@param posA table {x,z} pursuer current position
---@param speedA number pursuer speed (m/s)
---@param posB table {x,z} target current position
---@param velB table {x,z} target velocity (m/s)
---@return number|nil tIntercept Time to intercept (seconds) or nil if no solution
---@return table|nil interceptPoint Intercept point {x,y,z} at time t
---@return table|nil requiredVelocity Required pursuer velocity vector {x,y,z}
function EstimateInterceptForSpeed(posA, speedA, posB, velB)
    if not posA or not posB or type(speedA) ~= "number" or not velB then
        _HarnessInternal.log.error(
            "EstimateInterceptForSpeed requires posA, speedA, posB, velB",
            "GeoMath.Intercept"
        )
        return nil, nil, nil
    end

    local rX = ((posB and posB.x) or 0) - ((posA and posA.x) or 0)
    local rZ = ((posB and posB.z) or 0) - ((posA and posA.z) or 0)
    local vX = (velB and velB.x) or 0
    local vZ = (velB and velB.z) or 0
    local s = speedA or 0

    local a = vX * vX + vZ * vZ - s * s
    local b = 2 * (rX * vX + rZ * vZ)
    local c = rX * rX + rZ * rZ

    local t = nil
    local eps = 1e-9
    if math.abs(a) < eps then
        -- Linear case: speeds nearly equal => 2*(r·v)t + r^2 = 0
        if math.abs(b) < eps then
            -- No relative motion; if already colocated, intercept now
            if c < eps then
                t = 0
            else
                return nil, nil, nil
            end
        else
            t = -c / b
            if t and t < 0 then
                return nil, nil, nil
            end
        end
    else
        local disc = b * b - 4 * a * c
        if disc < 0 then
            return nil, nil, nil
        end
        local sqrtDisc = math.sqrt(disc)
        local t1 = (-b - sqrtDisc) / (2 * a)
        local t2 = (-b + sqrtDisc) / (2 * a)
        -- choose smallest non-negative
        local best = math.huge
        if t1 and t1 >= 0 then
            best = math.min(best, t1)
        end
        if t2 and t2 >= 0 then
            best = math.min(best, t2)
        end
        if best == math.huge then
            return nil, nil, nil
        end
        t = best
    end

    -- Intercept point and required velocity
    local interceptX = (((posB and posB.x) or 0) + vX * (t or 0))
    local interceptZ = (((posB and posB.z) or 0) + vZ * (t or 0))
    local dx = interceptX - ((posA and posA.x) or 0)
    local dz = interceptZ - ((posA and posA.z) or 0)
    local reqVX, reqVZ
    if (t or 0) > eps then
        reqVX = dx / t
        reqVZ = dz / t
    else
        reqVX = 0
        reqVZ = 0
    end
    -- Normalize to exact speed to reduce numerical drift
    local mag = math.sqrt(reqVX * reqVX + reqVZ * reqVZ)
    if mag > eps and s > 0 then
        reqVX = reqVX * (s / mag)
        reqVZ = reqVZ * (s / mag)
    end

    return t,
        { x = interceptX, y = (posA and posA.y) or 0, z = interceptZ },
        { x = reqVX, y = (posA and posA.y) or 0, z = reqVZ }
end

--- Compute delta-velocity required for A to intercept B at given speed
---@param posA table {x,z}
---@param velA table {x,z}
---@param posB table {x,z}
---@param velB table {x,z}
---@param speedA number? If provided, solve using this speed; otherwise use |requiredVelocity|
---@return table|nil deltaV Vector {x,y,z} to add to velA; nil if no solution
---@return number|nil tIntercept Time to intercept
---@return table|nil interceptPoint Intercept position
---@return table|nil requiredVelocity Velocity vector needed
function EstimateInterceptDeltaV(posA, velA, posB, velB, speedA)
    if type(speedA) == "number" then
        local t, p, reqV = EstimateInterceptForSpeed(posA, speedA, posB, velB)
        if not t then
            return nil, nil, nil, nil
        end
        local dV = {
            x = (reqV.x or 0) - ((velA and velA.x) or 0),
            y = (reqV.y or 0) - ((velA and velA.y) or 0),
            z = (reqV.z or 0) - ((velA and velA.z) or 0),
        }
        return dV, t, p, reqV
    else
        -- If speed not provided, derive from solution magnitude
        local vAx = (velA and velA.x) or 0
        local vAz = (velA and velA.z) or 0
        local speedGuess = math.sqrt(vAx * vAx + vAz * vAz)
        -- If stationary, use distance/time heuristic by assuming time from CPA to point
        if speedGuess < 1e-6 then
            speedGuess = 1
        end
        local t, p, reqV = EstimateInterceptForSpeed(posA, speedGuess, posB, velB)
        if not t then
            return nil, nil, nil, nil
        end
        local dV = {
            x = (reqV.x or 0) - vAx,
            y = (reqV.y or 0) - ((velA and velA.y) or 0),
            z = (reqV.z or 0) - vAz,
        }
        return dV, t, p, reqV
    end
end
-- ==== END: src/geomath.lua ====

-- ==== BEGIN: src/group.lua ====
--[[
==================================================================================================
    GROUP MODULE
    Validated wrapper functions for DCS Group API
==================================================================================================
]]

--- Get group by name
---@param groupName string The name of the group to retrieve
---@return table? group The group object if found, nil otherwise
---@usage local group = GetGroup("Aerial-1")
function GetGroup(groupName)
    if not groupName or type(groupName) ~= "string" then
        _HarnessInternal.log.error("GetGroup requires string group name", "GetGroup")
        return nil
    end

    -- Check cache first
    local cached = _HarnessInternal.cache.groups[groupName]
    if cached then
        -- Verify group still exists
        local success, exists = pcall(function()
            return cached:isExist()
        end)
        if success and exists then
            _HarnessInternal.cache.stats.hits = _HarnessInternal.cache.stats.hits + 1
            return cached
        else
            -- Remove from cache if no longer exists
            RemoveGroupFromCache(groupName)
        end
    end

    -- Get from DCS API
    local success, group = pcall(Group.getByName, groupName)
    if not success then
        _HarnessInternal.log.error("Failed to get group: " .. tostring(group), "GetGroup")
        return nil
    end

    -- Add to cache if valid
    if group then
        _HarnessInternal.cache.groups[groupName] = group
        _HarnessInternal.cache.stats.misses = _HarnessInternal.cache.stats.misses + 1
    end

    return group
end

--- Check if group exists
---@param groupName string The name of the group to check
---@return boolean exists True if group exists, false otherwise
---@usage if GroupExists("Aerial-1") then ... end
function GroupExists(groupName)
    local group = GetGroup(groupName)
    if not group then
        return false
    end

    local success, exists = pcall(group.isExist, group)
    if not success then
        _HarnessInternal.log.error(
            "Failed to check group existence: " .. tostring(exists),
            "GroupExists"
        )
        return false
    end

    return exists
end

--- Get group units
---@param groupName string The name of the group
---@return table? units Array of unit objects if found, nil otherwise
---@usage local units = GetGroupUnits("Aerial-1")
function GetGroupUnits(groupName)
    local group = GetGroup(groupName)
    if not group then
        return nil
    end

    local success, units = pcall(group.getUnits, group)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get group units: " .. tostring(units),
            "GetGroupUnits"
        )
        return nil
    end

    return units
end

--- Get group size
---@param groupName string The name of the group
---@return number size Current number of units in the group (0 if not found)
---@usage local size = GetGroupSize("Aerial-1")
function GetGroupSize(groupName)
    local group = GetGroup(groupName)
    if not group then
        return 0
    end

    local success, size = pcall(group.getSize, group)
    if not success then
        _HarnessInternal.log.error("Failed to get group size: " .. tostring(size), "GetGroupSize")
        return 0
    end

    return size
end

--- Get group initial size
---@param groupName string The name of the group
---@return number size Initial number of units in the group (0 if not found)
---@usage local initialSize = GetGroupInitialSize("Aerial-1")
function GetGroupInitialSize(groupName)
    local group = GetGroup(groupName)
    if not group then
        return 0
    end

    local success, size = pcall(group.getInitialSize, group)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get group initial size: " .. tostring(size),
            "GetGroupInitialSize"
        )
        return 0
    end

    return size
end

--- Get group coalition
---@param groupName string The name of the group
---@return number? coalition The coalition ID if found, nil otherwise
---@usage local coalition = GetGroupCoalition("Aerial-1")
function GetGroupCoalition(groupName)
    local group = GetGroup(groupName)
    if not group then
        return nil
    end

    local success, coalition = pcall(group.getCoalition, group)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get group coalition: " .. tostring(coalition),
            "GetGroupCoalition"
        )
        return nil
    end

    return coalition
end

--- Get group category
---@param groupName string The name of the group
---@return number? category The category ID if found, nil otherwise
---@usage local category = GetGroupCategory("Aerial-1")
function GetGroupCategory(groupName)
    local group = GetGroup(groupName)
    if not group then
        return nil
    end

    local success, category = pcall(group.getCategory, group)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get group category: " .. tostring(category),
            "GetGroupCategory"
        )
        return nil
    end

    return category
end

--- Get group ID
---@param groupName string The name of the group
---@return number? id The group ID if found, nil otherwise
---@usage local id = GetGroupID("Aerial-1")
function GetGroupID(groupName)
    local group = GetGroup(groupName)
    if not group then
        return nil
    end

    local success, id = pcall(group.getID, group)
    if not success then
        _HarnessInternal.log.error("Failed to get group ID: " .. tostring(id), "GetGroupID")
        return nil
    end

    return id
end

--- Get group controller
---@param groupName string The name of the group
---@return table? controller The controller object if found, nil otherwise
---@usage local controller = GetGroupController("Aerial-1")
function GetGroupController(groupName)
    -- Check cache first
    local cacheKey = "group:" .. groupName
    local cached = _HarnessInternal.cache.getController(cacheKey)
    if cached then
        return cached
    end

    local group = GetGroup(groupName)
    if not group then
        return nil
    end

    local success, controller = pcall(group.getController, group)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get group controller: " .. tostring(controller),
            "GetGroupController"
        )
        return nil
    end

    -- Add to cache with optional metadata
    if controller then
        local info = { groupName = groupName }

        -- If this is an air group, capture unit names for reference
        local cat = GetGroupCategory(groupName)
        if cat == Group.Category.AIRPLANE or cat == Group.Category.HELICOPTER then
            local units = GetGroupUnits(groupName)
            if units and type(units) == "table" then
                local names = {}
                for i = 1, #units do
                    local u = units[i]
                    local ok, nm = pcall(function()
                        return u:getName()
                    end)
                    if ok and nm then
                        names[#names + 1] = nm
                    end
                end
                if #names > 0 then
                    info.unitNames = names
                end
            end
        end

        -- Determine and store domain
        local domain = nil
        if cat == Group.Category.AIRPLANE or cat == Group.Category.HELICOPTER then
            domain = "Air"
        elseif cat == Group.Category.GROUND then
            domain = "Ground"
        elseif cat == Group.Category.SHIP then
            domain = "Naval"
        end
        info.domain = domain

        _HarnessInternal.cache.addController(cacheKey, controller, info)
        -- Fallback: ensure metadata is stored even if addController ignores info
        local entry = _HarnessInternal.cache.controllers[cacheKey]
        if entry then
            if info.groupName and entry.groupName == nil then
                entry.groupName = info.groupName
            end
            if info.unitNames and entry.unitNames == nil then
                entry.unitNames = info.unitNames
            end
            if info.domain and entry.domain == nil then
                entry.domain = info.domain
            end
        end
    end

    return controller
end

--- Send message to group
---@param groupId number The group ID to send message to
---@param message string The message text
---@param duration number? Duration in seconds (default 20)
---@return boolean success True if message sent successfully
---@usage MessageToGroup(1, "Hello group", 10)
function MessageToGroup(groupId, message, duration)
    if not groupId or type(groupId) ~= "number" then
        _HarnessInternal.log.error("MessageToGroup requires numeric group ID", "MessageToGroup")
        return false
    end

    if not message or type(message) ~= "string" then
        _HarnessInternal.log.error("MessageToGroup requires string message", "MessageToGroup")
        return false
    end

    duration = duration or 20

    local success, result = pcall(trigger.action.outTextForGroup, groupId, message, duration, false)
    if not success then
        _HarnessInternal.log.error(
            string.format("Failed to send message to group %d: %s", groupId, tostring(result)),
            "MessageToGroup"
        )
        return false
    end

    return true
end

--- Send message to coalition
---@param coalitionId number The coalition ID to send message to
---@param message string The message text
---@param duration number? Duration in seconds (default 20)
---@return boolean success True if message sent successfully
---@usage MessageToCoalition(coalition.side.BLUE, "Hello blues", 10)
function MessageToCoalition(coalitionId, message, duration)
    if not coalitionId or type(coalitionId) ~= "number" then
        _HarnessInternal.log.error(
            "MessageToCoalition requires numeric coalition ID",
            "MessageToCoalition"
        )
        return false
    end

    if not message or type(message) ~= "string" then
        _HarnessInternal.log.error(
            "MessageToCoalition requires string message",
            "MessageToCoalition"
        )
        return false
    end

    duration = duration or 20

    local success, result =
        pcall(trigger.action.outTextForCoalition, coalitionId, message, duration)
    if not success then
        _HarnessInternal.log.error(
            string.format(
                "Failed to send message to coalition %d: %s",
                coalitionId,
                tostring(result)
            ),
            "MessageToCoalition"
        )
        return false
    end

    return true
end

--- Send message to all
---@param message string The message text
---@param duration number? Duration in seconds (default 20)
---@return boolean success True if message sent successfully
---@usage MessageToAll("Hello everyone", 10)
function MessageToAll(message, duration)
    if not message or type(message) ~= "string" then
        _HarnessInternal.log.error("MessageToAll requires string message", "MessageToAll")
        return false
    end

    duration = duration or 20

    local success, result = pcall(trigger.action.outText, message, duration)
    if not success then
        _HarnessInternal.log.error(
            "Failed to send message to all: " .. tostring(result),
            "MessageToAll"
        )
        return false
    end

    return true
end

--- Activate group
---@param groupName string The name of the group to activate
---@return boolean success True if group activated successfully
---@usage ActivateGroup("Aerial-1")
function ActivateGroup(groupName)
    local group = GetGroup(groupName)
    if not group then
        return false
    end

    local success, result = pcall(group.activate, group)
    if not success then
        _HarnessInternal.log.error(
            "Failed to activate group: " .. tostring(result),
            "ActivateGroup"
        )
        return false
    end

    return true
end

--- Get all groups of coalition and category
---@param coalitionId number The coalition ID to query
---@param categoryId number? Optional category ID to filter by
---@return table groups Array of group objects (empty if error)
---@usage local blueAirGroups = GetCoalitionGroups(coalition.side.BLUE, Group.Category.AIRPLANE)
function GetCoalitionGroups(coalitionId, categoryId)
    if not coalitionId or type(coalitionId) ~= "number" then
        _HarnessInternal.log.error(
            "GetCoalitionGroups requires numeric coalition ID",
            "GetCoalitionGroups"
        )
        return {}
    end

    local success, groups = pcall(coalition.getGroups, coalitionId, categoryId)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get coalition groups: " .. tostring(groups),
            "GetCoalitionGroups"
        )
        return {}
    end

    return groups or {}
end

-- Advanced Group Functions

--- Get group name
---@param group table Group object
---@return string? name Group name or nil on error
---@usage local name = GetGroupName(group)
function GetGroupName(group)
    if not group then
        _HarnessInternal.log.error("GetGroupName requires group", "GetGroupName")
        return nil
    end

    local success, name = pcall(function()
        return group:getName()
    end)
    if not success then
        _HarnessInternal.log.error("Failed to get group name: " .. tostring(name), "GetGroupName")
        return nil
    end

    return name
end

--- Get unit by index
---@param group table Group object
---@param index number Unit index (1-based)
---@return table? unit Unit object or nil on error
---@usage local unit = GetGroupUnit(group, 1)
function GetGroupUnit(group, index)
    if not group then
        _HarnessInternal.log.error("GetGroupUnit requires group", "GetGroupUnit")
        return nil
    end

    if not index or type(index) ~= "number" then
        _HarnessInternal.log.error("GetGroupUnit requires numeric index", "GetGroupUnit")
        return nil
    end

    local success, unit = pcall(function()
        return group:getUnit(index)
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get unit by index: " .. tostring(unit),
            "GetGroupUnit"
        )
        return nil
    end

    return unit
end

--- Get group category extended
---@param group table Group object
---@return number? category Extended category or nil on error
---@usage local cat = GetGroupCategoryEx(group)
function GetGroupCategoryEx(group)
    if not group then
        _HarnessInternal.log.error("GetGroupCategoryEx requires group", "GetGroupCategoryEx")
        return nil
    end

    local success, category = pcall(function()
        return group:getCategoryEx()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get group category ex: " .. tostring(category),
            "GetGroupCategoryEx"
        )
        return nil
    end

    return category
end

--- Enable/disable group emissions
---@param group table Group object
---@param enabled boolean True to enable emissions
---@return boolean success True if emissions were set
---@usage EnableGroupEmissions(group, false) -- Go dark
function EnableGroupEmissions(group, enabled)
    if not group then
        _HarnessInternal.log.error("EnableGroupEmissions requires group", "EnableGroupEmissions")
        return false
    end

    if type(enabled) ~= "boolean" then
        _HarnessInternal.log.error(
            "EnableGroupEmissions requires boolean enabled",
            "EnableGroupEmissions"
        )
        return false
    end

    local success, result = pcall(function()
        group:enableEmission(enabled)
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to set group emissions: " .. tostring(result),
            "EnableGroupEmissions"
        )
        return false
    end

    _HarnessInternal.log.info("Set group emissions: " .. tostring(enabled), "EnableGroupEmissions")
    return true
end

--- Destroy group without events
---@param group table Group object
---@return boolean success True if destroyed
---@usage DestroyGroup(group)
function DestroyGroup(group)
    if not group then
        _HarnessInternal.log.error("DestroyGroup requires group", "DestroyGroup")
        return false
    end

    local success, result = pcall(function()
        group:destroy()
    end)
    if not success then
        _HarnessInternal.log.error("Failed to destroy group: " .. tostring(result), "DestroyGroup")
        return false
    end

    _HarnessInternal.log.info("Destroyed group", "DestroyGroup")
    return true
end

--- Check if group is embarking
---@param group table Group object
---@return boolean? embarking True if embarking, nil on error
---@usage if IsGroupEmbarking(group) then ... end
function IsGroupEmbarking(group)
    if not group then
        _HarnessInternal.log.error("IsGroupEmbarking requires group", "IsGroupEmbarking")
        return nil
    end

    local success, embarking = pcall(function()
        return group:embarking()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to check group embarking: " .. tostring(embarking),
            "IsGroupEmbarking"
        )
        return nil
    end

    return embarking
end

--- Create map marker for group
---@param group table Group object
---@param point table Position for marker (Vec3)
---@param text string Marker text
---@return boolean success True if marker created
---@usage MarkGroup(group, position, "Enemy armor")
function MarkGroup(group, point, text)
    if not group then
        _HarnessInternal.log.error("MarkGroup requires group", "MarkGroup")
        return false
    end

    if not point or not IsVec3(point) then
        _HarnessInternal.log.error("MarkGroup requires Vec3 position", "MarkGroup")
        return false
    end

    if not text or type(text) ~= "string" then
        _HarnessInternal.log.error("MarkGroup requires string text", "MarkGroup")
        return false
    end

    local success, result = pcall(function()
        group:markGroup(point, text)
    end)
    if not success then
        _HarnessInternal.log.error("Failed to mark group: " .. tostring(result), "MarkGroup")
        return false
    end

    _HarnessInternal.log.info("Marked group with: " .. text, "MarkGroup")
    return true
end
-- ==== END: src/group.lua ====

-- ==== BEGIN: src/shapes.lua ====
--[[
    Shapes Module - Geospatial Shape Generation
    
    This module provides functions to generate various geometric shapes
    as arrays of Vec2/Vec3 points for use in DCS World scripting.
    All shapes are geospatially aware and use real-world measurements.
]]

--- Creates an equilateral triangle shape
--- @param center table|Vec2 Center point of the triangle {x, z} or Vec2
--- @param size number? Length of each side in meters (default: 1000)
--- @param rotation number? Rotation angle in degrees (default: 0)
--- @return table|nil points Array of Vec2 points defining the triangle or nil on error
--- @usage local triangle = CreateTriangle({x=0, z=0}, 5000, 45)
function CreateTriangle(center, size, rotation)
    if not center then
        _HarnessInternal.log.error("CreateTriangle requires center point", "Shapes.CreateTriangle")
        return nil
    end

    center = ToVec2(center)
    size = size or 1000 -- Default 1km sides
    rotation = rotation or 0

    -- Create equilateral triangle
    local height = size * math.sqrt(3) / 2
    local points = {
        Vec2(0, height * 2 / 3), -- Top vertex
        Vec2(-size / 2, -height * 1 / 3), -- Bottom left
        Vec2(size / 2, -height * 1 / 3), -- Bottom right
    }

    -- Rotate and translate
    local result = {}
    for _, p in ipairs(points) do
        local rotated = p:rotate(rotation)
        table.insert(result, center + rotated)
    end

    return result
end

--- Creates a rectangle shape
--- @param center table|Vec2 Center point of the rectangle {x, z} or Vec2
--- @param width number? Width in meters (default: 2000)
--- @param height number? Height in meters (default: 1000)
--- @param rotation number? Rotation angle in degrees (default: 0)
--- @return table|nil points Array of Vec2 points defining the rectangle or nil on error
--- @usage local rect = CreateRectangle({x=0, z=0}, 5000, 3000, 90)
function CreateRectangle(center, width, height, rotation)
    if not center then
        _HarnessInternal.log.error(
            "CreateRectangle requires center point",
            "Shapes.CreateRectangle"
        )
        return nil
    end

    center = ToVec2(center)
    width = width or 2000 -- Default 2km width
    height = height or 1000 -- Default 1km height
    rotation = rotation or 0

    local halfW = width / 2
    local halfH = height / 2

    local points = {
        Vec2(-halfW, -halfH), -- Bottom left
        Vec2(halfW, -halfH), -- Bottom right
        Vec2(halfW, halfH), -- Top right
        Vec2(-halfW, halfH), -- Top left
    }

    -- Rotate and translate
    local result = {}
    for _, p in ipairs(points) do
        local rotated = p:rotate(rotation)
        table.insert(result, center + rotated)
    end

    return result
end

--- Creates a square shape
--- @param center table|Vec2 Center point of the square {x, z} or Vec2
--- @param size number? Length of each side in meters
--- @param rotation number? Rotation angle in degrees (default: 0)
--- @return table|nil points Array of Vec2 points defining the square or nil on error
--- @usage local square = CreateSquare({x=0, z=0}, 2000, 45)
function CreateSquare(center, size, rotation)
    return CreateRectangle(center, size, size, rotation)
end

--- Creates an oval/ellipse shape
--- @param center table|Vec2 Center point of the oval {x, z} or Vec2
--- @param radiusX number? Radius along X axis in meters (default: 1000)
--- @param radiusZ number? Radius along Z axis in meters (default: radiusX)
--- @param numPoints number? Number of points to generate (default: 36)
--- @return table|nil points Array of Vec2 points defining the oval or nil on error
--- @usage local oval = CreateOval({x=0, z=0}, 2000, 1000, 48)
function CreateOval(center, radiusX, radiusZ, numPoints)
    if not center then
        _HarnessInternal.log.error("CreateOval requires center point", "Shapes.CreateOval")
        return nil
    end

    center = ToVec2(center)
    radiusX = radiusX or 1000 -- Default 1km radius X
    radiusZ = radiusZ or radiusX -- Default to circle if not specified
    numPoints = numPoints or 36 -- Default 36 points (10-degree increments)

    local points = {}
    local angleStep = 2 * math.pi / numPoints

    for i = 0, numPoints - 1 do
        local angle = i * angleStep
        local x = radiusX * math.cos(angle)
        local z = radiusZ * math.sin(angle)
        table.insert(points, center + Vec2(x, z))
    end

    return points
end

--- Creates a circle shape
--- @param center table|Vec2 Center point of the circle {x, z} or Vec2
--- @param radius number? Radius in meters
--- @param numPoints number? Number of points to generate (default: 36)
--- @return table|nil points Array of Vec2 points defining the circle or nil on error
--- @usage local circle = CreateCircle({x=0, z=0}, 5000, 72)
function CreateCircle(center, radius, numPoints)
    return CreateOval(center, radius, radius, numPoints)
end

--- Creates a fan/sector shape from an origin point
--- @param origin table|Vec2 Origin point of the fan {x, z} or Vec2
--- @param centerBearing number? Center bearing of the arc in degrees (default: 0)
--- @param arcDegrees number? Total arc width in degrees (default: 90)
--- @param distance number? Distance from origin in meters (default: 50 NM)
--- @param numPoints number? Number of arc points (default: based on arc size)
--- @return table|nil points Array of Vec2 points defining the fan or nil on error
--- @usage local fan = CreateFan({x=0, z=0}, 45, 60, 10000) -- 60° arc centered on bearing 45°
function CreateFan(origin, centerBearing, arcDegrees, distance, numPoints)
    if not origin then
        _HarnessInternal.log.error("CreateFan requires origin point", "Shapes.CreateFan")
        return nil
    end

    origin = ToVec2(origin)
    centerBearing = centerBearing or 0
    arcDegrees = arcDegrees or 90
    distance = distance or 50 * 1852 -- Default 50 nautical miles
    numPoints = numPoints or math.ceil(arcDegrees / 5) + 1 -- Default 5-degree increments

    local points = { origin } -- Start with origin

    -- Calculate start bearing (half arc to the left of center)
    local halfArc = arcDegrees / 2
    local startBearing = centerBearing - halfArc
    local angleStep = arcDegrees / (numPoints - 1)

    for i = 0, numPoints - 1 do
        local bearing = startBearing + i * angleStep
        local point = origin:displace(bearing, distance)
        table.insert(points, point)
    end

    -- Close the fan by returning to origin
    table.insert(points, origin)

    return points
end

--- Creates a trapezoid shape
--- @param center table|Vec2 Center point of the trapezoid {x, z} or Vec2
--- @param topWidth number? Width of top edge in meters (default: 1000)
--- @param bottomWidth number? Width of bottom edge in meters (default: 2000)
--- @param height number? Height in meters (default: 1000)
--- @param rotation number? Rotation angle in degrees (default: 0)
--- @return table|nil points Array of Vec2 points defining the trapezoid or nil on error
--- @usage local trap = CreateTrapezoid({x=0, z=0}, 1000, 3000, 2000)
function CreateTrapezoid(center, topWidth, bottomWidth, height, rotation)
    if not center then
        _HarnessInternal.log.error(
            "CreateTrapezoid requires center point",
            "Shapes.CreateTrapezoid"
        )
        return nil
    end

    center = ToVec2(center)
    topWidth = topWidth or 1000 -- Default 1km top width
    bottomWidth = bottomWidth or 2000 -- Default 2km bottom width
    height = height or 1000 -- Default 1km height
    rotation = rotation or 0

    local halfTop = topWidth / 2
    local halfBottom = bottomWidth / 2
    local halfH = height / 2

    local points = {
        Vec2(-halfBottom, -halfH), -- Bottom left
        Vec2(halfBottom, -halfH), -- Bottom right
        Vec2(halfTop, halfH), -- Top right
        Vec2(-halfTop, halfH), -- Top left
    }

    -- Rotate and translate
    local result = {}
    for _, p in ipairs(points) do
        local rotated = p:rotate(rotation)
        table.insert(result, center + rotated)
    end

    return result
end

--- Creates a pill/capsule shape (rectangle with semicircular ends)
--- @param center table|Vec2 Center point of the pill {x, z} or Vec2
--- @param legBearing number? Direction of the long axis in degrees (default: 0)
--- @param legLength number? Length of the straight section in meters (default: 40 NM)
--- @param radius number? Radius of the semicircular ends in meters (default: 10 NM)
--- @param pointsPerCap number? Points per semicircle end (default: 19)
--- @return table|nil points Array of Vec2 points defining the pill or nil on error
--- @usage local pill = CreatePill({x=0, z=0}, 90, 20000, 5000)
function CreatePill(center, legBearing, legLength, radius, pointsPerCap)
    if not center then
        _HarnessInternal.log.error("CreatePill requires center point", "Shapes.CreatePill")
        return nil
    end

    center = ToVec2(center)
    legBearing = legBearing or 0
    legLength = legLength or 40 * 1852 -- Default 40 nautical miles
    radius = radius or 10 * 1852 -- Default 10 nautical miles
    pointsPerCap = pointsPerCap or 19 -- Points per semicircle

    local halfLegLength = legLength / 2

    -- Calculate the two centers for the semicircular caps
    local cap1Center = center:displace(legBearing, halfLegLength)
    local cap2Center = center:displace((legBearing + 180) % 360, halfLegLength)

    -- Calculate perpendicular bearing for the sides
    local perpBearing = (legBearing + 90) % 360

    local points = {}

    -- Generate first semicircle (right side going clockwise from perpBearing)
    local angleStep = 180 / (pointsPerCap - 1)
    for i = 0, pointsPerCap - 1 do
        local bearing = (perpBearing - i * angleStep + 720) % 360
        table.insert(points, cap1Center:displace(bearing, radius))
    end

    -- Generate second semicircle (left side going clockwise from opposite perpBearing)
    for i = 0, pointsPerCap - 1 do
        local bearing = ((perpBearing + 180) - i * angleStep + 720) % 360
        table.insert(points, cap2Center:displace(bearing, radius))
    end

    return points
end

--- Creates a star shape
--- @param center table|Vec2 Center point of the star {x, z} or Vec2
--- @param outerRadius number? Radius to outer points in meters (default: 1000)
--- @param innerRadius number? Radius to inner points in meters (default: 400)
--- @param numPoints number? Number of star points (default: 5)
--- @param rotation number? Rotation angle in degrees (default: 0)
--- @return table|nil points Array of Vec2 points defining the star or nil on error
--- @usage local star = CreateStar({x=0, z=0}, 5000, 2000, 5, 0)
function CreateStar(center, outerRadius, innerRadius, numPoints, rotation)
    if not center then
        _HarnessInternal.log.error("CreateStar requires center point", "Shapes.CreateStar")
        return nil
    end

    center = ToVec2(center)
    outerRadius = outerRadius or 1000 -- Default 1km outer radius
    innerRadius = innerRadius or 400 -- Default 400m inner radius
    numPoints = numPoints or 5 -- Default 5-pointed star
    rotation = rotation or 0

    local points = {}
    local angleStep = math.pi / numPoints -- Half angle between points

    for i = 0, numPoints * 2 - 1 do
        local angle = i * angleStep - math.pi / 2 + DegToRad(rotation)
        local radius = (i % 2 == 0) and outerRadius or innerRadius
        local x = radius * math.cos(angle)
        local z = radius * math.sin(angle)
        table.insert(points, center + Vec2(x, z))
    end

    return points
end

--- Creates a regular polygon shape
--- @param center table|Vec2 Center point of the polygon {x, z} or Vec2
--- @param radius number Radius to vertices in meters
--- @param numSides number Number of sides (minimum 3)
--- @param rotation number? Rotation angle in degrees (default: 0)
--- @return table|nil points Array of Vec2 points defining the polygon or nil on error
--- @usage local pentagon = CreatePolygon({x=0, z=0}, 3000, 5, 0)
function CreatePolygon(center, radius, numSides, rotation)
    if not center or not radius or not numSides then
        _HarnessInternal.log.error(
            "CreatePolygon requires center, radius, and number of sides",
            "Shapes.CreatePolygon"
        )
        return nil
    end

    if numSides < 3 then
        _HarnessInternal.log.error(
            "CreatePolygon requires at least 3 sides",
            "Shapes.CreatePolygon"
        )
        return nil
    end

    center = ToVec2(center)
    rotation = rotation or 0

    local points = {}
    local angleStep = 2 * math.pi / numSides

    for i = 0, numSides - 1 do
        local angle = i * angleStep - math.pi / 2 + DegToRad(rotation)
        local x = radius * math.cos(angle)
        local z = radius * math.sin(angle)
        table.insert(points, center + Vec2(x, z))
    end

    return points
end

--- Creates a hexagon shape
--- @param center table|Vec2 Center point of the hexagon {x, z} or Vec2
--- @param radius number Radius to vertices in meters
--- @param rotation number? Rotation angle in degrees (default: 0)
--- @return table|nil points Array of Vec2 points defining the hexagon or nil on error
--- @usage local hex = CreateHexagon({x=0, z=0}, 2000, 30)
function CreateHexagon(center, radius, rotation)
    return CreatePolygon(center, radius, 6, rotation)
end

--- Creates an octagon shape
--- @param center table|Vec2 Center point of the octagon {x, z} or Vec2
--- @param radius number Radius to vertices in meters
--- @param rotation number? Rotation angle in degrees (default: 0)
--- @return table|nil points Array of Vec2 points defining the octagon or nil on error
--- @usage local oct = CreateOctagon({x=0, z=0}, 2000, 0)
function CreateOctagon(center, radius, rotation)
    return CreatePolygon(center, radius, 8, rotation)
end

--- Creates an arc shape
--- @param center table|Vec2 Center point of the arc {x, z} or Vec2
--- @param radius number Radius in meters
--- @param startBearing number? Starting bearing in degrees (default: 0)
--- @param endBearing number? Ending bearing in degrees (default: 90)
--- @param numPoints number? Number of points (default: based on arc size)
--- @return table|nil points Array of Vec2 points defining the arc or nil on error
--- @usage local arc = CreateArc({x=0, z=0}, 5000, 0, 180, 37)
function CreateArc(center, radius, startBearing, endBearing, numPoints)
    if not center or not radius then
        _HarnessInternal.log.error("CreateArc requires center and radius", "Shapes.CreateArc")
        return nil
    end

    center = ToVec2(center)
    startBearing = startBearing or 0
    endBearing = endBearing or 90
    numPoints = numPoints or math.ceil(math.abs(endBearing - startBearing) / 5) + 1

    local points = {}

    -- Normalize bearings
    startBearing = startBearing % 360
    endBearing = endBearing % 360

    -- Calculate arc span
    local arcSpan = endBearing - startBearing
    if arcSpan < 0 then
        arcSpan = arcSpan + 360
    end

    local angleStep = arcSpan / (numPoints - 1)

    for i = 0, numPoints - 1 do
        local bearing = (startBearing + i * angleStep) % 360
        table.insert(points, center:displace(bearing, radius))
    end

    return points
end

--- Creates a spiral shape
--- @param center table|Vec2 Center point of the spiral {x, z} or Vec2
--- @param startRadius number? Starting radius in meters (default: 100)
--- @param endRadius number? Ending radius in meters (default: 1000)
--- @param numTurns number? Number of complete turns (default: 3)
--- @param pointsPerTurn number? Points per turn (default: 36)
--- @return table|nil points Array of Vec2 points defining the spiral or nil on error
--- @usage local spiral = CreateSpiral({x=0, z=0}, 100, 5000, 5, 72)
function CreateSpiral(center, startRadius, endRadius, numTurns, pointsPerTurn)
    if not center then
        _HarnessInternal.log.error("CreateSpiral requires center point", "Shapes.CreateSpiral")
        return nil
    end

    center = ToVec2(center)
    startRadius = startRadius or 100
    endRadius = endRadius or 1000
    numTurns = numTurns or 3
    pointsPerTurn = pointsPerTurn or 36

    local points = {}
    local totalPoints = numTurns * pointsPerTurn
    local radiusStep = (endRadius - startRadius) / totalPoints
    local angleStep = 2 * math.pi / pointsPerTurn

    for i = 0, totalPoints - 1 do
        local radius = startRadius + i * radiusStep
        local angle = i * angleStep
        local x = radius * math.cos(angle)
        local z = radius * math.sin(angle)
        table.insert(points, center + Vec2(x, z))
    end

    return points
end

--- Creates a ring/donut shape
--- @param center table|Vec2 Center point of the ring {x, z} or Vec2
--- @param outerRadius number Outer radius in meters
--- @param innerRadius number Inner radius in meters (must be less than outer)
--- @param numPoints number? Number of points per circle (default: 36)
--- @return table|nil points Array of Vec2 points defining the ring or nil on error
--- @usage local ring = CreateRing({x=0, z=0}, 5000, 3000, 72)
function CreateRing(center, outerRadius, innerRadius, numPoints)
    if not center then
        _HarnessInternal.log.error("CreateRing requires center point", "Shapes.CreateRing")
        return nil
    end

    if not outerRadius or not innerRadius or innerRadius >= outerRadius then
        _HarnessInternal.log.error(
            "CreateRing requires valid inner and outer radii",
            "Shapes.CreateRing"
        )
        return nil
    end

    -- Create as two circles that will form a ring when rendered
    -- Note: This creates a hollow ring outline, not a filled donut
    local outer = CreateCircle(center, outerRadius, numPoints)
    local inner = CreateCircle(center, innerRadius, numPoints)

    -- Reverse inner circle for proper winding
    local reversedInner = {}
    for i = #inner, 1, -1 do
        table.insert(reversedInner, inner[i])
    end

    -- Combine: outer circle + connection + reversed inner circle + connection back
    local ring = {}

    -- Add outer circle
    for _, p in ipairs(outer) do
        table.insert(ring, p)
    end

    -- Connect to inner circle
    table.insert(ring, reversedInner[1])

    -- Add reversed inner circle
    for _, p in ipairs(reversedInner) do
        table.insert(ring, p)
    end

    -- Close the ring
    table.insert(ring, outer[1])

    return ring
end

--- Creates a cross/plus shape
--- @param center table|Vec2 Center point of the cross {x, z} or Vec2
--- @param size number? Length of the cross arms in meters (default: 1000)
--- @param thickness number? Thickness of the arms in meters (default: 200)
--- @param rotation number? Rotation angle in degrees (default: 0)
--- @return table|nil points Array of Vec2 points defining the cross or nil on error
--- @usage local cross = CreateCross({x=0, z=0}, 2000, 400, 45)
function CreateCross(center, size, thickness, rotation)
    if not center then
        _HarnessInternal.log.error("CreateCross requires center point", "Shapes.CreateCross")
        return nil
    end

    center = ToVec2(center)
    size = size or 1000 -- Default 1km size
    thickness = thickness or 200 -- Default 200m thickness
    rotation = rotation or 0

    local halfSize = size / 2
    local halfThick = thickness / 2

    -- Define cross shape points (12 points for the outline)
    local points = {
        Vec2(-halfThick, -halfSize), -- Bottom of vertical bar
        Vec2(halfThick, -halfSize),
        Vec2(halfThick, -halfThick),
        Vec2(halfSize, -halfThick), -- Right of horizontal bar
        Vec2(halfSize, halfThick),
        Vec2(halfThick, halfThick),
        Vec2(halfThick, halfSize), -- Top of vertical bar
        Vec2(-halfThick, halfSize),
        Vec2(-halfThick, halfThick),
        Vec2(-halfSize, halfThick), -- Left of horizontal bar
        Vec2(-halfSize, -halfThick),
        Vec2(-halfThick, -halfThick),
    }

    -- Rotate and translate
    local result = {}
    for _, p in ipairs(points) do
        local rotated = p:rotate(rotation)
        table.insert(result, center + rotated)
    end

    return result
end

--- Converts shape points to Vec3 with specified altitude
--- @param shape table Array of Vec2 points
--- @param altitude number? Altitude in meters (default: 0)
--- @return table|nil points Array of Vec3 points or nil on error
--- @usage local shape3D = ShapeToVec3(triangle, 1000)
function ShapeToVec3(shape, altitude)
    if not shape or type(shape) ~= "table" then
        _HarnessInternal.log.error("ShapeToVec3 requires valid shape", "Shapes.ShapeToVec3")
        return nil
    end

    altitude = altitude or 0

    local result = {}
    for _, p in ipairs(shape) do
        if IsVec2(p) then
            table.insert(result, p:toVec3(altitude))
        elseif IsVec3(p) then
            table.insert(result, p)
        else
            table.insert(result, Vec3(p.x, altitude, p.z))
        end
    end

    return result
end
-- ==== END: src/shapes.lua ====

-- ==== BEGIN: src/spot.lua ====
--[[
==================================================================================================
    SPOT MODULE
    Laser and IR spot management utilities
==================================================================================================
]]
--- Create a laser spot
---@param source table Unit or weapon that creates the spot
---@param target table Target position (Vec3)
---@param localRef table? Optional local reference Vec3 on source (schema localRef)
---@param code number Laser code (1111-1788)
---@return table? spot Created spot object or nil on error
---@usage local spot = CreateLaserSpot(jtac, targetPos, nil, 1688)
function CreateLaserSpot(source, target, localRef, code)
    if not source then
        _HarnessInternal.log.error("CreateLaserSpot requires source unit/weapon", "CreateLaserSpot")
        return nil
    end

    if not target or not IsVec3(target) then
        _HarnessInternal.log.error(
            "CreateLaserSpot requires Vec3 target position",
            "CreateLaserSpot"
        )
        return nil
    end

    if code == nil then
        _HarnessInternal.log.error("CreateLaserSpot requires numeric laser code", "CreateLaserSpot")
        return nil
    end
    if type(code) ~= "number" then
        _HarnessInternal.log.error("CreateLaserSpot code must be a number", "CreateLaserSpot")
        return nil
    end
    if code < 1111 or code > 1788 then
        _HarnessInternal.log.error("Laser code must be between 1111-1788", "CreateLaserSpot")
        return nil
    end

    local success, spot = pcall(Spot.createLaser, source, localRef, target, code)
    if not success then
        _HarnessInternal.log.error(
            "Failed to create laser spot: " .. tostring(spot),
            "CreateLaserSpot"
        )
        return nil
    end

    _HarnessInternal.log.info(
        "Created laser spot" .. (code and (" with code " .. code) or ""),
        "CreateLaserSpot"
    )
    return spot
end

--- Create an IR pointer spot
---@param source table Unit that creates the spot
---@param target table Target position (Vec3)
---@param localRef table? Optional local reference Vec3 on source (schema localRef)
---@return table? spot Created spot object or nil on error
---@usage local spot = CreateIRSpot(aircraft, targetPos)
function CreateIRSpot(source, target, localRef)
    if not source then
        _HarnessInternal.log.error("CreateIRSpot requires source unit", "CreateIRSpot")
        return nil
    end

    if not target or not IsVec3(target) then
        _HarnessInternal.log.error("CreateIRSpot requires Vec3 target position", "CreateIRSpot")
        return nil
    end

    local success, spot = pcall(Spot.createInfraRed, source, localRef, target)
    if not success then
        _HarnessInternal.log.error("Failed to create IR spot: " .. tostring(spot), "CreateIRSpot")
        return nil
    end

    _HarnessInternal.log.info("Created IR spot", "CreateIRSpot")
    return spot
end

--- Destroy a spot
---@param spot table Spot object to destroy
---@return boolean success True if destroyed
---@usage DestroySpot(laserSpot)
function DestroySpot(spot)
    if not spot then
        _HarnessInternal.log.error("DestroySpot requires spot object", "DestroySpot")
        return false
    end

    local success, result = pcall(function()
        spot:destroy()
    end)
    if not success then
        _HarnessInternal.log.error("Failed to destroy spot: " .. tostring(result), "DestroySpot")
        return false
    end

    _HarnessInternal.log.info("Destroyed spot", "DestroySpot")
    return true
end

--- Get spot point/position
---@param spot table Spot object
---@return table? point Spot position (Vec3) or nil on error
---@usage local pos = GetSpotPoint(laserSpot)
function GetSpotPoint(spot)
    if not spot then
        _HarnessInternal.log.error("GetSpotPoint requires spot object", "GetSpotPoint")
        return nil
    end

    local success, point = pcall(function()
        return spot:getPoint()
    end)
    if not success then
        _HarnessInternal.log.error("Failed to get spot point: " .. tostring(point), "GetSpotPoint")
        return nil
    end

    if type(point) ~= "table" then
        return nil
    end
    return point
end

--- Set spot point/position
---@param spot table Spot object
---@param point table New position (Vec3)
---@return boolean success True if position was set
---@usage SetSpotPoint(laserSpot, newTargetPos)
function SetSpotPoint(spot, point)
    if not spot then
        _HarnessInternal.log.error("SetSpotPoint requires spot object", "SetSpotPoint")
        return false
    end

    if not point or not IsVec3(point) then
        _HarnessInternal.log.error("SetSpotPoint requires Vec3 position", "SetSpotPoint")
        return false
    end

    local success, result = pcall(function()
        spot:setPoint(point)
    end)
    if not success then
        _HarnessInternal.log.error("Failed to set spot point: " .. tostring(result), "SetSpotPoint")
        return false
    end

    return true
end

--- Get laser code
---@param spot table Laser spot object
---@return number? code Laser code or nil on error
---@usage local code = GetLaserCode(laserSpot)
function GetLaserCode(spot)
    if not spot then
        _HarnessInternal.log.error("GetLaserCode requires spot object", "GetLaserCode")
        return nil
    end

    local success, code = pcall(function()
        return spot:getCode()
    end)
    if not success then
        _HarnessInternal.log.error("Failed to get laser code: " .. tostring(code), "GetLaserCode")
        return nil
    end

    if type(code) ~= "number" then
        return nil
    end
    return code
end

--- Set laser code
---@param spot table Laser spot object
---@param code number New laser code (1111-1788)
---@return boolean success True if code was set
---@usage SetLaserCode(laserSpot, 1688)
function SetLaserCode(spot, code)
    if not spot then
        _HarnessInternal.log.error("SetLaserCode requires spot object", "SetLaserCode")
        return false
    end

    if not code or type(code) ~= "number" then
        _HarnessInternal.log.error("SetLaserCode requires numeric laser code", "SetLaserCode")
        return false
    end

    if code < 1111 or code > 1788 then
        _HarnessInternal.log.error("Laser code must be between 1111-1788", "SetLaserCode")
        return false
    end

    local success, result = pcall(function()
        spot:setCode(code)
    end)
    if not success then
        _HarnessInternal.log.error("Failed to set laser code: " .. tostring(result), "SetLaserCode")
        return false
    end

    _HarnessInternal.log.info("Set laser code to " .. code, "SetLaserCode")
    return true
end

--- Check if spot exists/is active
---@param spot table Spot object
---@return boolean exists True if spot exists
---@usage if SpotExists(laserSpot) then ... end
function SpotExists(spot)
    if not spot then
        return false
    end

    -- Schema does not expose isExist; probe a lightweight getter instead
    local success = pcall(function()
        -- getCategory is cheap and available per schema; any error implies invalid spot
        return spot:getCategory()
    end)
    return success == true
end

--- Get spot category
---@param spot table Spot object
---@return number? category Spot category or nil on error
---@usage local cat = GetSpotCategory(spot)
function GetSpotCategory(spot)
    if not spot then
        _HarnessInternal.log.error("GetSpotCategory requires spot object", "GetSpotCategory")
        return nil
    end

    local success, category = pcall(function()
        return spot:getCategory()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get spot category: " .. tostring(category),
            "GetSpotCategory"
        )
        return nil
    end

    if type(category) ~= "number" then
        return nil
    end
    return category
end
-- ==== END: src/spot.lua ====

-- ==== BEGIN: src/terrain.lua ====
--[[
==================================================================================================
    TERRAIN MODULE
    Terrain and land utilities
==================================================================================================
]]

--- Get terrain height at position
---@param position table Vec2 or Vec3 position
---@return number height Terrain height at position (0 on error)
---@usage local height = GetTerrainHeight(position)
function GetTerrainHeight(position)
    if not position then
        _HarnessInternal.log.error("GetTerrainHeight requires position", "GetTerrainHeight")
        return 0
    end

    local vec2 = IsVec3(position) and Vec2(position.x, position.z) or ToVec2(position)

    if not IsVec2(vec2) then
        _HarnessInternal.log.error("GetTerrainHeight requires Vec2 or Vec3", "GetTerrainHeight")
        return 0
    end

    local success, height = pcall(land.getHeight, vec2)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get terrain height: " .. tostring(height),
            "GetTerrainHeight"
        )
        return 0
    end

    return height or 0
end

--- Get altitude above ground level
---@param position table Vec3 position
---@return number agl Altitude above ground level (0 on error)
---@usage local agl = GetAGL(position)
function GetAGL(position)
    if not IsVec3(position) then
        _HarnessInternal.log.error("GetAGL requires Vec3 position", "GetAGL")
        return 0
    end

    local groundHeight = GetTerrainHeight(position)
    return position.y - groundHeight
end

--- Set altitude to specific AGL
---@param position table Vec3 position
---@param agl number Desired altitude above ground level
---@return table newPosition Vec3 with adjusted altitude
---@usage local newPos = SetAGL(position, 100)
function SetAGL(position, agl)
    if not IsVec3(position) or type(agl) ~= "number" then
        _HarnessInternal.log.error("SetAGL requires Vec3 and number", "SetAGL")
        return Vec3()
    end

    local groundHeight = GetTerrainHeight(position)
    return Vec3(position.x, groundHeight + agl, position.z)
end

--- Check line of sight between two points
---@param from table Vec3 start position
---@param to table Vec3 end position
---@return boolean hasLOS True if line of sight exists
---@usage if HasLOS(pos1, pos2) then ... end
function HasLOS(from, to)
    if not IsVec3(from) or not IsVec3(to) then
        _HarnessInternal.log.error("HasLOS requires two valid Vec3", "HasLOS")
        return false
    end

    local success, visible = pcall(land.isVisible, from, to)
    if not success then
        _HarnessInternal.log.error("Failed to check LOS: " .. tostring(visible), "HasLOS")
        return false
    end

    return visible == true
end

--- Estimate terrain grade (slope) around a point by sampling heights
---@param point table Vec3 center position
---@param radius number? Sampling radius in meters (default: 5)
---@param step number? Angular step in degrees for ring sampling (default: 45)
---@return table result {slopeDeg:number, slopePercent:number, dzdx:number, dzdz:number}
---@usage local g = GetTerrainGrade(pos, 10, 30)
function GetTerrainGrade(point, radius, step)
    if not IsVec3(point) then
        _HarnessInternal.log.error("GetTerrainGrade requires Vec3 point", "GetTerrainGrade")
        return { slopeDeg = 0, slopePercent = 0, dzdx = 0, dzdz = 0 }
    end

    radius = tonumber(radius) or 5
    step = tonumber(step) or 45
    if step <= 0 then
        step = 45
    end

    local centerH = GetTerrainHeight(point)

    -- Finite-difference gradient estimate using samples along +x/-x and +z/-z axes
    local dx = radius
    local dz = radius

    local px = { x = (point.x or 0) + dx, y = 0, z = point.z or 0 }
    local nx = { x = (point.x or 0) - dx, y = 0, z = point.z or 0 }
    local pz = { x = point.x or 0, y = 0, z = (point.z or 0) + dz }
    local nz = { x = point.x or 0, y = 0, z = (point.z or 0) - dz }

    local hx = GetTerrainHeight(px)
    local hnx = GetTerrainHeight(nx)
    local hz = GetTerrainHeight(pz)
    local hnz = GetTerrainHeight(nz)

    local dzdx = ((hx or centerH) - (hnx or centerH)) / (2 * dx)
    local dzdz = ((hz or centerH) - (hnz or centerH)) / (2 * dz)

    local slopeMag = math.sqrt(dzdx * dzdx + dzdz * dzdz)
    local slopeDeg = math.deg(math.atan(slopeMag))
    local slopePercent = slopeMag * 100

    return { slopeDeg = slopeDeg, slopePercent = slopePercent, dzdx = dzdx, dzdz = dzdz }
end

--- Get surface type at position
---@param position table Vec2 or Vec3 position
---@return number? surfaceType Surface type ID (1=land, 2=shallow water, 3=water, 4=road, 5=runway)
---@usage local surface = GetSurfaceType(position)
function GetSurfaceType(position)
    if not position then
        _HarnessInternal.log.error("GetSurfaceType requires position", "GetSurfaceType")
        return nil
    end

    local vec2 = IsVec3(position) and Vec2(position.x, position.z) or ToVec2(position)

    if not IsVec2(vec2) then
        _HarnessInternal.log.error("GetSurfaceType requires Vec2 or Vec3", "GetSurfaceType")
        return nil
    end

    local success, surfaceType = pcall(land.getSurfaceType, vec2)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get surface type: " .. tostring(surfaceType),
            "GetSurfaceType"
        )
        return nil
    end

    return surfaceType
end

--- Check if position is over water
---@param position table Vec2 or Vec3 position
---@return boolean overWater True if over water or shallow water
---@usage if IsOverWater(position) then ... end
function IsOverWater(position)
    local surfaceType = GetSurfaceType(position)
    if not surfaceType then
        return false
    end

    -- land.SurfaceType.WATER = 3, SHALLOW_WATER = 2
    return surfaceType == 2 or surfaceType == 3
end

--- Check if position is over land
---@param position table Vec2 or Vec3 position
---@return boolean overLand True if over land, road, or runway
---@usage if IsOverLand(position) then ... end
function IsOverLand(position)
    local surfaceType = GetSurfaceType(position)
    if not surfaceType then
        return false
    end

    -- land.SurfaceType.LAND = 1, ROAD = 4, RUNWAY = 5
    return surfaceType == 1 or surfaceType == 4 or surfaceType == 5
end

--- Get intersection point of ray with terrain
---@param origin table Vec3 ray origin
---@param direction table Vec3 ray direction
---@param maxDistance number Maximum ray distance
---@return table? intersection Vec3 intersection point if found
---@usage local hit = GetTerrainIntersection(origin, direction, 10000)
function GetTerrainIntersection(origin, direction, maxDistance)
    if not IsVec3(origin) or not IsVec3(direction) or type(maxDistance) ~= "number" then
        _HarnessInternal.log.error(
            "GetTerrainIntersection requires origin Vec3, direction Vec3, and maxDistance",
            "GetTerrainIntersection"
        )
        return nil
    end

    local success, intersection = pcall(land.getIP, origin, direction, maxDistance)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get terrain intersection: " .. tostring(intersection),
            "GetTerrainIntersection"
        )
        return nil
    end

    return intersection
end

--- Get terrain profile between two points
---@param from table Vec3 start position
---@param to table Vec3 end position
---@return table profile Array of profile points (empty on error)
---@usage local profile = GetTerrainProfile(pos1, pos2)
function GetTerrainProfile(from, to)
    if not IsVec3(from) or not IsVec3(to) then
        _HarnessInternal.log.error("GetTerrainProfile requires two valid Vec3", "GetTerrainProfile")
        return {}
    end

    local success, profile = pcall(land.profile, from, to)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get terrain profile: " .. tostring(profile),
            "GetTerrainProfile"
        )
        return {}
    end

    return profile or {}
end

--- Find closest point on roads
---@param position table Vec2 or Vec3 position
---@param roadType string? Road type ("roads" or "rails", default "roads")
---@return table? point Closest point on road if found
---@usage local roadPoint = GetClosestRoadPoint(position, "roads")
function GetClosestRoadPoint(position, roadType)
    if not position then
        _HarnessInternal.log.error("GetClosestRoadPoint requires position", "GetClosestRoadPoint")
        return nil
    end

    local vec2 = IsVec3(position) and Vec2(position.x, position.z) or ToVec2(position)

    if not IsVec2(vec2) then
        _HarnessInternal.log.error(
            "GetClosestRoadPoint requires Vec2 or Vec3",
            "GetClosestRoadPoint"
        )
        return nil
    end

    roadType = roadType or "roads"
    -- DCS API nuance: getClosestPointOnRoads expects 'railroads', while findPathOnRoads uses 'rails'
    if roadType == "rails" then
        roadType = "railroads"
    end

    if type(vec2.x) ~= "number" or type(vec2.z) ~= "number" then
        _HarnessInternal.log.error(
            "GetClosestRoadPoint requires numeric x/z on position",
            "GetClosestRoadPoint"
        )
        return nil
    end

    local success, r1, r2 =
        pcall(land.getClosestPointOnRoads, roadType, tonumber(vec2.x), tonumber(vec2.z))
    if not success then
        _HarnessInternal.log.error(
            "Failed to get closest road point: " .. tostring(r1),
            "GetClosestRoadPoint"
        )
        return nil
    end

    -- Normalize return: API may return table or two numeric coordinates
    if type(r1) == "table" then
        return r1
    end
    if type(r1) == "number" and type(r2) == "number" then
        return { x = r1, y = r2 }
    end
    return nil
end

--- Find path on roads between two points
---@param from table Vec2 or Vec3 start position
---@param to table Vec2 or Vec3 end position
---@param roadType string? Road type ("roads" or "railroads", default "roads")
---@return table path Array of path points (empty on error)
---@usage local path = FindRoadPath(start, finish, "roads")
function FindRoadPath(from, to, roadType)
    if not from or not to then
        _HarnessInternal.log.error("FindRoadPath requires from and to positions", "FindRoadPath")
        return {}
    end

    local fromVec2 = IsVec3(from) and Vec2(from.x, from.z) or from
    local toVec2 = IsVec3(to) and Vec2(to.x, to.z) or to

    if not IsVec2(fromVec2) or not IsVec2(toVec2) then
        _HarnessInternal.log.error("FindRoadPath requires Vec2 or Vec3 positions", "FindRoadPath")
        return {}
    end

    -- Note: For rails, the parameter should be "rails" not "railroads"
    roadType = roadType or "roads"
    if roadType == "railroads" then
        roadType = "rails"
    end

    local success, path =
        pcall(land.findPathOnRoads, roadType, fromVec2.x, fromVec2.z, toVec2.x, toVec2.z)
    if not success then
        _HarnessInternal.log.error("Failed to find road path: " .. tostring(path), "FindRoadPath")
        return {}
    end

    return path or {}
end
-- ==== END: src/terrain.lua ====

-- ==== BEGIN: src/trigger.lua ====
--[[
    Trigger Module - DCS World Trigger API Wrappers
    
    This module provides validated wrapper functions for DCS trigger.action operations,
    including messages, explosions, smoke, illumination, and other effects.
]]

-- Internal helpers for colors/fills
local function _normalizeColor(c)
    if type(c) ~= "table" then
        return { r = 1, g = 1, b = 1, a = 1 }
    end
    return {
        r = c.r or c[1] or 1,
        g = c.g or c[2] or 1,
        b = c.b or c[3] or 1,
        a = c.a or c[4] or 1,
    }
end

local function _defaultFill(color, fill)
    if type(fill) == "table" then
        return {
            r = fill.r or fill[1] or 1,
            g = fill.g or fill[2] or 1,
            b = fill.b or fill[3] or 1,
            a = fill.a or fill[4] or 0.25,
        }
    end
    local c = _normalizeColor(color)
    local a = c.a or 1
    return { r = c.r, g = c.g, b = c.b, a = math.max(0.0, math.min(1.0, a * 0.25)) }
end

-- Convert color table to array form {r,g,b,a} for DCS APIs
local function _toArrayColor(color)
    if type(color) ~= "table" then
        return { 1, 1, 1, 1 }
    end
    local r = color.r or color[1] or 1
    local g = color.g or color[2] or 1
    local b = color.b or color[3] or 1
    local a = color.a or color[4] or 1
    return { r, g, b, a }
end

--- Displays text message to all players
---@param text string The text message to display
---@param displayTime number? The time in seconds to display (default: 10)
---@param clearView boolean? Whether to clear the previous message (default: false)
---@return boolean? success Returns true if successful, nil on error
---@usage OutText("Hello World", 15, true)
function OutText(text, displayTime, clearView)
    if not text or type(text) ~= "string" then
        _HarnessInternal.log.error("OutText requires valid text string", "Trigger.OutText")
        return nil
    end

    if not displayTime or type(displayTime) ~= "number" then
        displayTime = 10
    end

    clearView = clearView or false

    local success, result = pcall(trigger.action.outText, text, displayTime, clearView)
    if not success then
        _HarnessInternal.log.error(
            "Failed to display text: " .. tostring(result),
            "Trigger.OutText"
        )
        return nil
    end

    return true
end

--- Displays text message to a specific coalition
---@param coalitionId number The coalition ID (0=neutral, 1=red, 2=blue)
---@param text string The text message to display
---@param displayTime number? The time in seconds to display (default: 10)
---@param clearView boolean? Whether to clear the previous message (default: false)
---@return boolean? success Returns true if successful, nil on error
---@usage OutTextForCoalition(coalition.side.BLUE, "Blue team message", 20)
function OutTextForCoalition(coalitionId, text, displayTime, clearView)
    if not coalitionId or type(coalitionId) ~= "number" then
        _HarnessInternal.log.error(
            "OutTextForCoalition requires valid coalition ID",
            "Trigger.OutTextForCoalition"
        )
        return nil
    end

    if not text or type(text) ~= "string" then
        _HarnessInternal.log.error(
            "OutTextForCoalition requires valid text string",
            "Trigger.OutTextForCoalition"
        )
        return nil
    end

    if not displayTime or type(displayTime) ~= "number" then
        displayTime = 10
    end

    clearView = clearView or false

    local success, result =
        pcall(trigger.action.outTextForCoalition, coalitionId, text, displayTime, clearView)
    if not success then
        _HarnessInternal.log.error(
            "Failed to display coalition text: " .. tostring(result),
            "Trigger.OutTextForCoalition"
        )
        return nil
    end

    return true
end

--- Displays text message to a specific group
---@param groupId number The group ID to display message to
---@param text string The text message to display
---@param displayTime number? The time in seconds to display (default: 10)
---@param clearView boolean? Whether to clear the previous message (default: false)
---@return boolean? success Returns true if successful, nil on error
---@usage OutTextForGroup(1001, "Group message", 15)
function OutTextForGroup(groupId, text, displayTime, clearView)
    if not groupId or type(groupId) ~= "number" then
        _HarnessInternal.log.error(
            "OutTextForGroup requires valid group ID",
            "Trigger.OutTextForGroup"
        )
        return nil
    end

    if not text or type(text) ~= "string" then
        _HarnessInternal.log.error(
            "OutTextForGroup requires valid text string",
            "Trigger.OutTextForGroup"
        )
        return nil
    end

    if not displayTime or type(displayTime) ~= "number" then
        displayTime = 10
    end

    clearView = clearView or false

    local success, result =
        pcall(trigger.action.outTextForGroup, groupId, text, displayTime, clearView)
    if not success then
        _HarnessInternal.log.error(
            "Failed to display group text: " .. tostring(result),
            "Trigger.OutTextForGroup"
        )
        return nil
    end

    return true
end

--- Displays text message to a specific unit
---@param unitId number The unit ID to display message to
---@param text string The text message to display
---@param displayTime number? The time in seconds to display (default: 10)
---@param clearView boolean? Whether to clear the previous message (default: false)
---@return boolean? success Returns true if successful, nil on error
---@usage OutTextForUnit(2001, "Unit message", 10)
function OutTextForUnit(unitId, text, displayTime, clearView)
    if not unitId or type(unitId) ~= "number" then
        _HarnessInternal.log.error(
            "OutTextForUnit requires valid unit ID",
            "Trigger.OutTextForUnit"
        )
        return nil
    end

    if not text or type(text) ~= "string" then
        _HarnessInternal.log.error(
            "OutTextForUnit requires valid text string",
            "Trigger.OutTextForUnit"
        )
        return nil
    end

    if not displayTime or type(displayTime) ~= "number" then
        displayTime = 10
    end

    clearView = clearView or false

    local success, result =
        pcall(trigger.action.outTextForUnit, unitId, text, displayTime, clearView)
    if not success then
        _HarnessInternal.log.error(
            "Failed to display unit text: " .. tostring(result),
            "Trigger.OutTextForUnit"
        )
        return nil
    end

    return true
end

--- Plays a sound file to all players
---@param soundFile string The path to the sound file to play
---@param soundType any? Optional sound type parameter
---@return boolean? success Returns true if successful, nil on error
---@usage OutSound("sounds/alarm.ogg")
function OutSound(soundFile, soundType)
    if not soundFile or type(soundFile) ~= "string" then
        _HarnessInternal.log.error("OutSound requires valid sound file path", "Trigger.OutSound")
        return nil
    end

    local success, result = pcall(trigger.action.outSound, soundFile, soundType)
    if not success then
        _HarnessInternal.log.error("Failed to play sound: " .. tostring(result), "Trigger.OutSound")
        return nil
    end

    return true
end

--- Plays a sound file to a specific coalition
---@param coalitionId number The coalition ID (0=neutral, 1=red, 2=blue)
---@param soundFile string The path to the sound file to play
---@param soundType any? Optional sound type parameter
---@return boolean? success Returns true if successful, nil on error
---@usage OutSoundForCoalition(coalition.side.RED, "sounds/warning.ogg")
function OutSoundForCoalition(coalitionId, soundFile, soundType)
    if not coalitionId or type(coalitionId) ~= "number" then
        _HarnessInternal.log.error(
            "OutSoundForCoalition requires valid coalition ID",
            "Trigger.OutSoundForCoalition"
        )
        return nil
    end

    if not soundFile or type(soundFile) ~= "string" then
        _HarnessInternal.log.error(
            "OutSoundForCoalition requires valid sound file path",
            "Trigger.OutSoundForCoalition"
        )
        return nil
    end

    local success, result =
        pcall(trigger.action.outSoundForCoalition, coalitionId, soundFile, soundType)
    if not success then
        _HarnessInternal.log.error(
            "Failed to play coalition sound: " .. tostring(result),
            "Trigger.OutSoundForCoalition"
        )
        return nil
    end

    return true
end

--- Creates an explosion at the specified position
---@param pos table Position table with x, y, z coordinates
---@param power number The explosion power/strength
---@return boolean? success Returns true if successful, nil on error
---@usage Explosion({x=1000, y=100, z=2000}, 500)
function Explosion(pos, power)
    if not pos or type(pos) ~= "table" or not pos.x or not pos.y or not pos.z then
        _HarnessInternal.log.error(
            "Explosion requires valid position with x, y, z",
            "Trigger.Explosion"
        )
        return nil
    end

    if not power or type(power) ~= "number" or power <= 0 then
        _HarnessInternal.log.error("Explosion requires valid power value", "Trigger.Explosion")
        return nil
    end

    local success, result = pcall(trigger.action.explosion, pos, power)
    if not success then
        _HarnessInternal.log.error(
            "Failed to create explosion: " .. tostring(result),
            "Trigger.Explosion"
        )
        return nil
    end

    return true
end

--- Creates smoke effect at the specified position
---@param pos table Position table with x, y, z coordinates
---@param smokeColor number Smoke color enum value
---@param density number? Optional smoke density
---@param name string? Optional name for the smoke effect
---@return boolean? success Returns true if successful, nil on error
---@usage Smoke({x=1000, y=0, z=2000}, trigger.smokeColor.Red)
function Smoke(pos, smokeColor, density, name)
    if not pos or type(pos) ~= "table" or not pos.x or not pos.y or not pos.z then
        _HarnessInternal.log.error("Smoke requires valid position with x, y, z", "Trigger.Smoke")
        return nil
    end

    if not smokeColor or type(smokeColor) ~= "number" then
        _HarnessInternal.log.error("Smoke requires valid smoke color enum", "Trigger.Smoke")
        return nil
    end

    local success, result = pcall(trigger.action.smoke, pos, smokeColor, density, name)
    if not success then
        _HarnessInternal.log.error("Failed to create smoke: " .. tostring(result), "Trigger.Smoke")
        return nil
    end

    return true
end

--- Creates a big smoke effect at the specified position
---@param pos table Position table with x, y, z coordinates
---@param smokePreset number Smoke preset enum value
---@param density number? Optional smoke density
---@param name string? Optional name for the smoke effect
---@return boolean? success Returns true if successful, nil on error
---@usage EffectSmokeBig({x=1000, y=0, z=2000}, trigger.effectPresets.BigSmoke)
function EffectSmokeBig(pos, smokePreset, density, name)
    if not pos or type(pos) ~= "table" or not pos.x or not pos.y or not pos.z then
        _HarnessInternal.log.error(
            "EffectSmokeBig requires valid position with x, y, z",
            "Trigger.EffectSmokeBig"
        )
        return nil
    end

    if not smokePreset or type(smokePreset) ~= "number" then
        _HarnessInternal.log.error(
            "EffectSmokeBig requires valid smoke preset enum",
            "Trigger.EffectSmokeBig"
        )
        return nil
    end

    local success, result = pcall(trigger.action.effectSmokeBig, pos, smokePreset, density, name)
    if not success then
        _HarnessInternal.log.error(
            "Failed to create big smoke effect: " .. tostring(result),
            "Trigger.EffectSmokeBig"
        )
        return nil
    end

    return true
end

--- Stops a named smoke effect
---@param name string The name of the smoke effect to stop
---@return boolean? success Returns true if successful, nil on error
---@usage EffectSmokeStop("smoke1")
function EffectSmokeStop(name)
    if not name or type(name) ~= "string" then
        _HarnessInternal.log.error(
            "EffectSmokeStop requires valid smoke effect name",
            "Trigger.EffectSmokeStop"
        )
        return nil
    end

    local success, result = pcall(trigger.action.effectSmokeStop, name)
    if not success then
        _HarnessInternal.log.error(
            "Failed to stop smoke effect: " .. tostring(result),
            "Trigger.EffectSmokeStop"
        )
        return nil
    end

    return true
end

--- Creates an illumination bomb at the specified position
---@param pos table Position table with x, y, z coordinates
---@param power number? The illumination power (default: 1000000)
---@return boolean? success Returns true if successful, nil on error
---@usage IlluminationBomb({x=1000, y=500, z=2000}, 2000000)
function IlluminationBomb(pos, power)
    if not pos or type(pos) ~= "table" or not pos.x or not pos.y or not pos.z then
        _HarnessInternal.log.error(
            "IlluminationBomb requires valid position with x, y, z",
            "Trigger.IlluminationBomb"
        )
        return nil
    end

    if not power or type(power) ~= "number" or power <= 0 then
        power = 1000000
    end

    local success, result = pcall(trigger.action.illuminationBomb, pos, power)
    if not success then
        _HarnessInternal.log.error(
            "Failed to create illumination bomb: " .. tostring(result),
            "Trigger.IlluminationBomb"
        )
        return nil
    end

    return true
end

--- Fires a signal flare at the specified position
---@param pos table Position table with x, y, z coordinates
---@param flareColor number Flare color enum value
---@param azimuth number? The azimuth direction in radians (default: 0)
---@return boolean? success Returns true if successful, nil on error
---@usage SignalFlare({x=1000, y=100, z=2000}, trigger.flareColor.Red, math.rad(45))
function SignalFlare(pos, flareColor, azimuth)
    if not pos or type(pos) ~= "table" or not pos.x or not pos.y or not pos.z then
        _HarnessInternal.log.error(
            "SignalFlare requires valid position with x, y, z",
            "Trigger.SignalFlare"
        )
        return nil
    end

    if not flareColor or type(flareColor) ~= "number" then
        _HarnessInternal.log.error(
            "SignalFlare requires valid flare color enum",
            "Trigger.SignalFlare"
        )
        return nil
    end

    if not azimuth or type(azimuth) ~= "number" then
        azimuth = 0
    end

    local success, result = pcall(trigger.action.signalFlare, pos, flareColor, azimuth)
    if not success then
        _HarnessInternal.log.error(
            "Failed to create signal flare: " .. tostring(result),
            "Trigger.SignalFlare"
        )
        return nil
    end

    return true
end

--- Starts a radio transmission from a position
---@param filename string The audio file to transmit
---@param pos table Position table with x, y, z coordinates
---@param modulation number? Radio modulation type (default: 0)
---@param loop boolean? Whether to loop the transmission
---@param frequency number? Transmission frequency in Hz (default: 124000000)
---@param power number? Transmission power (default: 100)
---@param name string? Optional name for the transmission
---@return boolean? success Returns true if successful, nil on error
---@usage RadioTransmission("sounds/message.ogg", {x=1000, y=100, z=2000}, 0, true, 124000000, 100, "radio1")
function RadioTransmission(filename, pos, modulation, loop, frequency, power, name)
    if not filename or type(filename) ~= "string" then
        _HarnessInternal.log.error(
            "RadioTransmission requires valid filename",
            "Trigger.RadioTransmission"
        )
        return nil
    end

    if not pos or type(pos) ~= "table" or not pos.x or not pos.y or not pos.z then
        _HarnessInternal.log.error(
            "RadioTransmission requires valid position with x, y, z",
            "Trigger.RadioTransmission"
        )
        return nil
    end

    if not modulation or type(modulation) ~= "number" then
        modulation = 0
    end

    if not frequency or type(frequency) ~= "number" then
        frequency = 124000000
    end

    if not power or type(power) ~= "number" then
        power = 100
    end

    local success, result = pcall(
        trigger.action.radioTransmission,
        filename,
        pos,
        modulation,
        loop,
        frequency,
        power,
        name
    )
    if not success then
        _HarnessInternal.log.error(
            "Failed to start radio transmission: " .. tostring(result),
            "Trigger.RadioTransmission"
        )
        return nil
    end

    return true
end

--- Stops a named radio transmission
---@param name string The name of the transmission to stop
---@return boolean? success Returns true if successful, nil on error
---@usage StopRadioTransmission("radio1")
function StopRadioTransmission(name)
    if not name or type(name) ~= "string" then
        _HarnessInternal.log.error(
            "StopRadioTransmission requires valid transmission name",
            "Trigger.StopRadioTransmission"
        )
        return nil
    end

    local success, result = pcall(trigger.action.stopRadioTransmission, name)
    if not success then
        _HarnessInternal.log.error(
            "Failed to stop radio transmission: " .. tostring(result),
            "Trigger.StopRadioTransmission"
        )
        return nil
    end

    return true
end

--- Sets the radius of an existing map mark
---@param markId number The ID of the mark to modify
---@param radius number The new radius in meters
---@return boolean? success Returns true if successful, nil on error
---@usage SetMarkupRadius(1001, 5000)
function SetMarkupRadius(markId, radius)
    if not markId or type(markId) ~= "number" then
        _HarnessInternal.log.error(
            "SetMarkupRadius requires valid mark ID",
            "Trigger.SetMarkupRadius"
        )
        return nil
    end

    if not radius or type(radius) ~= "number" or radius <= 0 then
        _HarnessInternal.log.error(
            "SetMarkupRadius requires valid radius",
            "Trigger.SetMarkupRadius"
        )
        return nil
    end

    local success, result = pcall(trigger.action.setMarkupRadius, markId, radius)
    if not success then
        _HarnessInternal.log.error(
            "Failed to set markup radius: " .. tostring(result),
            "Trigger.SetMarkupRadius"
        )
        return nil
    end

    return true
end

--- Sets the text of an existing map mark
---@param markId number The ID of the mark to modify
---@param text string The new text for the mark
---@return boolean? success Returns true if successful, nil on error
---@usage SetMarkupText(1001, "New target location")
function SetMarkupText(markId, text)
    if not markId or type(markId) ~= "number" then
        _HarnessInternal.log.error("SetMarkupText requires valid mark ID", "Trigger.SetMarkupText")
        return nil
    end

    if not text or type(text) ~= "string" then
        _HarnessInternal.log.error(
            "SetMarkupText requires valid text string",
            "Trigger.SetMarkupText"
        )
        return nil
    end

    local success, result = pcall(trigger.action.setMarkupText, markId, text)
    if not success then
        _HarnessInternal.log.error(
            "Failed to set markup text: " .. tostring(result),
            "Trigger.SetMarkupText"
        )
        return nil
    end

    return true
end

--- Sets the color of an existing map mark
---@param markId number The ID of the mark to modify
---@param color table Color table with r, g, b, a values (0-1)
---@return boolean? success Returns true if successful, nil on error
---@usage SetMarkupColor(1001, {r=1, g=0, b=0, a=1})
function SetMarkupColor(markId, color)
    if not markId or type(markId) ~= "number" then
        _HarnessInternal.log.error(
            "SetMarkupColor requires valid mark ID",
            "Trigger.SetMarkupColor"
        )
        return nil
    end

    if not color or type(color) ~= "table" then
        _HarnessInternal.log.error(
            "SetMarkupColor requires valid color table",
            "Trigger.SetMarkupColor"
        )
        return nil
    end

    local success, result = pcall(trigger.action.setMarkupColor, markId, color)
    if not success then
        _HarnessInternal.log.error(
            "Failed to set markup color: " .. tostring(result),
            "Trigger.SetMarkupColor"
        )
        return nil
    end

    return true
end

--- Sets the fill color of an existing map mark
---@param markId number The ID of the mark to modify
---@param colorFill table Color table with r, g, b, a values (0-1)
---@return boolean? success Returns true if successful, nil on error
---@usage SetMarkupColorFill(1001, {r=0, g=1, b=0, a=0.5})
function SetMarkupColorFill(markId, colorFill)
    if not markId or type(markId) ~= "number" then
        _HarnessInternal.log.error(
            "SetMarkupColorFill requires valid mark ID",
            "Trigger.SetMarkupColorFill"
        )
        return nil
    end

    if not colorFill or type(colorFill) ~= "table" then
        _HarnessInternal.log.error(
            "SetMarkupColorFill requires valid color fill table",
            "Trigger.SetMarkupColorFill"
        )
        return nil
    end

    local success, result = pcall(trigger.action.setMarkupColorFill, markId, colorFill)
    if not success then
        _HarnessInternal.log.error(
            "Failed to set markup color fill: " .. tostring(result),
            "Trigger.SetMarkupColorFill"
        )
        return nil
    end

    return true
end

--- Sets the font size of an existing map mark
---@param markId number The ID of the mark to modify
---@param fontSize number The font size in points
---@return boolean? success Returns true if successful, nil on error
---@usage SetMarkupFontSize(1001, 18)
function SetMarkupFontSize(markId, fontSize)
    if not markId or type(markId) ~= "number" then
        _HarnessInternal.log.error(
            "SetMarkupFontSize requires valid mark ID",
            "Trigger.SetMarkupFontSize"
        )
        return nil
    end

    if not fontSize or type(fontSize) ~= "number" or fontSize <= 0 then
        _HarnessInternal.log.error(
            "SetMarkupFontSize requires valid font size",
            "Trigger.SetMarkupFontSize"
        )
        return nil
    end

    local success, result = pcall(trigger.action.setMarkupFontSize, markId, fontSize)
    if not success then
        _HarnessInternal.log.error(
            "Failed to set markup font size: " .. tostring(result),
            "Trigger.SetMarkupFontSize"
        )
        return nil
    end

    return true
end

--- Removes a map mark
---@param markId number The ID of the mark to remove
---@return boolean? success Returns true if successful, nil on error
---@usage RemoveMark(1001)
function RemoveMark(markId)
    if not markId or type(markId) ~= "number" then
        _HarnessInternal.log.error("RemoveMark requires valid mark ID", "Trigger.RemoveMark")
        return nil
    end

    local success, result = pcall(trigger.action.removeMark, markId)
    if not success then
        _HarnessInternal.log.error(
            "Failed to remove mark: " .. tostring(result),
            "Trigger.RemoveMark"
        )
        return nil
    end

    return true
end

--- Creates a map mark visible to all players
---@param markId number Unique ID for the mark
---@param text string? Text to display (default: "")
---@param pos table Position table with x, y, z coordinates
---@param readOnly boolean? Whether the mark is read-only
---@param message string? Optional message
---@return boolean? success Returns true if successful, nil on error
---@usage MarkToAll(1001, "Target", {x=1000, y=0, z=2000}, true)
function MarkToAll(markId, text, pos, readOnly, message)
    if not markId or type(markId) ~= "number" then
        _HarnessInternal.log.error("MarkToAll requires valid mark ID", "Trigger.MarkToAll")
        return nil
    end

    if not text or type(text) ~= "string" then
        text = ""
    end

    if not pos or type(pos) ~= "table" or not pos.x or not pos.y or not pos.z then
        _HarnessInternal.log.error(
            "MarkToAll requires valid position with x, y, z",
            "Trigger.MarkToAll"
        )
        return nil
    end

    local success, result = pcall(trigger.action.markToAll, markId, text, pos, readOnly, message)
    if not success then
        _HarnessInternal.log.error(
            "Failed to create mark for all: " .. tostring(result),
            "Trigger.MarkToAll"
        )
        return nil
    end

    return true
end

--- Creates a map mark visible to a specific coalition
---@param markId number Unique ID for the mark
---@param text string? Text to display (default: "")
---@param pos table Position table with x, y, z coordinates
---@param coalitionId number The coalition ID (0=neutral, 1=red, 2=blue)
---@param readOnly boolean? Whether the mark is read-only
---@param message string? Optional message
---@return boolean? success Returns true if successful, nil on error
---@usage MarkToCoalition(1001, "Enemy Base", {x=1000, y=0, z=2000}, coalition.side.RED, true)
function MarkToCoalition(markId, text, pos, coalitionId, readOnly, message)
    if not markId or type(markId) ~= "number" then
        _HarnessInternal.log.error(
            "MarkToCoalition requires valid mark ID",
            "Trigger.MarkToCoalition"
        )
        return nil
    end

    if not coalitionId or type(coalitionId) ~= "number" then
        _HarnessInternal.log.error(
            "MarkToCoalition requires valid coalition ID",
            "Trigger.MarkToCoalition"
        )
        return nil
    end

    if not text or type(text) ~= "string" then
        text = ""
    end

    if not pos or type(pos) ~= "table" or not pos.x or not pos.y or not pos.z then
        _HarnessInternal.log.error(
            "MarkToCoalition requires valid position with x, y, z",
            "Trigger.MarkToCoalition"
        )
        return nil
    end

    local success, result =
        pcall(trigger.action.markToCoalition, markId, text, pos, coalitionId, readOnly, message)
    if not success then
        _HarnessInternal.log.error(
            "Failed to create mark for coalition: " .. tostring(result),
            "Trigger.MarkToCoalition"
        )
        return nil
    end

    return true
end

--- Creates a map mark visible to a specific group
---@param markId number Unique ID for the mark
---@param text string? Text to display (default: "")
---@param pos table Position table with x, y, z coordinates
---@param groupId number The group ID
---@param readOnly boolean? Whether the mark is read-only
---@param message string? Optional message
---@return boolean? success Returns true if successful, nil on error
---@usage MarkToGroup(1001, "Waypoint", {x=1000, y=0, z=2000}, 501, false)
function MarkToGroup(markId, text, pos, groupId, readOnly, message)
    if not markId or type(markId) ~= "number" then
        _HarnessInternal.log.error("MarkToGroup requires valid mark ID", "Trigger.MarkToGroup")
        return nil
    end

    if not groupId or type(groupId) ~= "number" then
        _HarnessInternal.log.error("MarkToGroup requires valid group ID", "Trigger.MarkToGroup")
        return nil
    end

    if not text or type(text) ~= "string" then
        text = ""
    end

    if not pos or type(pos) ~= "table" or not pos.x or not pos.y or not pos.z then
        _HarnessInternal.log.error(
            "MarkToGroup requires valid position with x, y, z",
            "Trigger.MarkToGroup"
        )
        return nil
    end

    local success, result =
        pcall(trigger.action.markToGroup, markId, text, pos, groupId, readOnly, message)
    if not success then
        _HarnessInternal.log.error(
            "Failed to create mark for group: " .. tostring(result),
            "Trigger.MarkToGroup"
        )
        return nil
    end

    return true
end

--- Draws a line on the map visible to all players
---@param markId number Unique ID for the line
---@param startPos table Start position with x, y, z coordinates
---@param endPos table End position with x, y, z coordinates
---@param color table? Color table with r, g, b, a values (0-1)
---@param lineType number? Line type enum
---@param readOnly boolean? Whether the line is read-only
---@param message string? Optional message
---@return boolean? success Returns true if successful, nil on error
---@usage LineToAll(1001, {x=1000, y=0, z=2000}, {x=2000, y=0, z=3000}, {r=1, g=0, b=0, a=1})
function LineToAll(
    coalitionOrId,
    startOrIdOrStart,
    endOrStartOrEnd,
    colorOrEnd,
    lineTypeOrColor,
    readOnlyOrLineType,
    messageOrReadOnly
)
    -- Backward-compatible signature handling:
    -- Old: (id, startPos, endPos, color, lineType, readOnly, message)
    -- New (DCS): (coalition, id, startPos, endPos, color, lineType, readOnly, message)
    local coalitionArg, idArg, startPos, endPos, color, lineType, readOnly, message
    if
        type(startOrIdOrStart) == "table"
        and startOrIdOrStart.x
        and startOrIdOrStart.y
        and startOrIdOrStart.z
    then
        -- Old signature without coalition
        coalitionArg = -1
        idArg = coalitionOrId
        startPos = startOrIdOrStart
        endPos = endOrStartOrEnd
        color = colorOrEnd
        lineType = lineTypeOrColor
        readOnly = readOnlyOrLineType
        message = messageOrReadOnly
    else
        -- New signature
        coalitionArg = coalitionOrId
        idArg = startOrIdOrStart
        startPos = endOrStartOrEnd
        endPos = colorOrEnd
        color = lineTypeOrColor
        lineType = readOnlyOrLineType
        readOnly = messageOrReadOnly
        message = nil
    end

    if not idArg or type(idArg) ~= "number" then
        _HarnessInternal.log.error("LineToAll requires valid unique ID", "Trigger.LineToAll")
        return nil
    end

    if
        not startPos
        or type(startPos) ~= "table"
        or not startPos.x
        or not startPos.y
        or not startPos.z
    then
        _HarnessInternal.log.error(
            "LineToAll requires valid start position with x, y, z",
            "Trigger.LineToAll"
        )
        return nil
    end

    if not endPos or type(endPos) ~= "table" or not endPos.x or not endPos.y or not endPos.z then
        _HarnessInternal.log.error(
            "LineToAll requires valid end position with x, y, z",
            "Trigger.LineToAll"
        )
        return nil
    end

    color = _normalizeColor(color)
    local colorArr = _toArrayColor(color)
    local success, result = pcall(
        trigger.action.lineToAll,
        coalitionArg,
        idArg,
        startPos,
        endPos,
        colorArr,
        lineType,
        readOnly,
        message
    )
    if not success then
        _HarnessInternal.log.error(
            "Failed to create line for all: " .. tostring(result),
            "Trigger.LineToAll"
        )
        return nil
    end

    return true
end

--- Draws a circle on the map visible to all players
---@param markId number Unique ID for the circle
---@param center table Center position with x, y, z coordinates
---@param radius number Circle radius in meters
---@param color table? Border color with r, g, b, a values (0-1)
---@param fillColor table? Fill color with r, g, b, a values (0-1)
---@param lineType number? Line type enum
---@param readOnly boolean? Whether the circle is read-only
---@param message string? Optional message
---@return boolean? success Returns true if successful, nil on error
---@usage CircleToAll(1001, {x=1000, y=0, z=2000}, 500, {r=1, g=0, b=0, a=1}, {r=1, g=0, b=0, a=0.3})
function CircleToAll(
    coalitionOrId,
    centerOrIdOrCenter,
    radiusOrCenterOrRadius,
    colorOrRadiusOrColor,
    fillColorOrColorOrFill,
    lineTypeOrFillOrLine,
    readOnlyOrLineOrReadOnly,
    messageOrReadOnly
)
    -- Old: (id, center, radius, color, fillColor, lineType, readOnly, message)
    -- New: (coalition, id, center, radius, color, fillColor, lineType, readOnly, message)
    local coalitionArg, idArg, center, radius, color, fillColor, lineType, readOnly, message
    if
        type(centerOrIdOrCenter) == "table"
        and centerOrIdOrCenter.x
        and centerOrIdOrCenter.y
        and centerOrIdOrCenter.z
        and type(radiusOrCenterOrRadius) == "number"
    then
        coalitionArg = -1
        idArg = coalitionOrId
        center = centerOrIdOrCenter
        radius = radiusOrCenterOrRadius
        color = colorOrRadiusOrColor
        fillColor = fillColorOrColorOrFill
        lineType = lineTypeOrFillOrLine
        readOnly = readOnlyOrLineOrReadOnly
        message = messageOrReadOnly
    else
        coalitionArg = coalitionOrId
        idArg = centerOrIdOrCenter
        center = radiusOrCenterOrRadius
        radius = colorOrRadiusOrColor
        color = fillColorOrColorOrFill
        fillColor = lineTypeOrFillOrLine
        lineType = readOnlyOrLineOrReadOnly
        readOnly = messageOrReadOnly
        message = nil
    end

    if not idArg or type(idArg) ~= "number" then
        _HarnessInternal.log.error("CircleToAll requires valid unique ID", "Trigger.CircleToAll")
        return nil
    end

    if not center or type(center) ~= "table" or not center.x or not center.y or not center.z then
        _HarnessInternal.log.error(
            "CircleToAll requires valid center position with x, y, z",
            "Trigger.CircleToAll"
        )
        return nil
    end

    if not radius or type(radius) ~= "number" or radius <= 0 then
        _HarnessInternal.log.error("CircleToAll requires valid radius", "Trigger.CircleToAll")
        return nil
    end

    color = _normalizeColor(color)
    fillColor = _defaultFill(color, fillColor)
    local colorArr = _toArrayColor(color)
    local fillArr = _toArrayColor(fillColor)
    local success, result = pcall(
        trigger.action.circleToAll,
        coalitionArg,
        idArg,
        center,
        radius,
        colorArr,
        fillArr,
        lineType,
        readOnly,
        message
    )
    if not success then
        _HarnessInternal.log.error(
            "Failed to create circle for all: " .. tostring(result),
            "Trigger.CircleToAll"
        )
        return nil
    end

    return true
end

--- Draws a rectangle on the map visible to all players
---@param markId number Unique ID for the rectangle
---@param startPos table First corner position with x, y, z coordinates
---@param endPos table Opposite corner position with x, y, z coordinates
---@param color table? Border color with r, g, b, a values (0-1)
---@param fillColor table? Fill color with r, g, b, a values (0-1)
---@param lineType number? Line type enum
---@param readOnly boolean? Whether the rectangle is read-only
---@param message string? Optional message
---@return boolean? success Returns true if successful, nil on error
---@usage RectToAll(1001, {x=1000, y=0, z=2000}, {x=2000, y=0, z=3000}, {r=0, g=1, b=0, a=1})
function RectToAll(
    coalitionOrId,
    startOrIdOrStart,
    endOrStartOrEnd,
    colorOrEndOrColor,
    fillColorOrColorOrFill,
    lineTypeOrFillOrLine,
    readOnlyOrLineOrReadOnly,
    messageOrReadOnly
)
    -- Old: (id, startPos, endPos, color, fillColor, lineType, readOnly, message)
    -- New: (coalition, id, startPos, endPos, color, fillColor, lineType, readOnly, message)
    local coalitionArg, idArg, startPos, endPos, color, fillColor, lineType, readOnly, message
    if
        type(startOrIdOrStart) == "table"
        and startOrIdOrStart.x
        and startOrIdOrStart.y
        and startOrIdOrStart.z
    then
        coalitionArg = -1
        idArg = coalitionOrId
        startPos = startOrIdOrStart
        endPos = endOrStartOrEnd
        color = colorOrEndOrColor
        fillColor = fillColorOrColorOrFill
        lineType = lineTypeOrFillOrLine
        readOnly = readOnlyOrLineOrReadOnly
        message = messageOrReadOnly
    else
        coalitionArg = coalitionOrId
        idArg = startOrIdOrStart
        startPos = endOrStartOrEnd
        endPos = colorOrEndOrColor
        color = fillColorOrColorOrFill
        fillColor = lineTypeOrFillOrLine
        lineType = readOnlyOrLineOrReadOnly
        readOnly = messageOrReadOnly
        message = nil
    end

    if not idArg or type(idArg) ~= "number" then
        _HarnessInternal.log.error("RectToAll requires valid unique ID", "Trigger.RectToAll")
        return nil
    end

    if
        not startPos
        or type(startPos) ~= "table"
        or not startPos.x
        or not startPos.y
        or not startPos.z
    then
        _HarnessInternal.log.error(
            "RectToAll requires valid start position with x, y, z",
            "Trigger.RectToAll"
        )
        return nil
    end

    if not endPos or type(endPos) ~= "table" or not endPos.x or not endPos.y or not endPos.z then
        _HarnessInternal.log.error(
            "RectToAll requires valid end position with x, y, z",
            "Trigger.RectToAll"
        )
        return nil
    end

    local colorArr = _toArrayColor(color or { 1, 1, 1, 1 })
    local fillArr = _toArrayColor(fillColor or { 1, 1, 1, 0.25 })
    local success, result = pcall(
        trigger.action.rectToAll,
        coalitionArg,
        idArg,
        startPos,
        endPos,
        colorArr,
        fillArr,
        lineType,
        readOnly,
        message
    )
    if not success then
        _HarnessInternal.log.error(
            "Failed to create rectangle for all: " .. tostring(result),
            "Trigger.RectToAll"
        )
        return nil
    end

    return true
end

--- Draws a quadrilateral on the map visible to all players
---@param markId number Unique ID for the quad
---@param point1 table First point with x, y, z coordinates
---@param point2 table Second point with x, y, z coordinates
---@param point3 table Third point with x, y, z coordinates
---@param point4 table Fourth point with x, y, z coordinates
---@param color table? Border color with r, g, b, a values (0-1)
---@param fillColor table? Fill color with r, g, b, a values (0-1)
---@param lineType number? Line type enum
---@param readOnly boolean? Whether the quad is read-only
---@param message string? Optional message
---@return boolean? success Returns true if successful, nil on error
---@usage QuadToAll(1001, {x=1000, y=0, z=2000}, {x=2000, y=0, z=2000}, {x=2000, y=0, z=3000}, {x=1000, y=0, z=3000})
function QuadToAll(
    coalitionOrId,
    p1OrIdOrP1,
    p2OrP1OrP2,
    p3OrP2OrP3,
    p4OrP3OrP4,
    colorOrP4OrColor,
    fillColorOrColorOrFill,
    lineTypeOrFillOrLine,
    readOnlyOrLineOrReadOnly,
    messageOrReadOnly
)
    -- Old: (id, p1, p2, p3, p4, color, fillColor, lineType, readOnly, message)
    -- New: (coalition, id, p1, p2, p3, p4, color, fillColor, lineType, readOnly, message)
    local coalitionArg, idArg, p1, p2, p3, p4, color, fillColor, lineType, readOnly, message
    if type(p1OrIdOrP1) == "table" and p1OrIdOrP1.x and p1OrIdOrP1.y and p1OrIdOrP1.z then
        coalitionArg = -1
        idArg = coalitionOrId
        p1 = p1OrIdOrP1
        p2 = p2OrP1OrP2
        p3 = p3OrP2OrP3
        p4 = p4OrP3OrP4
        color = colorOrP4OrColor
        fillColor = fillColorOrColorOrFill
        lineType = lineTypeOrFillOrLine
        readOnly = readOnlyOrLineOrReadOnly
        message = messageOrReadOnly
    else
        coalitionArg = coalitionOrId
        idArg = p1OrIdOrP1
        p1 = p2OrP1OrP2
        p2 = p3OrP2OrP3
        p3 = p4OrP3OrP4
        p4 = colorOrP4OrColor
        color = fillColorOrColorOrFill
        fillColor = lineTypeOrFillOrLine
        lineType = readOnlyOrLineOrReadOnly
        readOnly = messageOrReadOnly
        message = nil
    end

    if not idArg or type(idArg) ~= "number" then
        _HarnessInternal.log.error("QuadToAll requires valid unique ID", "Trigger.QuadToAll")
        return nil
    end

    if not p1 or type(p1) ~= "table" or not p1.x or not p1.y or not p1.z then
        _HarnessInternal.log.error(
            "QuadToAll requires valid point1 with x, y, z",
            "Trigger.QuadToAll"
        )
        return nil
    end
    if not p2 or type(p2) ~= "table" or not p2.x or not p2.y or not p2.z then
        _HarnessInternal.log.error(
            "QuadToAll requires valid point2 with x, y, z",
            "Trigger.QuadToAll"
        )
        return nil
    end
    if not p3 or type(p3) ~= "table" or not p3.x or not p3.y or not p3.z then
        _HarnessInternal.log.error(
            "QuadToAll requires valid point3 with x, y, z",
            "Trigger.QuadToAll"
        )
        return nil
    end
    if not p4 or type(p4) ~= "table" or not p4.x or not p4.y or not p4.z then
        _HarnessInternal.log.error(
            "QuadToAll requires valid point4 with x, y, z",
            "Trigger.QuadToAll"
        )
        return nil
    end

    local colorArr = _toArrayColor(color or { 1, 1, 1, 1 })
    local fillArr = _toArrayColor(fillColor or { 1, 1, 1, 0.25 })
    local success, result = pcall(
        trigger.action.quadToAll,
        coalitionArg,
        idArg,
        p1,
        p2,
        p3,
        p4,
        colorArr,
        fillArr,
        lineType,
        readOnly,
        message
    )
    if not success then
        _HarnessInternal.log.error(
            "Failed to create quad for all: " .. tostring(result),
            "Trigger.QuadToAll"
        )
        return nil
    end

    return true
end

--- Draws text on the map visible to all players
---@param markId number Unique ID for the text
---@param text string The text to display
---@param pos table Position with x, y, z coordinates
---@param color table? Text color with r, g, b, a values (0-1)
---@param fillColor table? Background color with r, g, b, a values (0-1)
---@param fontSize number? Font size in points
---@param readOnly boolean? Whether the text is read-only
---@param message string? Optional message
---@return boolean? success Returns true if successful, nil on error
---@usage TextToAll(1001, "Objective", {x=1000, y=0, z=2000}, {r=1, g=1, b=1, a=1}, nil, 14)
function TextToAll(
    coalitionOrId,
    textOrIdOrText,
    posOrTextOrPos,
    colorOrPosOrColor,
    fillColorOrColorOrFill,
    fontSizeOrFillOrFont,
    readOnlyOrFontOrReadOnly,
    messageOrReadOnly
)
    -- Old: (id, text, pos, color, fillColor, fontSize, readOnly, message)
    -- New: (coalition, id, text, pos, color, fillColor, fontSize, readOnly, message)
    local coalitionArg, idArg, text, pos, color, fillColor, fontSize, readOnly, message
    if
        type(textOrIdOrText) == "string"
        and type(posOrTextOrPos) == "table"
        and posOrTextOrPos.x
        and posOrTextOrPos.y
        and posOrTextOrPos.z
    then
        coalitionArg = -1
        idArg = coalitionOrId
        text = textOrIdOrText
        pos = posOrTextOrPos
        color = colorOrPosOrColor
        fillColor = fillColorOrColorOrFill
        fontSize = fontSizeOrFillOrFont
        readOnly = readOnlyOrFontOrReadOnly
        message = messageOrReadOnly
    else
        coalitionArg = coalitionOrId
        idArg = textOrIdOrText
        text = posOrTextOrPos
        pos = colorOrPosOrColor
        color = fillColorOrColorOrFill
        fillColor = fontSizeOrFillOrFont
        fontSize = readOnlyOrFontOrReadOnly
        readOnly = messageOrReadOnly
        message = nil
    end

    if not idArg or type(idArg) ~= "number" then
        _HarnessInternal.log.error("TextToAll requires valid unique ID", "Trigger.TextToAll")
        return nil
    end

    if not text or type(text) ~= "string" then
        _HarnessInternal.log.error("TextToAll requires valid text string", "Trigger.TextToAll")
        return nil
    end

    if not pos or type(pos) ~= "table" or not pos.x or not pos.y or not pos.z then
        _HarnessInternal.log.error(
            "TextToAll requires valid position with x, y, z",
            "Trigger.TextToAll"
        )
        return nil
    end

    color = _normalizeColor(color)
    fillColor = _defaultFill(color, fillColor)
    local colorArr = _toArrayColor(color)
    local fillArr = _toArrayColor(fillColor)
    -- DCS expects (coalition, id, point, color, fillColor, fontSize, readOnly, text)
    local success, result = pcall(
        trigger.action.textToAll,
        coalitionArg,
        idArg,
        pos,
        colorArr,
        fillArr,
        fontSize,
        readOnly,
        text
    )
    if not success then
        _HarnessInternal.log.error(
            "Failed to create text for all: " .. tostring(result),
            "Trigger.TextToAll"
        )
        return nil
    end

    return true
end

--- Draws an arrow on the map visible to all players
---@param markId number Unique ID for the arrow
---@param startPos table Start position with x, y, z coordinates
---@param endPos table End position (arrow points here) with x, y, z coordinates
---@param color table? Arrow color with r, g, b, a values (0-1)
---@param fillColor table? Fill color with r, g, b, a values (0-1)
---@param lineType number? Line type enum
---@param readOnly boolean? Whether the arrow is read-only
---@param message string? Optional message
---@return boolean? success Returns true if successful, nil on error
---@usage ArrowToAll(1001, {x=1000, y=0, z=2000}, {x=2000, y=0, z=3000}, {r=1, g=0, b=0, a=1})
function ArrowToAll(
    coalitionOrId,
    startOrIdOrStart,
    endOrStartOrEnd,
    colorOrEndOrColor,
    fillColorOrColorOrFill,
    lineTypeOrFillOrLine,
    readOnlyOrLineOrReadOnly,
    messageOrReadOnly
)
    -- Old: (id, startPos, endPos, color, fillColor, lineType, readOnly, message)
    -- New: (coalition, id, startPos, endPos, color, fillColor, lineType, readOnly, message)
    local coalitionArg, idArg, startPos, endPos, color, fillColor, lineType, readOnly, message
    if
        type(startOrIdOrStart) == "table"
        and startOrIdOrStart.x
        and startOrIdOrStart.y
        and startOrIdOrStart.z
    then
        coalitionArg = -1
        idArg = coalitionOrId
        startPos = startOrIdOrStart
        endPos = endOrStartOrEnd
        color = colorOrEndOrColor
        fillColor = fillColorOrColorOrFill
        lineType = lineTypeOrFillOrLine
        readOnly = readOnlyOrLineOrReadOnly
        message = messageOrReadOnly
    else
        coalitionArg = coalitionOrId
        idArg = startOrIdOrStart
        startPos = endOrStartOrEnd
        endPos = colorOrEndOrColor
        color = fillColorOrColorOrFill
        fillColor = lineTypeOrFillOrLine
        lineType = readOnlyOrLineOrReadOnly
        readOnly = messageOrReadOnly
        message = nil
    end

    if not idArg or type(idArg) ~= "number" then
        _HarnessInternal.log.error("ArrowToAll requires valid unique ID", "Trigger.ArrowToAll")
        return nil
    end

    if
        not startPos
        or type(startPos) ~= "table"
        or not startPos.x
        or not startPos.y
        or not startPos.z
    then
        _HarnessInternal.log.error(
            "ArrowToAll requires valid start position with x, y, z",
            "Trigger.ArrowToAll"
        )
        return nil
    end

    if not endPos or type(endPos) ~= "table" or not endPos.x or not endPos.y or not endPos.z then
        _HarnessInternal.log.error(
            "ArrowToAll requires valid end position with x, y, z",
            "Trigger.ArrowToAll"
        )
        return nil
    end

    local colorArr = _toArrayColor(color or { 1, 1, 1, 1 })
    local fillArr = _toArrayColor(fillColor or { 1, 1, 1, 0.25 })
    local success, result = pcall(
        trigger.action.arrowToAll,
        coalitionArg,
        idArg,
        startPos,
        endPos,
        colorArr,
        fillArr,
        lineType,
        readOnly,
        message
    )
    if not success then
        _HarnessInternal.log.error(
            "Failed to create arrow for all: " .. tostring(result),
            "Trigger.ArrowToAll"
        )
        return nil
    end

    return true
end

--- Sets an AI task for a group
---@param group table The group object
---@param actionIndex number Group action index (as defined in mission editor)
---@return boolean? success Returns true if successful, nil on error
---@usage SetAITask(group, 1)
function SetAITask(group, actionIndex)
    if not group then
        _HarnessInternal.log.error("SetAITask requires valid group", "Trigger.SetAITask")
        return nil
    end

    if not actionIndex or type(actionIndex) ~= "number" or actionIndex < 1 then
        _HarnessInternal.log.error("SetAITask requires valid action index", "Trigger.SetAITask")
        return nil
    end

    local success, result = pcall(trigger.action.setAITask, group, actionIndex)
    if not success then
        _HarnessInternal.log.error(
            "Failed to set AI task: " .. tostring(result),
            "Trigger.SetAITask"
        )
        return nil
    end

    return true
end

--- Pushes an AI task to a group's task queue
---@param group table The group object
---@param actionIndex number Group action index (as defined in mission editor)
---@return boolean? success Returns true if successful, nil on error
---@usage PushAITask(group, 1)
function PushAITask(group, actionIndex)
    if not group then
        _HarnessInternal.log.error("PushAITask requires valid group", "Trigger.PushAITask")
        return nil
    end

    if not actionIndex or type(actionIndex) ~= "number" or actionIndex < 1 then
        _HarnessInternal.log.error("PushAITask requires valid action index", "Trigger.PushAITask")
        return nil
    end

    local success, result = pcall(trigger.action.pushAITask, group, actionIndex)
    if not success then
        _HarnessInternal.log.error(
            "Failed to push AI task: " .. tostring(result),
            "Trigger.PushAITask"
        )
        return nil
    end

    return true
end

--- Activates a group using trigger action
---@param group table The group object to activate
---@return boolean? success Returns true if successful, nil on error
---@usage TriggerActivateGroup(group)
function TriggerActivateGroup(group)
    if not group then
        _HarnessInternal.log.error(
            "TriggerActivateGroup requires valid group",
            "Trigger.TriggerActivateGroup"
        )
        return nil
    end

    local success, result = pcall(trigger.action.activateGroup, group)
    if not success then
        _HarnessInternal.log.error(
            "Failed to activate group: " .. tostring(result),
            "Trigger.TriggerActivateGroup"
        )
        return nil
    end

    return true
end

--- Deactivates a group using trigger action
---@param group table The group object to deactivate
---@return boolean? success Returns true if successful, nil on error
---@usage TriggerDeactivateGroup(group)
function TriggerDeactivateGroup(group)
    if not group then
        _HarnessInternal.log.error(
            "TriggerDeactivateGroup requires valid group",
            "Trigger.TriggerDeactivateGroup"
        )
        return nil
    end

    local success, result = pcall(trigger.action.deactivateGroup, group)
    if not success then
        _HarnessInternal.log.error(
            "Failed to deactivate group: " .. tostring(result),
            "Trigger.TriggerDeactivateGroup"
        )
        return nil
    end

    return true
end

--- Enables AI for a group
---@param group table The group object
---@return boolean? success Returns true if successful, nil on error
---@usage SetGroupAIOn(group)
function SetGroupAIOn(group)
    if not group then
        _HarnessInternal.log.error("SetGroupAIOn requires valid group", "Trigger.SetGroupAIOn")
        return nil
    end

    local success, result = pcall(trigger.action.setGroupAIOn, group)
    if not success then
        _HarnessInternal.log.error(
            "Failed to set group AI on: " .. tostring(result),
            "Trigger.SetGroupAIOn"
        )
        return nil
    end

    return true
end

--- Disables AI for a group
---@param group table The group object
---@return boolean? success Returns true if successful, nil on error
---@usage SetGroupAIOff(group)
function SetGroupAIOff(group)
    if not group then
        _HarnessInternal.log.error("SetGroupAIOff requires valid group", "Trigger.SetGroupAIOff")
        return nil
    end

    local success, result = pcall(trigger.action.setGroupAIOff, group)
    if not success then
        _HarnessInternal.log.error(
            "Failed to set group AI off: " .. tostring(result),
            "Trigger.SetGroupAIOff"
        )
        return nil
    end

    return true
end

--- Stops a group from moving
---@param group table The group object
---@return boolean? success Returns true if successful, nil on error
---@usage GroupStopMoving(group)
function GroupStopMoving(group)
    if not group then
        _HarnessInternal.log.error(
            "GroupStopMoving requires valid group",
            "Trigger.GroupStopMoving"
        )
        return nil
    end

    local success, result = pcall(trigger.action.groupStopMoving, group)
    if not success then
        _HarnessInternal.log.error(
            "Failed to stop group moving: " .. tostring(result),
            "Trigger.GroupStopMoving"
        )
        return nil
    end

    return true
end

--- Resumes movement for a stopped group
---@param group table The group object
---@return boolean? success Returns true if successful, nil on error
---@usage GroupContinueMoving(group)
function GroupContinueMoving(group)
    if not group then
        _HarnessInternal.log.error(
            "GroupContinueMoving requires valid group",
            "Trigger.GroupContinueMoving"
        )
        return nil
    end

    local success, result = pcall(trigger.action.groupContinueMoving, group)
    if not success then
        _HarnessInternal.log.error(
            "Failed to continue group moving: " .. tostring(result),
            "Trigger.GroupContinueMoving"
        )
        return nil
    end

    return true
end

--- Creates a shape on the F10 map visible to all players
---@param shapeId number Shape type ID (1=Line, 2=Circle, 3=Rect, 4=Arrow, 5=Text, 6=Quad, 7=Freeform)
---@param coalition number Coalition ID (-1=All, 0=Neutral, 1=Red, 2=Blue)
---@param id number Unique ID for the shape (shared with mark panels)
---@param point1 table First point with x, y, z coordinates
---@param ... any Additional parameters depending on shape type
---@return boolean? success Returns true if successful, nil on error
---@usage MarkupToAll(2, -1, 1001, {x=1000, y=0, z=2000}, 500, {1, 0, 0, 1}, {1, 0, 0, 0.3}, 1, false, "Circle Zone")
---@usage MarkupToAll(7, -1, 1002, point1, point2, point3, point4, point5, point6, {0, .6, .6, 1}, {0.8, 0.8, 0.8, .3}, 4)
function MarkupToAll(shapeId, coalition, id, point1, ...)
    -- Validate shapeId
    if not shapeId or type(shapeId) ~= "number" or shapeId < 1 or shapeId > 7 then
        _HarnessInternal.log.error(
            "MarkupToAll requires valid shape ID (1-7)",
            "Trigger.MarkupToAll"
        )
        return nil
    end

    -- Validate coalition
    if not coalition or type(coalition) ~= "number" then
        _HarnessInternal.log.error("MarkupToAll requires valid coalition ID", "Trigger.MarkupToAll")
        return nil
    end

    -- Validate id
    if not id or type(id) ~= "number" then
        _HarnessInternal.log.error("MarkupToAll requires valid unique ID", "Trigger.MarkupToAll")
        return nil
    end

    -- Validate point1
    if not point1 or type(point1) ~= "table" or not point1.x or not point1.y or not point1.z then
        _HarnessInternal.log.error(
            "MarkupToAll requires valid first point with x, y, z",
            "Trigger.MarkupToAll"
        )
        return nil
    end

    local varargs = { ... }
    local params = { shapeId, coalition, id, point1 }

    -- Add all variadic arguments to params
    for i = 1, #varargs do
        table.insert(params, varargs[i])
    end

    -- Call the DCS function with unpacked parameters
    local success, result = pcall(function()
        return trigger.action.markupToAll(unpack(params))
    end)

    if not success then
        _HarnessInternal.log.error(
            "Failed to create markup shape: " .. tostring(result),
            "Trigger.MarkupToAll"
        )
        return nil
    end

    return true
end
-- ==== END: src/trigger.lua ====

-- ==== BEGIN: src/unit.lua ====
--[[
==================================================================================================
    UNIT MODULE
    Validated wrapper functions for DCS Unit API
==================================================================================================
]]

-- Ensure minimal cache structure in case environment hasn't initialized it yet
_HarnessInternal = _HarnessInternal or {}
_HarnessInternal.cache = _HarnessInternal.cache or {}
_HarnessInternal.cache.units = _HarnessInternal.cache.units or {}
_HarnessInternal.cache.groups = _HarnessInternal.cache.groups or {}
_HarnessInternal.cache.controllers = _HarnessInternal.cache.controllers or {}
_HarnessInternal.cache.airbases = _HarnessInternal.cache.airbases or {}
_HarnessInternal.cache.stats = _HarnessInternal.cache.stats
    or { hits = 0, misses = 0, evictions = 0 }

--- Get unit by name with validation and error handling
---@param unitName string The name of the unit to retrieve
---@return table? unit The unit object if found, nil otherwise
---@usage local unit = GetUnit("Player")
function GetUnit(unitName)
    if not unitName or type(unitName) ~= "string" then
        _HarnessInternal.log.error("GetUnit requires string unit name", "GetUnit")
        return nil
    end

    -- Ensure cache tables are available
    if not _HarnessInternal.cache then
        _HarnessInternal.cache = {
            units = {},
            groups = {},
            controllers = {},
            airbases = {},
            stats = { hits = 0, misses = 0, evictions = 0 },
        }
    else
        _HarnessInternal.cache.units = _HarnessInternal.cache.units or {}
        _HarnessInternal.cache.groups = _HarnessInternal.cache.groups or {}
        _HarnessInternal.cache.controllers = _HarnessInternal.cache.controllers or {}
        _HarnessInternal.cache.airbases = _HarnessInternal.cache.airbases or {}
        _HarnessInternal.cache.stats = _HarnessInternal.cache.stats
            or { hits = 0, misses = 0, evictions = 0 }
    end

    -- Check cache first
    local cached = _HarnessInternal.cache.units[unitName]
    if cached then
        -- Verify unit still exists
        local success, exists = pcall(function()
            return cached:isExist()
        end)
        if success and exists then
            _HarnessInternal.cache.stats.hits = _HarnessInternal.cache.stats.hits + 1
            return cached
        else
            -- Remove from cache if no longer exists
            RemoveUnitFromCache(unitName)
        end
    end

    -- Get from DCS API
    local success, unit = pcall(Unit.getByName, unitName)
    if not success then
        _HarnessInternal.log.error("Failed to get unit: " .. tostring(unit), "GetUnit")
        return nil
    end

    if not unit then
        _HarnessInternal.log.debug("Unit not found: " .. unitName, "GetUnit")
        return nil
    end

    -- Add to cache
    _HarnessInternal.cache.units[unitName] = unit
    _HarnessInternal.cache.stats.misses = _HarnessInternal.cache.stats.misses + 1

    return unit
end

--- Check if unit exists and is active
---@param unitName string The name of the unit to check
---@return boolean exists True if unit exists and is active, false otherwise
---@usage if UnitExists("Player") then ... end
function UnitExists(unitName)
    local unit = GetUnit(unitName)
    if not unit then
        return false
    end

    local success, exists = pcall(unit.isExist, unit)
    if not success then
        _HarnessInternal.log.error(
            "Failed to check unit existence: " .. tostring(exists),
            "UnitExists"
        )
        return false
    end

    return exists
end

--- Get unit position
---@param unitOrName string|table The name of the unit or unit object
---@return table? position The position {x, y, z} if found, nil otherwise
---@usage local pos = GetUnitPosition("Player") or GetUnitPosition(unitObject)
function GetUnitPosition(unitOrName)
    local unit

    -- Handle both unit objects and unit names
    if type(unitOrName) == "string" then
        unit = GetUnit(unitOrName)
        if not unit then
            return nil
        end
    elseif type(unitOrName) == "table" and unitOrName.getPosition then
        unit = unitOrName
    else
        _HarnessInternal.log.error(
            "GetUnitPosition requires unit name or unit object",
            "GetUnitPosition"
        )
        return nil
    end

    local success, position = pcall(unit.getPosition, unit)
    if not success or not position or not position.p then
        _HarnessInternal.log.error(
            "Failed to get unit position: " .. tostring(position),
            "GetUnitPosition"
        )
        return nil
    end

    return position.p
end

--- Get unit heading in degrees
---@param unitName string The name of the unit
---@return number? heading The heading in degrees (0-360) if found, nil otherwise
---@usage local heading = GetUnitHeading("Player")
function GetUnitHeading(unitName)
    local unit = GetUnit(unitName)
    if not unit then
        return nil
    end

    local success, position = pcall(unit.getPosition, unit)
    if not success or not position then
        _HarnessInternal.log.error(
            "Failed to get unit position for heading: " .. tostring(position),
            "GetUnitHeading"
        )
        return nil
    end

    -- Extract heading from orientation matrix
    -- position.x is the forward vector, so heading is atan2(forward.z, forward.x)
    local heading = math.atan2(position.x.z, position.x.x)
    heading = math.deg(heading)

    -- Normalize to 0-360
    if heading < 0 then
        heading = heading + 360
    end

    return heading
end

--- Get unit velocity
---@param unitName string The name of the unit
---@return table? velocity The velocity vector {x, y, z} if found, nil otherwise
---@usage local vel = GetUnitVelocity("Player")
function GetUnitVelocity(unitName)
    local unit = GetUnit(unitName)
    if not unit then
        return nil
    end

    local success, velocity = pcall(unit.getVelocity, unit)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get unit velocity: " .. tostring(velocity),
            "GetUnitVelocity"
        )
        return nil
    end

    return velocity
end

-- =========================================
-- Convenience Getters (Speed / Altitude)
-- =========================================

--- Get unit speed magnitude in meters per second
---@param unitName string
---@return number? speedMps
---@usage local v = GetUnitSpeedMps("Player")
function GetUnitSpeedMps(unitName)
    local v = GetUnitVelocity(unitName)
    if not v or type(v.x) ~= "number" or type(v.y) ~= "number" or type(v.z) ~= "number" then
        return nil
    end
    return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

--- Get unit speed magnitude in knots
---@param unitName string
---@return number? speedKts
---@usage local kts = GetUnitSpeedKnots("Player")
function GetUnitSpeedKnots(unitName)
    local mps = GetUnitSpeedMps(unitName)
    if type(mps) ~= "number" then
        return nil
    end
    return MpsToKnots(mps)
end

--- Get unit vertical speed in feet per second
---@param unitName string
---@return number? feetPerSecond
---@usage local vs = GetUnitVerticalSpeedFeet("Player")
function GetUnitVerticalSpeedFeet(unitName)
    local v = GetUnitVelocity(unitName)
    if not v or type(v.y) ~= "number" then
        return nil
    end
    return MetersToFeet(v.y)
end

--- Get unit altitude MSL in feet
---@param unitName string
---@return number? feetMSL
---@usage local alt = GetUnitAltitudeMSLFeet("Player")
function GetUnitAltitudeMSLFeet(unitName)
    local pos = GetUnitPosition(unitName)
    if not pos or type(pos.y) ~= "number" then
        return nil
    end
    return MetersToFeet(pos.y)
end

--- Get unit altitude AGL in feet
---@param unitName string
---@return number? feetAGL
---@usage local agl = GetUnitAltitudeAGLFeet("Player")
function GetUnitAltitudeAGLFeet(unitName)
    local pos = GetUnitPosition(unitName)
    if not pos then
        return nil
    end
    local aglMeters = GetAGL(pos)
    if type(aglMeters) ~= "number" then
        return nil
    end
    return MetersToFeet(aglMeters)
end

--- Get unit type name
---@param unitName string The name of the unit
---@return string? typeName The unit type name if found, nil otherwise
---@usage local type = GetUnitType("Player")
function GetUnitType(unitName)
    local unit = GetUnit(unitName)
    if not unit then
        return nil
    end

    local success, typeName = pcall(unit.getTypeName, unit)
    if not success then
        _HarnessInternal.log.error("Failed to get unit type: " .. tostring(typeName), "GetUnitType")
        return nil
    end

    return typeName
end

--- Get unit coalition
---@param unitOrName string|table The name of the unit or unit object
---@return number coalition The coalition ID (0 if unit not found or error)
---@usage local coalition = GetUnitCoalition("Player") or GetUnitCoalition(unitObject)
function GetUnitCoalition(unitOrName)
    local unit

    -- Handle both unit objects and unit names
    if type(unitOrName) == "string" then
        unit = GetUnit(unitOrName)
        if not unit then
            return 0 -- Return 0 instead of nil for consistency
        end
    elseif type(unitOrName) == "table" and unitOrName.getCoalition then
        unit = unitOrName
    else
        _HarnessInternal.log.error(
            "GetUnitCoalition requires unit name or unit object",
            "GetUnitCoalition"
        )
        return 0
    end

    local success, coalition = pcall(unit.getCoalition, unit)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get unit coalition: " .. tostring(coalition),
            "GetUnitCoalition"
        )
        return 0
    end

    return coalition or 0
end

--- Get unit country
---@param unitName string The name of the unit
---@return number? country The country ID if found, nil otherwise
---@usage local country = GetUnitCountry("Player")
function GetUnitCountry(unitName)
    local unit = GetUnit(unitName)
    if not unit then
        return nil
    end

    local success, country = pcall(unit.getCountry, unit)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get unit country: " .. tostring(country),
            "GetUnitCountry"
        )
        return nil
    end

    return country
end

--- Get unit group
---@param unitName string The name of the unit
---@return table? group The group object if found, nil otherwise
---@usage local group = GetUnitGroup("Player")
function GetUnitGroup(unitName)
    local unit = GetUnit(unitName)
    if not unit then
        return nil
    end

    local success, group = pcall(unit.getGroup, unit)
    if not success then
        _HarnessInternal.log.error("Failed to get unit group: " .. tostring(group), "GetUnitGroup")
        return nil
    end

    return group
end

--- Get unit player name (if player controlled)
---@param unitName string The name of the unit
---@return string? playerName The player name if unit is player-controlled, nil otherwise
---@usage local playerName = GetUnitPlayerName("Player")
function GetUnitPlayerName(unitName)
    local unit = GetUnit(unitName)
    if not unit then
        return nil
    end

    local success, playerName = pcall(unit.getPlayerName, unit)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get unit player name: " .. tostring(playerName),
            "GetUnitPlayerName"
        )
        return nil
    end

    return playerName
end

--- Get unit life/health
---@param unitName string The name of the unit
---@return number? life The current life/health if found, nil otherwise
---@usage local life = GetUnitLife("Player")
function GetUnitLife(unitName)
    local unit = GetUnit(unitName)
    if not unit then
        return nil
    end

    local success, life = pcall(unit.getLife, unit)
    if not success then
        _HarnessInternal.log.error("Failed to get unit life: " .. tostring(life), "GetUnitLife")
        return nil
    end

    return life
end

--- Get unit maximum life/health
---@param unitName string The name of the unit
---@return number? maxLife The maximum life/health if found, nil otherwise
---@usage local maxLife = GetUnitLife0("Player")
function GetUnitLife0(unitName)
    local unit = GetUnit(unitName)
    if not unit then
        return nil
    end

    local success, life0 = pcall(unit.getLife0, unit)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get unit max life: " .. tostring(life0),
            "GetUnitLife0"
        )
        return nil
    end

    return life0
end

--- Get unit fuel (0.0 to 1.0+)
---@param unitName string The name of the unit
---@return number? fuel The fuel level (0.0 to 1.0+) if found, nil otherwise
---@usage local fuel = GetUnitFuel("Player")
function GetUnitFuel(unitName)
    local unit = GetUnit(unitName)
    if not unit then
        return nil
    end

    local success, fuel = pcall(unit.getFuel, unit)
    if not success then
        _HarnessInternal.log.error("Failed to get unit fuel: " .. tostring(fuel), "GetUnitFuel")
        return nil
    end

    return fuel
end

--- Check if unit is in air
---@param unitName string The name of the unit
---@return boolean inAir True if unit is in air, false otherwise
---@usage if IsUnitInAir("Player") then ... end
function IsUnitInAir(unitName)
    local unit = GetUnit(unitName)
    if not unit then
        return false
    end

    local success, inAir = pcall(unit.inAir, unit)
    if not success then
        _HarnessInternal.log.error(
            "Failed to check if unit in air: " .. tostring(inAir),
            "IsUnitInAir"
        )
        return false
    end

    return inAir
end

--- Get unit ammo
---@param unitName string The name of the unit
---@return table? ammo The ammo table if found, nil otherwise
---@usage local ammo = GetUnitAmmo("Player")
function GetUnitAmmo(unitName)
    local unit = GetUnit(unitName)
    if not unit then
        return nil
    end

    local success, ammo = pcall(unit.getAmmo, unit)
    if not success then
        _HarnessInternal.log.error("Failed to get unit ammo: " .. tostring(ammo), "GetUnitAmmo")
        return nil
    end

    return ammo
end

-- Advanced Unit Functions

--- Get unit ID
---@param unit table Unit object
---@return number? id Unit ID or nil on error
---@usage local id = GetUnitID(unit)
function GetUnitID(unit)
    if not unit then
        _HarnessInternal.log.error("GetUnitID requires unit", "GetUnitID")
        return nil
    end

    local success, id = pcall(function()
        return unit:getID()
    end)
    if not success then
        _HarnessInternal.log.error("Failed to get unit ID: " .. tostring(id), "GetUnitID")
        return nil
    end

    return id
end

--- Get unit number within group
---@param unit table Unit object
---@return number? number Unit number or nil on error
---@usage local num = GetUnitNumber(unit)
function GetUnitNumber(unit)
    if not unit then
        _HarnessInternal.log.error("GetUnitNumber requires unit", "GetUnitNumber")
        return nil
    end

    local success, number = pcall(function()
        return unit:getNumber()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get unit number: " .. tostring(number),
            "GetUnitNumber"
        )
        return nil
    end

    return number
end

--- Get unit callsign
---@param unit table Unit object
---@return string? callsign Unit callsign or nil on error
---@usage local callsign = GetUnitCallsign(unit)
function GetUnitCallsign(unit)
    if not unit then
        _HarnessInternal.log.error("GetUnitCallsign requires unit", "GetUnitCallsign")
        return nil
    end

    local success, callsign = pcall(function()
        return unit:getCallsign()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get unit callsign: " .. tostring(callsign),
            "GetUnitCallsign"
        )
        return nil
    end

    return callsign
end

--- Get unit object ID
---@param unit table Unit object
---@return number? objectId Object ID or nil on error
---@usage local objId = GetUnitObjectID(unit)
function GetUnitObjectID(unit)
    if not unit then
        _HarnessInternal.log.error("GetUnitObjectID requires unit", "GetUnitObjectID")
        return nil
    end

    local success, objectId = pcall(function()
        return unit:getObjectID()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get unit object ID: " .. tostring(objectId),
            "GetUnitObjectID"
        )
        return nil
    end

    return objectId
end

--- Get unit category extended
---@param unit table Unit object
---@return number? category Extended category or nil on error
---@usage local cat = GetUnitCategoryEx(unit)
function GetUnitCategoryEx(unit)
    if not unit then
        _HarnessInternal.log.error("GetUnitCategoryEx requires unit", "GetUnitCategoryEx")
        return nil
    end

    local success, category = pcall(function()
        return unit:getCategoryEx()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get unit category ex: " .. tostring(category),
            "GetUnitCategoryEx"
        )
        return nil
    end

    return category
end

--- Get unit description
---@param unit table Unit object
---@return table? desc Unit description table or nil on error
---@usage local desc = GetUnitDesc(unit)
function GetUnitDesc(unit)
    if not unit then
        _HarnessInternal.log.error("GetUnitDesc requires unit", "GetUnitDesc")
        return nil
    end

    local success, desc = pcall(function()
        return unit:getDesc()
    end)
    if not success then
        _HarnessInternal.log.error("Failed to get unit desc: " .. tostring(desc), "GetUnitDesc")
        return nil
    end

    return desc
end

--- Get unit forces name
---@param unit table Unit object
---@return string? forcesName Forces name or nil on error
---@usage local forces = GetUnitForcesName(unit)
function GetUnitForcesName(unit)
    if not unit then
        _HarnessInternal.log.error("GetUnitForcesName requires unit", "GetUnitForcesName")
        return nil
    end

    local success, forcesName = pcall(function()
        return unit:getForcesName()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get unit forces name: " .. tostring(forcesName),
            "GetUnitForcesName"
        )
        return nil
    end

    return forcesName
end

--- Check if unit is active
---@param unit table Unit object
---@return boolean active True if unit is active
---@usage if IsUnitActive(unit) then ... end
function IsUnitActive(unit)
    if not unit then
        _HarnessInternal.log.error("IsUnitActive requires unit", "IsUnitActive")
        return false
    end

    local success, active = pcall(function()
        return unit:isActive()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to check unit active: " .. tostring(active),
            "IsUnitActive"
        )
        return false
    end

    return active == true
end

--- Get unit controller
---@param unit table Unit object
---@return table? controller Unit controller or nil on error
---@usage local controller = GetUnitController(unit)
function GetUnitController(unit)
    if not unit then
        _HarnessInternal.log.error("GetUnitController requires unit", "GetUnitController")
        return nil
    end

    -- Try to get unit name for cache key
    local unitName = nil
    local ok_get_name, name = pcall(function()
        return unit:getName()
    end)
    if ok_get_name and name then
        unitName = name

        -- Check cache first
        local cacheKey = "unit:" .. unitName
        local cached = _HarnessInternal.cache.getController(cacheKey)
        if cached then
            return cached
        end
    end

    -- Get controller from DCS API
    local ok_get_controller, controller = pcall(function()
        return unit:getController()
    end)
    if not ok_get_controller then
        _HarnessInternal.log.error(
            "Failed to get unit controller: " .. tostring(controller),
            "GetUnitController"
        )
        return nil
    end

    -- Add to cache if we have a name, with optional metadata
    if controller and unitName then
        local info = { unitNames = { unitName } }

        -- Attempt to capture owning group name
        local ok_get_group_name, grpName = pcall(function()
            local grp = unit:getGroup()
            return grp and grp.getName and grp:getName() or nil
        end)
        if ok_get_group_name and grpName then
            info.groupName = grpName
        end

        -- For air units, try to include all unit names from the group
        local ok_get_category, cat = pcall(function()
            return unit.getCategory and unit:getCategory() or nil
        end)
        -- Infer domain from unit category
        if ok_get_category then
            if cat == Unit.Category.AIRPLANE or cat == Unit.Category.HELICOPTER then
                info.domain = "Air"
            elseif cat == Unit.Category.GROUND_UNIT then
                info.domain = "Ground"
            elseif cat == Unit.Category.SHIP then
                info.domain = "Naval"
            end
        end
        if
            ok_get_category
            and (cat == Unit.Category.AIRPLANE or cat == Unit.Category.HELICOPTER)
            and info.groupName
        then
            local ok_get_units, names = pcall(function()
                local grp = unit:getGroup()
                if grp and grp.getUnits then
                    local list = grp:getUnits()
                    if type(list) == "table" then
                        local acc = {}
                        for i = 1, #list do
                            local u = list[i]
                            local ok_get_unit_name, nm = pcall(function()
                                return u:getName()
                            end)
                            if ok_get_unit_name and nm then
                                acc[#acc + 1] = nm
                            end
                        end
                        return acc
                    end
                end
                return nil
            end)
            if ok_get_units and names and #names > 0 then
                info.unitNames = names
            end
        end

        _HarnessInternal.cache.addController("unit:" .. unitName, controller, info)
        -- Fallback: ensure metadata is stored even if addController ignores info
        local entry = _HarnessInternal.cache.controllers["unit:" .. unitName]
        if entry then
            if info.groupName and entry.groupName == nil then
                entry.groupName = info.groupName
            end
            if info.unitNames and entry.unitNames == nil then
                entry.unitNames = info.unitNames
            end
            if info.domain and entry.domain == nil then
                entry.domain = info.domain
            end
        end
    end

    return controller
end

-- Sensor Functions

--- Get unit sensors
---@param unit table Unit object
---@return table? sensors Sensors table or nil on error
---@usage local sensors = GetUnitSensors(unit)
function GetUnitSensors(unit)
    if not unit then
        _HarnessInternal.log.error("GetUnitSensors requires unit", "GetUnitSensors")
        return nil
    end

    local success, sensors = pcall(function()
        return unit:getSensors()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get unit sensors: " .. tostring(sensors),
            "GetUnitSensors"
        )
        return nil
    end

    return sensors
end

--- Check if unit has sensors
---@param unit table Unit object
---@param sensorType number? Sensor type to check
---@param subCategory number? Sensor subcategory
---@return boolean hasSensors True if unit has specified sensors
---@usage if UnitHasSensors(unit, Sensor.RADAR) then ... end
function UnitHasSensors(unit, sensorType, subCategory)
    if not unit then
        _HarnessInternal.log.error("UnitHasSensors requires unit", "UnitHasSensors")
        return false
    end

    local success, hasSensors = pcall(function()
        return unit:hasSensors(sensorType, subCategory)
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to check unit sensors: " .. tostring(hasSensors),
            "UnitHasSensors"
        )
        return false
    end

    return hasSensors == true
end

--- Get unit radar
---@param unit table Unit object
---@return boolean active True if radar is active
---@return table? target Tracked target or nil
---@usage local active, target = GetUnitRadar(unit)
function GetUnitRadar(unit)
    if not unit then
        _HarnessInternal.log.error("GetUnitRadar requires unit", "GetUnitRadar")
        return false, nil
    end

    local success, active, target = pcall(function()
        return unit:getRadar()
    end)
    if not success then
        _HarnessInternal.log.error("Failed to get unit radar: " .. tostring(active), "GetUnitRadar")
        return false, nil
    end

    return active, target
end

--- Enable/disable unit emissions
---@param unit table Unit object
---@param enabled boolean True to enable emissions
---@return boolean success True if emissions were set
---@usage EnableUnitEmissions(unit, false) -- Go dark
function EnableUnitEmissions(unit, enabled)
    if not unit then
        _HarnessInternal.log.error("EnableUnitEmissions requires unit", "EnableUnitEmissions")
        return false
    end

    if type(enabled) ~= "boolean" then
        _HarnessInternal.log.error(
            "EnableUnitEmissions requires boolean enabled",
            "EnableUnitEmissions"
        )
        return false
    end

    local success, result = pcall(function()
        unit:enableEmission(enabled)
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to set unit emissions: " .. tostring(result),
            "EnableUnitEmissions"
        )
        return false
    end

    _HarnessInternal.log.info("Set unit emissions: " .. tostring(enabled), "EnableUnitEmissions")
    return true
end

-- Cargo Functions

--- Get nearest cargo objects
---@param unit table Unit object
---@return table cargos Array of nearby cargo objects
---@usage local cargos = GetUnitNearestCargos(unit)
function GetUnitNearestCargos(unit)
    if not unit then
        _HarnessInternal.log.error("GetUnitNearestCargos requires unit", "GetUnitNearestCargos")
        return {}
    end

    local success, cargos = pcall(function()
        return unit:getNearestCargos()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get nearest cargos: " .. tostring(cargos),
            "GetUnitNearestCargos"
        )
        return {}
    end

    return cargos or {}
end

--- Get cargo objects on board
---@param unit table Unit object
---@return table cargos Array of cargo objects on board
---@usage local cargos = GetUnitCargosOnBoard(unit)
function GetUnitCargosOnBoard(unit)
    if not unit then
        _HarnessInternal.log.error("GetUnitCargosOnBoard requires unit", "GetUnitCargosOnBoard")
        return {}
    end

    local success, cargos = pcall(function()
        return unit:getCargosOnBoard()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get cargos on board: " .. tostring(cargos),
            "GetUnitCargosOnBoard"
        )
        return {}
    end

    return cargos or {}
end

--- Get unit descent capacity
---@param unit table Unit object
---@return number? capacity Infantry capacity or nil on error
---@usage local capacity = GetUnitDescentCapacity(unit)
function GetUnitDescentCapacity(unit)
    if not unit then
        _HarnessInternal.log.error("GetUnitDescentCapacity requires unit", "GetUnitDescentCapacity")
        return nil
    end

    local success, capacity = pcall(function()
        return unit:getDescentCapacity()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get descent capacity: " .. tostring(capacity),
            "GetUnitDescentCapacity"
        )
        return nil
    end

    return capacity
end

--- Get troops on board
---@param unit table Unit object
---@return table? troops Troops info or nil on error
---@usage local troops = GetUnitDescentOnBoard(unit)
function GetUnitDescentOnBoard(unit)
    if not unit then
        _HarnessInternal.log.error("GetUnitDescentOnBoard requires unit", "GetUnitDescentOnBoard")
        return nil
    end

    local success, troops = pcall(function()
        return unit:getDescentOnBoard()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get descent on board: " .. tostring(troops),
            "GetUnitDescentOnBoard"
        )
        return nil
    end

    return troops
end

--- Load cargo/troops on board
---@param unit table Unit object
---@param cargo table Cargo or troops to load
---@return boolean success True if loaded
---@usage LoadUnitCargo(transportUnit, cargoObject)
function LoadUnitCargo(unit, cargo)
    if not unit then
        _HarnessInternal.log.error("LoadUnitCargo requires unit", "LoadUnitCargo")
        return false
    end

    if not cargo then
        _HarnessInternal.log.error("LoadUnitCargo requires cargo", "LoadUnitCargo")
        return false
    end

    local success, result = pcall(function()
        unit:LoadOnBoard(cargo)
    end)
    if not success then
        _HarnessInternal.log.error("Failed to load cargo: " .. tostring(result), "LoadUnitCargo")
        return false
    end

    _HarnessInternal.log.info("Loaded cargo on unit", "LoadUnitCargo")
    return true
end

--- Unload cargo
---@param unit table Unit object
---@param cargo table? Specific cargo to unload or nil for all
---@return boolean success True if unloaded
---@usage UnloadUnitCargo(transportUnit)
function UnloadUnitCargo(unit, cargo)
    if not unit then
        _HarnessInternal.log.error("UnloadUnitCargo requires unit", "UnloadUnitCargo")
        return false
    end

    local success, result = pcall(function()
        unit:UnloadCargo(cargo)
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to unload cargo: " .. tostring(result),
            "UnloadUnitCargo"
        )
        return false
    end

    _HarnessInternal.log.info("Unloaded cargo from unit", "UnloadUnitCargo")
    return true
end

--- Open unit ramp
---@param unit table Unit object
---@return boolean success True if ramp opened
---@usage OpenUnitRamp(transportUnit)
function OpenUnitRamp(unit)
    if not unit then
        _HarnessInternal.log.error("OpenUnitRamp requires unit", "OpenUnitRamp")
        return false
    end

    local success, result = pcall(function()
        unit:openRamp()
    end)
    if not success then
        _HarnessInternal.log.error("Failed to open ramp: " .. tostring(result), "OpenUnitRamp")
        return false
    end

    _HarnessInternal.log.info("Opened unit ramp", "OpenUnitRamp")
    return true
end

--- Check if ramp is open
---@param unit table Unit object
---@return boolean? isOpen True if ramp is open, nil on error
---@usage if CheckUnitRampOpen(unit) then ... end
function CheckUnitRampOpen(unit)
    if not unit then
        _HarnessInternal.log.error("CheckUnitRampOpen requires unit", "CheckUnitRampOpen")
        return nil
    end

    local success, isOpen = pcall(function()
        return unit:checkOpenRamp()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to check ramp: " .. tostring(isOpen),
            "CheckUnitRampOpen"
        )
        return nil
    end

    return isOpen
end

--- Start disembarking troops
---@param unit table Unit object
---@return boolean success True if disembarking started
---@usage DisembarkUnit(transportUnit)
function DisembarkUnit(unit)
    if not unit then
        _HarnessInternal.log.error("DisembarkUnit requires unit", "DisembarkUnit")
        return false
    end

    local success, result = pcall(function()
        unit:disembarking()
    end)
    if not success then
        _HarnessInternal.log.error("Failed to disembark: " .. tostring(result), "DisembarkUnit")
        return false
    end

    _HarnessInternal.log.info("Started disembarking", "DisembarkUnit")
    return true
end

--- Mark disembarking task
---@param unit table Unit object
---@return boolean success True if marked
---@usage MarkUnitDisembarkingTask(transportUnit)
function MarkUnitDisembarkingTask(unit)
    if not unit then
        _HarnessInternal.log.error(
            "MarkUnitDisembarkingTask requires unit",
            "MarkUnitDisembarkingTask"
        )
        return false
    end

    local success, result = pcall(function()
        unit:markDisembarkingTask()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to mark disembarking: " .. tostring(result),
            "MarkUnitDisembarkingTask"
        )
        return false
    end

    return true
end

--- Check if unit is embarking
---@param unit table Unit object
---@return boolean? embarking True if embarking, nil on error
---@usage if IsUnitEmbarking(unit) then ... end
function IsUnitEmbarking(unit)
    if not unit then
        _HarnessInternal.log.error("IsUnitEmbarking requires unit", "IsUnitEmbarking")
        return nil
    end

    local success, embarking = pcall(function()
        return unit:embarking()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to check embarking: " .. tostring(embarking),
            "IsUnitEmbarking"
        )
        return nil
    end

    return embarking
end

-- Aircraft Functions

--- Get unit airbase
---@param unit table Unit object
---@return table? airbase Airbase object or nil
---@usage local airbase = GetUnitAirbase(unit)
function GetUnitAirbase(unit)
    if not unit then
        _HarnessInternal.log.error("GetUnitAirbase requires unit", "GetUnitAirbase")
        return nil
    end

    local success, airbase = pcall(function()
        return unit:getAirbase()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get unit airbase: " .. tostring(airbase),
            "GetUnitAirbase"
        )
        return nil
    end

    return airbase
end

--- Check if unit can land on ship
---@param unit table Unit object
---@return boolean? canLand True if can land on ship, nil on error
---@usage if UnitCanShipLanding(unit) then ... end
function UnitCanShipLanding(unit)
    if not unit then
        _HarnessInternal.log.error("UnitCanShipLanding requires unit", "UnitCanShipLanding")
        return nil
    end

    local success, canLand = pcall(function()
        return unit:canShipLanding()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to check ship landing: " .. tostring(canLand),
            "UnitCanShipLanding"
        )
        return nil
    end

    return canLand
end

--- Check if unit has carrier capabilities
---@param unit table Unit object
---@return boolean? hasCarrier True if has carrier capabilities, nil on error
---@usage if UnitHasCarrier(unit) then ... end
function UnitHasCarrier(unit)
    if not unit then
        _HarnessInternal.log.error("UnitHasCarrier requires unit", "UnitHasCarrier")
        return nil
    end

    local success, hasCarrier = pcall(function()
        return unit:hasCarrier()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to check carrier: " .. tostring(hasCarrier),
            "UnitHasCarrier"
        )
        return nil
    end

    return hasCarrier
end

--- Get nearest cargo for aircraft
---@param unit table Unit object
---@return table cargos Array of cargo objects
---@usage local cargos = GetUnitNearestCargosForAircraft(unit)
function GetUnitNearestCargosForAircraft(unit)
    if not unit then
        _HarnessInternal.log.error(
            "GetUnitNearestCargosForAircraft requires unit",
            "GetUnitNearestCargosForAircraft"
        )
        return {}
    end

    local success, cargos = pcall(function()
        return unit:getNearestCargosForAircraft()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get aircraft cargos: " .. tostring(cargos),
            "GetUnitNearestCargosForAircraft"
        )
        return {}
    end

    return cargos or {}
end

--- Get unit fuel low state
---@param unit table Unit object
---@return number? threshold Fuel low threshold or nil on error
---@usage local lowFuel = GetUnitFuelLowState(unit)
function GetUnitFuelLowState(unit)
    if not unit then
        _HarnessInternal.log.error("GetUnitFuelLowState requires unit", "GetUnitFuelLowState")
        return nil
    end

    local success, threshold = pcall(function()
        return unit:getFuelLowState()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get fuel low state: " .. tostring(threshold),
            "GetUnitFuelLowState"
        )
        return nil
    end

    return threshold
end

--- Show old carrier menu
---@param unit table Unit object
---@return boolean success True if shown
---@usage ShowUnitCarrierMenu(unit)
function ShowUnitCarrierMenu(unit)
    if not unit then
        _HarnessInternal.log.error("ShowUnitCarrierMenu requires unit", "ShowUnitCarrierMenu")
        return false
    end

    local success, result = pcall(function()
        unit:OldCarrierMenuShow()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to show carrier menu: " .. tostring(result),
            "ShowUnitCarrierMenu"
        )
        return false
    end

    return true
end

-- Other Functions

--- Get draw argument value
---@param unit table Unit object
---@param arg number Animation argument number
---@return number? value Draw argument value or nil on error
---@usage local gearPos = GetUnitDrawArgument(unit, 0) -- Landing gear
function GetUnitDrawArgument(unit, arg)
    if not unit then
        _HarnessInternal.log.error("GetUnitDrawArgument requires unit", "GetUnitDrawArgument")
        return nil
    end

    if not arg or type(arg) ~= "number" then
        _HarnessInternal.log.error(
            "GetUnitDrawArgument requires numeric argument",
            "GetUnitDrawArgument"
        )
        return nil
    end

    local success, value = pcall(function()
        return unit:getDrawArgumentValue(arg)
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get draw argument: " .. tostring(value),
            "GetUnitDrawArgument"
        )
        return nil
    end

    return value
end

--- Get unit communicator
---@param unit table Unit object
---@return table? communicator Communicator object or nil on error
---@usage local comm = GetUnitCommunicator(unit)
function GetUnitCommunicator(unit)
    if not unit then
        _HarnessInternal.log.error("GetUnitCommunicator requires unit", "GetUnitCommunicator")
        return nil
    end

    local success, communicator = pcall(function()
        return unit:getCommunicator()
    end)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get communicator: " .. tostring(communicator),
            "GetUnitCommunicator"
        )
        return nil
    end

    return communicator
end

--- Get unit seats
---@param unit table Unit object
---@return table? seats Seats info or nil on error
---@usage local seats = GetUnitSeats(unit)
function GetUnitSeats(unit)
    if not unit then
        _HarnessInternal.log.error("GetUnitSeats requires unit", "GetUnitSeats")
        return nil
    end

    local success, seats = pcall(function()
        return unit:getSeats()
    end)
    if not success then
        _HarnessInternal.log.error("Failed to get seats: " .. tostring(seats), "GetUnitSeats")
        return nil
    end

    return seats
end
-- ==== END: src/unit.lua ====

-- ==== BEGIN: src/vectorops.lua ====
--[[
    VectorOps Module - Vector Operations and Shape Merging
    
    This module provides vector operations similar to Adobe Illustrator,
    including union, intersection, difference, and shape merging operations.
    All shapes are represented as arrays of Vec2/Vec3 points.
]]

--- Finds intersection point of two 2D line segments
--- @param p1 table First point of first line segment {x, z}
--- @param p2 table Second point of first line segment {x, z}
--- @param p3 table First point of second line segment {x, z}
--- @param p4 table Second point of second line segment {x, z}
--- @return table|nil intersection Point of intersection {x, y, z} or nil if no intersection
--- @usage local pt = LineSegmentIntersection2D({x=0,z=0}, {x=10,z=10}, {x=0,z=10}, {x=10,z=0})
function LineSegmentIntersection2D(p1, p2, p3, p4)
    if not p1 or not p2 or not p3 or not p4 then
        _HarnessInternal.log.error(
            "LineSegmentIntersection2D requires four valid points",
            "VectorOps.LineSegmentIntersection2D"
        )
        return nil
    end

    local x1, y1 = p1.x, p1.z
    local x2, y2 = p2.x, p2.z
    local x3, y3 = p3.x, p3.z
    local x4, y4 = p4.x, p4.z

    local denom = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)

    if math.abs(denom) < 1e-10 then
        return nil -- Lines are parallel
    end

    local t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / denom
    local u = -((x1 - x2) * (y1 - y3) - (y1 - y2) * (x1 - x3)) / denom

    if t >= 0 and t <= 1 and u >= 0 and u <= 1 then
        return {
            x = x1 + t * (x2 - x1),
            y = p1.y or 0,
            z = y1 + t * (y2 - y1),
        }
    end

    return nil
end

--- Finds all intersection points between two polygons
--- @param poly1 table Array of points defining first polygon
--- @param poly2 table Array of points defining second polygon
--- @return table intersections Array of intersection data with point and edge info
--- @usage local intersections = FindPolygonIntersections(shape1, shape2)
function FindPolygonIntersections(poly1, poly2)
    if not poly1 or not poly2 or type(poly1) ~= "table" or type(poly2) ~= "table" then
        _HarnessInternal.log.error(
            "FindPolygonIntersections requires two valid polygons",
            "VectorOps.FindPolygonIntersections"
        )
        return {}
    end

    local intersections = {}

    -- Check each edge of poly1 against each edge of poly2
    for i = 1, #poly1 do
        local p1 = poly1[i]
        local p2 = poly1[(i % #poly1) + 1]

        for j = 1, #poly2 do
            local p3 = poly2[j]
            local p4 = poly2[(j % #poly2) + 1]

            local intersection = LineSegmentIntersection2D(p1, p2, p3, p4)
            if intersection then
                table.insert(intersections, {
                    point = intersection,
                    edge1 = { i, (i % #poly1) + 1 },
                    edge2 = { j, (j % #poly2) + 1 },
                })
            end
        end
    end

    return intersections
end

--- Merges two polygons with option to keep interior points
--- @param poly1 table Array of points defining first polygon
--- @param poly2 table Array of points defining second polygon
--- @param keepInterior boolean? Whether to keep interior points (default: false)
--- @return table|nil merged Merged polygon points or nil on error
--- @usage local merged = MergePolygons(shape1, shape2, false)
function MergePolygons(poly1, poly2, keepInterior)
    if not poly1 or not poly2 or type(poly1) ~= "table" or type(poly2) ~= "table" then
        _HarnessInternal.log.error(
            "MergePolygons requires two valid polygons",
            "VectorOps.MergePolygons"
        )
        return nil
    end

    -- If keepInterior is false, we want to remove interior points (union operation)
    -- If keepInterior is true, we keep all points

    local merged = {}
    local used = {}

    -- First, find all intersection points
    local intersections = FindPolygonIntersections(poly1, poly2)

    -- Add all vertices from poly1 that are outside poly2 (for union)
    for i, point in ipairs(poly1) do
        if keepInterior or not PointInPolygon2D(point, poly2) then
            table.insert(merged, point)
            used[point] = true
        end
    end

    -- Add all vertices from poly2 that are outside poly1 (for union)
    for i, point in ipairs(poly2) do
        if not used[point] and (keepInterior or not PointInPolygon2D(point, poly1)) then
            table.insert(merged, point)
        end
    end

    -- Add intersection points
    for _, intersection in ipairs(intersections) do
        table.insert(merged, intersection.point)
    end

    -- Sort points by angle from centroid to create proper polygon
    if #merged > 2 then
        local centroid = PolygonCentroid2D(merged)
        table.sort(merged, function(a, b)
            local angle_a = math.atan2(a.z - centroid.z, a.x - centroid.x)
            local angle_b = math.atan2(b.z - centroid.z, b.x - centroid.x)
            return angle_a < angle_b
        end)
    end

    -- If not keeping interior, compute convex hull to get outer boundary
    if not keepInterior and #merged > 2 then
        merged = ConvexHull2D(merged)
    end

    return merged
end

--- Creates union of two polygons (combines and keeps outer boundary)
--- @param poly1 table Array of points defining first polygon
--- @param poly2 table Array of points defining second polygon
--- @return table|nil union Combined polygon boundary or nil on error
--- @usage local union = UnionPolygons(shape1, shape2)
function UnionPolygons(poly1, poly2)
    -- Union: merge polygons and keep only the outer boundary
    return MergePolygons(poly1, poly2, false)
end

--- Creates intersection of two polygons (overlapping area)
--- @param poly1 table Array of points defining first polygon
--- @param poly2 table Array of points defining second polygon
--- @return table|nil intersection Overlapping area points or nil on error
--- @usage local overlap = IntersectPolygons(shape1, shape2)
function IntersectPolygons(poly1, poly2)
    if not poly1 or not poly2 or type(poly1) ~= "table" or type(poly2) ~= "table" then
        _HarnessInternal.log.error(
            "IntersectPolygons requires two valid polygons",
            "VectorOps.IntersectPolygons"
        )
        return nil
    end

    local intersection = {}

    -- Find all intersection points
    local intersections = FindPolygonIntersections(poly1, poly2)

    -- Add intersection points
    for _, inter in ipairs(intersections) do
        table.insert(intersection, inter.point)
    end

    -- Add vertices of poly1 that are inside poly2
    for _, point in ipairs(poly1) do
        if PointInPolygon2D(point, poly2) then
            table.insert(intersection, point)
        end
    end

    -- Add vertices of poly2 that are inside poly1
    for _, point in ipairs(poly2) do
        if PointInPolygon2D(point, poly1) then
            table.insert(intersection, point)
        end
    end

    -- Sort points by angle from centroid
    if #intersection > 2 then
        local centroid = PolygonCentroid2D(intersection)
        table.sort(intersection, function(a, b)
            local angle_a = math.atan2(a.z - centroid.z, a.x - centroid.x)
            local angle_b = math.atan2(b.z - centroid.z, b.x - centroid.x)
            return angle_a < angle_b
        end)
    end

    return intersection
end

--- Creates difference of two polygons (poly1 minus poly2)
--- @param poly1 table Array of points defining first polygon
--- @param poly2 table Array of points defining second polygon to subtract
--- @return table|nil difference Remaining area points or nil on error
--- @usage local diff = DifferencePolygons(shape1, shape2)
function DifferencePolygons(poly1, poly2)
    if not poly1 or not poly2 or type(poly1) ~= "table" or type(poly2) ~= "table" then
        _HarnessInternal.log.error(
            "DifferencePolygons requires two valid polygons",
            "VectorOps.DifferencePolygons"
        )
        return nil
    end

    local difference = {}

    -- Add vertices of poly1 that are outside poly2
    for _, point in ipairs(poly1) do
        if not PointInPolygon2D(point, poly2) then
            table.insert(difference, point)
        end
    end

    -- Add intersection points
    local intersections = FindPolygonIntersections(poly1, poly2)
    for _, inter in ipairs(intersections) do
        table.insert(difference, inter.point)
    end

    -- Sort points by angle from centroid
    if #difference > 2 then
        local centroid = PolygonCentroid2D(difference)
        table.sort(difference, function(a, b)
            local angle_a = math.atan2(a.z - centroid.z, a.x - centroid.x)
            local angle_b = math.atan2(b.z - centroid.z, b.x - centroid.x)
            return angle_a < angle_b
        end)
    end

    return difference
end

--- Simplifies a polygon by removing unnecessary points
--- @param polygon table Array of points defining the polygon
--- @param tolerance number? Maximum allowed deviation in meters (default: 1.0)
--- @return table simplified Simplified polygon points
--- @usage local simple = SimplifyPolygon(complexShape, 10)
function SimplifyPolygon(polygon, tolerance)
    if not polygon or type(polygon) ~= "table" or #polygon < 3 then
        _HarnessInternal.log.error(
            "SimplifyPolygon requires valid polygon with at least 3 points",
            "VectorOps.SimplifyPolygon"
        )
        return polygon or {}
    end

    tolerance = tolerance or 1.0

    -- Douglas-Peucker algorithm
    local function douglasPeucker(points, start, endIdx, simplifyTolerance)
        if endIdx <= start + 1 then
            return {}
        end

        local maxDist = 0
        local maxIndex = 0

        -- Find the point with maximum distance from line
        for i = start + 1, endIdx - 1 do
            local dist = PerpendicularDistance2D(points[i], points[start], points[endIdx])
            if dist > maxDist then
                maxDist = dist
                maxIndex = i
            end
        end

        -- If max distance is greater than tolerance, recursively simplify
        local result = {}
        if maxDist > simplifyTolerance then
            -- Recursive call
            local left = douglasPeucker(points, start, maxIndex, simplifyTolerance)
            local right = douglasPeucker(points, maxIndex, endIdx, simplifyTolerance)

            -- Build the result
            for _, p in ipairs(left) do
                table.insert(result, p)
            end
            table.insert(result, points[maxIndex])
            for _, p in ipairs(right) do
                table.insert(result, p)
            end
        end

        return result
    end

    local simplified = { polygon[1] }
    local middle = douglasPeucker(polygon, 1, #polygon, tolerance)
    for _, p in ipairs(middle) do
        table.insert(simplified, p)
    end
    table.insert(simplified, polygon[#polygon])

    return simplified
end

--- Calculates perpendicular distance from point to line
--- @param point table Point to measure from {x, z}
--- @param lineStart table Start point of line {x, z}
--- @param lineEnd table End point of line {x, z}
--- @return number distance Distance in meters
--- @usage local dist = PerpendicularDistance2D({x=5,z=5}, {x=0,z=0}, {x=10,z=0})
function PerpendicularDistance2D(point, lineStart, lineEnd)
    if not point or not lineStart or not lineEnd then
        _HarnessInternal.log.error(
            "PerpendicularDistance2D requires valid points",
            "VectorOps.PerpendicularDistance2D"
        )
        return 0
    end

    local dx = lineEnd.x - lineStart.x
    local dz = lineEnd.z - lineStart.z

    if math.abs(dx) < 1e-6 and math.abs(dz) < 1e-6 then
        -- Line start and end are the same
        return Distance2D(point, lineStart)
    end

    local t = ((point.x - lineStart.x) * dx + (point.z - lineStart.z) * dz) / (dx * dx + dz * dz)

    if t < 0 then
        return Distance2D(point, lineStart)
    elseif t > 1 then
        return Distance2D(point, lineEnd)
    else
        local projection = {
            x = lineStart.x + t * dx,
            y = point.y or 0,
            z = lineStart.z + t * dz,
        }
        return Distance2D(point, projection)
    end
end

--- Offsets a polygon by a specified distance (inward or outward)
--- @param polygon table Array of points defining the polygon
--- @param distance number Offset distance in meters (positive = outward)
--- @return table|nil offset Offset polygon points or nil on error
--- @usage local expanded = OffsetPolygon(shape, 100)
function OffsetPolygon(polygon, distance)
    if not polygon or type(polygon) ~= "table" or #polygon < 3 then
        _HarnessInternal.log.error(
            "OffsetPolygon requires valid polygon with at least 3 points",
            "VectorOps.OffsetPolygon"
        )
        return nil
    end

    local offset = {}
    local n = #polygon

    for i = 1, n do
        local prev = polygon[((i - 2) % n) + 1]
        local curr = polygon[i]
        local next = polygon[(i % n) + 1]

        -- Calculate edge vectors
        local v1 = { x = curr.x - prev.x, z = curr.z - prev.z }
        local v2 = { x = next.x - curr.x, z = next.z - curr.z }

        -- Normalize
        local len1 = math.sqrt(v1.x * v1.x + v1.z * v1.z)
        local len2 = math.sqrt(v2.x * v2.x + v2.z * v2.z)

        if len1 > 1e-6 and len2 > 1e-6 then
            v1.x, v1.z = v1.x / len1, v1.z / len1
            v2.x, v2.z = v2.x / len2, v2.z / len2

            -- Calculate normals (perpendicular)
            local n1 = { x = -v1.z, z = v1.x }
            local n2 = { x = -v2.z, z = v2.x }

            -- Calculate miter
            local miter = { x = n1.x + n2.x, z = n1.z + n2.z }
            local miterLen = math.sqrt(miter.x * miter.x + miter.z * miter.z)

            if miterLen > 1e-6 then
                -- Calculate miter length
                local dot = v1.x * v2.x + v1.z * v2.z
                local miterScale = 1 / (1 + dot)

                -- Apply offset
                table.insert(offset, {
                    x = curr.x + miter.x * distance * miterScale / miterLen,
                    y = curr.y or 0,
                    z = curr.z + miter.z * distance * miterScale / miterLen,
                })
            else
                -- Fallback for sharp angles
                table.insert(offset, {
                    x = curr.x + n1.x * distance,
                    y = curr.y or 0,
                    z = curr.z + n1.z * distance,
                })
            end
        else
            -- Degenerate case
            table.insert(offset, curr)
        end
    end

    return offset
end

--- Clips one polygon to another using Sutherland-Hodgman algorithm
--- @param subject table Array of points defining polygon to clip
--- @param clip table Array of points defining clipping polygon
--- @return table|nil clipped Clipped polygon points or nil on error
--- @usage local clipped = ClipPolygonToPolygon(shape, boundary)
function ClipPolygonToPolygon(subject, clip)
    -- Sutherland-Hodgman algorithm
    if not subject or not clip or type(subject) ~= "table" or type(clip) ~= "table" then
        _HarnessInternal.log.error(
            "ClipPolygonToPolygon requires two valid polygons",
            "VectorOps.ClipPolygonToPolygon"
        )
        return nil
    end

    local function inside(p, edge_start, edge_end)
        return (edge_end.x - edge_start.x) * (p.z - edge_start.z)
                - (edge_end.z - edge_start.z) * (p.x - edge_start.x)
            >= 0
    end

    local output = subject

    for i = 1, #clip do
        if #output == 0 then
            break
        end

        local input = output
        output = {}

        local edge_start = clip[i]
        local edge_end = clip[(i % #clip) + 1]

        for j = 1, #input do
            local current = input[j]
            local previous = input[((j - 2) % #input) + 1]

            if inside(current, edge_start, edge_end) then
                if not inside(previous, edge_start, edge_end) then
                    -- Entering the inside
                    local intersection =
                        LineSegmentIntersection2D(previous, current, edge_start, edge_end)
                    if intersection then
                        table.insert(output, intersection)
                    end
                end
                table.insert(output, current)
            elseif inside(previous, edge_start, edge_end) then
                -- Leaving the inside
                local intersection =
                    LineSegmentIntersection2D(previous, current, edge_start, edge_end)
                if intersection then
                    table.insert(output, intersection)
                end
            end
        end
    end

    return output
end

--- Triangulates a polygon into triangles using ear clipping
--- @param polygon table Array of points defining the polygon
--- @return table triangles Array of triangles, each with 3 vertices
--- @usage local triangles = TriangulatePolygon(shape)
function TriangulatePolygon(polygon)
    if not polygon or type(polygon) ~= "table" or #polygon < 3 then
        _HarnessInternal.log.error(
            "TriangulatePolygon requires valid polygon with at least 3 points",
            "VectorOps.TriangulatePolygon"
        )
        return {}
    end

    -- Simple ear clipping algorithm
    local triangles = {}
    local vertices = {}

    -- Copy vertices
    for i, v in ipairs(polygon) do
        table.insert(vertices, { x = v.x, y = v.y or 0, z = v.z, index = i })
    end

    local function isEar(vertexList, i)
        local n = #vertexList
        local prev = ((i - 2) % n) + 1
        local next = (i % n) + 1

        local p1 = vertexList[prev]
        local p2 = vertexList[i]
        local p3 = vertexList[next]

        -- Check if angle is convex
        local cross = (p2.x - p1.x) * (p3.z - p1.z) - (p2.z - p1.z) * (p3.x - p1.x)
        if cross <= 0 then
            return false
        end

        -- Check if any other vertex is inside the triangle
        for j = 1, n do
            if j ~= prev and j ~= i and j ~= next then
                if PointInTriangle2D(vertexList[j], p1, p2, p3) then
                    return false
                end
            end
        end

        return true
    end

    while #vertices > 3 do
        local found = false

        for i = 1, #vertices do
            if isEar(vertices, i) then
                local n = #vertices
                local prev = ((i - 2) % n) + 1
                local next = (i % n) + 1

                table.insert(triangles, {
                    vertices[prev],
                    vertices[i],
                    vertices[next],
                })

                table.remove(vertices, i)
                found = true
                break
            end
        end

        if not found then
            -- Fallback: just create a fan from first vertex
            for i = 2, #vertices - 1 do
                table.insert(triangles, {
                    vertices[1],
                    vertices[i],
                    vertices[i + 1],
                })
            end
            break
        end
    end

    -- Add the last triangle
    if #vertices == 3 then
        table.insert(triangles, vertices)
    end

    return triangles
end

--- Checks if a point is inside a 2D triangle
--- @param p table Point to test {x, z}
--- @param a table First vertex of triangle {x, z}
--- @param b table Second vertex of triangle {x, z}
--- @param c table Third vertex of triangle {x, z}
--- @return boolean inside True if point is inside triangle
--- @usage local inside = PointInTriangle2D({x=5,z=5}, {x=0,z=0}, {x=10,z=0}, {x=5,z=10})
function PointInTriangle2D(p, a, b, c)
    local function sign(p1, p2, p3)
        return (p1.x - p3.x) * (p2.z - p3.z) - (p2.x - p3.x) * (p1.z - p3.z)
    end

    local d1 = sign(p, a, b)
    local d2 = sign(p, b, c)
    local d3 = sign(p, c, a)

    local has_neg = (d1 < 0) or (d2 < 0) or (d3 < 0)
    local has_pos = (d1 > 0) or (d2 > 0) or (d3 > 0)

    return not (has_neg and has_pos)
end
-- ==== END: src/vectorops.lua ====

-- ==== BEGIN: src/weapon.lua ====
--[[
    Weapon Module - DCS World Weapon API Wrappers
    
    This module provides validated wrapper functions for DCS weapon operations,
    including weapon tracking, target queries, and launcher information.
]]

-- require("vector")

--- Gets the type name of a weapon
---@param weapon table The weapon object
---@return string? typeName The weapon type name or nil on error
---@usage local typeName = GetWeaponTypeName(weapon)
function GetWeaponTypeName(weapon)
    if not weapon then
        _HarnessInternal.log.error("GetWeaponTypeName requires valid weapon", "Weapon.GetTypeName")
        return nil
    end

    local success, result = pcall(weapon.getTypeName, weapon)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get weapon type name: " .. tostring(result),
            "Weapon.GetTypeName"
        )
        return nil
    end

    return result
end

--- Gets the description of a weapon
---@param weapon table The weapon object
---@return table? desc The weapon description table or nil on error
---@usage local desc = GetWeaponDesc(weapon)
function GetWeaponDesc(weapon)
    if not weapon then
        _HarnessInternal.log.error("GetWeaponDesc requires valid weapon", "Weapon.GetDesc")
        return nil
    end

    local success, result = pcall(weapon.getDesc, weapon)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get weapon description: " .. tostring(result),
            "Weapon.GetDesc"
        )
        return nil
    end

    return result
end

--- Gets the launcher unit of a weapon
---@param weapon table The weapon object
---@return table? launcher The launcher unit object or nil on error
---@usage local launcher = GetWeaponLauncher(weapon)
function GetWeaponLauncher(weapon)
    if not weapon then
        _HarnessInternal.log.error("GetWeaponLauncher requires valid weapon", "Weapon.GetLauncher")
        return nil
    end

    local success, result = pcall(weapon.getLauncher, weapon)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get weapon launcher: " .. tostring(result),
            "Weapon.GetLauncher"
        )
        return nil
    end

    return result
end

--- Gets the target of a weapon
---@param weapon table The weapon object
---@return table? target The target object or nil if no target
---@usage local target = GetWeaponTarget(weapon)
function GetWeaponTarget(weapon)
    if not weapon then
        _HarnessInternal.log.error("GetWeaponTarget requires valid weapon", "Weapon.GetTarget")
        return nil
    end

    local success, result = pcall(weapon.getTarget, weapon)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get weapon target: " .. tostring(result),
            "Weapon.GetTarget"
        )
        return nil
    end

    return result
end

--- Gets the category of a weapon
---@param weapon table The weapon object
---@return number? category The weapon category or nil on error
---@usage local category = GetWeaponCategory(weapon)
function GetWeaponCategory(weapon)
    if not weapon then
        _HarnessInternal.log.error("GetWeaponCategory requires valid weapon", "Weapon.GetCategory")
        return nil
    end

    local success, result = pcall(weapon.getCategory, weapon)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get weapon category: " .. tostring(result),
            "Weapon.GetCategory"
        )
        return nil
    end

    return result
end

--- Checks if a weapon exists
---@param weapon table The weapon object to check
---@return boolean? exists Returns true if exists, false if not, nil on error
---@usage local exists = IsWeaponExist(weapon)
function IsWeaponExist(weapon)
    if not weapon then
        _HarnessInternal.log.error("IsWeaponExist requires valid weapon", "Weapon.IsExist")
        return nil
    end

    local success, result = pcall(weapon.isExist, weapon)
    if not success then
        _HarnessInternal.log.error(
            "Failed to check weapon existence: " .. tostring(result),
            "Weapon.IsExist"
        )
        return nil
    end

    return result
end

--- Gets the coalition of a weapon
---@param weapon table The weapon object
---@return number? coalition The coalition ID or nil on error
---@usage local coalition = GetWeaponCoalition(weapon)
function GetWeaponCoalition(weapon)
    if not weapon then
        _HarnessInternal.log.error(
            "GetWeaponCoalition requires valid weapon",
            "Weapon.GetCoalition"
        )
        return nil
    end

    local success, result = pcall(weapon.getCoalition, weapon)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get weapon coalition: " .. tostring(result),
            "Weapon.GetCoalition"
        )
        return nil
    end

    return result
end

--- Gets the country of a weapon
---@param weapon table The weapon object
---@return number? country The country ID or nil on error
---@usage local country = GetWeaponCountry(weapon)
function GetWeaponCountry(weapon)
    if not weapon then
        _HarnessInternal.log.error("GetWeaponCountry requires valid weapon", "Weapon.GetCountry")
        return nil
    end

    local success, result = pcall(weapon.getCountry, weapon)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get weapon country: " .. tostring(result),
            "Weapon.GetCountry"
        )
        return nil
    end

    return result
end

--- Gets the 3D position point of a weapon
---@param weapon table The weapon object
---@return table? point Position table with x, y, z coordinates or nil on error
---@usage local point = GetWeaponPoint(weapon)
function GetWeaponPoint(weapon)
    if not weapon then
        _HarnessInternal.log.error("GetWeaponPoint requires valid weapon", "Weapon.GetPoint")
        return nil
    end

    local success, result = pcall(weapon.getPoint, weapon)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get weapon point: " .. tostring(result),
            "Weapon.GetPoint"
        )
        return nil
    end

    return result
end

--- Gets the position and orientation of a weapon
---@param weapon table The weapon object
---@return table? position Position table with p (point) and x,y,z vectors or nil on error
---@usage local pos = GetWeaponPosition(weapon)
function GetWeaponPosition(weapon)
    if not weapon then
        _HarnessInternal.log.error("GetWeaponPosition requires valid weapon", "Weapon.GetPosition")
        return nil
    end

    local success, result = pcall(weapon.getPosition, weapon)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get weapon position: " .. tostring(result),
            "Weapon.GetPosition"
        )
        return nil
    end

    return result
end

--- Gets the velocity vector of a weapon
---@param weapon table The weapon object
---@return table? velocity Velocity vector with x, y, z components or nil on error
---@usage local vel = GetWeaponVelocity(weapon)
function GetWeaponVelocity(weapon)
    if not weapon then
        _HarnessInternal.log.error("GetWeaponVelocity requires valid weapon", "Weapon.GetVelocity")
        return nil
    end

    local success, result = pcall(weapon.getVelocity, weapon)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get weapon velocity: " .. tostring(result),
            "Weapon.GetVelocity"
        )
        return nil
    end

    return result
end

--- Gets the name of a weapon
---@param weapon table The weapon object
---@return string? name The weapon name or nil on error
---@usage local name = GetWeaponName(weapon)
function GetWeaponName(weapon)
    if not weapon then
        _HarnessInternal.log.error("GetWeaponName requires valid weapon", "Weapon.GetName")
        return nil
    end

    local success, result = pcall(weapon.getName, weapon)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get weapon name: " .. tostring(result),
            "Weapon.GetName"
        )
        return nil
    end

    return result
end

--- Destroys a weapon
---@param weapon table The weapon object to destroy
---@return boolean? success Returns true if successful, nil on error
---@usage DestroyWeapon(weapon)
function DestroyWeapon(weapon)
    if not weapon then
        _HarnessInternal.log.error("DestroyWeapon requires valid weapon", "Weapon.Destroy")
        return nil
    end

    local success, result = pcall(weapon.destroy, weapon)
    if not success then
        _HarnessInternal.log.error(
            "Failed to destroy weapon: " .. tostring(result),
            "Weapon.Destroy"
        )
        return nil
    end

    return true
end

--- Gets the category name of a weapon
---@param weapon table The weapon object
---@return string? categoryName The weapon category name or nil on error
---@usage local catName = GetWeaponCategoryName(weapon)
function GetWeaponCategoryName(weapon)
    if not weapon then
        _HarnessInternal.log.error(
            "GetWeaponCategoryName requires valid weapon",
            "Weapon.GetCategoryName"
        )
        return nil
    end

    local success, result = pcall(weapon.getCategoryName, weapon)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get weapon category name: " .. tostring(result),
            "Weapon.GetCategoryName"
        )
        return nil
    end

    return result
end

--- Checks if a weapon is active
---@param weapon table The weapon object to check
---@return boolean? active Returns true if active, false if not, nil on error
---@usage local active = IsWeaponActive(weapon)
function IsWeaponActive(weapon)
    if not weapon then
        _HarnessInternal.log.error("IsWeaponActive requires valid weapon", "Weapon.IsActive")
        return nil
    end

    -- Some DCS builds do not expose weapon.isActive; prefer it when present,
    -- otherwise fall back to existence as a proxy for activity to avoid errors.
    if type(weapon.isActive) == "function" then
        local success, result = pcall(weapon.isActive, weapon)
        if not success then
            _HarnessInternal.log.error(
                "Failed to check if weapon is active: " .. tostring(result),
                "Weapon.IsActive"
            )
            return nil
        end
        return result
    end

    local okExist, exists = pcall(weapon.isExist, weapon)
    if not okExist then
        _HarnessInternal.log.error(
            "Failed to check weapon existence as activity proxy: " .. tostring(exists),
            "Weapon.IsActive"
        )
        return nil
    end
    return exists == true
end
-- ==== END: src/weapon.lua ====

-- ==== BEGIN: src/world.lua ====
--[[
    World Module - DCS World API Wrappers
    
    This module provides validated wrapper functions for DCS world operations,
    including event management, marking panels, and world information queries.
]]

-- require("vector")

--- Adds an event handler to the world
---@param handler table Event handler table with onEvent function
---@return boolean? success Returns true if successful, nil on error
---@usage AddWorldEventHandler({onEvent = function(self, event) ... end})
function AddWorldEventHandler(handler)
    if not handler or type(handler) ~= "table" then
        _HarnessInternal.log.error(
            "AddWorldEventHandler requires valid handler table",
            "World.AddEventHandler"
        )
        return nil
    end

    if not handler.onEvent or type(handler.onEvent) ~= "function" then
        _HarnessInternal.log.error(
            "AddWorldEventHandler handler must have onEvent function",
            "World.AddEventHandler"
        )
        return nil
    end

    local success, result = pcall(world.addEventHandler, handler)
    if not success then
        _HarnessInternal.log.error(
            "Failed to add event handler: " .. tostring(result),
            "World.AddEventHandler"
        )
        return nil
    end

    return true
end

--- Removes an event handler from the world
---@param handler table The event handler table to remove
---@return boolean? success Returns true if successful, nil on error
---@usage RemoveWorldEventHandler(myHandler)
function RemoveWorldEventHandler(handler)
    if not handler or type(handler) ~= "table" then
        _HarnessInternal.log.error(
            "RemoveWorldEventHandler requires valid handler table",
            "World.RemoveEventHandler"
        )
        return nil
    end

    local success, result = pcall(world.removeEventHandler, handler)
    if not success then
        _HarnessInternal.log.error(
            "Failed to remove event handler: " .. tostring(result),
            "World.RemoveEventHandler"
        )
        return nil
    end

    return true
end

--- Gets the player unit in the world
---@return table? player The player unit object or nil if not found
---@usage local player = GetWorldPlayer()
function GetWorldPlayer()
    local success, result = pcall(world.getPlayer)
    if not success then
        _HarnessInternal.log.error("Failed to get player: " .. tostring(result), "World.GetPlayer")
        return nil
    end

    return result
end

--- Gets all airbases in the world
---@return table? airbases Array of airbase objects or nil on error
---@usage local airbases = GetWorldAirbases()
function GetWorldAirbases()
    local success, result = pcall(world.getAirbases)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get world airbases: " .. tostring(result),
            "World.GetAirbases"
        )
        return nil
    end

    return result
end

--- Searches for objects in the world within a volume
---@param category number? Object category to search for
---@param volume table? Search volume definition
---@param objectFilter function? Filter function for objects
---@return table? objects Array of found objects or nil on error
---@usage local objects = SearchWorldObjects(Object.Category.UNIT, sphereVolume)
function SearchWorldObjects(category, volume, objectFilter)
    if category and type(category) ~= "number" then
        _HarnessInternal.log.error(
            "SearchWorldObjects category must be a number if provided",
            "World.SearchObjects"
        )
        return nil
    end

    if volume and type(volume) ~= "table" then
        _HarnessInternal.log.error(
            "SearchWorldObjects volume must be a table if provided",
            "World.SearchObjects"
        )
        return nil
    end

    local success, result = pcall(world.searchObjects, category, volume, objectFilter)
    if not success then
        _HarnessInternal.log.error(
            "Failed to search world objects: " .. tostring(result),
            "World.SearchObjects"
        )
        return nil
    end

    return result
end

--- Gets all mark panels in the world
---@return table? panels Array of mark panel objects or nil on error
---@usage local panels = getMarkPanels()
function GetMarkPanels()
    local success, result = pcall(world.getMarkPanels)
    if not success then
        _HarnessInternal.log.error(
            "Failed to get mark panels: " .. tostring(result),
            "World.GetMarkPanels"
        )
        return nil
    end

    return result
end

--- Processes a world event
---@param event table The event table to process
---@return boolean? success Returns true if successful, nil on error
---@usage OnWorldEvent({id = world.event.S_EVENT_SHOT, ...})
function OnWorldEvent(event)
    if not event or type(event) ~= "table" then
        _HarnessInternal.log.error("OnWorldEvent requires valid event table", "World.OnEvent")
        return nil
    end

    local success, result = pcall(world.onEvent, event)
    if not success then
        _HarnessInternal.log.error(
            "Failed to process world event: " .. tostring(result),
            "World.OnEvent"
        )
        return nil
    end

    return true
end

--- Gets fog-related weather values if available (DCS 2.9.10+)
---@return table? weather Table with fog fields if available { fogThickness, fogVisibilityDistance, fogAnimationEnabled }
---@usage local weather = GetWorldWeather()
function GetWorldWeather()
    if not world or not world.weather then
        _HarnessInternal.log.error(
            "World.weather is not available in this DCS version",
            "World.GetWeather"
        )
        return nil
    end

    local data = {}

    if world.weather.getFogThickness then
        local ok, v = pcall(world.weather.getFogThickness)
        if ok then
            data.fogThickness = v
        end
    end

    if world.weather.getFogVisibilityDistance then
        local ok, v = pcall(world.weather.getFogVisibilityDistance)
        if ok then
            data.fogVisibilityDistance = v
        end
    end

    if world.weather.setFogAnimation and world.weather.getFogVisibilityDistance then
        -- No getter for animation; absent in API. Expose presence of setter as capability flag.
        data.fogAnimationEnabled = nil
    end

    return data
end

-- Fog control (DCS 2.9.10+)

--- Get fog thickness in meters
---@return number? thickness Fog thickness in meters or nil if unsupported/error
---@usage local t = GetFogThickness()
function GetFogThickness()
    if not world or not world.weather or type(world.weather.getFogThickness) ~= "function" then
        _HarnessInternal.log.error(
            "world.weather.getFogThickness not available",
            "World.GetFogThickness"
        )
        return nil
    end
    local ok, v = pcall(world.weather.getFogThickness)
    if not ok then
        _HarnessInternal.log.error(
            "Failed to get fog thickness: " .. tostring(v),
            "World.GetFogThickness"
        )
        return nil
    end
    return v
end

--- Set fog thickness in meters
---@param thickness number Non-negative thickness in meters
---@return boolean? success True on success, nil on error
---@usage SetFogThickness(300)
function SetFogThickness(thickness)
    if not world or not world.weather or type(world.weather.setFogThickness) ~= "function" then
        _HarnessInternal.log.error(
            "world.weather.setFogThickness not available",
            "World.SetFogThickness"
        )
        return nil
    end
    if type(thickness) ~= "number" or thickness < 0 then
        _HarnessInternal.log.error(
            "SetFogThickness requires non-negative number",
            "World.SetFogThickness"
        )
        return nil
    end
    local ok, err = pcall(world.weather.setFogThickness, thickness)
    if not ok then
        _HarnessInternal.log.error(
            "Failed to set fog thickness: " .. tostring(err),
            "World.SetFogThickness"
        )
        return nil
    end
    return true
end

--- Get fog visibility distance in meters
---@return number? distance Visibility distance in meters or nil if unsupported/error
---@usage local d = GetFogVisibilityDistance()
function GetFogVisibilityDistance()
    if
        not world
        or not world.weather
        or type(world.weather.getFogVisibilityDistance) ~= "function"
    then
        _HarnessInternal.log.error(
            "world.weather.getFogVisibilityDistance not available",
            "World.GetFogVisibilityDistance"
        )
        return nil
    end
    local ok, v = pcall(world.weather.getFogVisibilityDistance)
    if not ok then
        _HarnessInternal.log.error(
            "Failed to get fog visibility distance: " .. tostring(v),
            "World.GetFogVisibilityDistance"
        )
        return nil
    end
    return v
end

--- Set fog visibility distance in meters
---@param distance number Non-negative distance in meters
---@return boolean? success True on success, nil on error
---@usage SetFogVisibilityDistance(800)
function SetFogVisibilityDistance(distance)
    if
        not world
        or not world.weather
        or type(world.weather.setFogVisibilityDistance) ~= "function"
    then
        _HarnessInternal.log.error(
            "world.weather.setFogVisibilityDistance not available",
            "World.SetFogVisibilityDistance"
        )
        return nil
    end
    if type(distance) ~= "number" or distance < 0 then
        _HarnessInternal.log.error(
            "SetFogVisibilityDistance requires non-negative number",
            "World.SetFogVisibilityDistance"
        )
        return nil
    end
    local ok, err = pcall(world.weather.setFogVisibilityDistance, distance)
    if not ok then
        _HarnessInternal.log.error(
            "Failed to set fog visibility distance: " .. tostring(err),
            "World.SetFogVisibilityDistance"
        )
        return nil
    end
    return true
end

--- Enable or disable fog animation
---@param enabled boolean Whether to enable fog animation
---@return boolean? success True on success, nil on error
---@usage SetFogAnimation(true)
function SetFogAnimation(enabled)
    if not world or not world.weather or type(world.weather.setFogAnimation) ~= "function" then
        _HarnessInternal.log.error(
            "world.weather.setFogAnimation not available",
            "World.SetFogAnimation"
        )
        return nil
    end
    if type(enabled) ~= "boolean" then
        _HarnessInternal.log.error(
            "SetFogAnimation requires boolean enabled",
            "World.SetFogAnimation"
        )
        return nil
    end
    local ok, err = pcall(world.weather.setFogAnimation, enabled)
    if not ok then
        _HarnessInternal.log.error(
            "Failed to set fog animation: " .. tostring(err),
            "World.SetFogAnimation"
        )
        return nil
    end
    return true
end

--- Removes junk objects within a search volume
---@param searchVolume table The search volume definition
---@return number? count Number of objects removed or nil on error
---@usage local removed = RemoveWorldJunk(sphereVolume)
function RemoveWorldJunk(searchVolume)
    if not searchVolume or type(searchVolume) ~= "table" then
        _HarnessInternal.log.error(
            "RemoveWorldJunk requires valid search volume",
            "World.RemoveJunk"
        )
        return nil
    end

    local success, result = pcall(world.removeJunk, searchVolume)
    if not success then
        _HarnessInternal.log.error(
            "Failed to remove world junk: " .. tostring(result),
            "World.RemoveJunk"
        )
        return nil
    end

    return result
end

--- Creates a world event handler with named event callbacks
---@param handlers table Table of event name to callback function mappings
---@return table? eventHandler Event handler object or nil on error
---@usage local handler = CreateWorldEventHandler({S_EVENT_SHOT = function(event) ... end})
function CreateWorldEventHandler(handlers)
    if not handlers or type(handlers) ~= "table" then
        _HarnessInternal.log.error(
            "CreateWorldEventHandler requires valid handlers table",
            "World.CreateEventHandler"
        )
        return nil
    end

    local eventHandler = {}

    eventHandler.onEvent = function(self, event)
        if not event or not event.id then
            return
        end

        local eventName = nil
        for name, id in pairs(world.event) do
            if id == event.id then
                eventName = name
                break
            end
        end

        if eventName and handlers[eventName] then
            local success, result = pcall(handlers[eventName], event)
            if not success then
                _HarnessInternal.log.error(
                    "Event handler error for " .. eventName .. ": " .. tostring(result),
                    "World.EventHandler"
                )
            end
        end
    end

    return eventHandler
end

--- Gets all world event type constants
---@return table? eventTypes Table of event name to ID mappings or nil on error
---@usage local eventTypes = GetWorldEventTypes()
function GetWorldEventTypes()
    local success, result = pcall(function()
        return world.event
    end)

    if not success then
        _HarnessInternal.log.error(
            "Failed to get world event types: " .. tostring(result),
            "World.GetEventTypes"
        )
        return nil
    end

    return result
end

--- Gets all world volume type constants
---@return table? volumeTypes Table of volume type constants or nil on error
---@usage local volumeTypes = GetWorldVolumeTypes()
function GetWorldVolumeTypes()
    local success, result = pcall(function()
        return world.VolumeType
    end)

    if not success then
        _HarnessInternal.log.error(
            "Failed to get world volume types: " .. tostring(result),
            "World.GetVolumeTypes"
        )
        return nil
    end

    return result
end

--- Creates a search volume for world object searches
---@param volumeType number The volume type constant
---@param params table Parameters for the volume type
---@return table? volume Volume definition or nil on error
---@usage local volume = CreateWorldSearchVolume(world.VolumeType.SPHERE, {point={x=0,y=0,z=0}, radius=1000})
function CreateWorldSearchVolume(volumeType, params)
    if not volumeType or type(volumeType) ~= "number" then
        _HarnessInternal.log.error(
            "CreateWorldSearchVolume requires valid volume type",
            "World.CreateSearchVolume"
        )
        return nil
    end

    if not params or type(params) ~= "table" then
        _HarnessInternal.log.error(
            "CreateWorldSearchVolume requires valid parameters table",
            "World.CreateSearchVolume"
        )
        return nil
    end

    local volume = {
        id = volumeType,
        params = params,
    }

    return volume
end

--- Creates a spherical search volume
---@param center table Center position with x, y, z coordinates
---@param radius number Sphere radius in meters
---@return table? volume Sphere volume definition or nil on error
---@usage local sphere = CreateSphereVolume({x=1000, y=100, z=2000}, 500)
function CreateSphereVolume(center, radius)
    if not center or type(center) ~= "table" or not center.x or not center.y or not center.z then
        _HarnessInternal.log.error(
            "CreateSphereVolume requires valid center position",
            "World.CreateSphereVolume"
        )
        return nil
    end

    if not radius or type(radius) ~= "number" or radius <= 0 then
        _HarnessInternal.log.error(
            "CreateSphereVolume requires valid radius",
            "World.CreateSphereVolume"
        )
        return nil
    end

    return CreateWorldSearchVolume(world.VolumeType.SPHERE, {
        point = center,
        radius = radius,
    })
end

--- Creates a box-shaped search volume
---@param min table Minimum corner position with x, y, z coordinates
---@param max table Maximum corner position with x, y, z coordinates
---@return table? volume Box volume definition or nil on error
---@usage local box = CreateBoxVolume({x=0, y=0, z=0}, {x=1000, y=500, z=1000})
function CreateBoxVolume(min, max)
    if not min or type(min) ~= "table" or not min.x or not min.y or not min.z then
        _HarnessInternal.log.error(
            "CreateBoxVolume requires valid min position",
            "World.CreateBoxVolume"
        )
        return nil
    end

    if not max or type(max) ~= "table" or not max.x or not max.y or not max.z then
        _HarnessInternal.log.error(
            "CreateBoxVolume requires valid max position",
            "World.CreateBoxVolume"
        )
        return nil
    end

    return CreateWorldSearchVolume(world.VolumeType.BOX, {
        min = min,
        max = max,
    })
end

--- Creates a pyramid-shaped search volume
---@param pos table Position and orientation table
---@param length number Length of the pyramid in meters
---@param halfAngleHor number Horizontal half angle in radians
---@param halfAngleVer number Vertical half angle in radians
---@return table? volume Pyramid volume definition or nil on error
---@usage local pyramid = CreatePyramidVolume({x=0, y=100, z=0}, 5000, math.rad(30), math.rad(20))
function CreatePyramidVolume(pos, length, halfAngleHor, halfAngleVer)
    if not pos or type(pos) ~= "table" then
        _HarnessInternal.log.error(
            "CreatePyramidVolume requires valid position",
            "World.CreatePyramidVolume"
        )
        return nil
    end

    if not length or type(length) ~= "number" or length <= 0 then
        _HarnessInternal.log.error(
            "CreatePyramidVolume requires valid length",
            "World.CreatePyramidVolume"
        )
        return nil
    end

    if not halfAngleHor or type(halfAngleHor) ~= "number" then
        _HarnessInternal.log.error(
            "CreatePyramidVolume requires valid horizontal half angle",
            "World.CreatePyramidVolume"
        )
        return nil
    end

    if not halfAngleVer or type(halfAngleVer) ~= "number" then
        _HarnessInternal.log.error(
            "CreatePyramidVolume requires valid vertical half angle",
            "World.CreatePyramidVolume"
        )
        return nil
    end

    return CreateWorldSearchVolume(world.VolumeType.PYRAMID, {
        pos = pos,
        length = length,
        halfAngleHor = halfAngleHor,
        halfAngleVer = halfAngleVer,
    })
end

--- Creates a line segment search volume
---@param from table Start position with x, y, z coordinates
---@param to table End position with x, y, z coordinates
---@return table? volume Segment volume definition or nil on error
---@usage local segment = CreateSegmentVolume({x=0, y=100, z=0}, {x=1000, y=100, z=1000})
function CreateSegmentVolume(from, to)
    if not from or type(from) ~= "table" or not from.x or not from.y or not from.z then
        _HarnessInternal.log.error(
            "CreateSegmentVolume requires valid from position",
            "World.CreateSegmentVolume"
        )
        return nil
    end

    if not to or type(to) ~= "table" or not to.x or not to.y or not to.z then
        _HarnessInternal.log.error(
            "CreateSegmentVolume requires valid to position",
            "World.CreateSegmentVolume"
        )
        return nil
    end

    return CreateWorldSearchVolume(world.VolumeType.SEGMENT, {
        from = from,
        to = to,
    })
end
-- ==== END: src/world.lua ====

-- ==== BEGIN: src/drawing.lua ====
--[[
    Drawing Module - DCS World Drawing API Wrappers
    
    This module provides validated wrapper functions for DCS drawing operations,
    including getting drawing objects from the mission.
]]

--- Get all drawings from the mission
---@return table? drawings Table of all drawing layers and objects or nil on error
---@usage local drawings = GetDrawings()
function GetDrawings()
    local success, result = pcall(function()
        if env and env.mission and env.mission.drawings then
            return env.mission.drawings
        end
        return nil
    end)

    if not success then
        _HarnessInternal.log.error(
            "Failed to get drawings: " .. tostring(result),
            "Drawing.GetDrawings"
        )
        return nil
    end

    return result
end

--- Process drawing objects and extract geometry
---@param drawing table Drawing object to process
---@return table? geometry Processed geometry data or nil on error
function ProcessDrawingGeometry(drawing)
    if not drawing or type(drawing) ~= "table" then
        return nil
    end

    local geometry = {
        name = drawing.name,
        type = drawing.primitiveType,
        visible = drawing.visible,
        layerName = drawing.layerName,
        mapX = drawing.mapX,
        mapY = drawing.mapY,
    }

    -- Convert mapX, mapY to DCS coordinate system (x, z)
    if geometry.mapX and geometry.mapY then
        geometry.x = geometry.mapX
        geometry.z = geometry.mapY
        geometry.y = 0 -- Default ground level
    end

    -- Process based on primitive type
    if drawing.primitiveType == "Line" then
        geometry.lineMode = drawing.lineMode
        geometry.closed = drawing.closed
        geometry.points = {}

        if drawing.points then
            for i, point in ipairs(drawing.points) do
                table.insert(geometry.points, {
                    x = (drawing.mapX or 0) + (point.x or 0),
                    y = 0,
                    z = (drawing.mapY or 0) + (point.y or 0),
                })
            end
        end
    elseif drawing.primitiveType == "Polygon" then
        geometry.polygonMode = drawing.polygonMode

        if drawing.polygonMode == "circle" then
            geometry.radius = drawing.radius
            geometry.center = { x = geometry.x, y = 0, z = geometry.z }
        elseif drawing.polygonMode == "rect" then
            geometry.width = drawing.width
            geometry.height = drawing.height
            geometry.angle = drawing.angle or 0
            geometry.center = { x = geometry.x, y = 0, z = geometry.z }
        elseif drawing.polygonMode == "oval" then
            geometry.r1 = drawing.r1
            geometry.r2 = drawing.r2
            geometry.angle = drawing.angle or 0
            geometry.center = { x = geometry.x, y = 0, z = geometry.z }
        elseif drawing.polygonMode == "arrow" then
            geometry.length = drawing.length
            geometry.angle = drawing.angle or 0
            geometry.points = {}

            if drawing.points then
                for i, point in ipairs(drawing.points) do
                    table.insert(geometry.points, {
                        x = (drawing.mapX or 0) + (point.x or 0),
                        y = 0,
                        z = (drawing.mapY or 0) + (point.y or 0),
                    })
                end
            end
        elseif drawing.polygonMode == "free" and drawing.points then
            geometry.points = {}
            for i, point in ipairs(drawing.points) do
                table.insert(geometry.points, {
                    x = (drawing.mapX or 0) + (point.x or 0),
                    y = 0,
                    z = (drawing.mapY or 0) + (point.y or 0),
                })
            end
        end
    elseif drawing.primitiveType == "Icon" then
        geometry.file = drawing.file
        geometry.scale = drawing.scale or 1
        geometry.angle = drawing.angle or 0
        geometry.position = { x = geometry.x, y = 0, z = geometry.z }
    end

    -- Store color information if available
    if drawing.colorString then
        geometry.color = drawing.colorString
    end
    if drawing.fillColorString then
        geometry.fillColor = drawing.fillColorString
    end

    return geometry
end

--- Initialize drawing cache
---@return boolean success True if cache initialized successfully
function InitializeDrawingCache()
    if not _HarnessInternal.cache then
        _HarnessInternal.cache = {}
    end

    _HarnessInternal.cache.drawings = {
        all = {},
        byName = {},
        byType = {},
        byLayer = {},
    }

    -- Get mission drawings
    local missionDrawings = GetDrawings()
    if not missionDrawings then
        _HarnessInternal.log.warning("No drawings found in mission", "Drawing.InitializeCache")
        return true
    end

    -- Process each layer
    if missionDrawings.layers then
        for _, layer in pairs(missionDrawings.layers) do
            if layer.objects then
                for _, drawing in pairs(layer.objects) do
                    local geometry = ProcessDrawingGeometry(drawing)
                    if geometry then
                        -- Store in all
                        table.insert(_HarnessInternal.cache.drawings.all, geometry)

                        -- Index by name
                        if geometry.name then
                            _HarnessInternal.cache.drawings.byName[geometry.name] = geometry
                        end

                        -- Index by type
                        if geometry.type then
                            if not _HarnessInternal.cache.drawings.byType[geometry.type] then
                                _HarnessInternal.cache.drawings.byType[geometry.type] = {}
                            end
                            table.insert(
                                _HarnessInternal.cache.drawings.byType[geometry.type],
                                geometry
                            )
                        end

                        -- Index by layer
                        if geometry.layerName then
                            if not _HarnessInternal.cache.drawings.byLayer[geometry.layerName] then
                                _HarnessInternal.cache.drawings.byLayer[geometry.layerName] = {}
                            end
                            table.insert(
                                _HarnessInternal.cache.drawings.byLayer[geometry.layerName],
                                geometry
                            )
                        end
                    end
                end
            end
        end
    end

    _HarnessInternal.log.info(
        "Drawing cache initialized with " .. #_HarnessInternal.cache.drawings.all .. " drawings",
        "Drawing.InitializeCache"
    )
    return true
end

--- Get all cached drawings
---@return table Array of all drawing geometries
function GetAllDrawings()
    if not _HarnessInternal.cache or not _HarnessInternal.cache.drawings then
        InitializeDrawingCache()
    end

    return _HarnessInternal.cache.drawings.all or {}
end

--- Get drawing by exact name
---@param name string Drawing name
---@return table? drawing Drawing geometry or nil if not found
function GetDrawingByName(name)
    if not name or type(name) ~= "string" then
        _HarnessInternal.log.error("GetDrawingByName requires valid name", "Drawing.GetByName")
        return nil
    end

    if not _HarnessInternal.cache or not _HarnessInternal.cache.drawings then
        InitializeDrawingCache()
    end

    return _HarnessInternal.cache.drawings.byName[name]
end

--- Find drawings by partial name
---@param pattern string Name pattern to search for
---@return table Array of matching drawing geometries
function FindDrawingsByName(pattern)
    if not pattern or type(pattern) ~= "string" then
        _HarnessInternal.log.error(
            "FindDrawingsByName requires valid pattern",
            "Drawing.FindByName"
        )
        return {}
    end

    if not _HarnessInternal.cache or not _HarnessInternal.cache.drawings then
        InitializeDrawingCache()
    end

    local results = {}
    local lowerPattern = string.lower(pattern)

    for _, drawing in ipairs(_HarnessInternal.cache.drawings.all) do
        if drawing.name and string.find(string.lower(drawing.name), lowerPattern, 1, true) then
            table.insert(results, drawing)
        end
    end

    return results
end

--- Get all drawings of a specific type
---@param drawingType string Drawing type (Line, Polygon, Icon)
---@return table Array of drawing geometries of the specified type
function GetDrawingsByType(drawingType)
    if not drawingType or type(drawingType) ~= "string" then
        _HarnessInternal.log.error("GetDrawingsByType requires valid type", "Drawing.GetByType")
        return {}
    end

    if not _HarnessInternal.cache or not _HarnessInternal.cache.drawings then
        InitializeDrawingCache()
    end

    return _HarnessInternal.cache.drawings.byType[drawingType] or {}
end

--- Get all drawings in a specific layer
---@param layerName string Layer name
---@return table Array of drawing geometries in the specified layer
function GetDrawingsByLayer(layerName)
    if not layerName or type(layerName) ~= "string" then
        _HarnessInternal.log.error(
            "GetDrawingsByLayer requires valid layer name",
            "Drawing.GetByLayer"
        )
        return {}
    end

    if not _HarnessInternal.cache or not _HarnessInternal.cache.drawings then
        InitializeDrawingCache()
    end

    return _HarnessInternal.cache.drawings.byLayer[layerName] or {}
end

--- Check if a point is inside a drawing shape
---@param drawing table Drawing geometry
---@param point table Point with x, z coordinates
---@return boolean isInside True if point is inside the shape
function IsPointInDrawing(drawing, point)
    if not drawing or not point then
        return false
    end

    if drawing.type == "Polygon" then
        if drawing.polygonMode == "circle" and drawing.center and drawing.radius then
            local dx = point.x - drawing.center.x
            local dz = point.z - drawing.center.z
            return (dx * dx + dz * dz) <= (drawing.radius * drawing.radius)
        elseif
            drawing.polygonMode == "rect"
            and drawing.center
            and drawing.width
            and drawing.height
        then
            -- Simple axis-aligned check (ignoring rotation for now)
            local halfWidth = drawing.width / 2
            local halfHeight = drawing.height / 2
            local dx = math.abs(point.x - drawing.center.x)
            local dz = math.abs(point.z - drawing.center.z)
            return dx <= halfWidth and dz <= halfHeight
        elseif drawing.points and #drawing.points >= 3 then
            -- Point-in-polygon test using ray casting algorithm
            local x, z = point.x, point.z
            local inside = false
            local j = #drawing.points

            for i = 1, #drawing.points do
                local xi, zi = drawing.points[i].x, drawing.points[i].z
                local xj, zj = drawing.points[j].x, drawing.points[j].z

                if ((zi > z) ~= (zj > z)) and (x < (xj - xi) * (z - zi) / (zj - zi) + xi) then
                    inside = not inside
                end
                j = i
            end

            return inside
        end
    elseif
        drawing.type == "Line"
        and drawing.closed
        and drawing.points
        and #drawing.points >= 3
    then
        -- Closed lines form polygons, use same algorithm
        local x, z = point.x, point.z
        local inside = false
        local j = #drawing.points

        for i = 1, #drawing.points do
            local xi, zi = drawing.points[i].x, drawing.points[i].z
            local xj, zj = drawing.points[j].x, drawing.points[j].z

            if ((zi > z) ~= (zj > z)) and (x < (xj - xi) * (z - zi) / (zj - zi) + xi) then
                inside = not inside
            end
            j = i
        end

        return inside
    end

    return false
end

--- Calculate bounding sphere for a set of points
---@param points table Array of points with x, z coordinates
---@return table center Center point of bounding sphere
---@return number radius Radius of bounding sphere
local function CalculateDrawingBoundingSphere(points)
    if not points or #points == 0 then
        return { x = 0, y = 0, z = 0 }, 0
    end

    -- Find centroid
    local sumX, sumZ = 0, 0
    for _, point in ipairs(points) do
        sumX = sumX + (point.x or 0)
        sumZ = sumZ + (point.z or 0)
    end

    local center = {
        x = sumX / #points,
        y = 0,
        z = sumZ / #points,
    }

    -- Find maximum distance from center
    local maxDist = 0
    for _, point in ipairs(points) do
        local dx = (point.x or 0) - center.x
        local dz = (point.z or 0) - center.z
        local dist = math.sqrt(dx * dx + dz * dz)
        if dist > maxDist then
            maxDist = dist
        end
    end

    return center, maxDist
end

--- Get units in drawing
---@param drawingName string The name of the drawing
---@param coalitionId number? Optional coalition ID to filter by (0=neutral, 1=red, 2=blue)
---@return table units Array of unit objects found in drawing
---@usage local units = GetUnitsInDrawing("Target Area", coalition.side.RED)
function GetUnitsInDrawing(drawingName, coalitionId)
    local unitsInDrawing = {}

    -- Get drawing geometry
    local drawing = GetDrawingByName(drawingName)
    if not drawing then
        return {}
    end

    -- Create search volume based on drawing type
    local searchVolume
    if drawing.type == "Polygon" then
        if drawing.polygonMode == "circle" and drawing.center and drawing.radius then
            -- For circular drawings, use sphere volume with 1.5x radius for search
            searchVolume = CreateSphereVolume(drawing.center, drawing.radius * 1.5)
        elseif
            drawing.polygonMode == "rect"
            and drawing.center
            and drawing.width
            and drawing.height
        then
            -- For rectangles, calculate bounding sphere with 1.5x radius
            local halfWidth = drawing.width / 2
            local halfHeight = drawing.height / 2
            local radius = math.sqrt(halfWidth * halfWidth + halfHeight * halfHeight) * 1.5
            searchVolume = CreateSphereVolume(drawing.center, radius)
        elseif drawing.points and #drawing.points >= 3 then
            -- For polygon drawings, calculate bounding sphere with 1.5x radius
            local center, radius = CalculateDrawingBoundingSphere(drawing.points)
            searchVolume = CreateSphereVolume(center, radius * 1.5)
        else
            return {}
        end
    elseif
        drawing.type == "Line"
        and drawing.closed
        and drawing.points
        and #drawing.points >= 3
    then
        -- Closed lines form polygons
        local center, radius = CalculateDrawingBoundingSphere(drawing.points)
        searchVolume = CreateSphereVolume(center, radius * 1.5)
    else
        return {}
    end

    if not searchVolume then
        return {}
    end

    -- Handler function for found objects
    local function handleUnit(unit, data)
        if not unit then
            return true
        end

        -- Check coalition filter
        if coalitionId then
            local unitCoalition = GetUnitCoalition(unit)
            if unitCoalition ~= coalitionId then
                return true
            end
        end

        -- Get unit position for precise drawing check
        local pos = GetUnitPosition(unit)
        if pos then
            local point = { x = pos.x, z = pos.z }

            -- Check if unit is actually in the drawing (not just the bounding sphere)
            if IsPointInDrawing(drawing, point) then
                table.insert(unitsInDrawing, unit)
            end
        end

        return true
    end

    -- Search for units in the volume
    -- Object.Category.UNIT = 1 in DCS
    SearchWorldObjects(1, searchVolume, handleUnit)

    return unitsInDrawing
end

--- Get drawings containing a specific point
---@param point table Point with x, z coordinates
---@param drawingType string? Optional filter by drawing type
---@return table drawings Array of drawings containing the point
---@usage local drawings = GetDrawingsAtPoint({x=1000, z=2000})
function GetDrawingsAtPoint(point, drawingType)
    if not point or type(point) ~= "table" or not point.x or not point.z then
        _HarnessInternal.log.error(
            "GetDrawingsAtPoint requires valid point with x, z",
            "Drawing.GetDrawingsAtPoint"
        )
        return {}
    end

    if not _HarnessInternal.cache or not _HarnessInternal.cache.drawings then
        InitializeDrawingCache()
    end

    local results = {}
    local drawings = drawingType and GetDrawingsByType(drawingType) or GetAllDrawings()

    for _, drawing in ipairs(drawings) do
        if IsPointInDrawing(drawing, point) then
            table.insert(results, drawing)
        end
    end

    return results
end

--- Clear drawing cache
function ClearDrawingCache()
    if _HarnessInternal.cache and _HarnessInternal.cache.drawings then
        _HarnessInternal.cache.drawings = {
            all = {},
            byName = {},
            byType = {},
            byLayer = {},
        }
    end
end
-- ==== END: src/drawing.lua ====

-- ==== BEGIN: src/zone.lua ====
--[[
==================================================================================================
    ZONE MODULE
    Trigger zone utilities with caching support
    
    This module provides:
    - Runtime DCS API access to trigger zones (with cache-first lookups)
    - Mission trigger zone caching for fast queries
    - Spatial queries for units and points in zones
    - Support for both circular and polygon zones
==================================================================================================
]]

--- Get zone by name
---@param zoneName string The name of the zone to retrieve
---@return table? zone The zone object if found, nil otherwise
---@usage local zone = GetZone("LZ Alpha")
function GetZone(zoneName)
    if not zoneName or type(zoneName) ~= "string" then
        _HarnessInternal.log.error("GetZone requires string zone name", "GetZone")
        return nil
    end

    -- Check cache first
    if _HarnessInternal.cache and _HarnessInternal.cache.triggerZones then
        local cachedZone = _HarnessInternal.cache.triggerZones.byName[zoneName]
        if cachedZone then
            -- Convert cached format to DCS API format
            if cachedZone.type == "circle" then
                return {
                    point = cachedZone.center or { x = 0, y = 0, z = 0 },
                    radius = cachedZone.radius or 0,
                }
            elseif cachedZone.type == "polygon" and cachedZone.points then
                -- For polygon zones, return the first point as center with radius 0
                -- This matches DCS behavior for polygon zones
                return {
                    point = cachedZone.points[1] or { x = 0, y = 0, z = 0 },
                    radius = 0,
                    vertices = cachedZone.points,
                }
            end
        end
    end

    -- Fall back to API call
    local success, zone = pcall(trigger.misc.getZone, zoneName)
    if not success then
        _HarnessInternal.log.error("Failed to get zone: " .. tostring(zone), "GetZone")
        return nil
    end

    return zone
end

--- Get zone position
---@param zoneName string The name of the zone
---@return table? position The zone center position as Vec3 if found, nil otherwise
---@usage local pos = GetZonePosition("LZ Alpha")
function GetZonePosition(zoneName)
    local zone = GetZone(zoneName)
    if not zone then
        return nil
    end

    return Vec3(zone.point.x, zone.point.y, zone.point.z)
end

--- Get zone radius
---@param zoneName string The name of the zone
---@return number? radius The zone radius if found, nil otherwise
---@usage local radius = GetZoneRadius("LZ Alpha")
function GetZoneRadius(zoneName)
    local zone = GetZone(zoneName)
    if not zone then
        return nil
    end

    return zone.radius
end

--- Check if point is in zone
---@param position table Vec3 position to check
---@param zoneName string The name of the zone
---@return boolean inZone True if position is within zone (handles both circular and polygon zones)
---@usage if IsInZone(pos, "LZ Alpha") then ... end
function IsInZone(position, zoneName)
    if not IsVec3(position) then
        _HarnessInternal.log.error("IsInZone requires Vec3 position", "IsInZone")
        return false
    end

    -- Try to use cached zone geometry first for polygon support
    if _HarnessInternal.cache and _HarnessInternal.cache.triggerZones then
        local cachedZone = _HarnessInternal.cache.triggerZones.byName[zoneName]
        if cachedZone then
            return IsPointInZoneGeometry(cachedZone, { x = position.x, z = position.z })
        end
    end

    -- Fall back to API zone (only works for circular zones)
    local zone = GetZone(zoneName)
    if not zone then
        return false
    end

    -- Check if zone has vertices (polygon)
    if zone.vertices and #zone.vertices >= 3 then
        return IsInPolygonZone(position, zone.vertices)
    end

    -- Standard circular zone check
    local zonePos = Vec3(zone.point.x, zone.point.y, zone.point.z)
    local distance = Distance2D(position, zonePos)

    return distance <= zone.radius
end

--- Check if unit is in zone
---@param unitName string The name of the unit
---@param zoneName string The name of the zone
---@return boolean inZone True if unit is within zone radius
---@usage if IsUnitInZone("Player", "LZ Alpha") then ... end
function IsUnitInZone(unitName, zoneName)
    local position = GetUnitPosition(unitName)
    if not position then
        return false
    end

    return IsInZone(position, zoneName)
end

--- Check if group is in zone (any unit)
---@param groupName string The name of the group
---@param zoneName string The name of the zone
---@return boolean inZone True if any unit of the group is in zone
---@usage if IsGroupInZone("Aerial-1", "LZ Alpha") then ... end
function IsGroupInZone(groupName, zoneName)
    local units = GetGroupUnits(groupName)
    if not units then
        return false
    end

    for _, unit in ipairs(units) do
        local success, unitName = pcall(unit.getName, unit)
        if success and unitName then
            if IsUnitInZone(unitName, zoneName) then
                return true
            end
        end
    end

    return false
end

--- Check if entire group is in zone (all units)
---@param groupName string The name of the group
---@param zoneName string The name of the zone
---@return boolean inZone True if all units of the group are in zone
---@usage if IsGroupCompletelyInZone("Aerial-1", "LZ Alpha") then ... end
function IsGroupCompletelyInZone(groupName, zoneName)
    local units = GetGroupUnits(groupName)
    if not units or #units == 0 then
        return false
    end

    for _, unit in ipairs(units) do
        local success, unitName = pcall(unit.getName, unit)
        if success and unitName then
            if not IsUnitInZone(unitName, zoneName) then
                return false
            end
        end
    end

    return true
end

--- Calculate bounding sphere for a set of points
---@param points table Array of points with x, z coordinates
---@return table center Center point of bounding sphere
---@return number radius Radius of bounding sphere
local function CalculateZoneBoundingSphere(points)
    if not points or #points == 0 then
        return { x = 0, y = 0, z = 0 }, 0
    end

    -- Find centroid
    local sumX, sumZ = 0, 0
    for _, point in ipairs(points) do
        sumX = sumX + (point.x or 0)
        sumZ = sumZ + (point.z or 0)
    end

    local center = {
        x = sumX / #points,
        y = 0,
        z = sumZ / #points,
    }

    -- Find maximum distance from center
    local maxDist = 0
    for _, point in ipairs(points) do
        local dx = (point.x or 0) - center.x
        local dz = (point.z or 0) - center.z
        local dist = math.sqrt(dx * dx + dz * dz)
        if dist > maxDist then
            maxDist = dist
        end
    end

    return center, maxDist
end

--- Get units in zone
---@param zoneName string The name of the zone
---@param coalitionId number? Optional coalition ID to filter by (0=neutral, 1=red, 2=blue)
---@return table units Array of unit objects found in zone
---@usage local units = GetUnitsInZone("LZ Alpha", coalition.side.BLUE)
function GetUnitsInZone(zoneName, coalitionId)
    local unitsInZone = {}

    -- Get zone geometry
    local zone = nil

    -- Try to use cached zone geometry first for better performance
    if _HarnessInternal.cache and _HarnessInternal.cache.triggerZones then
        zone = _HarnessInternal.cache.triggerZones.byName[zoneName]
    end

    -- Fall back to API zone
    if not zone then
        local apiZone = GetZone(zoneName)
        if not apiZone then
            return {}
        end

        -- Convert API zone to our geometry format
        zone = {
            type = "circle",
            center = apiZone.point,
            radius = apiZone.radius or 0,
        }
    end

    -- Create search volume based on zone type
    local searchVolume
    if zone.type == "circle" and zone.center and zone.radius then
        -- For circular zones, use sphere volume with 1.5x radius for search
        searchVolume = CreateSphereVolume(zone.center, zone.radius * 1.5)
    elseif zone.type == "polygon" and zone.points and #zone.points >= 3 then
        -- For polygon zones, calculate bounding sphere with 1.5x radius
        local center, radius = CalculateZoneBoundingSphere(zone.points)
        searchVolume = CreateSphereVolume(center, radius * 1.5)
    else
        return {}
    end

    if not searchVolume then
        return {}
    end

    -- Handler function for found objects
    local function handleUnit(unit, data)
        if not unit then
            return true
        end

        -- Check coalition filter
        if coalitionId then
            local unitCoalition = GetUnitCoalition(unit)
            if unitCoalition ~= coalitionId then
                return true
            end
        end

        -- Get unit position for precise zone check
        local pos = GetUnitPosition(unit)
        if pos then
            local point = { x = pos.x, z = pos.z }

            -- Check if unit is actually in the zone (not just the bounding sphere)
            if IsPointInZoneGeometry(zone, point) then
                table.insert(unitsInZone, unit)
            end
        end

        return true
    end

    -- Search for units in the volume
    -- Object.Category.UNIT = 1 in DCS
    SearchWorldObjects(1, searchVolume, handleUnit)

    return unitsInZone
end

--- Get groups in zone
---@param zoneName string The name of the zone
---@param coalitionId number? Optional coalition ID to filter by (0=neutral, 1=red, 2=blue)
---@return table groups Array of group objects found in zone
---@usage local groups = GetGroupsInZone("LZ Alpha", coalition.side.BLUE)
function GetGroupsInZone(zoneName, coalitionId)
    local zone = GetZone(zoneName)
    if not zone then
        return {}
    end

    local groupsInZone = {}
    local groupsAdded = {}

    -- Get all groups for the coalition (or all coalitions if not specified)
    local coalitions = coalitionId and { coalitionId } or { 0, 1, 2 }

    for _, coal in ipairs(coalitions) do
        -- Check all categories
        for _, category in ipairs({
            Group.Category.AIRPLANE,
            Group.Category.HELICOPTER,
            Group.Category.GROUND,
            Group.Category.SHIP,
        }) do
            local groups = GetCoalitionGroups(coal, category)

            for _, group in ipairs(groups) do
                local success, groupName = pcall(group.getName, group)
                if success and groupName and not groupsAdded[groupName] then
                    if IsGroupInZone(groupName, zoneName) then
                        table.insert(groupsInZone, group)
                        groupsAdded[groupName] = true
                    end
                end
            end
        end
    end

    return groupsInZone
end

--- Create random position in zone
---@param zoneName string The name of the zone
---@param inner number? Minimum distance from center (default 0)
---@param outer number? Maximum distance from center (default zone radius)
---@return table? position Random Vec3 position within zone, nil if zone not found
---@usage local randPos = RandomPointInZone("LZ Alpha", 100, 500)
function RandomPointInZone(zoneName, inner, outer)
    local zone = GetZone(zoneName)
    if not zone then
        return nil
    end

    inner = inner or 0
    outer = outer or zone.radius

    -- Random angle
    local angle = math.random() * 2 * math.pi

    -- Random distance between inner and outer radius
    local distance = inner + math.random() * (outer - inner)

    -- Calculate position
    local x = zone.point.x + distance * math.cos(angle)
    local z = zone.point.z + distance * math.sin(angle)

    return Vec3(x, zone.point.y, z)
end

--- Check if point is in polygon zone
---@param point table Vec3 position to check
---@param vertices table Array of Vec3 vertices defining the polygon
---@return boolean inZone True if point is inside the polygon
---@usage if IsInPolygonZone(pos, {v1, v2, v3, v4}) then ... end
function IsInPolygonZone(point, vertices)
    if not IsVec3(point) or not vertices or type(vertices) ~= "table" then
        _HarnessInternal.log.error(
            "IsInPolygonZone requires Vec3 point and vertices table",
            "IsInPolygonZone"
        )
        return false
    end

    -- Ray casting algorithm for point-in-polygon test
    local x, z = point.x, point.z
    local inside = false
    local j = #vertices

    for i = 1, #vertices do
        local xi, zi = vertices[i].x, vertices[i].z
        local xj, zj = vertices[j].x, vertices[j].z

        if ((zi > z) ~= (zj > z)) and (x < (xj - xi) * (z - zi) / (zj - zi) + xi) then
            inside = not inside
        end
        j = i
    end

    return inside
end

-- ==================================================================================================
-- ZONE CACHING FUNCTIONALITY
-- Cache trigger zones from mission for fast lookups
-- ==================================================================================================

--- Get all trigger zones from the mission
---@return table? zones Array of trigger zone data or nil on error
function GetMissionZones()
    local success, result = pcall(function()
        if env.mission and env.mission.triggers and env.mission.triggers.zones then
            return env.mission.triggers.zones
        end
        return nil
    end)

    if not success then
        _HarnessInternal.log.error(
            "Failed to get mission zones: " .. tostring(result),
            "Zone.GetMissionZones"
        )
        return nil
    end

    return result
end

--- Process trigger zone geometry from mission data
---@param zone table Trigger zone data
---@return table? geometry Processed zone geometry or nil
function ProcessZoneGeometry(zone)
    if not zone or type(zone) ~= "table" then
        return nil
    end

    -- Skip zones attached to units (they move)
    if zone.linkUnit then
        return nil
    end

    local geometry = {
        name = zone.name,
        zoneId = zone.zoneId,
        hidden = zone.hidden,
        color = zone.color,
        properties = zone.properties or {},
    }

    -- Zone type: 0 = circular, 2 = quadpoint
    if zone.type == 0 then
        -- Circular zone
        geometry.type = "circle"
        geometry.center = {
            x = zone.x or 0,
            y = 0,
            z = zone.y or 0, -- Note: mission y is DCS z
        }
        geometry.radius = zone.radius or 0
    elseif zone.type == 2 and zone.verticies then
        -- Quadpoint/polygon zone
        geometry.type = "polygon"
        geometry.points = {}

        -- Check if vertices appear to be absolute or relative coordinates
        -- If any vertex coordinate is very large (>10000), assume absolute coordinates
        local useAbsolute = false
        for _, vertex in ipairs(zone.verticies) do
            if math.abs(vertex.x or 0) > 10000 or math.abs(vertex.y or 0) > 10000 then
                useAbsolute = true
                break
            end
        end

        -- Zone center position
        local centerX = zone.x or 0
        local centerZ = zone.y or 0 -- Mission y is DCS z

        for i, vertex in ipairs(zone.verticies) do
            if useAbsolute then
                -- Vertices are absolute coordinates
                table.insert(geometry.points, {
                    x = vertex.x or 0,
                    y = 0,
                    z = vertex.y or 0, -- Note: mission y is DCS z
                })
            else
                -- Vertices are relative to center
                table.insert(geometry.points, {
                    x = centerX + (vertex.x or 0),
                    y = 0,
                    z = centerZ + (vertex.y or 0), -- Note: mission y is DCS z
                })
            end
        end
    else
        -- Unknown zone type
        return nil
    end

    return geometry
end

--- Initialize trigger zone cache
---@return boolean success True if cache initialized successfully
function InitializeZoneCache()
    if not _HarnessInternal.cache then
        _HarnessInternal.cache = {}
    end

    _HarnessInternal.cache.triggerZones = {
        all = {},
        byName = {},
        byId = {},
        byType = {},
    }

    -- Get mission trigger zones
    local zones = GetMissionZones()
    if not zones then
        _HarnessInternal.log.warning("No zones found in mission", "Zone.InitializeCache")
        return true
    end

    -- Process each zone
    for _, zone in pairs(zones) do
        local geometry = ProcessZoneGeometry(zone)
        if geometry then
            -- Store in all
            table.insert(_HarnessInternal.cache.triggerZones.all, geometry)

            -- Index by name
            if geometry.name then
                _HarnessInternal.cache.triggerZones.byName[geometry.name] = geometry
            end

            -- Index by ID
            if geometry.zoneId then
                _HarnessInternal.cache.triggerZones.byId[geometry.zoneId] = geometry
            end

            -- Index by type
            if geometry.type then
                if not _HarnessInternal.cache.triggerZones.byType[geometry.type] then
                    _HarnessInternal.cache.triggerZones.byType[geometry.type] = {}
                end
                table.insert(_HarnessInternal.cache.triggerZones.byType[geometry.type], geometry)
            end
        end
    end

    _HarnessInternal.log.info(
        "Zone cache initialized with " .. #_HarnessInternal.cache.triggerZones.all .. " zones",
        "Zone.InitializeCache"
    )
    return true
end

--- Get all cached trigger zones
---@return table Array of all trigger zone geometries
function GetAllZones()
    if not _HarnessInternal.cache or not _HarnessInternal.cache.triggerZones then
        InitializeZoneCache()
    end

    return _HarnessInternal.cache.triggerZones.all or {}
end

--- Get cached trigger zone by exact name
---@param name string Zone name
---@return table? zone Trigger zone geometry or nil if not found
function GetCachedZoneByName(name)
    if not name or type(name) ~= "string" then
        _HarnessInternal.log.error(
            "GetCachedZoneByName requires valid name",
            "Zone.GetCachedByName"
        )
        return nil
    end

    if not _HarnessInternal.cache or not _HarnessInternal.cache.triggerZones then
        InitializeZoneCache()
    end

    return _HarnessInternal.cache.triggerZones.byName[name]
end

--- Get cached trigger zone by ID
---@param zoneId number Zone ID
---@return table? zone Trigger zone geometry or nil if not found
function GetCachedZoneById(zoneId)
    if not zoneId or type(zoneId) ~= "number" then
        _HarnessInternal.log.error("GetCachedZoneById requires valid ID", "Zone.GetCachedById")
        return nil
    end

    if not _HarnessInternal.cache or not _HarnessInternal.cache.triggerZones then
        InitializeZoneCache()
    end

    return _HarnessInternal.cache.triggerZones.byId[zoneId]
end

--- Find cached trigger zones by partial name
---@param pattern string Name pattern to search for
---@return table Array of matching zone geometries
function FindZonesByName(pattern)
    if not pattern or type(pattern) ~= "string" then
        _HarnessInternal.log.error("FindZonesByName requires valid pattern", "Zone.FindByName")
        return {}
    end

    if not _HarnessInternal.cache or not _HarnessInternal.cache.triggerZones then
        InitializeZoneCache()
    end

    local results = {}
    local lowerPattern = string.lower(pattern)

    for _, zone in ipairs(_HarnessInternal.cache.triggerZones.all) do
        if zone.name and string.find(string.lower(zone.name), lowerPattern, 1, true) then
            table.insert(results, zone)
        end
    end

    return results
end

--- Get all cached trigger zones of a specific type
---@param zoneType string Zone type (circle, polygon)
---@return table Array of zone geometries of the specified type
function GetZonesByType(zoneType)
    if not zoneType or type(zoneType) ~= "string" then
        _HarnessInternal.log.error("GetZonesByType requires valid type", "Zone.GetByType")
        return {}
    end

    if not _HarnessInternal.cache or not _HarnessInternal.cache.triggerZones then
        InitializeZoneCache()
    end

    return _HarnessInternal.cache.triggerZones.byType[zoneType] or {}
end

--- Check if a point is inside a cached trigger zone
---@param zone table Trigger zone geometry
---@param point table Point with x, z coordinates
---@return boolean isInside True if point is inside the zone
function IsPointInZoneGeometry(zone, point)
    if not zone or not point then
        return false
    end

    if zone.type == "circle" and zone.center and zone.radius then
        local dx = point.x - zone.center.x
        local dz = point.z - zone.center.z
        return (dx * dx + dz * dz) <= (zone.radius * zone.radius)
    elseif zone.type == "polygon" and zone.points and #zone.points >= 3 then
        -- Convert 2D point to 3D for IsInPolygonZone
        local point3d = { x = point.x, y = 0, z = point.z }
        return IsInPolygonZone(point3d, zone.points)
    end

    return false
end

--- Clear trigger zone cache
function ClearZoneCache()
    if _HarnessInternal.cache and _HarnessInternal.cache.triggerZones then
        _HarnessInternal.cache.triggerZones = {
            all = {},
            byName = {},
            byId = {},
            byType = {},
        }
    end
end
-- ==== END: src/zone.lua ====

-- ==== BEGIN: src/shapecache.lua ====
--[[
    ShapeCache Module - Combined cache for drawings and trigger zones
    
    This module provides a unified interface for searching and querying
    both drawings and trigger zones.
]]
--- Initialize all shape caches (drawings and trigger zones)
---@return boolean success True if all caches initialized successfully
function InitializeShapeCache()
    local drawingSuccess = InitializeDrawingCache()
    local zoneSuccess = InitializeZoneCache()

    _HarnessInternal.log.info("Shape cache initialization complete", "ShapeCache.Initialize")
    return drawingSuccess and zoneSuccess
end

--- Get all shapes (drawings and trigger zones)
---@return table shapes Table with drawings and triggerZones arrays
function GetAllShapes()
    return {
        drawings = GetAllDrawings(),
        triggerZones = GetAllZones(),
    }
end

--- Find shapes by name (partial match)
---@param pattern string Name pattern to search for
---@return table results Table with matching drawings and triggerZones
function FindShapesByName(pattern)
    if not pattern or type(pattern) ~= "string" then
        _HarnessInternal.log.error(
            "FindShapesByName requires valid pattern",
            "ShapeCache.FindByName"
        )
        return { drawings = {}, triggerZones = {} }
    end

    return {
        drawings = FindDrawingsByName(pattern),
        triggerZones = FindZonesByName(pattern),
    }
end

--- Get shape by exact name (searches both drawings and zones)
---@param name string Shape name
---@return table? shape Shape data with type field or nil if not found
function GetShapeByName(name)
    if not name or type(name) ~= "string" then
        _HarnessInternal.log.error("GetShapeByName requires valid name", "ShapeCache.GetByName")
        return nil
    end

    -- Check drawings first
    local drawing = GetDrawingByName(name)
    if drawing then
        drawing.shapeType = "drawing"
        return drawing
    end

    -- Check trigger zones
    local zone = GetCachedZoneByName(name)
    if zone then
        zone.shapeType = "triggerZone"
        return zone
    end

    return nil
end

--- Check if a point is inside any named shape
---@param point table Point with x, z coordinates
---@param shapeName string? Optional shape name to check specifically
---@return table results Array of shapes containing the point
function GetShapesAtPoint(point, shapeName)
    if not point or type(point) ~= "table" or not point.x or not point.z then
        _HarnessInternal.log.error(
            "GetShapesAtPoint requires valid point with x, z",
            "ShapeCache.GetShapesAtPoint"
        )
        return {}
    end

    local results = {}

    if shapeName then
        -- Check specific shape
        local shape = GetShapeByName(shapeName)
        if shape then
            local isInside = false
            if shape.shapeType == "drawing" then
                isInside = IsPointInDrawing(shape, point)
            elseif shape.shapeType == "triggerZone" then
                isInside = IsPointInZoneGeometry(shape, point)
            end

            if isInside then
                table.insert(results, shape)
            end
        end
    else
        -- Check all shapes
        local allShapes = GetAllShapes()

        -- Check drawings
        for _, drawing in ipairs(allShapes.drawings) do
            if IsPointInDrawing(drawing, point) then
                drawing.shapeType = "drawing"
                table.insert(results, drawing)
            end
        end

        -- Check trigger zones
        for _, zone in ipairs(allShapes.triggerZones) do
            if IsPointInZoneGeometry(zone, point) then
                zone.shapeType = "triggerZone"
                table.insert(results, zone)
            end
        end
    end

    return results
end

--- Get all circular shapes (both drawings and trigger zones)
---@return table circles Array of circular shapes
function GetAllCircularShapes()
    local circles = {}

    -- Get circular drawings
    local polygons = GetDrawingsByType("Polygon")
    for _, drawing in ipairs(polygons) do
        if drawing.polygonMode == "circle" then
            drawing.shapeType = "drawing"
            table.insert(circles, drawing)
        end
    end

    -- Get circular trigger zones
    local zones = GetZonesByType("circle")
    for _, zone in ipairs(zones) do
        zone.shapeType = "triggerZone"
        table.insert(circles, zone)
    end

    return circles
end

--- Get all polygon shapes (both drawings and trigger zones)
---@return table polygons Array of polygon shapes
function GetAllPolygonShapes()
    local polygons = {}

    -- Get polygon drawings
    local drawings = GetDrawingsByType("Polygon")
    for _, drawing in ipairs(drawings) do
        if drawing.polygonMode == "free" or (drawing.points and #drawing.points >= 3) then
            drawing.shapeType = "drawing"
            table.insert(polygons, drawing)
        end
    end

    -- Get all lines that are closed (forming polygons)
    local lines = GetDrawingsByType("Line")
    for _, line in ipairs(lines) do
        if line.closed and line.points and #line.points >= 3 then
            line.shapeType = "drawing"
            table.insert(polygons, line)
        end
    end

    -- Get polygon trigger zones
    local zones = GetZonesByType("polygon")
    for _, zone in ipairs(zones) do
        zone.shapeType = "triggerZone"
        table.insert(polygons, zone)
    end

    return polygons
end

--- Get units in shape
---@param shapeName string Shape name (drawing or trigger zone)
---@return table Array of units inside the shape
function GetUnitsInShape(shapeName)
    if not shapeName or type(shapeName) ~= "string" then
        _HarnessInternal.log.error(
            "GetUnitsInShape requires valid shape name",
            "ShapeCache.GetUnitsInShape"
        )
        return {}
    end

    local shape = GetShapeByName(shapeName)
    if not shape then
        _HarnessInternal.log.warning("Shape not found: " .. shapeName, "ShapeCache.GetUnitsInShape")
        return {}
    end

    -- If it's a trigger zone, use GetUnitsInZone with the name
    if shape.shapeType == "triggerZone" then
        return GetUnitsInZone(shapeName)
    end

    -- If it's a drawing, use GetUnitsInDrawing
    if shape.shapeType == "drawing" then
        return GetUnitsInDrawing(shapeName)
    end

    -- Fallback - shouldn't reach here
    return {}
end

--- Get shape statistics
---@return table stats Statistics about cached shapes
function GetShapeStatistics()
    local allShapes = GetAllShapes()
    local stats = {
        drawings = {
            total = #allShapes.drawings,
            byType = {},
        },
        triggerZones = {
            total = #allShapes.triggerZones,
            byType = {},
        },
    }

    -- Count drawings by type
    for _, drawing in ipairs(allShapes.drawings) do
        local dtype = drawing.type or "unknown"
        stats.drawings.byType[dtype] = (stats.drawings.byType[dtype] or 0) + 1
    end

    -- Count zones by type
    for _, zone in ipairs(allShapes.triggerZones) do
        local ztype = zone.type or "unknown"
        stats.triggerZones.byType[ztype] = (stats.triggerZones.byType[ztype] or 0) + 1
    end

    return stats
end

--- Clear all shape caches
function ClearShapeCache()
    ClearDrawingCache()
    ClearZoneCache()
end

--- Automatically initialize shape cache on mission start
---@return boolean success
function AutoInitializeShapeCache()
    -- Check if we're in a mission
    local success, hasMission = pcall(function()
        return env and env.mission ~= nil
    end)

    if success and hasMission then
        return InitializeShapeCache()
    end

    return false
end
-- ==== END: src/shapecache.lua ====

