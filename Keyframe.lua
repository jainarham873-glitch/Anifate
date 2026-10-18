local Keyframe = {}

local MAX_KEY_TIME = 600

local function isFinite(value)
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function isKeyTime(time)
	return isFinite(time) and time >= 0 and time <= MAX_KEY_TIME
end

local function isFiniteCFrame(cframe)
	if typeof(cframe) ~= "CFrame" then
		return false
	end
	for _, component in ipairs({ cframe:GetComponents() }) do
		if not isFinite(component) then
			return false
		end
	end
	return true
end

local function roundedTime(time)
	return math.floor(time * 1000 + 0.5) / 1000
end

local function sortedTimes(keys)
	local times = {}
	for time, cframe in pairs(keys) do
		if isKeyTime(time) and isFiniteCFrame(cframe) then
			table.insert(times, time)
		end
	end
	table.sort(times)
	return times
end

function Keyframe.insertKey(state, motorName, time, cframe)
	if type(state) ~= "table" or type(motorName) ~= "string" or motorName == "" then
		return false, "A state table and nonempty track name are required"
	end
	if not isKeyTime(time) then
		return false, "Key time must be finite and between 0 and 600 seconds"
	end
	if not isFiniteCFrame(cframe) then
		return false, "Key value must be a CFrame with finite components"
	end
	if state.keys ~= nil and type(state.keys) ~= "table" then
		return false, "state.keys must be a table"
	end
	local motorKeys = state.keys and state.keys[motorName]
	if motorKeys ~= nil and type(motorKeys) ~= "table" then
		return false, "Track keys must be a table"
	end

	-- Track names are generic: @Rig is the owner's original-pivot-relative offset.
	state.keys = state.keys or {}
	state.keys[motorName] = motorKeys or {}
	state.keys[motorName][roundedTime(time)] = cframe
	Keyframe.recomputeMaxTime(state)
	return true
end

function Keyframe.deleteKey(state, motorName, time)
	if type(state) ~= "table" or type(motorName) ~= "string" or motorName == "" then
		return false
	end
	if not isKeyTime(time) then
		return false, "Key time must be finite and between 0 and 600 seconds"
	end

	local motorKeys = Keyframe.getKeys(state, motorName)
	local keyTime = roundedTime(time)
	if motorKeys[keyTime] == nil then
		return false
	end

	motorKeys[keyTime] = nil
	Keyframe.recomputeMaxTime(state)
	return true
end

function Keyframe.getKeys(state, motorName)
	if type(state) ~= "table" or type(motorName) ~= "string" then
		return {}
	end
	if type(state.keys) ~= "table" or type(state.keys[motorName]) ~= "table" then
		return {}
	end
	return state.keys[motorName]
end

function Keyframe.sampleAt(state, motorName, time)
	local keys = Keyframe.getKeys(state, motorName)
	local times = sortedTimes(keys)
	if #times == 0 then
		return CFrame.identity
	end

	local sampleTime = time
	if not isFinite(sampleTime) then
		sampleTime = times[1]
	end
	if sampleTime <= times[1] then
		return keys[times[1]]
	end
	if sampleTime >= times[#times] then
		return keys[times[#times]]
	end

	for index = 1, #times - 1 do
		local time0 = times[index]
		local time1 = times[index + 1]
		if sampleTime >= time0 and sampleTime <= time1 then
			if time0 == time1 then
				return keys[time1]
			end
			local alpha = (sampleTime - time0) / (time1 - time0)
			return keys[time0]:Lerp(keys[time1], alpha)
		end
	end

	return keys[times[#times]]
end

function Keyframe.recomputeMaxTime(state)
	if type(state) ~= "table" then
		return 1
	end

	local latest = 0
	local keyCounts = {}
	if type(state.keys) == "table" then
		for motorName, motorKeys in pairs(state.keys) do
			if type(motorName) == "string" and type(motorKeys) == "table" then
				local count = 0
				for time, cframe in pairs(motorKeys) do
					if isKeyTime(time) and isFiniteCFrame(cframe) then
						count = count + 1
						latest = math.max(latest, time)
					end
				end
				keyCounts[motorName] = count
			end
		end
	end

	local duration = isFinite(state.duration) and state.duration or 1
	local maximum = math.max(1, duration, latest)
	local currentTime = isFinite(state.currentTime) and state.currentTime or 0
	state.keyCounts = keyCounts
	state.minTime = 0
	state.maxTime = maximum
	state.currentTime = math.clamp(currentTime, 0, maximum)
	return maximum
end

return Keyframe
