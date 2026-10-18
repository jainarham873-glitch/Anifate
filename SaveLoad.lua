local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SaveLoad = {}

local MAX_KEY_TIME = 600

local function isFinite(value)
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function uniqueChild(parent, name)
	local found = nil
	for _, child in ipairs(parent:GetChildren()) do
		if child.Name == name then
			if found then
				error("Duplicate entry: " .. name, 0)
			end
			found = child
		end
	end
	return found
end

local function getLegacySaveRoot()
	local root = uniqueChild(ReplicatedStorage, "AnifateSaves")
	if root and not root:IsA("Folder") then
		error("ReplicatedStorage.AnifateSaves must be a Folder", 0)
	end
	return root
end

local function getRigSaveRoot(state, createIfMissing)
	if type(state) ~= "table" or typeof(state.rig) ~= "Instance" then
		error("No rig selected: rig-local animation storage requires a selected rig", 0)
	end
	local root = uniqueChild(state.rig, "AnifateAnimations")
	if root and not root:IsA("Folder") then
		error("Selected rig.AnifateAnimations must be a Folder", 0)
	end
	if not root and createIfMissing then
		root = Instance.new("Folder")
		root.Name = "AnifateAnimations"
		root.Archivable = true
		root.Parent = state.rig
	end
	return root
end

local function normalizedName(name)
	if type(name) ~= "string" then
		return ""
	end
	return name:gsub("^%s+", ""):gsub("%s+$", "")
end

local function validateRig(state)
	if type(state) ~= "table" or typeof(state.rig) ~= "Instance" or not (state.rig:IsA("Model") or state.rig:IsA("BasePart")) then
		error("No rig selected: select a Model or MeshPart", 0)
	end
	if not state.rig.Parent then
		error("Selected rig is no longer parented", 0)
	end

	local ids, joints
	if state.resolveTracks ~= nil then
		if type(state.resolveTracks) ~= "function" then
			error("state.resolveTracks must be a function", 0)
		end
		-- The owner is the authority for canonical IDs, including duplicate/reserved names.
		local labels
		ids, labels, joints = state.resolveTracks(state.rig)
		if type(ids) ~= "table" or type(labels) ~= "table" or type(joints) ~= "table" then
			error("Rig resolver must return ID and label maps and a joint array", 0)
		end
	else
		-- Legacy states have no naming adapter, so only unambiguous ordinary names work.
		ids, joints = {}, {}
		for _, descendant in ipairs(state.rig:GetDescendants()) do
			if descendant:IsA("Motor6D") or descendant:IsA("AnimationConstraint") or descendant:IsA("Bone") then
				if descendant:IsA("Motor6D") or descendant:IsA("AnimationConstraint") then
					local part0, part1 = descendant.Part0, descendant.Part1
					if not part0 or not part1 or part0 == part1
						or not (part0 == state.rig or part0:IsDescendantOf(state.rig))
						or not (part1 == state.rig or part1:IsDescendantOf(state.rig)) then
						error("Motor6D must connect two distinct parts within the selected rig: " .. descendant.Name, 0)
					end
				else
					local parent = descendant.Parent
					if not parent or not (parent:IsA("Bone") or parent:IsA("BasePart")) then
						error("Bone must be parented to a Bone or BasePart: " .. descendant.Name, 0)
					end
				end
				local name = descendant.Name
				if name == "" or name == "meta" or name:sub(1, 1) == "@" then
					error("Joint has an empty or reserved name: " .. name, 0)
				end
				ids[descendant] = name
				table.insert(joints, descendant)
			end
		end
	end

	local motorNames, inventory = { ["@Rig"] = true }, {}
	for _, joint in ipairs(joints) do
		if typeof(joint) ~= "Instance" or not (joint:IsA("Motor6D") or joint:IsA("AnimationConstraint") or joint:IsA("Bone"))
			or not joint:IsDescendantOf(state.rig) or inventory[joint] then
			error("Invalid joint inventory for selected rig", 0)
		end
		local id = ids[joint]
		if type(id) ~= "string" or id == "" or id == "meta" or id == "@Rig" then
			error("Joint track IDs must be nonempty, nonreserved strings", 0)
		end
		if motorNames[id] then
			error("Duplicate joint track ID in selected rig: " .. id, 0)
		end
		motorNames[id], inventory[joint] = true, true
	end
	for joint in pairs(ids) do
		if not inventory[joint] then
			error("Rig track IDs contain a joint outside the fresh inventory", 0)
		end
	end
	if state.trackIds ~= nil or state.resolveTracks ~= nil then
		if type(state.trackIds) ~= "table" then
			error("state.trackIds must contain the current rig track IDs", 0)
		end
		-- Compare both directions: renames, additions, removals and replacements must not remap keys.
		for joint in pairs(inventory) do
			if state.trackIds[joint] ~= ids[joint] then
				error("Rig tracks changed; reselect the rig before saving or loading", 0)
			end
		end
		for joint, id in pairs(state.trackIds) do
			if not inventory[joint] or ids[joint] ~= id then
				error("Rig tracks changed; reselect the rig before saving or loading", 0)
			end
		end
	end
	return state.rig.Name, motorNames
end

local function validateTrackName(motorName, motorNames)
	if type(motorName) ~= "string" or motorName == "" then
		error("Track names must be nonempty strings", 0)
	end
	if motorName == "meta" then
		error("Track name 'meta' is reserved for save metadata", 0)
	end
	if not motorNames[motorName] then
		error("Unknown joint track on selected rig: " .. motorName, 0)
	end
end

local function validatedTime(time, context)
	-- Validate before rounding so a small negative or a value above 600 cannot slip through.
	if not isFinite(time) or time < 0 or time > MAX_KEY_TIME then
		error(context .. ": key time must be finite and between 0 and 600 seconds", 0)
	end
	return math.floor(time * 1000 + 0.5) / 1000
end

local function validateCFrame(cframe, context)
	if typeof(cframe) ~= "CFrame" then
		error(context .. ": key value must be a CFrame", 0)
	end
	for _, component in ipairs({ cframe:GetComponents() }) do
		if not isFinite(component) then
			error(context .. ": CFrame components must be finite", 0)
		end
	end
end

local function validatedDuration(duration, latest)
	if duration ~= nil and (not isFinite(duration) or duration < 0 or duration > MAX_KEY_TIME) then
		error("Duration must be finite and between 0 and 600 seconds", 0)
	end
	return math.max(1, duration or 1, latest)
end

local function validatedKeys(keys, motorNames)
	if keys ~= nil and type(keys) ~= "table" then
		error("state.keys must be a table", 0)
	end
	local tracks = {}
	local latest = 0
	for motorName, motorKeys in pairs(keys or {}) do
		validateTrackName(motorName, motorNames)
		if type(motorKeys) ~= "table" then
			error("Track keys must be a table: " .. motorName, 0)
		end
		local copiedKeys = {}
		for time, cframe in pairs(motorKeys) do
			local keyTime = validatedTime(time, motorName)
			validateCFrame(cframe, motorName)
			if copiedKeys[keyTime] ~= nil then
				error("Duplicate rounded key time in track: " .. motorName, 0)
			end
			copiedKeys[keyTime] = cframe
			latest = math.max(latest, keyTime)
		end
		if next(copiedKeys) ~= nil then
			tracks[motorName] = copiedKeys
		end
	end
	return tracks, latest
end

local function sortedMotorNames(keys)
	local names = {}
	for motorName, motorKeys in pairs(keys or {}) do
		local hasKey = false
		for _ in pairs(motorKeys) do
			hasKey = true
			break
		end
		if hasKey then
			table.insert(names, motorName)
		end
	end
	table.sort(names)
	return names
end

local function sortedKeyTimes(keys)
	local times = {}
	for time in pairs(keys or {}) do
		if type(time) == "number" then
			table.insert(times, time)
		end
	end
	table.sort(times)
	return times
end

local function parseKeyTime(valueName, motorName)
	local text = string.match(valueName, "^k_([%-]?%d+%.?%d*)$")
	if not text then
		error("Invalid key name: " .. valueName, 0)
	end
	return validatedTime(tonumber(text), motorName .. "/" .. valueName)
end

function SaveLoad.save(state, name)
	local staging = nil
	local createdRoot = nil
	local ok, result = pcall(function()
		local rigName, motorNames = validateRig(state)
		local tracks, latest = validatedKeys(state.keys, motorNames)
		local duration = validatedDuration(state.duration, latest)
		local saveName = normalizedName(name)
		if saveName == "" then
			saveName = "anim_" .. tostring(os.time())
		end

		-- New saves live inside the selected rig, so a copied/published rig carries
		-- its own animations and two rigs can reuse the same animation name safely.
		local root = getRigSaveRoot(state, false)
		local existing = root and uniqueChild(root, saveName)
		if existing and not existing:IsA("Folder") then
			error("Save name is occupied by a non-Folder: " .. saveName, 0)
		end

		-- Build the entire replacement off-tree; a failed save leaves the old save intact.
		staging = Instance.new("Folder")
		staging.Name = saveName
		if staging.Name ~= saveName then error("Save name exceeds Roblox's 100-byte name limit", 0) end
		local meta = Instance.new("Folder")
		meta.Parent = staging
		meta.Name = "meta"
		if duration > math.max(1, latest) then
			meta:SetAttribute("Duration", duration)
		end

		local storedRigName = Instance.new("StringValue")
		storedRigName.Parent = meta
		storedRigName.Name = "rigName"
		storedRigName.Value = rigName
		local savedAt = Instance.new("NumberValue")
		savedAt.Parent = meta
		savedAt.Name = "savedAt"
		savedAt.Value = os.time()

		for _, motorName in ipairs(sortedMotorNames(tracks)) do
			local motorFolder = Instance.new("Folder")
			motorFolder.Parent = staging
			motorFolder.Name = motorName
			if motorFolder.Name ~= motorName then error("Joint track ID exceeds Roblox's name limit", 0) end
			for _, time in ipairs(sortedKeyTimes(tracks[motorName])) do
				local value = Instance.new("CFrameValue")
				value.Parent = motorFolder
				value.Name = string.format("k_%.3f", time)
				value.Value = tracks[motorName][time]
			end
		end

		if not root then root = getRigSaveRoot(state, true) end
		staging.Parent = root
		if existing then
			existing:Destroy()
		end
		staging = nil
		createdRoot = nil
		return saveName
	end)

	if not ok then
		if staging then
			pcall(function()
				staging:Destroy()
			end)
		end
		if createdRoot then
			pcall(function()
				createdRoot:Destroy()
			end)
		end
		return false, tostring(result)
	end
	return true, result
end

function SaveLoad.load(state, name)
	local ok, result = pcall(function()
		local rigName, motorNames = validateRig(state)
		if table.isfrozen(state) then
			error("Editor state is read-only", 0)
		end
		local saveName = normalizedName(name)
		if saveName == "" then
			error("Load name is empty", 0)
		end
		local root = getRigSaveRoot(state, false)
		local saveFolder = root and uniqueChild(root, saveName)
		-- Backward compatibility: old global saves can still be loaded, but new
		-- saves are never written to the shared ReplicatedStorage location.
		if not saveFolder then
			local legacyRoot = getLegacySaveRoot()
			saveFolder = legacyRoot and uniqueChild(legacyRoot, saveName)
		end
		if not saveFolder or not saveFolder:IsA("Folder") then
			error("Save not found: " .. saveName, 0)
		end

		local meta = uniqueChild(saveFolder, "meta")
		if not meta or not meta:IsA("Folder") then
			error("Save is missing its meta Folder", 0)
		end
		local storedRigName = uniqueChild(meta, "rigName")
		local savedAt = uniqueChild(meta, "savedAt")
		if not storedRigName or not storedRigName:IsA("StringValue") then
			error("Save is missing rigName StringValue metadata", 0)
		end
		if not savedAt or not savedAt:IsA("NumberValue") or not isFinite(savedAt.Value) or savedAt.Value < 0 then
			error("Save is missing valid savedAt NumberValue metadata", 0)
		end
		for _, child in ipairs(meta:GetChildren()) do
			if child ~= storedRigName and child ~= savedAt then
				error("Unexpected save metadata: " .. child.Name, 0)
			end
		end
		if storedRigName.Value ~= rigName then
			error(string.format("Rig mismatch: expected %s, got %s", storedRigName.Value, rigName), 0)
		end

		local loadedKeys = {}
		local keyCounts = {}
		local latest = 0
		for _, child in ipairs(saveFolder:GetChildren()) do
			if child ~= meta then
				if not child:IsA("Folder") then
					error("Track must be a Folder: " .. child.Name, 0)
				end
				local motorName = child.Name
				validateTrackName(motorName, motorNames)
				if loadedKeys[motorName] ~= nil then
					error("Duplicate track Folder: " .. motorName, 0)
				end
				local motorKeys = {}
				local count = 0
				for _, value in ipairs(child:GetChildren()) do
					if not value:IsA("CFrameValue") then
						error("Invalid key value in track: " .. motorName, 0)
					end
					local time = parseKeyTime(value.Name, motorName)
					if motorKeys[time] ~= nil then
						error("Duplicate rounded key time in track: " .. motorName, 0)
					end
					local cframe = value.Value
					validateCFrame(cframe, motorName .. "/" .. value.Name)
					motorKeys[time] = cframe
					count = count + 1
					latest = math.max(latest, time)
				end
				loadedKeys[motorName] = motorKeys
				keyCounts[motorName] = count
			end
		end

		local duration = validatedDuration(meta:GetAttribute("Duration"), latest)
		-- No state writes occur until every entry is valid. Raw writes cannot invoke metamethods.
		rawset(state, "keys", loadedKeys)
		rawset(state, "duration", duration)
		rawset(state, "keyCounts", keyCounts)
		rawset(state, "minTime", 0)
		rawset(state, "maxTime", duration)
		rawset(state, "currentTime", 0)
		rawset(state, "selectedKeys", {})
		return saveName
	end)
	if not ok then
		return false, tostring(result)
	end
	return true, result
end

function SaveLoad.listSaves()
	local ok, result = pcall(function()
		local root = getLegacySaveRoot()
		local names = {}
		local seen = {}
		if root then
			for _, child in ipairs(root:GetChildren()) do
				if seen[child.Name] then
					error("Duplicate save name: " .. child.Name, 0)
				end
				seen[child.Name] = true
				if child:IsA("Folder") then
					table.insert(names, child.Name)
				end
			end
		end
		table.sort(names)
		return names
	end)
	if not ok then
		return {}, tostring(result)
	end
	return result
end

return SaveLoad
